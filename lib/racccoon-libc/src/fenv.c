/* <fenv.h>: straight onto the fflags / frm / fcsr CSRs. */
#include <fenv.h>

int feclearexcept(int e) { __asm__ volatile("csrc fflags, %0" :: "r"(e & FE_ALL_EXCEPT)); return 0; }
int feraiseexcept(int e) { __asm__ volatile("csrs fflags, %0" :: "r"(e & FE_ALL_EXCEPT)); return 0; }

int fetestexcept(int e)
{
	unsigned f;
	__asm__ volatile("frflags %0" : "=r"(f));
	return (int)f & e & FE_ALL_EXCEPT;
}

int fegetexceptflag(fexcept_t *p, int e) { *p = (fexcept_t)fetestexcept(e); return 0; }

int fesetexceptflag(const fexcept_t *p, int e)
{
	feclearexcept(e);
	feraiseexcept((int)*p & e);
	return 0;
}

int fegetround(void)
{
	unsigned r;
	__asm__ volatile("frrm %0" : "=r"(r));
	return (int)r;
}

int fesetround(int r)
{
	if (r < FE_TONEAREST || r > FE_UPWARD) return -1;
	__asm__ volatile("fsrm %0" :: "r"(r));
	return 0;
}

int fegetenv(fenv_t *env)
{
	unsigned v;
	__asm__ volatile("frcsr %0" : "=r"(v));
	*env = v;
	return 0;
}

int fesetenv(const fenv_t *env)
{
	unsigned v = env == FE_DFL_ENV ? 0 : *env;
	__asm__ volatile("fscsr %0" :: "r"(v));
	return 0;
}

int feholdexcept(fenv_t *env)
{
	fegetenv(env);
	feclearexcept(FE_ALL_EXCEPT);   /* no trap enables on RISC-V: nothing else to mask */
	return 0;
}

int feupdateenv(const fenv_t *env)
{
	int raised = fetestexcept(FE_ALL_EXCEPT);
	fesetenv(env);
	feraiseexcept(raised);
	return 0;
}
