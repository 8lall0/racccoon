module kernel;

import std::io;
import board;
import sbi;
import panic;

// Multi-core (SMP) scaffold — hart enumeration + bring-up only.
//
// This is NOT an SMP scheduler. racccoon's kernel still assumes it is
// never preempted (a single run queue, no locks), so the secondary
// harts brought up here do exactly one useful thing — announce
// themselves — and then park in `wfi` forever. What this buys today:
//   - proves the SBI HSM (Hart State Management) bring-up path works,
//   - gives boot a real count of usable harts (board::SMP_MAX_HARTS is
//     just a ceiling; the kernel discovers which ones actually exist),
//   - lays down the per-hart state (stacks, an online bitmap) a real
//     scheduler would build on.
//
// Testable on QEMU with `-smp N` (default launch scripts pass no -smp,
// so this is a clean no-op there). The Milk-V Duo's second C906 has no
// MMU and is never an SMP target — boards/duo/board.c3 sets
// SMP_MAX_HARTS = 1, so smp_start_secondaries() there is a no-op too.

// Hard ceiling on the per-hart arrays below. board::SMP_MAX_HARTS is
// the per-board *policy* limit and is clamped to this.
const uint SMP_MAX_HARTS = 8;

// The hart that OpenSBI handed control to in S-mode — a0 at the S-mode
// entry, carried as kernel_main's parameter and written here right after
// the .bss clear (this var is IN .bss — see boot()/kernel_main). Was
// previously stashed by boot() itself and silently zeroed by that clear;
// harmless on a hart-0 boot, wrong on the sifive_u harness (hart 1).
ulong boot_hartid_raw @export("boot_hartid_raw");
ulong boot_hartid;

// Set true by each hart once it reaches secondary_main (or, for the
// boot hart, by smp_start_secondaries). One writer per slot; the boot
// hart only ever reads the others. Plain aligned bool on RV64 — no
// cross-hart mutation of a shared word, so no atomics needed.
bool[SMP_MAX_HARTS] hart_online;

// --- SMP scheduler: per-hart control block ----------------------------
// (docs/roadmap.md §8). `current` is the process this hart runs; the
// kernel-wide `current_proc` global mirrors the current of whichever hart
// holds kernel_lock (Stage C2) — only that hart runs kernel code — so it is
// reloaded from here every time a hart takes the lock (handle_trap, yield
// after a switch, kernel_lock_breathe). `idle` is the hart's idle context
// (pid 0), `switched_from` the process this hart just switched away from,
// released to other harts by sched_after_switch once its state is saved.
struct Hart
{
	uint hartid;
	bool scheduling;           // runs the scheduler (boot hart, started secondaries)
	Process* current;
	Process* idle;
	Process* switched_from;
}

Hart[SMP_MAX_HARTS] harts;

// An idle hart's longest lock-free wait (0.5 ms): yield() also drains the
// PLIC by hand and runs the sleep / IPC-timeout sweeps, which a sleeping
// driver's completion depends on — so idle harts must keep calling it.
const ulong SCHED_IDLE_WAIT_TICKS = board::TIMEBASE_HZ / 2000 + 1;

// How many harts schedule. yield()'s lock breather only kicks in above 1,
// so a single-hart system behaves exactly as before.
uint g_sched_harts = 1;

// Lock-free peek for idle harts: is there a runnable process no hart is
// running? Racy by design — a stale answer only delays or wastes one look
// under the lock, where the real decision is made.
fn bool sched_has_work() @noinline
{
	for (int i = 0; i < PROCS_MAX; i++)
	{
		Process* p = &procs[i];
		if (p.state == PROC_RUNNABLE && p.pid > 0 && p.on_hart < 0) { return true; }
	}
	return false;
}

// An idle hart's wait: drop the lock, poll sched_has_work() every ~20 µs
// without it, and take it back after `max_ticks` at most (the boot hart
// still owes the shell-respawn check and the housekeeping yield() runs).
fn void sched_idle_wait(ulong max_ticks) @noinline
{
	kernel_lock.release();
	// Interrupts on only here — idle, no lock held — so a timer tick (the
	// supervisor, sleep deadlines) still reaches an idle hart. Everywhere
	// else kernel code runs with SIE off: an interrupt in yield() between
	// dropping kernel_lock and switch_context built its trap frame over the
	// yielding process's own and re-entered the lock (SMP Stage C3).
	asm(`csrsi sstatus, 2`);
	ulong start = time_raw();
	ulong step = board::TIMEBASE_HZ / 50000 + 1;
	for (;;)
	{
		ulong t = time_raw();
		if (t - start >= max_ticks || sched_has_work()) { break; }
		while (time_raw() - t < step) { }
	}
	asm(`csrci sstatus, 2`);
	kernel_lock.acquire();
	current_proc = harts[this_hartid()].current;
}

// --- SMP Stage C1: per-hart identity via `tp` + `sscratch` ------------
// RISC-V S-mode has no hartid CSR, so the kernel carries its per-hart
// identity itself (the xv6 scheme):
//   - `sscratch` always holds &hart_scratch[this hart] while in S-mode.
//   - `tp` holds the same pointer while kernel C code runs (the ABI
//     reserves tp, the compiler never allocates it, so it survives every
//     call and every switch_context — a context switch never changes
//     harts, so tp correctly stays with the hart).
//   - kernel_entry swaps tp with sscratch on a trap (getting the pointer
//     back after user code ran with its own tp), parks the user sp in
//     HartScratch.tmp and builds the trap frame on HartScratch.kstack.
//   - switch_context stores the resumed process's kernel-stack top into
//     HartScratch.kstack (it used to `csrw sscratch` it).
// Only the trap asm touches HartScratch, and its offsets are baked into
// that asm (KSTACK=0, TMP=8, HARTID=16).
struct HartScratch
{
	uptr  kstack;  // +0  frame anchor: the running process's kstack top, or the bare trap stack
	uptr  tmp;     // +8  trap-entry scratch: the user sp
	ulong hartid;  // +16
	ulong _pad;    // +24 (32-byte stride)
}

HartScratch[SMP_MAX_HARTS] hart_scratch @align(32);

// The `time` CSR for code running WITHOUT kernel_lock (the idle waits, the
// lock breather): read_reg() bridges through the shared read_reg_tmp global,
// and racing the lock holder's own read_reg / write_csr / write_sepc there
// corrupted another hart's values (user processes resumed at garbage pcs).
fn ulong time_raw() @naked @noinline
{
	asm(`
        csrr a0, time
        ret
    `);
}

// @naked, a0 by the ABI — not read_reg_tmp / write_csr_tmp, whose shared
// globals two harts would race.
fn uptr read_tp() @naked @noinline
{
	asm(`
        mv a0, tp
        ret
    `);
}

fn void set_hart_pointer(HartScratch* s) @naked @noinline
{
	asm(`
        mv tp, a0
        csrw sscratch, a0
        ret
    `);
}

// The hart running this code. Valid once this hart has run
// hart_identity_init (kernel_main for the boot hart, secondary_main for the
// others); every Stage B lock / irq nest indexes by it.
fn uint this_hartid() @noinline
{
	HartScratch* s = (HartScratch*)read_tp();
	return (uint)s.hartid;
}

// Point this hart's tp + sscratch at its HartScratch. Run once per hart in
// bare mode, before any trap can be taken on it; `kstack_top` is the
// anchor kernel_entry builds a frame on until switch_context repoints it
// at a real process.
fn void hart_identity_init(uint hartid, uptr kstack_top) @noinline
{
	HartScratch* s = &hart_scratch[hartid];
	s.kstack = kstack_top & ~(uptr)15; // see kernel_main's alignment note
	s.tmp    = 0;
	s.hartid = hartid;
	set_hart_pointer(s);
}

// Called from kernel_main, once boot_hartid is known: the boot hart's
// identity (replaces the old plain `write_csr("sscratch", ...)`), and mark
// it the (currently sole) scheduling hart.
fn void smp_init_boot_hart() @noinline
{
	boot_hartid = boot_hartid_raw;
	uint bh = (uint)boot_hartid;
	if (bh < SMP_MAX_HARTS)
	{
		harts[bh].hartid = bh;
		harts[bh].scheduling = true;
		hart_identity_init(bh, (uptr)&boot_trap_stack + boot_trap_stack.len);
	}
}

// One boot stack per potential secondary. .bss, so zero-filled; 16 KiB
// each is plenty for the wfi-park path (it never nests deep). Indexed
// by hartid. @align(16) — the RISC-V ABI wants a 16-byte-aligned sp.
const uint SECONDARY_STACK_SIZE = 16 * 1024;
char[SECONDARY_STACK_SIZE][SMP_MAX_HARTS] secondary_stacks @align(16);

// Each secondary's bare-mode trap-frame anchor (its HartScratch.kstack until
// the first switch_context), like the boot hart's boot_trap_stack.
char[4096][SMP_MAX_HARTS] secondary_trap_stacks @align(16);

// SBI HSM extension (EID "HSM" = 0x48534D), FID 0 = sbi_hart_start:
// wake `hartid` (must be in the STOPPED state) and enter it in S-mode
// at `start_addr` with satp=0, a0=hartid, a1=`opaque`.
fn bool hart_is_online(uint h) @noinline
{
	// @noinline so the -O2 optimizer can't hoist this read out of the
	// bounded spin loop in smp_start_secondaries() and turn it into an
	// infinite loop — the store that flips it happens on another hart.
	return h < SMP_MAX_HARTS && hart_online[h];
}

// The naked landing pad SBI drops a woken hart into: its stack pointer
// arrives in a1 (the `opaque` we passed to sbi_hart_start), its hartid
// in a0. Set sp, then straight into secondary_main — no prologue, no
// touching the shared write_csr_tmp/read_reg_tmp globals (those would
// race the boot hart).
fn void secondary_entry() @naked @export("secondary_entry") @section(".text.boot") @noinline @nostrip @used
{
	asm(`
        mv sp, a1
        j secondary_main
    `);
}

fn void secondary_main(ulong hartid) @export("secondary_main") @noinline @nostrip
{
	// Interrupts off until this hart is set up. Pure-register CSR ops
	// only: write_csr()/read_reg() bridge through globals, which are safe
	// only under kernel_lock (Stage C2 — one hart in the kernel at a time).
	asm(`
        csrw sie, zero
        csrci sstatus, 2
    `);
	if (hartid >= SMP_MAX_HARTS)
	{
		for (;;) { asm(`wfi`); }
	}
	uint h = (uint)hartid;
	hart_identity_init(h, (uptr)&secondary_trap_stacks[h] + 4096);
	hart_online[h] = true;

	// SMP Stage C3: from here this hart schedules. Everything below runs
	// under the giant lock, like any kernel code.
	kernel_lock.acquire();
	write_reg("stvec", "kernel_entry");
	// sstatus is per hart: FPU on (FS), and SUM — S-mode access to user
	// pages, which every syscall copying to/from user memory needs. The boot
	// hart gets SUM from user_entry's sstatus and keeps it; a secondary
	// whose first process arrived via fork_entry or a resumed trap never
	// passed there, and its first such syscall page-faulted inside the
	// kernel, holding kernel_lock (a recursive acquire, all harts stuck).
	write_csr("sstatus", (read_reg("sstatus") & ~SSTATUS_FS_MASK) | SSTATUS_FS_INITIAL | SSTATUS_SUM);
	enable_user_timer_access();

	Process* idle = create_process(null, 0);
	if (idle == null) { panic::panic("SMP: can't create a secondary idle process"); }
	proc_set_name(idle, "idle");
	idle.pid = 0;
	idle.on_hart = (int)h;
	harts[h].hartid = h;
	harts[h].idle = idle;
	harts[h].current = idle;
	harts[h].scheduling = true;
	current_proc = idle;

	// This hart's own timer: preemption of whatever it runs (the 1 s tick
	// and sleep deadlines are shared — handle_trap re-arms per hart).
	arm_next_timer();
	write_csr("sie", read_reg("sie") | SIE_STIE);

	for (;;)
	{
		yield();
		sched_idle_wait(SCHED_IDLE_WAIT_TICKS);
	}
}

// Called once from kernel_main after all the boot servers are up and
// before the idle loop. Discovers and starts every hart the board
// policy allows, waits (bounded) for each to check in, and prints the
// tally.
fn void smp_start_secondaries() @noinline
{
	boot_hartid = boot_hartid_raw;

	uint max = board::SMP_MAX_HARTS;
	if (max > SMP_MAX_HARTS) { max = SMP_MAX_HARTS; }

	if (boot_hartid < SMP_MAX_HARTS)
	{
		hart_online[(uint)boot_hartid] = true;
	}

	// board::SMP_MAX_HARTS <= 1 is the "single-hart, no SMP" policy both
	// shipping boards set (boards/duo, boards/opi-rv). Nothing to start,
	// whatever hart we booted on — and the guard matters: with a boot hart
	// other than 0 (the Orange Pi RV / JH7110 boots on hart 1) the loop
	// below would otherwise iterate to h=0 and sbi_hart_start() the JH7110's
	// S7 monitor core, an explicit non-target. Invisible on the Duo, whose
	// boot hart 0 is caught by the h == boot_hartid check.
	// Harts SMP_HART_MIN .. SMP_HART_MIN + max - 1: the JH7110's hart 0 is
	// the S7 monitor core (no MMU, an explicit non-target), its U74s are 1-4.
	uint started = 0;
	ulong hmin = board::SMP_HART_MIN;
	for (ulong h = hmin; max > 1 && h < hmin + max && h < SMP_MAX_HARTS; h++)
	{
		if (h == boot_hartid) { continue; }

		sbi::Sbiret r = sbi::sbi_hart_start(
			h,
			(ulong)(uptr)&secondary_entry,
			(ulong)((uptr)&secondary_stacks[h] + SECONDARY_STACK_SIZE));

		// error 0 = SBI_SUCCESS (coming up). Anything else — most
		// commonly SBI_ERR_INVALID_PARAM for a hartid that doesn't
		// exist on this machine, or SBI_ERR_ALREADY_AVAILABLE — just
		// means "not a hart we can use", so skip it.
		if (r.error != 0) { continue; }
		started++;

		// Bounded wait for the secondary to reach secondary_main. Big
		// enough for a real hart to get there, small enough that a hart
		// which starts but wedges first can't hang boot.
		for (int spin = 0; spin < 20_000_000 && !hart_is_online((uint)h); spin++)
		{
			asm(`nop`);
		}
	}

	uint online = 0;
	for (uint i = 0; i < SMP_MAX_HARTS; i++)
	{
		if (hart_online[i]) { online++; }
	}

	// Every hart that came online schedules (secondary_main); count them
	// now, before they can take kernel_lock, so yield() starts letting them
	// in right away.
	g_sched_harts = online > 0 ? online : 1;

	if (started == 0)
	{
		io::printfn("SMP: boot hart %d only (no secondaries)", (int)boot_hartid);
	}
	else
	{
		io::printfn("SMP: %d hart(s) online of %d (boot hart %d), all scheduling",
			(int)online, (int)(started + 1), (int)boot_hartid);
	}
}
