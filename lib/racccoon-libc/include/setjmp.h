#ifndef _SETJMP_H
#define _SETJMP_H

/* rv64 / lp64d: ra, sp, s0-s11 (12), fs0-fs11 (12) = 26 doublewords.
 * Layout must match src/setjmp.S. */
typedef unsigned long jmp_buf[26];

int  setjmp(jmp_buf env) __attribute__((returns_twice));
__attribute__((noreturn)) void longjmp(jmp_buf env, int val);

#define setjmp(env)  setjmp(env)

#endif
