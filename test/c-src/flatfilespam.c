#include <stdio.h>
#include <dirent.h>
#include <string.h>

/* opendir() ONE directory, then fopen+fread+fclose every file entry in
 * it -- flat, no recursive C calls -- narrows bug 3 further (see
 * docs/devlog.md, c3c self-host arc): is "many distinct files
 * fopen/fread'd" alone enough, without recursion? */
int main(void)
{
	printf("flatfilespam: start\n"); fflush(stdout);
	DIR *d = opendir("/c3/std/core");
	if (!d) { printf("flatfilespam: opendir failed\n"); return 1; }
	struct dirent *ent;
	int nfiles = 0;
	long total = 0;
	while ((ent = readdir(d))) {
		if (ent->d_name[0] == '.') continue;
		if (ent->d_type != DT_REG) continue;
		char path[256];
		snprintf(path, sizeof path, "/c3/std/core/%s", ent->d_name);
		FILE *f = fopen(path, "rb");
		if (!f) continue;
		char buf[4096];
		size_t n;
		while ((n = fread(buf, 1, sizeof buf, f)) > 0) total += (long)n;
		fclose(f);
		nfiles++;
	}
	closedir(d);
	printf("flatfilespam: done, %d files, %ld bytes, exiting\n", nfiles, total);
	fflush(stdout);
	return 0;
}
