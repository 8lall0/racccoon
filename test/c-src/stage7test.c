/* roadmap §7 stage 7 groundwork — the extra libc surface a compiler
 * (TinyCC) pulls in: <math.h>, <time.h>, <strings.h>, the string.h
 * extensions, strerror, realpath, sysconf. "stage7test: ok" or the
 * failing checks. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <math.h>
#include <time.h>
#include <errno.h>
#include <unistd.h>

static int fails = 0;
#define CHK(c, msg) do { if (!(c)) { fails++; fprintf(stderr, "  %s\n", msg); } } while (0)

int main(void)
{
	/* math */
	CHK(ldexp(1.0, 10) == 1024.0, "ldexp(1,10)");
	CHK(ldexp(3.0, -2) == 0.75, "ldexp(3,-2)");
	CHK(ldexp(1.0, 0) == 1.0, "ldexp(1,0)");
	int e; double m = frexp(12.0, &e);
	CHK(m == 0.75 && e == 4, "frexp(12)");
	CHK(fabs(-2.5) == 2.5, "fabs");
	CHK((int)pow(10.0, 3.0) == 1000, "pow(10,3)");
	CHK(strtold("1.5", NULL) == 1.5L, "strtold");
	CHK(strtof("2.25", NULL) == 2.25f, "strtof");

	/* strings.h + string.h extensions */
	CHK(strcasecmp("HeLLo", "hello") == 0, "strcasecmp");
	CHK(strncasecmp("ABCxx", "abcYY", 3) == 0, "strncasecmp");
	CHK(strspn("aabbcc", "ab") == 4, "strspn");
	CHK(strcspn("abcdef", "cd") == 2, "strcspn");
	CHK(strcmp(strpbrk("hello world", "ow"), "o world") == 0, "strpbrk");

	char toks[] = "a,b,,c";
	char *sv = NULL;
	CHK(strcmp(strtok_r(toks, ",", &sv), "a") == 0, "strtok_r 1");
	CHK(strcmp(strtok_r(NULL, ",", &sv), "b") == 0, "strtok_r 2");
	CHK(strcmp(strtok_r(NULL, ",", &sv), "c") == 0, "strtok_r 3");
	CHK(strtok_r(NULL, ",", &sv) == NULL, "strtok_r end");

	const char *hay = "the quick brown fox";
	CHK(memmem(hay, strlen(hay), "quick", 5) == hay + 4, "memmem");
	char *dup = strndup("abcdef", 3);
	CHK(dup && strcmp(dup, "abc") == 0, "strndup");
	free(dup);
	CHK(strnlen("abc", 10) == 3 && strnlen("abcdef", 3) == 3, "strnlen");

	/* strerror */
	CHK(strcmp(strerror(ENOENT), "No such file or directory") == 0, "strerror ENOENT");
	CHK(strerror(EINVAL)[0] != 0, "strerror EINVAL");

	/* time (fixed clock — just structural) */
	time_t t = time(NULL);
	struct tm *tm = localtime(&t);
	CHK(tm && tm->tm_year == 126 && tm->tm_mon == 5, "localtime fixed date");
	clock_t c0 = clock();
	CHK(c0 >= 0, "clock");

	/* sysconf / getpagesize */
	CHK(sysconf(_SC_PAGESIZE) == 4096, "sysconf(_SC_PAGESIZE)");
	CHK(getpagesize() == 4096, "getpagesize");

	/* realpath */
	char rp[128];
	CHK(realpath("/bin", rp) != NULL && rp[0] == '/', "realpath /bin");

	if (fails) { printf("stage7test: FAILED (%d)\n", fails); return 1; }
	printf("stage7test: ok\n");
	return 0;
}
