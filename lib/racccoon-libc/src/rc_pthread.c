/* Stub pthreads for racccoon (single-core cooperative kernel — no real
 * threads). c3c only reaches these when build_threads > 1, which never
 * happens on racccoon (cpus() returns 1), so pthread_create aborts
 * rather than pretend. The mutex/attr calls are honest no-ops. */
#include <pthread.h>
#include <stdlib.h>
#include <stdio.h>

int pthread_create(pthread_t *t, const pthread_attr_t *a, void *(*fn)(void *), void *arg)
{
	(void)t; (void)a; (void)fn; (void)arg;
	fprintf(stderr, "racccoon: pthread_create unsupported (build single-threaded)\n");
	abort();
}
int pthread_join(pthread_t t, void **r) { (void)t; (void)r; return 0; }
void pthread_exit(void *r) { (void)r; abort(); }
pthread_t pthread_self(void) { return 0; }

int pthread_attr_init(pthread_attr_t *a) { (void)a; return 0; }
int pthread_attr_destroy(pthread_attr_t *a) { (void)a; return 0; }
int pthread_attr_setstacksize(pthread_attr_t *a, size_t s) { (void)a; (void)s; return 0; }

int pthread_mutex_init(pthread_mutex_t *m, const pthread_mutexattr_t *a) { (void)a; if (m) m->_lock = 0; return 0; }
int pthread_mutex_destroy(pthread_mutex_t *m) { (void)m; return 0; }
int pthread_mutex_lock(pthread_mutex_t *m) { (void)m; return 0; }
int pthread_mutex_unlock(pthread_mutex_t *m) { (void)m; return 0; }
int pthread_mutex_trylock(pthread_mutex_t *m) { (void)m; return 0; }

int pthread_cond_init(pthread_cond_t *c, const pthread_condattr_t *a) { (void)c; (void)a; return 0; }
int pthread_cond_destroy(pthread_cond_t *c) { (void)c; return 0; }
int pthread_cond_wait(pthread_cond_t *c, pthread_mutex_t *m) { (void)c; (void)m; return 0; }
int pthread_cond_signal(pthread_cond_t *c) { (void)c; return 0; }
int pthread_cond_broadcast(pthread_cond_t *c) { (void)c; return 0; }
