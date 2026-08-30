/* <time.h> — racccoon has no real-time clock, so the wall-clock side is
 * a fixed build-era timestamp (enough for a compiler's __DATE__ /
 * __TIME__). clock() / gettimeofday() are real: they read the `time`
 * CSR, whose rate SYS_TIMEBASE reports. */
#include <time.h>
#include <sys/time.h>
#include <unistd.h>
#include <string.h>

/* 2026-06-01 00:00:00 UTC. Recomputed only if someone cares. */
#define RC_FIXED_TIME  ((time_t)1780272000)

static const struct tm rc_fixed_tm = {
	.tm_sec = 0, .tm_min = 0, .tm_hour = 0,
	.tm_mday = 1, .tm_mon = 5, .tm_year = 126,   /* Jun 2026 */
	.tm_wday = 1, .tm_yday = 151, .tm_isdst = 0,
};

static unsigned long rc_rdtime(void)
{
	unsigned long t;
	__asm__ volatile ("rdtime %0" : "=r"(t));
	return t;
}

time_t time(time_t *t)
{
	if (t) *t = RC_FIXED_TIME;
	return RC_FIXED_TIME;
}

struct tm *localtime(const time_t *t) { (void)t; return (struct tm *)&rc_fixed_tm; }
struct tm *gmtime(const time_t *t)    { (void)t; return (struct tm *)&rc_fixed_tm; }

double difftime(time_t a, time_t b) { return (double)(a - b); }

time_t mktime(struct tm *tm) { (void)tm; return RC_FIXED_TIME; }

char *asctime(const struct tm *tm)
{
	(void)tm;
	static char b[] = "Mon Jun  1 00:00:00 2026\n";
	return b;
}

char *ctime(const time_t *t) { (void)t; return asctime(&rc_fixed_tm); }

size_t strftime(char *s, size_t max, const char *fmt, const struct tm *tm)
{
	(void)fmt; (void)tm;
	if (max == 0) return 0;
	s[0] = 0;
	return 0;
}

clock_t clock(void)
{
	unsigned long hz = __rc_timebase_hz();
	if (hz == 0) return -1;
	/* scale ticks -> CLOCKS_PER_SEC (1e6) without overflowing */
	unsigned long t = rc_rdtime();
	return (clock_t)((t / hz) * CLOCKS_PER_SEC + ((t % hz) * CLOCKS_PER_SEC) / hz);
}

int gettimeofday(struct timeval *tv, void *tz)
{
	if (tz) memset(tz, 0, sizeof(struct timezone));
	if (tv) {
		unsigned long hz = __rc_timebase_hz();
		unsigned long t  = rc_rdtime();
		if (hz == 0) hz = 1;
		tv->tv_sec  = (time_t)(t / hz);
		tv->tv_usec = (long)(((t % hz) * 1000000UL) / hz);
	}
	return 0;
}
