/* <time.h> — racccoon has no real-time clock, so the wall-clock side is
 * a fixed build-era timestamp (enough for a compiler's __DATE__ /
 * __TIME__). clock() / gettimeofday() are real: they read the `time`
 * CSR, whose rate SYS_TIMEBASE reports. */
#include <time.h>
#include <sys/time.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <racccoon/syscall.h>

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

struct tm *localtime_r(const time_t *t, struct tm *out) { (void)t; *out = rc_fixed_tm; return out; }
struct tm *gmtime_r(const time_t *t, struct tm *out)    { (void)t; *out = rc_fixed_tm; return out; }

size_t strftime_l(char *s, size_t max, const char *fmt, const struct tm *tm, locale_t l)
{
	(void)l;   /* the C locale is the only one */
	return strftime(s, max, fmt, tm);
}

int clock_gettime(clockid_t clk, struct timespec *ts)
{
	unsigned long hz = __rc_timebase_hz();
	if (hz == 0) hz = 1;
	if (clk != CLOCK_REALTIME && clk != CLOCK_MONOTONIC) { errno = EINVAL; return -1; }
	unsigned long t = rc_rdtime();
	ts->tv_sec  = (time_t)(t / hz);
	ts->tv_nsec = (long)(((t % hz) * 1000000000UL) / hz);
	if (clk == CLOCK_REALTIME) ts->tv_sec += RC_FIXED_TIME;
	return 0;
}

int clock_getres(clockid_t clk, struct timespec *ts)
{
	if (clk != CLOCK_REALTIME && clk != CLOCK_MONOTONIC) { errno = EINVAL; return -1; }
	unsigned long hz = __rc_timebase_hz();
	if (ts) { ts->tv_sec = 0; ts->tv_nsec = hz ? (long)(1000000000UL / hz) : 1; }
	return 0;
}

int timespec_get(struct timespec *ts, int base)
{
	return base == TIME_UTC && clock_gettime(CLOCK_REALTIME, ts) == 0 ? base : 0;
}

/* A real sleep: SYS_AWAIT with nothing to wait for but its timeout (in
 * `time` ticks). A note ends it early, as EINTR. */
#define RC_AW_NOTE 8
int nanosleep(const struct timespec *req, struct timespec *rem)
{
	if (req->tv_sec < 0 || req->tv_nsec < 0 || req->tv_nsec >= 1000000000L) { errno = EINVAL; return -1; }
	unsigned long hz = __rc_timebase_hz();
	if (hz == 0) return 0;
	unsigned long ticks = (unsigned long)req->tv_sec * hz + ((unsigned long)req->tv_nsec * hz) / 1000000000UL;
	if (ticks == 0) return 0;
	unsigned long start = rc_rdtime();
	long r = __rc_syscall5(0, (long)ticks, 0, 0, 0, RC_SYS_AWAIT);
	if (r >= 0 && (r & RC_AW_NOTE)) {
		if (rem) {
			unsigned long done = rc_rdtime() - start;
			unsigned long left = done < ticks ? ticks - done : 0;
			rem->tv_sec = (time_t)(left / hz);
			rem->tv_nsec = (long)(((left % hz) * 1000000000UL) / hz);
		}
		errno = EINTR;
		return -1;
	}
	if (rem) { rem->tv_sec = 0; rem->tv_nsec = 0; }
	return 0;
}
