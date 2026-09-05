module user;

import std::io;

// ps — one-shot process list. Walks every process-table slot via
// SYS_PROC_STAT (src/entry.c3) and prints pid / state / uid / resident
// pages / name. No options; the kernel table caps at 16 slots (PROCS_MAX).

const int MAXSLOT = 64; // generous ceiling over PROCS_MAX

fn uint le32(char* p) {
    // c3's `char` is already unsigned 8-bit — no sign-extension to mask.
    return (uint)p[0] | ((uint)p[1] << 8) | ((uint)p[2] << 16) | ((uint)p[3] << 24);
}

fn String state_name(uint s) {
    switch (s) {
        case 1: return "run";
        case 2: return "blk";
        default: return "?";
    }
}

fn void main(String[] args) {
    io::printn("  PID S    UID  PAGES NAME");
    for (int slot = 1; slot <= MAXSLOT; slot++) {
        char[52] st @noinit;
        if (proc_stat(slot, &st[0]) != 0) { continue; }
        uint state = le32(&st[0]);
        uint uid   = le32(&st[4]);
        uint pages = le32(&st[12]);
        uint pid   = le32(&st[16]);
        st[51] = 0;
        io::printfn("%5d %-3s %4d %6d %s", pid, state_name(state), uid, pages, (ZString)&st[20]);
    }
}
