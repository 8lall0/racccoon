/* The libc allocator (rc_malloc.c, dlmalloc) under an LLVM-like churn:
 * mixed small and large blocks (16 B .. 4 MiB) allocated, resized and
 * freed at random. Checks that every block keeps its contents, that
 * alignment requests are honoured, and that the heap stops growing once
 * the churn is steady — freed memory, large blocks included, must be
 * reused (the allocator before dlmalloc leaked every block over 1 KiB).
 * Prints "alloctest: ok" (exit 0) or a diagnostic (exit 1). */
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern unsigned long __rc_heap_mapped;

static void put(const char *s) { write(1, s, strlen(s)); }
static void putn(unsigned long v)
{
	char b[24]; int i = 24;
	if (!v) { put("0"); return; }
	while (v) { b[--i] = '0' + (v % 10); v /= 10; }
	write(1, b + i, 24 - i);
}
#define FAIL(msg) do { put("alloctest: FAILED: " msg "\n"); return 1; } while (0)

#define SLOTS  64
#define ROUNDS 4000

static unsigned long rng = 88172645463325252UL;
static unsigned long next(void) { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return rng; }

/* Mostly small, sometimes large, rarely huge — roughly a compiler's mix. */
static size_t pick_size(void)
{
	unsigned long r = next() % 100;
	if (r < 70) return 16 + next() % 512;
	if (r < 95) return 1024 + next() % (64 * 1024);
	return 256 * 1024 + next() % (4 * 1024 * 1024 - 256 * 1024);
}

static char *slot[SLOTS];
static size_t len[SLOTS];
static unsigned char tag[SLOTS];

static int check(int i)
{
	/* the first and last bytes and a few in between */
	size_t n = len[i];
	if (!slot[i]) return 1;
	if ((unsigned char)slot[i][0] != tag[i] || (unsigned char)slot[i][n - 1] != tag[i]) return 0;
	if ((unsigned char)slot[i][n / 2] != tag[i]) return 0;
	return 1;
}

static void fill(int i) { memset(slot[i], tag[i], len[i]); }

static int churn(int rounds)
{
	for (int r = 0; r < rounds; r++) {
		int i = (int)(next() % SLOTS);
		if (!check(i)) return 0;
		unsigned long op = next() % 3;
		if (op == 0 || !slot[i]) {             /* replace */
			free(slot[i]);
			len[i] = pick_size();
			slot[i] = malloc(len[i]);
			if (!slot[i]) return -1;
			tag[i] = (unsigned char)next();
			fill(i);
		} else if (op == 1) {                  /* resize, keep the prefix */
			size_t nl = pick_size();
			char *p = realloc(slot[i], nl);
			if (!p) return -1;
			slot[i] = p;
			size_t keep = nl < len[i] ? nl : len[i];
			if ((unsigned char)p[0] != tag[i] || (unsigned char)p[keep - 1] != tag[i]) return 0;
			len[i] = nl;
			fill(i);
		} else {                                /* drop */
			free(slot[i]);
			slot[i] = 0;
		}
	}
	return 1;
}

int main(void)
{
	/* alignment */
	void *a64 = aligned_alloc(64, 100), *a4k = 0;
	if (!a64 || ((unsigned long)a64 & 63)) FAIL("aligned_alloc(64) misaligned");
	if (posix_memalign(&a4k, 4096, 10000) != 0 || ((unsigned long)a4k & 4095)) FAIL("posix_memalign(4096) misaligned");
	free(a64);
	free(a4k);

	/* warm up, then measure: a steady churn must not keep mapping memory */
	int r = churn(ROUNDS);
	if (r < 0) FAIL("allocation failed during warm-up");
	if (r == 0) FAIL("block contents corrupted during warm-up");
	unsigned long warm = __rc_heap_mapped;
	r = churn(ROUNDS);
	if (r < 0) FAIL("allocation failed during steady churn");
	if (r == 0) FAIL("block contents corrupted during steady churn");
	unsigned long grew = __rc_heap_mapped - warm;

	put("alloctest: heap ");
	putn(warm >> 10);
	put(" KiB after warm-up, +");
	putn(grew >> 10);
	put(" KiB during the steady churn\n");
	/* The live set is the same size in both halves, so a reusing
	 * allocator only grows for fragmentation; a leaking one maps about
	 * as much again as the warm-up did. */
	if (grew > warm / 4) FAIL("heap kept growing: freed memory isn't reused");

	for (int i = 0; i < SLOTS; i++) free(slot[i]);
	put("alloctest: ok\n");
	return 0;
}
