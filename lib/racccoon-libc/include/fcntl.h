#ifndef _FCNTL_H
#define _FCNTL_H
#ifdef __cplusplus
extern "C" {
#endif

#include <sys/types.h>

/* Values chosen to match Linux's asm-generic bits so ported code that
 * hardcodes them behaves. Only the semantics racccoon's fsd can back
 * are actually honoured (see rc_posix.c). */
#define O_RDONLY    0
#define O_WRONLY    1
#define O_RDWR      2
#define O_ACCMODE   3

#define O_CREAT     0100
#define O_EXCL      0200
#define O_TRUNC     01000
#define O_APPEND    02000
#define O_NONBLOCK  04000      /* accepted, ignored */
#define O_CLOEXEC   02000000   /* accepted, ignored (no exec fd inheritance yet) */
#define O_DIRECTORY 0200000

/* fcntl commands — mostly accepted-and-ignored for now */
#define F_DUPFD  0
#define F_GETFD  1
#define F_SETFD  2
#define F_GETFL  3
#define F_SETFL  4
#define FD_CLOEXEC 1
#define F_GETLK  5
#define F_SETLK  6
#define F_SETLKW 7

/* Record locks: only one process ever holds a file open for locking in
 * practice, so a lock is always granted and F_GETLK reports none. */
#define F_RDLCK 0
#define F_WRLCK 1
#define F_UNLCK 2
struct flock {
	short l_type;
	short l_whence;
	off_t l_start;
	off_t l_len;
	pid_t l_pid;
};

int open(const char *path, int flags, ...);
int creat(const char *path, mode_t mode);
int fcntl(int fd, int cmd, ...);

#ifdef __cplusplus
}
#endif
#endif
