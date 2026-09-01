module user;

import std::nolibc::main_stub;

// chown <uid|name> <path> — sets the owner uid of an ext2 file or
// directory. Accepts a decimal uid or a name resolved through
// /adm/users. ext2 mounts only; root-only (POSIX — you cannot give a
// file away, and racccoon's uid model only drops). See docs/roadmap.md §2.
fn void main(String[] args) {
    if (args.len != 2) {
        print("usage: chown <uid|name> <path>\n");
        return;
    }

    char* who = args[0].ptr;
    bool numeric = who[0] != 0;
    for (int i = 0; who[i] != 0; i++) {
        if (who[i] < '0' || who[i] > '9') { numeric = false; break; }
    }

    int uid;
    if (numeric) {
        uid = 0;
        for (int i = 0; who[i] != 0; i++) uid = uid * 10 + (int)(who[i] - '0');
    } else {
        uid = user_uid_by_name(who);
    }
    if (uid < 0) {
        print("chown: ");
        print(who);
        print(": unknown user\n");
        return;
    }

    if (fs_chown(args[1].ptr, (uint)uid) < 0) {
        print("chown: ");
        print(args[1].ptr);
        print(": failed\n");
    }
}
