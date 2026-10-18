module user;

import std::io;

// Stage 3 of docs/camera-plan.md: tells cifd (user/cif/cifd.c3) to enable
// its D-PHY receiver, THEN brings the sensor all the way up (reset +
// chip-ID + full mode-init, same as caminit.c3 — the init table ends with
// 0x023e = 0x99, stream on), and polls the MAC's own CSI_STATUS register
// for a couple seconds looking for a clean lock: a valid CSI-2 packet
// header decoded, no ECC/CRC/word-count errors. See main() for why the
// order matters.
// No DMA, no pixels reaching DRAM — that's Stage 4+, gated on the
// closed `vi` block (see docs/camera-plan.md's sourcing-split note).
//
// Duplicates camtest.c3/caminit.c3's own reset-pulse/mode-init/IPC
// plumbing by hand rather than sharing it — same convention this
// project already uses for these small CLI tools.

const uint GPIO_IPC_SET_DIR = 1;
const uint GPIO_IPC_WRITE   = 2;
const uint GPIO_IPC_MSG_MAX = 8;

const uint I2C_IPC_XFER    = 1;
const uint I2C_IPC_MSG_MAX = 8;

const uint CIF_IPC_GET_STATUS    = 1;
const uint CIF_IPC_STREAM_ENABLE = 2;
const uint CIF_IPC_PEEK          = 3;
const uint CIF_IPC_MSG_MAX    = 8;
const int CIF_STATUS_LOCKED     = 0;
const int CIF_STATUS_NOT_LOCKED = 1;
const int CIF_STATUS_ERROR      = 2;

const ulong MOUNT_WAIT_ATTEMPTS = 20;

const char SENSOR_RSTN_BANK = 'C';
const int  SENSOR_RSTN_BIT  = 8;
const uint GC2083_I2C_ADDR  = 0x37;
const uint GC2083_CHIPID_REG = 0x03f0;

fn bool gpio_call(uint verb, char bank_letter, int bit, char arg)
{
    if (ns_mount_wait("/srv/gpiod/", "gpiod", MOUNT_WAIT_ATTEMPTS) < 0)
    {
        io::print("cifinit: gpiod not available\n");
        return false;
    }
    char[GPIO_IPC_MSG_MAX] req @noinit;
    req[0] = bank_letter;
    req[1] = (char)bit;
    req[2] = arg;
    uint reply_verb = 0;
    int from = p9_call_path("/srv/gpiod/", verb, &req[0], (int)GPIO_IPC_MSG_MAX, &req[0], (int)GPIO_IPC_MSG_MAX, &reply_verb);
    if (from <= 0 || reply_verb != verb) { io::print("cifinit: no reply from gpiod\n"); return false; }
    if (req[0] != 0) { io::print("cifinit: GPIOC8 not in gpiod's own allowlist (unexpected)\n"); return false; }
    return true;
}

fn int i2c_xfer_call(uint addr7, char* wbuf, int write_len, char* rbuf, int read_len)
{
    if (ns_mount_wait("/srv/i2cd/", "i2cd", MOUNT_WAIT_ATTEMPTS) < 0)
    {
        io::print("cifinit: i2cd not available\n");
        return -1;
    }
    char[I2C_IPC_MSG_MAX] req @noinit;
    req[0] = (char)addr7;
    req[1] = (char)write_len;
    req[2] = (char)read_len;
    for (int i = 0; i < 4; i++) { req[3 + i] = i < write_len ? wbuf[i] : (char)0; }
    uint reply_verb = 0;
    int from = p9_call_path("/srv/i2cd/", I2C_IPC_XFER, &req[0], (int)I2C_IPC_MSG_MAX, &req[0], (int)I2C_IPC_MSG_MAX, &reply_verb);
    if (from <= 0 || reply_verb != I2C_IPC_XFER) { io::print("cifinit: no reply from i2cd\n"); return -1; }
    int status = (int)(char)req[0];
    for (int i = 0; i < read_len && i < 4; i++) { rbuf[i] = req[1 + i]; }
    return status;
}

fn int read_reg8(uint reg_addr, char* out_byte)
{
    char[2] reg @noinit;
    reg[0] = (char)((reg_addr >> 8) & 0xff);
    reg[1] = (char)(reg_addr & 0xff);
    return i2c_xfer_call(GC2083_I2C_ADDR, &reg[0], 2, out_byte, 1);
}

fn int write_reg8(uint reg_addr, char val)
{
    char[3] wbuf @noinit;
    wbuf[0] = (char)((reg_addr >> 8) & 0xff);
    wbuf[1] = (char)(reg_addr & 0xff);
    wbuf[2] = val;
    return i2c_xfer_call(GC2083_I2C_ADDR, &wbuf[0], 3, null, 0);
}

fn void sleep_ms(ulong ms)
{
    ulong hz = timebase_hz();
    ulong deadline = rdtime() + (hz / 1000) * ms;
    while (rdtime() < deadline) { yield(); }
}

// Same 135-entry table as user/bin/caminit.c3 — kept in sync by hand,
// same convention as every other small wire-protocol/table constant
// this project duplicates per caller rather than sharing.
const int GC2083_REG_COUNT = 135;
uint[GC2083_REG_COUNT] gc2083_reg_addr;
char[GC2083_REG_COUNT] gc2083_reg_val;

fn void gc2083_reg_table_init()
{
    uint[GC2083_REG_COUNT] addrs = {
        0x03fe, 0x03fe, 0x03fe, 0x03fe, 0x03f2, 0x03f3, 0x03f4, 0x03f5, 0x03f6, 0x03f7,
        0x03f8, 0x03f9, 0x03fc, 0x0381, 0x00d7, 0x0d6d, 0x00d5, 0x0082, 0x0db3, 0x0db0,
        0x0db5, 0x0d03, 0x0d04, 0x0d05, 0x0d06, 0x0d07, 0x0d08, 0x0d09, 0x0d0a, 0x000b,
        0x000c, 0x0d0d, 0x0d0e, 0x000f, 0x0010, 0x0017, 0x0d73, 0x0d76, 0x0076, 0x0d41,
        0x0d42, 0x0d7a, 0x0d19, 0x0d25, 0x0d20, 0x0d27, 0x0d29, 0x0d43, 0x0d49, 0x0d55,
        0x0dc2, 0x0058, 0x00d8, 0x00d9, 0x00da, 0x0050, 0x0db6, 0x00d2, 0x0d66, 0x008c,
        0x008d, 0x007a, 0x00d0, 0x0dc1, 0x0102, 0x0158, 0x0107, 0x0108, 0x0109, 0x010a,
        0x010b, 0x010c, 0x0428, 0x0429, 0x042a, 0x042b, 0x042c, 0x042d, 0x042e, 0x042f,
        0x0430, 0x0431, 0x0432, 0x0433, 0x0434, 0x0435, 0x0436, 0x0437, 0x0438, 0x0439,
        0x043a, 0x043b, 0x043c, 0x043d, 0x043e, 0x043f, 0x0077, 0x0078, 0x0079, 0x0067,
        0x0054, 0x0055, 0x0056, 0x0057, 0x005a, 0x005b, 0x0026, 0x0152, 0x0153, 0x0155,
        0x0410, 0x0411, 0x0412, 0x0413, 0x0414, 0x0415, 0x0416, 0x0417, 0x04e0, 0x0192,
        0x0194, 0x0195, 0x0196, 0x0197, 0x0198, 0x0201, 0x0202, 0x0203, 0x0204, 0x0212,
        0x0213, 0x0215, 0x0229, 0x0237, 0x023e,
    };
    char[GC2083_REG_COUNT] vals = {
        (char)0xf0, (char)0xf0, (char)0xf0, (char)0x00, (char)0x00, (char)0x00, (char)0x36, (char)0xc0, (char)0x24, (char)0x01,
        (char)0x32, (char)0x43, (char)0x8e, (char)0x07, (char)0x29, (char)0x18, (char)0x03, (char)0x01, (char)0xd4, (char)0x0d,
        (char)0x96, (char)0x02, (char)0x02, (char)0x05, (char)0xc9, (char)0x00, (char)0x11, (char)0x00, (char)0x02, (char)0x00,
        (char)0x02, (char)0x04, (char)0x40, (char)0x07, (char)0x90, (char)0x0c, (char)0x92, (char)0x00, (char)0x00, (char)0x04,
        (char)0x65, (char)0x10, (char)0x31, (char)0xcb, (char)0x60, (char)0x03, (char)0x60, (char)0x10, (char)0x10, (char)0x18,
        (char)0x44, (char)0x3c, (char)0x68, (char)0x14, (char)0xc1, (char)0x18, (char)0x3d, (char)0xbc, (char)0x42, (char)0x07,
        (char)0xff, (char)0x50, (char)0x00, (char)0x00, (char)0xa9, (char)0x00, (char)0xa6, (char)0xa9, (char)0xa8, (char)0xa7,
        (char)0xff, (char)0xff, (char)0x86, (char)0x86, (char)0x86, (char)0x68, (char)0x68, (char)0x68, (char)0x68, (char)0x68,
        (char)0x4f, (char)0x68, (char)0x67, (char)0x66, (char)0x66, (char)0x66, (char)0x66, (char)0x66, (char)0x62, (char)0x62,
        (char)0x62, (char)0x62, (char)0x62, (char)0x62, (char)0x62, (char)0x62, (char)0x01, (char)0x65, (char)0x04, (char)0xa0,
        (char)0xff, (char)0x02, (char)0x00, (char)0x04, (char)0xff, (char)0x07, (char)0x01, (char)0x02, (char)0x50, (char)0x93,
        (char)0x16, (char)0x16, (char)0x16, (char)0x16, (char)0x6f, (char)0x6f, (char)0x6f, (char)0x6f, (char)0x18, (char)0x04,
        (char)0x04, (char)0x04, (char)0x38, (char)0x07, (char)0x80, (char)0x27, (char)0x53, (char)0xce, (char)0x40, (char)0x07,
        (char)0x80, (char)0x12, (char)0x05, (char)0x03, (char)0x99,
    };
    for (int i = 0; i < GC2083_REG_COUNT; i++)
    {
        gc2083_reg_addr[i] = addrs[i];
        gc2083_reg_val[i] = vals[i];
    }
}

fn bool bring_up_sensor()
{
    io::print("cifinit: asserting SENSOR_RSTN (GPIOC8) low, then releasing...\n");
    if (!gpio_call(GPIO_IPC_SET_DIR, SENSOR_RSTN_BANK, SENSOR_RSTN_BIT, (char)1)) { return false; }
    if (!gpio_call(GPIO_IPC_WRITE, SENSOR_RSTN_BANK, SENSOR_RSTN_BIT, (char)0)) { return false; }
    sleep_ms(10);
    if (!gpio_call(GPIO_IPC_WRITE, SENSOR_RSTN_BANK, SENSOR_RSTN_BIT, (char)1)) { return false; }
    sleep_ms(10);

    char id_hi = 0;
    char id_lo = 0;
    int status = read_reg8(GC2083_CHIPID_REG, &id_hi);
    if (status == 0) { status = read_reg8(GC2083_CHIPID_REG + 1, &id_lo); }
    if (status != 0) { io::print("cifinit: FAIL — chip-ID read failed\n"); return false; }
    uint chip_id = ((uint)id_hi << 8) | (uint)id_lo;
    if (chip_id != 0x2083) { io::printfn("cifinit: FAIL — chip-ID = 0x%04x, not 0x2083", chip_id); return false; }
    io::print("cifinit: chip-ID OK (0x2083)\n");

    io::printfn("cifinit: writing %d mode-init registers (GC2083 1080p30 RAW10 2-lane)...", GC2083_REG_COUNT);
    sleep_ms(10);
    for (int i = 0; i < GC2083_REG_COUNT; i++)
    {
        int wstatus = write_reg8(gc2083_reg_addr[i], gc2083_reg_val[i]);
        if (wstatus != 0)
        {
            io::printfn("cifinit: FAIL — mode-init register %d/%d (addr 0x%04x)", i + 1, GC2083_REG_COUNT, gc2083_reg_addr[i]);
            return false;
        }
    }
    sleep_ms(80);
    io::print("cifinit: sensor mode-init OK\n");

    return true;
}

// *status_reg_out gets the MAC's own raw CSI_STATUS register (REG_0x440
// — error bits + CSI_DECODE_FORMAT, both datasheet-confirmed real).
// verb is CIF_IPC_GET_STATUS or CIF_IPC_STREAM_ENABLE — both share the
// same reply format (cifd.c3's own cifd_ipc_poll() always reports
// current status, whether or not this call also triggered the enable
// sequence first).
// *pd_ctrl_byte_out gets cifd's own reply[5]: PD_CTRL's IBIAS/RXLP bits
// shifted into one byte (bit0=ibias, bits[7:1]=rxlp) — see cifd.c3's
// own cifd_ipc_poll() comment on why this is on the wire instead of
// trusted from a print().
fn int cif_call(uint verb, char payload0, uint* status_reg_out, char* pd_ctrl_byte_out)
{
    if (ns_mount_wait("/srv/cifd/", "cifd", MOUNT_WAIT_ATTEMPTS) < 0)
    {
        io::print("cifinit: cifd not available\n");
        return -1;
    }
    char[CIF_IPC_MSG_MAX] req @noinit;
    req[0] = payload0;
    uint reply_verb = 0;
    int from = p9_call_path("/srv/cifd/", verb, &req[0], (int)CIF_IPC_MSG_MAX, &req[0], (int)CIF_IPC_MSG_MAX, &reply_verb);
    if (from <= 0 || reply_verb != verb) { io::print("cifinit: no reply from cifd\n"); return -1; }

    int status = (int)(char)req[0];
    *status_reg_out = (uint)(char)req[1] | ((uint)(char)req[2] << 8) | ((uint)(char)req[3] << 16) | ((uint)(char)req[4] << 24);
    *pd_ctrl_byte_out = req[5];
    return status;
}

// One 32-bit read through cifd's PEEK verb (req[0..3] = addr; reply[0] =
// 0 ok, reply[1..4] = value). Returns false (and prints) on failure.
fn bool cif_peek(uint addr, uint* out)
{
    char[CIF_IPC_MSG_MAX] req;
    for (int i = 0; i < 8; i++) { req[i] = i < 4 ? (char)(addr >> (8 * i)) : (char)0; }
    uint reply_verb = 0;
    int from = p9_call_path("/srv/cifd/", CIF_IPC_PEEK, &req[0], (int)CIF_IPC_MSG_MAX, &req[0], (int)CIF_IPC_MSG_MAX, &reply_verb);
    if (from <= 0 || reply_verb != CIF_IPC_PEEK || req[0] != 0) { io::print("cifinit: cifd PEEK failed\n"); return false; }
    *out = (uint)req[1] | ((uint)req[2] << 8) | ((uint)req[3] << 16) | ((uint)req[4] << 24);
    return true;
}

// The D-PHY's live lane state (csi_wrap0 +0x390): bit0 set while the clock
// lane is in HS, 0x4 = stop state, 0x2 = sensor held in reset. Readback
// only — undocumented in the public TRM, decoded from Linux-vs-racccoon
// snapshots streaming and stopped (docs/devlog.md 2026-10-18).
const uint WRAP_PHY_STATE = 0x0A0D0390;

// Receiver first, sensor second: the D-PHY only syncs on the clock lane's
// LP->HS start-of-transmission, which this continuous-clock sensor emits
// once, when its stream starts after reset + mode-init. Bringing the
// sensor up first and enabling the receiver under an already-running
// stream never locks (+0x390 stays in stop state) — that, together with
// the Linux receiver settings in cifd's cif_stream_enable(), is why this
// tool decoded nothing for months (docs/devlog.md 2026-10-18). No pn-swap: Milk-V's Linux
// streams with WRAP 0x308 = 0x3 (clock on pad 3, nothing swapped).
fn void main()
{
    gc2083_reg_table_init();

    // A re-run finds the sensor still streaming from last time; re-enabling
    // the receiver under a live HS stream leaves it unable to lock even
    // after the sensor's reset below. Stop the stream first (fails
    // harmlessly on a sensor that's still held in reset).
    write_reg8(0x023e, (char)0x00);
    sleep_ms(50);

    uint enable_status_reg = 0;
    char pd_ctrl_byte = 0;
    if (cif_call(CIF_IPC_STREAM_ENABLE, (char)0, &enable_status_reg, &pd_ctrl_byte) < 0) { return; } // already reported
    io::printfn("cifinit: cifd D-PHY receiver enabled (PD_CTRL ibias/rxlp byte = 0x%02x)", (uint)pd_ctrl_byte);

    if (!bring_up_sensor()) { return; }

    // CSI_STATUS is sticky — nothing found on the board clears it (not the
    // interrupt-clear bits, a write, nor a CSI MAC0 reset pulse) — so on a
    // re-run a decode_format alone could be last run's. Its ECC bits do
    // follow each packet header though, so a pass needs a clean ECC result
    // with the PHY in HS *now*. An ECC error while the sensor is still
    // coming up is transient: keep polling instead of failing on it.
    ulong hz = timebase_hz();
    ulong start = rdtime();
    ulong deadline = start + hz * 2;
    int status = -1;
    uint csi_status = 0;
    uint phy = 0;
    bool saw_error = false;
    while (rdtime() < deadline)
    {
        char unused_pd_byte = 0;
        status = cif_call(CIF_IPC_GET_STATUS, (char)0, &csi_status, &unused_pd_byte);
        if (status < 0) { return; } // already reported
        if (!cif_peek(WRAP_PHY_STATE, &phy)) { return; }
        if (status == CIF_STATUS_ERROR) { saw_error = true; }
        if (status == CIF_STATUS_LOCKED && (phy & 1) != 0) { break; }
        sleep_ms(20);
    }

    uint decode_fmt = (csi_status >> 16) & 0x3F;
    ulong ms = (rdtime() - start) / (hz / 1000);
    io::printfn("cifinit: CSI_STATUS (0x440) = 0x%08x (decode_format=0x%02x, status=%d), PHY state 0x%02x, after %d ms%s",
        csi_status, decode_fmt, status, phy, ms, saw_error ? " (transient ECC error seen first)" : "");
    if (status == CIF_STATUS_LOCKED && (phy & 1) != 0)
    {
        io::print("cifinit: PASS — D-PHY in HS, CSI-2 packets decoding with clean ECC\n");
    }
    else
    {
        io::print("cifinit: FAIL — no clean CSI-2 decode with the PHY in HS within 2s\n");
    }
}
