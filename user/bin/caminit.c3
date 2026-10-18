module user;

import std::io;

// Stage 2 of docs/camera-plan.md: the GC2083's full mode register
// script (1920x1080p30, RAW10, 2-lane MIPI) — "streaming blind": no
// MIPI receiver is up yet (that's Stage 3), this only proves the
// sensor accepts its whole real init sequence over I2C without ever
// NAKing partway through, then reads a couple of registers back to
// confirm the writes actually landed (not just "every transfer
// returned OK", since a register could in principle always read back
// its own reset value regardless of what's written to it).
//
// The register table below is transcribed byte-for-byte from Milk-V's
// own vendor sensor driver
// (middleware/v2/component/isp/sensor/cv180x/gcore_gc2083/
// gc2083_sensor_ctl.c's own gc2083_linear_1080p30_init(), duo-
// buildroot-sdk) — not derived or guessed, the exact sequence real
// production firmware writes for this exact mode. The three
// consecutive 0x03fe=0xf0 writes followed by 0x03fe=0x00 are the
// vendor's own page-select/soft-reset dance, kept exactly as-is rather
// than "simplified" to one write — GalaxyCore sensors are known to
// need the repeated toggle. Omits gc2083_default_reg_init()'s own
// loop (an optional runtime-supplied calibration overlay, empty by
// default, no fixed content to transcribe).
//
// Same reset-then-I2C flow as user/bin/camtest.c3 (its own Stage-1
// tool) — the two files duplicate the small IPC-protocol/reset-pulse
// plumbing by hand rather than sharing it, same convention this
// project already uses for gpiod/i2cd's own wire-protocol constants
// across every caller.

const uint GPIO_IPC_SET_DIR = 1;
const uint GPIO_IPC_WRITE   = 2;
const uint GPIO_IPC_MSG_MAX = 8;

const uint I2C_IPC_XFER    = 1;
const uint I2C_IPC_MSG_MAX = 8;

const ulong MOUNT_WAIT_ATTEMPTS = 20;

const char SENSOR_RSTN_BANK = 'C';
const int  SENSOR_RSTN_BIT  = 8;
const uint GC2083_I2C_ADDR  = 0x37;
const uint GC2083_CHIPID_REG = 0x03f0;

fn bool gpio_call(uint verb, char bank_letter, int bit, char arg)
{
    if (ns_mount_wait("/srv/gpiod/", "gpiod", MOUNT_WAIT_ATTEMPTS) < 0)
    {
        io::print("caminit: gpiod not available\n");
        return false;
    }

    char[GPIO_IPC_MSG_MAX] req @noinit;
    req[0] = bank_letter;
    req[1] = (char)bit;
    req[2] = arg;

    uint reply_verb = 0;
    int from = p9_call_path("/srv/gpiod/", verb, &req[0], (int)GPIO_IPC_MSG_MAX, &req[0], (int)GPIO_IPC_MSG_MAX, &reply_verb);
    if (from <= 0 || reply_verb != verb)
    {
        io::print("caminit: no reply from gpiod\n");
        return false;
    }
    if (req[0] != 0)
    {
        io::print("caminit: GPIOC8 not in gpiod's own allowlist (unexpected)\n");
        return false;
    }
    return true;
}

// status: 0 ok, 1 = NAK/abort, 2 = timeout, <0 = no reply from i2cd.
fn int i2c_xfer_call(uint addr7, char* wbuf, int write_len, char* rbuf, int read_len)
{
    if (ns_mount_wait("/srv/i2cd/", "i2cd", MOUNT_WAIT_ATTEMPTS) < 0)
    {
        io::print("caminit: i2cd not available\n");
        return -1;
    }

    char[I2C_IPC_MSG_MAX] req @noinit;
    req[0] = (char)addr7;
    req[1] = (char)write_len;
    req[2] = (char)read_len;
    for (int i = 0; i < 4; i++) { req[3 + i] = i < write_len ? wbuf[i] : (char)0; }

    uint reply_verb = 0;
    int from = p9_call_path("/srv/i2cd/", I2C_IPC_XFER, &req[0], (int)I2C_IPC_MSG_MAX, &req[0], (int)I2C_IPC_MSG_MAX, &reply_verb);
    if (from <= 0 || reply_verb != I2C_IPC_XFER)
    {
        io::print("caminit: no reply from i2cd\n");
        return -1;
    }

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

// 3-byte transaction: 2-byte register address + 1 data byte, no read.
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

fn void main()
{
    gc2083_reg_table_init();

    io::print("caminit: asserting SENSOR_RSTN (GPIOC8) low, then releasing...\n");
    if (!gpio_call(GPIO_IPC_SET_DIR, SENSOR_RSTN_BANK, SENSOR_RSTN_BIT, (char)1)) { return; }
    if (!gpio_call(GPIO_IPC_WRITE, SENSOR_RSTN_BANK, SENSOR_RSTN_BIT, (char)0)) { return; }
    sleep_ms(10);
    if (!gpio_call(GPIO_IPC_WRITE, SENSOR_RSTN_BANK, SENSOR_RSTN_BIT, (char)1)) { return; }
    sleep_ms(10);

    char id_hi = 0;
    char id_lo = 0;
    int status = read_reg8(GC2083_CHIPID_REG, &id_hi);
    if (status == 0) { status = read_reg8(GC2083_CHIPID_REG + 1, &id_lo); }
    if (status != 0) { io::print("caminit: FAIL — chip-ID read failed before mode init even started\n"); return; }
    uint chip_id = ((uint)id_hi << 8) | (uint)id_lo;
    if (chip_id != 0x2083) { io::printfn("caminit: FAIL — chip-ID = 0x%04x, not 0x2083", chip_id); return; }
    io::print("caminit: chip-ID OK (0x2083)\n");

    io::printfn("caminit: writing %d mode-init registers (GC2083 1080p30 RAW10 2-lane)...", GC2083_REG_COUNT);
    // delay_ms(10) before the table in the vendor driver — matches
    // gc2083_linear_1080p30_init()'s own opening delay.
    sleep_ms(10);
    for (int i = 0; i < GC2083_REG_COUNT; i++)
    {
        int wstatus = write_reg8(gc2083_reg_addr[i], gc2083_reg_val[i]);
        if (wstatus != 0)
        {
            io::printfn("caminit: FAIL — register %d/%d (addr 0x%04x) %s",
                i + 1, GC2083_REG_COUNT, gc2083_reg_addr[i],
                wstatus == 1 ? "NAK/abort" : wstatus == 2 ? "timeout" : "no reply");
            return;
        }
    }
    // delay_ms(80) after the table in the vendor driver.
    sleep_ms(80);
    io::print("caminit: all registers written OK\n");

    // Verify: re-read chip-ID (sensor still alive/responsive after
    // ~140 writes) and the last table entry (0x023e, expected 0x99) —
    // confirms writes actually land, not just "every transfer
    // returned OK" (some registers could in principle be write-only
    // strobes that always read back their own reset value regardless).
    status = read_reg8(GC2083_CHIPID_REG, &id_hi);
    if (status == 0) { status = read_reg8(GC2083_CHIPID_REG + 1, &id_lo); }
    if (status != 0) { io::print("caminit: FAIL — chip-ID re-read failed after mode init\n"); return; }
    chip_id = ((uint)id_hi << 8) | (uint)id_lo;

    uint last_addr = gc2083_reg_addr[GC2083_REG_COUNT - 1];
    char last_expected = gc2083_reg_val[GC2083_REG_COUNT - 1];
    char last_readback = 0;
    // 0x023e (stream on) can read back late: at the MCLK Linux uses (i2cd's
    // CLK_CAM0_SRC_DIV_LINUX) it read 0x48 right after the write, the written
    // value shortly after. Re-read for up to ~200 ms before calling it.
    for (int tries = 0; tries < 10; tries++)
    {
        status = read_reg8(last_addr, &last_readback);
        if (status != 0) { io::print("caminit: FAIL — readback of last register failed\n"); return; }
        if (last_readback == last_expected) { break; }
        sleep_ms(20);
    }

    io::printfn("caminit: post-init chip-ID = 0x%04x, register 0x%04x = 0x%02x (wrote 0x%02x)",
        chip_id, last_addr, (uint)last_readback, (uint)last_expected);

    if (chip_id == 0x2083 && last_readback == last_expected)
    {
        io::print("caminit: PASS — sensor accepted the full mode-init sequence\n");
    }
    else
    {
        io::print("caminit: FAIL — post-init verification mismatch\n");
    }
}
