/* roadmap §7 stage 3 — ctype / strtol / qsort / bsearch / setjmp /
 * atexit. "stage3test: ok" (exit 0) or a diagnostic (exit 1). */
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <setjmp.h>
#include <unistd.h>

static void put(const char *s) { write(1, s, strlen(s)); }
#define FAIL(m) do { put("stage3test: FAILED: " m "\n"); return 1; } while (0)

static int atexit_ran = 0;
static void on_exit_hook(void) { atexit_ran = 1; }   /* observable only via a re-run trick — see note */

static int cmp_int(const void *a, const void *b)
{
	int x = *(const int *)a, y = *(const int *)b;
	return (x > y) - (x < y);
}

static jmp_buf jb;
static int longjmp_landed = 0;

static void deep(int n)
{
	volatile int guard = 0xABCD;
	if (n <= 0) longjmp(jb, 7);
	if (n > 0) deep(n - 1);
	if (guard != 0xABCD) put("stage3test: guard clobbered\n");
}

int main(void)
{
	atexit(on_exit_hook);
	(void)atexit_ran;

	/* ctype */
	if (!isdigit('5') || isdigit('x')) FAIL("isdigit");
	if (!isspace('\t') || !isspace(' ') || isspace('a')) FAIL("isspace");
	if (toupper('a') != 'A' || tolower('Z') != 'z') FAIL("case");
	if (!isxdigit('f') || !isxdigit('C') || isxdigit('g')) FAIL("isxdigit");

	/* strtol / strtoul, bases + overflow-ish */
	char *e;
	if (strtol("  -42abc", &e, 10) != -42 || strcmp(e, "abc") != 0) FAIL("strtol dec");
	if (strtol("0x1F", 0, 0) != 31) FAIL("strtol hex auto");
	if (strtol("777", 0, 8) != 511) FAIL("strtol oct");
	if (strtoul("4294967295", 0, 10) != 4294967295UL) FAIL("strtoul");
	if (atoi("123") != 123 || atoi("-7") != -7) FAIL("atoi");

	/* qsort + bsearch */
	int v[17] = { 9, 3, 14, 1, 7, 7, 0, -5, 100, 2, 6, 6, 6, 8, 4, -1, 50 };
	qsort(v, 17, sizeof(int), cmp_int);
	for (int i = 1; i < 17; i++) if (v[i] < v[i - 1]) FAIL("qsort not sorted");
	int key = 14;
	int *hit = bsearch(&key, v, 17, sizeof(int), cmp_int);
	if (!hit || *hit != 14) FAIL("bsearch");
	int miss = 999;
	if (bsearch(&miss, v, 17, sizeof(int), cmp_int)) FAIL("bsearch false hit");

	/* setjmp / longjmp across deep recursion */
	if (setjmp(jb) == 0) {
		deep(400);
		FAIL("longjmp did not unwind");
	} else {
		longjmp_landed = 1;
	}
	if (!longjmp_landed) FAIL("setjmp second return");

	/* malloc + qsort interaction (larger) */
	int n = 5000;
	int *big = malloc(n * sizeof(int));
	if (!big) FAIL("malloc big");
	unsigned s = 12345;
	for (int i = 0; i < n; i++) { s = s * 1103515245u + 12345u; big[i] = (int)(s >> 8); }
	qsort(big, n, sizeof(int), cmp_int);
	for (int i = 1; i < n; i++) if (big[i] < big[i - 1]) FAIL("big qsort");
	free(big);

	put("stage3test: ok\n");
	return 0;
}
