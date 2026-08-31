/* FS_LIST pagination — a directory with more entries than fit in one
 * fsd reply (31) must still list completely. Reads /manyfiles (60
 * entries e00..e59, seeded by scripts/build.sh) via readdir and checks
 * every one is present. "pagelisttest: ok" or the failure. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <dirent.h>

#define N 60

int main(void)
{
	DIR *d = opendir("/manyfiles");
	if (!d) { printf("pagelisttest: SKIPPED (/manyfiles not on this image)\n"); return 0; }

	int seen[N];
	memset(seen, 0, sizeof seen);
	int count = 0;
	struct dirent *e;
	while ((e = readdir(d)) != NULL) {
		count++;
		if (tolower((unsigned char)e->d_name[0]) == 'e') {   /* FAT32 upcases short names */
			int idx = atoi(e->d_name + 1);
			if (idx >= 0 && idx < N) seen[idx] = 1;
		}
	}
	closedir(d);

	int missing = 0;
	for (int i = 0; i < N; i++) if (!seen[i]) missing++;

	int fails = 0;
	if (count != N) { fails++; fprintf(stderr, "  count %d want %d\n", count, N); }
	if (missing)    { fails++; fprintf(stderr, "  %d of %d names missing\n", missing, N); }

	if (fails) { printf("pagelisttest: FAILED (%d)\n", fails); return 1; }
	printf("pagelisttest: ok (%d entries across %d pages)\n", count, (count + 30) / 31);
	return 0;
}
