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
    for (;;) {
        shell_prompt();

        char[128] cmdline @noinit;
        int i = 0;
        bool too_long = false;
        for (;;) {
            char ch = (char)getchar();
            // 0x7F (DEL) and 0x08 (BS) — different terminal
            // emulators/serial console tools send different bytes for
            // Backspace, no way to know which in advance, so both are
            // handled. Checked before the echo/full-buffer logic below
            // (not gated behind i == 127) so a user can also backspace
            // their way back from a genuinely full line instead of it
            // being unconditionally abandoned — falls out of the
            // ordering, not extra logic. The raw byte is never echoed
            // via putchar() — "\b \b" (cursor back, blank, cursor back
            // again) is what actually erases the character on-screen.
            if (ch == 127 || ch == 8) {
                if (i > 0) {
                    i--;
                    print("\b \b");
                }
                continue;
            }
            putchar(ch);
            if (i == 127) {
                print("\ncommand line too long\n");
                too_long = true;
                break;
            }
            if (ch == '\r') {
                print("\n");
                cmdline[i] = 0;
                break;
            }
            cmdline[i] = ch;
            i++;
        }

        if (too_long) continue;

        // `;` / `&&` / `||` sequencing, then per-pipeline `$var`
        // expansion + tokenising + `|` / `<` / `>` / `>>`; a plain line
        // is still just shell_dispatch_common || the /bin fallback
        // (see shell_exec_line, user/shell_common.c3).
        shell_exec_line(&cmdline[0]);
    }
}
