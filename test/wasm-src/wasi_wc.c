// WASI fixture: a tiny wc over stdin (fd_read on fd 0). `echo hi there | wasm
// wasi_wc.wasm` prints "1 2 9".
#include <stdio.h>
#include <ctype.h>

int main(void)
{
    long lines = 0, words = 0, bytes = 0;
    int c, in_word = 0;
    while ((c = getchar()) != EOF) {
        bytes++;
        if (c == '\n') lines++;
        if (isspace(c)) in_word = 0;
        else if (!in_word) { in_word = 1; words++; }
    }
    printf("%ld %ld %ld\n", lines, words, bytes);
    return 0;
}
