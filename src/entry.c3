module kernel;

import std::io;
import panic;
import board;
import sbi;

const SCAUSE_ECALL             = 8;
// Synchronous page-fault causes (RISC-V privileged spec table): a fetch,
// load, or store/AMO through a PTE that's invalid or lacks permission.
// try_lazy_fault (handle_trap) uses these to demand-map a SYS_MAP page.
const SCAUSE_INST_PAGE_FAULT   = 12;
const SCAUSE_LOAD_PAGE_FAULT   = 13;
const SCAUSE_STORE_PAGE_FAULT  = 15;
// RV64 port: the interrupt bit is scause's MSB — bit 63 on RV64, not
// bit 31 as on RV32. This is a real correctness-critical difference,
// not just a width bump; getting it wrong silently misclassifies every
// interrupt as an exception (or vice versa).
const ulong SCAUSE_INTERRUPT_BIT = (1ul << 63);
const SCAUSE_SUPERVISOR_EXTERNAL = 9;        // interrupt cause code for a PLIC-routed external interrupt — same code on both XLENs
const SCAUSE_SUPERVISOR_TIMER    = 5;        // interrupt cause code for a real timer interrupt (sstc's stimecmp) — same code on both XLENs

// Dedicated trap-frame anchor for traps taken during kernel_main's
// bare-mode phase, between enable_external_interrupts() and the first
// process existing — a brief window, but interrupts are live during it.
// Deliberately NOT __stack_top:
// __stack_top is the *top* of the live boot stack kernel_main is actively
// executing on, not a spare/unused region — anchoring sscratch there
// means the trap frame plus handle_trap's own call depth (io::printfn,
// plic_claim, ...) grows down from the top of a stack kernel_main is
// simultaneously using several frames deep into, and collides with it.
// A real process doesn't have this problem: its sscratch points at its
// own dedicated 64KB stack, which nothing else is using concurrently.
// This buffer plays that same "dedicated, nothing else touches it" role
// for the brief pre-process window.
char[4096] boot_trap_stack;

// Sentinel msg_type handle_trap posts to wake an interrupt-driven
// driver when its PLIC source fires (see handle_trap's interrupt branch
// and the Irq_route table in process.c3) — distinguishes "your device
// fired, go check its status register" from an actual client request in
// the driver's single inbox slot. Opaque to the driver: diskd, sdd,
// usbd all treat it the same way. Named for its first user; must match
// user/diskd.c3's copy (and user/sdd.c3, user/usb/dwc2.c3).
const uint DISKD_IRQ_NOTIFY = 0xFFFFFFFF;

// RV64 port: these bridge globals carry full CSR values now (sepc/satp
// hold real 64-bit addresses; sstatus/sie are 64-bit bitfields), so they
// widen from uint to ulong — and every asm block bridging through them
// uses sd/ld instead of sw/lw accordingly.
ulong read_reg_tmp @export("read_reg_tmp");

macro read_reg(String $reg)
{
	// Bridged through memory (t0/t1), not a0: the previous version read the
	// CSR into a0 via opaque string asm(), which the compiler can't see the
	// side effects of. Any caller that still has a value live in a0 at this
	// point (e.g. a pointer parameter it hasn't spilled) gets it silently
	// clobbered — this corrupted handle_trap's own Trap_frame* parameter in
	// practice, since the compiler had no reason to move it out of a0.
	asm(@sprintf(`
        csrr t0, %s
        la t1, read_reg_tmp
        sd t0, 0(t1)
    `, $reg));
	return read_reg_tmp;
}

macro write_reg(String $reg, String $value)
{
	// Single asm() call: two separate asm() statements bridging a value
	// through t0 can be reordered/interleaved by the optimizer, since it
	// doesn't know t0 must stay live across them (this bit us for real:
	// stvec ended up not pointing at kernel_entry until this was merged).
	asm(@sprintf(`
        la t0, %s
        csrw %s, t0
    `, $value, $reg));
}

ulong write_sepc_tmp @export("write_sepc_tmp");

fn void write_sepc(ulong value) @noinline
{
	// Single asm() call, bridged through a memory location rather than a
	// register: a normal (non-naked) function gives no guarantee about
	// which register `value` lives in by the time this runs, and splitting
	// this across separate asm() statements reintroduces the reordering
	// hazard described on write_reg.
	write_sepc_tmp = value;
	asm(`
        la t0, write_sepc_tmp
        ld t0, 0(t0)
        csrw sepc, t0
    `);
}

ulong write_csr_tmp @export("write_csr_tmp");

macro write_csr(String $reg, value)
{
	// Same memory-bridged, single-atomic-asm() pattern as write_sepc,
	// generalized to any CSR name (known at compile time, so @sprintf's
	// %s-only limitation is fine here).
	write_csr_tmp = value;
	asm(@sprintf(`
        la t0, write_csr_tmp
        ld t0, 0(t0)
        csrw %s, t0
    `, $reg));
}

const SIE_SEIE     = (1 << 9);  // sie: supervisor external interrupt enable
const SSTATUS_SIE  = (1 << 1);  // sstatus: global supervisor interrupt enable
const SSTATUS_SPP  = (1 << 8);  // sstatus: previous privilege — 0 = the trap came from U-mode, 1 = from S-mode

// sstatus.FS (bits 14:13) — FP unit state: 0 Off, 1 Initial, 2 Clean,
// 3 Dirty. Set to Initial once at boot (kernel.c3) so hardware FP is
// usable; f0-f31 + fcsr are then saved/restored on every context switch
// (yield(), process.c3). CLEAN/DIRTY are only referenced by the optional
// conditional-save path — see yield()'s own comment.
const SSTATUS_FS_MASK    = (3 << 13);
const SSTATUS_FS_INITIAL = (1 << 13);
const SSTATUS_FS_CLEAN   = (2 << 13);
const SSTATUS_FS_DIRTY   = (3 << 13);
// SSTATUS_SPIE (what sret restores SIE from — see handle_trap's own end,
// below) is process.c3's own const, not redeclared here: unlike
// DISKD_READ/etc across the separate user-mode binaries, entry.c3,
// syscalls.c3 and process.c3 compile into one shared kernel module, so a
// duplicate name is a real conflict, not a harmless copy.
const SCOUNTEREN_TM = (1 << 1); // scounteren: lets U-mode execute rdtime without trapping

fn void enable_external_interrupts()
{
	write_csr("sie", read_reg("sie") | SIE_SEIE);
	write_csr("sstatus", read_reg("sstatus") | SSTATUS_SIE);
}

// Arms the next timer interrupt via the SBI legacy set_timer call
// (sbi::__set_timer) — deliberately not a direct write to stimecmp
// (the sstc extension's own S-mode-writable CSR): confirmed on real
// Milk-V Duo hardware that writing stimecmp directly hangs the board
// silently (see docs/devlog.md and sbi::__set_timer's own comment for
// the full story — likely menvcfg.STCE not being set by the Duo's own
// firmware, unlike QEMU's OpenSBI). The SBI ecall asks M-mode firmware
// to do the actual timer-comparator programming instead, needing no
// such S-mode CSR permission at all. A supervisor timer interrupt
// (SCAUSE_SUPERVISOR_TIMER) fires once `time` reaches `now +
// delta_ticks`; handle_trap's own timer case re-arms it every time it
// fires, or the same interrupt would immediately refire forever (an
// interrupt storm, not a periodic tick) — see that case's own comment.
fn void arm_timer(ulong delta_ticks)
{
	ulong now = read_reg("time");
	sbi::__set_timer(now + delta_ticks);
}

const SIE_STIE = (1 << 5); // sie: supervisor timer interrupt enable

// Total real timer interrupts handled since boot — inert bookkeeping,
// not consulted by anything yet, but real, useful infrastructure for
// whatever needs to observe "is this firing, how often" later (this
// session's own verification used it directly — see docs/devlog.md).
ulong timer_tick_count = 0;

// Real preemptive-scheduling support (see docs/devlog.md): the sstc
// timer interrupt fires, re-arms, and — for real processes — forces a
// reschedule via yield() (see the SCAUSE_SUPERVISOR_TIMER case in
// handle_trap below) instead of only ever returning to whatever was
// running. This is safe specifically because of where a timer
// interrupt can land: unlike a hand-placed yield() call (always at a
// caller-chosen, already-safe moment), an interrupt can in principle
// land in the middle of *anything* — but the interrupt-latency
// characteristic below establishes it can only ever land during
// genuine user-mode execution, never mid-syscall kernel bookkeeping
// (SYS_IPC_SEND's own multi-step state updates, mid-page-table-edit,
// etc.), so no new concurrent-access hazard is introduced there.
//
// Real interrupt-latency characteristic found while verifying this,
// and exactly why the above is safe: SYS_GETCHAR (and SYS_IPC_RECV,
// SYS_JOIN's poll loop — every *blocking* syscall in this kernel)
// busy-loops with yield() *inside its own still-open trap*, never
// reaching sret until its condition is met. Hardware auto-clears
// sstatus.SIE on trap entry and only restores it on sret — so while
// any process is stuck inside one of these (e.g. the shell idly
// waiting for a keystroke), sstatus.SIE stays globally disabled for
// every process switch_context() switches to in the meantime, not just
// the one that's blocked (SIE is one shared, un-banked hardware bit,
// switch_context is a plain software stack swap, not a trap return —
// nothing about it touches SIE). Confirmed directly: with the shell
// left idle, a timer armed for ~1s out didn't actually fire until
// whenever the next keystroke arrived, sometimes many seconds later;
// with the shell kept continuously busy (no idle GETCHAR wait), it
// fired reliably every ~1s as armed. Direct consequence: a timer
// interrupt can only ever land during genuine, uninterrupted user-mode
// execution — never inside any trap's own kernel-mode handling,
// regardless of how many yield()-driven switches happen inside it —
// which is what makes forcing a reschedule from this handler safe
// without any new locking.
//
// The other half of that safety — current_proc.pid > 0 in the
// SCAUSE_SUPERVISOR_TIMER case below — excludes idle_proc (pid 0),
// which covers two cases the argument above doesn't: kernel_main's own
// boot-time sequence (create_process/alloc_pages for echod/diskd/fsd/
// etc — real S-mode kernel code, not user-mode, and not reentrant —
// running with interrupts already on, since this function is called
// early in kernel_main), and idle's own post-boot respawn loop (which
// already calls yield() every iteration on its own, so forcing another
// one adds no benefit, only risk).
fn void enable_timer_interrupts()
{
	// Arm *before* enabling sie.STIE, not after: stimecmp's reset value
	// is implementation-defined and could easily be 0, which would make
	// `time >= stimecmp` already true the instant STIE goes live —
	// enabling the source with a real future deadline already in place
	// avoids that spurious-immediate-fire window entirely.
	arm_timer(board::TIMEBASE_HZ); // first tick ~1 second out
	write_csr("sie", read_reg("sie") | SIE_STIE);
}

// mcounteren.TM (M-mode -> S-mode) is expected to already be enabled by
// OpenSBI — standard practice, needed for any S-mode OS to read `time`
// at all — so nothing to do for this kernel's own S-mode access.
// scounteren.TM (S-mode -> U-mode) is this kernel's own responsibility,
// and was never set before this: any user-mode `rdtime` would have
// trapped. See user/sdd.c3's own real-time wait budgets (docs/devlog.md)
// for the actual motivation — busy-wait loops there used to be raw
// iteration counts with no real correspondence to wall-clock time.
fn void enable_user_timer_access()
{
	write_csr("scounteren", read_reg("scounteren") | SCOUNTEREN_TM);
}

// @align(4) alone is not reliably honored (found via disassembly diffing:
// unrelated code-size changes elsewhere shifted this function to a
// 2-byte-but-not-4-byte-aligned address in a real build). stvec's low 2
// bits ARE the trap mode field per the RISC-V spec (0=Direct, 1=Vectored,
// 2/3=Reserved) — writing a misaligned address here puts the CPU into
// Reserved trap mode, undefined behavior, which is almost certainly the
// real mechanism behind this project's whole string of "silent reboot,
// no trap ever printed" bugs blamed on the compiler. Pinned into its own
// section with linker-enforced alignment in kernel.ld instead, since the
// linker script's ALIGN() is what's actually trustworthy here.
//
// RV64 port: sd/ld instead of sw/lw, 8*N offsets instead of 4*N — every
// saved register is 8 bytes now, so the 31-word frame is 248 bytes, not
// 124.
fn void kernel_entry() @align(4) @section(".text.trap") @export("kernel_entry") @noinline @nostrip
{
	asm(`
        csrrw sp, sscratch, sp

        addi sp, sp, -8 * 31
        sd ra,  8 * 0(sp)
        sd gp,  8 * 1(sp)
        sd tp,  8 * 2(sp)
        sd t0,  8 * 3(sp)
        sd t1,  8 * 4(sp)
        sd t2,  8 * 5(sp)
        sd t3,  8 * 6(sp)
        sd t4,  8 * 7(sp)
        sd t5,  8 * 8(sp)
        sd t6,  8 * 9(sp)
        sd a0,  8 * 10(sp)
        sd a1,  8 * 11(sp)
        sd a2,  8 * 12(sp)
        sd a3,  8 * 13(sp)
        sd a4,  8 * 14(sp)
        sd a5,  8 * 15(sp)
        sd a6,  8 * 16(sp)
        sd a7,  8 * 17(sp)
        sd s0,  8 * 18(sp)
        sd s1,  8 * 19(sp)
        sd s2,  8 * 20(sp)
        sd s3,  8 * 21(sp)
        sd s4,  8 * 22(sp)
        sd s5,  8 * 23(sp)
        sd s6,  8 * 24(sp)
        sd s7,  8 * 25(sp)
        sd s8,  8 * 26(sp)
        sd s9,  8 * 27(sp)
        sd s10, 8 * 28(sp)
        sd s11, 8 * 29(sp)

        csrr a0, sscratch
        sd a0, 8 * 30(sp)

        addi a0, sp, 8 * 31

        csrw sscratch, a0
        mv a0, sp
        call handle_trap

        ld ra,  8 * 0(sp)
        ld gp,  8 * 1(sp)
        ld tp,  8 * 2(sp)
        ld t0,  8 * 3(sp)
        ld t1,  8 * 4(sp)
        ld t2,  8 * 5(sp)
        ld t3,  8 * 6(sp)
        ld t4,  8 * 7(sp)
        ld t5,  8 * 8(sp)
        ld t6,  8 * 9(sp)
        ld a0,  8 * 10(sp)
        ld a1,  8 * 11(sp)
        ld a2,  8 * 12(sp)
        ld a3,  8 * 13(sp)
        ld a4,  8 * 14(sp)
        ld a5,  8 * 15(sp)
        ld a6,  8 * 16(sp)
        ld a7,  8 * 17(sp)
        ld s0,  8 * 18(sp)
        ld s1,  8 * 19(sp)
        ld s2,  8 * 20(sp)
        ld s3,  8 * 21(sp)
        ld s4,  8 * 22(sp)
        ld s5,  8 * 23(sp)
        ld s6,  8 * 24(sp)
        ld s7,  8 * 25(sp)
        ld s8,  8 * 26(sp)
        ld s9,  8 * 27(sp)
        ld s10, 8 * 28(sp)
        ld s11, 8 * 29(sp)
        ld sp,  8 * 30(sp)
        sret
    `);
}

struct Trap_frame @packed
{
	ulong ra;
	ulong gp;
	ulong tp;
	ulong t0;
	ulong t1;
	ulong t2;
	ulong t3;
	ulong t4;
	ulong t5;
	ulong t6;
	ulong a0;
	ulong a1;
	ulong a2;
	ulong a3;
	ulong a4;
	ulong a5;
	ulong a6;
	ulong a7;
	ulong s0;
	ulong s1;
	ulong s2;
	ulong s3;
	ulong s4;
	ulong s5;
	ulong s6;
	ulong s7;
	ulong s8;
	ulong s9;
	ulong s10;
	ulong s11;
	ulong sp;
}

// Claim, route, and complete one pending PLIC external interrupt, or do
// nothing when none is pending (plic_claim() returns 0). handle_trap's
// SCAUSE_SUPERVISOR_EXTERNAL case calls it for a genuine hardware trap;
// sys_ipc_poll also calls it, because an interrupt-driven driver
// (user/block/diskd.c3, user/block/sdd.c3, user/usb/*, user/gpio/*)
// waits for its device completion by spin-polling its inbox through
// that syscall — and while a concurrent multi-stage shell pipeline
// keeps several processes parked in SYS_IPC_CALL's cooperative yield
// loops, none of those loops ever sret, so hardware-cleared
// sstatus.SIE stays globally off and the completion IRQ is never
// taken. Draining it here delivers the driver its notify regardless of
// SIE, closing a real deadlock (diskd spins for an IRQ that can't fire
// → fsd blocks on diskd → the pipeline stage blocks on fsd → the
// shell's join() hangs). The notify lands in Process.driver_irq_pending,
// NOT the IPC inbox, so it can't collide with a client request the
// driver hasn't consumed yet. See docs/devlog.md.
fn void service_pending_external_irq() @noinline
{
	uint irq = plic_claim();

	Irq_route* route = irq_route_by_irq(irq);
	if (route != null)
	{
		Process* driver = proc_by_pid(route.pid);
		if (driver != null)
		{
			driver.driver_irq_pending = true;
			if (driver.state == PROC_BLOCKED)
			{
				driver.state = PROC_RUNNABLE;
			}
		}
	}
	if (irq != 0)
	{
		plic_complete(irq);
	}
	// A `level` source (DWC2, SDHCI, dwmac) keeps its device status line
	// asserted until the driver clears it; on this SoC a still-pending
	// external interrupt at sret re-traps before the returned-to context
	// runs an instruction, so leaving it enabled hangs the driver out of
	// ever reaching that clear. Disable AFTER plic_complete (the PLIC
	// ignores a completion for a disabled source); the driver re-arms
	// via SYS_DRIVER_IRQ_ARM before its next wait. Also disable any
	// unrecognized non-zero source — a misrouted level IRQ left enabled
	// is a guaranteed storm. An edge/latched route (virtio-mmio,
	// level=false) is the only case left enabled.
	if (irq != 0 && (route == null || route.level))
	{
		plic_set_enabled(irq, false);
	}
}

// Lazy SYS_MAP: a page fault at `stval` inside the current process's
// [map_floor, heap_top) reservation demand-maps one fresh zero page.
// Returns true if it handled the fault (execution should retry the
// faulting instruction); false for anything else — a fault outside the
// lazy region, a permission fault on an already-present page, a fault
// from S-mode, or an out-of-memory allocation failure (the caller then
// tears the process down, which is the right response to a process that
// touched more mapped memory than the machine has).
fn bool try_lazy_fault(ulong scause, ulong stval) @noinline
{
	if (scause != SCAUSE_INST_PAGE_FAULT
		&& scause != SCAUSE_LOAD_PAGE_FAULT
		&& scause != SCAUSE_STORE_PAGE_FAULT)
	{
		return false;
	}
	if ((read_reg("sstatus") & SSTATUS_SPP) != 0 || current_proc.pid == 0)
	{
		return false;
	}
	uptr addr = (uptr)stval;
	if (addr < current_proc.map_floor || addr >= current_proc.heap_top)
	{
		return false;
	}
	uptr page = addr & ~(uptr)(PAGE_SIZE - 1);
	// Present already => this is a permission fault, not a demand fault
	// (SYS_MAP pages are R|W|U, so it shouldn't be, but don't paper over
	// it) — hand it back to the real-fault path. NB the PLIC's kernel-only
	// pages used to alias into this range on QEMU and land here; they're
	// mapped high now (boards/qemu/board.c3 PLIC_BASE).
	if (pte_present(current_proc.page_table, page))
	{
		return false;
	}
	uptr phys = try_alloc_pages(1); // zero-filled
	if (phys == 0)
	{
		return false;
	}
	if (!try_map_page(current_proc.page_table, page, phys, PAGE_U | PAGE_R | PAGE_W))
	{
		free_pages(phys, 1);
		return false;
	}
	flush_tlb_page(page);
	return true;
}

// Periodic kernel bookkeeping, rate-limited to ~1/s (g_housekeeping_deadline,
// wall clock via the `time` CSR). Split in two:
//   - ipc_timeout_sweep() — cheap, allocation-free; runs from BOTH the
//     timer tick AND yield(). The yield() path is what keeps the
//     SYS_IPC_CALL timeout alive when the system is blocked-on-blocked
//     and the timer has stopped firing (every blocking syscall spins its
//     yield() loop inside an open trap with SIE cleared — see
//     enable_timer_interrupts()'s comment — so no sret, no timer).
//   - kernel_housekeeping() — the sweep plus supervisor_tick(); ONLY
//     from the timer case. supervisor_tick can proc_destroy(current_proc)
//     and have its slot reused, which is unsafe to trigger from an
//     arbitrary yield() call depth.
ulong g_housekeeping_deadline = 0;

// The SYS_IPC_CALL timeout half only — a cheap, allocation-free scan.
// Safe to run from yield() at any call depth. Wakes any caller past its
// deadline so its own phase 1/2/3 loop aborts with -1 (same shape as
// sys_kill's ipc_wake_waiters_on / ipc_peer_died). Rate-limited by the
// shared deadline guard so it does real work at most ~1/s.
fn void ipc_timeout_sweep() @noinline
{
	ulong hk_now = read_reg("time");
	if (hk_now < g_housekeeping_deadline)
	{
		return;
	}
	g_housekeeping_deadline = hk_now + board::TIMEBASE_HZ;

	for (int hk_i = 0; hk_i < PROCS_MAX; hk_i++)
	{
		Process* hk_p = &procs[hk_i];
		if (hk_p.ipc_call_deadline != 0 && hk_now >= hk_p.ipc_call_deadline)
		{
			hk_p.ipc_timed_out = true;
			hk_p.ipc_call_deadline = 0;
			if (hk_p.state == PROC_BLOCKED) { hk_p.state = PROC_RUNNABLE; }
		}
	}
}

// Full pass — the IPC sweep plus the supervisor watchdog. Only from the
// SCAUSE_SUPERVISOR_TIMER case, never yield(): supervisor_tick can
// proc_destroy(current_proc) and its slot be reused while yield() is
// mid-flight through this call.
fn bool kernel_housekeeping() @noinline
{
	ipc_timeout_sweep();
	return supervisor_tick();
}

fn void handle_trap(Trap_frame* f) @export("handle_trap") @noinline @nostrip
{
	ulong scause  = read_reg("scause");
	ulong stval   = read_reg("stval");
	ulong user_pc = read_reg("sepc");
	// Captured here, restored (via write_sepc) right before this
	// function returns — see Process.saved_sepc's own comment for why
	// this needs to be per-process state now, not just this shared
	// hardware register left to survive a trap's own handling
	// untouched. Correct as-is for every existing case (hardware
	// already points sepc at the right resume address for an
	// interrupt); the ecall branch below overwrites it with the
	// post-ecall address once it knows that's needed.
	current_proc.saved_sepc = user_pc;

	if (scause & SCAUSE_INTERRUPT_BIT)
	{
		ulong code = scause & ~SCAUSE_INTERRUPT_BIT;
		if (code == SCAUSE_SUPERVISOR_EXTERNAL)
		{
			service_pending_external_irq();
		}
		else if (code == SCAUSE_SUPERVISOR_TIMER)
		{
			// Rearm first, before anything else: stimecmp is what
			// actually clears the pending interrupt (time < stimecmp
			// again), so leaving the old, already-elapsed value in
			// place would refire the instant interrupts are next
			// enabled — an interrupt storm, not a periodic tick.
			arm_timer(board::TIMEBASE_HZ);
			timer_tick_count += 1;

			// Boot-server supervision + the IPC-call timeout sweep, both
			// via kernel_housekeeping(): ipc_timeout_sweep() (also run
			// from yield(), ~1/s) + the supervisor watchdog (timer only).
			bool svc_killed_current = kernel_housekeeping();

			// Real preemption: force a reschedule on every tick, not
			// just when a process happens to yield() on its own. See
			// enable_timer_interrupts()'s own comment above for why
			// this is safe and why it's gated on pid > 0. Also yield
			// unconditionally if the watchdog just tore down the
			// process we'd otherwise sret back into.
			if (svc_killed_current || current_proc.pid > 0)
			{
				yield();
			}
		}
		// No sepc adjustment for interrupts: unlike ecall (which must skip
		// past the trapping instruction), the hardware already points sepc
		// at the correct resume address — for wfi specifically, the
		// instruction right after it.
	}
	else if (scause == SCAUSE_ECALL)
	{
		// Syscall number, captured before handle_syscall runs: SYS_EXEC's
		// own case (below) needs to know, after the fact, whether it's
		// the one that just ran — f.a3 is preserved unchanged through the
		// switch (no case touches it), so reading it after the call is
		// exactly as reliable as reading it before.
		ulong syscall_num = f.a3;
		handle_syscall(f);
		// current_proc, not necessarily the same process that entered
		// this trap: any of the blocking syscalls in syscalls.c3 (SYS_GETCHAR,
		// SYS_IPC_RECV, SYS_JOIN's poll loop) can yield() through many
		// other processes before finally returning here — but by the
		// time handle_syscall returns, execution has unwound back onto
		// *this* process's own kernel stack (switch_context is a plain
		// stack swap; a process's own call chain, including this exact
		// frame, only ever resumes where it left off), so current_proc
		// is correctly this process again. user_pc is this same
		// process's own local copy from trap entry, untouched by
		// anything that happened to other processes in between.
		//
		// SYS_EXEC on success is the one exception: its own case already
		// set saved_sepc to USER_BASE (this process is about to run a
		// completely different image, not resume the ecall it just
		// made) — this unconditional "+4, resume right after the ecall"
		// would silently clobber that back to the old image's own
		// address. Found the hard way: SYS_EXEC's own staging/mapping
		// logic was already provably correct (a byte-for-byte checksum
		// of the loaded image matched, and per-step debug prints showed
		// no failure at any point) yet execution kept faulting inside
		// the *old* image's own code right after the ecall returned —
		// this is why: the redirect was being set correctly and then
		// overwritten before it ever took effect.
		// f.a0 carries argc on a successful SYS_EXEC now (0 or more, see
		// that case's own comment), not a plain 0 return value — a real
		// failure still sets it to (ulong)(-1), so "non-negative" is the
		// right success test, not "== 0" (argc can genuinely be nonzero).
		bool just_execd = syscall_num == SYS_EXEC && (long)f.a0 >= 0;
		if (!just_execd)
		{
			current_proc.saved_sepc = user_pc + 4;
		}
	}
	else if (try_lazy_fault(scause, stval))
	{
		// A demand fault on a lazily-reserved SYS_MAP page — one zero
		// page was just mapped in. Fall through to write_sepc (which
		// still points at the faulting instruction) + sret to retry it.
	}
	else
	{
		// Not an interrupt, not an ecall, not a lazy-map fault — a
		// synchronous exception: an unrelated page fault, an illegal
		// instruction, a misaligned access, a breakpoint. If it came
		// from U-mode (sstatus.SPP == 0), it's a buggy user program —
		// tear down just that process and move on, the same way
		// SYS_EXIT / the watchdog do. Only an exception from S-mode is a
		// genuine kernel bug worth a panic.
		//
		// This is also what lets a userspace interpreter (/bin/wasm)
		// treat an out-of-bounds computed address as a clean process
		// exit rather than needing to be provably perfect — see
		// docs/roadmap.md §4.
		if ((read_reg("sstatus") & SSTATUS_SPP) == 0 && current_proc.pid > 0)
		{
			io::printfn("user fault: pid=%d scause=%x stval=%x sepc=%x — killing the process\n",
				current_proc.pid, scause, stval, user_pc);
			proc_destroy(current_proc, -1);
			yield();   // never returns: current_proc is PROC_UNUSED now
		}
		io::printfn("unexpected trap scause=%x, stval=%x, sepc=%x, current_pid=%d\n", scause, stval, user_pc, current_proc.pid);
		panic::panic("it's a trap!");
	}

	// The one place the real sepc CSR actually gets written, always
	// immediately before this function returns (and so, immediately
	// before kernel_entry's own tail-end sret, with nothing able to run
	// in between) — see Process.saved_sepc's own comment for why this
	// needs to read per-process state rather than just trust the
	// hardware register survived whatever this trap's own handling did.
	write_sepc(current_proc.saved_sepc);

	// No blocking_depth check here, deliberately — see its own comment
	// (process.c3) for why not: an earlier version of this fix also
	// forced SPIE off here whenever blocking_depth was nonzero, but
	// blocking_depth is *effectively always* nonzero during normal
	// operation (echod/fsd/procd/envd — every idle server — sit
	// permanently blocked in SYS_IPC_RECV waiting for their next
	// client; that's their normal steady state, not a transient
	// window). Gating this shared tail on it would have disabled real
	// timer-interrupt preemption for the *entire system*, forever, from
	// very early in boot onward — found directly, real hardware/QEMU
	// testing this session, when hotplugtest itself started hanging
	// once this was in place. The kernel_entry tail's own sret already
	// correctly restores SIE from *this process's own* sstatus snapshot
	// (auto-captured at *this same trap's* own entry) — safe by the
	// existing, already-proven invariant (enable_timer_interrupts()'s
	// own comment above): SIE only actually needs forcing off for a
	// *synthetic* sret with no real corresponding trap-entry of its
	// own, which only ever happens in fork_entry() (process.c3) — never
	// here.
}
