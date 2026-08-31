/* fsd ext2 write past the 12 direct blocks (single + double indirect).
 * Writes a 400 KiB file with a byte-position-derived pattern, reads it
 * back, verifies every byte, then deletes it. "bigwritetest: ok" or the
 * first failure. */
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <sys/stat.h>

#define SIZE (400 * 1024)

static unsigned char pat(long i) { return (unsigned char)((i * 37 + (i >> 8) * 11) & 0xff); }

int main(void)
{
	const char *path = "/bw.bin";
	unsigned char buf[4096];

	int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC);
	if (fd < 0) { printf("bigwritetest: FAILED (open w)\n"); return 1; }

	long off = 0;
	while (off < SIZE) {
		int n = SIZE - off < (int)sizeof buf ? (int)(SIZE - off) : (int)sizeof buf;
		for (int i = 0; i < n; i++) buf[i] = pat(off + i);
		int w = (int)write(fd, buf, n);
		if (w != n) { printf("bigwritetest: FAILED (write %ld: got %d want %d)\n", off, w, n); return 1; }
		off += n;
	}
	close(fd);

	struct stat sb;
	if (stat(path, &sb) != 0 || sb.st_size != SIZE) {
		printf("bigwritetest: FAILED (stat size %ld want %d)\n", (long)sb.st_size, SIZE);
		return 1;
	}

	fd = open(path, O_RDONLY);
	if (fd < 0) { printf("bigwritetest: FAILED (open r)\n"); return 1; }
	off = 0;
	while (off < SIZE) {
		int want = SIZE - off < (int)sizeof buf ? (int)(SIZE - off) : (int)sizeof buf;
		int got = (int)read(fd, buf, want);
		if (got != want) { printf("bigwritetest: FAILED (read %ld: got %d)\n", off, got); return 1; }
		for (int i = 0; i < got; i++)
			if (buf[i] != pat(off + i)) {
				printf("bigwritetest: FAILED (byte %ld: %02x want %02x)\n",
				       off + i, buf[i], pat(off + i));
				return 1;
			}
		off += got;
	}
	close(fd);

	if (unlink(path) != 0) { printf("bigwritetest: FAILED (unlink)\n"); return 1; }

	printf("bigwritetest: ok (400 KiB round trip through double-indirect)\n");
	return 0;
}
