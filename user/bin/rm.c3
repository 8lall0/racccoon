module user;

import std::io;

// Real, argv-taking replacement for shell.c3's own former deletetest/
// deletetest2/rmdirtest/rmdirtest2/rmdirnonempty/rmdirnonempty2/rmrtest
// (all hardcoded to fixed paths) — plain delete (files and empty
// directories, matching fs_delete's own existing behavior) or, with a
// leading -r flag, recursive delete (fs_delete_recursive).
fn void main(String[] args) {
    int result;
    char* target;
    if (args.len == 1) {
        target = args[0].ptr;
        result = fs_delete(target);
    } else if (args.len == 2 && strcmp(args[0].ptr, "-r") == 0) {
        target = args[1].ptr;
        result = fs_delete_recursive(target);
    } else {
        io::print("usage: rm <path> | rm -r <path>\n");
        return;
    }

    if (result < 0) {
        io::print("rm: ");
        io::print((ZString)target);
        io::print(": failed\n");
    }
}
