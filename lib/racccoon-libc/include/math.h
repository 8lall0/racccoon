#ifndef _MATH_H
#define _MATH_H

/* A near-empty <math.h>: racccoon's userspace does no floating-point
 * numerics beyond what a compiler needs for constant folding. Only the
 * handful of entry points an actual caller (TinyCC's float-literal
 * parser) references are here. Add more as something needs them. */

#define HUGE_VAL  (__builtin_huge_val())
#define HUGE_VALF (__builtin_huge_valf())
#define HUGE_VALL (__builtin_huge_vall())
#define INFINITY  (__builtin_inff())
#define NAN       (__builtin_nanf(""))

#define isnan(x)    __builtin_isnan(x)
#define isinf(x)    __builtin_isinf(x)
#define isfinite(x) __builtin_isfinite(x)
#define signbit(x)  __builtin_signbit(x)

double      ldexp(double x, int exp);
long double ldexpl(long double x, int exp);
double      frexp(double x, int *exp);

double fabs(double x);
double pow(double base, double exp);   /* stub: integer exponents only */

#endif
