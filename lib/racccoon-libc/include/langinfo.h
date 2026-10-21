#ifndef _LANGINFO_H
#define _LANGINFO_H
#ifdef __cplusplus
extern "C" {
#endif

/* nl_langinfo for the C locale (src/locale.c). */

#ifndef __RC_LOCALE_T
#define __RC_LOCALE_T
typedef struct __rc_locale *locale_t;
#endif

typedef int nl_item;

#define CODESET     0
#define RADIXCHAR   1
#define THOUSEP     2
#define D_T_FMT     3
#define D_FMT       4
#define T_FMT       5
#define T_FMT_AMPM  6
#define AM_STR      7
#define PM_STR      8
#define DAY_1       9    /* ..DAY_7 = 15 */
#define DAY_2       10
#define DAY_3       11
#define DAY_4       12
#define DAY_5       13
#define DAY_6       14
#define DAY_7       15
#define ABDAY_1     16   /* ..ABDAY_7 = 22 */
#define ABDAY_2     17
#define ABDAY_3     18
#define ABDAY_4     19
#define ABDAY_5     20
#define ABDAY_6     21
#define ABDAY_7     22
#define MON_1       23   /* ..MON_12 = 34 */
#define MON_2       24
#define MON_3       25
#define MON_4       26
#define MON_5       27
#define MON_6       28
#define MON_7       29
#define MON_8       30
#define MON_9       31
#define MON_10      32
#define MON_11      33
#define MON_12      34
#define ABMON_1     35   /* ..ABMON_12 = 46 */
#define ABMON_2     36
#define ABMON_3     37
#define ABMON_4     38
#define ABMON_5     39
#define ABMON_6     40
#define ABMON_7     41
#define ABMON_8     42
#define ABMON_9     43
#define ABMON_10    44
#define ABMON_11    45
#define ABMON_12    46
#define ERA         47
#define ERA_D_FMT   48
#define ALT_DIGITS  49
#define ERA_D_T_FMT 50
#define ERA_T_FMT   51
#define YESEXPR     52
#define NOEXPR      53
#define CRNCYSTR    54

char *nl_langinfo(nl_item item);
char *nl_langinfo_l(nl_item item, locale_t l);

#ifdef __cplusplus
}
#endif
#endif
