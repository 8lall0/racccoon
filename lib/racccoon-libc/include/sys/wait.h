#ifndef _SYS_WAIT_H
#define _SYS_WAIT_H

#include <sys/types.h>

/* racccoon's SYS_JOIN gives back only an exit code (0 for a clean exit,
 * the process's own code otherwise, 0xff-ish for a killed child). We
 * pack it the glibc way: exit code in bits 8..15, low 7 bits zero for a
 * normal exit. Signals aren't modelled — a killed child reports
 * WIFEXITED with status 255. */
#define WNOHANG   1
#define WUNTRACED 2

#define WIFEXITED(s)    (((s) & 0x7f) == 0)
#define WEXITSTATUS(s)  (((s) >> 8) & 0xff)
#define WIFSIGNALED(s)  (((s) & 0x7f) != 0 && ((s) & 0x7f) != 0x7f)
#define WTERMSIG(s)     ((s) & 0x7f)
#define WIFSTOPPED(s)   (((s) & 0xff) == 0x7f)
#define WSTOPSIG(s)     WEXITSTATUS(s)
#define WCOREDUMP(s)    0

/* wait for any child (wait / waitpid(-1,...)) joins children in the
 * order they were fork()ed — racccoon has no "any child" primitive.
 * WNOHANG is accepted but not honoured (SYS_JOIN always blocks). */
pid_t wait(int *status);
pid_t waitpid(pid_t pid, int *status, int options);

#endif
