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

        char[128] cmdline @noinit;
        if (shell_readline(&cmdline[0], 128) < 0) { continue; }

        // `;` / `&&` / `||` sequencing, then per-pipeline `$var`
        // expansion + tokenising + `|` / `<` / `>` / `>>` + globbing;
        // a plain line is still just shell_dispatch_common || the /bin
        // fallback (see shell_exec_line, user/shell_common.c3).
        shell_exec_line(&cmdline[0]);
    }
}
