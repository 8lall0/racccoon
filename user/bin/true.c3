module user;

import std::nolibc::main_stub;

// Exit 0, always — the canonical success command for `&&` / `||`
// (shell_exec_line, user/shell_common.c3) and a no-op statement.
fn void main() {
    exitcode(0);
}
