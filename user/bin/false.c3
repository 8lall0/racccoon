module user;

import std::nolibc::main_stub;

// Exit 1, always — the counterpart to /bin/true, for `&&` / `||`
// (shell_exec_line, user/shell_common.c3).
fn void main() {
    exitcode(1);
}
