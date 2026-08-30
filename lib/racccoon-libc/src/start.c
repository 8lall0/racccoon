/* crt0 for a C program on racccoon.
 *
 * racccoon's SYS_EXEC hands the fresh image control at its entry point
 * with a0 = argc and a1 = the base address of a NUL-separated argv blob
 * ("foo\0bar\0" for argc = 2), mapped right after the image — the same
 * ABI user/user.c3's start() + the c3 @main_args macro consume. There
 * is no envp: racccoon exec() carries no environment (a later libc
 * stage adds a convention for it). __stack_top comes from the linker
 * script (racccoon-libc.ld), same as user/user.ld's own.
 *
 * argv[0]: racccoon's exec ABI passes only the *arguments* — no program
 * name (a c3 program's args[0] is its first real argument). POSIX C
 * expects argv[0] to be the program name, so the crt0 synthesises a
 * placeholder there and shifts the racccoon args to argv[1..]. A real
 * name needs a kernel exec-passes-name path or an argv/env convention —
 * deferred to the process-layer stage (roadmap §7.6). */
#include <racccoon/syscall.h>

extern char __stack_top[];

int main(int argc, char **argv, char **envp);

#ifndef LIBC_ARGV_MAX
#define LIBC_ARGV_MAX 64
#endif

static char libc_argv0[16] = "racccoon-prog";
static char *libc_argv[LIBC_ARGV_MAX + 2];
static char *libc_envp[1] = { 0 };
char **environ = libc_envp;

__attribute__((noreturn)) void _exit(int code)
{
	__rc_syscall3(code, 0, 0, RC_SYS_EXIT);
	for (;;) { }   /* SYS_EXIT never returns; keep the compiler happy */
}

/* Called by _start (below) with a0/a1 still holding argc / the argv
 * blob base, since _start is @naked and only touches sp. */
__attribute__((used)) static void __libc_start(int argc, char *blob)
{
	int n = argc;
	if (n < 0) n = 0;
	if (n > LIBC_ARGV_MAX) n = LIBC_ARGV_MAX;

	libc_argv[0] = libc_argv0;
	char *p = blob;
	for (int i = 0; i < n; i++) {
		libc_argv[i + 1] = p;
		while (*p) p++;
		p++;
	}
	libc_argv[n + 1] = 0;

	_exit(main(n + 1, libc_argv, environ));
}

__attribute__((naked, section(".text.start"), used))
void _start(void)
{
	__asm__ volatile(
		"la sp, __stack_top\n\t"
		"call __libc_start\n\t"
	);
}
