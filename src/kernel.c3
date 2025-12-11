module kernel;

import libc;
import std::io;
import panic;

char[] __bss @export("__bss");
char[] __bss_end @export("__bss_end");
char[] __stack_top @export("__stack_top");
char[] __free_ram @export("__free_ram");
char[] __free_ram_end @export("__free_ram_end");

fn void boot() @naked @extern("boot") @section(".text.boot") @noinline @nostrip @used {
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
    io::printfn("starting process A");
    for (;;) {
        libc::putchar('A');
        switch_context(&proc_a.sp, &proc_b.sp);
        delay();
    }
}

fn void proc_b_entry() {
    io::printfn("starting process B");
    for (;;) {
        libc::putchar('B');
        switch_context(&proc_b.sp, &proc_a.sp);
        delay();
    }
}

fn void kernel_main() @export("kernel_main") @noinline @nostrip {
    mem::set(&__bss, 0, (uint) &__bss_end - (uint) &__bss);
    //asm(@sprintf("la t0, %s", &kernel_entry));
    //asm("csrw stvec, t0");
    //asm("unimp");

    proc_a = create_process((uint) &proc_a_entry);
    proc_b = create_process((uint) &proc_b_entry);
    proc_a_entry();

    panic::panic("BOOTED");
    /*for (;;) {
        asm {
            wfi;
        }
    }*/
}
