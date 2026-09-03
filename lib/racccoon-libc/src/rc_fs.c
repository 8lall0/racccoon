/* The racccoon fs primitives, reimplemented in C over SYS_NS_RESOLVE +
 * SYS_IPC_CALL to fsd. Mirrors user/user.c3's fs_read_at / fs_write_at
 * / fs_stat / fs_list / fs_mkdir / fs_delete / fs_rename byte for byte
 * (see that file + user/fs/fsd.c3 for the wire format). The POSIX
 * layer (rc_posix.c) sits on top of this. */
#include <racccoon/syscall.h>
#include <racccoon/fs.h>
#include <string.h>

extern long __rc_syscall3(long, long, long, long);
extern long __rc_syscall5(long, long, long, long, long, long);

/* Union-aware path resolution — applies any `bind` rewrite (the /bin
 * union at login, e.g.) that rc_ns_resolve + a manual prefix strip
 * would silently drop. member 0 = the first/highest-priority binding.
 * Writes the server-relative path into `out` (cap bytes), returns pid. */
extern long __rc_syscall4(long, long, long, long, long);
static int rc_ns_translate(const char *path, int member, char *out, int cap)
{
	return (int)__rc_syscall4((long)path, member, (long)out, cap, RC_SYS_NS_TRANSLATE);
}

static int rc_getcwd(char *buf, int cap)
{
	return (int)__rc_syscall3((long)buf, cap, 0, RC_SYS_GETCWD);
}

/* fsd IPC: request + reply share one buffer, like p9_call. Returns the
 * replier pid (>0) or <=0 on failure; *verb_out gets the reply verb. */
static int rc_fsd_call(int pid, unsigned verb, char *buf, int req_len, unsigned *verb_out)
{
	long packed = ((long)(req_len & 0xFFFF) << 16) | (long)(RC_FS_MSG_MAX & 0xFFFF);
	return (int)__rc_syscall5(pid, (long)verb, (long)buf, packed,
	                          (long)verb_out, RC_SYS_IPC_CALL);
}

void __rc_abspath(const char *rel, char *out)
{
	if (rel[0] == '/') {
		int i = 0;
		while (rel[i] && i < 127) { out[i] = rel[i]; i++; }
		out[i] = 0;
		return;
	}
	char cw[128];
	int n = rc_getcwd(cw, sizeof cw);
	if (rel[0] == 0) {
		int i = 0;
		while (i < n && i < 127) { out[i] = cw[i]; i++; }
		out[i] = 0;
		return;
	}
	if (n <= 0) {
		int i = 0;
		while (rel[i] && i < 127) { out[i] = rel[i]; i++; }
		out[i] = 0;
		return;
	}
	int o = 0;
	for (int i = 0; i < n && o < 127; i++) out[o++] = cw[i];
	if (o < 127) out[o++] = '/';
	for (int i = 0; rel[i] && o < 127; i++) out[o++] = rel[i];
	out[o] = 0;
}

/* Resolve `path` (already absolute) to (fsd pid, server-relative path
 * copied into `stripped` >= 100 bytes). Via SYS_NS_TRANSLATE so a
 * `bind` path rewrite (the /bin union at login) is applied — the old
 * rc_ns_resolve + manual strip dropped it, so /bin/<tool> resolved to a
 * bare "<tool>" the root fsd couldn't find. Returns fsd pid or -1. */
static int resolve_stripped(const char *abspath, char *stripped)
{
	int pid = rc_ns_translate(abspath, 0, stripped, 100);
	if (pid < 0) { stripped[0] = 0; return -1; }
	return pid;
}

/* Same, but for creation — resolves to the union's create member (the
 * `bind -c` one, or member 0 with no union, so identical there). So
 * `tcc x.c -o /bin/x` / `go build -o /bin/x` land in /usr/$user/bin,
 * not the root-owned system /bin. Matches user/user.c3's fs_write. */
static int resolve_stripped_c(const char *abspath, char *stripped)
{
	int pid = rc_ns_translate(abspath, -1, stripped, 100);
	if (pid < 0) { stripped[0] = 0; return -1; }
	return pid;
}

long __rc_fs_read_at(const char *path, void *buf, long len, unsigned long off)
{
	char ap[128]; __rc_abspath(path, ap);
	char req[RC_FS_MSG_MAX];
	int pid = resolve_stripped(ap, req);
	if (pid < 0) return -1;

	*(unsigned *)(req + 100) = (unsigned)len;
	*(unsigned *)(req + 104) = (unsigned)off;

	unsigned rv = 0;
	int from = rc_fsd_call(pid, RC_FS_READ_AT, req, RC_FS_MSG_MAX, &rv);
	if (from <= 0 || rv != RC_FS_READ_AT) return -1;

	int result = *(int *)req;
	if (result < 0) return result;
	if (result > len) result = (int)len;
	memcpy(buf, req + 4, (size_t)result);
	return result;
}

long __rc_fs_write_at(const char *path, const void *buf, long len, unsigned long off)
{
	char ap[128]; __rc_abspath(path, ap);
	char req[RC_FS_MSG_MAX];
	int pid = resolve_stripped_c(ap, req);
	if (pid < 0) return -1;

	if (len < 0) len = 0;
	if (len > RC_FS_WRITE_AT_MAXCHUNK) len = RC_FS_WRITE_AT_MAXCHUNK;
	*(unsigned *)(req + 100) = (unsigned)len;
	*(unsigned *)(req + 104) = (unsigned)off;
	memcpy(req + 108, buf, (size_t)len);

	unsigned rv = 0;
	int from = rc_fsd_call(pid, RC_FS_WRITE_AT, req, RC_FS_MSG_MAX, &rv);
	if (from <= 0 || rv != RC_FS_WRITE_AT) return -1;
	return *(int *)req;
}

/* Legacy whole-file FS_READ / FS_WRITE (verbs 20 / 21). envd (the /env
 * store) only ever implements these, not the offset-aware FS_READ_AT /
 * FS_WRITE_AT — wire format is the plain one: path at req[0..99], length
 * at req[100], reply result at req[0], data from req[4]. */
long __rc_fs_read(const char *path, void *buf, long len)
{
	char ap[128]; __rc_abspath(path, ap);
	char req[RC_FS_MSG_MAX];
	int pid = resolve_stripped(ap, req);
	if (pid < 0) return -1;

	if (len < 0) len = 0;
	if (len > RC_FS_MSG_MAX - 4) len = RC_FS_MSG_MAX - 4;
	*(unsigned *)(req + 100) = (unsigned)len;

	unsigned rv = 0;
	int from = rc_fsd_call(pid, RC_FS_READ, req, RC_FS_MSG_MAX, &rv);
	if (from <= 0 || rv != RC_FS_READ) return -1;

	int result = *(int *)req;
	if (result < 0) return result;
	if (result > len) result = (int)len;
	memcpy(buf, req + 4, (size_t)result);
	return result;
}

long __rc_fs_write(const char *path, const void *buf, long len)
{
	char ap[128]; __rc_abspath(path, ap);
	char req[RC_FS_MSG_MAX];
	int pid = resolve_stripped_c(ap, req);
	if (pid < 0) return -1;

	if (len < 0) len = 0;
	if (len > RC_FS_MSG_MAX - 104) len = RC_FS_MSG_MAX - 104;
	*(unsigned *)(req + 100) = (unsigned)len;
	memcpy(req + 104, buf, (size_t)len);

	unsigned rv = 0;
	int from = rc_fsd_call(pid, RC_FS_WRITE, req, RC_FS_MSG_MAX, &rv);
	if (from <= 0 || rv != RC_FS_WRITE) return -1;
	return *(int *)req;
}

int __rc_fs_stat(const char *path, unsigned long *size_out, int *type_out)
{
	char ap[128]; __rc_abspath(path, ap);
	char req[RC_FS_MSG_MAX];
	int pid = resolve_stripped(ap, req);
	if (pid < 0) return -1;

	unsigned rv = 0;
	int from = rc_fsd_call(pid, RC_FS_STAT, req, RC_FS_MSG_MAX, &rv);
	if (from <= 0 || rv != RC_FS_STAT) return -1;
	if (*(int *)req < 0) return -1;
	if (size_out) *size_out = *(unsigned *)(req + 4);
	if (type_out) *type_out = (int)((unsigned char)req[8]);
	return 0;
}

#define RC_FS_LIST_PAGE_MAX ((RC_FS_MSG_MAX - 4) / RC_FS_LIST_ENTRY_SIZE)

int __rc_fs_list(const char *path, void *out, int max_entries)
{
	char ap[128]; __rc_abspath(path, ap);
	char stripped[100];
	int pid = resolve_stripped(ap, stripped);
	if (pid < 0) return -1;

	char req[RC_FS_MSG_MAX];
	char *dst = out;
	int total = 0;
	for (;;) {
		/* the buffer is reused for the reply, so rebuild the request
		 * each page: path at [0..99], running start index at byte 104
		 * (fsd pages the listing there, mirroring FS_READ_AT's offset). */
		int i = 0;
		while (stripped[i] && i < 99) { req[i] = stripped[i]; i++; }
		req[i] = 0;
		*(unsigned *)(req + 104) = (unsigned)total;

		unsigned rv = 0;
		int from = rc_fsd_call(pid, RC_FS_LIST, req, RC_FS_MSG_MAX, &rv);
		if (from <= 0 || rv != RC_FS_LIST) return total > 0 ? total : -1;

		int page = *(int *)req;
		if (page < 0) return total > 0 ? total : page;

		int take = page;
		if (take > max_entries - total) take = max_entries - total;
		memcpy(dst + (size_t)total * RC_FS_LIST_ENTRY_SIZE,
		       req + 4, (size_t)take * RC_FS_LIST_ENTRY_SIZE);
		total += take;

		if (page < RC_FS_LIST_PAGE_MAX || total >= max_entries) break;
	}
	return total;
}

static int simple_verb(const char *path, unsigned verb, unsigned aux_at_100, int create)
{
	char ap[128]; __rc_abspath(path, ap);
	char req[RC_FS_MSG_MAX];
	int pid = create ? resolve_stripped_c(ap, req) : resolve_stripped(ap, req);
	if (pid < 0) return -1;
	*(unsigned *)(req + 100) = aux_at_100;
	unsigned rv = 0;
	int from = rc_fsd_call(pid, verb, req, RC_FS_MSG_MAX, &rv);
	if (from <= 0 || rv != verb) return -1;
	return *(int *)req;
}

int __rc_fs_mkdir(const char *path)              { return simple_verb(path, RC_FS_MKDIR, 0, 1); }
int __rc_fs_delete(const char *path, int recur)  { return simple_verb(path, RC_FS_DELETE, (unsigned)recur, 0); }

int __rc_fs_rename(const char *oldp, const char *newp)
{
	char apo[128]; __rc_abspath(oldp, apo);
	char apn[128]; __rc_abspath(newp, apn);
	char so[100], sn[100];
	int pido = resolve_stripped(apo, so);      /* source: existing */
	int pidn = resolve_stripped_c(apn, sn);    /* dest: create member */
	if (pido < 0 || pidn < 0 || pido != pidn) return -1;

	char req[RC_FS_MSG_MAX];
	int i = 0; while (so[i] && i < 99) { req[i] = so[i]; i++; } req[i] = 0;
	int j = 0; while (sn[j] && j < 99) { req[100 + j] = sn[j]; j++; } req[100 + j] = 0;

	unsigned rv = 0;
	int from = rc_fsd_call(pido, RC_FS_RENAME, req, RC_FS_MSG_MAX, &rv);
	if (from <= 0 || rv != RC_FS_RENAME) return -1;
	return *(int *)req;
}
