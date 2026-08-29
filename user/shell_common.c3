module user;

// exec()'s own receive buffer for runtest below — caller-owned per
// exec()'s own header comment (user.c3): a global here, not inside
// user.c3 itself, so only binaries that actually call exec() pay the
// size (matches src/entry.c3's own EXEC_MAX_IMAGE_SIZE, the kernel-
// side cap this must be at least as large as).
const int RUN_EXEC_BUF_MAX = 262144;
char[RUN_EXEC_BUF_MAX] run_exec_buf;

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

// Dispatches the small set of real, end-user shell builtins shared by
// both the production shell (shell.c3) and the test shell
// (shell_test.c3) — hello/exit/mountusb/su. Returns true if cmd was one
// of these (and therefore handled); false means the caller should fall
// back to shell_exec_external() below.
fn bool shell_dispatch_common(char* cmd, char** cmd_argv, int cmd_argc)
{
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
                return true;
            }
            if (setuid(su_uid) < 0) {
                print("su: denied (this shell already dropped privilege — exit and start over)\n");
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
                    return true;
                }
                if (cd_ty == 0) {
                    print("cd: not a directory\n");
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
        }
    return false;
}

// The /bin/<cmd> fallback — also shared by both shells (see
// shell_dispatch_common's own comment above for why).
fn void shell_exec_external(char* cmd, char** cmd_argv, int cmd_argc)
{
            char[100] bin_path @noinit;
            int bp_i = 0;
            char* prefix = "/bin/";
            while (prefix[bp_i] != 0) { bin_path[bp_i] = prefix[bp_i]; bp_i++; }
            int bp_j = 0;
            while (cmd[bp_j] != 0 && bp_i < 99) { bin_path[bp_i] = cmd[bp_j]; bp_i++; bp_j++; }
            bin_path[bp_i] = 0;

            uint sh_gen = 0;
            int sh_r = rfork(RFPROC, &sh_gen);
            if (sh_r < 0) {
                print("rfork failed\n");
            } else if (sh_r == 0) {
                exec(&bin_path, &run_exec_buf, RUN_EXEC_BUF_MAX, 0, cmd_argv, cmd_argc);
                print(cmd);
                print(": command not found\n");
                exit();
            } else {
                join(sh_r, sh_gen);
            }
}
