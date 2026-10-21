#ifndef _PWD_H
#define _PWD_H
#ifdef __cplusplus
extern "C" {
#endif

/* No password database in the C library: racccoon's users live in
 * /adm/users, read by login. Every lookup reports "no such entry"
 * (NULL, errno untouched; the _r forms return 0 with *result = NULL),
 * so callers fall back to $HOME and friends. src/rc_proc.c. */

#include <sys/types.h>

struct passwd {
	char *pw_name;
	char *pw_passwd;
	uid_t pw_uid;
	gid_t pw_gid;
	char *pw_gecos;
	char *pw_dir;
	char *pw_shell;
};

struct passwd *getpwuid(uid_t uid);
struct passwd *getpwnam(const char *name);
int getpwuid_r(uid_t uid, struct passwd *pw, char *buf, size_t n, struct passwd **result);
int getpwnam_r(const char *name, struct passwd *pw, char *buf, size_t n, struct passwd **result);

#ifdef __cplusplus
}
#endif
#endif
