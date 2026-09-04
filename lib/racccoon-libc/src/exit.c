/* exit() runs the atexit handlers (LIFO), then _exit(). stdio flushing
 * is layered on in the stdio stage. abort() skips the handlers and
 * exits with the conventional 128 + SIGABRT code (racccoon has no
 * signals). */
#include <stdlib.h>

extern void (*__libc_atexit_fns[])(void);
extern int  __libc_atexit_n;
extern void __libc_stdio_exit_flush(void);   /* src/stdio.c */

void exit(int code)
{
	while (__libc_atexit_n > 0)
		__libc_atexit_fns[--__libc_atexit_n]();
	__libc_stdio_exit_flush();
	_exit(code);
}

void abort(void)
{
	_exit(134);
}
