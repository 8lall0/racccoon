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
#include <limits.h>

/* --- direct-syscall bits --------------------------------------------- */

pid_t getpid(void)  { return (pid_t)__rc_syscall3(0, 0, 0, RC_SYS_GETPID); }
pid_t getppid(void)
{
	long r = __rc_syscall3((long)getpid(), 0, 0, RC_SYS_PARENT_INFO);
	return r < 0 ? 0 : (pid_t)r;
}
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

enum { K_FREE = 0, K_CONSOLE, K_FILE, K_NET };   /* K_NET: a /net conversation (rc_socket.c) */

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

/* Hooks for rc_socket.c, which keeps a socket's /net conversation
 * directory ("/net/tcp/3") in the fd's path, its flags in flags and its
 * bound port in off. */
ssize_t __rc_net_read(int fd, void *buf, size_t n);
ssize_t __rc_net_write(int fd, const void *buf, size_t n);
void    __rc_net_close(int fd);

static int fd_alloc(void);

int __rc_fd_new_net(const char *dir, int flags)
{
	int fd = fd_alloc();
	if (fd < 0) return -1;
	fdtab[fd].kind = K_NET;
	fdtab[fd].flags = flags;
	fdtab[fd].off = 0;
	int i = 0;
	for (; dir[i] && i < 127; i++) fdtab[fd].path[i] = dir[i];
	fdtab[fd].path[i] = 0;
	return fd;
}

/* The conversation directory of socket `fd`, or NULL if it isn't one. */
char *__rc_fd_net_dir(int fd, int **flags, unsigned long **port)
{
	fd_init();
	if (fd < 0 || fd >= FD_MAX || fdtab[fd].kind != K_NET) return NULL;
	if (flags) *flags = &fdtab[fd].flags;
	if (port) *port = &fdtab[fd].off;
	return fdtab[fd].path;
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
	if (fdtab[fd].kind == K_NET) __rc_net_close(fd);
	if (fd >= 3) fdtab[fd].kind = K_FREE;   /* 0/1/2 stay open */
	return 0;
}

static ssize_t console_write(const void *buf, size_t n)
{
	if (n == 0) return 0;
	long r = __rc_syscall3((long)buf, (long)n, 0, RC_SYS_WRITE);
	return r < 0 ? -1 : (ssize_t)r;
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
	if (fdtab[fd].kind == K_NET) return __rc_net_read(fd, buf, count);

	/* fsd returns at most ~1 KiB per IPC — loop so a regular-file read()
	 * fills the caller's buffer (short only at EOF), which is what
	 * almost all callers expect. */
	char *p = buf;
	size_t done = 0;
	while (done < count) {
		long got = __rc_fs_read_at(fdtab[fd].path, p + done, (long)(count - done), fdtab[fd].off);
		if (got < 0) { if (done) break; errno = EIO; return -1; }
		if (got == 0) break;
		fdtab[fd].off += (unsigned long)got;
		done += (size_t)got;
	}
	return (ssize_t)done;
}

ssize_t write(int fd, const void *buf, size_t count)
{
	fd_init();
	if (fd < 0 || fd >= FD_MAX || fdtab[fd].kind == K_FREE) { errno = EBADF; return -1; }
	if (fdtab[fd].kind == K_CONSOLE) return console_write(buf, count);
	if (fdtab[fd].kind == K_NET) return __rc_net_write(fd, buf, count);

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
	if (cmd == F_GETLK) {
		va_list ap;
		va_start(ap, cmd);
		struct flock *fl = va_arg(ap, struct flock *);
		va_end(ap);
		fl->l_type = F_UNLCK;
		return 0;
	}
	return 0;   /* F_GETFD/F_SETFD/F_SETFL/F_SETLK(W) — accepted, no-op */
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

/* --- odds and ends the ported tools reach for ------------------- */

/* No symlinks on racccoon — realpath() is just cwd-relative -> absolute
 * plus a copy. resolved may be NULL (malloc a PATH_MAX buffer). */
char *realpath(const char *path, char *resolved)
{
	char tmp[128];
	__rc_abspath(path, tmp);

	unsigned long size = 0; int type = 0;
	if (__rc_fs_stat(tmp, &size, &type) != 0) { errno = ENOENT; return NULL; }

	if (!resolved) {
		resolved = malloc(128);
		if (!resolved) { errno = ENOMEM; return NULL; }
	}
	strcpy(resolved, tmp);
	return resolved;
}

/* fsd carries no mode bits — accept and ignore. */
int chmod(const char *path, mode_t mode) { (void)path; (void)mode; return 0; }

/* fsd has no truncate primitive. length 0 is the common case (rewrite a
 * file from scratch) — delete + recreate. Non-zero is best-effort no-op. */
/* The FS protocol has no truncate: growing appends zeros; shrinking
 * keeps the first `length` bytes by reading them, recreating the file
 * empty and writing them back. The fd's offset is left alone. */
int ftruncate(int fd, off_t length)
{
	fd_init();
	if (fd < 0 || fd >= FD_MAX || fdtab[fd].kind != K_FILE) { errno = EBADF; return -1; }
	if (length < 0) { errno = EINVAL; return -1; }
	const char *path = fdtab[fd].path;
	unsigned long size = 0;
	int type = 0;
	if (__rc_fs_stat(path, &size, &type) != 0) { errno = EIO; return -1; }
	unsigned long want = (unsigned long)length;
	if (want == size) return 0;
	if (want > size) {
		static const char zeros[1024];
		while (size < want) {
			long n = want - size > sizeof zeros ? (long)sizeof zeros : (long)(want - size);
			if (__rc_fs_write_at(path, zeros, n, size) != n) { errno = EIO; return -1; }
			size += (unsigned long)n;
		}
		return 0;
	}
	char *keep = want ? malloc(want) : 0;
	if (want && !keep) { errno = ENOMEM; return -1; }
	unsigned long got = 0;
	while (got < want) {
		long n = __rc_fs_read_at(path, keep + got, (long)(want - got), got);
		if (n <= 0) { free(keep); errno = EIO; return -1; }
		got += (unsigned long)n;
	}
	__rc_fs_delete(path, 0);
	long w = __rc_fs_write_at(path, want ? keep : "", (long)want, 0);
	free(keep);
	if (w != (long)want) { errno = EIO; return -1; }
	return 0;
}

int pipe(int fds[2]) { (void)fds; errno = ENOSYS; return -1; }

long sysconf(int name)
{
	switch (name) {
	case _SC_PAGESIZE:          return 4096;
	case _SC_NPROCESSORS_ONLN:  return 1;
	case _SC_CLK_TCK:           return 1000000;
	case _SC_OPEN_MAX:          return FD_MAX;
	case _SC_GETPW_R_SIZE_MAX:  return 1024;
	case _SC_ARG_MAX:           return _POSIX_ARG_MAX;   /* conservative: the exec argv blob shares a 8 KiB IPC message */
	default:                    return -1;
	}
}

int getpagesize(void) { return 4096; }

/* No scheduler sleep primitive exposed to userspace yet — spin on the
 * `time` CSR. Coarse, but sleep() is only ever a politeness call here. */
unsigned sleep(unsigned sec)  { usleep(sec * 1000000u); return 0; }

int usleep(unsigned usec)
{
	unsigned long hz = __rc_timebase_hz();
	if (hz == 0) return 0;
	unsigned long ticks = ((unsigned long)usec * hz) / 1000000UL;
	unsigned long start, now;
	__asm__ volatile ("rdtime %0" : "=r"(start));
	do { __asm__ volatile ("rdtime %0" : "=r"(now)); } while (now - start < ticks);
	return 0;
}

/* --- poll(2), on SYS_AWAIT ------------------------------------------- */
#include <poll.h>

#define RC_AW_STDIN 2
#define RC_AW_NOTE  8

unsigned long __rc_timebase_hz(void);

static int poll_scan(struct pollfd *fds, nfds_t n, int stdin_ready, int *want_stdin)
{
	int count = 0;
	*want_stdin = 0;
	for (nfds_t i = 0; i < n; i++) {
		struct pollfd *p = &fds[i];
		p->revents = 0;
		if (p->fd < 0) continue;
		if (p->fd >= FD_MAX || fdtab[p->fd].kind == K_FREE) { p->revents = POLLNVAL; count++; continue; }
		if (fdtab[p->fd].kind == K_FILE || fdtab[p->fd].kind == K_NET) {
			/* A socket counts as ready: ipd can't be waited on alongside
			 * stdin, and a socket read blocks only until data arrives. */
			p->revents = p->events & (POLLIN | POLLOUT);
		} else {                                   /* the console fds */
			p->revents = p->events & POLLOUT;
			if (p->fd == 0 && (p->events & POLLIN)) {
				if (stdin_ready) p->revents |= POLLIN; else *want_stdin = 1;
			}
		}
		if (p->revents) count++;
	}
	return count;
}

int poll(struct pollfd *fds, nfds_t nfds, int timeout_ms)
{
	fd_init();
	int want_stdin;
	int n = poll_scan(fds, nfds, 0, &want_stdin);
	if (n > 0 || (!want_stdin && timeout_ms == 0)) return n;
	/* Nothing ready yet: only stdin can become ready (or the timeout).
	 * timeout 0 = just look (1 tick), < 0 = forever (no timeout). */
	unsigned long ticks = 0;
	if (timeout_ms == 0) ticks = 1;
	else if (timeout_ms > 0) ticks = __rc_timebase_hz() / 1000 * (unsigned long)timeout_ms + 1;
	long r = __rc_syscall5(want_stdin ? RC_AW_STDIN : 0, (long)ticks, 0, 0, 0, RC_SYS_AWAIT);
	if (r < 0) { errno = EINVAL; return -1; }
	if (r & RC_AW_NOTE) { errno = EINTR; return -1; }
	return poll_scan(fds, nfds, (r & RC_AW_STDIN) != 0, &want_stdin);
}

/* pread / pwrite: the same transfer at an explicit offset; the fd's own
 * offset is left alone. */
ssize_t pread(int fd, void *buf, size_t count, off_t off)
{
	fd_init();
	if (fd < 0 || fd >= FD_MAX || fdtab[fd].kind != K_FILE) { errno = fd >= 0 && fd < FD_MAX && fdtab[fd].kind != K_FREE ? ESPIPE : EBADF; return -1; }
	if (off < 0) { errno = EINVAL; return -1; }
	unsigned long save = fdtab[fd].off;
	fdtab[fd].off = (unsigned long)off;
	ssize_t r = read(fd, buf, count);
	fdtab[fd].off = save;
	return r;
}

ssize_t pwrite(int fd, const void *buf, size_t count, off_t off)
{
	fd_init();
	if (fd < 0 || fd >= FD_MAX || fdtab[fd].kind != K_FILE) { errno = fd >= 0 && fd < FD_MAX && fdtab[fd].kind != K_FREE ? ESPIPE : EBADF; return -1; }
	if (off < 0) { errno = EINVAL; return -1; }
	unsigned long save = fdtab[fd].off;
	fdtab[fd].off = (unsigned long)off;
	ssize_t r = write(fd, buf, count);
	fdtab[fd].off = save;
	return r;
}

int fchmod(int fd, mode_t mode)
{
	fd_init();
	if (fd < 0 || fd >= FD_MAX || fdtab[fd].kind != K_FILE) { errno = EBADF; return -1; }
	return chmod(fdtab[fd].path, mode);
}

/* Every write already went to fsd. */
int fsync(int fd) { (void)fd; return 0; }
int fdatasync(int fd) { (void)fd; return 0; }

/* racccoon's filesystems have no symbolic or extra hard links. */
ssize_t readlink(const char *path, char *buf, size_t n)
{
	(void)buf; (void)n;
	struct stat st;
	if (stat(path, &st) != 0) return -1;
	errno = EINVAL;   /* exists, and isn't a symlink */
	return -1;
}
int symlink(const char *target, const char *path) { (void)target; (void)path; errno = EPERM; return -1; }
int link(const char *oldp, const char *newp) { (void)oldp; (void)newp; errno = EPERM; return -1; }

/* Ownership can't be changed through this library (the FS protocol's
 * chown is root-only and not wired up here): only a no-op request
 * (both ids -1) succeeds. */
int chown(const char *path, uid_t uid, gid_t gid)
{
	struct stat st;
	if (stat(path, &st) != 0) return -1;
	if (uid == (uid_t)-1 && gid == (gid_t)-1) return 0;
	errno = EPERM;
	return -1;
}
int lchown(const char *path, uid_t uid, gid_t gid) { return chown(path, uid, gid); }
int fchown(int fd, uid_t uid, gid_t gid)
{
	fd_init();
	if (fd < 0 || fd >= FD_MAX || fdtab[fd].kind != K_FILE) { errno = EBADF; return -1; }
	return chown(fdtab[fd].path, uid, gid);
}
