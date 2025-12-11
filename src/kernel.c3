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

fn void kernel_main() @export("kernel_main") @noinline @nostrip {
    mem::set(&__bss, 0, (uint) &__bss_end - (uint) &__bss);
    //asm(@sprintf("la t0, %s", &kernel_entry));
    //asm("csrw stvec, t0");
    //asm("unimp");

    uint paddr0 = alloc_pages(2);
    uint paddr1 = alloc_pages(1);
    io::printfn("alloc_pages test: paddr0=%x", paddr0);
    io::printfn("alloc_pages test: paddr1=%x", paddr1);

    panic::panic("BOOTED");
    for (;;) {
        asm {
            wfi;
        }
    }
}
