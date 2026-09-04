#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>

/* Reads every file under /c3/std (recursively, like c3c's stdlib load)
 * via fopen/fread, growing a heap arena as it goes, then exits -- a
 * closer analog to c3c's actual I/O + allocation pattern than hogtest
 * (raw mmap) or spamtest (raw console spam). Isolates whether heavy
 * fsd round-trips + many small mallocs is what makes SYS_EXIT hang
 * (see docs/devlog.md, c3c self-host arc, bug 3). */

static int nfiles = 0;
static long total_bytes = 0;

static void walk(const char *path)
{
	DIR *d = opendir(path);
	if (!d) return;
	struct dirent *ent;
	while ((ent = readdir(d))) {
		if (ent->d_name[0] == '.') continue;
		char child[256];
		snprintf(child, sizeof child, "%s/%s", path, ent->d_name);
		if (ent->d_type == DT_DIR) {
			walk(child);
			continue;
		}
		FILE *f = fopen(child, "rb");
		if (!f) continue;
		char buf[4096];
		size_t n;
		char *keep = NULL;
		size_t keep_len = 0;
		while ((n = fread(buf, 1, sizeof buf, f)) > 0) {
			char *grown = realloc(keep, keep_len + n);
			if (!grown) break;
			memcpy(grown + keep_len, buf, n);
			keep = grown;
			keep_len += n;
		}
		fclose(f);
		total_bytes += (long)keep_len;
		nfiles++;
		free(keep); /* mimic per-file churn, not one giant retained blob */
		if (nfiles % 50 == 0) { printf("fsspam: %d files, %ld bytes\n", nfiles, total_bytes); fflush(stdout); }
	}
	closedir(d);
}

int main(void)
{
	printf("fsspam: start\n"); fflush(stdout);
	walk("/c3/std");
	printf("fsspam: done, %d files, %ld bytes total, exiting\n", nfiles, total_bytes);
	fflush(stdout);
	return 0;
}
