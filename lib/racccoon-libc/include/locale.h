#ifndef _LOCALE_H
#define _LOCALE_H
#ifdef __cplusplus
extern "C" {
#endif

/* Only the "C" (= "POSIX") locale exists: single-byte characters, ASCII
 * classification, '.' as the decimal point. The POSIX-2008 locale_t API
 * is there because libc++ builds its <locale> on it (src/locale.c). */

#include <stddef.h>

#define LC_CTYPE    0
#define LC_NUMERIC  1
#define LC_TIME     2
#define LC_COLLATE  3
#define LC_MONETARY 4
#define LC_MESSAGES 5
#define LC_ALL      6

#define LC_CTYPE_MASK    (1 << LC_CTYPE)
#define LC_NUMERIC_MASK  (1 << LC_NUMERIC)
#define LC_TIME_MASK     (1 << LC_TIME)
#define LC_COLLATE_MASK  (1 << LC_COLLATE)
#define LC_MONETARY_MASK (1 << LC_MONETARY)
#define LC_MESSAGES_MASK (1 << LC_MESSAGES)
#define LC_ALL_MASK      0x3f

struct lconv {
	char *decimal_point, *thousands_sep, *grouping;
	char *int_curr_symbol, *currency_symbol, *mon_decimal_point;
	char *mon_thousands_sep, *mon_grouping, *positive_sign, *negative_sign;
	char int_frac_digits, frac_digits, p_cs_precedes, p_sep_by_space;
	char n_cs_precedes, n_sep_by_space, p_sign_posn, n_sign_posn;
	char int_p_cs_precedes, int_p_sep_by_space, int_n_cs_precedes;
	char int_n_sep_by_space, int_p_sign_posn, int_n_sign_posn;
};

#ifndef __RC_LOCALE_T
#define __RC_LOCALE_T
typedef struct __rc_locale *locale_t;
#endif
#define LC_GLOBAL_LOCALE ((locale_t)-1)

char         *setlocale(int category, const char *name);
struct lconv *localeconv(void);
locale_t      newlocale(int mask, const char *name, locale_t base);
locale_t      duplocale(locale_t l);
void          freelocale(locale_t l);
locale_t      uselocale(locale_t l);

#ifdef __cplusplus
}
#endif
#endif
