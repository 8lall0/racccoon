module user;

import std::io;

// Real, argv-taking replacement for shell.c3's own former readfile/
// readfile2/readsubfile/readsubfile2 (all four hardcoded to a fixed
// path) — one path argument, prints its content. Multi-file support
// real cat has isn't added: nothing in this project ever needed it.
//
// With no argument it copies stdin to stdout a byte at a time until
// EOF (getchar() == -1) — this is the `echo hi | cat` / `cat < file`
// case, where the shell (shell_run_line, user/shell_common.c3) has
// wired this process's stdin to a pipe.
//
// getchar()/stdin_is_console()/fs_read() are racccoon's own syscall
// wrappers (user.c3, this same module) — std::io has no notion of
// racccoon's pipe/fsd primitives, so those stay as they were; only the
// actual console output ("std::io on racccoon", docs/devlog.md) goes
// through io::print/io::putchar now.
fn void main(String[] args) {
    if (args.len == 0) {
        // Bare on the console with nothing piped in: no console EOF, so
        // this would block forever. Print usage instead.
        if (stdin_is_console() != 0) {
            io::print("usage: cat [path]   (with no path, copies stdin — use it in a pipeline)\n");
            return;
        }
        for (;;) {
            int c = getchar();
            if (c < 0) { return; }
            io::putchar((char)c);
        }
    }
    if (args.len != 1) {
        io::print("usage: cat [path]\n");
        return;
    }
    char* path = args[0].ptr;

    // Read in 1 KiB chunks with fs_read_at() until EOF (a short/zero read),
    // writing exactly the bytes read — so a file of any size prints in full
    // (this used to be ONE fs_read capped at 1023 bytes and silently dropped
    // the rest, found cat-ing a 1141-byte file on the Orange Pi) and NUL bytes
    // no longer end the output early. A trailing newline is added only if
    // the file didn't end with one.
    char[1024] buf @noinit;
    uint off = 0;
    char last = '\n';
    for (;;) {
        int got = fs_read_at(path, &buf, 1024, off);
        if (got < 0) {
            if (off == 0) {
                io::print("cat: ");
                io::print((ZString)path);
                io::print(": not found\n");
            }
            return;
        }
        if (got == 0) { break; }
        for (int i = 0; i < got; i++) { io::putchar(buf[i]); }
        last = buf[got - 1];
        off += (uint)got;
    }
    if (last != '\n') { io::print("\n"); }
}
