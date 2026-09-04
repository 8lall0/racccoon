#include <stdio.h>
#include <dirent.h>
#include <string.h>

/* Same as iterfilespam but stops after CAP files -- binary-searching
 * the threshold between "clean exit" (28 files, flatfilespam) and
 * "hangs on exit" (327 files, iterfilespam) for bug 3 (see
 * docs/devlog.md, c3c self-host arc). */
#ifndef CAP
#define CAP 150
#endif

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
	printf("capfilespam: start, cap=%d\n", CAP); fflush(stdout);
	int ndirs = (int)(sizeof dirs / sizeof dirs[0]);
	int nfiles = 0;
	long total = 0;
	for (int i = 0; i < ndirs && nfiles < CAP; i++) {
		DIR *d = opendir(dirs[i]);
		if (!d) continue;
		struct dirent *ent;
		while ((ent = readdir(d)) && nfiles < CAP) {
			if (ent->d_name[0] == '.') continue;
			if (ent->d_type != DT_REG) continue;
			char path[256];
			snprintf(path, sizeof path, "%s/%s", dirs[i], ent->d_name);
			FILE *f = fopen(path, "rb");
			if (!f) continue;
			char buf[4096];
			size_t n;
			while ((n = fread(buf, 1, sizeof buf, f)) > 0) total += (long)n;
			fclose(f);
			nfiles++;
		}
		closedir(d);
	}
	printf("capfilespam: done, %d files, %ld bytes, exiting\n", nfiles, total);
	fflush(stdout);
	return 0;
}
