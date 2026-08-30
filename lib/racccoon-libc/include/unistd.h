#ifndef _UNISTD_H
#define _UNISTD_H

/* Stage 1: just the standard-stream I/O + exit + a couple of racccoon
 * conveniences. The real fd-based file layer comes later. */

#define STDIN_FILENO  0
#define STDOUT_FILENO 1
#define STDERR_FILENO 2

long write(int fd, const void *buf, unsigned long count);
long read(int fd, void *buf, unsigned long count);
__attribute__((noreturn)) void _exit(int code);

int getuid(void);

/* racccoon-specific, not POSIX — namespaced so they don't collide once
 * a real <unistd.h>-shaped surface fills in around them. */
void *__rc_map_pages(unsigned long nbytes);
int __rc_stdin_is_console(void);
unsigned long __rc_timebase_hz(void);

#endif
