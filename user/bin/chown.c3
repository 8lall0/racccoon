module user;

import std::io;

// chown <uid|name> <path> — sets the owner uid of an ext2 file or
// directory. Accepts a decimal uid or a name resolved through
// /adm/users. ext2 mounts only; root-only (POSIX — you cannot give a
// file away, and racccoon's uid model only drops). See docs/roadmap.md §2.
fn void main(String[] args) {
    if (args.len != 2) {
        io::print("usage: chown <uid|name> <path>\n");
        return;
    }

    char* who = args[0].ptr;
    int? numeric_uid = args[0].to_int();
    int uid;
    if (catch numeric_uid) { uid = user_uid_by_name(who); } else { uid = numeric_uid; }
    if (uid < 0) {
        io::print("chown: ");
        io::print((ZString)who);
        io::print(": unknown user\n");
        return;
    }

    if (fs_chown(args[1].ptr, (uint)uid) < 0) {
        io::print("chown: ");
        io::print((ZString)args[1].ptr);
        io::print(": failed\n");
    }
}
