/* <assert.h> — re-includable, honours NDEBUG at each inclusion, per the
 * standard. On failure: a line on stderr, then abort() (exit 134). */
#undef assert

#ifdef NDEBUG
#define assert(x) ((void)0)
#else
void __libc_assert_fail(const char *expr, const char *file, int line, const char *func);
#define assert(x) \
	((x) ? (void)0 : __libc_assert_fail(#x, __FILE__, __LINE__, __func__))
#endif

#ifndef _ASSERT_H
#define _ASSERT_H
#ifdef __cplusplus
extern "C" {
#endif
#if !defined(__cplusplus) && (!defined(__STDC_VERSION__) || __STDC_VERSION__ < 202311L)
#define static_assert _Static_assert   /* C11; a keyword in C++ and C23 */
#endif
#ifdef __cplusplus
}
#endif
#endif
