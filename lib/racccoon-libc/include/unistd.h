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
int     ftruncate(int fd, off_t length);
int     pipe(int fds[2]);
char   *realpath(const char *path, char *resolved);
int     chmod(const char *path, mode_t mode);
long    sysconf(int name);
int     getpagesize(void);
unsigned sleep(unsigned sec);
int     usleep(unsigned usec);
#define F_OK 0
#define R_OK 4
#define W_OK 2
#define X_OK 1
#define _SC_PAGESIZE       1
#define _SC_PAGE_SIZE      1
#define _SC_NPROCESSORS_ONLN 2
#define _SC_CLK_TCK        3
#define _SC_OPEN_MAX       4

/* --- process --- */
pid_t   getpid(void);
pid_t   getppid(void);
int     getuid(void);
__attribute__((noreturn)) void _exit(int code);

pid_t   fork(void);
int     execve(const char *path, char *const argv[], char *const envp[]);
int     execv(const char *path, char *const argv[]);
int     execvp(const char *file, char *const argv[]);
int     execl(const char *path, const char *arg, ...);
int     execlp(const char *file, const char *arg, ...);

extern char **environ;

/* --- racccoon-specific --- */
void         *__rc_map_pages(unsigned long nbytes);
int           __rc_stdin_is_console(void);
unsigned long __rc_timebase_hz(void);

#endif
