module user;

import std::io;

// Print the first N lines of stdin (default 10), then stop reading — a
// filter for the middle or end of a pipeline (`ls | head -n 3`). No
// file argument: reads stdin only, which the shell wires to a pipe.
// `head -n 0` prints nothing.
fn void main(String[] args) {
    int limit = 10;
    if (args.len == 2 && args[0].len == 2 && args[0][0] == '-' && args[0][1] == 'n') {
        int? v = args[1].to_int();
        if (catch v) { io::print("head: bad line count\n"); return; }
        limit = v;
    } else if (args.len != 0) {
        io::print("usage: head [-n count]\n");
        return;
    }

    // Run bare on the console with nothing piped in: there's no console
    // EOF, so the read loop below would just wait for the user to
    // hand-type `limit` newline-terminated lines. Print usage instead.
    if (stdin_is_console() != 0) {
        io::print("usage: head [-n count]   (reads stdin — use it in a pipeline)\n");
        return;
    }

    int lines = 0;
    while (lines < limit) {
        int c = getchar();
        if (c < 0) { return; }
        io::putchar((char)c);
        if (c == '\n') { lines++; }
    }
}
