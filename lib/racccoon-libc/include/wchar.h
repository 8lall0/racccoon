#ifndef _RACCCOON_WCHAR_H
#define _RACCCOON_WCHAR_H
#ifdef __cplusplus
extern "C" {
#endif

/* Wide characters in the C locale (the only one, <locale.h>): a
 * multibyte character is one byte, and it converts to the wide character
 * with the same value; a wide character above 0xff has no multibyte form
 * (EILSEQ). src/wchar.c. */

#include <stddef.h>
#include <stdarg.h>

#ifndef __cplusplus   /* a keyword in C++ */
typedef int wchar_t;
#endif
typedef int wint_t;
typedef struct { unsigned __opaque[2]; } mbstate_t;
#define WEOF ((wint_t)-1)

/* C11: <wchar.h> declares struct tm (for wcsftime) and FILE (for the
 * wide stdio functions). */
struct tm;
#ifndef __RC_FILE_T
#define __RC_FILE_T
typedef struct __FILE FILE;
#endif
#define WCHAR_MIN (-2147483647 - 1)
#define WCHAR_MAX 2147483647

#ifndef __RC_LOCALE_T
#define __RC_LOCALE_T
typedef struct __rc_locale *locale_t;
#endif

size_t   wcslen(const wchar_t *s);
wchar_t *wcscpy(wchar_t *d, const wchar_t *s);
wchar_t *wcsncpy(wchar_t *d, const wchar_t *s, size_t n);
wchar_t *wcscat(wchar_t *d, const wchar_t *s);
wchar_t *wcsncat(wchar_t *d, const wchar_t *s, size_t n);
int      wcscmp(const wchar_t *a, const wchar_t *b);
int      wcsncmp(const wchar_t *a, const wchar_t *b, size_t n);
int      wcscoll(const wchar_t *a, const wchar_t *b);
size_t   wcsxfrm(wchar_t *d, const wchar_t *s, size_t n);
int      wcscoll_l(const wchar_t *a, const wchar_t *b, locale_t l);
size_t   wcsxfrm_l(wchar_t *d, const wchar_t *s, size_t n, locale_t l);
wchar_t *wcschr(const wchar_t *s, wchar_t c);
wchar_t *wcsrchr(const wchar_t *s, wchar_t c);
size_t   wcsspn(const wchar_t *s, const wchar_t *accept);
size_t   wcscspn(const wchar_t *s, const wchar_t *reject);
wchar_t *wcspbrk(const wchar_t *s, const wchar_t *accept);
wchar_t *wcsstr(const wchar_t *h, const wchar_t *n);
wchar_t *wcstok(wchar_t *s, const wchar_t *delim, wchar_t **save);
wchar_t *wmemchr(const wchar_t *s, wchar_t c, size_t n);
int      wmemcmp(const wchar_t *a, const wchar_t *b, size_t n);
wchar_t *wmemcpy(wchar_t *d, const wchar_t *s, size_t n);
wchar_t *wmemmove(wchar_t *d, const wchar_t *s, size_t n);
wchar_t *wmemset(wchar_t *d, wchar_t c, size_t n);

long               wcstol(const wchar_t *s, wchar_t **end, int base);
unsigned long      wcstoul(const wchar_t *s, wchar_t **end, int base);
long long          wcstoll(const wchar_t *s, wchar_t **end, int base);
unsigned long long wcstoull(const wchar_t *s, wchar_t **end, int base);
double             wcstod(const wchar_t *s, wchar_t **end);
float              wcstof(const wchar_t *s, wchar_t **end);
long double        wcstold(const wchar_t *s, wchar_t **end);

wint_t btowc(int c);
int    wctob(wint_t c);
int    mbsinit(const mbstate_t *ps);
size_t mbrlen(const char *s, size_t n, mbstate_t *ps);
size_t mbrtowc(wchar_t *pwc, const char *s, size_t n, mbstate_t *ps);
size_t wcrtomb(char *s, wchar_t wc, mbstate_t *ps);
size_t mbsrtowcs(wchar_t *d, const char **src, size_t n, mbstate_t *ps);
size_t mbsnrtowcs(wchar_t *d, const char **src, size_t nms, size_t n, mbstate_t *ps);
size_t wcsrtombs(char *d, const wchar_t **src, size_t n, mbstate_t *ps);
size_t wcsnrtombs(char *d, const wchar_t **src, size_t nwc, size_t n, mbstate_t *ps);

/* wide stdio over the byte stdio (C locale) */
wint_t   fgetwc(FILE *f);
wint_t   getwc(FILE *f);
wint_t   getwchar(void);
wint_t   ungetwc(wint_t c, FILE *f);
wint_t   fputwc(wchar_t c, FILE *f);
wint_t   putwc(wchar_t c, FILE *f);
wint_t   putwchar(wchar_t c);
int      fputws(const wchar_t *s, FILE *f);
wchar_t *fgetws(wchar_t *s, int n, FILE *f);
int      fwide(FILE *f, int mode);
int swprintf(wchar_t *s, size_t n, const wchar_t *fmt, ...);
int vswprintf(wchar_t *s, size_t n, const wchar_t *fmt, va_list ap);

#ifdef __cplusplus
}
#endif
#endif
