/* The thinnest libc-facing wrappers over the racccoon syscalls that
 * Stage 1 needs: raw console I/O, exit, and the page allocator. The
 * POSIX fd layer (open/read/write/close over racccoon's path-based fs)
 * arrives in a later stage; for now write()/read() only understand the
 * console (fd 0/1/2). */
#include <racccoon/syscall.h>
#include <stddef.h>

static void rc_putchar(char c)
{
	__rc_syscall3((long)(unsigned char)c, 0, 0, RC_SYS_PUTCHAR);
}

static int rc_getchar(void)
{
	return (int)__rc_syscall3(0, 0, 0, RC_SYS_GETCHAR);
}

/* Stage-1 write(): console only. fd is ignored beyond "is it a
 * standard stream". Returns the byte count, like POSIX. */
long write(int fd, const void *buf, unsigned long count)
{
	(void)fd;
	const char *p = (const char *)buf;
	for (unsigned long i = 0; i < count; i++) rc_putchar(p[i]);
	return (long)count;
}

/* Stage-1 read(): the console, one byte at a time; -1 on EOF (which
 * the console never actually reports). */
long read(int fd, void *buf, unsigned long count)
{
	(void)fd;
	char *p = (char *)buf;
	unsigned long i = 0;
	for (; i < count; i++) {
		int c = rc_getchar();
		if (c < 0) break;
		p[i] = (char)c;
		if (c == '\n' || c == '\r') { i++; break; }
	}
	return (long)i;
}

/* Anonymous demand pages, page-rounded, at the process's heap_top.
 * Returns NULL on failure (the kernel's SYS_MAP returns -1). The libc
 * malloc (Stage 2) is built on this. */
void *__rc_map_pages(unsigned long nbytes)
{
	long r = __rc_syscall3((long)nbytes, 0, 0, RC_SYS_MAP);
	if (r == -1) return NULL;
	return (void *)r;
}

int __rc_stdin_is_console(void)
{
	return (int)__rc_syscall3(0, 0, 0, RC_SYS_STDIN_ISATTY);
}

unsigned long __rc_timebase_hz(void)
{
	return (unsigned long)__rc_syscall3(0, 0, 0, RC_SYS_TIMEBASE);
}

int getuid(void)
{
	return (int)__rc_syscall3(0, 0, 0, RC_SYS_GETUID);
}
