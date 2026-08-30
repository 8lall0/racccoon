#ifndef _STRINGS_H
#define _STRINGS_H

#include <stddef.h>

int   strcasecmp(const char *a, const char *b);
int   strncasecmp(const char *a, const char *b, size_t n);
void  bzero(void *s, size_t n);
void  bcopy(const void *src, void *dst, size_t n);
int   ffs(int v);

#endif
