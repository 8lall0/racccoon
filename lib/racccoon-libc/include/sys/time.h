#ifndef _SYS_TIME_H
#define _SYS_TIME_H

#include <sys/types.h>

struct timeval {
	time_t tv_sec;
	long   tv_usec;
};

struct timezone {
	int tz_minuteswest;
	int tz_dsttime;
};

/* No wall clock — fills the struct from the `time` CSR (µs since boot)
 * so a bench delta is still meaningful; tz is zeroed. Always returns 0. */
int gettimeofday(struct timeval *tv, void *tz);

#endif
