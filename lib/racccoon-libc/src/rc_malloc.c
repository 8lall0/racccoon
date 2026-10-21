/* malloc / free / calloc / realloc / memalign / posix_memalign /
 * aligned_alloc: Doug Lea's dlmalloc 2.8.6, vendored verbatim in
 * dlmalloc.inc (gee.cs.oswego.edu/pub/misc/malloc.c, MIT-0-style licence,
 * no attribution required — compatible with racccoon's MIT).
 *
 * Configured for racccoon: memory only grows, through SYS_MAP
 * (__rc_map_pages, page-rounded, demand-paged, never handed back), so
 * there's no mmap path and no trimming. SYS_MAP regions are usually
 * adjacent, but nothing promises it, so MORECORE is non-contiguous and
 * dlmalloc keeps each region as its own segment when they aren't. No
 * locks: a C program has one thread (rc_pthread.c's pthread_create
 * aborts); turn on USE_LOCKS if that ever changes.
 *
 * Replaces the earlier bump + size-class allocator, which never reused a
 * freed block over 1 KiB — fine for tcc, a leak for anything like LLVM. */
#include <stddef.h>

extern void *__rc_map_pages(unsigned long nbytes);

/* Bytes obtained from the kernel so far (alloctest checks it stops
 * growing under a steady alloc/free churn). */
unsigned long __rc_heap_mapped;

static char *rc_top;   /* end of the last region, for MORECORE(0) */

static void *rc_morecore(ptrdiff_t n)
{
	if (n == 0) return rc_top ? rc_top : (void *)-1;
	if (n < 0) return (void *)-1;                 /* MORECORE_CANNOT_TRIM */
	unsigned long want = ((unsigned long)n + 4095) & ~4095UL;
	char *p = __rc_map_pages(want);
	if (!p) return (void *)-1;
	__rc_heap_mapped += want;
	rc_top = p + want;
	return p;
}

#define HAVE_MMAP            0
#define HAVE_MREMAP          0
#define MORECORE             rc_morecore
#define MORECORE_CONTIGUOUS  0
#define MORECORE_CANNOT_TRIM 1
#define DEFAULT_GRANULARITY  ((size_t)256U * 1024U)   /* SYS_MAP calls are cheap, but not free */
#define USE_LOCKS            0
#define NO_MALLINFO          1
#define NO_MALLOC_STATS      1
#define LACKS_SYS_PARAM_H
#define LACKS_SCHED_H
#define malloc_getpagesize   ((size_t)4096U)

#include "dlmalloc.inc"

/* C11; dlmalloc 2.8.6 predates it. */
void *aligned_alloc(size_t align, size_t size)
{
	return memalign(align, size);
}
