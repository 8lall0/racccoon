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

        // Tokenize on spaces, in place — each token is a pointer
        // straight into cmdline, NUL-terminated where the next space
        // was, same "no separate storage" approach exec()'s own
        // NUL-separated argv blob already uses (user.c3). cmd_argv/
        // cmd_argc (everything after the command name) only matter to
        // the /bin/ fallback branch at the very end of this chain —
        // every builtin below ignores them, unchanged from before this
        // tokenization existed.
        const int SHELL_MAX_TOKENS = 8;
        char*[SHELL_MAX_TOKENS] tokens @noinit;
        int token_count = 0;
        int ti = 0;
        while (cmdline[ti] != 0 && token_count < SHELL_MAX_TOKENS) {
            while (cmdline[ti] == ' ') ti++;
            if (cmdline[ti] == 0) break;
            tokens[token_count] = &cmdline[ti];
            token_count++;
            while (cmdline[ti] != 0 && cmdline[ti] != ' ') ti++;
            if (cmdline[ti] == ' ') { cmdline[ti] = 0; ti++; }
        }
        if (token_count == 0) continue;

        char* cmd = tokens[0];
        char** cmd_argv = &tokens[1];
        int cmd_argc = token_count - 1;
        if (!shell_dispatch_common(cmd, cmd_argv, cmd_argc)) {
            shell_exec_external(cmd, cmd_argv, cmd_argc);
        }
    }
}
