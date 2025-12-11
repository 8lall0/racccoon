module kernel;

import std::io;
import panic;

macro read_reg(String $reg)
{
    uptr x;
    asm(@sprintf("csrr a0, %s", $reg));
    asm { mv x, $a0; }
    return x;
}

macro write_reg(String $reg, String $value)
{
    asm(@sprintf("la t0, %s", $value));
    asm(@sprintf("csrw %s, t0", $reg));
}

fn void kernel_entry() @align(4) @export("kernel_entry") @noinline @nostrip {
    asm(`
        csrw sscratch, sp
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

struct Trap_frame @packed {
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

fn void handle_trap(Trap_frame *f) @export("handle_trap") @noinline @nostrip {
    uint scause = read_reg("scause");
    uint stval = read_reg("stval");
    uint user_pc = read_reg("sepc");

    io::printfn("unexpected trap scause=%x, stval=%x, sepc=%x\n", scause, stval, user_pc);
    panic::panic("it's a trap!");
}
