module user;

import std::nolibc::main_stub;

// Real, argv-taking replacement for shell.c3's own former ls/lssub
// (hardcoded to "" and "subdir" respectively) — one optional path
// argument (root if omitted). Listing/printing logic unchanged from
// the original shell.c3 code (FS_LIST's own wire format: each record
// is FS_LIST_NAME_MAX-null-terminated name, then a type byte at
// offset 32 — 0 file, nonzero directory).
fn void main() {
    char** argv;
    int argc = get_argv(&argv);
    char* path = argc > 0 ? argv[0] : "";

    char[576] listbuf @noinit; // FS_LIST_ENTRY_SIZE * 16 entries
    int count = fs_list(path, &listbuf, 16);
    if (count < 0) {
        print("ls: ");
        print(path);
        print(": not found\n");
        return;
    }
    for (int li = 0; li < count; li++) {
        char* rec = &listbuf[li * 36];
        print(rec);
        if (rec[32] != 0) {
            print("/");
        }
        print("\n");
    }
}
