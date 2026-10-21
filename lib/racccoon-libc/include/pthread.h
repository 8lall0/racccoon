/* pthread.h — racccoon libc. A C program has one thread: these exist so
 * hosted code compiles (c3c's taskqueue.c) and so libc++'s thread layer
 * (std::mutex, std::call_once, thread-specific storage) works in a
 * single-threaded program — the way LLVM runs on racccoon. src/rc_pthread.c:
 * mutexes count their owner's locks (a non-recursive relock is a
 * deadlock and aborts), once/keys are real, waiting on a condition with
 * nobody to signal it aborts (or times out), pthread_create aborts. */
#ifndef _RACCCOON_PTHREAD_H
#define _RACCCOON_PTHREAD_H
#ifdef __cplusplus
extern "C" {
#endif

#include <stddef.h>
#include <sched.h>
#include <time.h>

typedef unsigned long pthread_t;
typedef struct { int _dummy; } pthread_attr_t;
typedef struct { int _count; int _type; } pthread_mutex_t;
typedef struct { int _type; } pthread_mutexattr_t;
typedef struct { int _dummy; } pthread_cond_t;
typedef struct { int _dummy; } pthread_condattr_t;
typedef int pthread_once_t;
typedef unsigned pthread_key_t;

#define PTHREAD_MUTEX_NORMAL     0
#define PTHREAD_MUTEX_RECURSIVE  1
#define PTHREAD_MUTEX_ERRORCHECK 2
#define PTHREAD_MUTEX_DEFAULT    PTHREAD_MUTEX_NORMAL
#define PTHREAD_MUTEX_INITIALIZER { 0, PTHREAD_MUTEX_NORMAL }
#define PTHREAD_RECURSIVE_MUTEX_INITIALIZER { 0, PTHREAD_MUTEX_RECURSIVE }
#define PTHREAD_COND_INITIALIZER  { 0 }
#define PTHREAD_ONCE_INIT 0
#define PTHREAD_KEYS_MAX 128

int  pthread_create(pthread_t *, const pthread_attr_t *, void *(*)(void *), void *);
int  pthread_join(pthread_t, void **);
int  pthread_detach(pthread_t);
void pthread_exit(void *);
pthread_t pthread_self(void);
int  pthread_equal(pthread_t, pthread_t);

int pthread_attr_init(pthread_attr_t *);
int pthread_attr_destroy(pthread_attr_t *);
int pthread_attr_setstacksize(pthread_attr_t *, size_t);

int pthread_mutexattr_init(pthread_mutexattr_t *);
int pthread_mutexattr_destroy(pthread_mutexattr_t *);
int pthread_mutexattr_settype(pthread_mutexattr_t *, int);
int pthread_mutexattr_gettype(const pthread_mutexattr_t *, int *);

int pthread_mutex_init(pthread_mutex_t *, const pthread_mutexattr_t *);
int pthread_mutex_destroy(pthread_mutex_t *);
int pthread_mutex_lock(pthread_mutex_t *);
int pthread_mutex_unlock(pthread_mutex_t *);
int pthread_mutex_trylock(pthread_mutex_t *);

int pthread_cond_init(pthread_cond_t *, const pthread_condattr_t *);
int pthread_cond_destroy(pthread_cond_t *);
int pthread_cond_wait(pthread_cond_t *, pthread_mutex_t *);
int pthread_cond_timedwait(pthread_cond_t *, pthread_mutex_t *, const struct timespec *);
int pthread_cond_signal(pthread_cond_t *);
int pthread_cond_broadcast(pthread_cond_t *);

int pthread_once(pthread_once_t *, void (*)(void));

int   pthread_key_create(pthread_key_t *, void (*)(void *));
int   pthread_key_delete(pthread_key_t);
void *pthread_getspecific(pthread_key_t);
int   pthread_setspecific(pthread_key_t, const void *);

#ifdef __cplusplus
}
#endif
#endif
