#ifndef _SCHED_H
#define _SCHED_H
#ifdef __cplusplus
extern "C" {
#endif

struct sched_param { int sched_priority; };

int sched_yield(void);   /* SYS_YIELD: give up the rest of this timeslice */

#ifdef __cplusplus
}
#endif
#endif
