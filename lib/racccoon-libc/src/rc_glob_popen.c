/* glob and popen/pclose: POSIX calls racccoon can't really do yet —
 * glob finds nothing, popen fails (no shell pipes from C). c3c reaches
 * them only in paths a racccoon run doesn't take. (The c3c-specific
 * stubs the parked tcc-built c3c needed are in ../c3c-tcc-stubs.c, not
 * in libracccoon.a: a full c3c defines those symbols itself.) */
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <glob.h>

/* --- glob(3): c3c's linker.c globs for library files. Report no match. */
int glob(const char *p, int f, int (*e)(const char *, int), glob_t *g)
{
	(void)p; (void)f; (void)e;
	if (g) { g->gl_pathc = 0; g->gl_pathv = NULL; g->gl_offs = 0; }
	return GLOB_NOMATCH;
}
void globfree(glob_t *g) { (void)g; }

/* --- POSIX bits racccoon libc doesn't have yet; c3c's uses are all in
 *     error/cleanup paths that don't fire in a normal --backend=c run. */


/* popen/pclose: c3c shells out to the external linker on a full `build`.
 * `c3c compile --backend=c` (emit .c only) never reaches these. */
FILE *popen(const char *cmd, const char *mode) { (void)cmd; (void)mode; return (FILE *)0; }
int   pclose(FILE *f) { (void)f; return -1; }
