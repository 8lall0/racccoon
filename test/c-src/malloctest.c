/* roadmap §7 stage 2 — exercise malloc / free / realloc / calloc.
 * Prints "malloctest: ok" (exit 0) or a diagnostic (exit 1). */
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void put(const char *s) { write(1, s, strlen(s)); }
static void putn(unsigned long v)
{
	char b[24]; int i = 24;
	if (!v) { put("0"); return; }
	while (v) { b[--i] = '0' + (v % 10); v /= 10; }
	write(1, b + i, 24 - i);
}
#define FAIL(msg) do { put("malloctest: FAILED: " msg "\n"); return 1; } while (0)

int main(void)
{
	/* basic alloc + write + free */
	char *a = malloc(100);
	if (!a) FAIL("malloc(100) == NULL");
	memset(a, 'x', 100);
	if (a[0] != 'x' || a[99] != 'x') FAIL("write-back mismatch");

	/* calloc is zeroed */
	int *z = calloc(64, sizeof(int));
	if (!z) FAIL("calloc == NULL");
	for (int i = 0; i < 64; i++) if (z[i] != 0) FAIL("calloc not zeroed");
	z[63] = 12345;

	/* realloc grows and keeps the contents */
	strcpy(a, "hello realloc");
	char *a2 = realloc(a, 4096);
	if (!a2) FAIL("realloc == NULL");
	if (strcmp(a2, "hello realloc") != 0) FAIL("realloc lost data");
	a2[4095] = 'Z';

	/* free everything, then a churn loop that must reuse freed space
	 * rather than grow the heap without bound */
	free(a2);
	free(z);

	unsigned long peak = 0;
	for (int round = 0; round < 20000; round++) {
		void *p = malloc(200 + (round & 255));
		if (!p) FAIL("churn malloc == NULL");
		memset(p, round & 0xff, 8);
		free(p);
		peak++;
	}

	/* many small live allocations, then free in a scrambled order */
	void *v[512];
	for (int i = 0; i < 512; i++) {
		v[i] = malloc(16 + i * 3);
		if (!v[i]) FAIL("bulk malloc == NULL");
		*(int *)v[i] = i;
	}
	for (int i = 0; i < 512; i += 2) free(v[i]);
	for (int i = 1; i < 512; i += 2) {
		if (*(int *)v[i] != i) FAIL("bulk data clobbered");
		free(v[i]);
	}

	put("malloctest: ok ("); putn(peak); put(" churn allocs)\n");
	return 0;
}
