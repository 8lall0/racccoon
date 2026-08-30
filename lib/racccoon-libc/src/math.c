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
