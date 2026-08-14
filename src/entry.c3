module kernel;

import std::io;
import panic;
import sbi;

const SCAUSE_ECALL = 8;

// Syscall numbers. Kernel and user are separate c3c compilations with no
// shared header, so these must be kept in sync by hand with the SYS_*
// consts in user/user.c3.
const SYS_PUTCHAR   = 1;
const SYS_GETCHAR   = 2;
const SYS_READFILE  = 4;
const SYS_WRITEFILE = 5;

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

fn void kernel_entry() @align(4) @export("kernel_entry") @noinline @nostrip
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
		default:
			panic::panic("unexpected syscall");
	}
}

fn void handle_trap(Trap_frame* f) @export("handle_trap") @noinline @nostrip
{
	uint scause  = read_reg("scause");
	uint stval   = read_reg("stval");
	uint user_pc = read_reg("sepc");

	if (scause == SCAUSE_ECALL)
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