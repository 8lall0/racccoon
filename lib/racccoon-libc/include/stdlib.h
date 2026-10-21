#ifndef _STDLIB_H
#define _STDLIB_H
#ifdef __cplusplus
extern "C" {
#endif

#include <stddef.h>

/* glibc puts alloca() in <stdlib.h>'s reach; ported code expects it. */
#ifndef alloca
#define alloca(n) __builtin_alloca(n)
#endif

/* --- heap (stage 2) --- */
void *malloc(size_t size);
void *calloc(size_t nmemb, size_t size);
void *realloc(void *ptr, size_t size);
void  free(void *ptr);
int   posix_memalign(void **memptr, size_t alignment, size_t size);
int   mkstemp(char *tmpl);
char *mkdtemp(char *tmpl);
void *aligned_alloc(size_t alignment, size_t size);

/* --- process exit --- */
__attribute__((noreturn)) void _exit(int code);
__attribute__((noreturn)) void _Exit(int code);   /* C99: _exit */
__attribute__((noreturn)) void exit(int code);
__attribute__((noreturn)) void abort(void);
int atexit(void (*fn)(void));

#define EXIT_SUCCESS 0
#define EXIT_FAILURE 1

/* --- numeric conversion --- */
int            atoi(const char *s);
long           atol(const char *s);
long           strtol(const char *s, char **end, int base);
unsigned long  strtoul(const char *s, char **end, int base);
long long      strtoll(const char *s, char **end, int base);
unsigned long long strtoull(const char *s, char **end, int base);
double         strtod(const char *s, char **end);
float          strtof(const char *s, char **end);
long double    strtold(const char *s, char **end);
int            abs(int x);
long           labs(long x);
long long      llabs(long long x);

typedef struct { int quot, rem; } div_t;
typedef struct { long quot, rem; } ldiv_t;
typedef struct { long long quot, rem; } lldiv_t;
div_t          div(int num, int den);
ldiv_t         ldiv(long num, long den);
lldiv_t        lldiv(long long num, long long den);

/* multibyte: the C locale, one byte per character (src/wchar.c) */
#define MB_CUR_MAX ((size_t)1)
#ifndef __cplusplus
typedef int wchar_t;
#endif
int    mblen(const char *s, size_t n);
int    mbtowc(wchar_t *pwc, const char *s, size_t n);
int    wctomb(char *s, wchar_t wc);
size_t mbstowcs(wchar_t *d, const char *s, size_t n);
size_t wcstombs(char *d, const wchar_t *s, size_t n);
long long      atoll(const char *s);

/* --- sort / search --- */
void  qsort(void *base, size_t n, size_t size, int (*cmp)(const void *, const void *));
void *bsearch(const void *key, const void *base, size_t n, size_t size,
              int (*cmp)(const void *, const void *));

/* --- environment (rc_env.c) --- */
char *getenv(const char *name);
int   setenv(const char *name, const char *value, int overwrite);
int   unsetenv(const char *name);
int   putenv(char *string);

/* --- run a command line via the shell (rc_proc.c) --- */
int   system(const char *command);

/* --- pseudo-random --- */
#define RAND_MAX 0x7fffffff
int  rand(void);
void srand(unsigned seed);

#ifdef __cplusplus
}
#endif
#endif
