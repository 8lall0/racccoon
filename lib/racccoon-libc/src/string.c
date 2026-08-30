/* <string.h> — including the four the C standard requires even in a
 * freestanding build (memcpy/memmove/memset/memcmp), which gcc emits
 * calls to for struct copies and array initialisers. Straightforward,
 * not tuned — correctness first. */
#include <string.h>
#include <stdlib.h>

void *memcpy(void *dst, const void *src, size_t n)
{
	unsigned char *d = dst;
	const unsigned char *s = src;
	/* word-copy the aligned middle, byte-copy the ends */
	while (n && ((unsigned long)d & 7)) { *d++ = *s++; n--; }
	if (!((unsigned long)s & 7)) {
		while (n >= 8) {
			*(unsigned long *)d = *(const unsigned long *)s;
			d += 8; s += 8; n -= 8;
		}
	}
	while (n--) *d++ = *s++;
	return dst;
}

void *memmove(void *dst, const void *src, size_t n)
{
	unsigned char *d = dst;
	const unsigned char *s = src;
	if (d == s || n == 0) return dst;
	if (d < s) return memcpy(dst, src, n);
	d += n; s += n;
	while (n--) *--d = *--s;
	return dst;
}

void *memset(void *s, int c, size_t n)
{
	unsigned char *p = s;
	unsigned char b = (unsigned char)c;
	while (n && ((unsigned long)p & 7)) { *p++ = b; n--; }
	unsigned long w = 0x0101010101010101UL * b;
	while (n >= 8) { *(unsigned long *)p = w; p += 8; n -= 8; }
	while (n--) *p++ = b;
	return s;
}

int memcmp(const void *a, const void *b, size_t n)
{
	const unsigned char *x = a, *y = b;
	for (size_t i = 0; i < n; i++)
		if (x[i] != y[i]) return (int)x[i] - (int)y[i];
	return 0;
}

void *memchr(const void *s, int c, size_t n)
{
	const unsigned char *p = s;
	unsigned char b = (unsigned char)c;
	for (size_t i = 0; i < n; i++)
		if (p[i] == b) return (void *)(p + i);
	return NULL;
}

size_t strlen(const char *s)
{
	const char *p = s;
	while (*p) p++;
	return (size_t)(p - s);
}

int strcmp(const char *a, const char *b)
{
	while (*a && *a == *b) { a++; b++; }
	return (int)(unsigned char)*a - (int)(unsigned char)*b;
}

int strncmp(const char *a, const char *b, size_t n)
{
	for (size_t i = 0; i < n; i++) {
		unsigned char ca = (unsigned char)a[i], cb = (unsigned char)b[i];
		if (ca != cb) return (int)ca - (int)cb;
		if (ca == 0) return 0;
	}
	return 0;
}

char *strcpy(char *dst, const char *src)
{
	char *d = dst;
	while ((*d++ = *src++)) { }
	return dst;
}

char *strncpy(char *dst, const char *src, size_t n)
{
	size_t i = 0;
	for (; i < n && src[i]; i++) dst[i] = src[i];
	for (; i < n; i++) dst[i] = 0;
	return dst;
}

char *strcat(char *dst, const char *src)
{
	strcpy(dst + strlen(dst), src);
	return dst;
}

char *strncat(char *dst, const char *src, size_t n)
{
	char *d = dst + strlen(dst);
	size_t i = 0;
	for (; i < n && src[i]; i++) d[i] = src[i];
	d[i] = 0;
	return dst;
}

char *strchr(const char *s, int c)
{
	char ch = (char)c;
	for (;; s++) {
		if (*s == ch) return (char *)s;
		if (!*s) return NULL;
	}
}

char *strrchr(const char *s, int c)
{
	char ch = (char)c;
	const char *last = NULL;
	for (;; s++) {
		if (*s == ch) last = s;
		if (!*s) return (char *)last;
	}
}

char *strstr(const char *hay, const char *needle)
{
	if (!*needle) return (char *)hay;
	size_t nl = strlen(needle);
	for (; *hay; hay++)
		if (*hay == *needle && strncmp(hay, needle, nl) == 0)
			return (char *)hay;
	return NULL;
}

char *strdup(const char *s)
{
	size_t n = strlen(s) + 1;
	char *p = malloc(n);
	if (p) memcpy(p, s, n);
	return p;
}

char *strndup(const char *s, size_t max)
{
	size_t n = 0;
	while (n < max && s[n]) n++;
	char *p = malloc(n + 1);
	if (p) { memcpy(p, s, n); p[n] = 0; }
	return p;
}

size_t strnlen(const char *s, size_t max)
{
	size_t n = 0;
	while (n < max && s[n]) n++;
	return n;
}

size_t strspn(const char *s, const char *set)
{
	size_t n = 0;
	for (; s[n]; n++) if (!strchr(set, s[n])) break;
	return n;
}

size_t strcspn(const char *s, const char *set)
{
	size_t n = 0;
	for (; s[n]; n++) if (strchr(set, s[n])) break;
	return n;
}

char *strpbrk(const char *s, const char *set)
{
	for (; *s; s++) if (strchr(set, *s)) return (char *)s;
	return NULL;
}

char *strtok_r(char *s, const char *sep, char **save)
{
	if (!s) s = *save;
	if (!s) return NULL;
	s += strspn(s, sep);
	if (!*s) { *save = NULL; return NULL; }
	char *end = s + strcspn(s, sep);
	if (*end) { *end = 0; *save = end + 1; }
	else *save = NULL;
	return s;
}

char *strtok(char *s, const char *sep)
{
	static char *save;
	return strtok_r(s, sep, &save);
}

char *strsep(char **sp, const char *sep)
{
	char *s = *sp;
	if (!s) return NULL;
	char *end = s + strcspn(s, sep);
	if (*end) { *end = 0; *sp = end + 1; }
	else *sp = NULL;
	return s;
}

void *memrchr(const void *s, int c, size_t n)
{
	const unsigned char *p = (const unsigned char *)s + n;
	while (n--) if (*--p == (unsigned char)c) return (void *)p;
	return NULL;
}

void *memmem(const void *hay, size_t hn, const void *needle, size_t nn)
{
	if (nn == 0) return (void *)hay;
	if (nn > hn) return NULL;
	const char *h = hay;
	for (size_t i = 0; i + nn <= hn; i++)
		if (h[i] == *(const char *)needle && memcmp(h + i, needle, nn) == 0)
			return (void *)(h + i);
	return NULL;
}

/* --- <strings.h> --- */

static int lc(int c) { return (c >= 'A' && c <= 'Z') ? c + 32 : c; }

int strcasecmp(const char *a, const char *b)
{
	while (*a && lc((unsigned char)*a) == lc((unsigned char)*b)) { a++; b++; }
	return lc((unsigned char)*a) - lc((unsigned char)*b);
}

int strncasecmp(const char *a, const char *b, size_t n)
{
	for (; n && *a && lc((unsigned char)*a) == lc((unsigned char)*b); a++, b++, n--)
		;
	if (!n) return 0;
	return lc((unsigned char)*a) - lc((unsigned char)*b);
}

void bzero(void *s, size_t n) { memset(s, 0, n); }
void bcopy(const void *src, void *dst, size_t n) { memmove(dst, src, n); }

int ffs(int v)
{
	if (!v) return 0;
	int i = 1;
	while (!(v & 1)) { v >>= 1; i++; }
	return i;
}
