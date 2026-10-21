/* signal(2) / raise(3) / kill(2) on racccoon's notes (src/note.c3).
 *
 * A note is a string; the kernel delivers it to one handler per process
 * (SYS_NOTIFY), which must finish with SYS_NOTED. This maps the C
 * names onto that: one note handler, __rc_note, dispatches to whatever
 * signal() installed for the signal a note stands for. "interrupt" (the
 * console's ^C) is SIGINT, "kill" is SIGKILL (the kernel kills on it
 * before any handler runs), anything else is SIGTERM. SIG_DFL = die,
 * SIG_IGN = carry on. */
#include <signal.h>
#include <string.h>
#include <unistd.h>
#include <racccoon/syscall.h>
#include <errno.h>

#define NCONT 0
#define NDFLT 1
#define NSIG_RC 32

/* One sigaction per signal; signal() fills in sa_handler. */
static struct sigaction __rc_sa[NSIG_RC];
static int __rc_notify_on;

static int __rc_note_sig(const char *msg)
{
	if (strcmp(msg, "interrupt") == 0) return SIGINT;
	if (strcmp(msg, "kill") == 0)      return SIGKILL;
	if (strcmp(msg, "abort") == 0)     return SIGABRT;
	return SIGTERM;
}

static const char *__rc_sig_note(int sig)
{
	switch (sig) {
	case SIGINT:  return "interrupt";
	case SIGKILL: return "kill";
	case SIGABRT: return "abort";
	default:      return "terminate";
	}
}

static void __rc_note(char *msg)
{
	int sig = __rc_note_sig(msg);
	struct sigaction *a = &__rc_sa[sig];
	if (a->sa_flags & SA_SIGINFO) {
		siginfo_t info = { 0 };
		info.si_signo = sig;
		a->sa_sigaction(sig, &info, 0);
	} else if (a->sa_handler == SIG_DFL) {
		__rc_syscall3(NDFLT, 0, 0, RC_SYS_NOTED);
	} else if (a->sa_handler != SIG_IGN) {
		a->sa_handler(sig);
	}
	if (a->sa_flags & SA_RESETHAND) {
		a->sa_handler = SIG_DFL;
		a->sa_flags &= ~SA_SIGINFO;
	}
	__rc_syscall3(NCONT, 0, 0, RC_SYS_NOTED);
}

static void __rc_notify(void)
{
	if (!__rc_notify_on) {
		__rc_syscall3((long)__rc_note, 0, 0, RC_SYS_NOTIFY);
		__rc_notify_on = 1;
	}
}

void (*signal(int sig, void (*h)(int)))(int)
{
	if (sig <= 0 || sig >= NSIG_RC || sig == SIGKILL || sig == SIGSTOP) return SIG_ERR;
	void (*old)(int) = (__rc_sa[sig].sa_flags & SA_SIGINFO) ? SIG_DFL : __rc_sa[sig].sa_handler;
	__rc_sa[sig].sa_handler = h;
	__rc_sa[sig].sa_flags = 0;
	__rc_notify();
	return old;
}

int sigaction(int sig, const struct sigaction *act, struct sigaction *old)
{
	if (sig <= 0 || sig >= NSIG_RC || (act && (sig == SIGKILL || sig == SIGSTOP))) {
		errno = EINVAL;
		return -1;
	}
	if (old) *old = __rc_sa[sig];
	if (act) {
		__rc_sa[sig] = *act;
		__rc_notify();
	}
	return 0;
}

/* No masking: the mask is only remembered. */
static sigset_t __rc_mask;

int sigprocmask(int how, const sigset_t *set, sigset_t *old)
{
	if (old) *old = __rc_mask;
	if (!set) return 0;
	switch (how) {
	case SIG_BLOCK:   __rc_mask |= *set; break;
	case SIG_UNBLOCK: __rc_mask &= ~*set; break;
	case SIG_SETMASK: __rc_mask = *set; break;
	default: errno = EINVAL; return -1;
	}
	return 0;
}

int pthread_sigmask(int how, const sigset_t *set, sigset_t *old)
{
	return sigprocmask(how, set, old) ? errno : 0;
}

int sigaltstack(const stack_t *ss, stack_t *old)
{
	(void)ss;
	if (old) { old->ss_sp = 0; old->ss_flags = 2; old->ss_size = 0; }   /* SS_DISABLE */
	return 0;
}

int sigemptyset(sigset_t *set) { *set = 0; return 0; }
int sigfillset(sigset_t *set) { *set = ~0UL; return 0; }
int sigaddset(sigset_t *set, int sig)
{
	if (sig <= 0 || sig >= NSIG) { errno = EINVAL; return -1; }
	*set |= 1UL << sig;
	return 0;
}
int sigdelset(sigset_t *set, int sig)
{
	if (sig <= 0 || sig >= NSIG) { errno = EINVAL; return -1; }
	*set &= ~(1UL << sig);
	return 0;
}
int sigismember(const sigset_t *set, int sig)
{
	if (sig <= 0 || sig >= NSIG) { errno = EINVAL; return -1; }
	return (*set >> sig) & 1;
}

int kill(int pid, int sig)
{
	if (sig == 0) return 0;
	return __rc_syscall3(pid, 0, (long)__rc_sig_note(sig), RC_SYS_POSTNOTE) < 0 ? -1 : 0;
}

int raise(int sig)
{
	return kill(getpid(), sig);
}

char *strsignal(int sig)
{
	static const char *const names[NSIG] = {
		[SIGHUP] = "Hangup", [SIGINT] = "Interrupt", [SIGQUIT] = "Quit",
		[SIGILL] = "Illegal instruction", [SIGTRAP] = "Trace/breakpoint trap",
		[SIGABRT] = "Aborted", [SIGBUS] = "Bus error", [SIGFPE] = "Floating point exception",
		[SIGKILL] = "Killed", [SIGUSR1] = "User defined signal 1", [SIGSEGV] = "Segmentation fault",
		[SIGUSR2] = "User defined signal 2", [SIGPIPE] = "Broken pipe", [SIGALRM] = "Alarm clock",
		[SIGTERM] = "Terminated", [SIGCHLD] = "Child exited", [SIGCONT] = "Continued",
		[SIGSTOP] = "Stopped (signal)", [SIGTSTP] = "Stopped", [SIGWINCH] = "Window changed",
	};
	static char buf[24];
	if (sig > 0 && sig < NSIG && names[sig]) return (char *)names[sig];
	strcpy(buf, "Unknown signal ");
	char *p = buf + 15;
	int n = sig < 0 ? -sig : sig, i = 0;
	char d[8];
	do { d[i++] = (char)('0' + n % 10); n /= 10; } while (n && i < 7);
	if (sig < 0) *p++ = '-';
	while (i) *p++ = d[--i];
	*p = 0;
	return buf;
}
