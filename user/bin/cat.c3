module user;

import std::nolibc::main_stub;

// Real, argv-taking replacement for shell.c3's own former readfile/
// readfile2/readsubfile/readsubfile2 (all four hardcoded to a fixed
// path) — one path argument, prints its content. Multi-file support
// real cat has isn't added: nothing in this project ever needed it.
//
// With no argument it copies stdin to stdout a byte at a time until
// EOF (getchar() == -1) — this is the `echo hi | cat` / `cat < file`
// case, where the shell (shell_run_line, user/shell_common.c3) has
// wired this process's stdin to a pipe.
fn void main(String[] args) {
    if (args.len == 0) {
        // Bare on the console with nothing piped in: no console EOF, so
        // this would block forever. Print usage instead.
        if (stdin_is_console() != 0) {
            print("usage: cat [path]   (with no path, copies stdin — use it in a pipeline)\n");
            return;
        }
        for (;;) {
            int c = getchar();
            if (c < 0) { return; }
            putchar((char)c);
        }
    }
    if (args.len != 1) {
        print("usage: cat [path]\n");
        return;
    }
    char* path = args[0].ptr;

    char[1024] buf @noinit;
    int len = fs_read(path, &buf, 1023);
    if (len < 0) {
        print("cat: ");
        print(path);
        print(": not found\n");
        return;
    }
    buf[len] = 0;
    print(&buf);
    print("\n");
}
