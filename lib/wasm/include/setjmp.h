/* setjmp/longjmp for C programs run under racccoon's /bin/wasm.
 *
 * wasi-libc's own <setjmp.h> refuses to work without the wasm
 * exception-handling proposal, which /bin/wasm doesn't implement. Its
 * interpreter keeps call frames explicitly, so it provides setjmp/longjmp
 * itself as host imports (user/bin/wasm.c3, "interpreter-assisted
 * setjmp/longjmp"). Build with `-I lib/wasm/include` so this header
 * wins over the system one. Plain C semantics: locals modified after
 * setjmp are indeterminate unless volatile or in memory. */
#ifndef RACCCOON_SETJMP_H
#define RACCCOON_SETJMP_H

typedef int jmp_buf[1];
typedef int sigjmp_buf[1];

int __racccoon_setjmp(int *env)
    __attribute__((import_module("racccoon"), import_name("setjmp"), returns_twice));
_Noreturn void __racccoon_longjmp(int *env, int val)
    __attribute__((import_module("racccoon"), import_name("longjmp")));

#define setjmp(env)          __racccoon_setjmp(env)
#define longjmp(env, val)    __racccoon_longjmp(env, val)
#define _setjmp(env)         __racccoon_setjmp(env)
#define _longjmp(env, val)   __racccoon_longjmp(env, val)
#define sigsetjmp(env, save) __racccoon_setjmp(env)
#define siglongjmp(env, val) __racccoon_longjmp(env, val)

#endif
