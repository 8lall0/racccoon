module user;

import std::nolibc::main_stub;

// Real, argv-taking replacement for shell.c3's own former readfile/
// readfile2/readsubfile/readsubfile2 (all four hardcoded to a fixed
// path) — one path argument, prints its content. Multi-file support
// real cat has isn't added: nothing in this project ever needed it.
fn void main(String[] args) {
    if (args.len != 1) {
        print("usage: cat <path>\n");
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
