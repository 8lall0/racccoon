#ifndef _FENV_H
#define _FENV_H
#ifdef __cplusplus
extern "C" {
#endif

/* <fenv.h> on RISC-V: the exception flags and rounding mode are the
 * fflags / frm CSRs (src/fenv.c). Values match the hardware encoding
 * (and glibc's riscv headers). */

#define FE_INEXACT    0x01
#define FE_UNDERFLOW  0x02
#define FE_OVERFLOW   0x04
#define FE_DIVBYZERO  0x08
#define FE_INVALID    0x10
#define FE_ALL_EXCEPT 0x1f

#define FE_TONEAREST  0
#define FE_TOWARDZERO 1
#define FE_DOWNWARD   2
#define FE_UPWARD     3

typedef unsigned int fenv_t;      /* the whole fcsr */
typedef unsigned int fexcept_t;

#define FE_DFL_ENV ((const fenv_t *)-1)

int feclearexcept(int excepts);
int fegetexceptflag(fexcept_t *flagp, int excepts);
int feraiseexcept(int excepts);
int fesetexceptflag(const fexcept_t *flagp, int excepts);
int fetestexcept(int excepts);
int fegetround(void);
int fesetround(int round);
int fegetenv(fenv_t *envp);
int feholdexcept(fenv_t *envp);
int fesetenv(const fenv_t *envp);
int feupdateenv(const fenv_t *envp);

#ifdef __cplusplus
}
#endif
#endif
