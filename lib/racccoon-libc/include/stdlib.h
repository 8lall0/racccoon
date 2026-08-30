#ifndef _STDLIB_H
#define _STDLIB_H

#include <stddef.h>

/* --- heap (stage 2) --- */
void *malloc(size_t size);
void *calloc(size_t nmemb, size_t size);
void *realloc(void *ptr, size_t size);
void  free(void *ptr);

/* --- process exit (more of stdlib.h fills in at stage 3) --- */
__attribute__((noreturn)) void _exit(int code);
__attribute__((noreturn)) void exit(int code);
__attribute__((noreturn)) void abort(void);

#define EXIT_SUCCESS 0
#define EXIT_FAILURE 1

#endif
