/* <locale.h>: the "C" locale, and nothing else. newlocale() hands back
 * the one static locale object for "C", "POSIX" or "" (the default
 * environment locale, which is C here) and fails with ENOENT for any
 * other name, so callers asking for e.g. "de_DE" learn it isn't there. */
#include <locale.h>
#include <string.h>
#include <errno.h>

struct __rc_locale { int unused; };
static struct __rc_locale c_locale;
static locale_t current = LC_GLOBAL_LOCALE;

static int is_c(const char *name)
{
	return !name || !*name || !strcmp(name, "C") || !strcmp(name, "POSIX")
	    || !strncmp(name, "C.", 2);   /* "C.UTF-8" and friends: still C here */
}

char *setlocale(int category, const char *name)
{
	if (category < LC_CTYPE || category > LC_ALL) return 0;
	return is_c(name) ? (char *)"C" : 0;
}

static struct lconv c_lconv = {
	".", "", "", "", "", "", "", "", "", "",
	127, 127, 127, 127, 127, 127, 127, 127,
	127, 127, 127, 127, 127, 127,
};

struct lconv *localeconv(void) { return &c_lconv; }

locale_t newlocale(int mask, const char *name, locale_t base)
{
	(void)base;
	if (mask & ~LC_ALL_MASK) { errno = EINVAL; return 0; }
	if (!is_c(name)) { errno = ENOENT; return 0; }
	return &c_locale;
}

locale_t duplocale(locale_t l) { (void)l; return &c_locale; }
void freelocale(locale_t l) { (void)l; }

locale_t uselocale(locale_t l)
{
	locale_t old = current;
	if (l) current = l;
	return old;
}

/* nl_langinfo: the C locale's strings. */
#include <langinfo.h>

static const char *const c_langinfo[] = {
	[CODESET] = "ANSI_X3.4-1968", [RADIXCHAR] = ".", [THOUSEP] = "",
	[D_T_FMT] = "%a %b %e %H:%M:%S %Y", [D_FMT] = "%m/%d/%y", [T_FMT] = "%H:%M:%S",
	[T_FMT_AMPM] = "%I:%M:%S %p", [AM_STR] = "AM", [PM_STR] = "PM",
	[DAY_1] = "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
	[ABDAY_1] = "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat",
	[MON_1] = "January", "February", "March", "April", "May", "June", "July",
	"August", "September", "October", "November", "December",
	[ABMON_1] = "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
	[ERA] = "", [ERA_D_FMT] = "", [ALT_DIGITS] = "", [ERA_D_T_FMT] = "", [ERA_T_FMT] = "",
	[YESEXPR] = "^[yY]", [NOEXPR] = "^[nN]", [CRNCYSTR] = "-",
};

char *nl_langinfo(nl_item item)
{
	if (item < 0 || item >= (nl_item)(sizeof(c_langinfo) / sizeof(*c_langinfo)) || !c_langinfo[item])
		return (char *)"";
	return (char *)c_langinfo[item];
}

char *nl_langinfo_l(nl_item item, locale_t l) { (void)l; return nl_langinfo(item); }
