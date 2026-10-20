/* signal()/raise()/kill() and poll() — the libc faces of racccoon's notes
 * (src/note.c3) and SYS_AWAIT. Run it as `echo hi | sigtest`: the poll
 * checks need a stdin pipe with something in it. Prints one line per
 * check and "sigtest: ok" or "sigtest: FAILED". */
#include <stdio.h>
#include <signal.h>
#include <poll.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>

static volatile int got;

static void on_int(int sig) { got = sig; }

int main(void)
{
	int bad = 0;

	signal(SIGINT, on_int);
	raise(SIGINT);
	/* The note is delivered on the way out of the raise() syscall. */
	printf("sigtest: raise(SIGINT) ran the handler: %s\n", got == SIGINT ? "ok" : "FAILED");
	if (got != SIGINT) bad++;

	got = 0;
	signal(SIGINT, SIG_IGN);
	raise(SIGINT);
	printf("sigtest: SIG_IGN ignored it: %s\n", got == 0 ? "ok" : "FAILED");
	if (got != 0) bad++;

	struct pollfd p = { 0, POLLIN, 0 };
	int n;
	if (isatty(0)) {
		printf("sigtest: poll saw piped stdin: skipped (stdin is the console — run `echo hi | sigtest`)\n");
	} else {
		n = poll(&p, 1, 3000);
		char c = 0;
		if (n == 1 && (p.revents & POLLIN)) read(0, &c, 1);
		printf("sigtest: poll saw piped stdin: %s\n", n == 1 && c == 'h' ? "ok" : "FAILED");
		if (!(n == 1 && c == 'h')) bad++;
	}

	clock_t t0 = clock();
	n = poll(NULL, 0, 300);
	double dt = (double)(clock() - t0) / CLOCKS_PER_SEC;
	printf("sigtest: poll(nothing, 300 ms) timed out: %s\n", n == 0 && dt > 0.2 && dt < 3.0 ? "ok" : "FAILED");
	if (!(n == 0 && dt > 0.2 && dt < 3.0)) bad++;

	printf("sigtest: %s\n", bad ? "FAILED" : "ok");
	return bad ? 1 : 0;
}
