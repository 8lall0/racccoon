module user;

import std::nolibc::main_stub;

// chmod <octal-mode> <path> — replaces the permission bits (i_mode's low
// 12) of an ext2 file or directory, keeping the format nibble. Octal
// only, like real chmod's numeric form ("644", "755", "600"). ext2
// mounts only: a FAT32/exFAT target has no i_mode on disk and fails.
// Owner-or-root — see docs/roadmap.md §2.
fn void main(String[] args) {
    if (args.len != 2) {
        print("usage: chmod <octal-mode> <path>\n");
        return;
    }

    char* m = args[0].ptr;
    if (m[0] == 0) { print("chmod: bad mode\n"); return; }
    uint mode = 0;
    for (int i = 0; m[i] != 0; i++) {
        if (m[i] < '0' || m[i] > '7') { print("chmod: mode must be octal\n"); return; }
        mode = mode * 8 + (uint)(m[i] - '0');
    }

    if (fs_chmod(args[1].ptr, mode) < 0) {
        print("chmod: ");
        print(args[1].ptr);
        print(": failed\n");
    }
}
