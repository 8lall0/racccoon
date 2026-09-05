module user;

import std::io;

// Prints the current user's name (uid → name via /adm/users, falling
// back to the decimal uid). See docs/roadmap.md §2.
fn void main() {
    char[32] name @noinit;
    user_name_by_uid(getuid(), &name[0], 32);
    io::print((ZString)&name[0]);
    io::print("\n");
}
