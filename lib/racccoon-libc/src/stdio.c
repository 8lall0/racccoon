/* Buffered stdio over the POSIX fd layer (rc_posix.c). One malloc'd
 * buffer per stream; line-buffered when the fd is a tty, fully
 * buffered otherwise; stderr is unbuffered. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>

struct __FILE {
	int   fd;
	int   rmode, wmode;       /* opened for read / write */
	int   err, eof;
	int   bufmode;            /* _IOFBF / _IOLBF / _IONBF */
	int   buf_owned;
	unsigned char *buf;
	size_t bufcap;
	size_t rpos, rlen;        /* read buffer: [rpos, rlen) valid */
	size_t wlen;              /* write buffer: [0, wlen) pending */
	long  pos;                /* logical file position (start of the read buffer / after last write) */
	int   ungot;              /* -1 = none */
	/* open_memstream(): when ms_bufp != NULL the stream writes into a
	 * caller-owned growable heap buffer instead of a fd. */
	char   **ms_bufp;
	size_t  *ms_sizep;
	size_t   ms_len, ms_cap;
};

static struct __FILE _stdin  = { 0, 1, 0, 0, 0, _IOLBF, 0, NULL, 0, 0, 0, 0, 0, -1 };
static struct __FILE _stdout = { 1, 0, 1, 0, 0, _IOLBF, 0, NULL, 0, 0, 0, 0, 0, -1 };
static struct __FILE _stderr = { 2, 0, 1, 0, 0, _IONBF, 0, NULL, 0, 0, 0, 0, 0, -1 };

FILE *stdin  = &_stdin;
FILE *stdout = &_stdout;
FILE *stderr = &_stderr;

static int ensure_buf(FILE *f)
{
	if (f->buf) return 0;
	f->buf = malloc(BUFSIZ);
	if (!f->buf) { f->err = 1; errno = ENOMEM; return -1; }
	f->bufcap = BUFSIZ;
	f->buf_owned = 1;
	return 0;
}

/* Append `n` bytes to an open_memstream buffer, keeping it NUL-terminated
 * and *ms_sizep in sync. */
static int ms_append(FILE *f, const unsigned char *src, size_t n)
{
	if (f->ms_len + n + 1 > f->ms_cap) {
		size_t nc = f->ms_cap ? f->ms_cap * 2 : 128;
		while (nc < f->ms_len + n + 1) nc *= 2;
		char *nb = realloc(*f->ms_bufp, nc);
		if (!nb) { f->err = 1; errno = ENOMEM; return EOF; }
		*f->ms_bufp = nb;
		f->ms_cap = nc;
	}
	__builtin_memcpy(*f->ms_bufp + f->ms_len, src, n);
	f->ms_len += n;
	(*f->ms_bufp)[f->ms_len] = 0;
	if (f->ms_sizep) *f->ms_sizep = f->ms_len;
	return 0;
}

static int flush_write(FILE *f)
{
	if (f->wlen == 0) return 0;
	if (f->ms_bufp) {
		if (ms_append(f, f->buf, f->wlen) == EOF) return EOF;
		f->pos += (long)f->wlen;
		f->wlen = 0;
		return 0;
	}
	size_t done = 0;
	while (done < f->wlen) {
		long w = write(f->fd, f->buf + done, f->wlen - done);
		if (w <= 0) { f->err = 1; return EOF; }
		done += (size_t)w;
	}
	f->pos += (long)f->wlen;
	f->wlen = 0;
	return 0;
}

static void drop_read(FILE *f)
{
	/* discard the read buffer, rewinding the fd to the logical pos */
	if (f->rlen > f->rpos) lseek(f->fd, f->pos + (long)f->rpos, SEEK_SET);
	f->rpos = f->rlen = 0;
}

int fflush(FILE *f)
{
	if (f == NULL) {
		int r = 0;
		if (flush_write(&_stdout) == EOF) r = EOF;
		if (flush_write(&_stderr) == EOF) r = EOF;
		return r;
	}
	return flush_write(f);
}

static int parse_mode(const char *mode, int *rd, int *wr, int *append, int *trunc)
{
	*rd = *wr = *append = *trunc = 0;
	if (*mode == 'r') { *rd = 1; }
	else if (*mode == 'w') { *wr = 1; *trunc = 1; }
	else if (*mode == 'a') { *wr = 1; *append = 1; }
	else return -1;
	for (const char *p = mode + 1; *p; p++)
		if (*p == '+') { *rd = 1; *wr = 1; }
	return 0;
}

FILE *fdopen(int fd, const char *mode)
{
	int rd, wr, ap, tr;
	if (parse_mode(mode, &rd, &wr, &ap, &tr) < 0) { errno = EINVAL; return NULL; }
	FILE *f = calloc(1, sizeof *f);
	if (!f) { errno = ENOMEM; return NULL; }
	f->fd = fd;
	f->rmode = rd; f->wmode = wr;
	f->bufmode = isatty(fd) ? _IOLBF : _IOFBF;
	f->ungot = -1;
	return f;
}

/* POSIX open_memstream: a write-only stream backed by a heap buffer the
 * libc grows; *bufp / *sizep are updated on every fflush and on fclose,
 * and *bufp stays NUL-terminated. The caller frees *bufp. */
FILE *open_memstream(char **bufp, size_t *sizep)
{
	if (!bufp || !sizep) { errno = EINVAL; return NULL; }
	FILE *f = calloc(1, sizeof *f);
	if (!f) { errno = ENOMEM; return NULL; }
	*bufp = malloc(1);
	if (!*bufp) { free(f); errno = ENOMEM; return NULL; }
	(*bufp)[0] = 0;
	*sizep = 0;
	f->fd = -1;
	f->wmode = 1;
	f->bufmode = _IOFBF;
	f->ungot = -1;
	f->ms_bufp = bufp;
	f->ms_sizep = sizep;
	f->ms_cap = 1;
	return f;
}

FILE *fopen(const char *path, const char *mode)
{
	int rd, wr, ap, tr;
	if (parse_mode(mode, &rd, &wr, &ap, &tr) < 0) { errno = EINVAL; return NULL; }

	int fl;
	if (rd && wr) fl = O_RDWR;
	else if (wr) fl = O_WRONLY;
	else fl = O_RDONLY;
	if (wr) fl |= O_CREAT;
	if (tr) fl |= O_TRUNC;
	if (ap) fl |= O_APPEND;

	int fd = open(path, fl);
	if (fd < 0) return NULL;

	FILE *f = fdopen(fd, mode);
	if (!f) { close(fd); return NULL; }
	f->buf_owned = 0;   /* re-set by fdopen path; keep consistent */
	return f;
}

FILE *freopen(const char *path, const char *mode, FILE *f)
{
	if (!f) return NULL;
	fflush(f);
	if (f->fd > 2) close(f->fd);
	int rd, wr, ap, tr;
	if (parse_mode(mode, &rd, &wr, &ap, &tr) < 0) { errno = EINVAL; return NULL; }
	int fl = rd && wr ? O_RDWR : wr ? O_WRONLY : O_RDONLY;
	if (wr) fl |= O_CREAT;
	if (tr) fl |= O_TRUNC;
	if (ap) fl |= O_APPEND;
	int fd = open(path, fl);
	if (fd < 0) return NULL;
	f->fd = fd; f->rmode = rd; f->wmode = wr;
	f->err = f->eof = 0; f->rpos = f->rlen = f->wlen = 0; f->pos = 0; f->ungot = -1;
	return f;
}

int fclose(FILE *f)
{
	if (!f) return EOF;
	int r = flush_write(f);
	if (f->fd > 2) { if (close(f->fd) != 0) r = EOF; }
	if (f->buf && f->buf_owned) free(f->buf);
	if (f != &_stdin && f != &_stdout && f != &_stderr) free(f);
	return r;
}

/* --- input --- */

static int refill(FILE *f)
{
	if (f->wlen) flush_write(f);
	if (ensure_buf(f) < 0) return EOF;
	f->pos += (long)f->rlen;         /* advance past what we've consumed */
	f->rpos = f->rlen = 0;
	long n = read(f->fd, f->buf, f->bufcap);
	if (n <= 0) { if (n == 0) f->eof = 1; else f->err = 1; return EOF; }
	f->rlen = (size_t)n;
	return 0;
}

int fgetc(FILE *f)
{
	if (f->ungot >= 0) { int c = f->ungot; f->ungot = -1; return c; }
	if (f->rpos >= f->rlen && refill(f) == EOF) return EOF;
	return f->buf[f->rpos++];
}
int getc(FILE *f) { return fgetc(f); }
int getchar(void) { return fgetc(stdin); }

int ungetc(int c, FILE *f)
{
	if (c == EOF || f->ungot >= 0) return EOF;
	f->ungot = c & 0xff;
	f->eof = 0;
	return c & 0xff;
}

char *fgets(char *s, int n, FILE *f)
{
	if (n <= 0) return NULL;
	int i = 0;
	while (i < n - 1) {
		int c = fgetc(f);
		if (c == EOF) { if (i == 0) return NULL; break; }
		s[i++] = (char)c;
		if (c == '\n') break;
	}
	s[i] = 0;
	return s;
}

size_t fread(void *ptr, size_t size, size_t nmemb, FILE *f)
{
	if (size == 0 || nmemb == 0) return 0;
	unsigned char *p = ptr;
	size_t total = size * nmemb, got = 0;
	while (got < total) {
		int c = fgetc(f);
		if (c == EOF) break;
		p[got++] = (unsigned char)c;
	}
	return got / size;
}

/* --- output --- */

int fputc(int c, FILE *f)
{
	if (f->rlen > f->rpos || f->ungot >= 0) drop_read(f), f->ungot = -1;
	if (f->bufmode == _IONBF) {
		unsigned char b = (unsigned char)c;
		if (write(f->fd, &b, 1) != 1) { f->err = 1; return EOF; }
		f->pos++;
		return b;
	}
	if (ensure_buf(f) < 0) return EOF;
	f->buf[f->wlen++] = (unsigned char)c;
	if (f->wlen == f->bufcap || (f->bufmode == _IOLBF && c == '\n'))
		if (flush_write(f) == EOF) return EOF;
	return (unsigned char)c;
}
int putc(int c, FILE *f) { return fputc(c, f); }
int putchar(int c) { return fputc(c, stdout); }

int fputs(const char *s, FILE *f)
{
	while (*s) if (fputc(*s++, f) == EOF) return EOF;
	return 0;
}
int puts(const char *s)
{
	if (fputs(s, stdout) == EOF) return EOF;
	return fputc('\n', stdout) == EOF ? EOF : 0;
}

size_t fwrite(const void *ptr, size_t size, size_t nmemb, FILE *f)
{
	if (size == 0 || nmemb == 0) return 0;
	const unsigned char *p = ptr;
	size_t total = size * nmemb, put = 0;
	while (put < total) {
		if (fputc(p[put], f) == EOF) break;
		put++;
	}
	return put / size;
}

/* --- positioning --- */

int fseek(FILE *f, long off, int whence)
{
	if (flush_write(f) == EOF) return -1;
	f->ungot = -1;
	f->rpos = f->rlen = 0;
	long np = lseek(f->fd, off, whence);
	if (np < 0) return -1;
	f->pos = np;
	f->eof = 0;
	return 0;
}

long ftell(FILE *f)
{
	if (f->wlen) return f->pos + (long)f->wlen;
	return f->pos + (long)f->rpos;
}
void rewind(FILE *f) { fseek(f, 0, SEEK_SET); f->err = 0; }
int  fgetpos(FILE *f, fpos_t *pos) { long t = ftell(f); if (t < 0) return -1; *pos = t; return 0; }
int  fsetpos(FILE *f, const fpos_t *pos) { return fseek(f, (long)*pos, SEEK_SET); }

int  feof(FILE *f)   { return f->eof; }
int  ferror(FILE *f) { return f->err; }
void clearerr(FILE *f) { f->err = f->eof = 0; }
int  fileno(FILE *f) { return f->fd; }

int setvbuf(FILE *f, char *buf, int mode, size_t size)
{
	fflush(f);
	if (f->buf && f->buf_owned) free(f->buf);
	f->buf = (unsigned char *)buf;
	f->buf_owned = 0;
	f->bufcap = size ? size : BUFSIZ;
	f->bufmode = mode;
	if (!buf && mode != _IONBF) { f->buf = NULL; }   /* lazily malloc'd */
	return 0;
}
void setbuf(FILE *f, char *buf) { setvbuf(f, buf, buf ? _IOFBF : _IONBF, BUFSIZ); }

/* --- misc --- */

void perror(const char *s)
{
	if (s && *s) { fputs(s, stderr); fputs(": ", stderr); }
	/* no strerror table yet — just the number */
	extern int errno;
	char b[16]; int i = 16, e = errno;
	if (e < 0) { fputc('-', stderr); e = -e; }
	if (e == 0) b[--i] = '0';
	while (e) { b[--i] = '0' + e % 10; e /= 10; }
	fwrite(b + i, 1, 16 - i, stderr);
	fputc('\n', stderr);
}

int remove(const char *path) { return unlink(path); }

static unsigned __tmp_ctr = 0;
char *tmpnam(char *s)
{
	static char stat_buf[L_tmpnam];
	if (!s) s = stat_buf;
	unsigned id = ((unsigned)getpid() << 8) ^ (++__tmp_ctr) ^ (unsigned)__rc_timebase_hz();
	char *p = s;
	const char *pre = "/tmp/t";
	while (*pre) *p++ = *pre++;
	for (int i = 28; i >= 0; i -= 4) *p++ = "0123456789abcdef"[(id >> i) & 0xf];
	*p = 0;
	return s;
}
FILE *tmpfile(void)
{
	char nm[L_tmpnam];
	tmpnam(nm);
	return fopen(nm, "w+");
}

ssize_t getdelim(char **lineptr, size_t *n, int delim, FILE *f)
{
	if (!lineptr || !n) { errno = EINVAL; return -1; }
	if (!*lineptr || *n == 0) { *n = 128; *lineptr = malloc(*n); if (!*lineptr) return -1; }
	size_t len = 0;
	for (;;) {
		int c = fgetc(f);
		if (c == EOF) { if (len == 0) return -1; break; }
		if (len + 2 > *n) {
			size_t nn = *n * 2;
			char *np = realloc(*lineptr, nn);
			if (!np) return -1;
			*lineptr = np; *n = nn;
		}
		(*lineptr)[len++] = (char)c;
		if (c == delim) break;
	}
	(*lineptr)[len] = 0;
	return (ssize_t)len;
}
ssize_t getline(char **lp, size_t *n, FILE *f) { return getdelim(lp, n, '\n', f); }
