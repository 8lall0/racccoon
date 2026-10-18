module user;

import std::io;

// Stage 4 of docs/camera-plan.md: one raw frame from the GC2083 into a
// file. Asks cifd (user/cif/cifd.c3) to run its `vi` raw capture — the CSI
// bridge's write DMA, 12-bit packed, 2 pixels per 3 bytes — over a window
// of the 1920x1080 frame, then pulls the bytes out with FRAME_READ and
// writes them to /frame.raw. scripts/raw_to_png.py turns that into a
// picture on the PC.
//
//   camcap -p [x y w h]   the bridge's own pattern generator, no sensor
//   camcap [x y w h]      the real sensor; run cifinit first (link locked)
//   camcap -a ...         auto-exposure first (meters the centre, sets the
//                         GC2083's exposure and analog gain)
//   camcap -f             the full 1920x1080 frame
//
// The window defaults to 640x480 from the middle of the frame; x and w
// are rounded to even (one Bayer quad = 2x2).

const uint CIF_IPC_GET_STATUS = 1;
const uint CIF_IPC_PEEK       = 3;
const uint CIF_IPC_CAPTURE    = 5;   // must match user/cif/cifd.c3
const uint CIF_IPC_FRAME_READ = 6;
const int  CIF_STATUS_LOCKED  = 0;
const int  CIF_CAPTURE_REPLY  = 29;
const int  CIF_FRAME_CHUNK    = 4096;
const uint READ_STEP          = 4095; // a multiple of 3, so every chunk starts on a pixel pair
const uint WRAP_PHY_STATE     = 0x0A0D0390; // bit0 = clock lane in HS (cifinit.c3)
const ulong MOUNT_WAIT_ATTEMPTS = 20;
const ZString FRAME_PATH = "/frame.raw";

fn uint le32(char* p) { return (uint)p[0] | ((uint)p[1] << 8) | ((uint)p[2] << 16) | ((uint)p[3] << 24); }

fn bool cif_call(uint verb, char* req, int req_len, char* reply, int reply_len)
{
    uint rv = 0;
    int from = p9_call_path("/srv/cifd/", verb, req, req_len, reply, reply_len, &rv);
    return from > 0 && rv == verb;
}

// The sensor path only makes sense with the link locked and live.
fn bool link_live()
{
    char[8] r;
    for (int i = 0; i < 8; i++) { r[i] = 0; }
    if (!cif_call(CIF_IPC_GET_STATUS, &r[0], 8, &r[0], 8) || (int)r[0] != CIF_STATUS_LOCKED) { return false; }
    char[8] p;
    for (int i = 0; i < 8; i++) { p[i] = i < 4 ? (char)(WRAP_PHY_STATE >> (8 * i)) : (char)0; }
    if (!cif_call(CIF_IPC_PEEK, &p[0], 8, &p[0], 8) || p[0] != 0) { return false; }
    return (le32(&p[1]) & 1) != 0;
}

fn uint parse_uint(String s)
{
    uint v = 0;
    foreach (c : s) { if (c >= '0' && c <= '9') { v = v * 10 + (uint)(c - '0'); } }
    return v;
}

struct Frame_stats
{
    uint lo;
    uint hi;
    uint mean;
    uint npx;
    uint nonzero;
}

// One capture of `win` through cifd; reads the bytes back for the stats
// and, when `save`, writes them to /frame.raw. False (and printed) on
// failure.
fn bool capture(bool patgen, uint[4]* win, bool save, bool verbose, Frame_stats* st)
{
    char[16] req;
    for (int i = 0; i < 16; i++) { req[i] = 0; }
    req[0] = patgen ? (char)1 : (char)0;
    for (int i = 0; i < 4; i++) { req[1 + 2 * i] = (char)(*win)[i]; req[2 + 2 * i] = (char)((*win)[i] >> 8); }
    char[CIF_CAPTURE_REPLY] cr;
    if (!cif_call(CIF_IPC_CAPTURE, &req[0], 16, &cr[0], CIF_CAPTURE_REPLY)) { io::print("camcap: no reply from cifd\n"); return false; }
    uint bytes = le32(&cr[21]);
    if (verbose)
    {
        io::printfn("camcap: %s %dx%d at (%d,%d): INT_EVENT0=0x%08x INT_EVENT2=0x%08x BDG_INT=0x%08x/0x%08x PXL_CNT=%d DMA_STATUS=0x%08x",
            patgen ? "patgen" : "sensor", (*win)[2], (*win)[3], (*win)[0], (*win)[1],
            le32(&cr[1]), le32(&cr[5]), le32(&cr[9]), le32(&cr[25]), le32(&cr[13]), le32(&cr[17]));
    }
    if (cr[0] == 2) { io::print("camcap: FAIL — cifd refused the window (too big for its buffer, or off the frame)\n"); return false; }
    if (cr[0] != 0) { io::print("camcap: FAIL — no frame-done within 500 ms\n"); return false; }

    char[CIF_FRAME_CHUNK] chunk;
    uint off = 0;
    uint lo = 0xfff;
    uint hi = 0;
    ulong sum = 0;
    uint npx = 0;
    uint nonzero = 0;
    if (save) { fs_delete(FRAME_PATH); }
    while (off < bytes)
    {
        char[8] rq;
        for (int i = 0; i < 8; i++) { rq[i] = i < 4 ? (char)(off >> (8 * i)) : (char)0; }
        uint rv = 0;
        int got = p9_call_path("/srv/cifd/", CIF_IPC_FRAME_READ, &rq[0], 8, &chunk[0], CIF_FRAME_CHUNK, &rv);
        if (got <= 0 || rv != CIF_IPC_FRAME_READ) { io::print("camcap: FRAME_READ failed\n"); return false; }
        uint len = bytes - off < READ_STEP ? bytes - off : READ_STEP;
        if (off == 0 && verbose)
        {
            io::print("camcap: first bytes:");
            for (int i = 0; i < 24; i++) { io::printf(" %02x", (uint)chunk[i]); }
            io::print("\n");
        }
        // Packing as the bridge writes it (confirmed against the patgen
        // pattern): bytes b0 b1 b2 -> p0 = b0<<4 | b2&0xf, p1 = b1<<4 | b2>>4.
        for (uint i = 0; i + 2 < len; i += 3)
        {
            uint p0 = ((uint)chunk[i] << 4) | ((uint)chunk[i + 2] & 0xf);
            uint p1 = ((uint)chunk[i + 1] << 4) | ((uint)chunk[i + 2] >> 4);
            foreach (p : (uint[2]){ p0, p1 })
            {
                if (p < lo) { lo = p; }
                if (p > hi) { hi = p; }
                sum += p;
                npx++;
                if (p != 0) { nonzero++; }
            }
        }
        if (save && fs_write_at(FRAME_PATH, &chunk[0], (int)len, off) < 0) { io::print("camcap: writing /frame.raw failed\n"); return false; }
        off += len;
    }
    *st = { .lo = lo, .hi = hi, .mean = npx == 0 ? 0 : (uint)(sum / npx), .npx = npx, .nonzero = nonzero };
    return true;
}

// --- GC2083 exposure + gain, as the vendor driver writes them
// (middleware/v2/component/isp/sensor/cv180x/gcore_gc2083/gc2083_cmos.c:
// cmos_inttime_update, cmos_gains_update). Exposure is in lines, 1..1117
// (VTS 1125 - 8); analog gain is one of 29 table steps, each a set of 13
// registers, with digital gain left at 1.0x.
const uint I2C_IPC_XFER    = 1;     // must match user/i2c/i2cd.c3
const uint I2C_IPC_MSG_MAX = 8;
const uint GC2083_I2C_ADDR = 0x37;
const uint EXP_MIN = 1;
const uint EXP_MAX = 1117;
const int  GAIN_STEPS = 29;
// gain_table / 16: the step's analog gain in 1/64ths.
const uint[GAIN_STEPS] GAIN_X64 = {
    64, 76, 90, 107, 128, 152, 179, 213, 256, 305, 358, 427, 512, 610, 717, 854,
    1024, 1220, 1434, 1707, 2048, 2439, 2867, 3415, 4096, 4878, 5734, 6830, 8028 };
// regValTable columns: 0x00d0 0x0155 0x0410..0x0417 0x00b8 0x00b9 0x0dc1
const uint[12] GAIN_REGS = { 0x00d0, 0x0155, 0x0410, 0x0411, 0x0412, 0x0413, 0x0414, 0x0415, 0x0416, 0x0417, 0x00b8, 0x00b9 };
const char[13][GAIN_STEPS] GAIN_VALS = {
    { 0x00, 0x03, 0x11, 0x11, 0x11, 0x11, 0x6f, 0x6f, 0x6f, 0x6f, 0x01, 0x00, 0x00 },
    { 0x10, 0x03, 0x11, 0x11, 0x11, 0x11, 0x6f, 0x6f, 0x6f, 0x6f, 0x01, 0x0c, 0x00 },
    { 0x01, 0x03, 0x11, 0x11, 0x11, 0x11, 0x6f, 0x6f, 0x6f, 0x6f, 0x01, 0x1a, 0x00 },
    { 0x11, 0x03, 0x11, 0x11, 0x11, 0x11, 0x6f, 0x6f, 0x6f, 0x6f, 0x01, 0x2b, 0x00 },
    { 0x02, 0x03, 0x11, 0x11, 0x11, 0x11, 0x6f, 0x6f, 0x6f, 0x6f, 0x02, 0x00, 0x00 },
    { 0x12, 0x03, 0x11, 0x11, 0x11, 0x11, 0x6f, 0x6f, 0x6f, 0x6f, 0x02, 0x18, 0x00 },
    { 0x03, 0x03, 0x11, 0x11, 0x11, 0x11, 0x6f, 0x6f, 0x6f, 0x6f, 0x02, 0x33, 0x00 },
    { 0x13, 0x03, 0x11, 0x11, 0x11, 0x11, 0x6f, 0x6f, 0x6f, 0x6f, 0x03, 0x15, 0x00 },
    { 0x04, 0x03, 0x11, 0x11, 0x11, 0x11, 0x6f, 0x6f, 0x6f, 0x6f, 0x04, 0x00, 0x00 },
    { 0x14, 0x03, 0x11, 0x11, 0x11, 0x11, 0x6f, 0x6f, 0x6f, 0x6f, 0x04, 0xe0, 0x00 },
    { 0x05, 0x03, 0x11, 0x11, 0x11, 0x11, 0x6f, 0x6f, 0x6f, 0x6f, 0x05, 0x26, 0x00 },
    { 0x15, 0x03, 0x11, 0x11, 0x11, 0x11, 0x6f, 0x6f, 0x6f, 0x6f, 0x06, 0x2b, 0x00 },
    { 0x44, 0x03, 0x11, 0x11, 0x11, 0x11, 0x6f, 0x6f, 0x6f, 0x6f, 0x08, 0x00, 0x00 },
    { 0x54, 0x03, 0x11, 0x11, 0x11, 0x11, 0x6f, 0x6f, 0x6f, 0x6f, 0x09, 0x22, 0x00 },
    { 0x45, 0x03, 0x11, 0x11, 0x11, 0x11, 0x6f, 0x6f, 0x6f, 0x6f, 0x0b, 0x0d, 0x00 },
    { 0x55, 0x03, 0x11, 0x11, 0x11, 0x11, 0x6f, 0x6f, 0x6f, 0x6f, 0x0d, 0x16, 0x00 },
    { 0x04, 0x19, 0x16, 0x16, 0x16, 0x16, 0x6f, 0x6f, 0x6f, 0x6f, 0x10, 0x00, 0x01 },
    { 0x14, 0x19, 0x16, 0x16, 0x16, 0x16, 0x6f, 0x6f, 0x6f, 0x6f, 0x13, 0x04, 0x01 },
    { 0x24, 0x19, 0x16, 0x16, 0x16, 0x16, 0x6f, 0x6f, 0x6f, 0x6f, 0x16, 0x1a, 0x01 },
    { 0x34, 0x19, 0x16, 0x16, 0x16, 0x16, 0x6f, 0x6f, 0x6f, 0x6f, 0x1a, 0x2b, 0x01 },
    { 0x44, 0x36, 0x18, 0x18, 0x18, 0x18, 0x6f, 0x6f, 0x6f, 0x6f, 0x20, 0x00, 0x01 },
    { 0x54, 0x36, 0x18, 0x18, 0x18, 0x18, 0x6f, 0x6f, 0x6f, 0x6f, 0x26, 0x07, 0x01 },
    { 0x64, 0x36, 0x18, 0x18, 0x18, 0x18, 0x6f, 0x6f, 0x6f, 0x6f, 0x2c, 0x33, 0x01 },
    { 0x74, 0x36, 0x18, 0x18, 0x18, 0x18, 0x6f, 0x6f, 0x6f, 0x6f, 0x35, 0x17, 0x01 },
    { 0x84, 0x64, 0x16, 0x16, 0x16, 0x16, 0x72, 0x72, 0x72, 0x72, 0x35, 0x17, 0x01 },
    { 0x94, 0x64, 0x16, 0x16, 0x16, 0x16, 0x72, 0x72, 0x72, 0x72, 0x35, 0x17, 0x01 },
    { 0x85, 0x64, 0x16, 0x16, 0x16, 0x16, 0x72, 0x72, 0x72, 0x72, 0x35, 0x17, 0x01 },
    { 0x95, 0x64, 0x16, 0x16, 0x16, 0x16, 0x72, 0x72, 0x72, 0x72, 0x35, 0x17, 0x01 },
    { 0xa5, 0x64, 0x16, 0x16, 0x16, 0x16, 0x72, 0x72, 0x72, 0x72, 0x35, 0x17, 0x01 },
};

fn bool write_reg8(uint reg, char val)
{
    char[I2C_IPC_MSG_MAX] req;
    for (int i = 0; i < 8; i++) { req[i] = 0; }
    req[0] = (char)GC2083_I2C_ADDR;
    req[1] = (char)3;
    req[3] = (char)(reg >> 8); req[4] = (char)reg; req[5] = val;
    uint rv = 0;
    int from = p9_call_path("/srv/i2cd/", I2C_IPC_XFER, &req[0], (int)I2C_IPC_MSG_MAX, &req[0], (int)I2C_IPC_MSG_MAX, &rv);
    return from > 0 && rv == I2C_IPC_XFER && req[0] == 0;
}

fn bool set_exposure(uint lines, int gain_step)
{
    bool ok = write_reg8(0x0d03, (char)((lines >> 8) & 0x3f)) && write_reg8(0x0d04, (char)lines);
    for (int i = 0; i < 12; i++) { ok = ok && write_reg8(GAIN_REGS[i], GAIN_VALS[gain_step][i]); }
    ok = ok && write_reg8(0x031d, (char)0x2e) && write_reg8(0x0dc1, GAIN_VALS[gain_step][12]) && write_reg8(0x031d, (char)0x28);
    ok = ok && write_reg8(0x00b1, (char)1) && write_reg8(0x00b2, (char)0); // digital gain 1.0x (64 >> 6, (64 & 0x3f) << 2)
    return ok;
}

fn void sleep_ms(ulong ms)
{
    ulong hz = timebase_hz();
    ulong deadline = rdtime() + (hz / 1000) * ms;
    while (rdtime() < deadline) { yield(); }
}

// The black level the sensor adds (raw minimum on a dark scene: ~256 of 4095).
const uint BLACK_LEVEL = 256;
// Aim the metered mean at ~22% of the range above black: room for highlights.
const uint AE_TARGET = 850;

// A few rounds of: meter the centre, scale exposure x gain toward the
// target, wait for it to take (the sensor applies a new exposure a frame
// or two later). Exposure first; gain only once exposure is at its max.
fn void auto_expose()
{
    if (ns_mount_wait("/srv/i2cd/", "i2cd", MOUNT_WAIT_ATTEMPTS) < 0) { io::print("camcap: i2cd not available, no auto-exposure\n"); return; }
    uint[4] meter = { 800, 420, 320, 240 };
    // Start from a known setting — caminit's 0x0d03/0x0d04 = 0x0202 lines at
    // gain 1.0x — whatever an earlier camcap -a left behind.
    ulong total = 514 * 64;
    if (!set_exposure(514, 0)) { io::print("camcap: writing exposure/gain failed\n"); return; }
    sleep_ms(120);
    for (int round = 0; round < 8; round++)
    {
        Frame_stats st;
        if (!capture(false, &meter, false, false, &st)) { return; }
        uint signal = st.mean > BLACK_LEVEL ? st.mean - BLACK_LEVEL : 1;
        io::printfn("camcap: AE round %d: exposure x gain = %d lines, metered mean %d (signal %d, target %d)",
            round, (uint)(total / 64), st.mean, signal, AE_TARGET);
        if (signal * 100 >= AE_TARGET * 88 && signal * 100 <= AE_TARGET * 112) { return; }
        ulong want = total * AE_TARGET / signal;
        if (want > total * 4) { want = total * 4; }   // one step at a time keeps it from oscillating
        if (want < total / 4) { want = total / 4; }
        int g = 0;
        while (g < GAIN_STEPS - 1 && (ulong)EXP_MAX * GAIN_X64[g] < want) { g++; }
        ulong lines = want / GAIN_X64[g];
        if (lines < EXP_MIN) { lines = EXP_MIN; }
        if (lines > EXP_MAX) { lines = EXP_MAX; }
        ulong now = lines * GAIN_X64[g];
        if (now == total) { return; }               // pinned at a limit
        if (!set_exposure((uint)lines, g)) { io::print("camcap: writing exposure/gain failed\n"); return; }
        total = now;
        sleep_ms(120);
    }
}

fn void main(String[] args)
{
    bool patgen = false;
    bool ae = false;
    uint[4] win = { 640, 300, 640, 480 };
    int n = 0;
    for (int i = 0; i < args.len; i++) // racccoon passes no argv[0]: args[0] is the first argument
    {
        if (args[i].len == 2 && args[i][0] == '-')
        {
            switch (args[i][1])
            {
                case 'p': patgen = true; continue;
                case 'a': ae = true; continue;
                case 'f': win = { 0, 0, 1920, 1080 }; continue;
                default: io::print("usage: camcap [-p] [-a] [-f | x y w h]\n"); return;
            }
        }
        if (n < 4) { win[n++] = parse_uint(args[i]); }
    }
    if (n != 0 && n != 4) { io::print("usage: camcap [-p] [-a] [-f | x y w h]\n"); return; }
    win[0] &= ~(uint)1;
    win[2] &= ~(uint)1;

    if (ns_mount_wait("/srv/cifd/", "cifd", MOUNT_WAIT_ATTEMPTS) < 0) { io::print("camcap: cifd not available\n"); return; }
    if (!patgen && !link_live()) { io::print("camcap: the CSI-2 link isn't locked — run cifinit first (or camcap -p)\n"); return; }
    if (ae && !patgen) { auto_expose(); }

    Frame_stats st;
    if (!capture(patgen, &win, true, true, &st)) { return; }
    io::printfn("camcap: wrote %s — pixels min %d max %d mean %d, %d of %d non-zero",
        FRAME_PATH, st.lo, st.hi, st.mean, st.nonzero, st.npx);
    io::printfn("camcap: on the PC: python3 scripts/raw_to_png.py frame.raw %d %d frame.png", win[2], win[3]);
    io::print(st.nonzero == 0 ? "camcap: FAIL — the buffer is still all zeros\n" : "camcap: PASS\n");
}
