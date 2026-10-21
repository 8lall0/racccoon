#ifndef _SYS_STATVFS_H
#define _SYS_STATVFS_H
#ifdef __cplusplus
extern "C" {
#endif

/* Filesystem info (src/rc_proc.c). Every racccoon filesystem is local
 * (ST_LOCAL / MNT_LOCAL set); the FS protocol has no free-space query,
 * so the block counts are 0 = unknown. f_flags mirrors f_flag for code
 * that reads the BSD statfs spelling. */

typedef unsigned long fsblkcnt_t;
typedef unsigned long fsfilcnt_t;

struct statvfs {
	unsigned long f_bsize, f_frsize;
	fsblkcnt_t    f_blocks, f_bfree, f_bavail;
	fsfilcnt_t    f_files, f_ffree, f_favail;
	unsigned long f_fsid, f_flag, f_flags, f_namemax;
};

#define ST_RDONLY 0x1
#define ST_NOSUID 0x2
#define ST_LOCAL  0x1000
#define MNT_LOCAL ST_LOCAL

int statvfs(const char *path, struct statvfs *buf);
int fstatvfs(int fd, struct statvfs *buf);

#ifdef __cplusplus
}
#endif
#endif
