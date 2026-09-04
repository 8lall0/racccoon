#include <stdio.h>
#include <dirent.h>
#include <string.h>

/* opendir/readdir/closedir on many DIFFERENT directory paths, flat
 * (no recursive C calls, no file reads) -- narrows bug 3 further (see
 * docs/devlog.md, c3c self-host arc): is repeated opendir() on many
 * distinct paths alone enough to make SYS_EXIT hang? */

static const char *dirs[] = {
	"/c3/std", "/c3/std/_compiler_rt", "/c3/std/_nolibc", "/c3/std/collections",
	"/c3/std/compression", "/c3/std/core", "/c3/std/crypto", "/c3/std/encoding",
	"/c3/std/experimental", "/c3/std/hash", "/c3/std/io", "/c3/std/libc",
	"/c3/std/math", "/c3/std/net", "/c3/std/os", "/c3/std/sort",
	"/c3/std/threads", "/c3/std/time", "/c3/std/_nolibc/math_nolibc",
	"/c3/std/core/allocators", "/c3/std/core/os", "/c3/std/core/private",
	"/c3/std/core/sanitizer", "/c3/std/crypto/keccak", "/c3/std/hash/gost",
	"/c3/std/hash/whirlpool", "/c3/std/io/os", "/c3/std/io/stream",
	"/c3/std/libc/os", "/c3/std/math/random", "/c3/std/math/geometry",
	"/c3/std/net/os", "/c3/std/os/android", "/c3/std/os/freebsd",
	"/c3/std/os/linux", "/c3/std/os/macos", "/c3/std/os/netbsd",
	"/c3/std/os/openbsd", "/c3/std/os/posix", "/c3/std/os/win32",
};

int main(void)
{
	printf("dirspam: start\n"); fflush(stdout);
	int ndirs = (int)(sizeof dirs / sizeof dirs[0]);
	int total_entries = 0;
	/* go around the list 10x, like the total dir-open count in fsspam */
	for (int pass = 0; pass < 10; pass++) {
		for (int i = 0; i < ndirs; i++) {
			DIR *d = opendir(dirs[i]);
			if (!d) continue;
			struct dirent *ent;
			while ((ent = readdir(d))) {
				if (ent->d_name[0] == '.') continue;
				total_entries++;
			}
			closedir(d);
		}
		printf("dirspam: pass %d done, %d entries so far\n", pass, total_entries); fflush(stdout);
	}
	printf("dirspam: done, %d entries total, exiting\n", total_entries); fflush(stdout);
	return 0;
}
