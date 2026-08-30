/* roadmap §7 stage 4 — the POSIX fd layer: open/close/read/write/lseek
 * + stat/fstat + mkdir/unlink/rmdir/rename + opendir/readdir, against a
 * real (writable) filesystem. "stage4test: ok" (0) or a diagnostic (1).
 *
 * Uses short, upper-case names so it works on FAT32 (8.3, case-folded)
 * as well as ext2. Cleans up after itself. */
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <dirent.h>
#include <string.h>
#include <stdlib.h>

static void put(const char *s) { write(1, s, strlen(s)); }
#define FAIL(m) do { put("stage4test: FAILED: " m "\n"); return 1; } while (0)

static int ci_eq(const char *a, const char *b)
{
	for (; *a && *b; a++, b++) {
		int ca = *a >= 'a' && *a <= 'z' ? *a - 32 : *a;
		int cb = *b >= 'a' && *b <= 'z' ? *b - 32 : *b;
		if (ca != cb) return 0;
	}
	return *a == *b;
}

int main(void)
{
	const char *file = "/CTTMP.TXT";
	const char *file2 = "/CTMOVED.TXT";
	const char *dir  = "/CTDIR";
	const char *body = "hello\nworld\n";     /* 12 bytes */

	/* write */
	int fd = open(file, O_WRONLY | O_CREAT | O_TRUNC);
	if (fd < 0) FAIL("open write");
	if (write(fd, body, 12) != 12) FAIL("write count");
	if (close(fd) != 0) FAIL("close");

	/* stat */
	struct stat st;
	if (stat(file, &st) != 0) FAIL("stat");
	if (!S_ISREG(st.st_mode)) FAIL("stat not regular");
	if (st.st_size != 12) FAIL("stat size");

	/* read whole */
	char buf[64];
	fd = open(file, O_RDONLY);
	if (fd < 0) FAIL("open read");
	long n = read(fd, buf, sizeof buf);
	if (n != 12 || memcmp(buf, body, 12) != 0) FAIL("read-back mismatch");

	/* fstat on the open fd */
	struct stat fst;
	if (fstat(fd, &fst) != 0 || fst.st_size != 12) FAIL("fstat");

	/* lseek + partial read */
	if (lseek(fd, 6, SEEK_SET) != 6) FAIL("lseek set");
	n = read(fd, buf, sizeof buf);
	if (n != 6 || memcmp(buf, "world\n", 6) != 0) FAIL("lseek read");
	if (lseek(fd, -3, SEEK_END) != 9) FAIL("lseek end");
	close(fd);

	/* append */
	fd = open(file, O_WRONLY | O_APPEND);
	if (fd < 0) FAIL("open append");
	if (write(fd, "!!!", 3) != 3) FAIL("append write");
	close(fd);
	if (stat(file, &st) != 0 || st.st_size != 15) FAIL("append size");

	/* mkdir + opendir/readdir */
	if (mkdir(dir, 0755) != 0) FAIL("mkdir");
	if (stat(dir, &st) != 0 || !S_ISDIR(st.st_mode)) FAIL("stat dir");

	DIR *d = opendir("/");
	if (!d) FAIL("opendir /");
	int saw_file = 0, saw_dir = 0;
	struct dirent *e;
	while ((e = readdir(d))) {
		if (ci_eq(e->d_name, "CTTMP.TXT") && e->d_type == DT_REG) saw_file = 1;
		if (ci_eq(e->d_name, "CTDIR")     && e->d_type == DT_DIR) saw_dir = 1;
	}
	closedir(d);
	if (!saw_file) FAIL("readdir missed the file");
	if (!saw_dir)  FAIL("readdir missed the dir");

	/* rename + unlink + rmdir */
	if (rename(file, file2) != 0) FAIL("rename");
	if (stat(file, &st) == 0) FAIL("old name still there after rename");
	if (stat(file2, &st) != 0) FAIL("new name missing after rename");
	if (unlink(file2) != 0) FAIL("unlink");
	if (stat(file2, &st) == 0) FAIL("unlink left the file");
	if (rmdir(dir) != 0) FAIL("rmdir");

	put("stage4test: ok\n");
	return 0;
}
