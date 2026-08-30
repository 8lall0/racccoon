/* The environment: getenv / setenv / putenv / unsetenv over `environ`.
 *
 * `environ` is seeded by the crt0 (src/start.c) from the exec blob when
 * the program was launched through this libc's execve() with a non-empty
 * envp — otherwise it starts empty. Either way getenv() falls back to
 * racccoon's own per-process /env store (user/sys/envd.c3) so a C program
 * still sees the vars a c3 parent (the shell) set there, e.g. PATH.
 *
 * setenv/putenv/unsetenv edit the in-memory `environ` only. The initial
 * `environ` points at the crt0's fixed-size static array whose strings
 * live in the (never-freed) exec blob; the first mutation copies it to a
 * malloc'd, growable array of malloc'd "KEY=VAL" strings. */
#include <racccoon/syscall.h>
#include <racccoon/fs.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

extern char **environ;

static int    env_owned = 0;    /* 1 once we malloc'd our own array */
static size_t env_cap   = 0;    /* slots in the malloc'd array (incl. NULL) */

static size_t env_count(void)
{
	size_t n = 0;
	if (environ) while (environ[n]) n++;
	return n;
}

/* Does environ[i] name `name` (i.e. begins "name=")? */
static int name_matches(const char *entry, const char *name, size_t nlen)
{
	return strncmp(entry, name, nlen) == 0 && entry[nlen] == '=';
}

static int env_find(const char *name, size_t nlen)
{
	if (!environ) return -1;
	for (int i = 0; environ[i]; i++)
		if (name_matches(environ[i], name, nlen))
			return i;
	return -1;
}

/* Move from the crt0's static array to a malloc'd one we can grow. Each
 * entry is strdup'd so unsetenv/free is uniform. Returns 0 / -1. */
static int env_take_ownership(void)
{
	if (env_owned) return 0;

	size_t n = env_count();
	size_t cap = n + 8;
	char **arr = malloc(cap * sizeof *arr);
	if (!arr) { errno = ENOMEM; return -1; }

	for (size_t i = 0; i < n; i++) {
		arr[i] = strdup(environ[i]);
		if (!arr[i]) {
			for (size_t j = 0; j < i; j++) free(arr[j]);
			free(arr);
			errno = ENOMEM;
			return -1;
		}
	}
	arr[n] = 0;

	environ   = arr;
	env_cap   = cap;
	env_owned = 1;
	return 0;
}

static int env_grow_for_one(size_t n)
{
	if (n + 2 <= env_cap) return 0;
	size_t cap = env_cap ? env_cap * 2 : 16;
	char **arr = realloc(environ, cap * sizeof *arr);
	if (!arr) { errno = ENOMEM; return -1; }
	environ = arr;
	env_cap = cap;
	return 0;
}

/* --- the /env fallback -------------------------------------------- */

static char store_val[128];

static char *env_from_store(const char *name)
{
	if (!name || !name[0]) return NULL;
	for (const char *c = name; *c; c++)
		if (*c == '=' || *c == '/') return NULL;   /* not a bare var name */

	char path[160];
	int o = 0;
	const char *pfx = "/env/";
	while (pfx[o]) { path[o] = pfx[o]; o++; }
	for (int i = 0; name[i] && o < (int)sizeof path - 1; i++) path[o++] = name[i];
	path[o] = 0;

	long n = __rc_fs_read(path, store_val, (long)sizeof store_val - 1);
	if (n < 0) return NULL;
	store_val[n] = 0;
	return store_val;
}

/* --- public API -------------------------------------------------- */

char *getenv(const char *name)
{
	if (!name || !name[0]) return NULL;
	size_t nlen = strlen(name);

	int i = env_find(name, nlen);
	if (i >= 0) return environ[i] + nlen + 1;

	return env_from_store(name);
}

int setenv(const char *name, const char *value, int overwrite)
{
	if (!name || !name[0] || strchr(name, '=')) { errno = EINVAL; return -1; }
	if (!value) value = "";

	size_t nlen = strlen(name);

	if (env_take_ownership() != 0) return -1;

	int idx = env_find(name, nlen);
	if (idx >= 0 && !overwrite) return 0;

	size_t need = nlen + 1 + strlen(value) + 1;
	char *entry = malloc(need);
	if (!entry) { errno = ENOMEM; return -1; }
	memcpy(entry, name, nlen);
	entry[nlen] = '=';
	strcpy(entry + nlen + 1, value);

	if (idx >= 0) {
		free(environ[idx]);
		environ[idx] = entry;
		return 0;
	}

	size_t n = env_count();
	if (env_grow_for_one(n) != 0) { free(entry); return -1; }
	environ[n] = entry;
	environ[n + 1] = 0;
	return 0;
}

int unsetenv(const char *name)
{
	if (!name || !name[0] || strchr(name, '=')) { errno = EINVAL; return -1; }
	if (env_take_ownership() != 0) return -1;

	size_t nlen = strlen(name);
	int idx = env_find(name, nlen);
	if (idx < 0) return 0;

	free(environ[idx]);
	size_t n = env_count();
	for (int i = idx; i < (int)n; i++) environ[i] = environ[i + 1];
	return 0;
}

/* putenv keeps the caller's string in place (POSIX). Once we own the
 * array that means an entry we must not free later — track it loosely by
 * never freeing on the putenv path; a program that putenv()s the same
 * name repeatedly leaks, which no real program does. */
int putenv(char *string)
{
	if (!string) { errno = EINVAL; return -1; }
	char *eq = strchr(string, '=');
	if (!eq) return unsetenv(string);

	size_t nlen = (size_t)(eq - string);
	if (env_take_ownership() != 0) return -1;

	int idx = env_find(string, nlen);
	if (idx >= 0) { environ[idx] = string; return 0; }

	size_t n = env_count();
	if (env_grow_for_one(n) != 0) return -1;
	environ[n] = string;
	environ[n + 1] = 0;
	return 0;
}
