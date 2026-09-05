module user;

import std::io;

// chmod <octal-mode> <path> — replaces the permission bits (i_mode's low
// 12) of an ext2 file or directory, keeping the format nibble. Octal
// only, like real chmod's numeric form ("644", "755", "600"). ext2
// mounts only: a FAT32/exFAT target has no i_mode on disk and fails.
// Owner-or-root — see docs/roadmap.md §2.
fn void main(String[] args) {
    if (args.len != 2) {
        io::print("usage: chmod <octal-mode> <path>\n");
        return;
    }

    uint? mode = args[0].to_uint(8);
    if (catch mode) { io::print("chmod: mode must be octal\n"); return; }

    if (fs_chmod(args[1].ptr, mode) < 0) {
        io::print("chmod: ");
        io::print((ZString)args[1].ptr);
        io::print(": failed\n");
    }
}
