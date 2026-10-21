/* <wchar.h> / <wctype.h> and the multibyte half of <stdlib.h>, for the
 * C locale: one byte per character, byte value = wide value. */
#include <wchar.h>
#include <wctype.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <errno.h>
#include <stdio.h>
#include <stdarg.h>

/* --- strings ----------------------------------------------------------- */

size_t wcslen(const wchar_t *s) { const wchar_t *p = s; while (*p) p++; return (size_t)(p - s); }

wchar_t *wcscpy(wchar_t *d, const wchar_t *s) { wchar_t *r = d; while ((*d++ = *s++)) { } return r; }

wchar_t *wcsncpy(wchar_t *d, const wchar_t *s, size_t n)
{
	size_t i = 0;
	for (; i < n && s[i]; i++) d[i] = s[i];
	for (; i < n; i++) d[i] = 0;
	return d;
}

wchar_t *wcscat(wchar_t *d, const wchar_t *s) { wcscpy(d + wcslen(d), s); return d; }

wchar_t *wcsncat(wchar_t *d, const wchar_t *s, size_t n)
{
	wchar_t *p = d + wcslen(d);
	while (n-- && *s) *p++ = *s++;
	*p = 0;
	return d;
}

int wcscmp(const wchar_t *a, const wchar_t *b)
{
	while (*a && *a == *b) { a++; b++; }
	return *a < *b ? -1 : *a > *b;
}

int wcsncmp(const wchar_t *a, const wchar_t *b, size_t n)
{
	for (; n; n--, a++, b++) {
		if (*a != *b) return *a < *b ? -1 : 1;
		if (!*a) return 0;
	}
	return 0;
}

int wcscoll(const wchar_t *a, const wchar_t *b) { return wcscmp(a, b); }

size_t wcsxfrm(wchar_t *d, const wchar_t *s, size_t n)
{
	size_t len = wcslen(s);
	if (n) wcsncpy(d, s, len < n ? len + 1 : n);
	return len;
}

int wcscoll_l(const wchar_t *a, const wchar_t *b, locale_t l) { (void)l; return wcscoll(a, b); }
size_t wcsxfrm_l(wchar_t *d, const wchar_t *s, size_t n, locale_t l) { (void)l; return wcsxfrm(d, s, n); }

wchar_t *wcschr(const wchar_t *s, wchar_t c)
{
	for (;; s++) {
		if (*s == c) return (wchar_t *)s;
		if (!*s) return 0;
	}
}

wchar_t *wcsrchr(const wchar_t *s, wchar_t c)
{
	const wchar_t *r = 0;
	for (;; s++) {
		if (*s == c) r = s;
		if (!*s) return (wchar_t *)r;
	}
}

size_t wcsspn(const wchar_t *s, const wchar_t *accept)
{
	size_t n = 0;
	while (s[n] && wcschr(accept, s[n])) n++;
	return n;
}

size_t wcscspn(const wchar_t *s, const wchar_t *reject)
{
	size_t n = 0;
	while (s[n] && !wcschr(reject, s[n])) n++;
	return n;
}

wchar_t *wcspbrk(const wchar_t *s, const wchar_t *accept)
{
	s += wcscspn(s, accept);
	return *s ? (wchar_t *)s : 0;
}

wchar_t *wcsstr(const wchar_t *h, const wchar_t *n)
{
	size_t nl = wcslen(n);
	if (!nl) return (wchar_t *)h;
	for (; *h; h++)
		if (*h == *n && !wcsncmp(h, n, nl)) return (wchar_t *)h;
	return 0;
}

wchar_t *wcstok(wchar_t *s, const wchar_t *delim, wchar_t **save)
{
	if (!s) s = *save;
	s += wcsspn(s, delim);
	if (!*s) { *save = s; return 0; }
	wchar_t *end = s + wcscspn(s, delim);
	if (*end) *end++ = 0;
	*save = end;
	return s;
}

wchar_t *wmemchr(const wchar_t *s, wchar_t c, size_t n)
{
	for (; n; n--, s++) if (*s == c) return (wchar_t *)s;
	return 0;
}

int wmemcmp(const wchar_t *a, const wchar_t *b, size_t n)
{
	for (; n; n--, a++, b++) if (*a != *b) return *a < *b ? -1 : 1;
	return 0;
}

wchar_t *wmemcpy(wchar_t *d, const wchar_t *s, size_t n) { return memcpy(d, s, n * sizeof(wchar_t)); }
wchar_t *wmemmove(wchar_t *d, const wchar_t *s, size_t n) { return memmove(d, s, n * sizeof(wchar_t)); }

wchar_t *wmemset(wchar_t *d, wchar_t c, size_t n)
{
	for (size_t i = 0; i < n; i++) d[i] = c;
	return d;
}

/* --- numbers: narrow the (ASCII) digits, parse, map the end back ------- */

#define NARROW(s, buf) do { \
	size_t i_ = 0; \
	while (i_ < sizeof(buf) - 1 && s[i_] > 0 && s[i_] < 0x80) { buf[i_] = (char)s[i_]; i_++; } \
	buf[i_] = 0; \
} while (0)
#define WEND(s, buf, nend, end) do { if (end) *(end) = (wchar_t *)(s) + ((nend) - (buf)); } while (0)

long wcstol(const wchar_t *s, wchar_t **end, int base)
{ char b[128], *e; NARROW(s, b); long r = strtol(b, &e, base); WEND(s, b, e, end); return r; }
unsigned long wcstoul(const wchar_t *s, wchar_t **end, int base)
{ char b[128], *e; NARROW(s, b); unsigned long r = strtoul(b, &e, base); WEND(s, b, e, end); return r; }
long long wcstoll(const wchar_t *s, wchar_t **end, int base)
{ char b[128], *e; NARROW(s, b); long long r = strtoll(b, &e, base); WEND(s, b, e, end); return r; }
unsigned long long wcstoull(const wchar_t *s, wchar_t **end, int base)
{ char b[128], *e; NARROW(s, b); unsigned long long r = strtoull(b, &e, base); WEND(s, b, e, end); return r; }
double wcstod(const wchar_t *s, wchar_t **end)
{ char b[512], *e; NARROW(s, b); double r = strtod(b, &e); WEND(s, b, e, end); return r; }
float wcstof(const wchar_t *s, wchar_t **end)
{ char b[512], *e; NARROW(s, b); float r = strtof(b, &e); WEND(s, b, e, end); return r; }
long double wcstold(const wchar_t *s, wchar_t **end)
{ char b[512], *e; NARROW(s, b); long double r = strtold(b, &e); WEND(s, b, e, end); return r; }

/* --- multibyte <-> wide: one byte each --------------------------------- */

wint_t btowc(int c) { return c == -1 ? WEOF : (wint_t)(unsigned char)c; }
int wctob(wint_t c) { return c >= 0 && c <= 0xff ? c : -1; }
int mbsinit(const mbstate_t *ps) { (void)ps; return 1; }

size_t mbrtowc(wchar_t *pwc, const char *s, size_t n, mbstate_t *ps)
{
	(void)ps;
	if (!s) return 0;
	if (n == 0) return (size_t)-2;
	wchar_t c = (unsigned char)*s;
	if (pwc) *pwc = c;
	return c ? 1 : 0;
}

size_t mbrlen(const char *s, size_t n, mbstate_t *ps) { return mbrtowc(0, s, n, ps); }

size_t wcrtomb(char *s, wchar_t wc, mbstate_t *ps)
{
	(void)ps;
	if (!s) return 1;
	if (wc < 0 || wc > 0xff) { errno = EILSEQ; return (size_t)-1; }
	*s = (char)wc;
	return 1;
}

size_t mbsnrtowcs(wchar_t *d, const char **src, size_t nms, size_t n, mbstate_t *ps)
{
	(void)ps;
	const char *s = *src;
	size_t i = 0;
	while (i < nms && (!d || i < n)) {
		wchar_t c = (unsigned char)s[i];
		if (d) d[i] = c;
		if (!c) { if (d) *src = 0; return i; }
		i++;
	}
	if (d) *src = s + i;
	return i;
}

size_t mbsrtowcs(wchar_t *d, const char **src, size_t n, mbstate_t *ps)
{
	return mbsnrtowcs(d, src, (size_t)-1, n, ps);
}

size_t wcsnrtombs(char *d, const wchar_t **src, size_t nwc, size_t n, mbstate_t *ps)
{
	(void)ps;
	const wchar_t *s = *src;
	size_t i = 0;
	while (i < nwc && (!d || i < n)) {
		wchar_t c = s[i];
		if (c < 0 || c > 0xff) { if (d) *src = s + i; errno = EILSEQ; return (size_t)-1; }
		if (d) d[i] = (char)c;
		if (!c) { if (d) *src = 0; return i; }
		i++;
	}
	if (d) *src = s + i;
	return i;
}

size_t wcsrtombs(char *d, const wchar_t **src, size_t n, mbstate_t *ps)
{
	return wcsnrtombs(d, src, (size_t)-1, n, ps);
}

int mblen(const char *s, size_t n) { return s && n ? (*s != 0) : 0; }

int mbtowc(wchar_t *pwc, const char *s, size_t n)
{
	if (!s) return 0;
	if (!n) return -1;
	if (pwc) *pwc = (unsigned char)*s;
	return *s != 0;
}

int wctomb(char *s, wchar_t wc)
{
	if (!s) return 0;
	if (wc < 0 || wc > 0xff) { errno = EILSEQ; return -1; }
	*s = (char)wc;
	return 1;
}

size_t mbstowcs(wchar_t *d, const char *s, size_t n)
{
	const char *p = s;
	return mbsrtowcs(d, &p, n, 0);
}

size_t wcstombs(char *d, const wchar_t *s, size_t n)
{
	const wchar_t *p = s;
	return wcsrtombs(d, &p, n, 0);
}

/* --- classes ----------------------------------------------------------- */

#define ASCII(c) ((c) >= 0 && (c) < 0x80)
int iswalnum(wint_t c)  { return ASCII(c) && isalnum(c); }
int iswalpha(wint_t c)  { return ASCII(c) && isalpha(c); }
int iswblank(wint_t c)  { return ASCII(c) && isblank(c); }
int iswcntrl(wint_t c)  { return ASCII(c) && iscntrl(c); }
int iswdigit(wint_t c)  { return ASCII(c) && isdigit(c); }
int iswgraph(wint_t c)  { return ASCII(c) && isgraph(c); }
int iswlower(wint_t c)  { return ASCII(c) && islower(c); }
int iswprint(wint_t c)  { return ASCII(c) && isprint(c); }
int iswpunct(wint_t c)  { return ASCII(c) && ispunct(c); }
int iswspace(wint_t c)  { return ASCII(c) && isspace(c); }
int iswupper(wint_t c)  { return ASCII(c) && isupper(c); }
int iswxdigit(wint_t c) { return ASCII(c) && isxdigit(c); }
wint_t towlower(wint_t c) { return ASCII(c) ? tolower(c) : c; }
wint_t towupper(wint_t c) { return ASCII(c) ? toupper(c) : c; }

static const char *const class_names[] = {
	"alnum", "alpha", "blank", "cntrl", "digit", "graph",
	"lower", "print", "punct", "space", "upper", "xdigit",
};
static int (*const class_fns[])(wint_t) = {
	iswalnum, iswalpha, iswblank, iswcntrl, iswdigit, iswgraph,
	iswlower, iswprint, iswpunct, iswspace, iswupper, iswxdigit,
};

wctype_t wctype(const char *name)
{
	for (unsigned i = 0; i < sizeof(class_names) / sizeof(*class_names); i++)
		if (!strcmp(name, class_names[i])) return i + 1;
	return 0;
}

int iswctype(wint_t c, wctype_t t)
{
	return t >= 1 && t <= sizeof(class_fns) / sizeof(*class_fns) ? class_fns[t - 1](c) : 0;
}

static const int trans_lower = 1, trans_upper = 2;
wctrans_t wctrans(const char *name)
{
	if (!strcmp(name, "tolower")) return &trans_lower;
	if (!strcmp(name, "toupper")) return &trans_upper;
	return 0;
}

wint_t towctrans(wint_t c, wctrans_t t)
{
	if (t == &trans_lower) return towlower(c);
	if (t == &trans_upper) return towupper(c);
	return c;
}

int iswalnum_l(wint_t c, locale_t l)  { (void)l; return iswalnum(c); }
int iswalpha_l(wint_t c, locale_t l)  { (void)l; return iswalpha(c); }
int iswblank_l(wint_t c, locale_t l)  { (void)l; return iswblank(c); }
int iswcntrl_l(wint_t c, locale_t l)  { (void)l; return iswcntrl(c); }
int iswdigit_l(wint_t c, locale_t l)  { (void)l; return iswdigit(c); }
int iswgraph_l(wint_t c, locale_t l)  { (void)l; return iswgraph(c); }
int iswlower_l(wint_t c, locale_t l)  { (void)l; return iswlower(c); }
int iswprint_l(wint_t c, locale_t l)  { (void)l; return iswprint(c); }
int iswpunct_l(wint_t c, locale_t l)  { (void)l; return iswpunct(c); }
int iswspace_l(wint_t c, locale_t l)  { (void)l; return iswspace(c); }
int iswupper_l(wint_t c, locale_t l)  { (void)l; return iswupper(c); }
int iswxdigit_l(wint_t c, locale_t l) { (void)l; return iswxdigit(c); }
int iswctype_l(wint_t c, wctype_t t, locale_t l) { (void)l; return iswctype(c, t); }
wint_t towlower_l(wint_t c, locale_t l) { (void)l; return towlower(c); }
wint_t towupper_l(wint_t c, locale_t l) { (void)l; return towupper(c); }

/* --- swprintf: format narrow, widen (byte = wide char in the C locale).
 * Wide string arguments (%ls) aren't supported. */

int vswprintf(wchar_t *s, size_t n, const wchar_t *fmt, va_list ap)
{
	char nfmt[256], out[1024];
	size_t i = 0;
	for (; fmt[i] && i < sizeof nfmt - 1; i++) {
		if (fmt[i] < 0 || fmt[i] > 0xff) { errno = EILSEQ; return -1; }
		nfmt[i] = (char)fmt[i];
	}
	if (fmt[i]) { errno = EOVERFLOW; return -1; }
	nfmt[i] = 0;
	int len = vsnprintf(out, sizeof out, nfmt, ap);
	if (len < 0 || (size_t)len >= sizeof out || (size_t)len >= n) { errno = EOVERFLOW; return -1; }
	for (int k = 0; k <= len; k++) s[k] = (unsigned char)out[k];
	return len;
}

int swprintf(wchar_t *s, size_t n, const wchar_t *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	int r = vswprintf(s, n, fmt, ap);
	va_end(ap);
	return r;
}

/* --- wide stdio: one byte per character ------------------------------- */

wint_t fgetwc(FILE *f) { int c = fgetc(f); return c == EOF ? WEOF : (wint_t)(unsigned char)c; }
wint_t getwc(FILE *f) { return fgetwc(f); }
wint_t getwchar(void) { return fgetwc(stdin); }
wint_t ungetwc(wint_t c, FILE *f)
{
	if (c == WEOF || c < 0 || c > 0xff) return WEOF;
	return ungetc(c, f) == EOF ? WEOF : c;
}
wint_t fputwc(wchar_t c, FILE *f)
{
	if (c < 0 || c > 0xff) { errno = EILSEQ; return WEOF; }
	return fputc(c, f) == EOF ? WEOF : (wint_t)c;
}
wint_t putwc(wchar_t c, FILE *f) { return fputwc(c, f); }
wint_t putwchar(wchar_t c) { return fputwc(c, stdout); }
int fputws(const wchar_t *s, FILE *f)
{
	for (; *s; s++) if (fputwc(*s, f) == WEOF) return -1;
	return 0;
}
wchar_t *fgetws(wchar_t *s, int n, FILE *f)
{
	int i = 0;
	while (i < n - 1) {
		wint_t c = fgetwc(f);
		if (c == WEOF) break;
		s[i++] = c;
		if (c == L'\n') break;
	}
	if (i == 0) return 0;
	s[i] = 0;
	return s;
}
int fwide(FILE *f, int mode) { (void)f; return mode; }   /* no orientation kept */
