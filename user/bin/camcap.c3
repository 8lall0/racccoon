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

fn void main(String[] args)
{
    bool patgen = false;
    uint[4] win = { 640, 300, 640, 480 };
    int n = 0;
    for (int i = 0; i < args.len; i++) // racccoon passes no argv[0]: args[0] is the first argument
    {
        if (args[i].len == 2 && args[i][0] == '-' && args[i][1] == 'p') { patgen = true; continue; }
        if (n < 4) { win[n++] = parse_uint(args[i]); }
    }
    if (n != 0 && n != 4) { io::print("usage: camcap [-p] [x y w h]\n"); return; }
    win[0] &= ~(uint)1;
    win[2] &= ~(uint)1;

    if (ns_mount_wait("/srv/cifd/", "cifd", MOUNT_WAIT_ATTEMPTS) < 0) { io::print("camcap: cifd not available\n"); return; }
    if (!patgen && !link_live()) { io::print("camcap: the CSI-2 link isn't locked — run cifinit first (or camcap -p)\n"); return; }

    char[16] req;
    for (int i = 0; i < 16; i++) { req[i] = 0; }
    req[0] = patgen ? (char)1 : (char)0;
    for (int i = 0; i < 4; i++) { req[1 + 2 * i] = (char)win[i]; req[2 + 2 * i] = (char)(win[i] >> 8); }
    char[CIF_CAPTURE_REPLY] cr;
    if (!cif_call(CIF_IPC_CAPTURE, &req[0], 16, &cr[0], CIF_CAPTURE_REPLY)) { io::print("camcap: no reply from cifd\n"); return; }
    uint bytes = le32(&cr[21]);
    io::printfn("camcap: %s %dx%d at (%d,%d): INT_EVENT0=0x%08x INT_EVENT2=0x%08x BDG_INT=0x%08x/0x%08x PXL_CNT=%d DMA_STATUS=0x%08x",
        patgen ? "patgen" : "sensor", win[2], win[3], win[0], win[1],
        le32(&cr[1]), le32(&cr[5]), le32(&cr[9]), le32(&cr[25]), le32(&cr[13]), le32(&cr[17]));
    if (cr[0] == 2) { io::print("camcap: FAIL — cifd refused the window (too big for its buffer, or off the frame)\n"); return; }
    if (cr[0] != 0) { io::print("camcap: FAIL — no frame-done within 500 ms\n"); return; }

    // Pull the frame out and write it; keep a few stats as it goes past.
    char[CIF_FRAME_CHUNK] chunk;
    uint off = 0;
    uint lo = 0xfff;
    uint hi = 0;
    ulong sum = 0;
    uint npx = 0;
    uint nonzero = 0;
    fs_delete(FRAME_PATH);
    while (off < bytes)
    {
        char[8] rq;
        for (int i = 0; i < 8; i++) { rq[i] = i < 4 ? (char)(off >> (8 * i)) : (char)0; }
        uint rv = 0;
        int got = p9_call_path("/srv/cifd/", CIF_IPC_FRAME_READ, &rq[0], 8, &chunk[0], CIF_FRAME_CHUNK, &rv);
        if (got <= 0 || rv != CIF_IPC_FRAME_READ) { io::print("camcap: FRAME_READ failed\n"); return; }
        uint len = bytes - off < READ_STEP ? bytes - off : READ_STEP;
        if (off == 0)
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
        if (fs_write_at(FRAME_PATH, &chunk[0], (int)len, off) < 0) { io::print("camcap: writing /frame.raw failed\n"); return; }
        off += len;
    }
    io::printfn("camcap: wrote %d bytes to %s — pixels min %d max %d mean %d, %d of %d non-zero",
        bytes, FRAME_PATH, lo, hi, npx == 0 ? 0 : (uint)(sum / npx), nonzero, npx);
    io::printfn("camcap: on the PC: python3 scripts/raw_to_png.py frame.raw %d %d frame.png", win[2], win[3]);
    io::print(nonzero == 0 ? "camcap: FAIL — the buffer is still all zeros\n" : "camcap: PASS\n");
}
