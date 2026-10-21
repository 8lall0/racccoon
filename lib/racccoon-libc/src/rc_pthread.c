/* pthreads for a single-threaded program (racccoon runs one thread per
 * C program). c3c only reaches pthread_create when build_threads > 1,
 * which never happens on racccoon (cpus() returns 1), so it aborts rather
 * than pretend. Everything else is real for one thread: what libc++'s
 * std::mutex / call_once / thread_local-style keys need. */
#include <pthread.h>
#include <sched.h>
#include <errno.h>
#include <stdlib.h>
#include <stdio.h>
#include <time.h>
#include <racccoon/syscall.h>

static void deadlock(const char *what)
{
	fprintf(stderr, "racccoon: %s would wait forever (single-threaded program)\n", what);
	abort();
}

int pthread_create(pthread_t *t, const pthread_attr_t *a, void *(*fn)(void *), void *arg)
{
	(void)t; (void)a; (void)fn; (void)arg;
	fprintf(stderr, "racccoon: pthread_create unsupported (build single-threaded)\n");
	abort();
}
int pthread_join(pthread_t t, void **r) { (void)t; (void)r; return 0; }
int pthread_detach(pthread_t t) { (void)t; return 0; }
void pthread_exit(void *r) { (void)r; abort(); }
pthread_t pthread_self(void) { return 1; }
int pthread_equal(pthread_t a, pthread_t b) { return a == b; }

int pthread_attr_init(pthread_attr_t *a) { (void)a; return 0; }
int pthread_attr_destroy(pthread_attr_t *a) { (void)a; return 0; }
int pthread_attr_setstacksize(pthread_attr_t *a, size_t s) { (void)a; (void)s; return 0; }

int pthread_mutexattr_init(pthread_mutexattr_t *a) { a->_type = PTHREAD_MUTEX_DEFAULT; return 0; }
int pthread_mutexattr_destroy(pthread_mutexattr_t *a) { (void)a; return 0; }
int pthread_mutexattr_settype(pthread_mutexattr_t *a, int type)
{
	if (type < PTHREAD_MUTEX_NORMAL || type > PTHREAD_MUTEX_ERRORCHECK) return EINVAL;
	a->_type = type;
	return 0;
}
int pthread_mutexattr_gettype(const pthread_mutexattr_t *a, int *type) { *type = a->_type; return 0; }

/* The only thread is the owner whenever _count > 0. */
int pthread_mutex_init(pthread_mutex_t *m, const pthread_mutexattr_t *a)
{
	m->_count = 0;
	m->_type = a ? a->_type : PTHREAD_MUTEX_DEFAULT;
	return 0;
}
int pthread_mutex_destroy(pthread_mutex_t *m) { return m->_count ? EBUSY : 0; }

int pthread_mutex_trylock(pthread_mutex_t *m)
{
	if (m->_count && m->_type != PTHREAD_MUTEX_RECURSIVE) return EBUSY;
	m->_count++;
	return 0;
}

int pthread_mutex_lock(pthread_mutex_t *m)
{
	if (m->_count && m->_type != PTHREAD_MUTEX_RECURSIVE) {
		if (m->_type == PTHREAD_MUTEX_ERRORCHECK) return EDEADLK;
		deadlock("pthread_mutex_lock (relock)");
	}
	m->_count++;
	return 0;
}

int pthread_mutex_unlock(pthread_mutex_t *m)
{
	if (m->_count == 0) return EPERM;
	m->_count--;
	return 0;
}

int pthread_cond_init(pthread_cond_t *c, const pthread_condattr_t *a) { (void)c; (void)a; return 0; }
int pthread_cond_destroy(pthread_cond_t *c) { (void)c; return 0; }
int pthread_cond_signal(pthread_cond_t *c) { (void)c; return 0; }
int pthread_cond_broadcast(pthread_cond_t *c) { (void)c; return 0; }

/* Nobody else exists to signal: an untimed wait never ends. */
int pthread_cond_wait(pthread_cond_t *c, pthread_mutex_t *m)
{
	(void)c; (void)m;
	deadlock("pthread_cond_wait");
	return 0;
}

/* A timed wait just sleeps until the deadline (CLOCK_REALTIME). */
int pthread_cond_timedwait(pthread_cond_t *c, pthread_mutex_t *m, const struct timespec *abstime)
{
	(void)c; (void)m;
	struct timespec now;
	clock_gettime(CLOCK_REALTIME, &now);
	long long ns = (long long)(abstime->tv_sec - now.tv_sec) * 1000000000LL + (abstime->tv_nsec - now.tv_nsec);
	if (ns > 0) {
		struct timespec d = { (time_t)(ns / 1000000000LL), (long)(ns % 1000000000LL) };
		nanosleep(&d, 0);
	}
	return ETIMEDOUT;
}

int pthread_once(pthread_once_t *once, void (*fn)(void))
{
	if (*once == PTHREAD_ONCE_INIT) {
		*once = 1;
		fn();
	}
	return 0;
}

/* Thread-specific data for the one thread. Destructors would run at
 * thread exit, which never happens before the process exits. */
static unsigned char key_used[PTHREAD_KEYS_MAX];
static void *key_value[PTHREAD_KEYS_MAX];

int pthread_key_create(pthread_key_t *k, void (*dtor)(void *))
{
	(void)dtor;
	for (unsigned i = 0; i < PTHREAD_KEYS_MAX; i++) {
		if (!key_used[i]) {
			key_used[i] = 1;
			key_value[i] = 0;
			*k = i;
			return 0;
		}
	}
	return EAGAIN;
}

int pthread_key_delete(pthread_key_t k)
{
	if (k >= PTHREAD_KEYS_MAX || !key_used[k]) return EINVAL;
	key_used[k] = 0;
	return 0;
}

void *pthread_getspecific(pthread_key_t k)
{
	return k < PTHREAD_KEYS_MAX && key_used[k] ? key_value[k] : 0;
}

int pthread_setspecific(pthread_key_t k, const void *v)
{
	if (k >= PTHREAD_KEYS_MAX || !key_used[k]) return EINVAL;
	key_value[k] = (void *)v;
	return 0;
}

int sched_yield(void)
{
	__rc_syscall3(0, 0, 0, RC_SYS_YIELD);
	return 0;
}
