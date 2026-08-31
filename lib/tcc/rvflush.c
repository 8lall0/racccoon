/* __clear_cache for a tcc-linked binary on racccoon.
 *
 * TinyCC emits calls to __clear_cache from tccrun.c (the -run / JIT
 * path) to sync the I-cache after generating code. On gcc it's a
 * builtin; tcc's own lib/armflush.c provides it for the cross case, but
 * that file's __riscv branch calls __riscv64_clear_cache, a *tcc*
 * builtin — so it can't be gcc-compiled into libtcc1.a. This replaces
 * it. racccoon's tcc compiles to a file, never -run, so this is linked
 * but never called; a no-op is correct until on-device -run is a goal
 * (which would need a real fence.i / C906 I-cache sync here). */
void __clear_cache(void *beg, void *end)
{
	(void)beg;
	(void)end;
}

void __riscv64_clear_cache(void *beg, void *end)
{
	(void)beg;
	(void)end;
}
