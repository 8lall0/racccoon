#include <stdio.h>

/* Opens+reads+closes the same file many times in a flat loop (no
 * directories, no readdir) then exits -- narrows bug 3 (see
 * docs/devlog.md, c3c self-host arc): does repeated fopen/fread/fclose
 * alone make SYS_EXIT hang, or does it need opendir/readdir too? */
int main(void)
{
	printf("openspam: start\n"); fflush(stdout);
	int ok = 0;
	for (int i = 0; i < 400; i++) {
		FILE *f = fopen("/hello.txt", "rb");
		if (!f) continue;
		char buf[256];
		size_t n = fread(buf, 1, sizeof buf, f);
		(void)n;
		fclose(f);
		ok++;
		if (ok % 50 == 0) { printf("openspam: %d opens\n", ok); fflush(stdout); }
	}
	printf("openspam: done, %d opens, exiting\n", ok); fflush(stdout);
	return 0;
}
