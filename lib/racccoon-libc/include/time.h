#ifndef _TIME_H
#define _TIME_H
#ifdef __cplusplus
extern "C" {
#endif

#include <sys/types.h>

/* racccoon has no real-time clock. time() returns a fixed build-era
 * timestamp and localtime()/gmtime() decode it — enough for a compiler's
 * __DATE__ / __TIME__ and nothing more. clock() counts from the `time`
 * CSR (SYS_TIMEBASE Hz). */

typedef long clock_t;

#define CLOCKS_PER_SEC 1000000L

#ifndef __RC_TIMESPEC
#define __RC_TIMESPEC
struct timespec {
	time_t tv_sec;
	long   tv_nsec;
};
#endif

/* CLOCK_MONOTONIC counts the `time` CSR from boot; CLOCK_REALTIME is the
 * fixed build-era timestamp (src/time.c) plus that uptime. */
typedef int clockid_t;
#define CLOCK_REALTIME  0
#define CLOCK_MONOTONIC 1
#define TIME_UTC        1

#ifndef __RC_LOCALE_T
#define __RC_LOCALE_T
typedef struct __rc_locale *locale_t;
#endif

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
struct tm *localtime_r(const time_t *t, struct tm *out);
struct tm *gmtime_r(const time_t *t, struct tm *out);
size_t     strftime_l(char *s, size_t max, const char *fmt, const struct tm *tm, locale_t l);
int        clock_gettime(clockid_t clk, struct timespec *ts);
int        clock_getres(clockid_t clk, struct timespec *ts);
int        nanosleep(const struct timespec *req, struct timespec *rem);
int        timespec_get(struct timespec *ts, int base);

#ifdef __cplusplus
}
#endif
#endif
