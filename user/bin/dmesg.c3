module user;

import std::io;

// dmesg — dump the kernel console log ring (src/kernel/sbi.c3: kernel
// `io::print` / libc / panic output plus boot-server init chatter, last
// 32 KiB). A plain process's own stdout is NOT in the ring (the kernel
// takes it off the tee path — see SYS_PUTCHAR), so `dmesg` printing what
// it reads can't feed back.
//
// `-f` follows: keep printing new lines as they appear. Press any key to
// stop (racccoon has no ^C); a piped `dmesg -f` runs until the reader
// closes.

fn void main(String[] args) {
    bool follow = false;
    for (usz a = 0; a < args.len; a++) {
        if (args[a] == "-f") { follow = true; }
        else { io::printn("usage: dmesg [-f]"); return; }
    }

    bool console = stdin_is_console() != 0;
    if (follow && console) { io::printn("(dmesg: following — press any key to stop)"); }

    ulong cursor = 0;
    char[2048] buf @noinit;

    for (;;) {
        int n = klog_read(&buf[0], 2048, &cursor);
        if (n < 0) { io::printn("dmesg: klog_read failed"); return; }
        if (n > 0) { io::print((String)buf[:n]); }
        if (n == 0) {
            if (!follow) { return; }
            ulong deadline = rdtime() + timebase_hz() / 2;
            while (rdtime() < deadline) {
                if (console && getchar_nb() >= 0) { io::putchar('\n'); return; }
                yield();
            }
        }
    }
}
