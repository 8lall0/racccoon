#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>

/* Touches a lot of pages via mmap, then exits -- isolates whether a
 * large SYS_MAP footprint alone makes SYS_EXIT/proc_destroy hang,
 * independent of c3c or tcc (see docs/devlog.md, c3c self-host arc). */
int main(void)
{
	printf("hog: start\n"); fflush(stdout);

	size_t total = 150ul * 1024 * 1024;   /* 150 MiB */
	size_t chunk = 4ul * 1024 * 1024;     /* 4 MiB per mmap call */
	size_t done = 0;
	int n = 0;
	while (done < total) {
		void *p = mmap(0, chunk, PROT_READ | PROT_WRITE,
		               MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		if (p == MAP_FAILED) { printf("hog: mmap failed at %zu MiB\n", done / (1024*1024)); break; }
		for (size_t off = 0; off < chunk; off += 4096)
			((volatile char *)p)[off] = (char)(off & 0xff);
		done += chunk;
		n++;
		if (n % 5 == 0) { printf("hog: touched %zu MiB\n", done / (1024*1024)); fflush(stdout); }
	}
	printf("hog: touched %zu MiB total, now exiting\n", done / (1024*1024)); fflush(stdout);
	return 0;
}
