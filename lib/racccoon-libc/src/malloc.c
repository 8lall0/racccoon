/* K&R malloc (The C Programming Language §8.7): a circular first-fit
 * free list of Header-sized units, coalescing on free, growing via
 * morecore(). The one change is morecore() — sbrk() becomes racccoon's
 * SYS_MAP (__rc_map_pages), which is a bump allocator that never
 * returns memory to the kernel. That's fine: consecutive SYS_MAP calls
 * are contiguous, so a freed arena coalesces with the next one just
 * like sbrk's would, and freed blocks are reused within the process.
 *
 * Alignment: Header is a union with a `long` member, so sizeof(Header)
 * is 16 on rv64 and every returned pointer (block + 1) is 16-aligned —
 * enough for lp64d's max_align_t (128-bit long double). */
#include <stdlib.h>
#include <string.h>

extern void *__rc_map_pages(unsigned long nbytes);

typedef long Align;

union header {
	struct {
		union header *ptr;   /* next free block */
		size_t        size;  /* this block's size, in units of sizeof(Header) */
	} s;
	Align pad;
};
typedef union header Header;

static Header  base;             /* the empty list to start from */
static Header *freep = NULL;     /* last-used free-list entry */

void free(void *ap)
{
	if (!ap) return;

	Header *bp = (Header *)ap - 1;   /* block header */
	Header *p;

	for (p = freep; !(bp > p && bp < p->s.ptr); p = p->s.ptr)
		if (p >= p->s.ptr && (bp > p || bp < p->s.ptr))
			break;   /* freed block at the start or end of the arena */

	if (bp + bp->s.size == p->s.ptr) {          /* coalesce with the upper neighbour */
		bp->s.size += p->s.ptr->s.size;
		bp->s.ptr   = p->s.ptr->s.ptr;
	} else {
		bp->s.ptr = p->s.ptr;
	}
	if (p + p->s.size == bp) {                  /* coalesce with the lower neighbour */
		p->s.size += bp->s.size;
		p->s.ptr   = bp->s.ptr;
	} else {
		p->s.ptr = bp;
	}
	freep = p;
}

#define NALLOC 4096   /* min units to grow by (~64 KiB) — keep SYS_MAP calls coarse */

static Header *morecore(size_t nu)
{
	if (nu < NALLOC) nu = NALLOC;

	Header *up = __rc_map_pages(nu * sizeof(Header));
	if (up == NULL) return NULL;

	up->s.size = nu;
	free((void *)(up + 1));   /* fold the fresh arena into the free list */
	return freep;
}

void *malloc(size_t nbytes)
{
	if (nbytes == 0) return NULL;

	size_t nunits = (nbytes + sizeof(Header) - 1) / sizeof(Header) + 1;

	Header *prevp = freep;
	if (prevp == NULL) {             /* first call — seed the list */
		base.s.ptr = freep = prevp = &base;
		base.s.size = 0;
	}

	for (Header *p = prevp->s.ptr; ; prevp = p, p = p->s.ptr) {
		if (p->s.size >= nunits) {
			if (p->s.size == nunits) {
				prevp->s.ptr = p->s.ptr;
			} else {                 /* carve the tail off */
				p->s.size -= nunits;
				p += p->s.size;
				p->s.size = nunits;
			}
			freep = prevp;
			return (void *)(p + 1);
		}
		if (p == freep) {            /* wrapped the whole list without a fit */
			p = morecore(nunits);
			if (p == NULL) return NULL;
		}
	}
}

void *calloc(size_t nmemb, size_t size)
{
	if (nmemb && size > (size_t)-1 / nmemb) return NULL;   /* overflow */
	size_t total = nmemb * size;
	void *p = malloc(total);
	if (p) memset(p, 0, total);
	return p;
}

void *realloc(void *ptr, size_t size)
{
	if (ptr == NULL) return malloc(size);
	if (size == 0) { free(ptr); return NULL; }

	Header *bp = (Header *)ptr - 1;
	size_t old = (bp->s.size - 1) * sizeof(Header);   /* usable bytes in the old block */
	if (old >= size) return ptr;                       /* shrink / no-op in place */

	void *np = malloc(size);
	if (np == NULL) return NULL;
	memcpy(np, ptr, old);
	free(ptr);
	return np;
}
