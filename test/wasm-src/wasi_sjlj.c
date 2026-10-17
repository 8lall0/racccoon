// WASI fixture: setjmp/longjmp (racccoon's interpreter-assisted version via
// include/setjmp.h; the system one natively). Unwinds out of deep recursion
// with big stack frames — so the C stack pointer must really be restored —
// nested and reused jmp_bufs, val 0 -> 1. Self-checking: exit 0 or check no.
#include <setjmp.h>
#include <stdio.h>
#include <string.h>

static jmp_buf outer, inner;
static volatile int depth_reached;

static int deep(int n, int bail_at)
{
    char pad[512];                                   // grow the C stack per level
    memset(pad, n & 0x7f, sizeof pad);
    if (n == bail_at) { depth_reached = n; longjmp(outer, 42); }
    return deep(n + 1, bail_at) + pad[n % 512];
}

static int nested(void)
{
    volatile int stage = 0;
    if (setjmp(inner) == 0) {
        stage = 1;
        longjmp(inner, 0);                           // val 0 must arrive as 1
    }
    return stage == 1 ? 1 : 0;
}

int main(void)
{
    char marker[64];
    strcpy(marker, "stack intact");

    volatile int r = setjmp(outer);
    if (r == 0) {
        deep(0, 200);                                // ~100 KiB of C stack, then jump out
        return 1;                                    // unreachable
    }
    if (r != 42) return 2;
    if (depth_reached != 200) return 3;
    if (strcmp(marker, "stack intact") != 0) return 4;   // our frame's stack data survived

    if (!nested()) return 5;

    // Reuse the same buffer many times (the interpreter keeps one slot per buffer).
    volatile int loops = 0;
    for (int i = 0; i < 100; i++) {
        if (setjmp(outer) == 0) longjmp(outer, i + 1);
        loops++;
    }
    if (loops != 100) return 6;

    // A second unwind after the first: the stack pointer was restored the first time.
    volatile int r2 = setjmp(outer);
    if (r2 == 0) { deep(0, 150); return 7; }
    if (r2 != 42 || depth_reached != 150) return 8;

    printf("wasi_sjlj: ok\n");
    return 0;
}
