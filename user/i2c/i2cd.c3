module user;

import std::nolibc::main_stub;

// i2cd: driver for the CV1800B's I2C1 (Synopsys DesignWare APB I2C,
// "snps,designware-i2c" in cv180x_base.dtsi's own i2c1 node,
// @0x04010000) — the GC2083 camera's own bus, per Milk-V's own
// sensor_cfg_GC2083.ini (bus_id = 1). See boards/duo/board.c3's own
// camera comment for the full pin/register sourcing (this session's
// re-derivation off Milk-V's actual schematics, correcting an earlier
// wrong guess that used a sibling chip's pin map).
//
// Poll-only, same reasoning as gpiod/usbd/ethd: no PLIC interrupt
// wiring. IC_INTR_MASK is left at 0 (all masked) and every wait below
// is a bounded spin with its own timeout — never an unbounded loop —
// so a wedged bus degrades to "this one transfer failed", not a hang
// the supervisor has to notice and kill.
//
// Owns: the I2C1 controller's own MMIO page, plus (like every other
// driver on this shared page — sdd/usbd/ethd/gpiod) its own two direct
// writes on the shared PINMUX page for IIC1_SDA/IIC1_SCL, a defensive
// OR-in of the clk_i2c + clk_apb_i2c1 gate bits on the shared
// CLOCK_BASE page (same "OR the bit in, never assume, never clear
// anyone else's" pattern user/net/ethd.c3 already established for its
// own ETH_CLK_EN gating — clk_apb_i2c1 is CLK_IS_CRITICAL per
// linux_5.10/drivers/clk/cvitek/clk-cv180x.c so is probably already on,
// but clk_i2c itself (the shared SCL-timing generator all 5 I2C
// buses' masters use) is not marked critical there, so this driver
// can't assume it survived boot already enabled), and a same-pattern
// deassert of RST_I2C1 on the shared RESET_BASE page (same physical
// page usbd already maps for its own RST_USB bit) — see RESET_BASE's
// own comment: unlike SD/USB/ETH, no earlier boot stage ever uses I2C1,
// so nothing else could have deasserted it already. Found the hard way
// this session: clocks + pinmux alone left every register read/write
// silently succeeding but the actual transfer state machine dead —
// IC_STATUS's TFNF bit never set, timing out on the very first
// send — exactly reset-held-low's signature, not a timing or address
// problem.
//
// SENSOR_RSTN (GPIOC8) is NOT this driver's pin — that's gpiod's own
// allowlisted GPIO, toggled over IPC by whatever calls this driver
// (see user/bin/camtest.c3), matching the project's one-owner-per-
// real-device split.
//
// Real-hardware-verified 2026-09-12/13 (see docs/camera-plan.md /
// docs/devlog.md): camtest reads the GC2083's chip-ID (0x2083)
// correctly and repeatably. Getting there past RST_I2C1 (above) also
// needed two bugs in this file's own i2c_xfer(), both worth knowing
// about for any future DW I2C use: IC_TAR may only be programmed
// while the controller is disabled (silently ignored otherwise — see
// i2c_set_enable's own comment), and disabling isn't instant either,
// so that disable needs the same polled-status treatment as enabling.
// The third bug was in the caller, not here: this IP's own combined
// write+read transactions do NOT auto-increment the GC2083's internal
// register pointer across multiple read bytes (only writes get that,
// per the sensor's own datasheet) — a caller wanting N>1 registers
// needs N separate single-byte-read transactions, not one write-2/
// read-N call.

const uint I2C_REG_CON            = 0x00;
const uint I2C_REG_TAR             = 0x04;
const uint I2C_REG_DATA_CMD        = 0x10;
const uint I2C_REG_SS_SCL_HCNT     = 0x14;
const uint I2C_REG_SS_SCL_LCNT     = 0x18;
const uint I2C_REG_INTR_MASK       = 0x30;
const uint I2C_REG_RAW_INTR_STAT   = 0x34;
const uint I2C_REG_RX_TL           = 0x38;
const uint I2C_REG_TX_TL           = 0x3c;
const uint I2C_REG_CLR_TX_ABRT     = 0x54;
const uint I2C_REG_ENABLE          = 0x6c;
const uint I2C_REG_STATUS          = 0x70;
const uint I2C_REG_SDA_HOLD        = 0x7c;
const uint I2C_REG_TX_ABRT_SOURCE  = 0x80;
const uint I2C_REG_ENABLE_STATUS   = 0x9c;

const uint IC_CON_MASTER_MODE   = 0x0001;
const uint IC_CON_SPEED_STANDARD = 0x0002;
const uint IC_CON_RESTART_EN    = 0x0020;
const uint IC_CON_SLAVE_DISABLE = 0x0040;

const uint IC_DATA_CMD_CMD_READ = 0x0100; // 1 = read, 0 = write
const uint IC_DATA_CMD_STOP     = 0x0200;
const uint IC_DATA_CMD_RESTART  = 0x0400;

const uint IC_RAW_INTR_TX_ABRT  = 0x0040;

const uint IC_STATUS_TFNF = 0x0002; // TX FIFO not full
const uint IC_STATUS_RFNE = 0x0008; // RX FIFO not empty

const uint IC_ENABLE_ON  = 0x0001;

// SS_SCL_HCNT/LCNT/SDA_HOLD below were computed by the DesignWare
// databook's own back-solve formula (same one
// u-boot-2021.10/drivers/i2c/designware_i2c.c's dw_i2c_calc_timing()
// implements) for 100kHz standard mode assuming clk_i2c = 25MHz — this
// project's own already-established real-timebase constant
// (board::TIMEBASE_HZ / SD_TIMEBASE_HZ / GPIOD_TIMEBASE_HZ all agree
// on 25MHz, and clk_i2c's own devicetree parent list is ("osc",
// "clk_axi6") with "osc" = the board's 25MHz crystal per
// duo-schematic-v1.2.pdf's own SYS XTAL sheet — a reset-default mux
// pick, not independently confirmed on real hardware). If chip-ID
// reads never ACK, this assumption — not the register sequence — is
// the first thing to re-check (a wrong clk_i2c just gives the wrong
// actual SCL frequency, not necessarily a dead bus, so this is a
// plausible-but-unverified value, not a guess pulled from nowhere).
const uint I2C_SS_SCL_HCNT = 101;
const uint I2C_SS_SCL_LCNT = 116;
const uint I2C_SDA_HOLD_CNT = 8;

// mmio_read32 / mmio_write32: user/user.c3 (shared).

// board is a kernel-only module (unreachable from user code) — same
// duplicated-by-hand convention as every other driver's own copy of
// its MMIO base (sdhci.c3's CLOCK_BASE, gpiod.c3's GPIO_PINMUX_BASE,
// etc.). Must match boards/duo/board.c3's own I2C1_MMIO_BASE.
const uint I2C1_MMIO_BASE = 0x04010000;

fn uint i2c_reg_read(uint offset) { return mmio_read32((uptr)(I2C1_MMIO_BASE + offset)); }
fn void i2c_reg_write(uint offset, uint v) { mmio_write32((uptr)(I2C1_MMIO_BASE + offset), v); }

const uint PINMUX_BASE = 0x03001000; // GPIO_PINMUX_BASE/PINMUX_BASE's own shared physical page, see board.c3's camera comment
const uint CLOCK_BASE  = 0x03002000; // same physical page sdd/ethd/gpiod each independently map for their own bits
// Same physical page usbd already maps for its own RST_USB bit (see
// board::USB_TOP_RST_PAGE's comment) — cvitek's reset controller
// (linux_5.10/drivers/reset/reset-cvitek.c's own bm_reset_deassert:
// bank = id/32, bit = id%32, SET the bit to deassert/run, clear to
// hold in reset). RST_I2C1 = index 28 (cv180x-resets.h), so bank 0,
// bit 28 — same register RST_USB's bit 11 lives in.
const uint RESET_BASE  = 0x03003000;

fn uint pinmux_reg_read(uint offset) { return mmio_read32((uptr)(PINMUX_BASE + offset)); }
fn void pinmux_reg_write(uint offset, uint v) { mmio_write32((uptr)(PINMUX_BASE + offset), v); }
fn uint clock_reg_read(uint offset) { return mmio_read32((uptr)(CLOCK_BASE + offset)); }
fn void clock_reg_write(uint offset, uint v) { mmio_write32((uptr)(CLOCK_BASE + offset), v); }
fn uint reset_reg_read(uint offset) { return mmio_read32((uptr)(RESET_BASE + offset)); }
fn void reset_reg_write(uint offset, uint v) { mmio_write32((uptr)(RESET_BASE + offset), v); }

const uint REG_CLK_EN_3       = 0x00c;
const uint CLK_EN_3_I2C_BIT     = 1u << 7;  // clk_i2c — shared SCL-timing generator, not CLK_IS_CRITICAL
const uint CLK_EN_3_APB_I2C1_BIT = 1u << 18; // clk_apb_i2c1 — register interface, already CLK_IS_CRITICAL

const uint REG_SOFT_RST_0  = 0x000;
const uint SOFT_RST_0_I2C1_BIT  = 1u << 28; // RST_I2C1 (cv180x-resets.h index 28)
const uint SOFT_RST_0_VIPSYS_BIT = 1u << 6;  // RST_VIPSYS (index 6) — untried guess: the whole
                                              // video-input subsystem's own reset, separate from
                                              // I2C1's, might also gate clk_cam0 actually reaching
                                              // its pad even with the clock enabled and pinmuxed.

const uint IIC1_SDA_FUNCSEL_OFFSET = 0xf0; // PAD_MIPIRX1P
const uint IIC1_SCL_FUNCSEL_OFFSET = 0xf4; // PAD_MIPIRX0N
const uint IIC_FUNCSEL_VALUE       = 4;    // IIC1_SDA / IIC1_SCL alt function

// SENSOR_CLK/CAM_MCLK0 (PAD_MIPIRX0P, pin 65) — the GC2083's own
// external reference clock, generated by clk_cam0 (REG_CLK_EN_2 bit
// 16 gates it; REG_CLK_CAM0_SRC_DIV's own mux+divider pick its actual
// rate, already programmed by FSBL at boot — see i2c_bus_init's own
// comment). Not part of the MIPI CSI-2 lanes at all (2 data lanes +
// 1 clock lane, a completely separate differential interface) —
// this is a plain single-ended clock the SoC feeds *to* the sensor so
// its own internal logic (including, evidently, its I2C slave) has
// something to run on.
const uint CAM_MCLK0_FUNCSEL_OFFSET = 0xf8;
const uint CAM_MCLK0_FUNCSEL_VALUE  = 4;

const uint REG_CLK_EN_2      = 0x008;
const uint CLK_EN_2_CAM0_BIT = 1u << 16; // clk_cam0 gate

// Read-modify-write: only bits [2:0] select the pad's own alternate
// function, same convention gpiod.c3's own gpio_configure_pinmux uses.
fn void configure_pinmux(uint offset, uint value)
{
    uint reg = pinmux_reg_read(offset);
    reg = (reg & ~(uint)0x7) | (value & 0x7);
    pinmux_reg_write(offset, reg);
}

// u-boot-2021.10/drivers/i2c/designware_i2c.c's own dw_i2c_enable():
// IC_ENABLE_STATUS bit0 follows IC_ENABLE, but not instantly — poll it
// (bounded) rather than assume either direction of the write landed
// immediately. Matters for *disable* just as much as enable: a caller
// that writes IC_TAR right after requesting disable, without waiting
// for IC_ENABLE_STATUS to actually clear, can still lose that write
// the same way writing IC_TAR while enabled does.
fn void i2c_set_enable(bool enable)
{
    uint target = enable ? IC_ENABLE_ON : 0;
    i2c_reg_write(I2C_REG_ENABLE, target);
    for (uint i = 0; i < 1000; i++)
    {
        if ((i2c_reg_read(I2C_REG_ENABLE_STATUS) & IC_ENABLE_ON) == target) { return; }
    }
}

fn void i2c_bus_init()
{
    // Defensive clock-gate OR-in — see this file's own top comment.
    uint clk_en_3 = clock_reg_read(REG_CLK_EN_3);
    clk_en_3 |= CLK_EN_3_I2C_BIT | CLK_EN_3_APB_I2C1_BIT;
    clock_reg_write(REG_CLK_EN_3, clk_en_3);
    print("i2cd: REG_CLK_EN_3 readback=0x"); print_hex32(clock_reg_read(REG_CLK_EN_3)); print("\n");

    // Deassert RST_I2C1 — see RESET_BASE's own comment. Unlike SD/USB/
    // ETH (which some earlier boot stage already uses and so already
    // deasserts), nothing before this driver has ever touched I2C1, so
    // it may still be sitting in its power-on-reset default.
    uint soft_rst_0 = reset_reg_read(REG_SOFT_RST_0);
    soft_rst_0 |= SOFT_RST_0_I2C1_BIT | SOFT_RST_0_VIPSYS_BIT;
    reset_reg_write(REG_SOFT_RST_0, soft_rst_0);
    print("i2cd: REG_SOFT_RST_0 readback=0x"); print_hex32(reset_reg_read(REG_SOFT_RST_0)); print("\n");

    configure_pinmux(IIC1_SDA_FUNCSEL_OFFSET, IIC_FUNCSEL_VALUE);
    configure_pinmux(IIC1_SCL_FUNCSEL_OFFSET, IIC_FUNCSEL_VALUE);
    print("i2cd: IIC1_SDA funcsel readback=0x"); print_hex32(pinmux_reg_read(IIC1_SDA_FUNCSEL_OFFSET)); print("\n");
    print("i2cd: IIC1_SCL funcsel readback=0x"); print_hex32(pinmux_reg_read(IIC1_SCL_FUNCSEL_OFFSET)); print("\n");

    // SENSOR_CLK bring-up — see CAM_MCLK0_FUNCSEL_OFFSET's own comment.
    // The live register dump this session showed FSBL already
    // programs MIPIMPLL (900MHz) and CAM0PLL (~594MHz) at boot,
    // regardless of whether anything uses them — clk_cam0's own
    // mux+divider (REG_CLK_CAM0_SRC_DIV) was also already sitting at a
    // real (not power-on-default) value, computing to ~18.5625MHz.
    // Nothing has ever gated the clock on or routed it to its actual
    // pin, though: REG_CLK_EN_2 bit 16 and this pad's own funcsel both
    // still need setting. Not reprogramming any PLL — reusing whatever
    // FSBL already set up.
    configure_pinmux(CAM_MCLK0_FUNCSEL_OFFSET, CAM_MCLK0_FUNCSEL_VALUE);
    print("i2cd: CAM_MCLK0 funcsel readback=0x"); print_hex32(pinmux_reg_read(CAM_MCLK0_FUNCSEL_OFFSET)); print("\n");
    uint clk_en_2 = clock_reg_read(REG_CLK_EN_2);
    clk_en_2 |= CLK_EN_2_CAM0_BIT;
    clock_reg_write(REG_CLK_EN_2, clk_en_2);
    print("i2cd: REG_CLK_EN_2 readback=0x"); print_hex32(clock_reg_read(REG_CLK_EN_2)); print("\n");

    i2c_set_enable(false); // disable before reconfiguring, per databook
    i2c_reg_write(I2C_REG_INTR_MASK, 0); // poll-only, nothing unmasked
    i2c_reg_write(I2C_REG_CON, IC_CON_MASTER_MODE | IC_CON_SPEED_STANDARD | IC_CON_RESTART_EN | IC_CON_SLAVE_DISABLE);
    i2c_reg_write(I2C_REG_SS_SCL_HCNT, I2C_SS_SCL_HCNT);
    i2c_reg_write(I2C_REG_SS_SCL_LCNT, I2C_SS_SCL_LCNT);
    i2c_reg_write(I2C_REG_SDA_HOLD, I2C_SDA_HOLD_CNT);
    i2c_reg_write(I2C_REG_RX_TL, 0);
    i2c_reg_write(I2C_REG_TX_TL, 0);
    i2c_set_enable(true);

    print("i2cd: IC_ENABLE_STATUS readback=0x"); print_hex32(i2c_reg_read(I2C_REG_ENABLE_STATUS)); print("\n");
    print("i2cd: IC_STATUS readback=0x"); print_hex32(i2c_reg_read(I2C_REG_STATUS)); print("\n");

    print("i2cd: I2C1 @ 0x04010000 initialized, 100kHz standard mode\n");
}

// Bounded spins — every wait in this driver has one, so a wedged bus
// (or an absent/unpowered sensor that never releases the ack-less
// bus) fails one transfer instead of hanging this process forever.
const uint I2C_POLL_ITERS = 200000;

const int I2C_XFER_OK      = 0;
const int I2C_XFER_ABORT   = 1; // NAK or other IC_TX_ABRT condition
const int I2C_XFER_TIMEOUT = 2;

// Writes write_len bytes from wbuf, then (combined restart, same
// transaction) reads read_len bytes into rbuf. Either length may be 0
// (a pure write or a pure read). This is exactly the GC2083's own
// 16-bit-register-address read idiom: write_len=2 (reg addr hi/lo),
// read_len=1 or 2 (the register's own data byte(s)).
// Drains + clears a latched TX_ABRT (read-to-clear, per the databook —
// IC_TX_ABRT_SOURCE's own cause bits aren't decoded, just drained so
// the clear actually takes).
fn void clear_tx_abrt()
{
    i2c_reg_read(I2C_REG_TX_ABRT_SOURCE);
    i2c_reg_read(I2C_REG_CLR_TX_ABRT);
}

fn int i2c_xfer(uint addr7, char* wbuf, int write_len, char* rbuf, int read_len)
{
    // IC_TAR may only be programmed while the controller is disabled —
    // DesignWare databook, and confirmed by u-boot-2021.10/drivers/i2c/
    // designware_i2c.c's own i2c_setaddress(): disable, write IC_TAR,
    // re-enable. This driver's own i2c_bus_init() enables the
    // controller once at boot and this function used to write IC_TAR
    // afterwards, with no disable/enable cycle around it — on real
    // silicon that write is ignored, so every transfer this session
    // was very likely still addressing whatever IC_TAR held at reset
    // (not 0x37), a NAK indistinguishable from "sensor not there" no
    // matter what else got fixed elsewhere. i2c_set_enable() (not a
    // bare register write either side) matters here too: disabling
    // isn't instant, and writing IC_TAR before IC_ENABLE_STATUS
    // actually clears is the same class of lost-write bug.
    i2c_set_enable(false);
    i2c_reg_write(I2C_REG_TAR, addr7 & 0x7f);
    i2c_set_enable(true);

    int total = write_len + read_len;
    for (int i = 0; i < total; i++)
    {
        // Wait for room in the TX FIFO — checking TX_ABRT in the same
        // loop, not just once right after the write below: a NAK from
        // a *previous* byte takes real bus time (an ACK/NAK bit is
        // only sampled after that byte's own 8 data bits are clocked
        // out) to actually land in IC_RAW_INTR_STAT, so a single
        // immediate check the instruction after writing IC_DATA_CMD is
        // far too early — it was reading "no abort yet", not "no
        // abort ever", the actual bug this session's first two
        // real-hardware attempts both hit (a false OK/timeout instead
        // of the correct ABORT).
        uint iters = 0;
        while ((i2c_reg_read(I2C_REG_STATUS) & IC_STATUS_TFNF) == 0)
        {
            if ((i2c_reg_read(I2C_REG_RAW_INTR_STAT) & IC_RAW_INTR_TX_ABRT) != 0)
            {
                clear_tx_abrt();
                return I2C_XFER_ABORT;
            }
            if (++iters > I2C_POLL_ITERS)
            {
                print("i2cd: xfer timeout waiting TFNF — IC_STATUS=0x"); print_hex32(i2c_reg_read(I2C_REG_STATUS));
                print(" IC_ENABLE_STATUS=0x"); print_hex32(i2c_reg_read(I2C_REG_ENABLE_STATUS));
                print(" IC_RAW_INTR_STAT=0x"); print_hex32(i2c_reg_read(I2C_REG_RAW_INTR_STAT));
                print("\n");
                return I2C_XFER_TIMEOUT;
            }
        }

        uint cmd;
        if (i < write_len)
        {
            cmd = (uint)(char)wbuf[i];
        }
        else
        {
            cmd = IC_DATA_CMD_CMD_READ;
            // RESTART on the first command that switches direction
            // (either the very first command overall, if this is a
            // pure read, or the first read after some writes).
            if (i == write_len) { cmd |= IC_DATA_CMD_RESTART; }
        }
        if (i == total - 1) { cmd |= IC_DATA_CMD_STOP; }

        i2c_reg_write(I2C_REG_DATA_CMD, cmd);

        if (i >= write_len)
        {
            // Same reasoning as the TFNF wait above: poll for RFNE
            // *or* TX_ABRT together, not a one-shot check — an
            // aborted read never produces RX data, so without this
            // the abort would otherwise only surface as a timeout
            // here (a real bus problem) instead of ABORT (a NAK).
            uint iters2 = 0;
            while ((i2c_reg_read(I2C_REG_STATUS) & IC_STATUS_RFNE) == 0)
            {
                if ((i2c_reg_read(I2C_REG_RAW_INTR_STAT) & IC_RAW_INTR_TX_ABRT) != 0)
                {
                    clear_tx_abrt();
                    return I2C_XFER_ABORT;
                }
                if (++iters2 > I2C_POLL_ITERS)
                {
                    print("i2cd: xfer timeout waiting RFNE — IC_STATUS=0x"); print_hex32(i2c_reg_read(I2C_REG_STATUS));
                    print(" IC_RAW_INTR_STAT=0x"); print_hex32(i2c_reg_read(I2C_REG_RAW_INTR_STAT));
                    print("\n");
                    return I2C_XFER_TIMEOUT;
                }
            }
            rbuf[i - write_len] = (char)i2c_reg_read(I2C_REG_DATA_CMD);
        }
    }

    // One last check: a pure-write transfer (read_len=0) never enters
    // either poll loop above after its final byte, so an abort on the
    // very last byte would otherwise go unnoticed and this function
    // would wrongly report OK.
    if ((i2c_reg_read(I2C_REG_RAW_INTR_STAT) & IC_RAW_INTR_TX_ABRT) != 0)
    {
        clear_tx_abrt();
        return I2C_XFER_ABORT;
    }
    return I2C_XFER_OK;
}

// Wire protocol (see user/bin/camtest.c3's own hand-kept copy, same
// "kept in sync by hand" convention as DISKD_READ/WRITE and gpiod's
// own GPIO_IPC_* — the request is 8 bytes: byte0 = 7-bit device
// address, byte1 = write_len (0-4), byte2 = read_len (0-4), bytes
// 3..6 = write data. Reply is 8 bytes: byte0 = status (I2C_XFER_*
// above), bytes 1..4 = read data.
const uint I2C_IPC_XFER    = 1;
const uint I2C_IPC_MSG_MAX = 8;

fn void i2cd_ipc_poll()
{
    char[I2C_IPC_MSG_MAX] buf @noinit;
    uint verb = 0;
    int from = ipc_poll_type(&buf[0], (int)I2C_IPC_MSG_MAX, &verb);
    if (from < 0) { return; }
    if (verb != I2C_IPC_XFER) { return; }

    uint addr7 = (uint)(char)buf[0];
    int write_len = (int)(char)buf[1];
    int read_len = (int)(char)buf[2];
    if (write_len < 0 || write_len > 4 || read_len < 0 || read_len > 4)
    {
        write_len = 0;
        read_len = 0;
    }

    char[4] wbuf @noinit;
    for (int i = 0; i < 4; i++) { wbuf[i] = buf[3 + i]; }
    char[4] rbuf @noinit;
    for (int i = 0; i < 4; i++) { rbuf[i] = (char)0; }

    int status = i2c_xfer(addr7, &wbuf[0], write_len, &rbuf[0], read_len);

    char[I2C_IPC_MSG_MAX] reply @noinit;
    reply[0] = (char)status;
    for (int i = 0; i < 4; i++) { reply[1 + i] = rbuf[i]; }

    ipc_reply(from, verb, &reply[0], (int)I2C_IPC_MSG_MAX, 0);
}

fn void main()
{
    i2c_bus_init();

    // Same dynamic srv_post()/ns_mount_wait() two-step gpiod.c3/usbd.c3
    // already established — this pid isn't fixed.
    srv_post("i2cd");
    print("i2cd: init done\n");

    for (;;)
    {
        i2cd_ipc_poll();
        yield();
    }
}
