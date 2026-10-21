#ifndef _UTIME_H
#define _UTIME_H
#ifdef __cplusplus
extern "C" {
#endif

/* racccoon's filesystems keep no file times (st_mtime etc. read 0), so
 * utime() only checks the file exists — there is nothing to set.
 * src/rc_posix.c. */

#include <sys/types.h>

struct utimbuf {
	time_t actime;
	time_t modtime;
};

int utime(const char *path, const struct utimbuf *times);

#ifdef __cplusplus
}
#endif
#endif
