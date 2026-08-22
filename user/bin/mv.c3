module user;

import std::nolibc::main_stub;

// Real, argv-taking replacement for shell.c3's own former renametest/
// movetest (both hardcoded to fixed paths) — fs_rename() already
// handles same-directory rename and cross-directory move identically,
// so one utility covers both old scenarios.
fn void main() {
    char** argv;
    int argc = get_argv(&argv);
    if (argc != 2) {
        print("usage: mv <old> <new>\n");
        return;
    }

    int result = fs_rename(argv[0], argv[1]);
    if (result < 0) {
        print("mv: ");
        print(argv[0]);
        print(": failed\n");
    }
}
