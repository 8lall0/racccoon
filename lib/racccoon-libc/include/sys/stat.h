#ifndef _SYS_STAT_H
#define _SYS_STAT_H
#ifdef __cplusplus
extern "C" {
#endif

#include <sys/types.h>

#ifndef __RC_TIMESPEC
#define __RC_TIMESPEC
struct timespec {
	time_t tv_sec;
	long   tv_nsec;
};
#endif

struct stat {
	dev_t     st_dev;
	ino_t     st_ino;
	mode_t    st_mode;
	nlink_t   st_nlink;
	uid_t     st_uid;
	gid_t     st_gid;
	dev_t     st_rdev;
	off_t     st_size;
	blksize_t st_blksize;
	blkcnt_t  st_blocks;
	struct timespec st_atim;   /* POSIX 2008; the filesystems keep no times, so 0 */
	struct timespec st_mtim;
	struct timespec st_ctim;
};
#define st_atime st_atim.tv_sec
#define st_mtime st_mtim.tv_sec
#define st_ctime st_ctim.tv_sec

#define UTIME_NOW  ((1L << 30) - 1L)
#define UTIME_OMIT ((1L << 30) - 2L)
int utimensat(int dirfd, const char *path, const struct timespec times[2], int flags);
int futimens(int fd, const struct timespec times[2]);
int fstatat(int dirfd, const char *path, struct stat *st, int flags);
int mkdirat(int dirfd, const char *path, mode_t mode);
int fchmodat(int dirfd, const char *path, mode_t mode, int flags);

#define S_IFMT   0170000
#define S_IFREG  0100000
#define S_IFDIR  0040000
#define S_IFCHR  0020000

#define S_ISREG(m)  (((m) & S_IFMT) == S_IFREG)
#define S_ISDIR(m)  (((m) & S_IFMT) == S_IFDIR)
#define S_ISCHR(m)  (((m) & S_IFMT) == S_IFCHR)
#define S_ISBLK(m)  0
#define S_ISFIFO(m) 0
#define S_ISLNK(m)  0
#define S_ISSOCK(m) 0

#define S_IRWXU 0700
#define S_IRUSR 0400
#define S_IWUSR 0200
#define S_IXUSR 0100
#define S_IRWXG 0070
#define S_IRWXO 0007

int stat(const char *path, struct stat *st);
int lstat(const char *path, struct stat *st);
int fstat(int fd, struct stat *st);
int mkdir(const char *path, mode_t mode);
int fchmod(int fd, mode_t mode);
mode_t umask(mode_t mask);

#ifdef __cplusplus
}
#endif
#endif
