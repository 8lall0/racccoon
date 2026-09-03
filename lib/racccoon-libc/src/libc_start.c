/* The C-runtime entry logic, shared by every crt variant:
 *
 *   - lib/racccoon-libc/src/start.c  — crt0.o for our own flat /bin
 *     programs; _start sets sp from the linker script's __stack_top.
 *   - lib/tcc/crt1.c                 — crt1.o for tcc-linked binaries,
 *     whose layout we don't control; _start SYS_MAPs its own stack.
 *
 * Both just land in __libc_start() with a0/a1 still holding what the
 * kernel's SYS_EXEC passed at the entry point: a0 = argc, a1 = the base
 * of a NUL-separated argv blob mapped right after the image.
 *
 * Two producers put blobs there, told apart by the first byte:
 *   - a c3 program's exec() (the shell, most /bin tools): a plain
 *     "argv0\0arg1\0…" blob, argc = the count. Since the 2026-09-02
 *     exec-ABI change (user/user.c3 exec()) blob string 0 IS the
 *     program path = argv[0], and argc counts it — so we use it
 *     directly, no synthetic placeholder, no +1 shift. (Before that
 *     change the blob held only the real args and this synthesised an
 *     argv[0]; the fallback below still does, for a hypothetical
 *     empty blob.)
 *   - this libc's execve() (rc_proc.c): a 0x01 marker, then argc strings
 *     the first of which is argv[0], then optionally a 0x02 marker and
 *     "KEY=VAL\0…" ended by an empty string. A real argv[0] + environ,
 *     with no kernel ABI change (0x01 never begins a path/argument). */
#include <racccoon/syscall.h>

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

__attribute__((used, noreturn)) void __libc_start(int argc, char *blob)
{
	int n = argc;
	if (n < 0) n = 0;
	if (n > LIBC_ARGV_MAX) n = LIBC_ARGV_MAX;

	char *p = blob;

	if (argc > 0 && (unsigned char)*p == LIBC_ARGV0_MARK) {
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

	if (n == 0) {
		/* No blob at all — hand main a synthetic argv[0] so argv[0]
		 * is never NULL. */
		libc_argv[0] = libc_argv0;
		libc_argv[1] = 0;
		_exit(main(1, libc_argv, environ));
	}

	/* Blob string 0 is argv[0] (the program path); the rest are the
	 * real arguments. argc already counts string 0. */
	for (int i = 0; i < n; i++) {
		libc_argv[i] = p;
		while (*p) p++;
		p++;
	}
	libc_argv[n] = 0;

	_exit(main(n, libc_argv, environ));
}
