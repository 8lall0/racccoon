#ifndef _MATH_H
#define _MATH_H

/* A small <math.h>: racccoon's userspace does no floating-point numerics
 * beyond what a compiler needs for constant folding (TinyCC's float
 * parser, c3c's number.c / float.c). tcc does not implement the GCC
 * __builtin_* float helpers, so these are real functions (src/math.c),
 * not builtins. Add more as something needs them. */

double      __rc_huge_val(void);
float       __rc_inff(void);
double      __rc_nan(const char *tag);
int         __rc_isnan(double x);
int         __rc_isinf(double x);
int         __rc_isfinite(double x);
int         __rc_signbit(double x);

#define HUGE_VAL  (__rc_huge_val())
#define HUGE_VALF ((float)__rc_huge_val())
#define HUGE_VALL ((long double)__rc_huge_val())
#define INFINITY  (__rc_inff())
#define NAN       (__rc_nan(""))

#define isnan(x)    __rc_isnan((double)(x))
#define isinf(x)    __rc_isinf((double)(x))
#define isfinite(x) __rc_isfinite((double)(x))
#define signbit(x)  __rc_signbit((double)(x))

double      ldexp(double x, int exp);
long double ldexpl(long double x, int exp);
double      frexp(double x, int *exp);

double fabs(double x);
double pow(double base, double exp);   /* integer exponents only */
double ceil(double x);
double floor(double x);
double trunc(double x);
double fmod(double x, double y);
double log10(double x);
double nan(const char *tag);

#endif
