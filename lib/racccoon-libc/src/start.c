/* crt0.o for our own flat /bin programs (built by build.sh). _start sets
 * sp from the linker script's __stack_top, then hands off to
 * __libc_start (src/libc_start.c, in libracccoon.a) with a0/a1 — the
 * kernel's argc / argv-blob — untouched. tcc-linked binaries use
 * lib/tcc/crt1.c instead (same handoff, self-mapped stack). */

void __libc_start(int argc, char *blob);

__attribute__((naked, section(".text.start"), used))
void _start(void)
{
	__asm__ volatile(
		"la sp, __stack_top\n\t"
		"call __libc_start\n\t"
	);
}
