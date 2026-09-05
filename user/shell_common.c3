module user;

// exec()'s own receive buffer — caller-owned per exec()'s header comment
// (user.c3). Sized to the board's EXEC_MAX_IMAGE_SIZE via SYS_EXEC_MAX
// (exec_max(), user.c3) — 1 MiB on the Duo, 4 MiB on QEMU/JH7110 for the
// Go port (docs/go-port-plan.md) — rather than a hardcoded constant that
// would be wrong on some board. Too big to carry as a static array in
// every shell (.bss is materialised into the flat binary, which is then
// embedded in the kernel), so it's SYS_MAP'd on first use — only a
// process that actually exec()s a child pays for it, and only then.
// exec_buf() is always called from the rfork'd child, just before it
// exec()s, so the mapping lives for microseconds.
uint run_exec_buf_max = 0;
char* run_exec_buf_ptr = null;

fn uint exec_buf_max() {
    if (run_exec_buf_max == 0) run_exec_buf_max = exec_max();
    return run_exec_buf_max;
}

fn char* exec_buf() {
    if (run_exec_buf_ptr == null) {
        run_exec_buf_ptr = (char*)map_pages(exec_buf_max());
    }
    return run_exec_buf_ptr; // null on map failure -> exec() returns -1 -> "command not found"
}

// `< file` redirection is bounded at one kernel pipe buffer (PIPE_BUF,
// src/pipe.c3) — the shell preloads the whole file before any child
// runs, so it can't stream more than the buffer holds. Larger inputs
// need a real streaming reader; nothing in this project has wanted one.
const int PIPE_FILE_MAX = 4096;

// mountusb builtin's own wait bound — see that command's own comment
// below for why this is a plain retry count this generous, not a
// wall-clock timeout.
const int MOUNTUSB_WAIT_ATTEMPTS = 2000000;

// Kills whatever's currently mounted at /mnt/usb/ (if anything) and
// removes the namespace binding — shared by mountusb (idempotent
// re-run) and unmountusb (explicit teardown) below. Deliberately
// stateless: reads the live binding straight out of the namespace/
// process tables via ns_resolve()/proc_info() rather than keeping a
// separate side-channel pid/generation pair that could drift out of
// sync with reality (e.g. if the fsd ever died on its own for an
// unrelated reason) — this way there's exactly one place "what's
// mounted at /mnt/usb/" is ever recorded, the namespace table itself.
//
// matched_len == 9 (strlen("/mnt/usb/")) is the real safety check
// here, not just a sanity assertion: ns_resolve()'s own longest-prefix
// match (src/entry.c3's SYS_NS_RESOLVE) falls through to the ""
// catch-all (root fsd, matched_len 0) for ANY path when nothing more
// specific is bound — including "/mnt/usb/" itself, whenever it isn't
// currently mounted. Without this check, calling usbfs_teardown() with
// nothing actually mounted there would resolve to the ROOT filesystem
// server's own pid instead and kill it.
fn void usbfs_teardown()
{
    uint matched_len = 0;
    int old_pid = ns_resolve("/mnt/usb/", &matched_len);
    if (old_pid > 0 && matched_len == 9) {
        uint old_gen = 0;
        proc_info(old_pid, null, &old_gen, null);
        ns_unmount("/mnt/usb/");
        kill(old_pid, old_gen);
    }
}

// The current user, cached — refreshed lazily on the first prompt and
// again after every `su`, rather than an fs_read of /adm/users per
// keystroke line.
char[32] g_shell_user @noinit;
int      g_shell_uid = -1;

// Status of the last simple command, for `&&` / `||` sequencing and the
// `$status` / `$?` var. shell_dispatch_common resets it to 0 on entry;
// a builtin that fails (bad `cd`, denied `su`) sets it non-zero.
// External commands overwrite it with join()'s return in
// shell_run_pipeline.
int g_shell_status = 0;

// Background job control (`cmd &`, `jobs`, `wait`) lives in
// user/shell_jobs.c3; word expansion (quotes, $var, globbing, brace
// expansion) in user/shell_words.c3 — same `module user`, so everything
// here just calls across.

// --- script execution (§2.5 S2) --------------------------------------
// `. file` / `source file`, and a `#!`-first file run by name, execute
// their lines in *this* shell process (racccoon can't re-exec the shell
// — it's embedded in the kernel image, not a /bin binary), so `cd` in a
// script sticks and `exit` would kill the interactive shell. To make
// `exit` behave, shell_run_script bumps g_shell_script_depth; the `exit`
// builtin, when that's non-zero, just sets g_shell_script_stop and the
// line loop unwinds instead of calling exit().
const int SH_SCRIPT_MAX = 8192;
int  g_shell_script_depth = 0;
bool g_shell_script_stop  = false;

// Read `path` and run it line by line. A leading `#!` line and any line
// whose first non-blank char is `#` are skipped (comments). argv[0..argc)
// become $1.., $#, $* for the duration (saved/restored around a nested
// source). Returns the status of the last line run.
fn int shell_run_script(char* path, char** argv, int argc)
{
    char[SH_SCRIPT_MAX] buf @noinit;
    int n = fs_read(path, &buf[0], SH_SCRIPT_MAX - 1);
    if (n < 0) {
        print("rc: cannot read ");
        print(path);
        print("\n");
        return 1;
    }
    buf[n] = 0;

    char[SH_PARG_LEN][SH_PARG_MAX] saved_pargs = g_shell_pargs;
    int  saved_pargc = g_shell_pargc;
    bool saved_stop  = g_shell_script_stop;

    g_shell_pargc = argc < SH_PARG_MAX ? argc : SH_PARG_MAX;
    for (int a = 0; a < g_shell_pargc; a++) {
        int k = 0;
        while (argv[a][k] != 0 && k < SH_PARG_LEN - 1) { g_shell_pargs[a][k] = argv[a][k]; k++; }
        g_shell_pargs[a][k] = 0;
    }

    g_shell_script_depth++;
    g_shell_script_stop = false;

    // Whole-buffer execution — shell_exec_block splits statements on
    // top-level `\n` / `;` and runs `if` / `for` / `while` constructs
    // (which may span lines) as units. The `#!` line and `#` comments
    // are skipped by shell_exec_stmt.
    int status = shell_exec_block(&buf[0]);

    g_shell_script_depth--;
    g_shell_pargs = saved_pargs;
    g_shell_pargc = saved_pargc;
    g_shell_script_stop = saved_stop;
    return status;
}

// True once every `'`/`"` is closed and `(`/`{` depth is back to 0 —
// i.e. `s` is a complete block, not a half-typed `if (...) {` (§2.5 S3
// multi-line prompt). Escapes are honoured; `{a,b}` brace expansion in
// a plain command counts toward depth too, but a plain command has no
// newline so the reader still returns it after one line.
fn bool shell_text_balanced(char* s)
{
    char q = 0;
    int paren = 0;
    int brace = 0;
    for (int i = 0; s[i] != 0; i++) {
        char c = s[i];
        if (q != 0) { if (c == q) { q = 0; } continue; }
        if (c == '\\' && s[i + 1] != 0) { i++; continue; }
        if (c == '\'' || c == '"') { q = c; continue; }
        if (c == '(') { paren++; }
        else if (c == ')') { if (paren > 0) { paren--; } }
        else if (c == '{') { brace++; }
        else if (c == '}') { if (brace > 0) { brace--; } }
    }
    return q == 0 && paren == 0 && brace == 0;
}

// Read a possibly-multi-line block: keep pulling lines (a `> `
// continuation prompt after the first) until the accumulated text is
// balanced. Returns its length, or -1 on overrun / read error.
fn int shell_read_block(char* buf, int cap)
{
    int len = 0;
    buf[0] = 0;
    for (;;) {
        char[256] line @noinit;
        int n = shell_readline(&line[0], 256);
        if (n < 0) { return -1; }
        if (len + n + 2 > cap) { print("shell: block too long\n"); return -1; }
        for (int k = 0; k < n; k++) { buf[len] = line[k]; len++; }
        buf[len] = '\n'; len++;
        buf[len] = 0;
        if (shell_text_balanced(&buf[0])) { return len; }
        print("> ");
    }
}

// The exec target the shell would use for `cmd` — mirrors shell_spawn:
// a name with a '/' is a path (absolute as-is, else cwd-relative via
// shell_resolve_path); a bare name is /bin/<cmd>. `out` >= 100 bytes.
fn void shell_exec_target(char* cmd, char* out)
{
    bool is_path = false;
    for (int i = 0; cmd[i] != 0; i++) { if (cmd[i] == '/') { is_path = true; break; } }
    if (is_path) {
        if (cmd[0] == '/') {
            int i = 0;
            while (cmd[i] != 0 && i < 99) { out[i] = cmd[i]; i++; }
            out[i] = 0;
        } else {
            shell_resolve_path(cmd, out);
        }
    } else {
        int o = 0;
        char* pfx = "/bin/";
        while (pfx[o] != 0) { out[o] = pfx[o]; o++; }
        int j = 0;
        while (cmd[j] != 0 && o < 99) { out[o] = cmd[j]; o++; j++; }
        out[o] = 0;
    }
}

fn void shell_refresh_user()
{
    g_shell_uid = getuid();
    user_name_by_uid(g_shell_uid, &g_shell_user[0], 32);
}

// Union `/usr/$user/bin` onto `/bin` (`bind -ac`), so a binary the user
// built into their own bin dir runs by bare name without `/bin` itself
// being writable — see docs/bin-layout.md. Idempotent-ish: a second
// call just adds another (identical) union member, so both shells call
// it exactly once at startup, after the user's identity is settled.
// The dir is seeded per user (scripts/build.sh, populate_duo_bin.sh);
// the bind still succeeds if it's missing, it just contributes nothing.
fn void shell_bind_user_bin()
{
    shell_refresh_user();
    if (g_shell_user[0] == 0) { return; }
    char[64] hb @noinit;
    int k = 0;
    char* pfx = "/usr/";
    while (pfx[k] != 0) { hb[k] = pfx[k]; k++; }
    for (int j = 0; g_shell_user[j] != 0 && k < 58; j++) { hb[k] = g_shell_user[j]; k++; }
    char* sfx = "/bin";
    for (int j = 0; sfx[j] != 0 && k < 62; j++) { hb[k] = sfx[j]; k++; }
    hb[k] = 0;
    // The physical /bin isn't a distinct mount — it's just "under root"
    // (prefix "", the shortest possible). A plain `bind X /bin` would
    // create a longer-prefix "/bin/" mount that shadows it entirely,
    // so establish an explicit "/bin/" -> /bin member first, then union
    // the user's dir after it.
    ns_bind_flags("/bin/", "/bin", 0);       // member 0: the real /bin
    ns_bind_flags("/bin/", &hb[0], 1 | 4);   // member 1: /usr/$user/bin, -a + -c (creates land here)
}

// Wait out the boot servers' init chatter, then tell the kernel to drop
// their console output (SYS_BOOT_QUIET). settle_ticks is a raw rdtime()
// delta — the caller picks it for its board's timebase (there's no
// board-agnostic "seconds" in user mode yet). Called once, before the
// first prompt.
fn void shell_boot_settle(ulong settle_ticks)
{
    ulong start = rdtime();
    while (rdtime() - start < settle_ticks) { yield(); }
    boot_quiet();
}

// The prompt — "<user> <cwd># " for root, "... % " otherwise (Plan 9's
// `%`). Both shells call this instead of a bare "> ".
fn void shell_prompt()
{
    shell_jobs_reap();   // report any background job that finished since last time
    if (g_shell_uid < 0) { shell_refresh_user(); }
    print(&g_shell_user[0]);
    putchar(' ');
    char[100] cw @noinit;
    int n = getcwd(&cw[0], 100);
    print(n > 0 ? &cw[0] : "/");
    print(g_shell_uid == 0 ? " # " : " % ");
}

// Resolve `arg` against the cwd (or take it absolute), collapse "." /
// ".." / "//", write an absolute path with no trailing slash ("" =
// root) into out (>= 100 bytes). Used by `cd`.
fn void shell_resolve_path(char* arg, char* out)
{
    char[100] raw @noinit;
    int r = 0;
    if (arg[0] == '/') {
        while (arg[r] != 0 && r < 99) { raw[r] = arg[r]; r++; }
    } else {
        int n = getcwd(&raw[0], 100);
        r = n > 0 ? n : 0;
        if (r < 99) { raw[r] = '/'; r++; }
        for (int i = 0; arg[i] != 0 && r < 99; i++) { raw[r] = arg[i]; r++; }
    }
    raw[r] = 0;

    int o = 0;
    int i = 0;
    while (raw[i] != 0) {
        while (raw[i] == '/') i++;
        if (raw[i] == 0) break;
        int s = i;
        while (raw[i] != 0 && raw[i] != '/') i++;
        int seglen = i - s;
        if (seglen == 1 && raw[s] == '.') { continue; }
        if (seglen == 2 && raw[s] == '.' && raw[s + 1] == '.') {
            while (o > 0 && out[o - 1] != '/') o--;
            if (o > 0) o--;
            continue;
        }
        if (o < 99) { out[o] = '/'; o++; }
        for (int k = s; k < i && o < 99; k++) { out[o] = raw[k]; o++; }
    }
    out[o] = 0;
}

// Read one console line into buf (cap includes the NUL). Both Backspace
// bytes (0x7F / 0x08) erase with a "\b \b"; every other byte is echoed;
// CR ends the line (a newline is printed). Returns the line length, or
// -1 if it overran cap-1 (caller discards and reprompts). Shared by
// shell.c3's command loop and shell_login() below — shell_test.c3 keeps
// its own inline copy (it has extra dev-only line handling).
fn int shell_readline(char* buf, int cap)
{
    int i = 0;
    for (;;) {
        char ch = (char)getchar();
        if (ch == 127 || ch == 8) {
            if (i > 0) { i--; print("\b \b"); }
            continue;
        }
        // A stray NUL (a UART framing error / line break shows up as one)
        // or a bare LF at the start of a line (the trailing half of a
        // CRLF the previous line's CR already consumed, or a double-tap)
        // must not become a one-character phantom command — swallow it,
        // no echo, no store.
        if (ch == 0 || (ch == '\n' && i == 0)) {
            continue;
        }
        putchar(ch);
        if (i == cap - 1) {
            print("\ncommand line too long\n");
            return -1;
        }
        // CR or LF ends the line — accept either so a CRLF terminal works
        // (its CR ends the command; the following LF then reads back here
        // as an empty line, which shell_exec_line treats as a no-op).
        if (ch == '\r' || ch == '\n') {
            print("\n");
            buf[i] = 0;
            return i;
        }
        buf[i] = ch;
        i++;
    }
}

// Absolutise `in` against the cwd and write it into `out` (>=
// NS_PREFIX_MAX bytes) with exactly one trailing '/' — the namespace
// prefix convention (src/process.c3's Mount). Bare `/` and the empty
// string both come out as "/", which resolves as a catch-all the same
// way the boot-time root mount's "" does. Used by the mount / bind /
// unmount builtins.
const int SH_NS_PREFIX_MAX = 32; // must match src/process.c3's NS_PREFIX_MAX
const int NS_LIST_RECS     = 16; // must match src/process.c3's NS_MOUNTS_MAX
const int NS_LIST_REC      = 100; // SYS_NS_LIST record size — must match entry.c3's NS_LIST_REC_SIZE
                                  // (32 prefix + 4 pid LE + 1 flags + 63 target)

fn void shell_ns_prefix(char* in, char* out)
{
    char[100] abs @noinit;
    shell_resolve_path(in, &abs[0]);   // "" for root, "/foo" otherwise, no trailing slash
    int k = 0;
    while (abs[k] != 0 && k < SH_NS_PREFIX_MAX - 2) { out[k] = abs[k]; k++; }
    out[k] = '/'; k++;
    out[k] = 0;
}

// One login attempt: look `name` up in /adm/users, drop to that uid, cd
// to its /usr/<name> home, refresh the cached user. Returns false (with
// a message) for an unknown name or a shell that already dropped
// privilege — setuid is one-way, so `exit` for a fresh root shell.
// Backs both the `login` builtin and shell.c3's startup prompt.
fn bool shell_login_once(char* name)
{
    int uid = user_uid_by_name(name);
    if (uid < 0) { print("login: no such user\n"); return false; }
    if (setuid(uid) < 0) {
        print("login: this shell already dropped privilege — exit and start over\n");
        return false;
    }
    shell_refresh_user();
    char[100] home @noinit;
    char* pfx = "/usr/";
    int h = 0;
    while (pfx[h] != 0) { home[h] = pfx[h]; h++; }
    for (int j = 0; name[j] != 0 && h < 99; j++) { home[h] = name[j]; h++; }
    home[h] = 0;
    char[100] dst @noinit;
    shell_resolve_path(&home[0], &dst[0]);
    uint lg_sz = 0;
    int  lg_ty = 0;
    if (dst[0] != 0 && fs_stat(&dst[0], &lg_sz, &lg_ty) == 0 && lg_ty != 0) { chdir(&dst[0]); }
    else { chdir(""); }
    return true;
}

// Startup login loop for shell.c3 — repeats until a valid /adm/users
// name is entered. `root` is always in /adm/users, so there's no way to
// lock yourself out.
fn void shell_login()
{
    // Wait for /adm/users to be readable before deciding whether to
    // prompt. On the Duo the SD driver + ext2 mount can still be
    // finishing when the shell starts — a one-shot read here would see
    // -1 and skip login on a perfectly good card. Retry for a bounded
    // window; a genuinely unprovisioned root partition still falls
    // through to a root console once it expires.
    char[8] probe @noinit;
    bool have_db = false;
    ulong deadline = rdtime() + 250000000; // ~10s at the Duo's 25MHz
    while (rdtime() < deadline) {
        if (fs_read("/adm/users", &probe[0], 8) >= 0) { have_db = true; break; }
        yield();
    }
    if (!have_db) { return; }

    for (;;) {
        print("login: ");
        char[64] nm @noinit;
        int n = shell_readline(&nm[0], 64);
        if (n <= 0) { continue; }
        if (shell_login_once(&nm[0])) { return; }
    }
}

// Dispatches the small set of real, end-user shell builtins shared by
// both the production shell (shell.c3) and the test shell
// (shell_test.c3) — hello/exit/mountusb/su/cd/login/mount/bind/…
// Returns true if cmd was one of these (and therefore handled); false
// means the caller should fall back to shell_exec_external() below.
fn bool shell_dispatch_common(char* cmd, char** cmd_argv, int cmd_argc)
{
        g_shell_status = 0; // a builtin that fails overrides this below
        if (strcmp(cmd, "hello") == 0) {
            print("Hello world from shell!\n");
            return true;
        } else if (strcmp(cmd, "echo") == 0) {
            for (int e = 0; e < cmd_argc; e++) {
                if (e > 0) { putchar(' '); }
                print(cmd_argv[e]);
            }
            putchar('\n');
            return true;
        } else if (strcmp(cmd, "su") == 0) {
            // Become another user. One-way (setuid only drops, never
            // elevates — Plan 9's "become none, never come back"); to
            // get root back, `exit` and let the kernel respawn a fresh
            // root shell.
            if (cmd_argc < 1) {
                print("usage: su <user>\n");
                return true;
            }
            int su_uid = user_uid_by_name(cmd_argv[0]);
            if (su_uid < 0) {
                print("su: no such user in /adm/users\n");
                g_shell_status = 1;
                return true;
            }
            if (setuid(su_uid) < 0) {
                print("su: denied (this shell already dropped privilege — exit and start over)\n");
                g_shell_status = 1;
                return true;
            }
            shell_refresh_user();
            return true;
        } else if (strcmp(cmd, "sandbox") == 0) {
            // sandbox <cmd> [args...] — run <cmd> in an rfork'd child
            // whose namespace has been trimmed down to just /bin/ (so it
            // can still exec tools) and whose uid has been dropped to
            // `none` (65534 — one-way, exactly like `su` above). The
            // parent shell's own namespace and uid are untouched, since
            // the child got its own copy at fork time, not a reference
            // (same reasoning as sandboxtest / mountusb).
            //
            // This is the Plan 9 "the namespace is the security
            // boundary, not the uid" stance (docs/roadmap.md §2) made
            // usable: the sandboxed command can run /bin binaries but
            // can't read a single data file (not even world-readable
            // ones — the root mount is gone), touch another process
            // (/proc gone), read or write env vars (/env gone), reach
            // the second disk (/mnt/fs2 gone) or the echo service
            // (/srv/echo gone); and as `none` it owns nothing, so it
            // can't write anywhere ext2 permission-checks. Generalises
            // shell_test.c3's own sandboxtest into a real, argv-taking
            // command.
            if (cmd_argc < 1) {
                print("usage: sandbox <cmd> [args...]\n");
                g_shell_status = 1;
                return true;
            }
            // `none` is uid 65534 by fixed convention (docs/roadmap.md
            // §2, and `/adm/users` seeds it as `65534:none`). Resolve
            // the name if the user db has it, but don't depend on the
            // db — a FAT32/exFAT root has no `/adm/users` at all, and a
            // sandbox that drops privilege + trims the namespace is
            // still worth having there.
            int sb_none = user_uid_by_name("none");
            if (sb_none < 0) { sb_none = 65534; }
            uint sb_gen = 0;
            int sb_r = rfork(RFPROC, &sb_gen);
            if (sb_r < 0) {
                print("sandbox: rfork failed (no free process slot)\n");
                g_shell_status = 1;
                return true;
            }
            if (sb_r == 0) {
                // Pin /bin/ (resolved now, while the root mount is still
                // here, to whatever serves it) so it survives dropping
                // the root catch-all; then strip every mount this
                // process inherited.
                ns_bind_flags("/bin/", "/bin", 0);
                ns_unmount("/srv/echo/");
                ns_unmount("/mnt/fs2/");
                ns_unmount("/proc/");
                ns_unmount("/env/");
                ns_unmount("");
                setuid(sb_none);

                // Same /bin/<name> vs. explicit-path handling as
                // shell_spawn.
                bool sb_is_path = false;
                for (int ci = 0; cmd_argv[0][ci] != 0; ci++) { if (cmd_argv[0][ci] == '/') { sb_is_path = true; break; } }
                char[100] sb_bin @noinit;
                char* sb_target = cmd_argv[0];
                if (!sb_is_path) {
                    int p = 0;
                    char* pfx = "/bin/";
                    while (pfx[p] != 0) { sb_bin[p] = pfx[p]; p++; }
                    int j = 0;
                    while (cmd_argv[0][j] != 0 && p < 99) { sb_bin[p] = cmd_argv[0][j]; p++; j++; }
                    sb_bin[p] = 0;
                    sb_target = &sb_bin;
                }
                exec(sb_target, exec_buf(), exec_buf_max(), 0, &cmd_argv[1], cmd_argc - 1);
                print("sandbox: ");
                print(cmd_argv[0]);
                print(": command not found (or unreadable in the sandbox)\n");
                exitcode(127);
            }
            g_shell_status = join(sb_r, sb_gen);
            return true;
        } else if (strcmp(cmd, "cd") == 0) {
            char[100] dst @noinit;
            if (cmd_argc < 1) {
                // home = /usr/<user>
                char[100] home @noinit;
                char* pfx = "/usr/";
                int h = 0;
                while (pfx[h] != 0) { home[h] = pfx[h]; h++; }
                for (int j = 0; g_shell_user[j] != 0 && h < 99; j++) { home[h] = g_shell_user[j]; h++; }
                home[h] = 0;
                shell_resolve_path(&home[0], &dst[0]);
            } else {
                shell_resolve_path(cmd_argv[0], &dst[0]);
            }
            // "" is root — always valid; otherwise it must be a real dir.
            if (dst[0] != 0) {
                uint cd_sz = 0;
                int cd_ty = 0;
                if (fs_stat(&dst[0], &cd_sz, &cd_ty) != 0) {
                    // `cd` with no arg to a home that doesn't exist yet
                    // (unprovisioned /usr) falls back to root rather
                    // than erroring.
                    if (cmd_argc < 1) { chdir(""); return true; }
                    print("cd: ");
                    print(&dst[0]);
                    print(": no such directory\n");
                    g_shell_status = 1;
                    return true;
                }
                if (cd_ty == 0) {
                    print("cd: not a directory\n");
                    g_shell_status = 1;
                    return true;
                }
            }
            chdir(&dst[0]);
            return true;
        } else if (strcmp(cmd, "pwd") == 0) {
            char[100] cw @noinit;
            int n = getcwd(&cw[0], 100);
            print(n > 0 ? &cw[0] : "/");
            print("\n");
            return true;
        } else if (strcmp(cmd, "exit") == 0) {
            // Inside a `. script` / `#!` run: unwind the script instead
            // of killing the (interactive) shell. `exit N` sets $status.
            if (g_shell_script_depth > 0) {
                if (cmd_argc >= 1 && cmd_argv[0][0] >= '0' && cmd_argv[0][0] <= '9') {
                    int ec = 0;
                    for (int k = 0; cmd_argv[0][k] >= '0' && cmd_argv[0][k] <= '9'; k++) {
                        ec = ec * 10 + (cmd_argv[0][k] - '0');
                    }
                    g_shell_status = ec;
                }
                g_shell_script_stop = true;
                return true;
            }
            exit();
        } else if (strcmp(cmd, ".") == 0 || strcmp(cmd, "source") == 0) {
            if (cmd_argc < 1) {
                print("usage: . <script> [args...]\n");
                g_shell_status = 1;
                return true;
            }
            char[100] scr @noinit;
            shell_exec_target(cmd_argv[0], &scr[0]);
            g_shell_status = shell_run_script(&scr[0], &cmd_argv[1], cmd_argc - 1);
            return true;
        } else if (strcmp(cmd, "mountusb") == 0) {
            // Idempotent: retires whatever a previous mountusb run left
            // behind (a successful mount, or a fsd that never found
            // anything and is just idling forever per its own comment
            // below) before probing again — see usbfs_teardown()'s own
            // comment above. Without this, every re-run (e.g. after
            // physically swapping the USB drive) leaked a whole fsd
            // process — with PROCS_MAX this small, only a handful of
            // re-runs would exhaust the process table entirely.
            usbfs_teardown();

            // Mounts whatever USB Mass Storage device is currently
            // attached at /mnt/usb/ — must be a real shell builtin,
            // not a separate /bin/mountusb exec()'d the ordinary way
            // (the first cut of this feature, tried and reverted): the
            // final ns_mount_wait() call below binds "/mnt/usb/" into
            // whatever process calls it, and rfork() only ever copies
            // a namespace from parent to child at the moment of the
            // call — never the other way, and never retroactively. A
            // separate mountusb.bin is itself just another rfork()'d+
            // exec()'d child of this shell (same as ls/cat below): it
            // would print "mounted" truthfully, then exit, taking that
            // mount right along with it — leaving the shell's own
            // namespace (and everything the shell rfork()s afterward,
            // e.g. `ls /mnt/usb/`) exactly as unmounted as before.
            // Confirmed the hard way on real hardware: fsd itself
            // mounted a real FAT32 filesystem correctly every time,
            // but `ls /mnt/usb/` kept reporting "not found" regardless
            // (see docs/devlog.md). Running this directly in the
            // shell's own long-lived process is what makes the mount
            // actually visible to commands typed afterward.
            //
            // Spawns a second, dynamically-configured fsd instance
            // (the exact same binary the boot-time fsd/fsd2 use,
            // user/fs/fsd.c3 — exec()'d here with an argv instead of
            // create_process()'d at boot) pointed at usbd itself
            // ("usbd" — the exact name usbd.c3's own main() already
            // srv_post()s under; its usb_msc_ipc_poll() responder is
            // diskd-compatible). That fsd instance runs forever, like
            // every other server in this system — not join()ed.
            char*[1] mountusb_fsd_argv;
            mountusb_fsd_argv[0] = "usbd";

            uint mountusb_gen = 0;
            int mountusb_child = rfork(RFPROC, &mountusb_gen);
            if (mountusb_child < 0) {
                print("mountusb: rfork failed (no free process slot)\n");
            } else if (mountusb_child == 0) {
                exec_path("fsd", exec_buf(), exec_buf_max(), 0, &mountusb_fsd_argv[0], 1);
                print("mountusb: failed to exec fsd\n");
                exit();
            } else if (ns_mount_wait("/mnt/usb/", "usbfs", (ulong)MOUNTUSB_WAIT_ATTEMPTS) < 0) {
                print("mountusb: no USB filesystem appeared — no drive attached, or nothing recognized on it\n");
                // Nothing to track — this fsd will never find anything
                // (usbd's own state hasn't changed since ns_mount_wait
                // gave up), so leaving it running would just be the
                // same leak this whole idempotency fix exists to close.
                kill(mountusb_child, mountusb_gen);
            } else {
                print("mountusb: mounted at /mnt/usb/\n");
            }
            return true;
        } else if (strcmp(cmd, "unmountusb") == 0) {
            uint um_matched_len = 0;
            int um_pid = ns_resolve("/mnt/usb/", &um_matched_len);
            if (um_pid <= 0 || um_matched_len != 9) {
                print("unmountusb: nothing mounted\n");
            } else {
                usbfs_teardown();
                print("unmountusb: unmounted\n");
            }
            return true;
        } else if (strcmp(cmd, "jobs") == 0) {
            shell_jobs_list();
            return true;
        } else if (strcmp(cmd, "wait") == 0) {
            shell_jobs_wait();
            return true;
        } else if (strcmp(cmd, "login") == 0) {
            if (cmd_argc < 1) {
                print("usage: login <user>\n");
                g_shell_status = 1;
                return true;
            }
            if (!shell_login_once(cmd_argv[0])) { g_shell_status = 1; }
            return true;
        } else if (strcmp(cmd, "namespace") == 0 || strcmp(cmd, "ns") == 0) {
            // The current process's mount table — this shell's own, the
            // one every command it spawns inherits a copy of.
            char[NS_LIST_RECS * NS_LIST_REC] nsb @noinit;
            int nc = ns_list(&nsb[0], NS_LIST_RECS);
            if (nc < 0) {
                print("namespace: failed\n");
                g_shell_status = 1;
                return true;
            }
            for (int e = 0; e < nc; e++) {
                char* rec = &nsb[e * NS_LIST_REC];
                uint pid = ((uint)rec[32] & 0xff)
                         | (((uint)rec[33] & 0xff) << 8)
                         | (((uint)rec[34] & 0xff) << 16)
                         | (((uint)rec[35] & 0xff) << 24);
                uint flags = (uint)rec[36] & 0xff;
                char* tgt = &rec[37];
                print(rec[0] != 0 ? rec : "/");
                print("\t-> pid ");
                print_uint(pid);
                if (tgt[0] != 0) { print(" = "); print(tgt); }
                if ((flags & 1) != 0) { print(" (create)"); }
                putchar('\n');
            }
            return true;
        } else if (strcmp(cmd, "mount") == 0) {
            // mount <srv> <dir> — bind a posted server (srv_post name,
            // e.g. the ones from `srvtest` or a hand-spawned fsd) into
            // this shell's namespace. Must be a builtin: a namespace
            // change only ever flows parent -> child at spawn time, so a
            // separate /bin/mount would bind the mount into its own
            // throwaway process and take it right back on exit (the same
            // reason mountusb is a builtin — see its comment above).
            if (cmd_argc < 2) {
                print("usage: mount <srv> <dir>\n");
                g_shell_status = 1;
                return true;
            }
            char[SH_NS_PREFIX_MAX] mp @noinit;
            shell_ns_prefix(cmd_argv[1], &mp[0]);
            if (ns_mount(&mp[0], cmd_argv[0]) < 0) {
                print("mount: ");
                print(cmd_argv[0]);
                print(": no server posted under that name\n");
                g_shell_status = 1;
            }
            return true;
        } else if (strcmp(cmd, "bind") == 0) {
            // bind [-a] [-c] <source> <dir> — make <dir> resolve to
            // whatever currently serves <source>. -a: add as a union
            // member (searched after the existing ones) instead of
            // replacing. -c: this member receives creation. Builtin for
            // the same reason as mount above.
            uint bflags = 0;
            int bi = 0;
            while (bi < cmd_argc && cmd_argv[bi][0] == '-' && cmd_argv[bi][1] != 0) {
                for (int bk = 1; cmd_argv[bi][bk] != 0; bk++) {
                    if (cmd_argv[bi][bk] == 'a') { bflags |= 1; }
                    if (cmd_argv[bi][bk] == 'c') { bflags |= 4; }
                }
                bi++;
            }
            if (cmd_argc - bi < 2) {
                print("usage: bind [-a] [-c] <source> <dir>\n");
                g_shell_status = 1;
                return true;
            }
            char[SH_NS_PREFIX_MAX] bp @noinit;
            shell_ns_prefix(cmd_argv[bi + 1], &bp[0]);
            char[100] bsrc @noinit;
            shell_resolve_path(cmd_argv[bi], &bsrc[0]);
            if (ns_bind_flags(&bp[0], bsrc[0] != 0 ? &bsrc[0] : "/", bflags) < 0) {
                print("bind: ");
                print(cmd_argv[bi]);
                print(": resolves nowhere, or the namespace is full\n");
                g_shell_status = 1;
            }
            return true;
        } else if (strcmp(cmd, "unmount") == 0 || strcmp(cmd, "umount") == 0) {
            if (cmd_argc < 1) {
                print("usage: unmount <dir>\n");
                g_shell_status = 1;
                return true;
            }
            char[SH_NS_PREFIX_MAX] up @noinit;
            shell_ns_prefix(cmd_argv[0], &up[0]);
            if (ns_unmount(&up[0]) < 0) {
                print("unmount: ");
                print(&up[0]);
                print(": not mounted\n");
                g_shell_status = 1;
            }
            return true;
        }
    return false;
}

// rfork + exec a /bin/<cmd>, returning the child pid (its generation in
// *gen_out for a later join()) WITHOUT waiting. The child that fails to
// exec prints "<cmd>: command not found" and exits 127 (the shell reads
// that back through join() for `&&` / `||`). -1 = rfork failed.
// Split out of shell_exec_external so shell_run_pipeline can start
// several children, wire their pipe ends, then join them all.
// stdout_pipe / stdin_pipe (-1 = console): wired into the child
// atomically by rfork_io — a follow-up SYS_PIPE_SETOUT/SETIN loses a
// race to a timer-preempted shell (the child can run, and exit, in the
// window between the fork and the second call).
fn int shell_spawn(char* cmd, char** cmd_argv, int cmd_argc, uint* gen_out, int stdout_pipe, int stdin_pipe)
{
            // A command with a '/' in it (absolute "/bin/foo", or
            // relative "./foo" / "sub/foo") is a path — exec() resolves
            // it, cwd-relative if it doesn't start with '/'. A bare name
            // ("ls") is looked up under /bin/, as before.
            bool cmd_is_path = false;
            for (int ci = 0; cmd[ci] != 0; ci++) { if (cmd[ci] == '/') { cmd_is_path = true; break; } }

            char[100] bin_path @noinit;
            char* exec_target = cmd;
            if (!cmd_is_path) {
                int bp_i = 0;
                char* prefix = "/bin/";
                while (prefix[bp_i] != 0) { bin_path[bp_i] = prefix[bp_i]; bp_i++; }
                int bp_j = 0;
                while (cmd[bp_j] != 0 && bp_i < 99) { bin_path[bp_i] = cmd[bp_j]; bp_i++; bp_j++; }
                bin_path[bp_i] = 0;
                exec_target = &bin_path;
            }

            *gen_out = 0;
            int sh_r = rfork_io(RFPROC, gen_out, stdout_pipe, stdin_pipe);
            if (sh_r < 0) {
                print("rfork failed\n");
                return -1;
            }
            if (sh_r == 0) {
                exec(exec_target, exec_buf(), exec_buf_max(), 0, cmd_argv, cmd_argc);
                print(cmd);
                print(": command not found\n");
                exitcode(127);
            }
            return sh_r;
}

// Builtins that are safe to run as a pipeline stage: they only produce
// output and touch no shell-process state, so running one in a forked
// child (which is what a pipeline stage is) still does the right thing.
// `cd` / `su` / `login` / `mount` / `bind` / `exit` / `mountusb` are
// deliberately absent — their whole point is a side effect on the
// shell's own long-lived process, which a child can't deliver; in a
// pipeline they fall through to the /bin path and 127 like any unknown
// command. `echo` / `whoami` aren't here either: they already have real
// /bin binaries that the pipeline path picks up.
fn bool shell_builtin_pipeable(char* cmd)
{
    return strcmp(cmd, "pwd") == 0
        || strcmp(cmd, "hello") == 0
        || strcmp(cmd, "namespace") == 0
        || strcmp(cmd, "ns") == 0;
}

// One pipeline stage. A pipeable builtin (above) runs in a forked child
// whose stdout the caller has already wired to the stage's pipe —
// shell_dispatch_common does the actual work, exactly as for a plain
// command, just in a child that then exits. Everything else is an
// ordinary /bin spawn. Returns the child pid (generation in *gen_out),
// or -1 on rfork failure — same contract as shell_spawn.
fn int shell_spawn_stage(char* cmd, char** cmd_argv, int cmd_argc, uint* gen_out, int stdout_pipe, int stdin_pipe)
{
    if (!shell_builtin_pipeable(cmd)) {
        return shell_spawn(cmd, cmd_argv, cmd_argc, gen_out, stdout_pipe, stdin_pipe);
    }
    *gen_out = 0;
    int r = rfork_io(RFPROC, gen_out, stdout_pipe, stdin_pipe);
    if (r < 0) { print("rfork failed\n"); return -1; }
    if (r == 0) {
        shell_dispatch_common(cmd, cmd_argv, cmd_argc);
        exit();
    }
    return r;
}

// The /bin/<cmd> fallback — also shared by both shells (see
// shell_dispatch_common's own comment above for why). Returns the
// command's exit status (127 if it couldn't be spawned).
fn int shell_exec_external(char* cmd, char** cmd_argv, int cmd_argc)
{
            // A `#!` script run by name: racccoon's exec() loads a flat /
            // ELF image and would fault on shell text, so interpret it in
            // this shell instead (§2.5 S2). Peek the first two bytes of
            // whatever exec would have run.
            char[100] xt @noinit;
            shell_exec_target(cmd, &xt[0]);
            char[2] magic @noinit;
            if (fs_read(&xt[0], &magic[0], 2) == 2 && magic[0] == '#' && magic[1] == '!') {
                return shell_run_script(&xt[0], cmd_argv, cmd_argc);
            }

            uint sh_gen = 0;
            int sh_r = shell_spawn(cmd, cmd_argv, cmd_argc, &sh_gen, -1, -1);
            if (sh_r <= 0) { return 127; }
            return join(sh_r, sh_gen);
}

// One pipeline — a chain of commands joined by `|` (up to MAX_STAGES),
// optionally with `<` on the first stage and `>` / `>>` on the last
// (each operator its own space-separated token; quoted, e.g.
// `echo '|'`, they're literal). `seg` is the raw segment text
// (shell_exec_line has already split off `;` / `&&` / `||`); it's
// `$var`-expanded quote-aware and tokenised here, right before it runs.
// With no `|`/redirection it's the plain
// `shell_dispatch_common() || shell_exec_external()` path, builtins and
// all. A pipeline stage is normally an external /bin binary; the
// output-only builtins (`pwd` / `hello` / `namespace`, see
// shell_builtin_pipeable) also work as stages, run in a forked child.
// `< file` is capped at the kernel pipe buffer (PIPE_BUF, src/pipe.c3).
// A word carrying an unquoted `{a,b,...}` is brace-expanded first
// (`x.{c3,md}` -> `x.c3 x.md`, cartesian across multiple groups); then
// any word with an unquoted `*` / `?` is glob-expanded against the
// filesystem (last path component only), a no-match pattern staying
// literal (rc's rule).
// Returns the exit status of the last stage (0 = success); a shell-side
// error (bad syntax, unterminated quote, unopenable redirection) is 2.
//
// `bg` (from a trailing `&`) spawns the stages and returns 0 without
// waiting — the job goes into g_jobs, reaped at the next prompt. A
// background job can't use `<` / `>` / `>>` (the shell pumps those
// itself, which would block). An output-only builtin still works
// backgrounded (it runs in the forked stage child); a side-effecting
// one (`cd`, `su`, …) hits the /bin path and 127s.
fn int shell_run_pipeline(char* seg, int seg_len, bool bg)
{
    char[256] raw @noinit;
    int rn = seg_len < 255 ? seg_len : 255;
    for (int k = 0; k < rn; k++) { raw[k] = seg[k]; }
    raw[rn] = 0;

    char[512] exp @noinit;
    char[512] qm  @noinit;
    if (shell_expand_q(&raw[0], &exp[0], &qm[0], 512) < 0) {
        print("shell: unterminated quote\n");
        return 2;
    }

    // Tokenise on unquoted whitespace. A token is an operator only if
    // it's an unquoted, bare `|` / `<` / `>` / `>>`.
    const int PL_MAX_TOKENS = 20;
    char*[PL_MAX_TOKENS] tokens   @noinit;
    bool[PL_MAX_TOKENS]  tok_op   @noinit;
    bool[PL_MAX_TOKENS]  tok_glob @noinit;   // token has an unquoted * or ?
    int nt = 0;
    int ti = 0;
    while (exp[ti] != 0 && nt < PL_MAX_TOKENS) {
        while (exp[ti] == ' ' && qm[ti] == 0) { ti++; }
        if (exp[ti] == 0) { break; }
        int ts = ti;
        tokens[nt] = &exp[ti];
        while (exp[ti] != 0 && !(exp[ti] == ' ' && qm[ti] == 0)) { ti++; }
        int te = ti;
        if (exp[ti] == ' ') { exp[ti] = 0; ti++; }
        char* t = tokens[nt];
        tok_op[nt] = qm[ts] == 0 &&
            ((t[0] == '|' && t[1] == 0) ||
             (t[0] == '<' && t[1] == 0) ||
             (t[0] == '>' && t[1] == 0) ||
             (t[0] == '>' && t[1] == '>' && t[2] == 0));
        bool tg = false;
        for (int q = ts; q < te; q++) {
            if (qm[q] == 0 && (exp[q] == '*' || exp[q] == '?')) { tg = true; }
        }
        tok_glob[nt] = tg && !tok_op[nt];
        nt++;
    }
    if (nt == 0) { return 0; }

    // Split the tokens into pipeline stages on `|`, collecting each
    // stage's argv plus the (first-stage-only) `<` and (last-stage-only)
    // `>` / `>>` targets. `stage_words` is flat storage; stage s's argv
    // is stage_words[stage_off[s] ..] with element 0 the command name.
    const int MAX_STAGES = 6;
    const int STAGE_WORDS_MAX = MAX_STAGES * 12;   // headroom for glob expansion
    char*[STAGE_WORDS_MAX] stage_words @noinit;
    int[MAX_STAGES] stage_off @noinit;
    int[MAX_STAGES] stage_n   @noinit;

    // Packed storage for glob-expanded path strings — stage_words[] holds
    // pointers into here, so it has to outlive the spawn loop below (it
    // does: same function scope).
    const int GLOB_NAMES_BUF = 2048;
    char[GLOB_NAMES_BUF] glob_names @noinit;
    int gnb = 0;

    // Same deal for brace-expanded words (only tokens that contain a
    // brace are copied in here — plain words keep pointing into `exp`).
    char[BRACE_BUF] brace_buf @noinit;
    int bbo = 0;

    int nstages = 1;
    int sw = 0;
    stage_off[0] = 0; stage_n[0] = 0;
    char* infile   = null;
    char* outfile  = null;
    bool  append   = false;
    int   gt_stage = -1;   // which stage carried `>` (must be the last one)
    bool  bad      = false;

    for (int i = 0; i < nt; i++) {
        char* t = tokens[i];
        if (tok_op[i] && t[0] == '|') {
            if (nstages >= MAX_STAGES) { print("shell: pipeline too long\n"); return 2; }
            stage_off[nstages] = sw;
            stage_n[nstages] = 0;
            nstages++;
            continue;
        }
        if (tok_op[i]) {   // < > >>
            if (i + 1 >= nt || tok_op[i + 1]) { bad = true; break; }
            char* target = tokens[i + 1];
            i++;
            if (t[0] == '<') {
                if (nstages != 1) { print("shell: `<` redirect only on the first pipeline stage\n"); return 2; }
                infile = target;
            } else {
                outfile = target; append = t[1] == '>'; gt_stage = nstages - 1;
            }
            continue;
        }
        // A word: brace-expand it if it carries an unquoted `{`, then
        // glob each result. A plain word skips both and points straight
        // into `exp`.
        int toff = (int)(t - &exp[0]);
        bool has_brace = false;
        for (int q = 0; t[q] != 0; q++) {
            if (t[q] == '{' && qm[toff + q] == 0) { has_brace = true; break; }
        }
        char*[BRACE_MAX] bres @noinit;
        int bn = 1;
        bres[0] = t;
        if (has_brace) {
            int brn = 0;
            shell_brace_expand(t, &qm[toff], &brace_buf[0], &bbo, BRACE_BUF, &bres[0], &brn, BRACE_MAX);
            bn = brn;
            if (bn == 0) { bres[0] = t; bn = 1; }   // buffer full -> literal
        }

        for (int b = 0; b < bn; b++) {
            char* w = bres[b];
            if (tok_glob[i]) {
                int gm = shell_glob_into(w, &glob_names[0], &gnb, GLOB_NAMES_BUF,
                                         &stage_words[0], &sw, STAGE_WORDS_MAX);
                stage_n[nstages - 1] += gm;
                // rc: a pattern that matches nothing stands as a literal word.
                if (gm == 0 && sw < STAGE_WORDS_MAX) { stage_words[sw] = w; sw++; stage_n[nstages - 1]++; }
            } else if (sw < STAGE_WORDS_MAX) {
                stage_words[sw] = w; sw++; stage_n[nstages - 1]++;
            }
        }
    }

    for (int s = 0; s < nstages; s++) { if (stage_n[s] == 0) { bad = true; } }
    if (bad) { print("shell: malformed pipeline\n"); return 2; }
    if (outfile != null && gt_stage != nstages - 1) {
        print("shell: `>` redirect only on the last pipeline stage\n");
        return 2;
    }
    if (bg && (infile != null || outfile != null)) {
        print("shell: a background job can't use < / > / >>\n");
        return 2;
    }

    // No pipe, no redirection: the plain path, builtins included.
    // (Skipped for `&` — a backgrounded command always goes through the
    // spawn loop below, even a single one, so it gets a real child pid.)
    if (!bg && nstages == 1 && infile == null && outfile == null) {
        char* c0 = stage_words[0];
        if (shell_dispatch_common(c0, &stage_words[1], stage_n[0] - 1)) {
            return g_shell_status;
        }
        return shell_exec_external(c0, &stage_words[1], stage_n[0] - 1);
    }

    // `< file`: read it up front (bounded at one kernel pipe buffer)
    // into a buffer that outlives the whole pipeline.
    char[PIPE_FILE_MAX] infbuf @noinit;
    int inflen = 0;
    if (infile != null) {
        inflen = fs_read(infile, &infbuf[0], PIPE_FILE_MAX);
        if (inflen < 0) {
            print("shell: "); print(infile); print(": cannot open\n");
            return 2;
        }
    }

    // Allocate every pipe first: nstages-1 inter-stage pipes, plus
    // in_pipe (`<`) and out_pipe (`>`). On exhaustion, free what we got
    // (pipe_hold +1 then -1 — the -1 detach runs pipe_free_if_idle) and
    // bail before spawning anything.
    int[MAX_STAGES] mpipe @noinit;
    int nmp = nstages - 1;
    int in_pipe  = -1;
    int out_pipe = -1;
    bool pipe_fail = false;
    for (int s = 0; s < nmp; s++) {
        mpipe[s] = pipe_new();
        if (mpipe[s] < 0) { pipe_fail = true; nmp = s; break; }
    }
    if (!pipe_fail && infile  != null) { in_pipe  = pipe_new(); if (in_pipe  < 0) { pipe_fail = true; } }
    if (!pipe_fail && outfile != null) { out_pipe = pipe_new(); if (out_pipe < 0) { pipe_fail = true; } }
    if (pipe_fail) {
        for (int s = 0; s < nmp; s++) { pipe_hold(mpipe[s], 0, 1); pipe_hold(mpipe[s], 0, -1); }
        if (in_pipe >= 0) { pipe_hold(in_pipe, 0, 1); pipe_hold(in_pipe, 0, -1); }
        print("shell: out of pipes\n");
        return 2;
    }
    if (in_pipe  >= 0) { pipe_hold(in_pipe, 1, 1); }   // shell writes the file in
    if (out_pipe >= 0) { pipe_hold(out_pipe, 0, 1); }  // shell drains it to the file

    // Spawn every stage with its pipe ends already wired *atomically by
    // the fork* (rfork_io / SYS_RFORK a2+a4). The old code did an
    // rfork then a separate SYS_PIPE_SETOUT/SETIN, on the assumption
    // the shell is never preempted in between — but the timer can fire
    // in that window, letting a fast child (`/bin/echo`) run and exit
    // before its output was ever redirected. On a spawn failure, kill
    // what started and bail.
    int[MAX_STAGES]  spid @noinit;
    uint[MAX_STAGES] sgen @noinit;
    int spawned = 0;
    for (int s = 0; s < nstages; s++) {
        char** argv = &stage_words[stage_off[s] + 1];
        int    argc = stage_n[s] - 1;
        int stdin_p  = s == 0           ? in_pipe  : mpipe[s - 1];
        int stdout_p = s == nstages - 1 ? out_pipe : mpipe[s];
        spid[s] = shell_spawn_stage(stage_words[stage_off[s]], argv, argc, &sgen[s], stdout_p, stdin_p);
        if (spid[s] < 0) {
            for (int k = 0; k < spawned; k++) { kill(spid[k], sgen[k]); }
            if (in_pipe  >= 0) { pipe_hold(in_pipe, 1, -1); }
            if (out_pipe >= 0) { pipe_hold(out_pipe, 0, -1); }
            return 2;
        }
        spawned++;
    }

    // Background: hand the whole pipeline to the job table and return
    // now. The inter-stage pipes need no shell-side hold — each child
    // holds its own ends and they free themselves once the last stage
    // exits (in_pipe / out_pipe are always -1 here: redirection was
    // rejected above).
    if (bg) {
        shell_job_add(&spid[0], &sgen[0], nstages, seg, seg_len);
        return 0;
    }

    // Feed `< file`, then drop our writer so stage 0 sees EOF once it
    // has drained the buffer.
    if (in_pipe >= 0) {
        if (inflen > 0) { pipe_write(in_pipe, &infbuf[0], inflen); }
        pipe_hold(in_pipe, 1, -1);
    }

    // Pump `>` / `>>`: stream the last stage's stdout to the file.
    bool redir_failed = false;
    if (out_pipe >= 0) {
        uint off = 0;
        if (append) {
            uint st_sz = 0; int st_ty = 0;
            if (fs_stat(outfile, &st_sz, &st_ty) == 0) { off = st_sz; }
        } else {
            char[1] empty @noinit;
            fs_write(outfile, &empty[0], 0);   // truncate / create
        }
        char[512] chunk @noinit;
        for (;;) {
            int got = pipe_read(out_pipe, &chunk[0], 512);
            if (got <= 0) { break; }
            int w = fs_write_at(outfile, &chunk[0], got, off);
            if (w < 0) { print("shell: "); print(outfile); print(": write failed\n"); redir_failed = true; break; }
            off += (uint)w;
        }
        pipe_hold(out_pipe, 0, -1);
    }

    // Join in order; the pipeline's status is the last stage's.
    int last_status = 0;
    for (int s = 0; s < nstages; s++) {
        int st = join(spid[s], sgen[s]);
        if (s == nstages - 1) { last_status = st; }
    }
    return redir_failed ? 3 : last_status;
}

// Which sequencing operator (if any) starts at line[p]: 1 = ` ; `,
// 2 = ` && `, 3 = ` || `, 4 = ` & ` (background), 0 = none. *op_len
// gets the operator's byte length including its surrounding spaces. A
// trailing ` ;` / ` &&` / ` ||` / ` &` at the very end of the line
// counts too (no space after).
fn int sh_seq_op_at(char* line, int p, int* op_len)
{
    if (line[p] != ' ') { return 0; }
    char a = line[p + 1];
    if (a == ';') {
        if (line[p + 2] == ' ') { *op_len = 3; return 1; }
        if (line[p + 2] == 0)   { *op_len = 2; return 1; }
        return 0;
    }
    if ((a == '&' && line[p + 2] == '&') || (a == '|' && line[p + 2] == '|')) {
        int kind = a == '&' ? 2 : 3;
        if (line[p + 3] == ' ') { *op_len = 4; return kind; }
        if (line[p + 3] == 0)   { *op_len = 3; return kind; }
    }
    if (a == '&' && line[p + 2] != '&') {   // single `&` — background
        if (line[p + 2] == ' ') { *op_len = 3; return 4; }
        if (line[p + 2] == 0)   { *op_len = 2; return 4; }
    }
    return 0;
}

// A whole entered line: one or more pipelines joined by ` ; `, ` && `,
// ` || ` (space-surrounded — `a;b` is not split; a quoted `';'` is
// literal). Left-associative, all three at one precedence level
// (simpler than sh's split levels, and predictable): `a && b || c`
// runs c only if the `a && b` result was non-zero. `;` always runs the
// next pipeline; `&&` only after success (status 0); `||` only after
// failure. Each pipeline is quote-aware `$var`-expanded and tokenised
// on its own, right before it runs — so `$status` inside a sequenced
// line reflects the pipeline just before it. Returns the last
// pipeline's status; also left in g_shell_status for `$status`.
fn int shell_exec_line(char* line)
{
    int status = 0;
    int conn = 0;       // 0 = first (always run), 1 = `;`, 2 = `&&`, 3 = `||`, 4 = `&`
    int seg_start = 0;
    int p = 0;
    char quote = 0;     // 0, '\'' or '"' — a sequencing op inside a quote is literal

    for (;;) {
        char c = line[p];
        // A backslash escape spans two bytes and neither is ever a
        // quote toggle or a sequencing operator — skip the pair whole
        // (outside single quotes; inside '...' a backslash is literal).
        if (c == '\\' && line[p + 1] != 0 && quote != '\'') { p += 2; continue; }
        if (c != 0 && quote == 0 && (c == '\'' || c == '"')) { quote = c; p++; continue; }
        if (c != 0 && quote != 0 && c == quote)              { quote = 0; p++; continue; }

        int op_len = 0;
        int op = c == 0 ? -1 : (quote != 0 ? 0 : sh_seq_op_at(line, p, &op_len));
        if (op == 0) { p++; continue; }   // ordinary char, keep scanning

        // op == -1 (end of line) or op >= 1 (a sequencing operator): the
        // run [seg_start, p) is one pipeline.
        int seg_len = p - seg_start;
        bool run = conn == 0
                || conn == 1
                || conn == 4
                || (conn == 2 && status == 0)
                || (conn == 3 && status != 0);

        // Trim leading spaces of the raw segment for the emptiness check.
        int s = seg_start;
        while (s < p && line[s] == ' ') { s++; }

        if (s < p && run) {
            // op == 4 -> this segment is `cmd &`: spawn and don't wait.
            status = shell_run_pipeline(&line[seg_start], seg_len, op == 4);
            g_shell_status = status;   // visible to the next segment's $status
        } else if (s >= p && op >= 1) {
            print("shell: empty command near a ; && || & operator\n");
            status = 2;
            g_shell_status = status;
        }

        if (op < 0) { break; }
        conn = op;
        p += op_len;
        seg_start = p;
    }

    g_shell_status = status;
    return status;
}

// ====================================================================
// Control flow (§2.5 S3+): `if (COND) BODY [else BODY]`, plus
// `NAME=value` shell-local assignment. `for` / `while` land in S4.
//
// shell_exec_block() is the new top layer: it splits a block of shell
// text — which may span newlines / `;` and contain `{ }` groups — into
// statements and runs each. A plain statement goes to shell_exec_line()
// (the `;`/`&&`/`||` + pipeline machinery, unchanged). A control
// construct is handled here. The interactive prompt (shell.c3) and
// shell_run_script() both call shell_exec_block now.
//
// Everything parses in place: the caller's buffer is writable (readline
// / script buffer), so a statement is run by temporarily NUL-ing its
// end byte rather than copied out — no big per-recursion stack buffer.
// ====================================================================

// break/continue for S4's loops — the block loop checks these.
bool g_shell_loop_break    = false;
bool g_shell_loop_continue = false;

fn int sh_strlen(char* s)
{
    int i = 0;
    while (s[i] != 0) { i++; }
    return i;
}

fn int sh_skip_ws(char* s, int i)
{
    while (s[i] == ' ' || s[i] == '\t' || s[i] == '\n') { i++; }
    return i;
}

// s[i] is `(` or `{`. Index just past the matching close (quote- and
// backslash-aware), or -1 if it never closes.
fn int sh_span_group(char* s, int i)
{
    char open = s[i];
    char close = open == '(' ? ')' : '}';
    int depth = 0;
    char q = 0;
    for (; s[i] != 0; i++) {
        char c = s[i];
        if (q != 0) { if (c == q) { q = 0; } continue; }
        if (c == '\'' || c == '"') { q = c; continue; }
        if (c == '\\' && s[i + 1] != 0) { i++; continue; }
        if (c == open) { depth++; }
        else if (c == close) { depth--; if (depth == 0) { return i + 1; } }
    }
    return -1;
}

// End of a plain statement: the first top-level (not quoted, not
// escaped) `\n` or `;`, or the NUL.
fn int sh_plain_end(char* s, int start)
{
    char q = 0;
    for (int i = start; s[i] != 0; i++) {
        char c = s[i];
        if (q != 0) { if (c == q) { q = 0; } continue; }
        if (c == '\'' || c == '"') { q = c; continue; }
        if (c == '\\' && s[i + 1] != 0) { i++; continue; }
        if (c == '\n' || c == ';') { return i; }
    }
    return sh_strlen(s);
}

// Is `s` (starting at a non-ws char) the keyword `kw` used as a
// statement head — i.e. followed by whitespace, `(`, or end?
fn bool sh_kw_head(char* s, char* kw)
{
    int i = 0;
    while (kw[i] != 0) { if (s[i] != kw[i]) { return false; } i++; }
    char after = s[i];
    return after == 0 || after == ' ' || after == '\t' || after == '\n' || after == '(';
}

// `NAME=...` as a whole one-word statement (no space before `=`, name is
// [A-Za-z_][A-Za-z0-9_]*). `x = 5` (spaces) is a command, not this.
fn bool sh_is_assign(char* s)
{
    if (!sh_name_start(s[0])) { return false; }
    int i = 1;
    while (sh_name_char(s[i])) { i++; }
    return s[i] == '=';
}

fn int sh_do_assign(char* s)
{
    char[SH_VNAME_MAX] name @noinit;
    int n = 0;
    while (sh_name_char(s[n]) && n < SH_VNAME_MAX - 1) { name[n] = s[n]; n++; }
    name[n] = 0;
    // s[n] == '='
    char[SH_VVAL_MAX] val @noinit;
    shell_expand(&s[n + 1], &val[0], SH_VVAL_MAX);
    shell_local_set(&name[0], &val[0]);
    g_shell_status = 0;
    return 0;
}

// Run the body starting at s[at] (already ws-skipped): a `{ ... }` group
// (its inner text is run as a block) or a single bare statement. `*after`
// is set to the index just past the body. `run` = actually execute
// (false = just skip past it — for the not-taken branch of an `if`).
fn int sh_run_body(char* s, int at, bool run, int* after)
{
    if (s[at] == '{') {
        int past = sh_span_group(s, at);
        if (past < 0) {
            print("rc: unbalanced { }\n");
            *after = sh_strlen(s);
            g_shell_status = 2;
            return 2;
        }
        *after = past;
        if (!run) { return g_shell_status; }
        char save = s[past - 1];      // the '}'
        s[past - 1] = 0;
        int st = shell_exec_block(&s[at + 1]);
        s[past - 1] = save;
        return st;
    }
    // bare statement
    int end = sh_stmt_end(s, at);
    *after = end;
    if (!run) { return g_shell_status; }
    char save = s[end];
    s[end] = 0;
    int st = shell_exec_stmt(&s[at]);
    s[end] = save;
    return st;
}

// End index of one statement beginning at s[start] (ws already at
// start). A control construct swallows its `( )` and body (and, for
// `if`, a trailing `else` + body); a plain statement ends at sh_plain_end.
fn int sh_stmt_end(char* s, int start)
{
    if (sh_kw_head(&s[start], "if")) {
        int i = start + 2;
        i = sh_skip_ws(s, i);
        if (s[i] != '(') { return sh_plain_end(s, start); }
        int past_cond = sh_span_group(s, i);
        if (past_cond < 0) { return sh_plain_end(s, start); }
        i = sh_skip_ws(s, past_cond);
        int after = 0;
        sh_run_body(s, i, false, &after);
        int j = sh_skip_ws(s, after);
        if (sh_kw_head(&s[j], "else")) {
            j = sh_skip_ws(s, j + 4);
            sh_run_body(s, j, false, &after);
        }
        return after;
    }
    return sh_plain_end(s, start);
}

fn int shell_do_if(char* s)
{
    int i = sh_skip_ws(s, 2);              // past "if"
    if (s[i] != '(') { print("rc: if: expected `(`\n"); g_shell_status = 2; return 2; }
    int past_cond = sh_span_group(s, i);
    if (past_cond < 0) { print("rc: if: unbalanced `( )`\n"); g_shell_status = 2; return 2; }

    int cond_close = past_cond - 1;        // the ')'
    char save = s[cond_close];
    s[cond_close] = 0;
    int cstatus = shell_exec_line(&s[i + 1]);
    s[cond_close] = save;

    int body_at = sh_skip_ws(s, past_cond);
    int after = 0;
    int st = sh_run_body(s, body_at, cstatus == 0, &after);

    int j = sh_skip_ws(s, after);
    if (sh_kw_head(&s[j], "else")) {
        j = sh_skip_ws(s, j + 4);
        st = sh_run_body(s, j, cstatus != 0, &after);
    } else if (cstatus == 0) {
        // no else, condition true -> `st` already holds the body status
    } else {
        st = 0;                            // `if` with a false cond, no else -> success
    }
    g_shell_status = st;
    return st;
}

// One statement, already isolated (NUL-terminated) and ws-trimmed at the
// front by the caller.
fn int shell_exec_stmt(char* s)
{
    int i = sh_skip_ws(s, 0);
    if (s[i] == 0 || s[i] == '#') { return g_shell_status; }   // blank / comment
    if (sh_kw_head(&s[i], "if"))    { return shell_do_if(&s[i]); }
    if (sh_kw_head(&s[i], "for") || sh_kw_head(&s[i], "while")) {
        print("rc: for/while not implemented yet (S4)\n");
        g_shell_status = 2;
        return 2;
    }
    if (sh_is_assign(&s[i]))        { return sh_do_assign(&s[i]); }
    return shell_exec_line(&s[i]);
}

// Split `text` (writable) into statements at top-level `\n` / `;` and
// run each. `if` etc. are kept whole (their braced bodies contain the
// separators). Returns the last statement's status.
fn int shell_exec_block(char* text)
{
    int i = 0;
    int status = g_shell_status;
    while (text[i] != 0) {
        while (text[i] == '\n' || text[i] == ';' || text[i] == ' ' || text[i] == '\t') { i++; }
        if (text[i] == 0) { break; }
        int start = i;
        int end = sh_stmt_end(text, start);

        char save = text[end];
        text[end] = 0;
        status = shell_exec_stmt(&text[start]);
        text[end] = save;

        if (g_shell_script_stop || g_shell_loop_break || g_shell_loop_continue) { break; }

        i = end;
        if (text[i] == '\n' || text[i] == ';') { i++; }
    }
    g_shell_status = status;
    return status;
}
