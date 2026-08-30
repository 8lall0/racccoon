#ifndef _SYS_MMAN_H
#define _SYS_MMAN_H

#include <sys/types.h>

#define PROT_NONE  0
#define PROT_READ  1
#define PROT_WRITE 2
#define PROT_EXEC  4

#define MAP_SHARED    0x01
#define MAP_PRIVATE   0x02
#define MAP_FIXED     0x10
#define MAP_ANON      0x20
#define MAP_ANONYMOUS 0x20

#define MAP_FAILED ((void *)-1)

/* Only anonymous mappings are supported (fd must be -1), backed by
 * racccoon's SYS_MAP bump allocator. munmap is a no-op — SYS_MAP never
 * returns pages — so mmap/munmap churn leaks; use it for a few big
 * long-lived regions, not as a general allocator. mprotect is a no-op
 * (SYS_MAP pages are already R+W+X). */
void *mmap(void *addr, size_t length, int prot, int flags, int fd, off_t offset);
int   munmap(void *addr, size_t length);
int   mprotect(void *addr, size_t length, int prot);

#endif
