/* racccoon syscall numbers + the raw ecall wrappers.
 *
 * Register convention matches user/user.c3's syscall()/syscall4()/
 * syscall5(): a0..a2 (and a4, a5) carry arguments, a3 the syscall
 * number, the result comes back in a0. Keep the numbers in sync with
 * user/user.c3 (authoritative — shared by every c3 program and the
 * kernel switch in src/entry.c3). Wrappers are real functions in
 * src/syscall.c (not inline — some callers want a stable address). */
#ifndef RACCCOON_SYSCALL_H
#define RACCCOON_SYSCALL_H

#define RC_SYS_PUTCHAR          1
#define RC_SYS_GETCHAR          2
#define RC_SYS_EXIT             3
#define RC_SYS_NS_RESOLVE       8
#define RC_SYS_RFORK            11
#define RC_SYS_JOIN             13
#define RC_SYS_PROC_INFO       17
#define RC_SYS_KILL           18
#define RC_SYS_EXEC          24
#define RC_SYS_IPC_CALL     34
#define RC_SYS_GETUID       35
#define RC_SYS_CHDIR       37
#define RC_SYS_GETCWD     38
#define RC_SYS_MAP        47
#define RC_SYS_STDIN_ISATTY 48
#define RC_SYS_TIMEBASE     49
#define RC_SYS_GETPID       50

/* fsd IPC verbs (user/user.c3 authoritative) + wire limits */
#define RC_FS_DELETE          22
#define RC_FS_LIST            23
#define RC_FS_MKDIR           24
#define RC_FS_RENAME          25
#define RC_FS_READ_AT         26
#define RC_FS_WRITE_AT        27
#define RC_FS_STAT            28
#define RC_FS_MSG_MAX         1128
#define RC_FS_WRITE_AT_MAXCHUNK (1128 - 108)
#define RC_FS_LIST_NAME_MAX    32
#define RC_FS_LIST_ENTRY_SIZE  36
#define RC_FS_OFFSET_APPEND    0xFFFFFFFFu

long __rc_syscall3(long a0, long a1, long a2, long sysno);
long __rc_syscall4(long a0, long a1, long a2, long a4, long sysno);
long __rc_syscall5(long a0, long a1, long a2, long a4, long a5, long sysno);

#endif
