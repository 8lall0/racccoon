// Adapted from the real c3 stdlib's std::core::mem — specifically its
// own NO_LIBC feature block (/usr/lib/c3c/lib/std/core/mem.c3, module
// std::core::mem @feat(NO_LIBC)): plain C-style __memcpy/__memset/
// __memcmp implementations, no allocator, no OS dependency, exported
// under the real C symbol names. Copied nearly verbatim rather than
// hand-written, same "adapt real stdlib code, don't reinvent it"
// approach user/atomic.c3 already established for std::atomic::types —
// see that file's own header comment for the full reasoning. Needed for
// the same reason atomic.c3 was: user-mode binaries build with
// --use-stdlib=no (scripts/build_user.sh), so the real module isn't
// reachable at all, not even its own NO_LIBC variant.
//
// Also provides copy()/set() as plain functions, not the real stdlib's
// own macro-based mem::copy()/mem::set() (which lower through
// $$memcpy/$$memset compiler builtins — machinery tied to stdlib
// infrastructure this freestanding build doesn't have reachable
// either). Giving user-mode code the exact same mem::copy(dst, src,
// len)/mem::set(dst, val, len) calling convention the kernel side
// (src/*.c3, real std::core::mem, stdlib fully available there)
// already uses everywhere means one calling convention project-wide,
// not two — every hand-rolled byte-copy loop this codebase had grown
// across procd.c3/envd.c3/fsd.c3/shell.c3 (one per binary, since each
// is a separate build unit with nothing shared) collapses to the same
// mem::copy() call the kernel already reaches for.
module std::core::mem;

fn int __memcmp(void* s1, void* s2, sz n) @weak @export("memcmp")
{
    char* p1 = s1;
    char* p2 = s2;
    for (sz i = 0; i < n; i++, p1++, p2++)
    {
        char c1 = *p1;
        char c2 = *p2;
        if (c1 < c2) return -1;
        if (c1 > c2) return 1;
    }
    return 0;
}

fn void* __memset(void* str, int c, sz n) @weak @export("memset")
{
    char* p = str;
    char cc = (char)c;
    for (sz i = 0; i < n; i++, p++)
    {
        *p = cc;
    }
    return str;
}

fn void* __memcpy(void* dst, void* src, sz n) @weak @export("memcpy")
{
    char* d = dst;
    char* s = src;
    for (sz i = 0; i < n; i++, d++, s++)
    {
        *d = *s;
    }
    return dst;
}

// dst/src ranges must not overlap — same contract the real mem::copy()
// documents (@require'd there via contracts this freestanding build
// doesn't have reachable; left as a plain documented precondition
// here instead). Every existing call site this session's own port
// replaces was already a forward, non-overlapping byte-copy loop, so
// this holds for all of them.
fn void copy(void* dst, void* src, sz len)
{
    __memcpy(dst, src, len);
}

fn void set(void* dst, char val, sz len)
{
    __memset(dst, (int)val, len);
}
