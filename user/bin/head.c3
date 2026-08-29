module user;

import std::nolibc::main_stub;

// Print the first N lines of stdin (default 10), then stop reading — a
// filter for the middle or end of a pipeline (`ls | head -n 3`). No
// file argument: reads stdin only, which the shell wires to a pipe.
// `head -n 0` prints nothing.
fn void main(String[] args) {
    int limit = 10;
    if (args.len == 2 && args[0].len == 2 && args[0][0] == '-' && args[0][1] == 'n') {
        int v = 0;
        String s = args[1];
        for (usz i = 0; i < s.len; i++) {
            if (s[i] < '0' || s[i] > '9') { print("head: bad line count\n"); return; }
            v = v * 10 + (s[i] - '0');
        }
        limit = v;
    } else if (args.len != 0) {
        print("usage: head [-n count]\n");
        return;
    }

    int lines = 0;
    while (lines < limit) {
        int c = getchar();
        if (c < 0) { return; }
        putchar((char)c);
        if (c == '\n') { lines++; }
    }
}
