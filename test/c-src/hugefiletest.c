/* A file past ext2's double-indirect reach: with 1 KiB blocks that is
 * (12 + 256 + 256*256) KiB ~= 64.3 MiB; past it the driver needs triple-
 * indirect blocks (user/fs/ext2.c3, since 2026-10-22 — c3c's own 98 MB
 * ELF, linked on racccoon, was the first file that big). Writes 66 MiB
 * in 64 KiB chunks with a position-dependent pattern, reads it all back,
 * checks every byte, deletes it (which must free the triple-indirect
 * blocks — the suite's fsck checks). Also runs on FAT32 (4 GiB files).
 * Prints "hugefiletest: ok" (exit 0) or the first failure. */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>

#define TOTAL (66UL * 1024 * 1024)
#define CHUNK (64UL * 1024)

static unsigned char pat(unsigned long pos) { return (unsigned char)((pos * 2654435761UL) >> 13); }

int main(void)
{
	const char *path = "/hugefile.tmp";
	unsigned char *buf = malloc(CHUNK);
	if (!buf) { printf("hugefiletest: FAILED: malloc\n"); return 1; }

	int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (fd < 0) { printf("hugefiletest: FAILED: create\n"); return 1; }
	for (unsigned long off = 0; off < TOTAL; off += CHUNK) {
		for (unsigned long i = 0; i < CHUNK; i++) buf[i] = pat(off + i);
		if (write(fd, buf, CHUNK) != (ssize_t)CHUNK) {
			printf("hugefiletest: FAILED: write at %lu MiB\n", off >> 20);
			return 1;
		}
	}
	close(fd);

	fd = open(path, O_RDONLY);
	if (fd < 0) { printf("hugefiletest: FAILED: reopen\n"); return 1; }
	for (unsigned long off = 0; off < TOTAL; off += CHUNK) {
		if (read(fd, buf, CHUNK) != (ssize_t)CHUNK) {
			printf("hugefiletest: FAILED: read at %lu MiB\n", off >> 20);
			return 1;
		}
		for (unsigned long i = 0; i < CHUNK; i++) {
			if (buf[i] != pat(off + i)) {
				printf("hugefiletest: FAILED: byte %lu differs\n", off + i);
				return 1;
			}
		}
	}
	close(fd);
	if (unlink(path) != 0) { printf("hugefiletest: FAILED: unlink\n"); return 1; }
	printf("hugefiletest: ok (%lu MiB written, read back, deleted)\n", TOTAL >> 20);
	return 0;
}
