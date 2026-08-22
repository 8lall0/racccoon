module user;

import std::nolibc::main_stub;

// Real, argv-taking replacement for shell.c3's own former deletetest/
// deletetest2/rmdirtest/rmdirtest2/rmdirnonempty/rmdirnonempty2/rmrtest
// (all hardcoded to fixed paths) — plain delete (files and empty
// directories, matching fs_delete's own existing behavior) or, with a
// leading -r flag, recursive delete (fs_delete_recursive).
fn void main() {
    char** argv;
    int argc = get_argv(&argv);

    int result;
    char* target;
    if (argc == 1) {
        target = argv[0];
        result = fs_delete(target);
    } else if (argc == 2 && strcmp(argv[0], "-r") == 0) {
        target = argv[1];
        result = fs_delete_recursive(target);
    } else {
        print("usage: rm <path> | rm -r <path>\n");
        return;
    }

    if (result < 0) {
        print("rm: ");
        print(target);
        print(": failed\n");
    }
}
