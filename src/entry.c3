module kernel;

import std::io;
import panic;
import sbi;

const SCAUSE_ECALL             = 8;
const SCAUSE_INTERRUPT_BIT     = 0x80000000; // MSB of scause: set for interrupts, clear for exceptions
const SCAUSE_SUPERVISOR_EXTERNAL = 9;        // interrupt cause code for a PLIC-routed external interrupt

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

uint read_reg_tmp @export("read_reg_tmp");

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
        sw t0, 0(t1)
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

uint write_sepc_tmp @export("write_sepc_tmp");

fn void write_sepc(uint value) @noinline
{
	// Single asm() call, bridged through a memory location rather than a
	// register: a normal (non-naked) function gives no guarantee about
	// which register `value` lives in by the time this runs, and splitting
	// this across separate asm() statements reintroduces the reordering
	// hazard described on write_reg.
	write_sepc_tmp = value;
	asm(`
        la t0, write_sepc_tmp
        lw t0, 0(t0)
        csrw sepc, t0
    `);
}

uint write_csr_tmp @export("write_csr_tmp");

macro write_csr(String $reg, value)
{
	// Same memory-bridged, single-atomic-asm() pattern as write_sepc,
	// generalized to any CSR name (known at compile time, so @sprintf's
	// %s-only limitation is fine here).
	write_csr_tmp = value;
	asm(@sprintf(`
        la t0, write_csr_tmp
        lw t0, 0(t0)
        csrw %s, t0
    `, $reg));
}

const SIE_SEIE     = (1 << 9);  // sie: supervisor external interrupt enable
const SSTATUS_SIE  = (1 << 1);  // sstatus: global supervisor interrupt enable

fn void enable_external_interrupts()
{
	write_csr("sie", read_reg("sie") | SIE_SEIE);
	write_csr("sstatus", read_reg("sstatus") | SSTATUS_SIE);
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
	write_csr("sstatus", read_reg("sstatus") & (uint)~SSTATUS_SIE);
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
fn void kernel_entry() @align(4) @section(".text.trap") @export("kernel_entry") @noinline @nostrip
{
	asm(`
        csrrw sp, sscratch, sp

        addi sp, sp, -4 * 31
        sw ra,  4 * 0(sp)
        sw gp,  4 * 1(sp)
        sw tp,  4 * 2(sp)
        sw t0,  4 * 3(sp)
        sw t1,  4 * 4(sp)
        sw t2,  4 * 5(sp)
        sw t3,  4 * 6(sp)
        sw t4,  4 * 7(sp)
        sw t5,  4 * 8(sp)
        sw t6,  4 * 9(sp)
        sw a0,  4 * 10(sp)
        sw a1,  4 * 11(sp)
        sw a2,  4 * 12(sp)
        sw a3,  4 * 13(sp)
        sw a4,  4 * 14(sp)
        sw a5,  4 * 15(sp)
        sw a6,  4 * 16(sp)
        sw a7,  4 * 17(sp)
        sw s0,  4 * 18(sp)
        sw s1,  4 * 19(sp)
        sw s2,  4 * 20(sp)
        sw s3,  4 * 21(sp)
        sw s4,  4 * 22(sp)
        sw s5,  4 * 23(sp)
        sw s6,  4 * 24(sp)
        sw s7,  4 * 25(sp)
        sw s8,  4 * 26(sp)
        sw s9,  4 * 27(sp)
        sw s10, 4 * 28(sp)
        sw s11, 4 * 29(sp)

        csrr a0, sscratch
        sw a0, 4 * 30(sp)

        addi a0, sp, 4 * 31

        csrw sscratch, a0
        mv a0, sp
        call handle_trap

        lw ra,  4 * 0(sp)
        lw gp,  4 * 1(sp)
        lw tp,  4 * 2(sp)
        lw t0,  4 * 3(sp)
        lw t1,  4 * 4(sp)
        lw t2,  4 * 5(sp)
        lw t3,  4 * 6(sp)
        lw t4,  4 * 7(sp)
        lw t5,  4 * 8(sp)
        lw t6,  4 * 9(sp)
        lw a0,  4 * 10(sp)
        lw a1,  4 * 11(sp)
        lw a2,  4 * 12(sp)
        lw a3,  4 * 13(sp)
        lw a4,  4 * 14(sp)
        lw a5,  4 * 15(sp)
        lw a6,  4 * 16(sp)
        lw a7,  4 * 17(sp)
        lw s0,  4 * 18(sp)
        lw s1,  4 * 19(sp)
        lw s2,  4 * 20(sp)
        lw s3,  4 * 21(sp)
        lw s4,  4 * 22(sp)
        lw s5,  4 * 23(sp)
        lw s6,  4 * 24(sp)
        lw s7,  4 * 25(sp)
        lw s8,  4 * 26(sp)
        lw s9,  4 * 27(sp)
        lw s10, 4 * 28(sp)
        lw s11, 4 * 29(sp)
        lw sp,  4 * 30(sp)
        sret
    `);
}

struct Trap_frame @packed
{
	uint ra;
	uint gp;
	uint tp;
	uint t0;
	uint t1;
	uint t2;
	uint t3;
	uint t4;
	uint t5;
	uint t6;
	uint a0;
	uint a1;
	uint a2;
	uint a3;
	uint a4;
	uint a5;
	uint a6;
	uint a7;
	uint s0;
	uint s1;
	uint s2;
	uint s3;
	uint s4;
	uint s5;
	uint s6;
	uint s7;
	uint s8;
	uint s9;
	uint s10;
	uint s11;
	uint sp;
}

fn void handle_syscall(Trap_frame* f) @noinline
{
	switch (f.a3)
	{
		case SYS_PUTCHAR:
			sbi::__putchar((int)f.a0);
		case SYS_GETCHAR:
			for (;;)
			{
				int ch = sbi::__getchar();
				if (ch >= 0)
				{
					f.a0 = (uint)ch;
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
			// memory), every on-demand 2nd-level table map_page allocated
			// for it, and the top-level table itself.
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
				uint* exiting_table1 = current_proc.page_table;
				for (uint vpn1 = 0; vpn1 < 1024; vpn1++)
				{
					if ((exiting_table1[vpn1] & PAGE_V) == 0) continue;

					uint* table0 = (uint*)((exiting_table1[vpn1] >> 10) * PAGE_SIZE);
					for (uint vpn0 = 0; vpn0 < 1024; vpn0++)
					{
						if ((table0[vpn0] & PAGE_V) == 0) continue;
						if (table0[vpn0] & PAGE_U)
						{
							uint leaf_paddr = (table0[vpn0] >> 10) * PAGE_SIZE;
							free_pages(leaf_paddr, 1);
						}
					}

					free_pages((uint)table0, 1);
				}
				free_pages((uint)exiting_table1, 1);
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
			uint ipc_type    = f.a1;
			char* ipc_data   = (char*)f.a2;
			int ipc_len      = (int)f.a4;
			int ipc_copy_len = ipc_len > MSG_MAX ? MSG_MAX : ipc_len;
			if (ipc_copy_len < 0) ipc_copy_len = 0;
			Process* ipc_target = proc_by_pid(ipc_dest_pid);
			if (!ipc_target)
			{
				f.a0 = (uint)(-1);
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
			char* recv_buf       = (char*)f.a0;
			int recv_len         = (int)f.a1;
			uint* recv_type_out  = (uint*)f.a2;
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
					f.a0 = (uint)current_proc.msg_from;
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
			char* poll_buf      = (char*)f.a0;
			int poll_len        = (int)f.a1;
			uint* poll_type_out = (uint*)f.a2;
			if (!current_proc.has_message)
			{
				f.a0 = (uint)(-1);
				break;
			}
			int poll_copy_len = poll_len > MSG_MAX ? MSG_MAX : poll_len;
			if (poll_copy_len < 0) poll_copy_len = 0;
			mem::copy(poll_buf, &current_proc.msg_data, (sz)poll_copy_len);
			if (poll_type_out != null)
			{
				*poll_type_out = current_proc.msg_type;
			}
			f.a0 = (uint)current_proc.msg_from;
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
			char* ns_path = (char*)f.a0;
			int ns_result = -1;
			int ns_best_len = -1;
			for (int m = 0; m < NS_MOUNTS_MAX; m++)
			{
				if (current_proc.namespace[m].server_pid == 0) continue;
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
			f.a0 = (uint)ns_result;
		case SYS_DISKD_INFO:
			// diskd-only, called once at its own startup — see
			// setup_diskd_mappings in process.c3 for why these addresses
			// can't be known at compile time or derived by diskd itself.
			// a0/a1 are out-pointers (same convention as SYS_IPC_RECV's
			// optional type-out pointer): a0 -> vq paddr, a1 -> req paddr.
			uint* diskd_vq_out  = (uint*)f.a0;
			uint* diskd_req_out = (uint*)f.a1;
			*diskd_vq_out  = diskd_vq_paddr;
			*diskd_req_out = diskd_req_paddr;
		case SYS_RFORK:
			// Inline for the same reason as every other case in this
			// switch — see SYS_EXIT's comment. See process.c3's
			// fork_entry() for how the child actually resumes, and
			// docs/devlog.md for the full design rationale.
			int rfork_flags = (int)f.a0;
			if ((rfork_flags & RFPROC) == 0)
			{
				f.a0 = (uint)(-1);
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
				f.a0 = (uint)(-1);
				break;
			}

			if (rfork_flags & RFMEM)
			{
				// True sharing: same L1 table pointer, so every mapping
				// either process makes or already has is visible to
				// both — this is what makes it a "thread" rather than a
				// process. SYS_EXIT's own free loop above has a guard
				// specifically for this case.
				child.page_table = current_proc.page_table;
			}
			else
			{
				// Independent copy: fresh L1 table, same kernel-range +
				// PLIC identity mapping create_process always does,
				// then every PAGE_U leaf in the parent's table gets a
				// fresh physical page with a byte-for-byte copy, mapped
				// at the same vaddr with the same flags. Same walk
				// shape as SYS_EXIT's free loop above, copy instead of
				// free.
				uint* child_table = (uint*)alloc_pages(1);
				for (uint paddr = (uint)&__kernel_base; paddr < (uint)&__free_ram_end; paddr += PAGE_SIZE)
				{
					map_page(child_table, paddr, paddr, PAGE_R | PAGE_W | PAGE_X);
				}
				map_page(child_table, PLIC_PRIORITY_PAGE, PLIC_PRIORITY_PAGE, PAGE_R | PAGE_W);
				map_page(child_table, PLIC_ENABLE_PAGE, PLIC_ENABLE_PAGE, PAGE_R | PAGE_W);
				map_page(child_table, PLIC_CLAIM_PAGE, PLIC_CLAIM_PAGE, PAGE_R | PAGE_W);

				uint* parent_table1 = current_proc.page_table;
				for (uint vpn1 = 0; vpn1 < 1024; vpn1++)
				{
					if ((parent_table1[vpn1] & PAGE_V) == 0) continue;

					uint* parent_table0 = (uint*)((parent_table1[vpn1] >> 10) * PAGE_SIZE);
					for (uint vpn0 = 0; vpn0 < 1024; vpn0++)
					{
						if ((parent_table0[vpn0] & PAGE_V) == 0) continue;
						if ((parent_table0[vpn0] & PAGE_U) == 0) continue;

						uint parent_leaf_paddr = (parent_table0[vpn0] >> 10) * PAGE_SIZE;
						uint child_leaf_paddr  = alloc_pages(1);
						mem::copy((void*)child_leaf_paddr, (void*)parent_leaf_paddr, (sz)PAGE_SIZE);

						uint child_vaddr  = (vpn1 << 22) | (vpn0 << 12);
						uint parent_flags = parent_table0[vpn0] & 0x1f; // V|R|W|X|U — see page.c3's map_page encoding
						map_page(child_table, child_vaddr, child_leaf_paddr, parent_flags);
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
			// process.c3 for how this block gets consumed.
			uint* child_sp = (uint*)&child.stack;
			child_sp += STACK_SIZE / 4;
			child_sp -= 32;

			mem::copy((void*)child_sp, f, (sz)Trap_frame::size);
			Trap_frame* child_frame = (Trap_frame*)child_sp;
			child_frame.a0 = 0;
			child_sp[31] = read_reg("sepc") + 4;

			for (int rf_j = 0; rf_j < 12; rf_j++)
			{
				*(--child_sp) = 0;
			}
			*(--child_sp) = (uint)&fork_entry;

			child.has_message = false;
			child.pid   = child_i + 1;
			child.generation++;
			child.sp    = (uint)child_sp;
			child.state = PROC_RUNNABLE;

			// Optional out-pointer (a1), same "null means don't care"
			// convention as SYS_IPC_RECV's type_out — lets the caller
			// capture this child's generation for a later SYS_JOIN to
			// check against, so a join can tell "this pid exited" apart
			// from "this pid got reused by something else."
			uint* rfork_gen_out = (uint*)f.a1;
			if (rfork_gen_out != null)
			{
				*rfork_gen_out = child.generation;
			}

			f.a0 = (uint)child.pid;
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
			char* unmount_prefix = (char*)f.a0;
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
			f.a0 = (uint)unmount_result;
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
			uint join_generation = f.a1;
			if (join_pid == current_proc.pid)
			{
				// Can't wait for yourself to disappear while you're the
				// one running — always self-deadlock. Reject rather than
				// hang.
				f.a0 = (uint)(-1);
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
	uint scause  = read_reg("scause");
	uint stval   = read_reg("stval");
	uint user_pc = read_reg("sepc");

	if (scause & SCAUSE_INTERRUPT_BIT)
	{
		uint code = scause & ~SCAUSE_INTERRUPT_BIT;
		if (code == SCAUSE_SUPERVISOR_EXTERNAL)
		{
			// Claiming acknowledges the IRQ to the PLIC. 0 means a
			// spurious claim (nothing pending) — don't complete an IRQ
			// that wasn't actually claimed.
			uint irq = plic_claim();
			if (irq == IRQ_VIRTIO_BLK && diskd_pid != 0)
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
			if (irq != 0)
			{
				plic_complete(irq);
			}
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
		io::printfn("unexpected trap scause=%x, stval=%x, sepc=%x\n", scause, stval, user_pc);
		panic::panic("it's a trap!");
	}
}