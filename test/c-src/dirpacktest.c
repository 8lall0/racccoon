/* ext2 directory dirent packing — racccoon can now create many files in
 * one directory (they pack into a block's rec_len slack instead of one
 * block per file, which capped an ext2 dir at ~11). Creates 30 files +
 * 3 subdirs in a fresh dir, lists them all, deletes half, creates 10
 * more (reusing the freed dirent slots), re-lists, stats survivors,
 * cleans up. "dirpacktest: ok" or the first failure.
 *
 * `dirpacktest keep` leaves /dpt on disk for an e2fsck pass. Each
 * mutating fs op is retried a few times: hammering fsd/diskd this hard
 * can trip the supervisor's stall watchdog and get diskd respawned
 * mid-op (a single request lost), which callers are expected to ride
 * out — same tolerance the *killtest builtins use. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#include <sys/stat.h>

#define NF 30
#define ND 3

static int r_create(const char *p)
{
	for (int t = 0; t < 5; t++) {
		int fd = open(p, O_WRONLY | O_CREAT | O_TRUNC);
		if (fd >= 0) { write(fd, "y", 1); close(fd); return 0; }
		usleep(200000);
	}
	return -1;
}
static int r_mkdir(const char *p)
{
	for (int t = 0; t < 5; t++) { if (mkdir(p, 0755) == 0) return 0; usleep(200000); }
	return -1;
}
static int r_unlink(const char *p)
{
	for (int t = 0; t < 5; t++) { if (unlink(p) == 0) return 0; usleep(200000); }
	return -1;
}

static int count_dir(const char *path)
{
	DIR *d = opendir(path);
	if (!d) return -1;
	int n = 0;
	while (readdir(d)) n++;
	closedir(d);
	return n;
}

int main(int argc, char **argv)
{
	int keep = argc > 1 && strcmp(argv[1], "keep") == 0;
	const char *dir = "/dpt";
	char p[64];

	if (r_mkdir(dir) != 0) { printf("dirpacktest: FAILED (mkdir base)\n"); return 1; }

	for (int i = 0; i < NF; i++) {
		snprintf(p, sizeof p, "%s/f%03d", dir, i);
		if (r_create(p) != 0) { printf("dirpacktest: FAILED (create %s at %d)\n", p, i); return 1; }
	}
	for (int i = 0; i < ND; i++) {
		snprintf(p, sizeof p, "%s/d%d", dir, i);
		if (r_mkdir(p) != 0) { printf("dirpacktest: FAILED (mkdir %s)\n", p); return 1; }
	}

	int c = count_dir(dir);
	if (c != NF + ND) { printf("dirpacktest: FAILED (count %d want %d)\n", c, NF + ND); return 1; }

	for (int i = 0; i < NF; i += 2) {
		snprintf(p, sizeof p, "%s/f%03d", dir, i);
		if (r_unlink(p) != 0) { printf("dirpacktest: FAILED (unlink %s)\n", p); return 1; }
	}
	for (int i = 0; i < 10; i++) {
		snprintf(p, sizeof p, "%s/g%02d", dir, i);
		if (r_create(p) != 0) { printf("dirpacktest: FAILED (recreate %s)\n", p); return 1; }
	}

	c = count_dir(dir);
	int want = (NF - NF / 2) + ND + 10;
	if (c != want) { printf("dirpacktest: FAILED (post-churn count %d want %d)\n", c, want); return 1; }

	struct stat sb;
	snprintf(p, sizeof p, "%s/f%03d", dir, NF - 1);   /* NF-1 is odd for even NF -> survives */
	if (stat(p, &sb) != 0) { printf("dirpacktest: FAILED (%s gone)\n", p); return 1; }
	snprintf(p, sizeof p, "%s/d%d", dir, ND - 1);
	if (stat(p, &sb) != 0 || !S_ISDIR(sb.st_mode)) { printf("dirpacktest: FAILED (%s gone)\n", p); return 1; }

	if (keep) { printf("dirpacktest: ok (kept /dpt with %d entries for fsck)\n", want); return 0; }

	DIR *d = opendir(dir);
	struct dirent *e;
	char names[128][40];
	int n = 0;
	while ((e = readdir(d)) && n < 128) { strncpy(names[n], e->d_name, 39); names[n][39] = 0; n++; }
	closedir(d);
	for (int i = 0; i < n; i++) {
		snprintf(p, sizeof p, "%s/%s", dir, names[i]);
		if (rmdir(p) != 0) r_unlink(p);
	}
	rmdir(dir);

	printf("dirpacktest: ok (%d entries packed, churned, %d after)\n", NF + ND, want);
	return 0;
}
