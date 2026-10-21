/* libm (musl's src/math in libracccoon.a): known values, the edge cases
 * racccoon's old stub math got wrong (trunc/floor/ceil through a long long
 * cast), classification on float/double/long double, and a strtod <->
 * printf round trip. Prints "mathtest: ok" (exit 0) or each failure. */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fails, checks;

static void near(const char *what, double got, double want, double tol)
{
	checks++;
	double err = fabs(got - want);
	if (!(err <= tol * (fabs(want) > 1 ? fabs(want) : 1))) {
		printf("mathtest: FAILED %s: got %.17g want %.17g\n", what, got, want);
		fails++;
	}
}

static void same(const char *what, double got, double want)
{
	checks++;
	/* bitwise, so -0.0 vs 0.0 and NaN are told apart */
	if (memcmp(&got, &want, sizeof got) != 0 && !(isnan(got) && isnan(want))) {
		printf("mathtest: FAILED %s: got %.17g want %.17g\n", what, got, want);
		fails++;
	}
}

static void fmt(const char *what, const char *got, const char *want)
{
	checks++;
	if (strcmp(got, want) != 0) {
		printf("mathtest: FAILED printf %s: got \"%s\" want \"%s\"\n", what, got, want);
		fails++;
	}
}

static void truth(const char *what, int ok)
{
	checks++;
	if (!ok) { printf("mathtest: FAILED %s\n", what); fails++; }
}

int main(void)
{
	const double tol = 1e-15;
	near("sin(pi/6)", sin(M_PI / 6), 0.5, tol);
	near("cos(pi/3)", cos(M_PI / 3), 0.5, tol);
	near("tan(pi/4)", tan(M_PI / 4), 1.0, tol);
	near("atan2(1,-1)", atan2(1, -1), 3 * M_PI / 4, tol);
	near("asin(1)", asin(1), M_PI / 2, tol);
	near("acos(-1)", acos(-1), M_PI, tol);
	near("exp(1)", exp(1), M_E, tol);
	near("log(10)", log(10), M_LN10, tol);
	near("log2(1024)", log2(1024), 10, 0);
	near("log10(1e-7)", log10(1e-7), -7, tol);
	near("log1p(1e-10)", log1p(1e-10), 9.9999999995e-11, 1e-12);
	near("pow(2,0.5)", pow(2, 0.5), M_SQRT2, tol);
	near("pow(10,-3.5)", pow(10, -3.5), 3.1622776601683794e-4, tol);
	near("sqrt(2)", sqrt(2), M_SQRT2, tol);
	near("cbrt(-27)", cbrt(-27), -3, tol);
	near("hypot(3,4)", hypot(3, 4), 5, 0);
	near("erf(0.5)", erf(0.5), 0.52049987781304654, tol);
	near("tanh(0.5)", tanh(0.5), 0.46211715726000974, tol);
	near("sinh(1)", sinh(1), 1.1752011936438014, tol);
	near("fmod(10.5,3)", fmod(10.5, 3), 1.5, 0);
	near("log2f(8)", log2f(8.0f), 3, 0);
	near("sinf(0.5)", sinf(0.5f), 0.47942554f, 1e-7);

	/* what the old trunc/floor/ceil (a long long cast) got wrong */
	same("trunc(1e300)", trunc(1e300), 1e300);
	same("floor(-1e300)", floor(-1e300), -1e300);
	same("ceil(9.3e18)", ceil(9.3e18), 9.3e18);
	same("floor(-0.5)", floor(-0.5), -1.0);
	same("ceil(-0.5)", ceil(-0.5), -0.0);
	same("trunc(-0.0)", trunc(-0.0), -0.0);
	same("trunc(inf)", trunc(INFINITY), INFINITY);
	truth("trunc(nan) is nan", isnan(trunc(NAN)));
	same("round(2.5)", round(2.5), 3.0);
	same("rint(2.5)", rint(2.5), 2.0);
	same("pow(-8,1/3.) is nan", pow(-8, 1 / 3.0), NAN);

	/* classification on all three types */
	truth("fpclassify(float subnormal)", fpclassify(1e-40f) == FP_SUBNORMAL);
	truth("fpclassify(double zero)", fpclassify(-0.0) == FP_ZERO);
	truth("fpclassify(long double normal)", fpclassify(1.0L) == FP_NORMAL);
	truth("isinf(-HUGE_VAL)", isinf(-HUGE_VAL));
	truth("isnan(NAN) float", isnan(NAN));
	truth("signbit(-0.0)", signbit(-0.0) != 0);
	truth("isnormal(DBL_MIN-ish)", isnormal(2.2250738585072014e-308));

	/* long double (binary128) */
	near("sqrtl(2)", (double)sqrtl(2.0L), M_SQRT2, tol);
	near("expl(1)", (double)expl(1.0L), M_E, tol);
	truth("ldexpl(1,-16000) > 0", ldexpl(1.0L, -16000) > 0);

	/* strtod <-> %.17g */
	const double vals[] = { M_PI, 1e-310, 123456789.125, -2.5e300, 0.1 };
	for (unsigned i = 0; i < sizeof vals / sizeof *vals; i++) {
		char buf[64];
		snprintf(buf, sizeof buf, "%.17g", vals[i]);
		same("strtod(%.17g) round trip", strtod(buf, NULL), vals[i]);
	}

	/* printf's float conversions (racccoon's old ones lost exponents
	 * past 99 and overflowed %f) and strtod's special forms */
	char b[128];
	snprintf(b, sizeof b, "%.3e", -2.5e300);   fmt("%.3e", b, "-2.500e+300");
	snprintf(b, sizeof b, "%f", 1e20);         fmt("%f 1e20", b, "100000000000000000000.000000");
	snprintf(b, sizeof b, "%g", 0.0001234);    fmt("%g", b, "0.0001234");
	snprintf(b, sizeof b, "%g", 1e100);        fmt("%g 1e100", b, "1e+100");
	snprintf(b, sizeof b, "%.17g", 0.1);       fmt("%.17g 0.1", b, "0.10000000000000001");
	snprintf(b, sizeof b, "%a", 1.0);          fmt("%a", b, "0x1p+0");
	snprintf(b, sizeof b, "%08.2f|%-6.1f|", -3.14159, 2.25); fmt("width/flags", b, "-0003.14|2.2   |");
	snprintf(b, sizeof b, "%.20Lf", 1.0L / 3); fmt("%Lf", b, "0.33333333333333333333");
	snprintf(b, sizeof b, "%f %F", INFINITY, -NAN); fmt("inf/nan", b, "inf -NAN");
	same("strtod(\"inf\")", strtod("inf", NULL), INFINITY);
	truth("strtod(\"nan\") is nan", isnan(strtod("nan", NULL)));
	same("strtod(hex)", strtod("0x1.8p1", NULL), 3.0);
	same("strtod(1e400) = inf", strtod("1e400", NULL), INFINITY);
	same("strtod(subnormal)", strtod("4.9406564584124654e-324", NULL), 4.9406564584124654e-324);

	if (fails) { printf("mathtest: %d of %d checks FAILED\n", fails, checks); return 1; }
	printf("mathtest: ok (%d checks)\n", checks);
	return 0;
}
