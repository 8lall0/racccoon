module kernel;

import panic;
import libc;
import std::io;

const PROCS_MAX = 8;        // Maximum number of processes
const PROC_UNUSED = 0;      // Unused process control structure
const PROC_RUNNABLE = 1;    // Runnable process
const STACK_SIZE = 8192;    // Stack size

struct Process {
    int pid;                // Process ID
    int state;              // Process state: PROC_UNUSED or PROC_RUNNABLE
    uint sp;                // Stack pointer
    uint *page_table;
    char [STACK_SIZE]stack;       // Kernel stack
}

fn void switch_context(uint *prev_sp, uint *next_sp) @naked @noinline {
    asm(`
        addi sp, sp, -13 * 4
        sw ra,  0  * 4(sp)
        sw s0,  1  * 4(sp)
        sw s1,  2  * 4(sp)
        sw s2,  3  * 4(sp)
        sw s3,  4  * 4(sp)
        sw s4,  5  * 4(sp)
        sw s5,  6  * 4(sp)
        sw s6,  7  * 4(sp)
        sw s7,  8  * 4(sp)
        sw s8,  9  * 4(sp)
        sw s9,  10 * 4(sp)
        sw s10, 11 * 4(sp)
        sw s11, 12 * 4(sp)
        sw sp, (a0)
        lw sp, (a1)
        lw ra,  0  * 4(sp)
        lw s0,  1  * 4(sp)
        lw s1,  2  * 4(sp)
        lw s2,  3  * 4(sp)
        lw s3,  4  * 4(sp)
        lw s4,  5  * 4(sp)
        lw s5,  6  * 4(sp)
        lw s6,  7  * 4(sp)
        lw s7,  8  * 4(sp)
        lw s8,  9  * 4(sp)
        lw s9,  10 * 4(sp)
        lw s10, 11 * 4(sp)
        lw s11, 12 * 4(sp)
        addi sp, sp, 13 * 4
        ret
    `);
}

Process [PROCS_MAX]procs; // All process control structures.

fn Process *create_process(uint pc) {
    // Find an unused process control structure.
    Process *proc = null;
    int i;
    for (i = 0; i < PROCS_MAX; i++) {
        if (procs[i].state == PROC_UNUSED) {
            proc = &procs[i];
            break;
        }
    }

    if (!proc) {
        panic::panic("no free process slots");
    }

    uint * sp = (uint *) &proc.stack;
    sp += 2048;
    for (int j = 0; j < 12; j++) {
        *(--sp) = 0;
    }
    // Setting RA
    *(--sp) = pc;

    uint *page_table = (uint *) alloc_pages(1);
    io::printfn("Creating page table at: %x", (uint)page_table);
    for (
        uint paddr = (uint) &__kernel_base;
        paddr < (uint) &__free_ram_end;
        paddr += PAGE_SIZE
    ) {
        map_page(page_table, paddr, paddr, PAGE_R | PAGE_W | PAGE_X);
    }

    io::printfn("Mapped %x to %x", (uint)&__kernel_base, (uint)&__free_ram);

    // Verify the mapping worked - try to look up a test address
    uint test_addr = 0x80200000;
    uint vpn1 = (test_addr >> 22) & 0x3ff;
    uint vpn0 = (test_addr >> 12) & 0x3ff;
    io::printfn("Page table[%d] = %x", vpn1, page_table[vpn1]);

    // NEW: Check the second-level table
    if (page_table[vpn1] & PAGE_V) {
        uint *table0 = (uint *) (((page_table[vpn1] >> 10)) << 12);
        io::printfn("L2 table at: %x", (uint)table0);
        io::printfn("Page table L2[%d] = %x", vpn0, table0[vpn0]);
    }

    // Initialize fields.
    proc.pid = i + 1;
    proc.state = PROC_RUNNABLE;
    proc.sp = (uint) sp;
    proc.page_table = page_table;
    return proc;
}

Process *current_proc; // Currently running process
Process *idle_proc;    // Idle process

fn void yield() @noinline {
    Process *next = idle_proc;
    for (int i = 0; i < PROCS_MAX; i++) {
        Process *proc = &procs[(current_proc.pid + i) % PROCS_MAX];
        if (proc.state == PROC_RUNNABLE && proc.pid > 0) {
            next = proc;
            break;
        }
    }

    if (next == current_proc) {
        return;
    }

    Process *prev = current_proc;
    current_proc = next;

    uint satp = SATP_SV32 | (uint) ((uint) next.page_table / PAGE_SIZE);
    uint sscratch = (uint) &next.stack[^1] + 1;

    asm {
        lw $t0, [&satp];
        lw $t1, [&sscratch];
    }

    // UPER DUPER WORKAROUND
    libc::putchar('\0');

    asm(`
        sfence.vma
        csrw satp, t0
        sfence.vma
        csrw sscratch, t1
    `);

    switch_context(&prev.sp, &next.sp);
}

