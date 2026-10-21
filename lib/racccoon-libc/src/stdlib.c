#include <stdlib.h>
#include <ctype.h>
#include <errno.h>
#include <string.h>

/* --- numeric conversion ------------------------------------------- */

static int digit_val(int c)
{
	if (c >= '0' && c <= '9') return c - '0';
	if (c >= 'a' && c <= 'z') return c - 'a' + 10;
	if (c >= 'A' && c <= 'Z') return c - 'A' + 10;
	return 99;
}

unsigned long long strtoull(const char *s, char **end, int base)
{
	const char *p = s;
	while (isspace((unsigned char)*p)) p++;

	int neg = 0;
	if (*p == '+' || *p == '-') neg = (*p++ == '-');

	if ((base == 0 || base == 16) && p[0] == '0' && (p[1] == 'x' || p[1] == 'X')
	    && digit_val(p[2]) < 16) {
		p += 2;
		base = 16;
	} else if (base == 0 && p[0] == '0') {
		base = 8;
	} else if (base == 0) {
		base = 10;
	}

	unsigned long long acc = 0;
	int any = 0;
	for (;; p++) {
		int d = digit_val((unsigned char)*p);
		if (d >= base) break;
		acc = acc * (unsigned)base + (unsigned)d;
		any = 1;
	}

	if (end) *end = (char *)(any ? p : s);
	return neg ? (unsigned long long)(-(long long)acc) : acc;
}

long long strtoll(const char *s, char **end, int base)
{
	return (long long)strtoull(s, end, base);
}

unsigned long strtoul(const char *s, char **end, int base)
{
	return (unsigned long)strtoull(s, end, base);
}

long strtol(const char *s, char **end, int base)
{
	return (long)strtoull(s, end, base);
}

int       atoi(const char *s) { return (int)strtol(s, NULL, 10); }
long      atol(const char *s) { return strtol(s, NULL, 10); }
long long atoll(const char *s) { return strtoll(s, NULL, 10); }

/* strtod / strtof / strtold: src/floatscan.c (musl's, correctly rounded). */

int  abs(int x)  { return x < 0 ? -x : x; }
long labs(long x) { return x < 0 ? -x : x; }
long long llabs(long long x) { return x < 0 ? -x : x; }

div_t div(int n, int d) { div_t r = { n / d, n % d }; return r; }
ldiv_t ldiv(long n, long d) { ldiv_t r = { n / d, n % d }; return r; }
lldiv_t lldiv(long long n, long long d) { lldiv_t r = { n / d, n % d }; return r; }

long imaxabs(long j) { return j < 0 ? -j : j; }
long strtoimax(const char *s, char **end, int base) { return (long)strtoull(s, end, base); }
unsigned long strtoumax(const char *s, char **end, int base) { return strtoull(s, end, base); }

/* --- qsort (median-of-three quicksort, insertion for small runs) --- */

static void swp(char *a, char *b, size_t n)
{
	while (n--) { char t = *a; *a++ = *b; *b++ = t; }
}

void qsort(void *base, size_t n, size_t size, int (*cmp)(const void *, const void *))
{
	char *b = base;
	if (n < 2) return;

	if (n <= 12) {
		for (size_t i = 1; i < n; i++)
			for (size_t j = i; j > 0 && cmp(b + j * size, b + (j - 1) * size) < 0; j--)
				swp(b + j * size, b + (j - 1) * size, size);
		return;
	}

	char *lo = b, *hi = b + (n - 1) * size, *mid = b + (n / 2) * size;
	if (cmp(mid, lo) < 0) swp(mid, lo, size);
	if (cmp(hi, mid) < 0) { swp(hi, mid, size); if (cmp(mid, lo) < 0) swp(mid, lo, size); }
	/* pivot -> mid; park it at hi-1 */
	swp(mid, hi - size, size);
	char *pivot = hi - size;

	char *i = lo, *j = hi - size;
	for (;;) {
		do { i += size; } while (cmp(i, pivot) < 0);
		do { j -= size; } while (cmp(pivot, j) < 0);
		if (i >= j) break;
		swp(i, j, size);
	}
	swp(i, hi - size, size);

	size_t left = (size_t)(i - lo) / size;
	qsort(lo, left, size, cmp);
	qsort(i + size, n - left - 1, size, cmp);
}

void *bsearch(const void *key, const void *base, size_t n, size_t size,
              int (*cmp)(const void *, const void *))
{
	const char *b = base;
	size_t lo = 0, hi = n;
	while (lo < hi) {
		size_t m = lo + (hi - lo) / 2;
		int r = cmp(key, b + m * size);
		if (r == 0) return (void *)(b + m * size);
		if (r < 0) hi = m; else lo = m + 1;
	}
	return NULL;
}

/* --- atexit (LIFO, wired into exit() in src/exit.c) --- */

/* One LIFO table for atexit() and C++'s __cxa_atexit() (destructors of
 * static objects), so the two run interleaved in reverse registration
 * order, as C++ requires. A plain atexit handler takes no argument; it's
 * stored as the one-argument kind and called with a null it ignores. */
#define ATEXIT_MAX 256
struct __libc_atexit_ent { void (*fn)(void *); void *arg; };
struct __libc_atexit_ent __libc_atexit_fns[ATEXIT_MAX];
int  __libc_atexit_n = 0;

int __cxa_atexit(void (*fn)(void *), void *arg, void *dso)
{
	(void)dso;   /* one static image: there are no DSOs to unload */
	if (__libc_atexit_n >= ATEXIT_MAX) return -1;
	__libc_atexit_fns[__libc_atexit_n].fn = fn;
	__libc_atexit_fns[__libc_atexit_n].arg = arg;
	__libc_atexit_n++;
	return 0;
}

int atexit(void (*fn)(void))
{
	return __cxa_atexit((void (*)(void *))fn, 0, 0);
}

void *__dso_handle = &__dso_handle;

/* environment: getenv / setenv / putenv / unsetenv live in rc_env.c */

/* --- rand (glibc TYPE_0 minimal LCG) --- */

static unsigned long __rand_state = 1;

void srand(unsigned seed) { __rand_state = seed; }

int rand(void)
{
	__rand_state = __rand_state * 1103515245UL + 12345UL;
	return (int)((__rand_state >> 16) & 0x7fffffff);
}
