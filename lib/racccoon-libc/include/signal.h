#ifndef _RACCCOON_SIGNAL_H
#define _RACCCOON_SIGNAL_H
#ifdef __cplusplus
extern "C" {
#endif
typedef int sig_atomic_t;
#define SIGINT   2
#define SIGABRT  6
#define SIGKILL  9
#define SIGSEGV  11
#define SIGTERM  15
#define SIG_DFL  ((void (*)(int))0)
#define SIG_IGN  ((void (*)(int))1)
#define SIG_ERR  ((void (*)(int))-1)
void (*signal(int, void (*)(int)))(int);
int raise(int);
int kill(int, int);   /* posts the note the signal stands for — lib/racccoon-libc/src/rc_signal.c */
#ifdef __cplusplus
}
#endif
#endif
