module kernel;

import std::io;
import board;
import sbi;

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

// The hart that OpenSBI handed control to in S-mode — captured from a0
// in boot() (kernel.c3) into boot_hartid_raw before anything else runs.
ulong boot_hartid_raw @export("boot_hartid_raw");
ulong boot_hartid;

// Set true by each hart once it reaches secondary_main (or, for the
// boot hart, by smp_start_secondaries). One writer per slot; the boot
// hart only ever reads the others. Plain aligned bool on RV64 — no
// cross-hart mutation of a shared word, so no atomics needed.
bool[SMP_MAX_HARTS] hart_online;

// --- SMP scheduler, Stage A: per-hart control block --------------------
// (docs/roadmap.md §8, docs/devlog.md). The kernel's scheduler state is
// still single-hart — current_proc / idle_proc (process.c3) are plain
// globals, and yield() has one run queue. This struct is where Stage C
// moves the per-hart pieces: `current_proc`, an idle Process*, this
// hart's dedicated trap stack top (the sscratch anchor for traps taken
// before its first switch_context), and an IPI mailbox for cross-hart
// reschedule / TLB shootdown. Stage A only lays down the array and the
// "which hart am I" accessor so the Stage B locks (spinlock.c3) can be
// per-hart from the start.
struct Hart
{
	uint hartid;
	bool scheduling; // Stage C: does this hart run the scheduler loop?
}

Hart[SMP_MAX_HARTS] harts;

// Which hart is executing this code. Stage A/B: only the boot hart ever
// runs kernel code (secondaries park in wfi with interrupts masked), so
// this is a constant. Stage C replaces it with a real per-hart source —
// RISC-V S-mode has no hartid CSR, so the options are a tp reserved for
// S-mode use or an sscratch-indirect per-hart block; that choice touches
// the trap entry asm and belongs with the second-hart bring-up, not here.
// Every Stage B lock / irq nest indexes by this, so getting it wrong
// later is a compile-time-visible single call site, not a scattered
// refactor.
fn uint this_hartid() @inline
{
	return (uint)boot_hartid;
}

// Called from kernel_main before smp_start_secondaries, once boot_hartid
// is known, to mark the boot hart as the (currently sole) scheduling hart.
fn void smp_init_boot_hart() @noinline
{
	boot_hartid = boot_hartid_raw;
	if (boot_hartid < SMP_MAX_HARTS)
	{
		harts[(uint)boot_hartid].hartid = (uint)boot_hartid;
		harts[(uint)boot_hartid].scheduling = true;
	}
}

// One boot stack per potential secondary. .bss, so zero-filled; 16 KiB
// each is plenty for the wfi-park path (it never nests deep). Indexed
// by hartid. @align(16) — the RISC-V ABI wants a 16-byte-aligned sp.
const uint SECONDARY_STACK_SIZE = 16 * 1024;
char[SECONDARY_STACK_SIZE][SMP_MAX_HARTS] secondary_stacks @align(16);

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
	// Mask every interrupt on this hart and park. Pure-register CSR ops
	// only (csrw sie, zero / csrci sstatus, SSTATUS_SIE) — a secondary
	// must not call write_csr(), which bridges through a global shared
	// with the boot hart. No stvec is set: with interrupts masked and
	// nothing but wfi running, no trap is taken, so the (zero/garbage)
	// stvec is never consulted.
	asm(`
        csrw sie, zero
        csrci sstatus, 2
    `);

	if (hartid < SMP_MAX_HARTS)
	{
		hart_online[hartid] = true;
	}

	// wfi in a loop: the spec allows wfi to return spuriously, so it is
	// only ever correct inside a loop that re-checks the wait condition
	// — here the condition is "forever", there being no SMP scheduler
	// to wake us into.
	for (;;)
	{
		asm(`wfi`);
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

	uint started = 0;
	for (ulong h = 0; h < max; h++)
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

	if (started == 0)
	{
		io::printfn("SMP: boot hart %d only (no secondaries)", (int)boot_hartid);
	}
	else
	{
		io::printfn("SMP: %d hart(s) online of %d (boot hart %d); secondaries parked — no SMP scheduler yet",
			(int)online, (int)(started + 1), (int)boot_hartid);
	}
}
