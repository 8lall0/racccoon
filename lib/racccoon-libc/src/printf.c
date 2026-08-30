/* The printf family: one vformat() over an emit callback, driving
 * vfprintf / vsnprintf / vsprintf / vprintf and the varargs wrappers.
 *
 * Conversions: d i u o x X c s p % f F e E g G  (n is parsed + ignored)
 * Length:      hh h l ll j z t L
 * Flags:       - + space # 0     width (num or *)     .prec (num or *)
 *
 * Floats use the hardware FPU (roadmap §3). Not bit-exact to the
 * shortest-round-trip ideal, but correct to the requested precision —
 * fine for a compiler and ordinary tools. */
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <stddef.h>

struct out {
	void (*emit)(struct out *, const char *, size_t);
	char  *dst;        /* snprintf/sprintf target */
	size_t cap;        /* snprintf limit (SIZE_MAX for sprintf) */
	size_t len;        /* bytes produced (may exceed cap) */
	FILE  *f;          /* fprintf target */
};

static void emit_file(struct out *o, const char *s, size_t n)
{
	fwrite(s, 1, n, o->f);
	o->len += n;
}
static void emit_str(struct out *o, const char *s, size_t n)
{
	for (size_t i = 0; i < n; i++) {
		if (o->len + 1 < o->cap) o->dst[o->len] = s[i];
		o->len++;
	}
}

static void pad(struct out *o, char c, int n)
{
	char b[16];
	memset(b, c, sizeof b);
	while (n > 0) { int k = n > 16 ? 16 : n; o->emit(o, b, (size_t)k); n -= k; }
}

/* unsigned -> string in `buf` (writes backwards from the end), base
 * 8/10/16, `upper` for hex. Returns pointer to the first digit. */
static char *utoa(unsigned long long v, char *end, int base, int upper)
{
	const char *dig = upper ? "0123456789ABCDEF" : "0123456789abcdef";
	char *p = end;
	*--p = 0;
	if (v == 0) *--p = '0';
	while (v) { *--p = dig[v % (unsigned)base]; v /= (unsigned)base; }
	return p;
}

static void put_number(struct out *o, char *digits, int neg,
                       const char *prefix, int flags, int width, int prec)
{
	enum { F_MINUS = 1, F_PLUS = 2, F_SPACE = 4, F_HASH = 8, F_ZERO = 16 };
	int dlen = (int)strlen(digits);
	int plen = prefix ? (int)strlen(prefix) : 0;
	char sign = neg ? '-' : (flags & F_PLUS) ? '+' : (flags & F_SPACE) ? ' ' : 0;

	int zeros = 0;
	if (prec >= 0 && dlen < prec) zeros = prec - dlen;
	if ((flags & F_ZERO) && prec < 0 && !(flags & F_MINUS)) {
		int room = width - dlen - plen - (sign ? 1 : 0);
		if (room > zeros) zeros = room;
	}
	int body = (sign ? 1 : 0) + plen + zeros + dlen;
	int space = width - body;

	if (!(flags & F_MINUS)) pad(o, ' ', space);
	if (sign) o->emit(o, &sign, 1);
	if (prefix) o->emit(o, prefix, (size_t)plen);
	pad(o, '0', zeros);
	o->emit(o, digits, (size_t)dlen);
	if (flags & F_MINUS) pad(o, ' ', space);
}

static void put_str(struct out *o, const char *s, int flags, int width, int prec)
{
	if (!s) s = "(null)";
	int len = 0;
	while (s[len] && (prec < 0 || len < prec)) len++;
	int space = width - len;
	if (!(flags & 1) /*F_MINUS*/) pad(o, ' ', space);
	o->emit(o, s, (size_t)len);
	if (flags & 1) pad(o, ' ', space);
}

static void put_float(struct out *o, double val, char conv,
                      int flags, int width, int prec)
{
	enum { F_MINUS = 1, F_PLUS = 2, F_SPACE = 4, F_HASH = 8, F_ZERO = 16 };
	if (prec < 0) prec = 6;

	int neg = 0;
	/* -0.0 and negatives */
	unsigned long long bits;
	memcpy(&bits, &val, 8);
	if (bits >> 63) { neg = 1; val = -val; }

	char buf[512];
	char *p = buf;

	if (val != val) { memcpy(p, "nan", 3); p += 3; neg = 0; goto emit; }
	if (val > 1.7976931348623157e308) { memcpy(p, "inf", 3); p += 3; goto emit; }

	if (conv == 'e' || conv == 'E') {
		int exp = 0;
		if (val != 0.0) {
			while (val >= 10.0) { val /= 10.0; exp++; }
			while (val < 1.0)   { val *= 10.0; exp--; }
		}
		/* round */
		double scale = 1.0; for (int i = 0; i < prec; i++) scale *= 10.0;
		val = ((double)(long long)(val * scale + 0.5)) / scale;
		if (val >= 10.0) { val /= 10.0; exp++; }
		long long ip = (long long)val;
		*p++ = (char)('0' + ip);
		if (prec > 0 || (flags & F_HASH)) {
			*p++ = '.';
			double frac = val - (double)ip;
			for (int i = 0; i < prec; i++) { frac *= 10.0; int d = (int)frac; *p++ = (char)('0' + d); frac -= d; }
		}
		*p++ = (conv == 'E') ? 'E' : 'e';
		*p++ = exp < 0 ? '-' : '+';
		if (exp < 0) exp = -exp;
		*p++ = (char)('0' + (exp / 10) % 10);
		*p++ = (char)('0' + exp % 10);
	} else if (conv == 'g' || conv == 'G') {
		if (prec == 0) prec = 1;
		/* crude: use %e if exponent < -4 or >= prec, else %f */
		int exp = 0; double t = val;
		if (t != 0.0) { while (t >= 10.0) { t /= 10.0; exp++; } while (t < 1.0) { t *= 10.0; exp--; } }
		if (exp < -4 || exp >= prec)
			put_float(o, neg ? -val : val, conv == 'G' ? 'E' : 'e', flags, width, prec - 1);
		else
			put_float(o, neg ? -val : val, 'f', flags, width, prec - 1 - exp);
		return;
	} else { /* f / F */
		double scale = 1.0; for (int i = 0; i < prec; i++) scale *= 10.0;
		unsigned long long ip = (unsigned long long)val;
		double frac = val - (double)ip;
		unsigned long long fp = (unsigned long long)(frac * scale + 0.5);
		if (fp >= (unsigned long long)scale) { fp -= (unsigned long long)scale; ip++; }

		char ib[32]; char *ipd = utoa(ip, ib + sizeof ib, 10, 0);
		while (*ipd) *p++ = *ipd++;
		if (prec > 0 || (flags & F_HASH)) {
			*p++ = '.';
			char fb[32]; char *fpd = utoa(fp, fb + sizeof fb, 10, 0);
			int flen = (int)strlen(fpd);
			for (int i = flen; i < prec; i++) *p++ = '0';
			while (*fpd) *p++ = *fpd++;
		}
	}

emit:;
	int len = (int)(p - buf);
	char sign = neg ? '-' : (flags & F_PLUS) ? '+' : (flags & F_SPACE) ? ' ' : 0;
	int space = width - len - (sign ? 1 : 0);
	if (!(flags & F_MINUS) && !(flags & F_ZERO)) pad(o, ' ', space);
	if (sign) o->emit(o, &sign, 1);
	if (!(flags & F_MINUS) && (flags & F_ZERO)) pad(o, '0', space);
	o->emit(o, buf, (size_t)len);
	if (flags & F_MINUS) pad(o, ' ', space);
}

static int vformat(struct out *o, const char *fmt, va_list ap)
{
	enum { F_MINUS = 1, F_PLUS = 2, F_SPACE = 4, F_HASH = 8, F_ZERO = 16 };

	for (const char *f = fmt; *f; f++) {
		if (*f != '%') { o->emit(o, f, 1); continue; }
		f++;

		int flags = 0;
		for (;; f++) {
			if (*f == '-') flags |= F_MINUS;
			else if (*f == '+') flags |= F_PLUS;
			else if (*f == ' ') flags |= F_SPACE;
			else if (*f == '#') flags |= F_HASH;
			else if (*f == '0') flags |= F_ZERO;
			else break;
		}

		int width = 0;
		if (*f == '*') { width = va_arg(ap, int); f++; if (width < 0) { flags |= F_MINUS; width = -width; } }
		else while (*f >= '0' && *f <= '9') width = width * 10 + (*f++ - '0');

		int prec = -1;
		if (*f == '.') {
			f++;
			prec = 0;
			if (*f == '*') { prec = va_arg(ap, int); f++; if (prec < 0) prec = -1; }
			else while (*f >= '0' && *f <= '9') prec = prec * 10 + (*f++ - '0');
		}

		int lng = 0;   /* 0=int 1=long 2=long long, also z/t map to long */
		for (;;) {
			if (*f == 'l') { lng++; f++; }
			else if (*f == 'h') { f++; }               /* narrowing — read as int, fine */
			else if (*f == 'z' || *f == 't' || *f == 'j') { lng = 1; f++; }
			else if (*f == 'L') { f++; }
			else break;
		}

		char c = *f;
		char nbuf[32];

		switch (c) {
		case 'd': case 'i': {
			long long v = lng >= 2 ? va_arg(ap, long long)
			            : lng == 1 ? va_arg(ap, long)
			                       : (long long)va_arg(ap, int);
			int neg = v < 0;
			unsigned long long uv = neg ? (unsigned long long)(-v) : (unsigned long long)v;
			char *d = utoa(uv, nbuf + sizeof nbuf, 10, 0);
			put_number(o, d, neg, NULL, flags, width, prec);
			break;
		}
		case 'u': case 'o': case 'x': case 'X': {
			unsigned long long v = lng >= 2 ? va_arg(ap, unsigned long long)
			                     : lng == 1 ? va_arg(ap, unsigned long)
			                                : (unsigned long long)va_arg(ap, unsigned);
			int base = c == 'o' ? 8 : c == 'u' ? 10 : 16;
			char *d = utoa(v, nbuf + sizeof nbuf, base, c == 'X');
			const char *pre = NULL;
			if ((flags & F_HASH) && v) {
				if (c == 'x') pre = "0x";
				else if (c == 'X') pre = "0X";
				else if (c == 'o') pre = "0";
			}
			put_number(o, d, 0, pre, flags, width, prec);
			break;
		}
		case 'p': {
			unsigned long long v = (unsigned long long)(size_t)va_arg(ap, void *);
			char *d = utoa(v, nbuf + sizeof nbuf, 16, 0);
			put_number(o, d, 0, "0x", flags, width, prec);
			break;
		}
		case 'c': {
			char ch = (char)va_arg(ap, int);
			int space = width - 1;
			if (!(flags & F_MINUS)) pad(o, ' ', space);
			o->emit(o, &ch, 1);
			if (flags & F_MINUS) pad(o, ' ', space);
			break;
		}
		case 's':
			put_str(o, va_arg(ap, const char *), flags, width, prec);
			break;
		case 'f': case 'F': case 'e': case 'E': case 'g': case 'G':
			put_float(o, va_arg(ap, double), c, flags, width, prec);
			break;
		case 'n':
			(void)va_arg(ap, void *);   /* parsed, ignored */
			break;
		case '%':
			o->emit(o, "%", 1);
			break;
		case 0:
			f--;   /* trailing '%' — stop */
			break;
		default:
			o->emit(o, "%", 1);
			o->emit(o, &c, 1);
			break;
		}
	}
	return (int)o->len;
}

int vfprintf(FILE *f, const char *fmt, va_list ap)
{
	struct out o = { emit_file, NULL, 0, 0, f };
	return vformat(&o, fmt, ap);
}
int vsnprintf(char *s, size_t n, const char *fmt, va_list ap)
{
	struct out o = { emit_str, s, n, 0, NULL };
	int r = vformat(&o, fmt, ap);
	if (n) s[o.len < n ? o.len : n - 1] = 0;
	return r;
}
int vsprintf(char *s, const char *fmt, va_list ap)
{
	struct out o = { emit_str, s, (size_t)-1, 0, NULL };
	int r = vformat(&o, fmt, ap);
	s[o.len] = 0;
	return r;
}
int vprintf(const char *fmt, va_list ap) { return vfprintf(stdout, fmt, ap); }

int fprintf(FILE *f, const char *fmt, ...)
{
	va_list ap; va_start(ap, fmt);
	int r = vfprintf(f, fmt, ap);
	va_end(ap);
	return r;
}
int printf(const char *fmt, ...)
{
	va_list ap; va_start(ap, fmt);
	int r = vfprintf(stdout, fmt, ap);
	va_end(ap);
	return r;
}
int snprintf(char *s, size_t n, const char *fmt, ...)
{
	va_list ap; va_start(ap, fmt);
	int r = vsnprintf(s, n, fmt, ap);
	va_end(ap);
	return r;
}
int sprintf(char *s, const char *fmt, ...)
{
	va_list ap; va_start(ap, fmt);
	int r = vsprintf(s, fmt, ap);
	va_end(ap);
	return r;
}
