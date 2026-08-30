module user;

// exec()'s own receive buffer for runtest below — caller-owned per
// exec()'s own header comment (user.c3): a global here, not inside
// user.c3 itself, so only binaries that actually call exec() pay the
// size (matches src/entry.c3's own EXEC_MAX_IMAGE_SIZE, the kernel-
// side cap this must be at least as large as).
const int RUN_EXEC_BUF_MAX = 262144;
char[RUN_EXEC_BUF_MAX] run_exec_buf;

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

fn void shell_refresh_user()
{
    g_shell_uid = getuid();
    user_name_by_uid(g_shell_uid, &g_shell_user[0], 32);
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

fn bool sh_name_start(char c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'; }
fn bool sh_name_char(char c)  { return sh_name_start(c) || (c >= '0' && c <= '9'); }

// Value of $<name>, into out (cap includes the NUL). "user"/"cwd"
// (alias "PWD")/"home" are synthesised from the shell's own state;
// everything else reads /env/<name> (empty if unset — Plan 9 rc
// treats an unset variable as the empty list).
fn int shell_var_value(char* name, char* out, int cap)
{
    if (strcmp(name, "user") == 0) {
        int k = 0;
        while (g_shell_user[k] != 0 && k < cap - 1) { out[k] = g_shell_user[k]; k++; }
        out[k] = 0;
        return k;
    }
    if (strcmp(name, "cwd") == 0 || strcmp(name, "PWD") == 0) {
        int n = getcwd(out, cap);
        if (n <= 0) { out[0] = '/'; out[1] = 0; return 1; }
        return n;
    }
    if (strcmp(name, "status") == 0) {
        // Exit status of the last command (rc's $status). Decimal, and
        // negative codes (e.g. -1 for a killed command) print with a
        // leading '-'.
        int v = g_shell_status;
        int k = 0;
        if (v < 0) { if (k < cap - 1) { out[k] = '-'; k++; } v = -v; }
        char[12] digs @noinit;
        int d = 0;
        digs[d] = (char)('0' + v % 10); d++; v /= 10;
        while (v > 0) { digs[d] = (char)('0' + v % 10); d++; v /= 10; }
        while (d > 0 && k < cap - 1) { d--; out[k] = digs[d]; k++; }
        out[k] = 0;
        return k;
    }
    if (strcmp(name, "home") == 0) {
        int k = 0;
        char* pfx = "/usr/";
        while (pfx[k] != 0 && k < cap - 1) { out[k] = pfx[k]; k++; }
        for (int j = 0; g_shell_user[j] != 0 && k < cap - 1; j++) { out[k] = g_shell_user[j]; k++; }
        out[k] = 0;
        return k;
    }
    char[80] path @noinit;
    char* ep = "/env/";
    int p = 0;
    while (ep[p] != 0) { path[p] = ep[p]; p++; }
    for (int j = 0; name[j] != 0 && p < 79; j++) { path[p] = name[j]; p++; }
    path[p] = 0;
    int n = fs_read(&path[0], out, cap - 1);
    if (n < 0) n = 0;
    out[n] = 0;
    return n;
}

// Expand $<name> references in `in` into `out` (cap includes the NUL).
// A `$` not followed by a name character is left literal. No braces,
// no quotes yet.
fn void shell_expand(char* in, char* out, int cap)
{
    int o = 0;
    int i = 0;
    while (in[i] != 0 && o < cap - 1) {
        if (in[i] == '$' && sh_name_start(in[i + 1])) {
            i++;
            char[32] name @noinit;
            int n = 0;
            while (sh_name_char(in[i]) && n < 31) { name[n] = in[i]; n++; i++; }
            name[n] = 0;
            char[256] val @noinit;
            int vl = shell_var_value(&name[0], &val[0], 256);
            for (int k = 0; k < vl && o < cap - 1; k++) { out[o] = val[k]; o++; }
        } else {
            out[o] = in[i];
            o++;
            i++;
        }
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
        putchar(ch);
        if (i == cap - 1) {
            print("\ncommand line too long\n");
            return -1;
        }
        if (ch == '\r') {
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
const int NS_LIST_RECS     = 8;  // must match src/process.c3's NS_MOUNTS_MAX

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
    // No user database at all (an unprovisioned root partition) — come
    // up as root rather than loop forever on a prompt nothing can
    // satisfy.
    char[8] probe @noinit;
    if (fs_read("/adm/users", &probe[0], 8) < 0) { return; }

    for (;;) {
        print("login: ");
        char[64] nm @noinit;
        int n = shell_readline(&nm[0], 64);
        if (n <= 0) { continue; }
        if (shell_login_once(&nm[0])) { return; }
    }
}

// Glob: does `name` match `pat`? `*` is any run (including empty), `?`
// is exactly one character; everything else is literal. Standard
// linear-time backtracking match. `pat` here is one path component —
// shell_glob_into() splits a pattern on its last '/' first.
fn bool glob_match(char* pat, char* name)
{
    int p = 0;
    int n = 0;
    int star_p = -1;
    int star_n = 0;
    while (name[n] != 0) {
        if (pat[p] == '?' || (pat[p] != 0 && pat[p] == name[n])) {
            p++; n++;
        } else if (pat[p] == '*') {
            star_p = p; star_n = n; p++;
        } else if (star_p >= 0) {
            p = star_p + 1; star_n++; n = star_n;
        } else {
            return false;
        }
    }
    while (pat[p] == '*') { p++; }
    return pat[p] == 0;
}

// Expand the glob pattern `pat` against the filesystem, appending each
// matching path to `words[*sw..]` (bounded by sw_cap) with the string
// bytes packed into `names[*nb..]` (bounded by nb_cap). Only the last
// path component may hold `*` / `?`; earlier components are literal.
// Returns the match count — 0 means "no match", and the caller keeps
// the pattern literal (rc's behaviour, not sh's).
fn int shell_glob_into(char* pat, char* names, int* nb, int nb_cap, char** words, int* sw, int sw_cap)
{
    int slash = -1;
    for (int k = 0; pat[k] != 0; k++) { if (pat[k] == '/') { slash = k; } }

    char[100] dir @noinit;
    char* base;
    if (slash < 0) {
        dir[0] = '.'; dir[1] = 0;
        base = pat;
    } else {
        int d = 0;
        while (d <= slash && d < 99) { dir[d] = pat[d]; d++; }
        dir[d] = 0;                 // keeps the trailing '/'
        base = &pat[slash + 1];
        if (base[0] == 0) { return 0; }
    }

    char[576] lb @noinit;           // FS_LIST_ENTRY_SIZE (36) * 16
    int cnt = fs_list(&dir[0], &lb[0], 16);
    if (cnt < 0) { return 0; }

    int matched = 0;
    for (int e = 0; e < cnt; e++) {
        char* nm = &lb[e * 36];
        if (!glob_match(base, nm)) { continue; }
        if (*sw >= sw_cap) { break; }
        int start = *nb;
        int w = start;
        if (slash >= 0) {
            for (int k = 0; k <= slash && w < nb_cap - 1; k++) { names[w] = pat[k]; w++; }
        }
        for (int k = 0; nm[k] != 0 && w < nb_cap - 1; k++) { names[w] = nm[k]; w++; }
        if (w >= nb_cap - 1) { break; }
        names[w] = 0; w++;
        words[*sw] = &names[start];
        (*sw)++;
        *nb = w;
        matched++;
    }
    return matched;
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
            exit();
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
                exec_path("fsd", &run_exec_buf, RUN_EXEC_BUF_MAX, 0, &mountusb_fsd_argv[0], 1);
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
            char[NS_LIST_RECS * 36] nsb @noinit;
            int nc = ns_list(&nsb[0], NS_LIST_RECS);
            if (nc < 0) {
                print("namespace: failed\n");
                g_shell_status = 1;
                return true;
            }
            for (int e = 0; e < nc; e++) {
                char* rec = &nsb[e * 36];
                uint pid = ((uint)rec[32] & 0xff)
                         | (((uint)rec[33] & 0xff) << 8)
                         | (((uint)rec[34] & 0xff) << 16)
                         | (((uint)rec[35] & 0xff) << 24);
                print(rec[0] != 0 ? rec : "/");
                print("\t-> pid ");
                print_uint(pid);
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
            // bind <source> <dir> — make <dir> resolve to whatever
            // currently serves <source>. Builtin for the same reason as
            // mount above.
            if (cmd_argc < 2) {
                print("usage: bind <source> <dir>\n");
                g_shell_status = 1;
                return true;
            }
            char[SH_NS_PREFIX_MAX] bp @noinit;
            shell_ns_prefix(cmd_argv[1], &bp[0]);
            char[100] bsrc @noinit;
            shell_resolve_path(cmd_argv[0], &bsrc[0]);
            if (ns_bind(&bp[0], bsrc[0] != 0 ? &bsrc[0] : "/") < 0) {
                print("bind: ");
                print(cmd_argv[0]);
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
fn int shell_spawn(char* cmd, char** cmd_argv, int cmd_argc, uint* gen_out)
{
            char[100] bin_path @noinit;
            int bp_i = 0;
            char* prefix = "/bin/";
            while (prefix[bp_i] != 0) { bin_path[bp_i] = prefix[bp_i]; bp_i++; }
            int bp_j = 0;
            while (cmd[bp_j] != 0 && bp_i < 99) { bin_path[bp_i] = cmd[bp_j]; bp_i++; bp_j++; }
            bin_path[bp_i] = 0;

            *gen_out = 0;
            int sh_r = rfork(RFPROC, gen_out);
            if (sh_r < 0) {
                print("rfork failed\n");
                return -1;
            }
            if (sh_r == 0) {
                exec(&bin_path, &run_exec_buf, RUN_EXEC_BUF_MAX, 0, cmd_argv, cmd_argc);
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
fn int shell_spawn_stage(char* cmd, char** cmd_argv, int cmd_argc, uint* gen_out)
{
    if (!shell_builtin_pipeable(cmd)) {
        return shell_spawn(cmd, cmd_argv, cmd_argc, gen_out);
    }
    *gen_out = 0;
    int r = rfork(RFPROC, gen_out);
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
            uint sh_gen = 0;
            int sh_r = shell_spawn(cmd, cmd_argv, cmd_argc, &sh_gen);
            if (sh_r <= 0) { return 127; }
            return join(sh_r, sh_gen);
}

// Quote-aware expansion for one pipeline segment. Copies `in` to `out`
// with the quote characters removed, expanding $name (via
// shell_var_value) except inside '...'. qmask[k] is 1 for every out[k]
// that came from inside quotes (or from a double-quoted expansion) —
// the tokeniser treats those bytes as ordinary text: never a word
// split, never an operator. Single quotes are fully literal, and '' is
// a literal '. Double quotes are literal except $name still expands
// (its bytes marked quoted, so "$x" stays one word). Returns the out
// length, or -1 on an unterminated quote.
fn int shell_expand_q(char* in, char* out, char* qmask, int cap)
{
    int o = 0;
    int i = 0;
    while (in[i] != 0 && o < cap - 1) {
        char c = in[i];
        if (c == '\'') {
            i++;
            for (;;) {
                if (in[i] == 0) { return -1; }
                if (in[i] == '\'') {
                    if (in[i + 1] == '\'') {
                        if (o < cap - 1) { out[o] = '\''; qmask[o] = 1; o++; }
                        i += 2; continue;
                    }
                    i++; break;
                }
                if (o < cap - 1) { out[o] = in[i]; qmask[o] = 1; o++; }
                i++;
            }
            continue;
        }
        if (c == '"') {
            i++;
            for (;;) {
                if (in[i] == 0) { return -1; }
                if (in[i] == '"') { i++; break; }
                if (in[i] == '$' && sh_name_start(in[i + 1])) {
                    i++;
                    char[32] nm @noinit; int n = 0;
                    while (sh_name_char(in[i]) && n < 31) { nm[n] = in[i]; n++; i++; }
                    nm[n] = 0;
                    char[256] val @noinit;
                    int vl = shell_var_value(&nm[0], &val[0], 256);
                    for (int k = 0; k < vl && o < cap - 1; k++) { out[o] = val[k]; qmask[o] = 1; o++; }
                } else {
                    if (o < cap - 1) { out[o] = in[i]; qmask[o] = 1; o++; }
                    i++;
                }
            }
            continue;
        }
        if (c == '$' && sh_name_start(in[i + 1])) {
            i++;
            char[32] nm @noinit; int n = 0;
            while (sh_name_char(in[i]) && n < 31) { nm[n] = in[i]; n++; i++; }
            nm[n] = 0;
            char[256] val @noinit;
            int vl = shell_var_value(&nm[0], &val[0], 256);
            for (int k = 0; k < vl && o < cap - 1; k++) { out[o] = val[k]; qmask[o] = 0; o++; }
            continue;
        }
        out[o] = c; qmask[o] = 0; o++;
        i++;
    }
    out[o] = 0;
    return o;
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
// Any word carrying an unquoted `*` / `?` is glob-expanded against the
// filesystem before the stage runs (last path component only); a
// pattern that matches nothing is left literal (rc's rule).
// Returns the exit status of the last stage (0 = success); a shell-side
// error (bad syntax, unterminated quote, unopenable redirection) is 2.
fn int shell_run_pipeline(char* seg, int seg_len)
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
        if (tok_glob[i]) {
            int gm = shell_glob_into(t, &glob_names[0], &gnb, GLOB_NAMES_BUF,
                                     &stage_words[0], &sw, STAGE_WORDS_MAX);
            stage_n[nstages - 1] += gm;
            // rc: a pattern that matches nothing stands as a literal word.
            if (gm == 0 && sw < STAGE_WORDS_MAX) { stage_words[sw] = t; sw++; stage_n[nstages - 1]++; }
        } else if (sw < STAGE_WORDS_MAX) {
            stage_words[sw] = t; sw++; stage_n[nstages - 1]++;
        }
    }

    for (int s = 0; s < nstages; s++) { if (stage_n[s] == 0) { bad = true; } }
    if (bad) { print("shell: malformed pipeline\n"); return 2; }
    if (outfile != null && gt_stage != nstages - 1) {
        print("shell: `>` redirect only on the last pipeline stage\n");
        return 2;
    }

    // No pipe, no redirection: the plain path, builtins included.
    if (nstages == 1 && infile == null && outfile == null) {
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

    // Spawn every stage, then wire its ends — before any child runs
    // (cooperative sched, the shell doesn't yield until the feed / pump
    // / join below). On a spawn failure, kill what started and bail.
    int[MAX_STAGES]  spid @noinit;
    uint[MAX_STAGES] sgen @noinit;
    int spawned = 0;
    for (int s = 0; s < nstages; s++) {
        char** argv = &stage_words[stage_off[s] + 1];
        int    argc = stage_n[s] - 1;
        spid[s] = shell_spawn_stage(stage_words[stage_off[s]], argv, argc, &sgen[s]);
        if (spid[s] < 0) {
            for (int k = 0; k < spawned; k++) { kill(spid[k], sgen[k]); }
            if (in_pipe  >= 0) { pipe_hold(in_pipe, 1, -1); }
            if (out_pipe >= 0) { pipe_hold(out_pipe, 0, -1); }
            return 2;
        }
        spawned++;
        int stdin_p  = s == 0           ? in_pipe  : mpipe[s - 1];
        int stdout_p = s == nstages - 1 ? out_pipe : mpipe[s];
        if (stdin_p  >= 0) { pipe_setin(spid[s], stdin_p); }
        if (stdout_p >= 0) { pipe_setout(spid[s], stdout_p); }
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
// 2 = ` && `, 3 = ` || `, 0 = none. *op_len gets the operator's byte
// length including its surrounding spaces. A trailing ` ;` / ` &&` /
// ` ||` at the very end of the line counts too (no space after).
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
    int conn = 0;       // 0 = first (always run), 1 = `;`, 2 = `&&`, 3 = `||`
    int seg_start = 0;
    int p = 0;
    char quote = 0;     // 0, '\'' or '"' — a sequencing op inside a quote is literal

    for (;;) {
        char c = line[p];
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
                || (conn == 2 && status == 0)
                || (conn == 3 && status != 0);

        // Trim leading spaces of the raw segment for the emptiness check.
        int s = seg_start;
        while (s < p && line[s] == ' ') { s++; }

        if (s < p && run) {
            status = shell_run_pipeline(&line[seg_start], seg_len);
            g_shell_status = status;   // visible to the next segment's $status
        } else if (s >= p && op >= 1) {
            print("shell: empty command near a ; && || operator\n");
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
