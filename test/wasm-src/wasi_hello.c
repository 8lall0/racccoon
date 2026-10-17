// WASI fixture: printf, argv, environ, clean exit. Self-checking: exits 0 on
// success, else the number of the first failed check (wasitest reads only the
// exit code). Run as `wasm wasi_hello.wasm a b` with WASITEST=hello in the
// environment (wasitest writes /env/WASITEST).
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv)
{
    printf("hello from wasi, argc=%d\n", argc);
    if (argc != 3) return 1;
    if (strstr(argv[0], "wasi_hello") == NULL) return 2;   // argv[0] = the module
    if (strcmp(argv[1], "a") != 0 || strcmp(argv[2], "b") != 0) return 3;
    const char *wt = getenv("WASITEST");                   // wasitest sets /env/WASITEST=hello
    if (wt == NULL || strcmp(wt, "hello") != 0) return 4;
    char buf[32];
    snprintf(buf, sizeof buf, "%d-%s-%.1f", 42, "x", 1.5);
    if (strcmp(buf, "42-x-1.5") != 0) return 5;
    // Signed bytes: i32.load8_s / i32.extend8_s must sign-extend (an
    // interpreter that zero-extends reads 0x80 as 128, not -128).
    volatile signed char sb[2] = { (signed char)0x80, (signed char)0xFF };
    int sum = sb[0] + sb[1];                               // -128 + -1
    if (sum != -129) return 6;
    volatile int wide = 0x1234F0;
    if ((signed char)wide != -16) return 7;
    printf("argv ok, WASITEST=%s\n", wt);
    return 0;
}
