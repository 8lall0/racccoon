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

/* 2026-09-04: was 256 KiB, too small for c3c (self-hosting on racccoon,
 * QEMU only) — its GlobalContext has a `Decl *decl_stack[65536]` local
 * (524 KiB by itself) declared on the stack in compiler_init(), which
 * blew straight through 256 KiB with no fault ever reported (the
 * overflow silently corrupted whatever SYS_MAP page came next, instead
 * of hitting an unmapped one) — the process just died with no output,
 * looking exactly like a hang until stderr checkpoints pinned it to
 * that one local. 4 MiB leaves ~8x headroom over that single local
 * plus real recursion depth (parser/sema). Trivial either way against
 * board::HEAP_MAX_BYTES (512 MiB QEMU) since SYS_MAP is demand-paged —
 * unused pages cost nothing. Duo's 16 MiB ceiling is the one board
 * this matters for; nothing tcc-linked targets the Duo today. */
#define RC_CRT1_STACK (4 * 1024 * 1024)

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
