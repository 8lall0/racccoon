#ifndef _TIME_H
#define _TIME_H

#include <sys/types.h>

/* racccoon has no real-time clock. time() returns a fixed build-era
 * timestamp and localtime()/gmtime() decode it — enough for a compiler's
 * __DATE__ / __TIME__ and nothing more. clock() counts from the `time`
 * CSR (SYS_TIMEBASE Hz). */

typedef long clock_t;

#define CLOCKS_PER_SEC 1000000L

struct tm {
	int tm_sec;
	int tm_min;
	int tm_hour;
	int tm_mday;
	int tm_mon;
	int tm_year;
	int tm_wday;
	int tm_yday;
	int tm_isdst;
};

time_t     time(time_t *t);
struct tm *localtime(const time_t *t);
struct tm *gmtime(const time_t *t);
char      *asctime(const struct tm *tm);
char      *ctime(const time_t *t);
size_t     strftime(char *s, size_t max, const char *fmt, const struct tm *tm);
double     difftime(time_t a, time_t b);
time_t     mktime(struct tm *tm);
clock_t    clock(void);

#endif
