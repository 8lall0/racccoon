module user;

import std::nolibc::main_stub;

// Real, argv-taking replacement for shell.c3's own former writefile/
// newfile/newfile2/newsubfile/newsubfile2 (all hardcoded path+content
// combinations) — fs_write() already creates-or-overwrites
// transparently, so one utility covers every one of those old
// scenarios. No shell redirection exists in this project (no "echo
// text > file"), so this takes the content directly as its own second
// argument rather than trying to imitate a real Unix "write" (which
// means something else entirely — talking to another user's terminal).
fn void main() {
    char** argv;
    int argc = get_argv(&argv);
    if (argc != 2) {
        print("usage: write <path> <text>\n");
        return;
    }

    int len = 0;
    while (argv[1][len] != 0) len++;

    int written = fs_write(argv[0], argv[1], len);
    if (written < 0) {
        print("write: ");
        print(argv[0]);
        print(": failed\n");
    }
}
