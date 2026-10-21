#ifndef _WCTYPE_H
#define _WCTYPE_H
#ifdef __cplusplus
extern "C" {
#endif

/* Wide-character classes in the C locale: ASCII rules, nothing above
 * 0x7f belongs to any class (src/wchar.c). */

#include <wchar.h>

typedef unsigned long wctype_t;
typedef const int *wctrans_t;

int iswalnum(wint_t c);
int iswalpha(wint_t c);
int iswblank(wint_t c);
int iswcntrl(wint_t c);
int iswdigit(wint_t c);
int iswgraph(wint_t c);
int iswlower(wint_t c);
int iswprint(wint_t c);
int iswpunct(wint_t c);
int iswspace(wint_t c);
int iswupper(wint_t c);
int iswxdigit(wint_t c);
wint_t towlower(wint_t c);
wint_t towupper(wint_t c);
wctype_t  wctype(const char *name);
int       iswctype(wint_t c, wctype_t t);
wctrans_t wctrans(const char *name);
wint_t    towctrans(wint_t c, wctrans_t t);

int iswalnum_l(wint_t c, locale_t l);
int iswalpha_l(wint_t c, locale_t l);
int iswblank_l(wint_t c, locale_t l);
int iswcntrl_l(wint_t c, locale_t l);
int iswdigit_l(wint_t c, locale_t l);
int iswgraph_l(wint_t c, locale_t l);
int iswlower_l(wint_t c, locale_t l);
int iswprint_l(wint_t c, locale_t l);
int iswpunct_l(wint_t c, locale_t l);
int iswspace_l(wint_t c, locale_t l);
int iswupper_l(wint_t c, locale_t l);
int iswxdigit_l(wint_t c, locale_t l);
int iswctype_l(wint_t c, wctype_t t, locale_t l);
wint_t towlower_l(wint_t c, locale_t l);
wint_t towupper_l(wint_t c, locale_t l);

#ifdef __cplusplus
}
#endif
#endif
