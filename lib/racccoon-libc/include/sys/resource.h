#ifndef _SYS_RESOURCE_H
#define _SYS_RESOURCE_H
#ifdef __cplusplus
extern "C" {
#endif

/* Resource limits and usage (src/rc_proc.c). racccoon enforces its
 * limits in the kernel (heap cap, exec cap); getrlimit reports them as
 * unlimited and setrlimit accepts and ignores. getrusage reports the time
 * since the program started as user time — there's no per-process CPU
 * accounting. */

#include <sys/time.h>

typedef unsigned long rlim_t;
#define RLIM_INFINITY (~0UL)

struct rlimit { rlim_t rlim_cur, rlim_max; };

#define RLIMIT_CPU     0
#define RLIMIT_FSIZE   1
#define RLIMIT_DATA    2
#define RLIMIT_STACK   3
#define RLIMIT_CORE    4
#define RLIMIT_RSS     5
#define RLIMIT_NPROC   6
#define RLIMIT_NOFILE  7
#define RLIMIT_MEMLOCK 8
#define RLIMIT_AS      9
#define RLIM_NLIMITS   16

#define RUSAGE_SELF     0
#define RUSAGE_CHILDREN (-1)

struct rusage {
	struct timeval ru_utime, ru_stime;
	long ru_maxrss, ru_ixrss, ru_idrss, ru_isrss, ru_minflt, ru_majflt, ru_nswap;
	long ru_inblock, ru_oublock, ru_msgsnd, ru_msgrcv, ru_nsignals, ru_nvcsw, ru_nivcsw;
};

int getrlimit(int resource, struct rlimit *r);
int setrlimit(int resource, const struct rlimit *r);
int getrusage(int who, struct rusage *u);

#ifdef __cplusplus
}
#endif
#endif
