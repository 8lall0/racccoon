/* roadmap §7 stage 6 — the process layer: fork / exec* / wait* / mmap
 * and the environment. "stage6test: ok" (0) or the failing checks (1).
 * Needs /bin/exiter (test/c-src/exiter.c) on the disk. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#include <sys/mman.h>

static int fails = 0;
#define CHK(c, msg) do { if (!(c)) { fails++; fprintf(stderr, "  %s\n", msg); } } while (0)

static int run(char *const argv[], char *const envp[], int use_path)
{
	pid_t p = fork();
	if (p == 0) {
		if (use_path) execvp(argv[0], argv);
		else          execve("/bin/exiter", argv, envp);
		_exit(111);
	}
	int st = 0;
	waitpid(p, &st, 0);
	return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}

int main(void)
{
	/* fork + plain exit code */
	pid_t p = fork();
	if (p == 0) _exit(3);
	CHK(p > 0, "fork returned <= 0");
	int st = 0;
	pid_t w = waitpid(p, &st, 0);
	CHK(w == p, "waitpid returned the wrong pid");
	CHK(WIFEXITED(st) && WEXITSTATUS(st) == 3, "child exit code != 3");

	/* wait() (any child) */
	p = fork();
	if (p == 0) _exit(5);
	CHK(wait(&st) == p && WEXITSTATUS(st) == 5, "wait() any-child failed");

	/* execve: exit code taken from argv[1] */
	{ char *av[] = { "exiter", "17", 0 };
	  CHK(run(av, NULL, 0) == 17, "execve exit code != 17"); }

	/* execvp: found via the PATH search (default /bin/) */
	{ char *av[] = { "exiter", "9", 0 };
	  CHK(run(av, NULL, 1) == 9, "execvp exit code != 9"); }

	/* argv[0] reaches the child intact */
	{ char *av[] = { "exiter-was-here", "argv0", 0 };
	  CHK(run(av, NULL, 0) == 0, "argv[0] not delivered to the child"); }

	/* envp reaches the child's getenv() */
	{ char *av[] = { "exiter", "env", "STAGE6", 0 };
	  char *ev[] = { "OTHER=x", "STAGE6=yes", 0 };
	  CHK(run(av, ev, 0) == 0, "envp not delivered to the child"); }

	/* in-process environment */
	CHK(getenv("NOPE_XYZ_123") == NULL, "getenv of an unset var != NULL");
	CHK(setenv("MYVAR", "hello", 1) == 0, "setenv failed");
	CHK(getenv("MYVAR") && strcmp(getenv("MYVAR"), "hello") == 0, "setenv/getenv roundtrip");
	setenv("MYVAR", "world", 0);
	CHK(strcmp(getenv("MYVAR"), "hello") == 0, "setenv overwrite=0 still changed it");
	setenv("MYVAR", "world", 1);
	CHK(strcmp(getenv("MYVAR"), "world") == 0, "setenv overwrite=1 did not take");
	CHK(unsetenv("MYVAR") == 0 && getenv("MYVAR") == NULL, "unsetenv failed");

	/* anonymous mmap */
	size_t n = 200000;
	unsigned char *m = mmap(NULL, n, PROT_READ | PROT_WRITE,
	                        MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
	CHK(m != MAP_FAILED, "mmap(MAP_ANONYMOUS) failed");
	if (m != MAP_FAILED) {
		int ok = 1;
		for (size_t i = 0; i < n; i += 997) m[i] = (unsigned char)(i * 7);
		for (size_t i = 0; i < n; i += 997) if (m[i] != (unsigned char)(i * 7)) ok = 0;
		CHK(ok, "mmap region did not hold its writes");
		munmap(m, n);
	}

	/* getenv() falls back to the /env store — informational */
	char *path = getenv("PATH");
	if (path) printf("  (PATH via /env = \"%s\")\n", path);

	if (fails) { printf("stage6test: FAILED (%d)\n", fails); return 1; }
	printf("stage6test: ok\n");
	return 0;
}
