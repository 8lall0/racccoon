/* The POSIX emulation layer: a userspace file-descriptor table over
 * racccoon's path-based fs (rc_fs.c). fds 0/1/2 are the console;
 * open() allocates a slot holding {abspath, offset, flags}; read/write
 * translate to __rc_fs_read_at/__rc_fs_write_at at the tracked offset;
 * stat/dirent go straight to __rc_fs_stat/__rc_fs_list. */
#include <racccoon/syscall.h>
#include <racccoon/fs.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <dirent.h>
#include <errno.h>
#include <string.h>
#include <stdlib.h>
#include <stdarg.h>

/* --- direct-syscall bits --------------------------------------------- */

pid_t getpid(void)  { return (pid_t)__rc_syscall3(0, 0, 0, RC_SYS_GETPID); }
pid_t getppid(void) { return 0; }   /* SYS_PARENT_INFO exists; not needed yet */
int   getuid(void)  { return (int)__rc_syscall3(0, 0, 0, RC_SYS_GETUID); }

int chdir(const char *path)
{
	char ap[128];
	__rc_abspath(path, ap);
	long r = __rc_syscall3((long)ap, 0, 0, RC_SYS_CHDIR);
	if (r != 0) { errno = ENOENT; return -1; }
	return 0;
}

char *getcwd(char *buf, size_t size)
{
	int n = (int)__rc_syscall3((long)buf, (long)size, 0, RC_SYS_GETCWD);
	if (n < 0) { errno = ERANGE; return NULL; }
	if (n == 0 || buf[0] == 0) { if (size >= 2) { buf[0] = '/'; buf[1] = 0; } }
	return buf;
}

/* --- the fd table -------------------------------------------------- */

#define FD_MAX 64

enum { K_FREE = 0, K_CONSOLE, K_FILE };

struct fdent {
	int  kind;
	int  flags;
	unsigned long off;
	char path[128];
};

static struct fdent fdtab[FD_MAX];
static int fdtab_inited = 0;

static void fd_init(void)
{
	if (fdtab_inited) return;
	fdtab[0].kind = fdtab[1].kind = fdtab[2].kind = K_CONSOLE;
	fdtab_inited = 1;
}

static int fd_alloc(void)
{
	fd_init();
	for (int i = 3; i < FD_MAX; i++)
		if (fdtab[i].kind == K_FREE) return i;
	errno = EMFILE;
	return -1;
}

/* --- open / close / read / write / lseek --------------------------- */

int open(const char *path, int flags, ...)
{
	fd_init();
	(void)flags;

	char ap[128];
	__rc_abspath(path, ap);

	unsigned long size = 0;
	int type = 0;
	int exists = (__rc_fs_stat(ap, &size, &type) == 0);

	if ((flags & O_DIRECTORY) && !(exists && type == 1)) { errno = ENOTDIR; return -1; }

	if (!exists) {
		if (!(flags & O_CREAT)) { errno = ENOENT; return -1; }
		if (__rc_fs_write_at(ap, "", 0, 0) < 0) { errno = EIO; return -1; }
		size = 0;
	} else if ((flags & O_CREAT) && (flags & O_EXCL)) {
		errno = EEXIST; return -1;
	} else if ((flags & O_TRUNC) && (flags & (O_WRONLY | O_RDWR))) {
		/* fsd has no truncate primitive — delete + recreate. */
		__rc_fs_delete(ap, 0);
		if (__rc_fs_write_at(ap, "", 0, 0) < 0) { errno = EIO; return -1; }
		size = 0;
	}

	int fd = fd_alloc();
	if (fd < 0) return -1;

	fdtab[fd].kind  = K_FILE;
	fdtab[fd].flags = flags;
	fdtab[fd].off   = (flags & O_APPEND) ? size : 0;
	strncpy(fdtab[fd].path, ap, sizeof fdtab[fd].path - 1);
	fdtab[fd].path[sizeof fdtab[fd].path - 1] = 0;
	return fd;
}

int creat(const char *path, mode_t mode)
{
	(void)mode;
	return open(path, O_WRONLY | O_CREAT | O_TRUNC);
}

int close(int fd)
{
	fd_init();
	if (fd < 0 || fd >= FD_MAX || fdtab[fd].kind == K_FREE) { errno = EBADF; return -1; }
	if (fd >= 3) fdtab[fd].kind = K_FREE;   /* 0/1/2 stay open */
	return 0;
}

static ssize_t console_write(const void *buf, size_t n)
{
	const char *p = buf;
	for (size_t i = 0; i < n; i++) __rc_syscall3((long)(unsigned char)p[i], 0, 0, RC_SYS_PUTCHAR);
	return (ssize_t)n;
}

static ssize_t console_read(void *buf, size_t n)
{
	char *p = buf;
	size_t i = 0;
	for (; i < n; i++) {
		long c = __rc_syscall3(0, 0, 0, RC_SYS_GETCHAR);
		if (c < 0) break;
		p[i] = (char)c;
		if (c == '\n' || c == '\r') { i++; break; }
	}
	return (ssize_t)i;
}

ssize_t read(int fd, void *buf, size_t count)
{
	fd_init();
	if (fd < 0 || fd >= FD_MAX || fdtab[fd].kind == K_FREE) { errno = EBADF; return -1; }
	if (fdtab[fd].kind == K_CONSOLE) return console_read(buf, count);

	long got = __rc_fs_read_at(fdtab[fd].path, buf, (long)count, fdtab[fd].off);
	if (got < 0) { errno = EIO; return -1; }
	fdtab[fd].off += (unsigned long)got;
	return got;
}

ssize_t write(int fd, const void *buf, size_t count)
{
	fd_init();
	if (fd < 0 || fd >= FD_MAX || fdtab[fd].kind == K_FREE) { errno = EBADF; return -1; }
	if (fdtab[fd].kind == K_CONSOLE) return console_write(buf, count);

	const char *p = buf;
	size_t done = 0;
	while (done < count) {
		long chunk = (long)(count - done);
		if (chunk > RC_FS_WRITE_AT_MAXCHUNK) chunk = RC_FS_WRITE_AT_MAXCHUNK;
		long w = __rc_fs_write_at(fdtab[fd].path, p + done, chunk, fdtab[fd].off);
		if (w < 0) { if (done) break; errno = EIO; return -1; }
		fdtab[fd].off += (unsigned long)w;
		done += (size_t)w;
		if (w < chunk) break;
	}
	return (ssize_t)done;
}

off_t lseek(int fd, off_t offset, int whence)
{
	fd_init();
	if (fd < 0 || fd >= FD_MAX || fdtab[fd].kind != K_FILE) { errno = ESPIPE; return -1; }

	unsigned long base;
	if (whence == SEEK_SET) base = 0;
	else if (whence == SEEK_CUR) base = fdtab[fd].off;
	else if (whence == SEEK_END) {
		unsigned long size = 0;
		if (__rc_fs_stat(fdtab[fd].path, &size, NULL) != 0) { errno = EIO; return -1; }
		base = size;
	} else { errno = EINVAL; return -1; }

	long np = (long)base + (long)offset;
	if (np < 0) { errno = EINVAL; return -1; }
	fdtab[fd].off = (unsigned long)np;
	return np;
}

int dup(int fd)
{
	fd_init();
	if (fd < 0 || fd >= FD_MAX || fdtab[fd].kind == K_FREE) { errno = EBADF; return -1; }
	int nf = fd_alloc();
	if (nf < 0) return -1;
	fdtab[nf] = fdtab[fd];
	return nf;
}

int dup2(int oldfd, int newfd)
{
	fd_init();
	if (oldfd < 0 || oldfd >= FD_MAX || fdtab[oldfd].kind == K_FREE) { errno = EBADF; return -1; }
	if (newfd < 0 || newfd >= FD_MAX) { errno = EBADF; return -1; }
	if (oldfd == newfd) return newfd;
	fdtab[newfd] = fdtab[oldfd];
	return newfd;
}

int fcntl(int fd, int cmd, ...)
{
	fd_init();
	if (fd < 0 || fd >= FD_MAX || fdtab[fd].kind == K_FREE) { errno = EBADF; return -1; }
	if (cmd == F_GETFL) return fdtab[fd].flags;
	if (cmd == F_DUPFD) return dup(fd);
	return 0;   /* F_GETFD/F_SETFD/F_SETFL — accepted, no-op */
}

int isatty(int fd)
{
	fd_init();
	if (fd < 0 || fd >= FD_MAX || fdtab[fd].kind == K_FREE) { errno = EBADF; return 0; }
	if (fdtab[fd].kind != K_CONSOLE) return 0;
	if (fd == 0) return __rc_stdin_is_console();
	return 1;
}

/* --- fs metadata ops ---------------------------------------------- */

static void fill_stat(struct stat *st, unsigned long size, int type)
{
	memset(st, 0, sizeof *st);
	st->st_mode  = (type == 1) ? (S_IFDIR | 0755) : (S_IFREG | 0644);
	st->st_size  = (off_t)size;
	st->st_nlink = 1;
	st->st_blksize = 4096;
	st->st_blocks  = (blkcnt_t)((size + 511) / 512);
}

int stat(const char *path, struct stat *st)
{
	unsigned long size = 0; int type = 0;
	if (__rc_fs_stat(path, &size, &type) != 0) { errno = ENOENT; return -1; }
	fill_stat(st, size, type);
	return 0;
}

int lstat(const char *path, struct stat *st) { return stat(path, st); }

int fstat(int fd, struct stat *st)
{
	fd_init();
	if (fd < 0 || fd >= FD_MAX || fdtab[fd].kind == K_FREE) { errno = EBADF; return -1; }
	if (fdtab[fd].kind == K_CONSOLE) {
		memset(st, 0, sizeof *st);
		st->st_mode = S_IFCHR | 0666;
		return 0;
	}
	return stat(fdtab[fd].path, st);
}

int mkdir(const char *path, mode_t mode)
{
	(void)mode;
	if (__rc_fs_mkdir(path) != 0) { errno = EIO; return -1; }
	return 0;
}

mode_t umask(mode_t mask) { (void)mask; return 022; }

int unlink(const char *path)
{
	if (__rc_fs_delete(path, 0) != 0) { errno = ENOENT; return -1; }
	return 0;
}

int rmdir(const char *path)
{
	if (__rc_fs_delete(path, 0) != 0) { errno = ENOTEMPTY; return -1; }
	return 0;
}

int rename(const char *oldp, const char *newp)
{
	if (__rc_fs_rename(oldp, newp) != 0) { errno = EIO; return -1; }
	return 0;
}

int access(const char *path, int mode)
{
	(void)mode;
	unsigned long size = 0; int type = 0;
	if (__rc_fs_stat(path, &size, &type) != 0) { errno = ENOENT; return -1; }
	return 0;
}

/* --- directories ------------------------------------------------- */

struct __dir {
	int   count;
	int   pos;
	struct dirent ent;
	char  buf[1];   /* count * RC_FS_LIST_ENTRY_SIZE, over-allocated */
};

#define DIR_LIST_MAX 512

DIR *opendir(const char *path)
{
	unsigned long size = 0; int type = 0;
	if (__rc_fs_stat(path, &size, &type) != 0) { errno = ENOENT; return NULL; }
	if (type != 1) { errno = ENOTDIR; return NULL; }

	DIR *d = malloc(sizeof(struct __dir) + (size_t)DIR_LIST_MAX * RC_FS_LIST_ENTRY_SIZE);
	if (!d) { errno = ENOMEM; return NULL; }

	int n = __rc_fs_list(path, d->buf, DIR_LIST_MAX);
	if (n < 0) { free(d); errno = EIO; return NULL; }
	d->count = n;
	d->pos = 0;
	return d;
}

struct dirent *readdir(DIR *d)
{
	if (!d || d->pos >= d->count) return NULL;
	const char *rec = d->buf + (size_t)d->pos * RC_FS_LIST_ENTRY_SIZE;
	strncpy(d->ent.d_name, rec, RC_FS_LIST_NAME_MAX);
	d->ent.d_name[RC_FS_LIST_NAME_MAX] = 0;
	unsigned char t = (unsigned char)rec[RC_FS_LIST_NAME_MAX];
	d->ent.d_type = t == 1 ? DT_DIR : DT_REG;
	d->ent.d_ino = (ino_t)(d->pos + 1);
	d->pos++;
	return &d->ent;
}

void rewinddir(DIR *d) { if (d) d->pos = 0; }

int closedir(DIR *d) { free(d); return 0; }
