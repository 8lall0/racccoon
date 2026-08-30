/* Internal: the C reimplementation of racccoon's path-based fs calls
 * (the c3 user.c3 exports the same set, but user.o also defines main /
 * exit / putchar / start, which collide with the C crt0 — so the POSIX
 * layer speaks fsd's wire protocol itself). Not a public header. */
#ifndef RACCCOON_FS_H
#define RACCCOON_FS_H

#include <stddef.h>

/* cwd-relative -> absolute, into out (>= 128 bytes). */
void  __rc_abspath(const char *rel, char *out);

/* -1 on error; result is a byte count (read) / status (write/mkdir/
 * delete/rename) / 0 (stat). type: 0 = file, 1 = directory. */
long  __rc_fs_read_at(const char *path, void *buf, long len, unsigned long off);
long  __rc_fs_write_at(const char *path, const void *buf, long len, unsigned long off);
int   __rc_fs_stat(const char *path, unsigned long *size_out, int *type_out);
int   __rc_fs_list(const char *path, void *out, int max_entries);   /* -> entry count */
int   __rc_fs_mkdir(const char *path);
int   __rc_fs_delete(const char *path, int recursive);
int   __rc_fs_rename(const char *oldp, const char *newp);

#endif
