/* long double == IEEE binary128 on rv64/lp64d, and every operation on
 * it is a libgcc soft-quad call (__multf3, __extenddftf2, …). Isolated
 * here so only a program that actually uses long double (a compiler's
 * float-literal parser — nothing else in racccoon's userspace) has to
 * link libgcc for it. */
#include <math.h>
#include <stdlib.h>

long double ldexpl(long double x, int n)
{
	while (n > 0) { x *= 2.0L; n--; }
	while (n < 0) { x *= 0.5L; n++; }
	return x;
}

/* Computed as a double and widened — racccoon needs no more precision
 * than that for the one caller; the extra mantissa bits are lost. */
long double strtold(const char *s, char **end)
{
	return (long double)strtod(s, end);
}
