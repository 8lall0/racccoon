module kernel;

import libc;
import std::io;

char[] __bss @export("__bss");
char[] __bss_end @export("__bss_end");
char[] __stack_top @export("__stack_top");

fn void boot() @naked @extern("boot") @section(".text.boot") @noinline @nostrip @used {
    asm(`
        la sp, __stack_top
        j kernel_main
    `);
}

fn void kernel_main() @export("kernel_main") @noinline @nostrip {
    mem::set(&__bss, 0, (uint) &__bss_end - (uint) &__bss);

    io::printf("prova: %d", 10);

    for (;;) {
        asm {
            wfi;
        }
    }
}
