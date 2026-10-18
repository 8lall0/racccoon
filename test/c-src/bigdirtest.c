/* ext2 directories past their 12 direct blocks — racccoon could pack a
 * directory's entries (dirpacktest) but never extend it into the indirect
 * block, so a directory stopped growing once 12 blocks were full. 480
 * files with 42-character names take ~26 one-KiB blocks: creates them,
 * counts them with readdir, stats the first and last, deletes every
 * other one and refills the holes, then unlinks them all and rmdirs the
 * directory (which only works if the empty check sees the indirect
 * blocks too). "bigdirtest: ok" or the first failure.
 *
 * `bigdirtest keep` stops after the refill and leaves /bdt behind, for
 * `rm -r /bdt` (the recursive delete) and an e2fsck pass. `-l LEN` sets
 * the name length (default 42, max 90 — fsd's path limit) and `-n N` the
 * count (max 500 — opendir reads 512): the Duo's card has 4 KiB blocks,
 * where `-l 90 -n 500` is what reaches past 12 blocks. Mutating ops are
 * retried a few times, like dirpacktest's. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#include <sys/stat.h>

static int NF = 480;
static int NAME_LEN = 42;

static int r_create(const char *p)
{
	for (int t = 0; t < 5; t++) {
		int fd = open(p, O_WRONLY | O_CREAT | O_TRUNC);
		if (fd >= 0) { write(fd, "z", 1); close(fd); return 0; }
		usleep(200000);
	}
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
	struct dirent *e;
	while ((e = readdir(d)))
		if (strcmp(e->d_name, ".") != 0 && strcmp(e->d_name, "..") != 0) n++;
	closedir(d);
	return n;
}

/* NAME_LEN characters: tag + "_entry_" + 4 digits + "_" + x's */
static void name_of(char *p, size_t n, char tag, int i)
{
	int k = snprintf(p, n, "/bdt/%c_entry_%04d_", tag, i);
	int want = 5 + NAME_LEN;
	while (k < want && k + 1 < (int)n) p[k++] = 'x';
	p[k] = 0;
}

int main(int argc, char **argv)
{
	int keep = 0;
	for (int a = 1; a < argc; a++) {
		if (strcmp(argv[a], "keep") == 0) keep = 1;
		else if (strcmp(argv[a], "-n") == 0 && a + 1 < argc) NF = atoi(argv[++a]);
		else if (strcmp(argv[a], "-l") == 0 && a + 1 < argc) NAME_LEN = atoi(argv[++a]);
	}
	if (NF < 2 || NF > 500 || NAME_LEN < 13 || NAME_LEN > 90) { printf("usage: bigdirtest [keep] [-n 2..500] [-l 13..90]\n"); return 1; }
	NF &= ~1;
	char p[128];
	struct stat sb;

	if (mkdir("/bdt", 0755) != 0) { printf("bigdirtest: FAILED (mkdir /bdt)\n"); return 1; }
	for (int i = 0; i < NF; i++) {
		name_of(p, sizeof p, 'f', i);
		if (r_create(p) != 0) { printf("bigdirtest: FAILED (create %d)\n", i); return 1; }
	}
	int c = count_dir("/bdt");
	if (c != NF) { printf("bigdirtest: FAILED (count %d want %d)\n", c, NF); return 1; }
	if (stat("/bdt", &sb) != 0) { printf("bigdirtest: FAILED (stat /bdt)\n"); return 1; }
	long dir_size = (long)sb.st_size;
	name_of(p, sizeof p, 'f', 0);
	if (stat(p, &sb) != 0) { printf("bigdirtest: FAILED (first entry gone)\n"); return 1; }
	name_of(p, sizeof p, 'f', NF - 1);
	if (stat(p, &sb) != 0) { printf("bigdirtest: FAILED (last entry gone)\n"); return 1; }

	for (int i = 0; i < NF; i += 2) {
		name_of(p, sizeof p, 'f', i);
		if (r_unlink(p) != 0) { printf("bigdirtest: FAILED (unlink %d)\n", i); return 1; }
	}
	for (int i = 0; i < NF / 2; i++) {
		name_of(p, sizeof p, 'g', i);
		if (r_create(p) != 0) { printf("bigdirtest: FAILED (refill %d)\n", i); return 1; }
	}
	c = count_dir("/bdt");
	if (c != NF) { printf("bigdirtest: FAILED (post-refill count %d want %d)\n", c, NF); return 1; }
	if (stat("/bdt", &sb) != 0 || (long)sb.st_size != dir_size) {
		printf("bigdirtest: FAILED (refill grew the dir %ld -> %ld: holes not reused)\n", dir_size, (long)sb.st_size);
		return 1;
	}

	if (keep) { printf("bigdirtest: ok (kept /bdt: %d entries, %ld bytes of directory)\n", NF, dir_size); return 0; }

	for (int i = 1; i < NF; i += 2) {
		name_of(p, sizeof p, 'f', i);
		if (r_unlink(p) != 0) { printf("bigdirtest: FAILED (cleanup f %d)\n", i); return 1; }
	}
	for (int i = 0; i < NF / 2; i++) {
		name_of(p, sizeof p, 'g', i);
		if (r_unlink(p) != 0) { printf("bigdirtest: FAILED (cleanup g %d)\n", i); return 1; }
	}
	if (rmdir("/bdt") != 0) { printf("bigdirtest: FAILED (rmdir of the emptied /bdt)\n"); return 1; }

	printf("bigdirtest: ok (%d entries, %ld bytes of directory)\n", NF, dir_size);
	return 0;
}
