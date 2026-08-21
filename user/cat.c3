module user;

// Real, argv-taking replacement for shell.c3's own former readfile/
// readfile2/readsubfile/readsubfile2 (all four hardcoded to a fixed
// path) — one path argument, prints its content. Multi-file support
// real cat has isn't added: nothing in this project ever needed it.
fn void main() @export("main") {
    char** argv;
    int argc = get_argv(&argv);
    if (argc != 1) {
        print("usage: cat <path>\n");
        return;
    }

    char[1024] buf @noinit;
    int len = fs_read(argv[0], &buf, 1023);
    if (len < 0) {
        print("cat: ");
        print(argv[0]);
        print(": not found\n");
        return;
    }
    buf[len] = 0;
    print(&buf);
    print("\n");
}
