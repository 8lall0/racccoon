#ifndef _RACCCOON_SIGNAL_H
#define _RACCCOON_SIGNAL_H
#ifdef __cplusplus
extern "C" {
#endif

/* Signals on racccoon's notes (src/rc_signal.c): a note the process
 * receives ("interrupt" = ^C, "abort", "kill", anything else) is
 * delivered as SIGINT / SIGABRT / SIGKILL / SIGTERM to the handler
 * signal() or sigaction() installed. Hardware faults kill the process in
 * the kernel and never reach a handler, and there's no masking, so the
 * mask calls only record what was asked. Numbers are the Linux ones. */

#include <sys/types.h>

typedef int sig_atomic_t;
typedef unsigned long sigset_t;

#define SIGHUP    1
#define SIGINT    2
#define SIGQUIT   3
#define SIGILL    4
#define SIGTRAP   5
#define SIGABRT   6
#define SIGIOT    SIGABRT
#define SIGBUS    7
#define SIGFPE    8
#define SIGKILL   9
#define SIGUSR1   10
#define SIGSEGV   11
#define SIGUSR2   12
#define SIGPIPE   13
#define SIGALRM   14
#define SIGTERM   15
#define SIGSTKFLT 16
#define SIGCHLD   17
#define SIGCONT   18
#define SIGSTOP   19
#define SIGTSTP   20
#define SIGTTIN   21
#define SIGTTOU   22
#define SIGURG    23
#define SIGXCPU   24
#define SIGXFSZ   25
#define SIGVTALRM 26
#define SIGPROF   27
#define SIGWINCH  28
#define SIGIO     29
#define SIGPOLL   SIGIO
#define SIGPWR    30
#define SIGSYS    31
#define NSIG      32

#define SIG_DFL  ((void (*)(int))0)
#define SIG_IGN  ((void (*)(int))1)
#define SIG_ERR  ((void (*)(int))-1)

#define SIG_BLOCK   0
#define SIG_UNBLOCK 1
#define SIG_SETMASK 2

#define SA_NOCLDSTOP 0x00000001
#define SA_NOCLDWAIT 0x00000002
#define SA_SIGINFO   0x00000004
#define SA_ONSTACK   0x08000000
#define SA_RESTART   0x10000000
#define SA_NODEFER   0x40000000
#define SA_RESETHAND 0x80000000

union sigval { int sival_int; void *sival_ptr; };

typedef struct {
	int   si_signo;
	int   si_errno;
	int   si_code;
	pid_t si_pid;
	uid_t si_uid;
	void *si_addr;
	int   si_status;
	union sigval si_value;
} siginfo_t;

struct sigaction {
	union {
		void (*sa_handler)(int);
		void (*sa_sigaction)(int, siginfo_t *, void *);
	} __sa;
	sigset_t sa_mask;
	int      sa_flags;
	void   (*sa_restorer)(void);
};
#define sa_handler   __sa.sa_handler
#define sa_sigaction __sa.sa_sigaction

typedef struct { void *ss_sp; int ss_flags; size_t ss_size; } stack_t;
#define SS_ONSTACK  1
#define SS_DISABLE  2
#define MINSIGSTKSZ 2048
#define SIGSTKSZ    8192

void (*signal(int, void (*)(int)))(int);
int raise(int);
int kill(int, int);   /* posts the note the signal stands for */
int sigaction(int sig, const struct sigaction *act, struct sigaction *old);
int sigprocmask(int how, const sigset_t *set, sigset_t *old);
int pthread_sigmask(int how, const sigset_t *set, sigset_t *old);
int sigaltstack(const stack_t *ss, stack_t *old);
int sigemptyset(sigset_t *set);
int sigfillset(sigset_t *set);
int sigaddset(sigset_t *set, int sig);
int sigdelset(sigset_t *set, int sig);
int sigismember(const sigset_t *set, int sig);

#ifdef __cplusplus
}
#endif
#endif
