#ifndef _UNISTD_H
#define _UNISTD_H

#include <sys/types.h>

#define STDIN_FILENO  0
#define STDOUT_FILENO 1
#define STDERR_FILENO 2

#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2

/* --- POSIX fd layer (rc_posix.c) --- */
ssize_t read(int fd, void *buf, size_t count);
ssize_t write(int fd, const void *buf, size_t count);
int     close(int fd);
off_t   lseek(int fd, off_t offset, int whence);
int     unlink(const char *path);
int     rmdir(const char *path);
int     chdir(const char *path);
char   *getcwd(char *buf, size_t size);
int     rename(const char *oldp, const char *newp);
int     isatty(int fd);
int     dup(int fd);
int     dup2(int oldfd, int newfd);
int     access(const char *path, int mode);
#define F_OK 0
#define R_OK 4
#define W_OK 2
#define X_OK 1

/* --- process --- */
pid_t   getpid(void);
pid_t   getppid(void);
int     getuid(void);
__attribute__((noreturn)) void _exit(int code);

/* --- racccoon-specific --- */
void         *__rc_map_pages(unsigned long nbytes);
int           __rc_stdin_is_console(void);
unsigned long __rc_timebase_hz(void);

#endif
