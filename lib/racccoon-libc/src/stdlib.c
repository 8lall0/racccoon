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

static int hexval(char c)
{
	if (c >= '0' && c <= '9') return c - '0';
	if (c >= 'a' && c <= 'f') return c - 'a' + 10;
	if (c >= 'A' && c <= 'F') return c - 'A' + 10;
	return -1;
}

/* C99 hex float: 0x<hex digits>[.<hex digits>]p[+-]<decimal exponent>,
 * binary exponent mandatory. Used by c3's own math_nolibc constants
 * (e.g. "-0x1ffffffd0c5e81.0p-54") — c3c parses these when compiling
 * the c3 stdlib on-device, so this isn't just spec completeness. */
static double strtod_hex(const char *p, int *any, const char **endp)
{
	double val = 0.0;
	while (hexval(*p) >= 0) { val = val * 16.0 + hexval(*p); p++; *any = 1; }
	if (*p == '.') {
		p++;
		double scale = 1.0 / 16.0;
		while (hexval(*p) >= 0) { val += hexval(*p) * scale; scale /= 16.0; p++; *any = 1; }
	}
	if (!*any) { *endp = p; return 0.0; }
	if (*p == 'p' || *p == 'P') {
		const char *save = p;
		p++;
		int eneg = 0;
		if (*p == '+' || *p == '-') eneg = (*p++ == '-');
		int exp = 0;
		int have_exp = 0;
		while (isdigit((unsigned char)*p)) { exp = exp * 10 + (*p++ - '0'); have_exp = 1; }
		if (have_exp) {
			if (eneg) exp = -exp;
			/* val * 2^exp, exponentiating by squaring so huge |exp|
			 * doesn't loop thousands of times. */
			double scale = 1.0;
			double base = exp < 0 ? 0.5 : 2.0;
			unsigned n = (unsigned)(exp < 0 ? -exp : exp);
			while (n) {
				if (n & 1) scale *= base;
				base *= base;
				n >>= 1;
			}
			val *= scale;
		} else {
			p = save;   /* "p" with no digits after — not consumed */
		}
	}
	*endp = p;
	return val;
}

double strtod(const char *s, char **end)
{
	const char *p = s;
	while (isspace((unsigned char)*p)) p++;
	int neg = 0;
	if (*p == '+' || *p == '-') neg = (*p++ == '-');

	if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) {
		int any = 0;
		const char *hexend;
		double hval = strtod_hex(p + 2, &any, &hexend);
		if (any) {
			if (end) *end = (char *)hexend;
			return neg ? -hval : hval;
		}
		/* "0x" not followed by a valid hex float — fall through and
		 * parse the leading "0" as a plain decimal below. */
	}

	double val = 0.0;
	int any = 0;
	while (isdigit((unsigned char)*p)) { val = val * 10.0 + (*p++ - '0'); any = 1; }
	if (*p == '.') {
		p++;
		double scale = 0.1;
		while (isdigit((unsigned char)*p)) { val += (*p++ - '0') * scale; scale *= 0.1; any = 1; }
	}
	if (any && (*p == 'e' || *p == 'E')) {
		p++;
		int eneg = 0;
		if (*p == '+' || *p == '-') eneg = (*p++ == '-');
		int exp = 0;
		while (isdigit((unsigned char)*p)) exp = exp * 10 + (*p++ - '0');
		double f = 1.0;
		while (exp--) f *= 10.0;
		val = eneg ? val / f : val * f;
	}

	if (end) *end = (char *)(any ? p : s);
	return neg ? -val : val;
}

/* strtof reuses strtod (float<-double is a hw convert); strtold lives
 * in src/quad.c so a program that never needs long double doesn't drag
 * in libgcc's soft-quad routines. */
float strtof(const char *s, char **end) { return (float)strtod(s, end); }

int  abs(int x)  { return x < 0 ? -x : x; }
long labs(long x) { return x < 0 ? -x : x; }
long long llabs(long long x) { return x < 0 ? -x : x; }

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

#define ATEXIT_MAX 32
void (*__libc_atexit_fns[ATEXIT_MAX])(void);
int  __libc_atexit_n = 0;

int atexit(void (*fn)(void))
{
	if (__libc_atexit_n >= ATEXIT_MAX) return -1;
	__libc_atexit_fns[__libc_atexit_n++] = fn;
	return 0;
}

/* environment: getenv / setenv / putenv / unsetenv live in rc_env.c */

/* --- rand (glibc TYPE_0 minimal LCG) --- */

static unsigned long __rand_state = 1;

void srand(unsigned seed) { __rand_state = seed; }

int rand(void)
{
	__rand_state = __rand_state * 1103515245UL + 12345UL;
	return (int)((__rand_state >> 16) & 0x7fffffff);
}
