module user;

import std::nolibc::main_stub;

// Prints the current user's name (uid → name via /adm/users, falling
// back to the decimal uid). See docs/roadmap.md §2.
fn void main() {
    char[32] name @noinit;
    user_name_by_uid(getuid(), &name[0], 32);
    print(&name[0]);
    print("\n");
}
