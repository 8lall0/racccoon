/* crt1.o for a TinyCC-linked binary on racccoon.
 *
 * Unlike our own flat /bin programs (lib/racccoon-libc/src/start.c),
 * tcc controls this binary's section layout, so there's no linker-script
 * __stack_top to load sp from. racccoon's SYS_EXEC doesn't hand a fresh
 * program a usable stack either (see src/entry.c3's exec comment). So
 * _start SYS_MAPs its own stack first thing — an ecall needs no stack —
 * then hands off to __libc_start (in libc.a / libracccoon.a) with the
 * kernel's a0 = argc, a1 = argv-blob preserved. */
#include <racccoon/syscall.h>

#define RC_CRT1_STACK (256 * 1024)

void __libc_start(int argc, char *blob);

__attribute__((naked, section(".text.start"), used))
void _start(void)
{
	__asm__ volatile(
		"mv   s0, a0\n\t"          /* argc */
		"mv   s1, a1\n\t"          /* argv blob base */
		"li   a0, %0\n\t"
		"li   a3, %1\n\t"         /* SYS_MAP */
		"ecall\n\t"
		"li   t0, %0\n\t"
		"add  sp, a0, t0\n\t"    /* stack grows down from base+size */
		"andi sp, sp, -16\n\t"
		"mv   a0, s0\n\t"
		"mv   a1, s1\n\t"
		"call __libc_start\n\t"
		:: "i"(RC_CRT1_STACK), "i"(RC_SYS_MAP)
	);
}
