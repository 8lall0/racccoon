/* racccoon syscall numbers + the raw ecall wrappers.
 *
 * The register convention matches user/user.c3's own syscall()/
 * syscall4()/syscall5(): a0..a2 (and a4, a5) carry the arguments, a3
 * carries the syscall number, the result comes back in a0. Keep the
 * numbers in sync with user/user.c3 (which is authoritative — it's
 * shared by every C3 program and the kernel-side switch in
 * src/entry.c3). */
#ifndef RACCCOON_SYSCALL_H
#define RACCCOON_SYSCALL_H

#define RC_SYS_PUTCHAR          1
#define RC_SYS_GETCHAR          2
#define RC_SYS_EXIT             3
#define RC_SYS_RFORK            11
#define RC_SYS_JOIN             13
#define RC_SYS_PROC_INFO        17
#define RC_SYS_KILL             18
#define RC_SYS_EXEC             24
#define RC_SYS_GETUID           35
#define RC_SYS_CHDIR            37
#define RC_SYS_GETCWD           38
#define RC_SYS_MAP              47
#define RC_SYS_STDIN_ISATTY     48
#define RC_SYS_TIMEBASE         49

static inline long __rc_syscall3(long a0, long a1, long a2, long sysno)
{
	register long _a0 __asm__("a0") = a0;
	register long _a1 __asm__("a1") = a1;
	register long _a2 __asm__("a2") = a2;
	register long _a3 __asm__("a3") = sysno;
	__asm__ volatile("ecall" : "+r"(_a0) : "r"(_a1), "r"(_a2), "r"(_a3) : "memory");
	return _a0;
}

static inline long __rc_syscall4(long a0, long a1, long a2, long a4, long sysno)
{
	register long _a0 __asm__("a0") = a0;
	register long _a1 __asm__("a1") = a1;
	register long _a2 __asm__("a2") = a2;
	register long _a3 __asm__("a3") = sysno;
	register long _a4 __asm__("a4") = a4;
	__asm__ volatile("ecall" : "+r"(_a0) : "r"(_a1), "r"(_a2), "r"(_a3), "r"(_a4) : "memory");
	return _a0;
}

static inline long __rc_syscall5(long a0, long a1, long a2, long a4, long a5, long sysno)
{
	register long _a0 __asm__("a0") = a0;
	register long _a1 __asm__("a1") = a1;
	register long _a2 __asm__("a2") = a2;
	register long _a3 __asm__("a3") = sysno;
	register long _a4 __asm__("a4") = a4;
	register long _a5 __asm__("a5") = a5;
	__asm__ volatile("ecall" : "+r"(_a0) : "r"(_a1), "r"(_a2), "r"(_a3), "r"(_a4), "r"(_a5) : "memory");
	return _a0;
}

#endif
