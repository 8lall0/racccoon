/* exit() runs the atexit handlers (LIFO), then _exit(). stdio flushing
 * is layered on in the stdio stage. abort() skips the handlers and
 * exits with the conventional 128 + SIGABRT code (racccoon has no
 * signals). */
#include <stdlib.h>

struct __libc_atexit_ent { void (*fn)(void *); void *arg; };
extern struct __libc_atexit_ent __libc_atexit_fns[];
extern int  __libc_atexit_n;
extern void __libc_stdio_exit_flush(void);   /* src/stdio.c */

/* .fini_array (static destructors not registered through __cxa_atexit,
 * __attribute__((destructor))). Weak: a linker that doesn't define the
 * bounds (tcc's) leaves both null and the loop empty. */
extern void (*__fini_array_start[])(void) __attribute__((weak));
extern void (*__fini_array_end[])(void) __attribute__((weak));

void exit(int code)
{
	while (__libc_atexit_n > 0) {
		__libc_atexit_n--;
		__libc_atexit_fns[__libc_atexit_n].fn(__libc_atexit_fns[__libc_atexit_n].arg);
	}
	for (long i = __fini_array_end - __fini_array_start; i > 0; i--)
		__fini_array_start[i - 1]();
	__libc_stdio_exit_flush();
	_exit(code);
}

void abort(void)
{
	_exit(134);
}
