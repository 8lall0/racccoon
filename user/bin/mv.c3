module user;

import std::nolibc::main_stub;

// Real, argv-taking replacement for shell.c3's own former renametest/
// movetest (both hardcoded to fixed paths) — fs_rename() already
// handles same-directory rename and cross-directory move identically,
// so one utility covers both old scenarios.
fn void main(String[] args) {
    if (args.len != 2) {
        print("usage: mv <old> <new>\n");
        return;
    }

    int result = fs_rename(args[0].ptr, args[1].ptr);
    if (result < 0) {
        print("mv: ");
        print(args[0].ptr);
        print(": failed\n");
    }
}
