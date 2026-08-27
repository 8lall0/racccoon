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
//
// `write -a <path> <text>` appends to the current end instead (via
// fs_write_at + FS_OFFSET_APPEND) — for a file that doesn't exist yet
// that's the same as a plain write from offset 0.
fn void main(String[] args) {
    bool append = args.len == 3 && args[0].len == 2 && args[0][0] == '-' && args[0][1] == 'a';
    if (args.len != 2 && !append) {
        print("usage: write [-a] <path> <text>\n");
        return;
    }

    char* path = append ? args[1].ptr : args[0].ptr;
    String text = append ? args[2] : args[1];

    int written = append
        ? fs_write_at(path, text.ptr, (int)text.len, FS_OFFSET_APPEND)
        : fs_write(path, text.ptr, (int)text.len);
    if (written < 0) {
        print("write: ");
        print(path);
        print(": failed\n");
    }
}
