module kernel;

import std::io;
import panic;
import sbi;

const SCAUSE_ECALL             = 8;
const SCAUSE_INTERRUPT_BIT     = 0x80000000; // MSB of scause: set for interrupts, clear for exceptions
const SCAUSE_SUPERVISOR_EXTERNAL = 9;        // interrupt cause code for a PLIC-routed external interrupt

// Dedicated trap-frame anchor for traps taken during kernel_main's
// bare-mode phase (before any process exists — this is when fs_init()'s
// disk reads happen, now interrupt-driven). Deliberately NOT __stack_top:
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
const SYS_READFILE  = 4;
const SYS_WRITEFILE = 5;
const SYS_IPC_SEND  = 6;
const SYS_IPC_RECV  = 7;
const SYS_NS_RESOLVE = 8;

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

			current_proc.state = PROC_UNUSED;
			current_proc.pid = 0;

			// yield() never returns here: current_proc is now PROC_UNUSED,
			// so its scan can't match itself, and switch_context's `ret`
			// jumps permanently into whatever process it picks instead.
			yield();
		case SYS_READFILE:
		case SYS_WRITEFILE:
			// NOTE: this logic looks like it belongs next to fs_lookup/
			// fs_flush in fs.c3, and it did live there as fs_handle_syscall(f)
			// at one point — but that alone (nothing else changed) made the
			// kernel fail on the very first syscall (SYS_PUTCHAR, unrelated
			// to this code path) with a reboot loop, reproducible even with
			// @noinline on the extracted function. Root cause not
			// identified — smells like a c3c 0.8.2 codegen bug tied to
			// calling a function taking Trap_frame* across the file
			// boundary. Left inline here since this version is proven
			// correct; revisit if this ever needs touching again.
			char* filename = (char*)f.a0;
			char* buf      = (char*)f.a1;
			int len        = (int)f.a2;
			File* file     = fs_lookup(filename);
			if (!file)
			{
				io::printfn("file not found: %s", (ZString)filename);
				f.a0 = (uint)(-1);
				break;
			}

			if (f.a3 == SYS_WRITEFILE)
			{
				// Never write more than the file's own storage can hold.
				if (len > (int)file.data.len)
				{
					len = (int)file.data.len;
				}
				mem::copy(&file.data, buf, (sz)len);
				file.size = (uint)len;
				fs_flush();
			}
			else
			{
				// Never hand back more than the file actually contains —
				// the caller's buffer is only guaranteed to hold `len`
				// bytes, so returning more than that (even if it fits in
				// the file's own 1024-byte storage) would have the caller
				// read/index past its own buffer.
				if (len > (int)file.size)
				{
					len = (int)file.size;
				}
				mem::copy(buf, &file.data, (sz)len);
			}

			f.a0 = (uint)len;
		case SYS_IPC_SEND:
			// Inline for the same reason as SYS_EXIT/SYS_READFILE above —
			// this is the pattern proven not to trigger the unexplained
			// c3c reboot bug in this switch. dest_pid/type/data are a0-a2
			// as usual; len is a4, since a3 is always the syscall number
			// (see syscall4 in user/user.c3 — this is the one syscall that
			// needs a 4th argument).
			int ipc_dest_pid = (int)f.a0;
			uint ipc_type    = f.a1;
			char* ipc_data   = (char*)f.a2;
			int ipc_len      = (int)f.a4;
			Process* ipc_target = proc_by_pid(ipc_dest_pid);
			if (!ipc_target)
			{
				f.a0 = (uint)(-1);
				break;
			}
			int ipc_copy_len = ipc_len > MSG_MAX ? MSG_MAX : ipc_len;
			if (ipc_copy_len < 0) ipc_copy_len = 0;
			mem::copy(&ipc_target.msg_data, ipc_data, (sz)ipc_copy_len);
			ipc_target.msg_from = current_proc.pid;
			ipc_target.msg_type = ipc_type;
			ipc_target.has_message = true;
			if (ipc_target.state == PROC_BLOCKED)
			{
				ipc_target.state = PROC_RUNNABLE;
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
					break;
				}
				current_proc.state = PROC_BLOCKED;
				yield();
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
			// Claiming acknowledges the IRQ to the PLIC; we don't need to
			// do anything else with it here — whatever was wfi-waiting on
			// this (read_write_disk) just needed the CPU to wake up, and
			// re-checks the real completion state (the used ring index)
			// itself. 0 means a spurious claim (nothing pending) — don't
			// complete an IRQ that wasn't actually claimed.
			uint irq = plic_claim();
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