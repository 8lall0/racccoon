/* A small allocator for racccoon's userspace.
 *
 * Design: a bump pointer over SYS_MAP (__rc_map_pages — page-granular,
 * never hands memory back to the kernel) for fresh allocations, plus
 * per-size-class free lists so freed blocks of a common size get reused.
 * No coalescing, no boundary tags: free() is O(1) and none of the
 * failure modes of a coalescing free list exist (the previous K&R
 * implementation had one that TinyCC's allocation pattern tripped —
 * roadmap §7). A program that frees a lot of oddly-sized blocks still
 * grows its heap, but the size-class reuse covers the churn that matters
 * for a compiler: many nodes of a handful of shapes.
 *
 * Every block carries an 8-byte header (its rounded payload size). The
 * bump region is 16-aligned and each block starts 16-aligned, so the
 * returned pointer (block + 8) is 8-aligned — wait: we pad each block to
 * 16 and place the header in the first 8 bytes, so payload is at +8,
 * 8-aligned. lp64d's max_align_t is 16 (long double), so bump each block
 * to leave the payload 16-aligned: header occupies a full 16-byte slot. */
#include <stdlib.h>
#include <string.h>

extern void *__rc_map_pages(unsigned long nbytes);

#define ALIGN       16u
#define HDR         16u                    /* full slot before the payload, keeps payload 16-aligned */
#define MIN_PAYLOAD 16u
#define CLASS_STEP  16u
#define NCLASS      64                     /* classes 16,32,…,1024 bytes */
#define CLASS_MAX   (NCLASS * CLASS_STEP)  /* 1024 — bigger blocks aren't pooled */
#define REFILL      (1u << 20)             /* 1 MiB per bump refill */

static char *bump_cur, *bump_end;
static void *freelist[NCLASS];             /* class i: payload (i+1)*16, linked through the payload */

static unsigned round_payload(size_t n)
{
	if (n < MIN_PAYLOAD) n = MIN_PAYLOAD;
	return (unsigned)((n + ALIGN - 1) & ~(size_t)(ALIGN - 1));
}

static int class_of(unsigned payload)
{
	if (payload == 0 || payload > CLASS_MAX) return -1;
	return (int)(payload / CLASS_STEP) - 1;
}

static void *bump_alloc(unsigned payload)
{
	unsigned need = HDR + payload;   /* both multiples of 16 */
	if (bump_cur == 0 || (size_t)(bump_end - bump_cur) < need) {
		unsigned long want = need > REFILL ? need : REFILL;
		char *p = __rc_map_pages(want);
		if (!p) return NULL;
		bump_cur = p;
		bump_end = p + want;
	}
	char *blk = bump_cur;
	bump_cur += need;
	*(size_t *)blk = payload;
	return blk + HDR;
}

void *malloc(size_t nbytes)
{
	if (nbytes == 0) return NULL;
	unsigned payload = round_payload(nbytes);

	int c = class_of(payload);
	if (c >= 0 && freelist[c]) {
		char *blk = freelist[c];
		freelist[c] = *(void **)(blk + HDR);   /* next free block */
		*(size_t *)blk = payload;
		return blk + HDR;
	}
	return bump_alloc(payload);
}

void free(void *ap)
{
	if (!ap) return;
	char *blk = (char *)ap - HDR;
	size_t payload = *(size_t *)blk;
	int c = class_of((unsigned)payload);
	if (c < 0) return;                          /* oversized — leak it */
	*(void **)(blk + HDR) = freelist[c];        /* link through the (now free) payload */
	freelist[c] = blk;
}

void *calloc(size_t nmemb, size_t size)
{
	if (nmemb && size > (size_t)-1 / nmemb) return NULL;
	size_t total = nmemb * size;
	void *p = malloc(total);
	if (p) memset(p, 0, total);
	return p;
}

void *realloc(void *ptr, size_t size)
{
	if (ptr == NULL) return malloc(size);
	if (size == 0) { free(ptr); return NULL; }

	size_t old = *((size_t *)((char *)ptr - HDR));
	if (old >= round_payload(size)) return ptr;

	void *np = malloc(size);
	if (np == NULL) return NULL;
	memcpy(np, ptr, old < size ? old : size);
	free(ptr);
	return np;
}
