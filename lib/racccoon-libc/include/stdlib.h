#ifndef _STDLIB_H
#define _STDLIB_H

#include <stddef.h>

/* --- heap (stage 2) --- */
void *malloc(size_t size);
void *calloc(size_t nmemb, size_t size);
void *realloc(void *ptr, size_t size);
void  free(void *ptr);

/* --- process exit --- */
__attribute__((noreturn)) void _exit(int code);
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
int            abs(int x);
long           labs(long x);

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

#endif
