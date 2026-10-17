/* libc functions wasi-libc doesn't provide, stubbed so Lua's io.tmpfile and
 * os.execute fail cleanly (nil + error / "no shell") instead of not linking. */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>

FILE *tmpfile(void) { errno = ENOSYS; return NULL; }
int system(const char *cmd) { return cmd == NULL ? 0 : -1; }   /* NULL: "no command processor" */
