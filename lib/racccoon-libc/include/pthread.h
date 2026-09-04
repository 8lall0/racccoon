/* pthread.h — racccoon libc. Single-core cooperative kernel: there is no
 * real threading. These declarations exist so hosted programs (c3c's
 * taskqueue.c) COMPILE; the stubs (src/rc_pthread.c) assume the caller
 * only ever uses the single-threaded path (c3c: build_threads == 1). */
#ifndef _RACCCOON_PTHREAD_H
#define _RACCCOON_PTHREAD_H
#include <stddef.h>

typedef unsigned long pthread_t;
typedef struct { int _dummy; } pthread_attr_t;
typedef struct { int _lock; } pthread_mutex_t;
typedef struct { int _dummy; } pthread_mutexattr_t;
typedef struct { int _dummy; } pthread_cond_t;
typedef struct { int _dummy; } pthread_condattr_t;

#define PTHREAD_MUTEX_INITIALIZER { 0 }
#define PTHREAD_COND_INITIALIZER  { 0 }

int  pthread_create(pthread_t *, const pthread_attr_t *, void *(*)(void *), void *);
int  pthread_join(pthread_t, void **);
void pthread_exit(void *);
pthread_t pthread_self(void);

int pthread_attr_init(pthread_attr_t *);
int pthread_attr_destroy(pthread_attr_t *);
int pthread_attr_setstacksize(pthread_attr_t *, size_t);

int pthread_mutex_init(pthread_mutex_t *, const pthread_mutexattr_t *);
int pthread_mutex_destroy(pthread_mutex_t *);
int pthread_mutex_lock(pthread_mutex_t *);
int pthread_mutex_unlock(pthread_mutex_t *);
int pthread_mutex_trylock(pthread_mutex_t *);

int pthread_cond_init(pthread_cond_t *, const pthread_condattr_t *);
int pthread_cond_destroy(pthread_cond_t *);
int pthread_cond_wait(pthread_cond_t *, pthread_mutex_t *);
int pthread_cond_signal(pthread_cond_t *);
int pthread_cond_broadcast(pthread_cond_t *);

#endif
