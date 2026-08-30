/* The process layer: fork / exec* / wait* / mmap, mapped onto
 * racccoon's SYS_RFORK, SYS_EXEC, SYS_JOIN and SYS_MAP.
 *
 * fork()   -> rfork(RFPROC): a real address-space copy, child gets 0.
 * execve() -> read the whole image through fsd, pack argv (+ envp) into
 *             the blob the crt0 (src/start.c) expects, one SYS_EXEC.
 * waitpid()-> SYS_JOIN on a (pid, generation) this libc recorded at
 *             fork() time. No "any child" primitive: wait() / waitpid(-1)
 *             join the oldest outstanding child. WNOHANG is not honoured.
 * mmap(MAP_ANONYMOUS) -> SYS_MAP; munmap / mprotect are no-ops. */
#include <racccoon/syscall.h>
#include <racccoon/fs.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/mman.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <stdlib.h>
#include <stdarg.h>

extern char **environ;

/* kernel limits — keep in sync with src/entry.c3 (EXEC_MAX_IMAGE_SIZE /
 * EXEC_MAX_ARGV_SIZE) */
#define RC_EXEC_IMAGE_MAX 1048576
#define RC_EXEC_BLOB_MAX  16384
#define RC_READ_CHUNK     (RC_FS_MSG_MAX - 4)

#define LIBC_ARGV0_MARK 0x01
#define LIBC_ENV_MARK   0x02

/* --- the child table (for waitpid) --------------------------------- */

#define RC_CHILD_MAX 32

static struct { int pid; unsigned gen; } rc_children[RC_CHILD_MAX];
static int rc_nchild = 0;

static void child_add(int pid, unsigned gen)
{
	if (rc_nchild < RC_CHILD_MAX) {
		rc_children[rc_nchild].pid = pid;
		rc_children[rc_nchild].gen = gen;
		rc_nchild++;
	}
}

/* --- fork -------------------------------------------------------- */

pid_t fork(void)
{
	unsigned gen = 0;
	long r = __rc_syscall3(RC_RFPROC, (long)&gen, 0, RC_SYS_RFORK);
	if (r < 0) { errno = EAGAIN; return -1; }
	if (r == 0) { rc_nchild = 0; return 0; }   /* child: not its parent's children */
	child_add((int)r, gen);
	return (pid_t)r;
}

/* --- exec ------------------------------------------------------- */

/* Read the whole file at `path` into a fresh buffer with RC_EXEC_BLOB_MAX
 * bytes of slack after it. *size_out gets the image length. NULL / errno
 * on failure. */
static char *load_image(const char *path, unsigned *size_out)
{
	unsigned long fsize = 0;
	int type = 0;
	if (__rc_fs_stat(path, &fsize, &type) != 0) { errno = ENOENT; return NULL; }
	if (type == 1) { errno = EACCES; return NULL; }          /* a directory */
	if (fsize == 0 || fsize > RC_EXEC_IMAGE_MAX) { errno = ENOEXEC; return NULL; }

	char *buf = malloc((size_t)fsize + RC_EXEC_BLOB_MAX + 16);
	if (!buf) { errno = ENOMEM; return NULL; }

	unsigned total = 0;
	while (total < fsize) {
		long want = (long)(fsize - total);
		if (want > RC_READ_CHUNK) want = RC_READ_CHUNK;
		long got = __rc_fs_read_at(path, buf + total, want, total);
		if (got < 0) { free(buf); errno = EIO; return NULL; }
		if (got == 0) break;
		total += (unsigned)got;
	}
	if (total == 0) { free(buf); errno = ENOEXEC; return NULL; }

	*size_out = total;
	return buf;
}

static int argv_len(char *const v[])
{
	int n = 0;
	if (v) while (v[n]) n++;
	return n;
}

/* Append `s` + its NUL at buf[*off], bounded by cap. -1 on overflow. */
static int blob_put(char *buf, unsigned *off, unsigned cap, const char *s)
{
	unsigned o = *off;
	for (; *s; s++) {
		if (o >= cap) return -1;
		buf[o++] = *s;
	}
	if (o >= cap) return -1;
	buf[o++] = 0;
	*off = o;
	return 0;
}

int execve(const char *path, char *const argv[], char *const envp[])
{
	unsigned image = 0;
	char *buf = load_image(path, &image);
	if (!buf) return -1;

	int ac = argv_len(argv);

	unsigned bo = 0;
	char *blob = buf + image;
	blob[bo++] = LIBC_ARGV0_MARK;
	for (int i = 0; i < ac; i++)
		if (blob_put(blob, &bo, RC_EXEC_BLOB_MAX, argv[i]) != 0) {
			free(buf); errno = E2BIG; return -1;
		}

	if (envp && envp[0]) {
		if (bo >= RC_EXEC_BLOB_MAX) { free(buf); errno = E2BIG; return -1; }
		blob[bo++] = LIBC_ENV_MARK;
		for (int i = 0; envp[i]; i++)
			if (blob_put(blob, &bo, RC_EXEC_BLOB_MAX, envp[i]) != 0) {
				free(buf); errno = E2BIG; return -1;
			}
		if (bo >= RC_EXEC_BLOB_MAX) { free(buf); errno = E2BIG; return -1; }
		blob[bo++] = 0;   /* empty string terminates the env list */
	}

	__rc_syscall4((long)buf, (long)image, (long)bo, (long)ac, RC_SYS_EXEC);

	/* only ever returns on failure */
	free(buf);
	errno = ENOEXEC;
	return -1;
}

int execv(const char *path, char *const argv[])
{
	return execve(path, argv, environ);
}

/* Build "dir" + "/" + "name" into out (cap bytes). dir may or may not
 * already end in '/'. Returns 0, or -1 if the result would not fit. */
static int join_path(char *out, size_t cap, const char *dir, size_t dirlen, const char *name)
{
	size_t o = 0;
	for (size_t i = 0; i < dirlen; i++) {
		if (o >= cap - 1) return -1;
		out[o++] = dir[i];
	}
	if (o == 0 || out[o - 1] != '/') {
		if (o >= cap - 1) return -1;
		out[o++] = '/';
	}
	for (size_t i = 0; name[i]; i++) {
		if (o >= cap - 1) return -1;
		out[o++] = name[i];
	}
	out[o] = 0;
	return 0;
}

int execvp(const char *file, char *const argv[])
{
	if (strchr(file, '/'))
		return execve(file, argv, environ);

	char pathvar[256];
	long n = __rc_fs_read("/env/PATH", pathvar, (long)sizeof pathvar - 1);
	const char *search;
	if (n <= 0) search = "/bin/:bin/";
	else { pathvar[n] = 0; search = pathvar; }

	char candidate[256];
	size_t start = 0;
	for (;;) {
		size_t i = start;
		while (search[i] && search[i] != ':') i++;
		if (i > start) {
			if (join_path(candidate, sizeof candidate, search + start, i - start, file) == 0)
				execve(candidate, argv, environ);   /* returns only on failure */
		}
		if (!search[i]) break;
		start = i + 1;
	}
	errno = ENOENT;
	return -1;
}

static int exec_varargs(const char *path, const char *arg0, va_list ap, int use_path)
{
	char *av[128];
	int n = 0;
	av[n++] = (char *)arg0;
	while (n < 127) {
		char *a = va_arg(ap, char *);
		av[n++] = a;
		if (!a) break;
	}
	av[127] = 0;
	return use_path ? execvp(path, av) : execve(path, av, environ);
}

int execl(const char *path, const char *arg, ...)
{
	va_list ap; va_start(ap, arg);
	int r = exec_varargs(path, arg, ap, 0);
	va_end(ap);
	return r;
}

int execlp(const char *file, const char *arg, ...)
{
	va_list ap; va_start(ap, arg);
	int r = exec_varargs(file, arg, ap, 1);
	va_end(ap);
	return r;
}

/* --- wait ----------------------------------------------------- */

pid_t waitpid(pid_t pid, int *status, int options)
{
	(void)options;
	if (rc_nchild == 0) { errno = ECHILD; return -1; }

	int idx = 0;
	if (pid > 0) {
		idx = -1;
		for (int i = 0; i < rc_nchild; i++)
			if (rc_children[i].pid == (int)pid) { idx = i; break; }
		if (idx < 0) { errno = ECHILD; return -1; }
	}

	int cpid = rc_children[idx].pid;
	unsigned cgen = rc_children[idx].gen;
	long code = __rc_syscall3(cpid, (long)cgen, 0, RC_SYS_JOIN);

	for (int i = idx; i < rc_nchild - 1; i++) rc_children[i] = rc_children[i + 1];
	rc_nchild--;

	if (status) *status = ((int)code & 0xff) << 8;
	return cpid;
}

pid_t wait(int *status)
{
	return waitpid(-1, status, 0);
}

/* --- system ------------------------------------------------- */

int system(const char *command)
{
	if (!command) return 0;   /* no command processor on racccoon */

	pid_t pid = fork();
	if (pid < 0) return -1;
	if (pid == 0) {
		char *av[] = { "sh", "-c", (char *)command, 0 };
		execvp("sh", av);
		_exit(127);
	}
	int st = 0;
	if (waitpid(pid, &st, 0) < 0) return -1;
	return st;
}

/* --- mmap ------------------------------------------------- */

void *mmap(void *addr, size_t length, int prot, int flags, int fd, off_t offset)
{
	(void)addr; (void)prot; (void)offset;
	if (fd != -1 || !(flags & MAP_ANONYMOUS)) { errno = ENOSYS; return MAP_FAILED; }
	if (length == 0) { errno = EINVAL; return MAP_FAILED; }
	void *p = __rc_map_pages(length);
	if (!p) { errno = ENOMEM; return MAP_FAILED; }
	return p;
}

int munmap(void *addr, size_t length)  { (void)addr; (void)length; return 0; }
int mprotect(void *addr, size_t length, int prot) { (void)addr; (void)length; (void)prot; return 0; }
