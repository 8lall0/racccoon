module user;

import std::nolibc::main_stub;

// Real, argv-taking replacement for shell.c3's own former mkdirtest
// (hardcoded to a fixed path).
fn void main(String[] args) {
    if (args.len != 1) {
        print("usage: mkdir <path>\n");
        return;
    }

    int result = fs_mkdir(args[0].ptr);
    if (result < 0) {
        print("mkdir: ");
        print(args[0].ptr);
        print(": failed\n");
    }
}
