module racccoon;
import sbi;

char[] __bss @export("__bss");
char[] __bss_end @export("__bss_end");
char[] __stack_top @export("__stack_top");

fn void boot() @naked @export(".text.boot") @noinline @nostrip {
    asm(`
        la sp, __stack_top
        j kernel_main
    `);
}

fn void kernel_main() @export("kernel_main") @noinline @nostrip {
    mem::set(&__bss, 0, (uint) &__bss_end - (uint) &__bss);
    const char *S = "\n\nHello World!\n";
    for (int i = 0; S[i] != '\0'; i++) {
        sbi::_putchar(S[i]);
    }

    for (;;) {
        asm {
            wfi;
        }
    }
}
