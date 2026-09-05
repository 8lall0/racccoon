module user;

import std::io;

// top — live process view. Redraws every ~2 s via SYS_PROC_STAT
// (src/entry.c3). racccoon has no ^C, so it runs a fixed number of frames
// (default 30, ~1 min) then exits; `top N` sets the frame count, `top 0`
// runs until the board resets.

const int MAXSLOT = 64;

fn uint le32(char* p) {
    return (uint)p[0] | ((uint)p[1] << 8) | ((uint)p[2] << 16) | ((uint)p[3] << 24);
}

fn String state_name(uint s) {
    switch (s) {
        case 1: return "run";
        case 2: return "blk";
        default: return "?";
    }
}

fn void draw(int frame) {
    io::print("\x1b[H\x1b[J"); // cursor home + clear screen

    ulong hz = timebase_hz();
    ulong secs = hz > 0 ? rdtime() / hz : 0;
    io::printfn("top - uptime %ds   frame %d", secs, frame);

    int nproc = 0;
    int nrun = 0;
    uint totpages = 0;

    io::printn("");
    io::printn("  PID S    UID  PAGES NAME");
    for (int slot = 1; slot <= MAXSLOT; slot++) {
        char[52] st @noinit;
        if (proc_stat(slot, &st[0]) != 0) { continue; }
        uint state = le32(&st[0]);
        uint uid   = le32(&st[4]);
        uint pages = le32(&st[12]);
        uint pid   = le32(&st[16]);
        st[51] = 0;
        nproc++;
        totpages += pages;
        if (state == 1) { nrun++; }
        io::printfn("%5d %-3s %4d %6d %s", pid, state_name(state), uid, pages, (ZString)&st[20]);
    }

    io::printn("");
    io::printfn("%d procs, %d runnable, %d pages resident (%d KiB)",
        nproc, nrun, totpages, totpages * 4);
}

fn void main(String[] args) {
    int frames = 30;
    if (args.len >= 1) {
        int? n = args[0].to_int();
        if (catch n) { io::printn("top: usage: top [frames]"); return; }
        if (n < 0) { io::printn("top: usage: top [frames]"); return; }
        frames = n;
    }

    bool console = stdin_is_console() != 0;
    int f = 0;
    for (;;) {
        f++;
        draw(f);
        if (console) { io::print("  (press any key to quit)\n"); }
        if (frames > 0 && f >= frames) { break; }
        // Bail on any keypress between frames — racccoon has no ^C, and
        // an un-bounded `top 0` would otherwise wedge the shell.
        ulong deadline = rdtime() + timebase_hz() * 2;
        while (rdtime() < deadline) {
            if (console && getchar_nb() >= 0) { return; }
            yield();
        }
    }
}
