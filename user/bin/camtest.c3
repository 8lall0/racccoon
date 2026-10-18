module user;

import std::io;

// First real milestone of docs/camera-plan.md's staged bring-up:
// power-on reset the CAM-GC2083 (SENSOR_RSTN, GPIOC8, over gpiod) then
// read its chip-ID over I2C1 (over i2cd) and check it against the
// datasheet's known value (0x2083 at register 0x03f0/0x03f1, 16-bit
// register address, 8-bit data, 7-bit I2C address 0x37 — Milk-V's own
// sensor_cfg_GC2083.ini). No mode-register script, no MIPI/vi
// involvement yet — just "is the sensor there and does it answer".
//
// Talks to both drivers over the dynamic srv_post()/ns_mount_wait()
// mechanism, same as gpio.c3/usbrw.c3 already established — neither
// driver's pid is fixed.

// Wire protocol constants — kept in sync by hand with
// user/gpio/gpiod.c3 and user/i2c/i2cd.c3's own copies, same
// convention as gpio.c3's own header comment on this.
const uint GPIO_IPC_SET_DIR = 1;
const uint GPIO_IPC_WRITE   = 2;
const uint GPIO_IPC_MSG_MAX = 8;

const uint I2C_IPC_XFER    = 1;
const uint I2C_IPC_MSG_MAX = 8;

const ulong MOUNT_WAIT_ATTEMPTS = 20;

const char SENSOR_RSTN_BANK = 'C';
const int  SENSOR_RSTN_BIT  = 8;
const uint GC2083_I2C_ADDR  = 0x37;
const uint GC2083_CHIPID_REG = 0x03f0; // 2 bytes, big-endian: 0x20 0x83

fn bool gpio_call(uint verb, char bank_letter, int bit, char arg)
{
    if (ns_mount_wait("/srv/gpiod/", "gpiod", MOUNT_WAIT_ATTEMPTS) < 0)
    {
        io::print("camtest: gpiod not available\n");
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
        io::print("camtest: no reply from gpiod\n");
        return false;
    }
    if (req[0] != 0)
    {
        io::print("camtest: GPIOC8 not in gpiod's own allowlist (unexpected)\n");
        return false;
    }
    return true;
}

// status: 0 ok, 1 = NAK/abort, 2 = timeout, <0 = no reply from i2cd.
fn int i2c_xfer_call(uint addr7, char* wbuf, int write_len, char* rbuf, int read_len)
{
    if (ns_mount_wait("/srv/i2cd/", "i2cd", MOUNT_WAIT_ATTEMPTS) < 0)
    {
        io::print("camtest: i2cd not available\n");
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
        io::print("camtest: no reply from i2cd\n");
        return -1;
    }

    int status = (int)(char)req[0];
    for (int i = 0; i < read_len && i < 4; i++) { rbuf[i] = req[1 + i]; }
    return status;
}

// One register at a time, each its own full (write 2-byte address,
// restart, read 1 byte) transaction — the GC2083 datasheet's own
// "Single Register Reading" diagram (S 6eH A RegAddr A S 6fH A Data NA
// P) shows no auto-increment for reads (only "Incremental Register
// Writing" gets that treatment), confirmed the hard way this session:
// a combined write-2/read-2 transaction returned the SAME first byte
// twice (chip-ID read back as 0x2020 — 0x20 alone is the correct high
// byte of 0x2083, the low-byte read just never advanced).
// status: 0 ok, 1 = NAK/abort, 2 = timeout, <0 = no reply; *out_byte
// only valid on status==0.
fn int read_reg8(uint reg_addr, char* out_byte)
{
    char[2] reg @noinit;
    reg[0] = (char)((reg_addr >> 8) & 0xff);
    reg[1] = (char)(reg_addr & 0xff);
    return i2c_xfer_call(GC2083_I2C_ADDR, &reg[0], 2, out_byte, 1);
}

fn void sleep_ms(ulong ms)
{
    ulong hz = timebase_hz();
    ulong deadline = rdtime() + (hz / 1000) * ms;
    while (rdtime() < deadline) { yield(); }
}

fn void main()
{
    io::print("camtest: asserting SENSOR_RSTN (GPIOC8) low, then releasing...\n");
    if (!gpio_call(GPIO_IPC_SET_DIR, SENSOR_RSTN_BANK, SENSOR_RSTN_BIT, (char)1)) { return; } // output
    if (!gpio_call(GPIO_IPC_WRITE, SENSOR_RSTN_BANK, SENSOR_RSTN_BIT, (char)0)) { return; }    // reset asserted (active-low)
    sleep_ms(10);
    if (!gpio_call(GPIO_IPC_WRITE, SENSOR_RSTN_BANK, SENSOR_RSTN_BIT, (char)1)) { return; }    // release
    sleep_ms(10); // GC2083 datasheet power-up sequencing isn't in hand yet — a generous guess

    io::print("camtest: reading GC2083 chip-ID over I2C1 (addr 0x37, regs 0x03f0/0x03f1)...\n");
    char id_hi = 0;
    char id_lo = 0;
    int status = read_reg8(GC2083_CHIPID_REG, &id_hi);
    if (status == 0) { status = read_reg8(GC2083_CHIPID_REG + 1, &id_lo); }

    if (status < 0) { return; } // already reported
    if (status == 1) { io::print("camtest: FAIL — I2C NAK/abort (no ACK from 0x37 — sensor absent, unpowered, or wrong bus timing)\n"); return; }
    if (status == 2) { io::print("camtest: FAIL — I2C timeout (bus wedged / SDA or SCL stuck)\n"); return; }

    uint chip_id = ((uint)id_hi << 8) | (uint)id_lo;
    io::printfn("camtest: chip-ID = 0x%04x (expected 0x2083)", chip_id);
    if (chip_id == 0x2083)
    {
        io::print("camtest: PASS\n");
    }
    else
    {
        io::print("camtest: FAIL — unexpected chip-ID\n");
    }
}
