/* Low-level racccoon conveniences that don't belong to any one <foo.h>.
 * The POSIX fd layer (read/write/close/lseek/…) lives in rc_posix.c. */
#include <racccoon/syscall.h>
#include <stddef.h>

/* Anonymous demand pages, page-rounded, at the process's heap_top.
 * NULL on failure. The libc malloc (malloc.c) is built on this. */
void *__rc_map_pages(unsigned long nbytes)
{
	long r = __rc_syscall3((long)nbytes, 0, 0, RC_SYS_MAP);
	return r == -1 ? NULL : (void *)r;
}

int __rc_stdin_is_console(void)
{
	return (int)__rc_syscall3(0, 0, 0, RC_SYS_STDIN_ISATTY);
}

unsigned long __rc_timebase_hz(void)
{
	return (unsigned long)__rc_syscall3(0, 0, 0, RC_SYS_TIMEBASE);
}
