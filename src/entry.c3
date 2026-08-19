module kernel;

import std::io;
import panic;
import board;
import sbi;

const SCAUSE_ECALL             = 8;
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

// Syscall numbers. Kernel and user are separate c3c compilations with no
// shared header, so these must be kept in sync by hand with the SYS_*
// consts in user/user.c3.
const SYS_PUTCHAR   = 1;
const SYS_GETCHAR   = 2;
const SYS_EXIT      = 3;
// 4 and 5 were SYS_READFILE/SYS_WRITEFILE — removed once fsd (user/fsd.c3)
// took over file access entirely (microkernel plan phase 5). Left unused
// rather than renumbered, matching user/user.c3's copy.
const SYS_IPC_SEND  = 6;
const SYS_IPC_RECV  = 7;
const SYS_NS_RESOLVE = 8;
const SYS_DISKD_INFO = 9; // diskd-only: returns its vq/req physical addrs
const SYS_IPC_POLL   = 10; // non-blocking SYS_IPC_RECV, see its case below
const SYS_RFORK       = 11;
const SYS_NS_UNMOUNT  = 12; // remove one of the caller's own namespace mounts by exact prefix
const SYS_JOIN        = 13; // block until the given pid no longer exists — see its case below
const SYS_FS_PARTITION_INFO = 14; // fsd-only: returns current_proc.fs_partition_start —
                                    // board is a kernel-only module (see user/sdd.c3's own
                                    // header comment), so this is fsd.c3's only way to learn
                                    // a board-specific fact despite being one board-agnostic
                                    // user binary, same shape as SYS_DISKD_INFO above. Reads
                                    // the CALLER's own per-process field, not a single shared
                                    // board constant directly — see process.c3's
                                    // setup_fsd_mappings()/fs_partition_start comments for why:
                                    // two fsd instances can be mounted simultaneously now, each
                                    // needing a different answer to this same syscall.

// rfork flags — Plan 9 names, this kernel's own subset. RFPROC is
// required (rfork() without it returns -1 in this v1: real Plan 9 uses
// that combination to change the *caller's* own group membership in
// place, not meaningful yet here since there's nothing group-scoped
// besides memory to change). RFMEM shares the parent's address space
// instead of copying it — the one flag that turns this same call into
// "spawn a thread." See the SYS_RFORK case below and process.c3's
// fork_entry for the full mechanism.
const int RFPROC = 1 << 0;
const int RFMEM  = 1 << 1;

// Sentinel msg_type handle_trap uses to wake diskd on a virtio-blk PLIC
// interrupt (see handle_trap's interrupt branch below) — distinguishes
// "the device finished, go check the used ring" from an actual client
// request in diskd's single inbox slot. Must match user/diskd.c3's copy.
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

// Narrow first slice of real preemptive-scheduling support (see
// docs/devlog.md): proves the sstc timer interrupt mechanism itself —
// fires, correctly re-arms, and returns cleanly to whatever was
// running — without yet forcing a context switch on each tick. Actual
// preemption (yield()-ing from inside a timer interrupt) is real,
// separate, higher-risk work: unlike every existing yield() point,
// which only ever happens at a caller-chosen, known-safe moment, a
// timer interrupt can land in the middle of *anything* — including
// kernel state this codebase has never needed to guard against
// concurrent access before (SYS_IPC_SEND's own multi-step bookkeeping,
// mid-page-table-edit, etc.) — deliberately not attempted here.
//
// Real interrupt-latency characteristic found while verifying this,
// directly relevant to that future work: SYS_GETCHAR (and SYS_IPC_RECV,
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
// fired reliably every ~1s as armed. Not a bug in this mechanism — an
// architectural fact worth knowing before assuming a timer-interrupt-
// based preemptive scheduler would actually preempt a process stuck in
// one of these loops; it wouldn't, for the exact same reason.
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

// For the standard check-condition-then-wfi race: if the completion
// interrupt arrives in the gap between checking a condition and executing
// wfi, the trap fires right there (claimed/completed as a normal
// interrupt), and a subsequent wfi then waits forever for an interrupt
// that already happened — a real lost wakeup, not a hypothetical one (see
// docs/devlog.md). The fix is the textbook one: disable interrupts before
// the check, keep them disabled across the whole check-and-wfi loop, only
// re-enable once the condition is actually met. wfi still wakes on a
// pending-but-globally-disabled interrupt per the RISC-V spec — that's
// the whole point of this pattern — it just doesn't let the trap actually
// fire and consume it until we're done checking.
fn void disable_interrupts()
{
	write_csr("sstatus", read_reg("sstatus") & ~(ulong)SSTATUS_SIE);
}

fn void enable_interrupts()
{
	// Just the global gate — sie.SEIE was already set once at boot by
	// enable_external_interrupts() and never needs touching again.
	write_csr("sstatus", read_reg("sstatus") | SSTATUS_SIE);
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

fn void handle_syscall(Trap_frame* f) @noinline
{
	switch (f.a3)
	{
		case SYS_PUTCHAR:
			board::console_putchar((int)f.a0);
		case SYS_GETCHAR:
			for (;;)
			{
				int ch = board::console_getchar();
				if (ch >= 0)
				{
					f.a0 = (ulong)ch;
					break;
				}
				yield();
			}
		case SYS_EXIT:
			// Inlined rather than factored into a process.c3 function on
			// purpose: a call to a moderately complex freshly-defined
			// function from inside this switch (proc.c3's free_process_pages,
			// taking Process*) reproducibly broke boot before even reaching
			// SYS_EXIT at runtime — same unexplained-c3c-bug shape as the
			// SYS_READFILE/WRITEFILE extraction below, just with a different
			// parameter type this time, so it's not specifically about
			// Trap_frame*. Not going to keep chasing it; inline is proven
			// safe both times.
			//
			// Frees everything this process's page table owns: every leaf
			// page mapped PAGE_U (its private image pages — never the
			// shared kernel-identity or virtio-MMIO mappings, which lack
			// PAGE_U precisely because they're not this process's own
			// memory), every on-demand 2nd/3rd-level table map_page
			// allocated for it, and the top-level table itself. Sv39: 3
			// levels (table2/table1/table0), not RV32/Sv32's 2 — see
			// page.c3.
			//
			// Skipped entirely if some other live process shares this
			// exact page_table pointer — an rfork(RFPROC|RFMEM) sibling
			// (see SYS_RFORK below). page_table pointers are never aliased
			// any other way (every ordinary create_process call gets its
			// own fresh alloc_pages(1) result), so this linear
			// PROCS_MAX-sized scan is a correct, sufficient stand-in for a
			// real refcount at this scale — no new field needed.
			bool exit_table_shared = false;
			for (int share_i = 0; share_i < PROCS_MAX; share_i++)
			{
				if (&procs[share_i] == current_proc) continue;
				if (procs[share_i].state == PROC_UNUSED) continue;
				if (procs[share_i].page_table == current_proc.page_table)
				{
					exit_table_shared = true;
					break;
				}
			}

			if (!exit_table_shared)
			{
				ulong* exiting_table2 = current_proc.page_table;
				for (uint vpn2 = 0; vpn2 < 512; vpn2++)
				{
					if ((exiting_table2[vpn2] & PAGE_V) == 0) continue;
					ulong* table1 = (ulong*)pte_to_paddr(exiting_table2[vpn2]);

					for (uint vpn1 = 0; vpn1 < 512; vpn1++)
					{
						if ((table1[vpn1] & PAGE_V) == 0) continue;
						ulong* table0 = (ulong*)pte_to_paddr(table1[vpn1]);

						for (uint vpn0 = 0; vpn0 < 512; vpn0++)
						{
							if ((table0[vpn0] & PAGE_V) == 0) continue;
							if (table0[vpn0] & PAGE_U)
							{
								uptr leaf_paddr = pte_to_paddr(table0[vpn0]);
								free_pages(leaf_paddr, 1);
							}
						}

						free_pages((uptr)table0, 1);
					}

					free_pages((uptr)table1, 1);
				}
				free_pages((uptr)exiting_table2, 1);
			}

			current_proc.state = PROC_UNUSED;
			current_proc.pid = 0;

			// yield() never returns here: current_proc is now PROC_UNUSED,
			// so its scan can't match itself, and switch_context's `ret`
			// jumps permanently into whatever process it picks instead.
			yield();
		case SYS_IPC_SEND:
			// Inline for the same reason as SYS_EXIT above — this is the
			// pattern proven not to trigger the unexplained c3c reboot
			// bug in this switch. dest_pid/type/data are a0-a2 as usual;
			// len is a4, since a3 is always the syscall number (see
			// syscall4 in user/user.c3 — this is the one syscall that
			// needs a 4th argument).
			int ipc_dest_pid = (int)f.a0;
			uint ipc_type    = (uint)f.a1;
			char* ipc_data   = (char*)(uptr)f.a2;
			int ipc_len      = (int)f.a4;
			int ipc_copy_len = ipc_len > MSG_MAX ? MSG_MAX : ipc_len;
			if (ipc_copy_len < 0) ipc_copy_len = 0;
			// proc_by_pid here only ever guards against a plain dead/
			// never-existed pid (e.g. a stale hardcoded pid like echod's
			// or diskd's, if one of those ever exited). The stale-
			// namespace-pid hazard this comment used to describe — a
			// Mount entry silently resolving to an unrelated process that
			// reused a dead target's slot, found while building the
			// second, simultaneously-mounted fsd (docs/devlog.md) — is
			// now closed one layer up, in SYS_NS_RESOLVE's own generation
			// check (see Mount.server_generation's comment, process.c3):
			// a caller can never obtain a hijacked pid through namespace
			// resolution in the first place, so this check doesn't need
			// to re-derive that distinction itself.
			Process* ipc_target = proc_by_pid(ipc_dest_pid);
			if (!ipc_target)
			{
				f.a0 = (ulong)(-1);
				break;
			}

			// Wait for the target's inbox to actually be free — a
			// previous sender's message that hasn't been consumed yet
			// must never be silently overwritten. Busy-poll like
			// SYS_GETCHAR: nothing specifically wakes a queued sender
			// when the slot frees up, it's whoever notices next.
			while (ipc_target.has_message)
			{
				yield();
			}

			mem::copy(&ipc_target.msg_data, ipc_data, (sz)ipc_copy_len);
			ipc_target.msg_from = current_proc.pid;
			ipc_target.msg_type = ipc_type;
			current_proc.msg_acked = false;
			ipc_target.has_message = true;
			if (ipc_target.state == PROC_BLOCKED)
			{
				ipc_target.state = PROC_RUNNABLE;
			}

			// True rendezvous: don't return to the caller until the
			// receiver has actually consumed *this* message — SYS_IPC_RECV
			// and SYS_IPC_POLL both wake us explicitly via msg_acked once
			// they do (targeted at us specifically via msg_from, not just
			// "the inbox looks empty again", which could just as easily
			// mean a different sender's message arrived and got consumed
			// instead).
			while (!current_proc.msg_acked)
			{
				current_proc.state = PROC_BLOCKED;
				yield();
			}
			f.a0 = 0;
		case SYS_IPC_RECV:
			// a2 (previously always 0 from user.c3's original ipc_recv) is
			// now an optional out-pointer for the message's type/verb —
			// null means "don't care", same as every existing call site
			// still passes.
			char* recv_buf       = (char*)(uptr)f.a0;
			int recv_len         = (int)f.a1;
			uint* recv_type_out  = (uint*)(uptr)f.a2;
			for (;;)
			{
				if (current_proc.has_message)
				{
					int recv_copy_len = recv_len > MSG_MAX ? MSG_MAX : recv_len;
					if (recv_copy_len < 0) recv_copy_len = 0;
					mem::copy(recv_buf, &current_proc.msg_data, (sz)recv_copy_len);
					if (recv_type_out != null)
					{
						*recv_type_out = current_proc.msg_type;
					}
					f.a0 = (ulong)current_proc.msg_from;
					current_proc.has_message = false;

					// Wake the sender: it's genuinely blocked (see
					// SYS_IPC_SEND) waiting specifically for this ack,
					// not just for the inbox to look empty from the
					// outside.
					Process* recv_acked_sender = proc_by_pid(current_proc.msg_from);
					if (recv_acked_sender != null)
					{
						recv_acked_sender.msg_acked = true;
						if (recv_acked_sender.state == PROC_BLOCKED)
						{
							recv_acked_sender.state = PROC_RUNNABLE;
						}
					}
					break;
				}
				current_proc.state = PROC_BLOCKED;
				yield();
			}
		case SYS_IPC_POLL:
			// Non-blocking counterpart to SYS_IPC_RECV: checks once,
			// never sets PROC_BLOCKED, never yields. Exists for diskd's
			// completion-wait (user/diskd.c3), which genuinely needs an
			// interrupt to fire to make progress — and a *blocking*
			// ipc_recv there is unsafe: sstatus.SIE has no per-process
			// save/restore (kernel_entry only saves GPRs), and
			// switch_context unconditionally resets sscratch to a fixed
			// "top of this process's stack" value on every switch,
			// including when *resuming* a process that's paused mid-trap
			// (not freshly entering one). That reset is only correct for
			// a fresh trap entry; enabling interrupts while blocked mid-
			// trap risks a nested trap building its frame at that fixed
			// address, colliding with — and corrupting — the still-in-
			// progress outer frame lower on the same stack. Confirmed
			// empirically: doing exactly that (enable_interrupts() right
			// before yield() in SYS_IPC_RECV's loop) turned an
			// intermittent hang into an intermittent page-fault panic
			// instead of fixing it. Polling from genuine user-mode code
			// sidesteps the whole problem: this process is never parked
			// mid-trap between polls, so sstatus.SIE's natural value
			// (on, from user_entry) is safe to leave alone, and the
			// interrupt can fire and get routed normally in between.
			char* poll_buf      = (char*)(uptr)f.a0;
			int poll_len        = (int)f.a1;
			uint* poll_type_out = (uint*)(uptr)f.a2;
			if (!current_proc.has_message)
			{
				f.a0 = (ulong)(-1);
				break;
			}
			int poll_copy_len = poll_len > MSG_MAX ? MSG_MAX : poll_len;
			if (poll_copy_len < 0) poll_copy_len = 0;
			mem::copy(poll_buf, &current_proc.msg_data, (sz)poll_copy_len);
			if (poll_type_out != null)
			{
				*poll_type_out = current_proc.msg_type;
			}
			f.a0 = (ulong)current_proc.msg_from;
			current_proc.has_message = false;

			// Same "wake the real sender" step as SYS_IPC_RECV — normally
			// a no-op here, since diskd's only use of this is for the
			// synthetic interrupt notify (msg_from=0, which proc_by_pid
			// always rejects, so there's no real sender to wake), but
			// correct regardless if that ever changes.
			Process* poll_acked_sender = proc_by_pid(current_proc.msg_from);
			if (poll_acked_sender != null)
			{
				poll_acked_sender.msg_acked = true;
				if (poll_acked_sender.state == PROC_BLOCKED)
				{
					poll_acked_sender.state = PROC_RUNNABLE;
				}
			}
		case SYS_NS_RESOLVE:
			// Inline for the same reason as every other case in this
			// switch — see SYS_EXIT's comment. Walks the caller's own
			// namespace (never a different process's — resolution is
			// always relative to whoever's asking) for the first mount
			// whose prefix matches the given path, longest-prefix-first so
			// a more specific mount always wins over a broader one that
			// also matches. Returns -1 (in f.a0, read as signed by the
			// caller) if nothing matches.
			char* ns_path = (char*)(uptr)f.a0;
			int ns_result = -1;
			int ns_best_len = -1;
			for (int m = 0; m < NS_MOUNTS_MAX; m++)
			{
				if (current_proc.namespace[m].server_pid == 0) continue;
				// Generation check closes the stale-pid hazard documented
				// on Mount.server_generation (process.c3): if the process
				// that originally held this pid has since exited and the
				// slot was reused (or never got this far at all), either
				// proc_by_pid returns null or its live generation won't
				// match what was recorded when this entry was bound —
				// either way, treat it exactly like server_pid == 0 rather
				// than resolve to the wrong, unrelated process.
				Process* ns_target = proc_by_pid(current_proc.namespace[m].server_pid);
				if (!ns_target || ns_target.generation != current_proc.namespace[m].server_generation) continue;
				char* ns_prefix = &current_proc.namespace[m].prefix[0];
				if (!str_starts_with(ns_path, ns_prefix)) continue;

				int ns_len = 0;
				while (ns_prefix[ns_len] != 0) ns_len++;
				if (ns_len > ns_best_len)
				{
					ns_best_len = ns_len;
					ns_result = current_proc.namespace[m].server_pid;
				}
			}
			f.a0 = (ulong)(iptr)ns_result;

			// Optional out-pointer (a1), same "null means don't care"
			// convention as SYS_RFORK's generation out-pointer above —
			// lets the caller strip the matched prefix itself (see
			// user/user.c3's fs_read/fs_write) before building a wire-
			// format request, so a server mounted under a non-empty
			// prefix (e.g. the second fsd, under "/2/") still only ever
			// sees the bare remainder, exactly like the "" catch-all
			// mount already did by construction (its own prefix length
			// is always 0). 0 when nothing matched — the caller already
			// has -1 in f.a0 to detect that case, this just avoids
			// leaving the out-pointer's target uninitialized.
			uint* ns_prefix_len_out = (uint*)(uptr)f.a1;
			if (ns_prefix_len_out != null)
			{
				*ns_prefix_len_out = (uint)(ns_best_len < 0 ? 0 : ns_best_len);
			}
		case SYS_DISKD_INFO:
			// diskd-only, called once at its own startup — see
			// setup_diskd_mappings in process.c3 for why these addresses
			// can't be known at compile time or derived by diskd itself.
			// a0/a1 are out-pointers (same convention as SYS_IPC_RECV's
			// optional type-out pointer): a0 -> vq paddr, a1 -> req paddr.
			uptr* diskd_vq_out  = (uptr*)(uptr)f.a0;
			uptr* diskd_req_out = (uptr*)(uptr)f.a1;
			*diskd_vq_out  = diskd_vq_paddr;
			*diskd_req_out = diskd_req_paddr;
		case SYS_FS_PARTITION_INFO:
			// fsd-only, called once at its own startup — a0 is an
			// out-pointer, same convention as SYS_DISKD_INFO above.
			// Reads the CALLER's own current_proc.fs_partition_start
			// (set by process.c3's setup_fsd_mappings() at spawn time),
			// not board::FS_PARTITION_START_SECTOR directly — see that
			// field's own comment for why: two fsd instances can be
			// mounted simultaneously now, so a single shared board
			// constant can't answer this the same way for both.
			uint* fs_partition_out = (uint*)(uptr)f.a0;
			*fs_partition_out = current_proc.fs_partition_start;
		case SYS_RFORK:
			// Inline for the same reason as every other case in this
			// switch — see SYS_EXIT's comment. See process.c3's
			// fork_entry() for how the child actually resumes, and
			// docs/devlog.md for the full design rationale.
			int rfork_flags = (int)f.a0;
			if ((rfork_flags & RFPROC) == 0)
			{
				f.a0 = (ulong)(-1);
				break;
			}

			Process* child = null;
			int child_i;
			for (child_i = 0; child_i < PROCS_MAX; child_i++)
			{
				if (procs[child_i].state == PROC_UNUSED)
				{
					child = &procs[child_i];
					break;
				}
			}
			if (!child)
			{
				f.a0 = (ulong)(-1);
				break;
			}

			if (rfork_flags & RFMEM)
			{
				// True sharing: same root table pointer, so every mapping
				// either process makes or already has is visible to
				// both — this is what makes it a "thread" rather than a
				// process. SYS_EXIT's own free loop above has a guard
				// specifically for this case.
				child.page_table = current_proc.page_table;
			}
			else
			{
				// Independent copy: fresh root table, same kernel-range +
				// PLIC identity mapping create_process always does, then
				// every PAGE_U leaf in the parent's table gets a fresh
				// physical page with a byte-for-byte copy, mapped at the
				// same vaddr with the same flags — map_page() allocates
				// the child's own intermediate (2nd/3rd level) tables on
				// demand as each leaf is mapped, exactly like
				// create_process already relies on, so this walk only
				// needs to find the parent's leaves and their flags, not
				// manage the child's table structure itself. Same walk
				// shape as SYS_EXIT's free loop above (now 3 levels for
				// Sv39, not 2), copy instead of free.
				ulong* child_table = (ulong*)alloc_pages(1);
				for (uptr paddr = (uptr)&__kernel_map_base; paddr < (uptr)&__free_ram_end; paddr += PAGE_SIZE)
				{
					map_page(child_table, paddr, paddr, PAGE_R | PAGE_W | PAGE_X);
				}
				map_device_page(child_table, board::PLIC_PRIORITY_PAGE, board::PLIC_PRIORITY_PAGE, PAGE_R | PAGE_W);
				map_device_page(child_table, board::PLIC_ENABLE_PAGE, board::PLIC_ENABLE_PAGE, PAGE_R | PAGE_W);
				map_device_page(child_table, board::PLIC_CLAIM_PAGE, board::PLIC_CLAIM_PAGE, PAGE_R | PAGE_W);
				map_device_page(child_table, board::PLIC_PENDING_PAGE, board::PLIC_PENDING_PAGE, PAGE_R | PAGE_W);

				ulong* parent_table2 = current_proc.page_table;
				for (uint vpn2 = 0; vpn2 < 512; vpn2++)
				{
					if ((parent_table2[vpn2] & PAGE_V) == 0) continue;
					ulong* parent_table1 = (ulong*)pte_to_paddr(parent_table2[vpn2]);

					for (uint vpn1 = 0; vpn1 < 512; vpn1++)
					{
						if ((parent_table1[vpn1] & PAGE_V) == 0) continue;
						ulong* parent_table0 = (ulong*)pte_to_paddr(parent_table1[vpn1]);

						for (uint vpn0 = 0; vpn0 < 512; vpn0++)
						{
							if ((parent_table0[vpn0] & PAGE_V) == 0) continue;
							if ((parent_table0[vpn0] & PAGE_U) == 0) continue;

							uptr parent_leaf_paddr = pte_to_paddr(parent_table0[vpn0]);
							uptr child_leaf_paddr  = alloc_pages(1);
							mem::copy((void*)child_leaf_paddr, (void*)parent_leaf_paddr, (sz)PAGE_SIZE);

							uptr child_vaddr  = ((uptr)vpn2 << 30) | ((uptr)vpn1 << 21) | ((uptr)vpn0 << 12);
							uint parent_flags = (uint)(parent_table0[vpn0] & 0x1f); // V|R|W|X|U — see page.c3's map_page encoding
							map_page(child_table, child_vaddr, child_leaf_paddr, parent_flags);
						}
					}
				}
				child.page_table = child_table;
			}

			// Namespace: always copied, regardless of RFMEM — cheap
			// (4 x Mount), and there's no mount/unmount syscall yet to
			// make "shared" vs. "copied" observably different. The seam
			// a future RFNAMEG-equivalent would slot into.
			for (int ns_i = 0; ns_i < NS_MOUNTS_MAX; ns_i++)
			{
				child.namespace[ns_i] = current_proc.namespace[ns_i];
			}

			// Build the child's first-resume state: a copy of this
			// trap's own Trap_frame (a0 zeroed — the child's return
			// value), plus this trap's own resume address as an extra
			// 32nd word, since sepc is a single CSR fork_entry can't
			// otherwise inherit. See fork_entry's own comment in
			// process.c3 for how this block gets consumed. 32 words of
			// 8 bytes now (Sv64 port), not 4.
			uptr* child_sp = (uptr*)&child.stack;
			child_sp += STACK_SIZE / 8;
			child_sp -= 32;

			mem::copy((void*)child_sp, f, (sz)Trap_frame::size);
			Trap_frame* child_frame = (Trap_frame*)child_sp;
			child_frame.a0 = 0;
			child_sp[31] = (uptr)(read_reg("sepc") + 4);

			for (int rf_j = 0; rf_j < 12; rf_j++)
			{
				*(--child_sp) = 0;
			}
			*(--child_sp) = (uptr)&fork_entry;

			child.has_message = false;
			child.pid   = child_i + 1;
			child.generation++;
			child.sp    = (uptr)child_sp;
			child.state = PROC_RUNNABLE;

			// Optional out-pointer (a1), same "null means don't care"
			// convention as SYS_IPC_RECV's type_out — lets the caller
			// capture this child's generation for a later SYS_JOIN to
			// check against, so a join can tell "this pid exited" apart
			// from "this pid got reused by something else." generation
			// itself stays a plain uint (a counter, not an address).
			uint* rfork_gen_out = (uint*)(uptr)f.a1;
			if (rfork_gen_out != null)
			{
				*rfork_gen_out = child.generation;
			}

			f.a0 = (ulong)child.pid;
		case SYS_NS_UNMOUNT:
			// Removes one of the *caller's own* namespace mounts by
			// exact prefix match (str_eq, not the longest-prefix match
			// SYS_NS_RESOLVE uses — this targets one specific entry, not
			// "whichever mount a path would resolve to"). Since a fresh
			// rfork(RFPROC) child gets its own independent copy of the
			// parent's namespace (see SYS_RFORK above), this is what
			// lets a child sandbox itself after forking, without
			// affecting the parent or any other process. Returns 0 if
			// found and removed, -1 if no mount had that exact prefix.
			char* unmount_prefix = (char*)(uptr)f.a0;
			int unmount_result = -1;
			for (int um = 0; um < NS_MOUNTS_MAX; um++)
			{
				if (current_proc.namespace[um].server_pid == 0) continue;
				if (str_eq(&current_proc.namespace[um].prefix[0], unmount_prefix))
				{
					current_proc.namespace[um].server_pid = 0;
					unmount_result = 0;
					break;
				}
			}
			f.a0 = (ulong)(iptr)unmount_result;
		case SYS_JOIN:
			// Blocks until the joined process is actually gone — plain
			// polling (check, yield(), recheck), the same proven shape
			// as SYS_GETCHAR's own retry loop, not an event-driven wake.
			//
			// "Actually gone" means either the slot is empty
			// (proc_by_pid returns null) *or* it's been reused by an
			// unrelated process — detected via the join_generation the
			// caller captured when it created this pid (rfork's or
			// threadcreate's optional generation_out), compared against
			// Process.generation (src/process.c3), which increments on
			// every reuse of a slot and never resets. Without this
			// check, a pid recycled into a new process (always possible,
			// since a slot's next occupant gets the exact same pid —
			// pid = slot index + 1) would look identical to the
			// original process still running, and join would wait for
			// the wrong thing.
			int join_pid = (int)f.a0;
			uint join_generation = (uint)f.a1;
			if (join_pid == current_proc.pid)
			{
				// Can't wait for yourself to disappear while you're the
				// one running — always self-deadlock. Reject rather than
				// hang.
				f.a0 = (ulong)(-1);
				break;
			}
			// Stays PROC_RUNNABLE throughout, same as SYS_GETCHAR's own
			// loop above — deliberately not PROC_BLOCKED: that state
			// only ever gets cleared by something *else* explicitly
			// flipping it back (SYS_IPC_SEND does this for a receiver).
			// Nothing does that for a join — SYS_EXIT only ever touches
			// its own process's state — so setting PROC_BLOCKED here
			// would make this process permanently unschedulable the
			// moment it's set, even after the joined pid actually exits.
			for (;;)
			{
				Process* join_target = proc_by_pid(join_pid);
				if (join_target == null) break;
				if (join_target.generation != join_generation) break;
				yield();
			}
			f.a0 = 0;
		default:
			panic::panic("unexpected syscall");
	}
}

fn void handle_trap(Trap_frame* f) @export("handle_trap") @noinline @nostrip
{
	ulong scause  = read_reg("scause");
	ulong stval   = read_reg("stval");
	ulong user_pc = read_reg("sepc");

	if (scause & SCAUSE_INTERRUPT_BIT)
	{
		ulong code = scause & ~SCAUSE_INTERRUPT_BIT;
		if (code == SCAUSE_SUPERVISOR_EXTERNAL)
		{
			// Claiming acknowledges the IRQ to the PLIC. 0 means a
			// spurious claim (nothing pending) — don't complete an IRQ
			// that wasn't actually claimed.
			uint irq = board::plic_claim();

			if (irq == board::IRQ_VIRTIO_BLK && diskd_pid != 0)
			{
				// Wake diskd specifically, rather than relying on
				// "whatever happened to be running/wfi-waiting" like the
				// old kernel-resident driver did — this interrupt can
				// land while any process (or the kernel's own boot code)
				// is active, and diskd is the only one that cares. Uses
				// the same single-slot inbox as ordinary client requests:
				// safe because diskd only ever waits here (its second
				// ipc_recv, inbox already drained by the first) right
				// after kicking the virtqueue, never while a client
				// request is still sitting unconsumed — see
				// user/diskd.c3's main loop and setup_diskd_mappings'
				// comment in process.c3.
				Process* diskd_proc = proc_by_pid(diskd_pid);
				if (diskd_proc != null)
				{
					diskd_proc.msg_from    = 0;
					diskd_proc.msg_type    = DISKD_IRQ_NOTIFY;
					diskd_proc.has_message = true;
					if (diskd_proc.state == PROC_BLOCKED)
					{
						diskd_proc.state = PROC_RUNNABLE;
					}
				}
			}
			// Same pattern as diskd above, for sdd (see user/sdd.c3) —
			// the two are mutually exclusive per board (see
			// board::HAS_SD_BLOCK/HAS_VIRTIO_BLOCK), so this only ever
			// matches on the Duo, where diskd_pid stays 0. Reuses
			// DISKD_IRQ_NOTIFY's sentinel value rather than defining a
			// second constant: it's an opaque "your IRQ fired" marker to
			// whichever driver receives it, not a DISKD-specific verb —
			// sdd interprets it exactly the same way diskd does, by
			// re-reading its own device's status register, not by
			// inspecting the notify itself.
			if (irq == board::IRQ_SDHCI && sdd_pid != 0)
			{
				Process* sdd_proc = proc_by_pid(sdd_pid);
				if (sdd_proc != null)
				{
					sdd_proc.msg_from    = 0;
					sdd_proc.msg_type    = DISKD_IRQ_NOTIFY;
					sdd_proc.has_message = true;
					if (sdd_proc.state == PROC_BLOCKED)
					{
						sdd_proc.state = PROC_RUNNABLE;
					}
				}
			}
			if (irq != 0)
			{
				board::plic_complete(irq);
			}
		}
		else if (code == SCAUSE_SUPERVISOR_TIMER)
		{
			// Rearm first, before anything else: stimecmp is what
			// actually clears the pending interrupt (time < stimecmp
			// again), so leaving the old, already-elapsed value in
			// place would refire the instant interrupts are next
			// enabled — an interrupt storm, not a periodic tick. No
			// context switch here — see enable_timer_interrupts()'s
			// own comment for why not yet.
			arm_timer(board::TIMEBASE_HZ);
			timer_tick_count += 1;
		}
		// No sepc adjustment for interrupts: unlike ecall (which must skip
		// past the trapping instruction), the hardware already points sepc
		// at the correct resume address — for wfi specifically, the
		// instruction right after it.
	}
	else if (scause == SCAUSE_ECALL)
	{
		handle_syscall(f);
		write_sepc(user_pc + 4);
	}
	else
	{
		io::printfn("unexpected trap scause=%x, stval=%x, sepc=%x, current_pid=%d\n", scause, stval, user_pc, current_proc.pid);
		panic::panic("it's a trap!");
	}
}
