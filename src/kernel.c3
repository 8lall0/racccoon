module kernel;

import libc;
import std::io;
import panic;

char[] __kernel_base @export("__kernel_base");
char[] __bss @export("__bss");
char[] __bss_end @export("__bss_end");
char[] __stack_top @export("__stack_top");
char[] __free_ram @export("__free_ram");
char[] __free_ram_end @export("__free_ram_end");

fn void boot() @naked @export("boot") @section(".text.boot") @noinline @nostrip @used {
    asm(`
        la sp, __stack_top
        j kernel_main
    `);
}

fn void delay() {
    for (int i = 0; i < 30000000; i++) {
        asm("nop");
    }
}

Process *proc_a;
Process *proc_b;

fn void proc_a_entry() {
    io::print("starting process A\n");
    for (;;) {
        libc::putchar('A');
        delay();
        yield();
    }
}

fn void proc_b_entry() {
    io::print("starting process B\n");
    for (;;) {
        libc::putchar('B');
        delay();
        yield();
    }
}

fn void kernel_main() @export("kernel_main") @noinline @nostrip {
    mem::set(&__bss, 0, (sz)((uint) &__bss_end - (uint) &__bss));

    io::print("1: BSS cleared\n");

    asm(@sprintf("la t0, %s", &kernel_entry));
    asm("csrw stvec, t0");

    io::print("2: Trap handler set\n");

    idle_proc = create_process((uint) &idle_entry);
    io::print("3: Idle created\n");

    idle_proc.pid = 0;
    current_proc = idle_proc;

    io::print("4: Idle configured\n");

    io::printfn("procs array at: %x", (uint)&procs);
    io::printfn("procs array end: %x", (uint)(&procs + 1));
    io::printfn("__kernel_base: %x", (uint)&__kernel_base);
    io::printfn("__free_ram: %x", (uint)&__free_ram);

    proc_a = create_process((uint) &proc_a_entry);
    io::print("5: Proc A created\n");
    io::printfn("Checking proc_a page table at %x", (uint)proc_a.page_table);

    uint *pt_a = proc_a.page_table;
    uint procs_addr = (uint)&procs;
    uint vpn1_procs = (procs_addr >> 22) & 0x3ff;
    uint vpn0_procs = (procs_addr >> 12) & 0x3ff;

    io::printfn("procs address: %x, vpn1=%d, vpn0=%d", procs_addr, vpn1_procs, vpn0_procs);
    io::printfn("PT L1[%d] = %x", vpn1_procs, pt_a[vpn1_procs]);

    if (pt_a[vpn1_procs] & PAGE_V) {
        uint *table0 = (uint *) (((pt_a[vpn1_procs] >> 10)) << 12);
        io::printfn("PT L2 at: %x", (uint)table0);
        io::printfn("PT L2[%d] = %x", vpn0_procs, table0[vpn0_procs]);
    }

    proc_b = create_process((uint) &proc_b_entry);
    io::print("6: Proc B created\n");

    io::print("7: Starting processes...\n");

    io::printfn("yield() function at: %x", (uint)&yield);
    idle_entry();

    io::print("8: Should never reach here\n");

    panic::panic("BOOTED");
}

fn void idle_entry() {
    io::print("Idle process started\n");
    for (;;) {
        yield();
    }
}

fn void print_hex(uint val) {
    char[9] hex = "00000000";
    for (int i = 7; i >= 0; i--) {
        uint digit = val & 0xF;
        hex[i] = (char)(digit < 10 ? '0' + digit : 'a' + digit - 10);
        val >>= 4;
    }
    for (int i = 0; i < 8; i++) {
        libc::putchar(hex[i]);
    }
}