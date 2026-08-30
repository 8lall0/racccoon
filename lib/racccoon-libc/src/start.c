/* crt0 for a C program on racccoon.
 *
 * racccoon's SYS_EXEC hands the fresh image control at its entry point
 * with a0 = argc and a1 = the base address of a NUL-separated argv blob
 * ("foo\0bar\0" for argc = 2), mapped right after the image — the same
 * ABI user/user.c3's start() + the c3 @main_args macro consume.
 *
 * Two producers put blobs in front of this crt0, and it tells them
 * apart by the first byte:
 *
 *   - a c3 program's exec() (the shell, most /bin tools): a plain
 *     "arg1\0arg2\0..." blob, argc = the argument count, NO program
 *     name (a c3 program's args[0] is its first real argument). This
 *     crt0 then synthesises a placeholder argv[0].
 *
 *   - this libc's execve()/execvp() (rc_proc.c): a blob that starts
 *     with a 0x01 marker byte, then argc strings the *first of which is
 *     argv[0]* (whatever the caller passed), then — if the caller
 *     passed a non-empty envp — a 0x02 marker and the environment as
 *     "KEY=VAL\0..." terminated by an empty string. A real argv[0] and
 *     a real environ, with no kernel ABI change. 0x01 never begins a
 *     path or a normal argument, so the disambiguation is safe.
 *
 * __stack_top comes from the linker script (racccoon-libc.ld). */
#include <racccoon/syscall.h>

extern char __stack_top[];

int main(int argc, char **argv, char **envp);

#ifndef LIBC_ARGV_MAX
#define LIBC_ARGV_MAX 64
#endif
#ifndef LIBC_ENV_MAX
#define LIBC_ENV_MAX 62
#endif

#define LIBC_ARGV0_MARK 0x01
#define LIBC_ENV_MARK   0x02

static char libc_argv0[16] = "racccoon-prog";
static char *libc_argv[LIBC_ARGV_MAX + 2];
char *libc_envp[LIBC_ENV_MAX + 2] = { 0 };
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

	char *p = blob;

	if (argc > 0 && (unsigned char)*p == LIBC_ARGV0_MARK) {
		/* libc-packed: marker, then n strings starting with argv[0]. */
		p++;
		for (int i = 0; i < n; i++) {
			libc_argv[i] = p;
			while (*p) p++;
			p++;
		}
		libc_argv[n] = 0;

		if ((unsigned char)*p == LIBC_ENV_MARK) {
			p++;
			int e = 0;
			while (*p && e < LIBC_ENV_MAX) {
				libc_envp[e++] = p;
				while (*p) p++;
				p++;
			}
			libc_envp[e] = 0;
		}

		_exit(main(n, libc_argv, environ));
	}

	/* c3-packed: n plain arguments, no program name — synthesise one. */
	libc_argv[0] = libc_argv0;
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
