#ifndef _UNISTD_H
#define _UNISTD_H
#ifdef __cplusplus
extern "C" {
#endif

#include <sys/types.h>

/* clock_gettime(CLOCK_MONOTONIC / CLOCK_REALTIME) exist (<time.h>). */
#define _POSIX_TIMERS          200809L
#define _POSIX_MONOTONIC_CLOCK 200809L

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
ssize_t pread(int fd, void *buf, size_t count, off_t off);
ssize_t pwrite(int fd, const void *buf, size_t count, off_t off);
int     fsync(int fd);
int     fdatasync(int fd);
ssize_t readlink(const char *path, char *buf, size_t n);
int     symlink(const char *target, const char *path);
int     link(const char *oldp, const char *newp);
int     pipe(int fds[2]);
char   *realpath(const char *path, char *resolved);
int     chmod(const char *path, mode_t mode);
int     chown(const char *path, uid_t uid, gid_t gid);
int     fchown(int fd, uid_t uid, gid_t gid);
int     lchown(const char *path, uid_t uid, gid_t gid);
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
#define _SC_ARG_MAX        5
#define _SC_GETPW_R_SIZE_MAX 6

/* --- process --- */
pid_t   getpid(void);
pid_t   getsid(pid_t pid);
pid_t   setsid(void);
unsigned alarm(unsigned seconds);
int     gethostname(char *name, size_t len);
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

#ifdef __cplusplus
}
#endif
#endif
