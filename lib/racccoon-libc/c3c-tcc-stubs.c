/* Stubs for the parked tcc-built c3c (docs/devlog.md, 2026-09-04), which
 * compiled only 85 of c3c's 92 .c files: the SDK-fetch / archive / bench
 * symbols the rest reference. Link this file into that build. NOT part of
 * libracccoon.a — the LLVM-built c3c (build_c3c.sh) has the real ones. */
#include <stddef.h>

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

