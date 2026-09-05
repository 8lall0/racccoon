module user;

import std::io;

// Raw single-sector read/write against whatever USB Mass Storage device
// is currently attached (through the DWC2 host controller's own hub,
// user/usb/msc.c3) — Tier 1 of this project's own two-tier USB storage
// work (see docs/devlog.md): prove raw read/write first, independent of
// the bigger step of wiring a drive into the mountable-filesystem layer
// (Tier 2 — see user/bin/mountusb.c3, which does exactly that now, a
// dynamically exec()'d fsd instance pointed at usbd instead of the real
// disk). Kept as its own standalone tool even after Tier 2 landed — a
// low-level dd/fdisk-style complement to normal mounted file access,
// useful independent of whatever filesystem (if any) is actually on a
// given drive.
//
// Talks to usbd (user/usb/usbd.c3) over the dynamic srv_post()/
// ns_mount_wait() mechanism, same Plan-9-style post+mount two-step
// fsd2 already uses (srv_post("fs2")) — usbd's own pid isn't fixed
// (spawned last at boot, after the shell itself), so this can't just
// use a static namespace default the way "/proc/"/"/env/" do.
//
// Wire protocol: byte 0..3 = LBA (uint), byte 4..515 = one 512-byte
// sector's data (the sector written, for a write request; the sector
// read, for a read reply) — the exact same shape AND numeric verb
// values as diskd's own DISKD_READ/DISKD_WRITE (user/block/diskd.c3) —
// deliberately, not arbitrary, so usbd is a genuine drop-in diskd-
// compatible block server (see docs/devlog.md). These constants must
// match user/usb/msc.c3's own copy by hand, same "kept in sync by
// hand" convention this project already established for DISKD_READ/
// WRITE across diskd.c3/fsd.c3's own separate copies.
const uint USB_MSC_IPC_READ  = 10;
const uint USB_MSC_IPC_WRITE = 11;
const uint USB_MSC_IPC_MSG_MAX = 516;
const uint USB_SECTOR_SIZE = 512;

// Bounded retry count, not a wall-clock timeout — see
// ns_mount_wait()'s own comment (user.c3) for why. usbd is a boot-time-
// spawned server (present well before any interactive command could
// possibly run), so this should succeed on its very first attempt in
// practice; generous headroom costs nothing since it only retries at
// all if usbd is genuinely missing (e.g. board::HAS_USB is false, a
// QEMU build).
const ulong USBD_MOUNT_WAIT_ATTEMPTS = 20;

// str_eq isn't available to an ordinary command binary (it's kernel-
// only, src/process.c3) — a small local copy, same "duplicate rather
// than share across separate compilation units" convention this
// project already uses for protocol constants (DISKD_READ/WRITE
// across diskd.c3/fsd.c3's own separate copies). print_int's own
// former hand-rolled copy is gone — io::printfn's %d does that now.
fn bool str_eq(char* a, char* b)
{
    int i = 0;
    while (a[i] != 0 && b[i] != 0)
    {
        if (a[i] != b[i]) { return false; }
        i++;
    }
    return a[i] == b[i];
}

fn bool usbrw_call(uint lba, char* sector_buf, bool is_write)
{
    if (ns_mount_wait("/srv/usbd/", "usbd", USBD_MOUNT_WAIT_ATTEMPTS) < 0)
    {
        io::print("usbrw: usbd not available (no USB host controller on this board?)\n");
        return false;
    }

    char[USB_MSC_IPC_MSG_MAX] req @noinit;
    uint* lba_field = (uint*)&req[0];
    *lba_field = lba;
    if (is_write)
    {
        for (uint i = 0; i < USB_SECTOR_SIZE; i++) { req[4 + i] = sector_buf[i]; }
    }

    uint verb = is_write ? USB_MSC_IPC_WRITE : USB_MSC_IPC_READ;
    uint reply_verb = 0;
    int from = p9_call_path("/srv/usbd/", verb, &req[0], (int)USB_MSC_IPC_MSG_MAX, &req[0], (int)USB_MSC_IPC_MSG_MAX, &reply_verb);
    if (from <= 0 || reply_verb != verb)
    {
        io::print("usbrw: request failed (no reply from usbd)\n");
        return false;
    }

    if (req[0] != 0)
    {
        io::print("usbrw: usbd reported failure — no MSC device attached, LBA out of range, or a real transfer error\n");
        return false;
    }

    if (!is_write)
    {
        for (uint i = 0; i < USB_SECTOR_SIZE; i++) { sector_buf[i] = req[4 + i]; }
    }
    return true;
}

fn void main(String[] args)
{
    if (args.len != 3 || (!str_eq(args[0].ptr, "read") && !str_eq(args[0].ptr, "write")))
    {
        io::print("usage: usbrw read <lba> <path>   (reads one 512-byte sector into path)\n");
        io::print("       usbrw write <lba> <path>  (writes path's first 512 bytes to that sector)\n");
        return;
    }

    bool is_write = str_eq(args[0].ptr, "write");
    int? lba_r = args[1].to_int();
    if (catch lba_r) { io::print("usbrw: <lba> must be a plain non-negative number\n"); return; }
    int lba = lba_r;
    char* path = args[2].ptr;

    char[512] sector @noinit;
    if (is_write)
    {
        int got = fs_read(path, &sector[0], 512);
        if (got != 512)
        {
            io::printfn("usbrw: %s: need exactly 512 bytes to write one sector, got %d", (ZString)path, got);
            return;
        }
        if (!usbrw_call((uint)lba, &sector[0], true)) { return; }
        io::printfn("usbrw: wrote LBA %d from %s", lba, (ZString)path);
    }
    else
    {
        if (!usbrw_call((uint)lba, &sector[0], false)) { return; }
        int written = fs_write(path, &sector[0], 512);
        if (written != 512)
        {
            io::print("usbrw: read the sector but failed writing it to ");
            io::print((ZString)path);
            io::print("\n");
            return;
        }
        io::printfn("usbrw: read LBA %d into %s", lba, (ZString)path);
    }
}
