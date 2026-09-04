#include <stdio.h>
#include <dirent.h>
#include <string.h>

/* Recursive directory walk (like fsspam) but fopen+fclose only, no
 * fread -- narrows bug 3 (see docs/devlog.md, c3c self-host arc):
 * does recursion + open/close at scale hang without any read? */
static int nfiles = 0;

static void walk(const char *path)
{
	DIR *d = opendir(path);
	if (!d) return;
	struct dirent *ent;
	while ((ent = readdir(d))) {
		if (ent->d_name[0] == '.') continue;
		char child[256];
		snprintf(child, sizeof child, "%s/%s", path, ent->d_name);
		if (ent->d_type == DT_DIR) { walk(child); continue; }
		FILE *f = fopen(child, "rb");
		if (!f) continue;
		fclose(f);
		nfiles++;
	}
	closedir(d);
}

int main(void)
{
	printf("recursespam: start\n"); fflush(stdout);
	walk("/c3/std");
	printf("recursespam: done, %d files, exiting\n", nfiles); fflush(stdout);
	return 0;
}
