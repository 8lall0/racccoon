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

// Tracks the dynamically-spawned fsd instance mountusb's own last run
// left behind, if any (0 = none) — see mountusb's own comment for why
// this exists: without it, re-running mountusb (or unmountusb) has no
// way to know what, if anything, needs cleaning up first.
int g_usbfs_fsd_pid = 0;
uint g_usbfs_fsd_gen = 0;

// Dispatches the small set of real, end-user shell builtins shared by
// both the production shell (shell.c3) and the test shell
// (shell_test.c3) — hello/exit/mountusb. Returns true if cmd was one of
// these (and therefore handled); false means the caller should fall
// back to shell_exec_external() below.
fn bool shell_dispatch_common(char* cmd, char** cmd_argv, int cmd_argc)
{
        if (strcmp(cmd, "hello") == 0) {
            print("Hello world from shell!\n");
            return true;
        } else if (strcmp(cmd, "exit") == 0) {
            exit();
        } else if (strcmp(cmd, "mountusb") == 0) {
            // Idempotent: retires whatever a previous mountusb run left
            // behind (a successful mount, or a fsd that never found
            // anything and is just idling forever per its own comment
            // below) before probing again. Without this, every re-run
            // (e.g. after physically swapping the USB drive) leaked a
            // whole fsd process — with PROCS_MAX this small, only a
            // handful of re-runs would exhaust the process table
            // entirely. ns_unmount() before kill(): the shell's own
            // namespace entry must stop resolving to this pid before
            // it's gone, not after — a caller racing this exact moment
            // could otherwise reach a pid that's already been recycled
            // into an unrelated process (closed the same way
            // everywhere else in this codebase, via kill()'s own
            // generation check, but there's no reason to rely on that
            // here when unmounting first is just as easy).
            if (g_usbfs_fsd_pid != 0) {
                ns_unmount("/mnt/usb/");
                kill(g_usbfs_fsd_pid, g_usbfs_fsd_gen);
                g_usbfs_fsd_pid = 0;
                g_usbfs_fsd_gen = 0;
            }

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
                g_usbfs_fsd_pid = mountusb_child;
                g_usbfs_fsd_gen = mountusb_gen;
            }
            return true;
        } else if (strcmp(cmd, "unmountusb") == 0) {
            if (g_usbfs_fsd_pid == 0) {
                print("unmountusb: nothing mounted\n");
            } else {
                ns_unmount("/mnt/usb/");
                kill(g_usbfs_fsd_pid, g_usbfs_fsd_gen);
                g_usbfs_fsd_pid = 0;
                g_usbfs_fsd_gen = 0;
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
