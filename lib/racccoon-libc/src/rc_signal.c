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

#define NCONT 0
#define NDFLT 1
#define NSIG_RC 32

static void (*__rc_sig[NSIG_RC])(int);
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
	void (*h)(int) = __rc_sig[sig];
	if (h == SIG_DFL) {
		__rc_syscall3(NDFLT, 0, 0, RC_SYS_NOTED);
	} else if (h != SIG_IGN) {
		h(sig);
	}
	__rc_syscall3(NCONT, 0, 0, RC_SYS_NOTED);
}

void (*signal(int sig, void (*h)(int)))(int)
{
	if (sig <= 0 || sig >= NSIG_RC || sig == SIGKILL) return SIG_ERR;
	void (*old)(int) = __rc_sig[sig];
	__rc_sig[sig] = h;
	if (!__rc_notify_on) {
		__rc_syscall3((long)__rc_note, 0, 0, RC_SYS_NOTIFY);
		__rc_notify_on = 1;
	}
	return old;
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
