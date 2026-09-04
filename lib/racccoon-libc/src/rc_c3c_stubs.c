/* Stubs for the c3c-no-LLVM symbols that only its SDK-fetch / archive /
 * external-linker paths reference. A racccoon-hosted c3c never fetches an
 * SDK or shells out to an archiver, and (with --backend=c) drives tcc
 * itself for the compile+link, so these are dead code that just has to
 * link. Each returns "not available" / fails loudly rather than pretend.
 *
 * Real POSIX pieces c3c does use on racccoon — open_memstream, the
 * subprocess spawn for invoking tcc — live in the proper libc files. */
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <glob.h>

/* --- glob(3): c3c's linker.c globs for library files. Report no match. */
int glob(const char *p, int f, int (*e)(const char *, int), glob_t *g)
{
	(void)p; (void)f; (void)e;
	if (g) { g->gl_pathc = 0; g->gl_pathv = NULL; g->gl_offs = 0; }
	return GLOB_NOMATCH;
}
void globfree(glob_t *g) { (void)g; }

/* --- SDK fetch / archive extraction (fetch_sdk/, msi.c, unzipper.c, …) */
int  download_available(void) { return 0; }
int  download_file(const char *u, const char *d) { (void)u; (void)d; return -1; }
int  fetch_macsdk(const char *a, const char *b) { (void)a; (void)b; return -1; }
int  msi_extract(const char *a, const char *b) { (void)a; (void)b; return -1; }
int  uncompress(unsigned char *d, unsigned long *dl, const unsigned char *s, unsigned long sl)
{ (void)d; (void)dl; (void)s; (void)sl; return -1; }
void *zip_dir_iterator(const char *p) { (void)p; return NULL; }
int   zip_dir_iterator_next(void *it, char *out, size_t cap) { (void)it; (void)out; (void)cap; return 0; }
long  zip_file_read(const char *z, const char *n, unsigned char *buf, size_t cap)
{ (void)z; (void)n; (void)buf; (void)cap; return -1; }
int   zip_file_write(const char *z, const char *n, const unsigned char *buf, size_t len)
{ (void)z; (void)n; (void)buf; (void)len; return -1; }

/* --- benchmark.c (compile-timing harness; not built for racccoon) */
void bench_begin(void) {}
void bench_mark(const char *label) { (void)label; }

/* --- POSIX bits racccoon libc doesn't have yet; c3c's uses are all in
 *     error/cleanup paths that don't fire in a normal --backend=c run. */
int kill(int pid, int sig) { (void)pid; (void)sig; return -1; }
int symlink(const char *t, const char *l) { (void)t; (void)l; return -1; }
char *mkdtemp(char *tmpl) { return tmpl; } /* caller-provided template used as-is */

/* signal(2): c3c installs a SIGINT handler for Ctrl-C during a build.
 * racccoon delivers no such signal to a process — accept and ignore. */
void (*signal(int sig, void (*h)(int)))(int) { (void)sig; (void)h; return (void (*)(int))0; }
int raise(int sig) { (void)sig; return 0; }

/* popen/pclose: c3c shells out to the external linker on a full `build`.
 * `c3c compile --backend=c` (emit .c only) never reaches these. */
FILE *popen(const char *cmd, const char *mode) { (void)cmd; (void)mode; return (FILE *)0; }
int   pclose(FILE *f) { (void)f; return -1; }
