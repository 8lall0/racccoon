/* crt0_mapped.o: crt0 for big C/C++ programs (LLVM tools). Same handoff
 * as start.c, but instead of the 64 KiB stack in .bss — which objcopy
 * materialises into the flat image, so it can't grow — it SYS_MAPs an
 * 8 MiB stack first thing (an ecall needs no stack; demand-paged, so
 * untouched pages cost nothing), the way lib/tcc/crt1.c does. Linked
 * instead of crt0.o; build.sh keeps it out of libracccoon.a. */
#include <racccoon/syscall.h>

#define RC_MAPPED_STACK (8 * 1024 * 1024)

void __libc_start(int argc, char *blob);

__attribute__((naked, section(".text.start"), used))
void _start(void)
{
	__asm__ volatile(
		"mv   s0, a0\n\t"          /* argc */
		"mv   s1, a1\n\t"          /* argv blob */
		"li   a0, %0\n\t"
		"li   a3, %1\n\t"          /* SYS_MAP */
		"ecall\n\t"
		"li   t0, %0\n\t"
		"add  sp, a0, t0\n\t"      /* the stack grows down from base + size */
		"andi sp, sp, -16\n\t"
		".weak __tls_start\n\t"
		"la   tp, __tls_start\n\t"
		"mv   a0, s0\n\t"
		"mv   a1, s1\n\t"
		"call __libc_start\n\t"
		:: "i"(RC_MAPPED_STACK), "i"(RC_SYS_MAP)
	);
}
