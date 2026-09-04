#include <stdio.h>
#include <dirent.h>
#include <string.h>

/* Same total work as fsspam (337 files across all of /c3/std, full
 * fopen+fread+fclose) but ITERATIVE across a flat list of known
 * directories -- no recursive C calls. Narrows bug 3 (see
 * docs/devlog.md): is it "recursion + reads" or just "reads at scale
 * (337 files)", independent of how the walk is structured? */

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
	printf("iterfilespam: start\n"); fflush(stdout);
	int ndirs = (int)(sizeof dirs / sizeof dirs[0]);
	int nfiles = 0;
	long total = 0;
	for (int i = 0; i < ndirs; i++) {
		DIR *d = opendir(dirs[i]);
		if (!d) continue;
		struct dirent *ent;
		while ((ent = readdir(d))) {
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
		if (i % 10 == 9) { printf("iterfilespam: dir %d, %d files so far\n", i, nfiles); fflush(stdout); }
	}
	printf("iterfilespam: done, %d files, %ld bytes, exiting\n", nfiles, total);
	fflush(stdout);
	return 0;
}
