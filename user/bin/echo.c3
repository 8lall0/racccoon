module user;

import std::nolibc::main_stub;

// The `echo` builtin (shell_dispatch_common, user/shell_common.c3) as a
// real /bin binary too: a builtin can't be the left side of a pipe or
// feed a redirection (shell_run_line only ever spawns externals for a
// pipeline segment), so `echo hi | cat` and `echo hi > f` need this.
// Same behaviour as the builtin — space-joined args, trailing newline.
fn void main(String[] args) {
    for (usz e = 0; e < args.len; e++) {
        if (e > 0) { putchar(' '); }
        print(args[e].ptr);
    }
    putchar('\n');
}
