/* sscanf / vsscanf: the C99 conversions over a string — d i u o x X n
 * (with hh h l ll j z t L), f e g a E G A F, s c [set], p, %%, field
 * widths and '*' suppression. Floats go through strtod/strtold, so they
 * parse whatever those accept. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <ctype.h>
#include <stdint.h>

enum { L_NONE, L_HH, L_H, L_L, L_LL, L_J, L_Z, L_T, L_BIGL };

static void store_int(void *p, int len, unsigned long long v)
{
	switch (len) {
	case L_HH: *(signed char *)p = (signed char)v; break;
	case L_H:  *(short *)p = (short)v; break;
	case L_L:  *(long *)p = (long)v; break;
	case L_LL: *(long long *)p = (long long)v; break;
	case L_J:  *(intmax_t *)p = (intmax_t)v; break;
	case L_Z:  *(size_t *)p = (size_t)v; break;
	case L_T:  *(ptrdiff_t *)p = (ptrdiff_t)v; break;
	default:   *(int *)p = (int)v; break;
	}
}

int vsscanf(const char *str, const char *fmt, va_list ap)
{
	const char *s = str;
	int count = 0;
	char buf[512];

	while (*fmt) {
		if (isspace((unsigned char)*fmt)) {
			while (isspace((unsigned char)*s)) s++;
			fmt++;
			continue;
		}
		if (*fmt != '%' || fmt[1] == '%') {
			if (*fmt == '%') fmt++;
			if (*s != *fmt) break;
			s++; fmt++;
			continue;
		}
		fmt++;
		int skip = 0;
		if (*fmt == '*') { skip = 1; fmt++; }
		int width = 0;
		while (isdigit((unsigned char)*fmt)) width = width * 10 + (*fmt++ - '0');
		int len = L_NONE;
		switch (*fmt) {
		case 'h': len = L_H; if (*++fmt == 'h') { len = L_HH; fmt++; } break;
		case 'l': len = L_L; if (*++fmt == 'l') { len = L_LL; fmt++; } break;
		case 'j': len = L_J; fmt++; break;
		case 'z': len = L_Z; fmt++; break;
		case 't': len = L_T; fmt++; break;
		case 'L': len = L_BIGL; fmt++; break;
		}
		char conv = *fmt++;
		if (!conv) break;

		if (conv == 'n') {
			if (!skip) store_int(va_arg(ap, void *), len, (unsigned long long)(s - str));
			continue;
		}
		if (conv != 'c' && conv != '[')
			while (isspace((unsigned char)*s)) s++;
		if (!*s) return count ? count : EOF;

		if (conv == 'c') {
			int n = width ? width : 1;
			char *out = skip ? 0 : va_arg(ap, char *);
			for (int i = 0; i < n; i++) {
				if (!s[i]) return count;
				if (out) out[i] = s[i];
			}
			s += n;
			if (!skip) count++;
			continue;
		}
		if (conv == 's' || conv == '[') {
			unsigned char set[256];
			int neg = 0;
			if (conv == '[') {
				memset(set, 0, sizeof set);
				if (*fmt == '^') { neg = 1; fmt++; }
				if (*fmt == ']') { set[']'] = 1; fmt++; }
				while (*fmt && *fmt != ']') {
					if (fmt[1] == '-' && fmt[2] && fmt[2] != ']') {
						for (int c = (unsigned char)fmt[0]; c <= (unsigned char)fmt[2]; c++) set[c] = 1;
						fmt += 3;
					} else {
						set[(unsigned char)*fmt++] = 1;
					}
				}
				if (*fmt == ']') fmt++;
			}
			char *out = skip ? 0 : va_arg(ap, char *);
			int n = 0;
			while (s[n] && (!width || n < width)) {
				unsigned char c = (unsigned char)s[n];
				int in = conv == 's' ? !isspace(c) : (set[c] != neg);
				if (!in) break;
				if (out) out[n] = (char)c;
				n++;
			}
			if (n == 0) return count;
			if (out) out[n] = 0;
			s += n;
			if (!skip) count++;
			continue;
		}

		/* numbers: copy at most `width` chars, parse with strto* */
		int max = width && width < (int)sizeof buf - 1 ? width : (int)sizeof buf - 1;
		int k = 0;
		while (k < max && s[k]) { buf[k] = s[k]; k++; }
		buf[k] = 0;
		char *end;
		if (conv == 'f' || conv == 'e' || conv == 'g' || conv == 'a' ||
		    conv == 'E' || conv == 'G' || conv == 'A' || conv == 'F') {
			long double v = strtold(buf, &end);
			if (end == buf) return count;
			if (!skip) {
				void *p = va_arg(ap, void *);
				if (len == L_BIGL) *(long double *)p = v;
				else if (len == L_L) *(double *)p = (double)v;
				else *(float *)p = (float)v;
				count++;
			}
		} else {
			int base = conv == 'd' || conv == 'u' ? 10 : conv == 'o' ? 8 :
			           conv == 'x' || conv == 'X' || conv == 'p' ? 16 : 0;
			if (conv != 'd' && conv != 'i' && conv != 'u' && conv != 'o' &&
			    conv != 'x' && conv != 'X' && conv != 'p')
				return count;   /* unknown conversion */
			unsigned long long v = (conv == 'd' || conv == 'i')
				? (unsigned long long)strtoll(buf, &end, base)
				: strtoull(buf, &end, base);
			if (end == buf) return count;
			if (!skip) {
				void *p = va_arg(ap, void *);
				if (conv == 'p') *(void **)p = (void *)(uintptr_t)v;
				else store_int(p, len, v);
				count++;
			}
		}
		s += end - buf;
	}
	return count;
}

int sscanf(const char *str, const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	int n = vsscanf(str, fmt, ap);
	va_end(ap);
	return n;
}

/* Stream scanning: one line, then the string scanner. */
int vfscanf(FILE *f, const char *fmt, va_list ap)
{
	char line[4096];
	if (!fgets(line, sizeof line, f)) return EOF;
	return vsscanf(line, fmt, ap);
}

int fscanf(FILE *f, const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	int n = vfscanf(f, fmt, ap);
	va_end(ap);
	return n;
}

int scanf(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	int n = vfscanf(stdin, fmt, ap);
	va_end(ap);
	return n;
}
