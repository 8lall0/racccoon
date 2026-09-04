/* The few math routines a compiler-class program needs for constant
 * folding — nothing more. See <math.h>. */
#include <math.h>

double fabs(double x) { return __builtin_fabs(x); }

double ldexp(double x, int n)
{
	union { double d; unsigned long long u; } v;

	if (x == 0.0 || __builtin_isnan(x) || __builtin_isinf(x))
		return x;

	/* Step the exponent in safe chunks so the bit-poke below always
	 * lands on a valid biased exponent. */
	while (n >  1000) { x *= 0x1p1000;  n -= 1000; if (__builtin_isinf(x)) return x; }
	while (n < -1000) { x *= 0x1p-1000; n += 1000; if (x == 0.0) return x; }

	v.u = (unsigned long long)(n + 1023) << 52;   /* 2^n, n in [-1000,1000] */
	return x * v.d;
}

/* ldexpl (long double / quad) lives in src/quad.c — see strtold there. */

double frexp(double x, int *e)
{
	*e = 0;
	if (x == 0.0 || __builtin_isnan(x) || __builtin_isinf(x)) return x;
	int neg = x < 0.0;
	if (neg) x = -x;
	while (x >= 1.0) { x *= 0.5; (*e)++; }
	while (x < 0.5)  { x *= 2.0; (*e)--; }
	return neg ? -x : x;
}

/* Integer exponents only — enough for the one "pow(10, n)" style use. */
double pow(double base, double exp)
{
	int n = (int)exp;
	double r = 1.0;
	int neg = n < 0;
	if (neg) n = -n;
	while (n--) r *= base;
	return neg ? 1.0 / r : r;
}

/* --- tcc has no __builtin float helpers: real versions --- */
static const unsigned long long __rc_inf_bits = 0x7FF0000000000000ULL;
double __rc_huge_val(void) { double d; __builtin_memcpy(&d, &__rc_inf_bits, 8); return d; }
float  __rc_inff(void)     { return (float)__rc_huge_val(); }
double __rc_nan(const char *tag) { (void)tag; unsigned long long b = 0x7FF8000000000000ULL; double d; __builtin_memcpy(&d, &b, 8); return d; }
double nan(const char *tag) { return __rc_nan(tag); }
int __rc_isnan(double x)    { return x != x; }
int __rc_isinf(double x)    { return !__rc_isnan(x) && (x == __rc_huge_val() || x == -__rc_huge_val()); }
int __rc_isfinite(double x) { return !__rc_isnan(x) && !__rc_isinf(x); }
int __rc_signbit(double x)  { unsigned long long b; __builtin_memcpy(&b, &x, 8); return (int)(b >> 63); }

double trunc(double x) { return (double)(long long)x; }
double floor(double x) { double t = trunc(x); return (t > x) ? t - 1.0 : t; }
double ceil(double x)  { double t = trunc(x); return (t < x) ? t + 1.0 : t; }
double fmod(double x, double y) { if (y == 0.0) return __rc_nan(""); return x - trunc(x / y) * y; }

/* log10 via a crude series — c3c only needs it for diagnostics-ish
 * float formatting; precision isn't load-bearing. */
double log10(double x)
{
	if (x <= 0.0) return __rc_nan("");
	/* ln(x) by range reduction: x = m * 2^e, ln(x) = e*ln2 + ln(m) */
	int e = 0;
	while (x >= 2.0) { x *= 0.5; e++; }
	while (x < 1.0)  { x *= 2.0; e--; }
	double y = (x - 1.0) / (x + 1.0), y2 = y * y, term = y, sum = 0.0;
	for (int k = 1; k < 30; k += 2) { sum += term / k; term *= y2; }
	double ln = e * 0.6931471805599453 + 2.0 * sum;
	return ln * 0.4342944819032518; /* / ln(10) */
}
