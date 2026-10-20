module user;

import std::nolibc::main_stub;
import std::nolibc::fmt;

// Test shell: every dev/regression-test command this project has
// accumulated across its whole tutorial/bring-up history. This is what
// scripts/build.sh embeds for QEMU — the real, end-user-only builtins
// (hello/exit/mountusb/the /bin/ fallback) live in user/shell_common.c3
// instead, shared with the trimmed production shell (user/shell.c3,
// what scripts/build_duo.sh embeds for real hardware). See
// docs/devlog.md for why this split exists (shell.c3 used to carry
// both).
//
// The builtins themselves live in user/shell_test_{fs,ipc,proc,drivers,
// lang}.c3, one shell_test_<cat>_dispatch() each; main() below only
// reads + tokenizes a line and tries them in turn.
// For the ext2-only builtins: true (after printing "<name>: skipped
// (...)") when the root filesystem isn't ext2 — e.g. a FAT32-root QEMU
// image — so a run there reports skipped, not a misleading FAILED. Uses
// FS_STAT's backend byte (fs_type_of), not "the first call failed", so a
// genuine ext2 regression still shows up as FAILED.
fn bool test_skip_unless_ext2_root(char* name, char* why) {
    int t = fs_type_of("/");
    if (t == FS_TYPE_EXT2) return false;
    print(name);
    print(": skipped (root is not ext2 — ");
    print(why);
    print(")\n");
    return true;
}

fn void main() {
    // ~3 s covers the (fast) virtio boot chatter; automated test runs
    // wait much longer than this before sending anything anyway.
    // timebase_hz() so an OPI_TEST_SHELL=1 build on the sifive_u harness
    // (1 MHz) settles in 3 s, not 30.
    shell_notes_init();   // catch ^C (src/note.c3) instead of dying of it
    shell_boot_settle(timebase_hz() * 3);
    shell_bind_user_bin();   // union /usr/root/bin onto /bin (docs/bin-layout.md)
    for (;;) {
        shell_prompt();

        // Cursor editing + history — shell_common.c3's shared reader
        // (arrows, ^A/^E/^K/^U/^W, Home/End/Del, up-arrow recall).
        char[128] cmdline @noinit;
        if (shell_readline_p(&cmdline[0], 128, &g_prompt_str[0], true) < 0) { continue; }

        // $var expansion, then tokenize the result in place.
        char[512] expanded @noinit;
        shell_expand(&cmdline[0], &expanded[0], 512);

        const int SHELL_MAX_TOKENS = 16;
        char*[SHELL_MAX_TOKENS] tokens @noinit;
        int token_count = 0;
        int ti = 0;
        while (expanded[ti] != 0 && token_count < SHELL_MAX_TOKENS) {
            while (expanded[ti] == ' ') ti++;
            if (expanded[ti] == 0) break;
            tokens[token_count] = &expanded[ti];
            token_count++;
            while (expanded[ti] != 0 && expanded[ti] != ' ') ti++;
            if (expanded[ti] == ' ') { expanded[ti] = 0; ti++; }
        }
        if (token_count == 0) continue;

        char* cmd = tokens[0];
        char** cmd_argv = &tokens[1];
        int cmd_argc = token_count - 1;
        // The dev/test builtins, by category (user/shell_test_*.c3).
        if (shell_test_fs_dispatch(cmd, cmd_argv, cmd_argc)) continue;
        if (shell_test_ipc_dispatch(cmd, cmd_argv, cmd_argc)) continue;
        if (shell_test_proc_dispatch(cmd, cmd_argv, cmd_argc)) continue;
        if (shell_test_drivers_dispatch(cmd, cmd_argv, cmd_argc)) continue;
        if (shell_test_lang_dispatch(cmd, cmd_argv, cmd_argc)) continue;
        if (shell_test_cam_dispatch(cmd, cmd_argv, cmd_argc)) continue;

        // Not a dev/test builtin: hand the raw line to the real
        // executor. shell_exec_block splits statements and runs
        // `if` / `for` / `while` / `NAME=value` (shell_common.c3);
        // everything else falls through to shell_exec_line (`;` /
        // `&&` / `||`, `$var`, `|`, `<` / `>`, globbing). The dev
        // shell reads one 128-byte line at a time, so a *multi-line*
        // `if (...) { ... }` needs `. script` — single-line
        // `if (test -f x) { echo y }` works here directly.
        shell_exec_block(&cmdline[0]);
    }
}
