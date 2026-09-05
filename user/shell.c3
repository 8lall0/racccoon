module user;

import std::nolibc::main_stub;

// Production shell: only the real, end-user builtins
// (shell_dispatch_common()/shell_exec_external(), user/shell_common.c3)
// — this is what actually ships embedded in the real hardware kernel
// image (scripts/build_duo.sh). Every dev/regression-test command this
// project has accumulated lives in user/shell_test.c3 instead, which is
// what scripts/build.sh embeds for QEMU. See docs/devlog.md for why
// this split exists (shell.c3 used to carry both).
fn void main() {
    // Duo timebase is 25 MHz — ~6 s, long enough to cover sdd/usb/ethd
    // bring-up (this shell is only ever built for the Duo; QEMU gets
    // shell_test.c3).
    shell_boot_settle(150000000);

    // The console comes up needing a login — `login: <name>`, matched
    // against /adm/users, then setuid + cd $home. `root` is always
    // valid, so there's no lockout. On `exit` the kernel respawns this
    // shell fresh as root and the prompt returns. (shell_test.c3, the
    // QEMU build, skips this — its automated runs expect a root shell
    // immediately; the `login` builtin is still there to exercise it.)
    shell_login();
    shell_bind_user_bin();   // union /usr/$user/bin onto /bin (docs/bin-layout.md)

    for (;;) {
        shell_prompt();

        // A block (one line, or several if it has an open `(` / `{` —
        // `if (…) { … }` spread over lines gets a `> ` continuation
        // prompt). shell_exec_block splits it into statements: `if` /
        // `for` / `while` and `NAME=value` are handled in
        // shell_common.c3, everything else flows through shell_exec_line
        // (`;` / `&&` / `||`, `$var`, `|`, `<` / `>`, globbing) exactly
        // as before.
        char[2048] block @noinit;
        if (shell_read_block(&block[0], 2048) < 0) { continue; }
        shell_exec_block(&block[0]);
    }
}
