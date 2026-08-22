module user;

// usbd: USB host-controller driver for the Milk-V Duo — Phase 1 only
// (see docs/devlog.md and the plan file this was built from). Scope,
// deliberately narrow: bring the Synopsys DesignWare USB2 OTG core
// ("DWC2") up into host mode, power the port, and observe the host
// port status register (HPRT0)'s own connect-status bit change when a
// real USB device is plugged/unplugged. NOT in scope yet: device
// enumeration, control transfers, mass storage, interrupts (pure
// polling — see IRQ_USB's own comment in boards/duo/board.c3 for why:
// the SDHCI PLIC-enable claim-storm bug user/sdd.c3 already hit once
// is exactly the kind of mistake this avoids repeating on a still
// barely-understood peripheral).
//
// Register offsets/bit layouts below are sourced directly from
// duo-buildroot-sdk's own driver code, read directly this session —
// not reverse-engineered, not secondary documentation:
//   - DWC2 core registers: u-boot-2021.10/drivers/usb/host/dwc2.c/.h
//     (the generic DWC2 host driver CV1800B's own devicetree binds to
//     unmodified — "cvitek,cv182x-usb" only changes software
//     parameters, linux_5.10/drivers/usb/dwc2/params.c, never register
//     addresses).
//   - TOP-block SoC-specific registers: u-boot-2021.10/board/cvitek/
//     cv180x/board.c and cv180x_reg.h. Confirmed: the devicetree's own
//     second `reg` range for this device (0x03006000, "USB 2.0 PHY" in
//     the source comment) is never actually written by any driver in
//     that SDK — not used here at all. The real SoC-specific registers
//     this driver needs live in the TOP control block instead
//     (board::USB_TOP_CTRL_PAGE/USB_TOP_RST_PAGE, boards/duo/board.c3).
//
// Expect real-hardware iteration here — this is a careful port of
// sourced values, not something exercised against real silicon yet (no
// QEMU equivalent exists for this controller at all — QEMU's own USB
// path, if ever added, would be PCIe+XHCI, a completely different
// controller, later phase). Diagnostic prints are deliberately
// generous at every step, not gated behind a _VERBOSE flag the way
// sdd.c3's now are — this is first bring-up, not a settled driver.

// --- DWC2 core registers (relative to board::USB_MMIO_BASE) — all fit
// in the first 4KB page, nothing here needs the other 15 pages of the
// core's own 64KB window.
const uint USB_GOTGCTL  = 0x000;
const uint USB_GAHBCFG  = 0x008;
const uint USB_GUSBCFG  = 0x00C;
const uint USB_GRSTCTL  = 0x010;
const uint USB_GINTSTS  = 0x014;
const uint USB_GSNPSID  = 0x040;
const uint USB_GHWCFG2  = 0x048; // fixed, synthesis-time core capability bits — not software-configurable, see usbd_init()'s own readback for why this matters
const uint USB_HCFG     = 0x400;
const uint USB_HPRT0    = 0x440;
// Power and Clock Gating Control — still within the first 4KB page.
// U-Boot's own dwc_otg_core_host_init() (drivers/usb/host/dwc2.c)
// writes 0 here as its VERY FIRST step, labeled "Restart the Phy
// Clock" — clears STOPPCLK/GATEHCLK/PWRCLMP/etc (all bits default to
// their own individual reset-time gating state). Never touched by
// this driver before now; found after HPRT0/GOTGCTL.CONIDSTS both
// stayed frozen at their reset defaults (0x0/1) across every TOP-block
// and DWC2-core register fix tried so far, regardless of what was
// written to them — the signature of an entire clock domain still
// gated off, not a wrong bit value.
const uint USB_PCGCCTL  = 0xE00;

// GOTGCTL — "Host only" mode bits, per the real CV1800B/CV1801B
// datasheet (register reference, section 12.6): a second,
// core-level VBUS-valid override, complementary to the TOP-block
// usb_phy_ctrl_reg bits below — overrides whatever Bvalid signal the
// core would otherwise receive directly from the PHY, rather than
// relying on the PHY correctly reporting it on its own.
const uint USB_GOTGCTL_VBVALIDOVEN  = 1 << 2; // VBUS Valid Override Enable
const uint USB_GOTGCTL_VBVALIDOVVAL = 1 << 3; // VBUS Valid Override Value (1 = valid, when OvEn is set)

const uint USB_GRSTCTL_CSFTRST     = 1 << 0;
const uint USB_GRSTCTL_GSFTRST_DONE = 1 << 29;
const uint USB_GRSTCTL_AHBIDLE     = 0x80000000;

const uint USB_GUSBCFG_PHYIF         = 1 << 3;  // UTMI+ 16-bit width (CV1800B: phy_type=UTMI, phy_utmi_width=16 — linux_5.10 dwc2_set_cv182x_params())
const uint USB_GUSBCFG_ULPI_UTMI_SEL = 1 << 4;  // must stay 0 — UTMI+, not ULPI
const uint USB_GUSBCFG_FORCEHOSTMODE = 1 << 29;
const uint USB_GUSBCFG_FORCEDEVMODE  = 1 << 30;

const uint USB_GINTSTS_CURMODE_HOST = 1 << 0; // 0=device, 1=host

const uint USB_HCFG_FSLSPCLKSEL_MASK    = 0x3;
const uint USB_HCFG_FSLSPCLKSEL_30_60MHZ = 0; // correct for the HS UTMI PHY

const uint USB_HPRT0_PRTCONNSTS     = 1 << 0;  // live connect state
const uint USB_HPRT0_PRTCONNDET     = 1 << 1;  // W1C, sticky "changed"
const uint USB_HPRT0_PRTENA         = 1 << 2;  // W1C
const uint USB_HPRT0_PRTENCHNG      = 1 << 3;  // W1C
const uint USB_HPRT0_PRTOVRCURRCHNG = 1 << 5;  // W1C
const uint USB_HPRT0_PRTRST         = 1 << 8;
const uint USB_HPRT0_PRTPWR         = 1 << 12;
const uint USB_HPRT0_W1C_MASK       = USB_HPRT0_PRTENA | USB_HPRT0_PRTCONNDET | USB_HPRT0_PRTENCHNG | USB_HPRT0_PRTOVRCURRCHNG;
// Diagnostic-only bits, not written — read to see what the analog PHY
// itself is reporting, independent of any higher-level protocol state.
// PRTLNSTS is the single most informative field for a "nothing ever
// detected" symptom: it's a raw sample of the D+/D- differential pair
// (bit10=DP, bit11=DM on this core), true regardless of whether the
// core's own connect-detect state machine ever asserts PRTCONNSTS —
// if this stays 00 (SE0) with a device plugged in, the PHY isn't
// seeing any voltage on the bus at all (pinmux/pad/power issue,
// upstream of anything DWC2-register-level), whereas 01/10 with
// PRTCONNSTS still 0 would mean the analog front-end is fine and the
// bug is in the core's own connect-detect logic instead.
const uint USB_HPRT0_PRTLNSTS_SHIFT = 10;
const uint USB_HPRT0_PRTLNSTS_MASK  = 0x3 << USB_HPRT0_PRTLNSTS_SHIFT;
const uint USB_HPRT0_PRTSPD_SHIFT   = 17;
const uint USB_HPRT0_PRTSPD_MASK    = 0x3 << USB_HPRT0_PRTSPD_SHIFT;

// --- TOP-block registers (SoC-specific — see this file's own header
// comment). Offsets relative to board::USB_TOP_CTRL_PAGE/
// USB_TOP_RST_PAGE respectively, each its own separate mapped page.
const uint USB_TOP_PHY_CTRL_OFFSET = 0x48;
// bits 0-1: found via the real CV1800B/CV1801B datasheet (register
// reference, "usb_phy_ctrl_reg" @ 0x048) — not present in any of the
// reference drivers this project's own earlier research checked
// (U-Boot/Linux/FSBL), since those all assume an earlier boot stage
// already asserted them. Both default to 0 (VBUS treated as invalid,
// VBUS power not driven) — without them, the PHY apparently never
// enables its own downstream connect-detection logic at all, even
// though the port's own Type-C circuitry may still briefly power a
// plugged-in device (matches this driver's own real-hardware symptom:
// a device's LED flashing on plug then going dark, HPRT0.PRTCONNSTS
// never asserting).
const uint USB_TOP_PHY_CTRL_EXTERNAL_VBUSVALID = 1 << 0; // "external vbus status" — tells the PHY to treat VBUS as valid
const uint USB_TOP_PHY_CTRL_DRIVE_VBUS         = 1 << 1; // "drive vbus power"
const uint USB_TOP_PHY_CTRL_ID_OVERRIDE_ENABLE = 1 << 6;
const uint USB_TOP_PHY_CTRL_ID_VALUE           = 1 << 7; // 0=host/A-side, 1=device/B-side
const uint USB_TOP_PHY_CTRL_MASK               = 0xC3;   // bits 0,1,6,7

const uint USB_TOP_SOFT_RST_OFFSET = 0x00;
const uint USB_TOP_SOFT_RST_USB    = 1 << 11;

// ECO (engineering-change-order) errata-fix register — same physical
// page as USB_TOP_PHY_CTRL_OFFSET above (both live on USB_TOP_CTRL_PAGE).
// Found via U-Boot's own board_usb_init() (board/cvitek/cv180x/board.c) —
// written unconditionally, right after the PHY_CTRL write, in every
// mode that board.c initializes USB for. Never referenced by this
// driver before now; added after two straight real-hardware rounds
// (a USB3 flash drive, then a genuine USB2-only Xbox 360 controller)
// both showed zero HPRT0.PRTCONNSTS reaction despite every other
// sourced register fix already applied.
const uint USB_TOP_ECO_OFFSET   = 0xB4;
const uint USB_TOP_ECO_RX_FLUSH = 0x80;

// PAD_USB_VBUS_DET pinmux function-select register — see
// board::USB_PINMUX_PAGE's own comment. Offset/mask/value sourced
// directly from cv180x_reg_fmux_gpio.h (FMUX_GPIO_FUNCSEL_USB_VBUS_DET)
// and cv180x_pinlist_swconfig.h (USB_VBUS_DET__USB_VBUS_DET = 0) — the
// same PINMUX_CONFIG(USB_VBUS_DET, USB_VBUS_DET) call U-Boot's own
// board_init() makes unconditionally, before board_usb_init() ever
// runs, for every boot regardless of USB mode.
const uint USB_PINMUX_VBUS_DET_OFFSET = 0xAC;
const uint USB_PINMUX_VBUS_DET_MASK   = 0x7;
const uint USB_PINMUX_VBUS_DET_FUNC   = 0x0; // function 0 = USB_VBUS_DET itself

// Clock-controller clock-enable registers — see board::USB_CLK_PAGE's
// own comment for full sourcing. REG_CLK_EN_1 controls many other,
// unrelated peripherals' own clocks too (uarts, i2s, ...) — always a
// read-modify-write of just these bits, never a blind write.
const uint USB_CLK_EN_1_OFFSET = 0x004;
const uint USB_CLK_EN_2_OFFSET = 0x008;
const uint USB_CLK_EN_1_125M_USB = 1 << 30;    // clk_125m_usb
const uint USB_CLK_EN_1_33K_USB  = 0x80000000; // clk_33k_usb, bit 31 — see USB_GRSTCTL_AHBIDLE's own comment for why bit-31 constants use a plain hex literal, not a left-shift (overflows int32 as a shift expression)
const uint USB_CLK_EN_2_12M_USB  = 1 << 0;     // clk_12m_usb

// Page bases — board::USB_MMIO_BASE/USB_TOP_CTRL_PAGE/USB_TOP_RST_PAGE/
// USB_CLK_PAGE aren't reachable from user-mode code (board is a
// kernel-only module), so duplicated here as plain constants, same
// convention user/sdd.c3's own SD_BASE/TOP_BASE/etc. already follow.
const uint USB_BASE          = 0x04340000;
const uint USB_TOP_CTRL_BASE = 0x03000000;
const uint USB_TOP_RST_BASE  = 0x03003000;
const uint USB_CLK_BASE      = 0x03002000;
const uint USB_PINMUX_BASE   = 0x03001000;

// Real, confirmed timebase-frequency, same sourcing as user/sdd.c3's
// own SD_TIMEBASE_HZ duplicate — see that file's header comment.
const uint USB_TIMEBASE_HZ = 25000000;

fn ulong usb_us_to_ticks(ulong us)
{
    return us * USB_TIMEBASE_HZ / 1000000;
}

fn uint mmio_read32(uptr addr)
{
    ulong v;
    asm
    {
        lw v, [addr];
    }
    return (uint)v;
}

fn void mmio_write32(uptr addr, uint v)
{
    ulong vv = (ulong)v;
    asm
    {
        sw vv, [addr];
    }
}

fn uint usb_reg_read(uint offset) { return mmio_read32((uptr)(USB_BASE + offset)); }
fn void usb_reg_write(uint offset, uint v) { mmio_write32((uptr)(USB_BASE + offset), v); }

fn uint top_ctrl_read(uint offset) { return mmio_read32((uptr)(USB_TOP_CTRL_BASE + offset)); }
fn void top_ctrl_write(uint offset, uint v) { mmio_write32((uptr)(USB_TOP_CTRL_BASE + offset), v); }

fn uint top_rst_read(uint offset) { return mmio_read32((uptr)(USB_TOP_RST_BASE + offset)); }
fn void top_rst_write(uint offset, uint v) { mmio_write32((uptr)(USB_TOP_RST_BASE + offset), v); }

fn uint clk_reg_read(uint offset) { return mmio_read32((uptr)(USB_CLK_BASE + offset)); }
fn void clk_reg_write(uint offset, uint v) { mmio_write32((uptr)(USB_CLK_BASE + offset), v); }

fn uint pinmux_read(uint offset) { return mmio_read32((uptr)(USB_PINMUX_BASE + offset)); }
fn void pinmux_write(uint offset, uint v) { mmio_write32((uptr)(USB_PINMUX_BASE + offset), v); }

const char[16] HEX_DIGITS = "0123456789abcdef";

fn void print_hex32(uint v)
{
    for (int shift = 28; shift >= 0; shift -= 4)
    {
        putchar(HEX_DIGITS[(v >> shift) & 0xF]);
    }
}

fn void print_hprt0_raw(char* label)
{
    uint hprt0 = usb_reg_read(USB_HPRT0);
    print("usbd: ");
    print(label);
    print(" HPRT0=0x");
    print_hex32(hprt0);
    print(" prtlnsts=");
    print_uint((hprt0 & USB_HPRT0_PRTLNSTS_MASK) >> USB_HPRT0_PRTLNSTS_SHIFT);
    print(" prtspd=");
    print_uint((hprt0 & USB_HPRT0_PRTSPD_MASK) >> USB_HPRT0_PRTSPD_SHIFT);
    print(" prtconnsts=");
    print_uint(hprt0 & USB_HPRT0_PRTCONNSTS);
    print("\n");
}

fn void usbd_panic(char* msg)
{
    print("usbd: ");
    print(msg);
    print("\n");
    // Same UB/optimizer hazard as diskd_panic/sdd_panic's own comment
    // — exit(), not an empty for(;;){} loop.
    exit();
}

// Core soft reset — used twice (once at init, once again right after
// changing PHY parameters, since those changes only take effect
// through a reset).
//
// Sequence and ordering now match the real Linux dwc2 driver's own
// dwc2_core_reset() (duo-buildroot-sdk's linux_5.10/drivers/usb/dwc2/
// core.c) exactly, not U-Boot's simpler version this driver mirrored
// originally. Two concrete differences that round of source-reading
// found:
//   1. CSFTRST is asserted immediately, with NO AHBIDLE poll before
//      it — Linux only checks AHBIDLE AFTER the reset completes, not
//      before.
//   2. For cores at or above revision 4.20a, after seeing
//      GRSTCTL_CSFTRST_DONE set, Linux does an explicit write-back:
//      read GRSTCTL, clear CSFTRST, set CSFTRST_DONE, write it back —
//      never just polls and moves on. This driver's own GSNPSID reads
//      back as exactly 0x4f54420a, which is bit-for-bit
//      DWC2_CORE_REV_4_20a in the real driver's own core.h constant
//      (not just "at or above" — genuinely equal), so this core
//      definitely takes that branch. This write-back was completely
//      missing before now.
// The old flat ≥100ms settle delay (from U-Boot's own comment, "very
// important, otherwise core will not stay in host mode") is kept
// anyway as a defensive extra, even though real Linux has no
// equivalent fixed sleep here at all — harmless either way, and cheap
// insurance since it's not the thing being changed this round.
fn bool usb_core_reset()
{
    usb_reg_write(USB_GRSTCTL, USB_GRSTCTL_CSFTRST);

    ulong reset_start = rdtime();
    ulong reset_budget = usb_us_to_ticks(100000);
    for (;;)
    {
        uint grstctl = usb_reg_read(USB_GRSTCTL);
        if ((grstctl & USB_GRSTCTL_GSFTRST_DONE) != 0) break;
        if (rdtime() - reset_start > reset_budget)
        {
            print("usbd: timed out waiting for GRSTCTL_CSFTRST_DONE\n");
            return false;
        }
        yield();
    }

    // Explicit write-back — see this function's own header comment.
    uint grstctl_done = usb_reg_read(USB_GRSTCTL);
    grstctl_done &= ~USB_GRSTCTL_CSFTRST;
    grstctl_done |= USB_GRSTCTL_GSFTRST_DONE;
    usb_reg_write(USB_GRSTCTL, grstctl_done);

    ulong idle_start = rdtime();
    ulong idle_budget = usb_us_to_ticks(100000);
    while ((usb_reg_read(USB_GRSTCTL) & USB_GRSTCTL_AHBIDLE) == 0)
    {
        if (rdtime() - idle_start > idle_budget)
        {
            print("usbd: timed out waiting for GRSTCTL.AHBIDLE\n");
            return false;
        }
        yield();
    }

    // Defensive settle delay — see this function's own header comment.
    // yield()-paced, not a bare spin — see SYS_YIELD's own comment
    // (src/entry.c3) for why a genuinely syscall-free wait here is a
    // real deadlock risk, not just wasted CPU.
    ulong settle_start = rdtime();
    ulong settle_budget = usb_us_to_ticks(100000);
    while (rdtime() - settle_start < settle_budget) { yield(); }

    return true;
}

fn void usbd_init()
{
    // PAD_USB_VBUS_DET pinmux — see USB_PINMUX_VBUS_DET_OFFSET's own
    // comment. Done first, mirroring U-Boot's own board_init() ordering
    // (pinmux_config(PINMUX_USB) runs before board_usb_init() touches
    // any DWC2/TOP-block register at all).
    uint pinmux = pinmux_read(USB_PINMUX_VBUS_DET_OFFSET);
    pinmux = (pinmux & ~USB_PINMUX_VBUS_DET_MASK) | USB_PINMUX_VBUS_DET_FUNC;
    pinmux_write(USB_PINMUX_VBUS_DET_OFFSET, pinmux);
    print("usbd: PAD_USB_VBUS_DET pinmux set\n");

    // The USB PHY's own reference clocks — clk_125m_usb/clk_33k_usb
    // (REG_CLK_EN_1 bits 30/31) and clk_12m_usb (REG_CLK_EN_2 bit 0) —
    // see board::USB_CLK_PAGE's own comment for full sourcing. Done
    // first, before touching RST_USB: these feed the analog PHY
    // itself, separate from clk_axi4_usb/clk_apb_usb (bits 28/29,
    // already confirmed enabled by default — they're what makes the
    // DWC2 core's own digital register access work at all, already
    // proven by every read/write below succeeding). Read-modify-write:
    // REG_CLK_EN_1/_2 control many other, unrelated peripherals' own
    // clocks too.
    uint clk_en_1 = clk_reg_read(USB_CLK_EN_1_OFFSET);
    clk_en_1 |= USB_CLK_EN_1_125M_USB | USB_CLK_EN_1_33K_USB;
    clk_reg_write(USB_CLK_EN_1_OFFSET, clk_en_1);
    uint clk_en_2 = clk_reg_read(USB_CLK_EN_2_OFFSET);
    clk_en_2 |= USB_CLK_EN_2_12M_USB;
    clk_reg_write(USB_CLK_EN_2_OFFSET, clk_en_2);
    print("usbd: PHY reference clocks enabled\n");

    // TOP block: RST_USB assert -> real delay -> deassert. Included
    // defensively even though the host-mode driver path itself doesn't
    // re-derive this (unclear from source whether an earlier boot
    // stage already leaves it deasserted) — redoing it is safe either
    // way.
    uint soft_rst = top_rst_read(USB_TOP_SOFT_RST_OFFSET);
    top_rst_write(USB_TOP_SOFT_RST_OFFSET, soft_rst & ~USB_TOP_SOFT_RST_USB);
    ulong rst_start = rdtime();
    while (rdtime() - rst_start < usb_us_to_ticks(50)) { yield(); }
    soft_rst = top_rst_read(USB_TOP_SOFT_RST_OFFSET);
    top_rst_write(USB_TOP_SOFT_RST_OFFSET, soft_rst | USB_TOP_SOFT_RST_USB);
    print("usbd: RST_USB toggled\n");

    // TOP block: force OTG ID override to host/A-side.
    //
    // This now matches, bit-for-bit, the real vendor Linux DWC2 glue
    // driver's own dwc2_set_hw_id() (duo-buildroot-sdk's
    // linux_5.10/drivers/usb/dwc2/platform.c) — the actual, proven
    // mechanism behind /mnt/system/usb-host.sh's `echo host >
    // /proc/cviusb/otg_role`, and also what runs automatically at
    // driver-probe time by default (cviusb.id_override initialized to
    // 0/host — comment right there: "init as host mode"). Its host-mode
    // write is `(read & ~0xC0) | 0x40` — clear bits 6-7, set bit6
    // only. Never touches bits 0-1 (EXTERNAL_VBUSVALID/DRIVE_VBUS) at
    // all, and never sets ID_VALUE (bit7) either — both were this
    // driver's own earlier inferences from the datasheet's field table,
    // unconfirmed by any real working driver, now known wrong: a whole
    // round of testing with ID_VALUE flipped to 1 (matching the
    // vendor's own *device*-mode value, 0xC0) went nowhere, which in
    // hindsight makes sense since that's the wrong role entirely.
    // GOTGCTL.CONIDSTS turned out to be a red herring the whole time —
    // the real driver never reads it either; host mode here comes
    // entirely from GUSBCFG.FORCEHOSTMODE (already confirmed active via
    // GINTSTS.CURMODE=1), not from this OTG protocol status bit.
    uint phy_ctrl = top_ctrl_read(USB_TOP_PHY_CTRL_OFFSET);
    phy_ctrl = (phy_ctrl & ~(USB_TOP_PHY_CTRL_ID_OVERRIDE_ENABLE | USB_TOP_PHY_CTRL_ID_VALUE))
        | USB_TOP_PHY_CTRL_ID_OVERRIDE_ENABLE;
    top_ctrl_write(USB_TOP_PHY_CTRL_OFFSET, phy_ctrl);
    print("usbd: PHY_CTRL ID override -> host (A-side), matching vendor dwc2_set_hw_id()\n");

    // Readback verification: did the override write actually stick, and
    // (bits 8/9 — io_usb_phy_idpad_c / toreg_usb_phy_idpad_c, both RO
    // per the real datasheet's own usb_phy_ctrl_reg field table) what
    // is the raw external ID pin reading vs. the overridden value
    // actually being forwarded downstream to the DWC2 core — the
    // direct way to tell whether this override is really reaching the
    // signal GOTGCTL.CONIDSTS reflects, or something else is.
    uint phy_ctrl_rb = top_ctrl_read(USB_TOP_PHY_CTRL_OFFSET);
    print("usbd: PHY_CTRL readback=0x");
    print_hex32(phy_ctrl_rb);
    print(" io_idpad_c(bit8)=");
    print_uint((phy_ctrl_rb >> 8) & 1);
    print(" toreg_idpad_c(bit9)=");
    print_uint((phy_ctrl_rb >> 9) & 1);
    print("\n");

    // ECO RX-flush errata fix — see USB_TOP_ECO_OFFSET's own comment.
    uint eco = top_ctrl_read(USB_TOP_ECO_OFFSET);
    top_ctrl_write(USB_TOP_ECO_OFFSET, eco | USB_TOP_ECO_RX_FLUSH);
    print("usbd: ECO RX_FLUSH set\n");

    // Sanity check the core responds at all before trusting anything
    // else — same reasoning user/diskd.c3's own VIRTIO_REG_MAGIC check
    // already established as this project's pattern.
    uint snpsid = usb_reg_read(USB_GSNPSID);
    print("usbd: GSNPSID=0x");
    print_hex32(snpsid);
    print("\n");
    if (snpsid == 0x00000000 || snpsid == 0xFFFFFFFF)
    {
        usbd_panic("GSNPSID readback looks wrong — MMIO mapping or clock/reset gating is probably not right yet");
    }

    // GHWCFG2 — fixed, synthesis-time core capability bits (not
    // software-configurable, unlike everything else this driver
    // touches). HS_PHY_TYPE in particular: this driver has been
    // assuming UTMI+ the whole time (GUSBCFG.PHYIF) — if this field
    // says otherwise (0=not supported, 2=ULPI only, 3=UTMI+ and ULPI),
    // that assumption itself would be wrong, independent of every
    // other register fix tried so far. ARCHITECTURE also determines
    // whether GAHBCFG needs DMA-related bits set below.
    uint hwcfg2 = usb_reg_read(USB_GHWCFG2);
    print("usbd: GHWCFG2=0x");
    print_hex32(hwcfg2);
    print(" hs_phy_type=");
    print_uint((hwcfg2 >> 6) & 0x3);
    print(" (0=none,1=UTMI+,2=ULPI,3=both) architecture=");
    print_uint((hwcfg2 >> 3) & 0x3);
    print(" (0=slave,1=ext_dma,2=int_dma) num_host_chan=");
    print_uint(((hwcfg2 >> 14) & 0xF) + 1);
    print("\n");

    if (!usb_core_reset())
    {
        usbd_panic("initial core soft reset failed");
    }
    print("usbd: core reset (1/2) done\n");

    // PHY parameters: UTMI+, 16-bit width. Requires a second reset to
    // actually take effect.
    uint usbcfg = usb_reg_read(USB_GUSBCFG);
    usbcfg &= ~(USB_GUSBCFG_ULPI_UTMI_SEL | USB_GUSBCFG_PHYIF);
    usbcfg |= USB_GUSBCFG_PHYIF;
    usb_reg_write(USB_GUSBCFG, usbcfg);

    if (!usb_core_reset())
    {
        usbd_panic("post-PHY-config core soft reset failed");
    }
    print("usbd: core reset (2/2) done\n");

    // Force host mode.
    usbcfg = usb_reg_read(USB_GUSBCFG);
    usbcfg &= ~USB_GUSBCFG_FORCEDEVMODE;
    usbcfg |= USB_GUSBCFG_FORCEHOSTMODE;
    usb_reg_write(USB_GUSBCFG, usbcfg);

    // GAHBCFG — never written by this driver before now. Reference
    // driver's dwc_otg_core_init() programs this as its own last step,
    // based on GHWCFG2.ARCHITECTURE (read above): internal-DMA cores
    // get HBURSTLEN_INCR4. DMAENABLE now set too — the real devicetree
    // node for this exact device (cv180x_base.dtsi) declares
    // `g-use-dma;`, and every other register-level fix that byte-exactly
    // matches the real vendor driver has still left HPRT0 frozen, so
    // this is the next concrete, sourced difference worth testing even
    // though Phase 1 has no real transfers planned yet — if host-port
    // status logic on this exact core integration turns out to be
    // gated behind DMA being enabled at all, this would explain it.
    uint architecture = (hwcfg2 >> 3) & 0x3;
    uint ahbcfg = 1 << 5; // DMAENABLE
    if (architecture == 2) // int_dma
    {
        ahbcfg |= (3 << 1); // HBURSTLEN_INCR4
    }
    usb_reg_write(USB_GAHBCFG, ahbcfg);
    print("usbd: GAHBCFG programmed (DMA enabled)\n");

    // Restart the PHY clock — see USB_PCGCCTL's own comment. This is
    // dwc_otg_core_host_init()'s own first step in the reference
    // driver, right after forcing host mode and before HCFG/HPRT0.
    usb_reg_write(USB_PCGCCTL, 0);
    print("usbd: PCGCCTL cleared (PHY clock restarted)\n");

    // GOTGCTL VBUS-valid override deliberately NOT set here (removed
    // after a real round-trip) — like the TOP-block bits 0-1 already
    // corrected earlier, this was this driver's own inference from the
    // datasheet's field table, never confirmed by any real driver
    // (the vendor's own dwc2_set_hw_id() never touches GOTGCTL at
    // all). Real-hardware evidence: with it set, HPRT0 became
    // permanently stuck reporting a false "connected, full-speed,
    // port-enabled" state — byte-identical whether or not a device was
    // actually plugged in. Forcing the session to always appear valid
    // regardless of real analog line state is a very plausible
    // explanation for exactly that symptom, so it's out until proven
    // otherwise. See USB_GOTGCTL_VBVALIDOVEN/_VBVALIDOVVAL's own
    // comment for what these bits are, kept for reference.

    // HCFG: FSLSPCLKSEL = 30-60MHz, correct for the HS UTMI PHY.
    uint hcfg = usb_reg_read(USB_HCFG);
    hcfg = (hcfg & ~USB_HCFG_FSLSPCLKSEL_MASK) | USB_HCFG_FSLSPCLKSEL_30_60MHZ;
    usb_reg_write(USB_HCFG, hcfg);

    // Real, observable checkpoint: did host mode actually take effect,
    // not just "we wrote the bits and hoped."
    uint gintsts = usb_reg_read(USB_GINTSTS);
    print("usbd: GINTSTS.CURMODE=");
    print_uint(gintsts & USB_GINTSTS_CURMODE_HOST);
    print(gintsts & USB_GINTSTS_CURMODE_HOST ? " (host mode active)\n" : " (still device mode — something above didn't take)\n");

    // Port power on — read-modify-write, clearing the W1C status bits
    // from the read value first so writing them back as 0 doesn't
    // accidentally clear a real pending event (standard DWC2 HPRT0
    // idiom).
    uint hprt0 = usb_reg_read(USB_HPRT0);
    hprt0 &= ~USB_HPRT0_W1C_MASK;
    hprt0 |= USB_HPRT0_PRTPWR;
    usb_reg_write(USB_HPRT0, hprt0);
    print("usbd: HPRT0 port power on\n");

    // Settle delay before trusting anything HPRT0 reports — VBUS
    // power-up is not instantaneous, and reading line state too early
    // risks sampling a genuine power-up transient. This replaces an
    // earlier, unconditional port-RESET pulse tried right after
    // port-power: real-hardware evidence (this session) showed that
    // approach latching HPRT0 into a permanent false "connected,
    // enabled" state — byte-identical whether or not a device was
    // actually plugged in — while PRTLNSTS itself correctly read SE0
    // (genuinely disconnected) the whole time. Root cause: a bus reset
    // pulsed against a power-up glitch (not a real device) completes
    // and *enables* the port anyway, and that enabled/connected state
    // then sticks — polling HPRT0 afterward can't undo it. Phase 1's
    // own scope (connect/disconnect polling only, no enumeration) never
    // actually needed a reset here at all; that will belong to a later
    // phase that performs real enumeration after a genuine, debounced
    // connect event.
    ulong power_settle_start = rdtime();
    while (rdtime() - power_settle_start < usb_us_to_ticks(100000)) { yield(); }
    print_hprt0_raw("post-power-settle");

    // Clear any stale W1C event bits (PRTCONNDET/PRTENCHNG/etc) that
    // may have latched during power-up, so the main polling loop below
    // starts from a genuinely clean slate rather than reacting to a
    // leftover flag from this settle window. Writing back exactly what
    // was just read is the standard DWC2 idiom here: any W1C bit
    // currently set gets cleared by the write-1, any W1C bit currently
    // clear is unaffected, and non-W1C fields (like PRTPWR) simply keep
    // their current value.
    usb_reg_write(USB_HPRT0, usb_reg_read(USB_HPRT0));

    uint gotgctl_final = usb_reg_read(USB_GOTGCTL);
    print("usbd: GOTGCTL=0x");
    print_hex32(gotgctl_final);
    print(" conidsts=");
    print_uint((gotgctl_final >> 16) & 1);
    print(" (0=A-device/host, 1=B-device/device)\n");
}

fn void main() @export("main")
{
    usbd_init();
    print("usbd: init done, polling HPRT0 for connect/disconnect\n");

    bool last_connected = false;
    int poll_count = 0;
    for (;;)
    {
        uint hprt0 = usb_reg_read(USB_HPRT0);
        bool connected = (hprt0 & USB_HPRT0_PRTCONNSTS) != 0;
        if (connected != last_connected)
        {
            print(connected ? "usbd: device connected\n" : "usbd: device disconnected\n");
            last_connected = connected;
        }

        // Periodic raw diagnostic dump (~every 2s, not gated on
        // PRTCONNSTS changing) — PRTLNSTS in particular is a direct
        // sample of the D+/D- differential pair, true regardless of
        // whether the core's own connect-detect logic ever reacts. See
        // print_hprt0_raw's own comment for how to read it.
        poll_count += 1;
        if (poll_count % 20 == 0)
        {
            print_hprt0_raw("poll");
        }

        // Clear PRTCONNDET (W1C) if it's set, without disturbing any
        // other W1C bit — keeps the register tidy for whenever a later
        // phase starts consulting it instead of just PRTCONNSTS.
        if (hprt0 & USB_HPRT0_PRTCONNDET)
        {
            uint clear = (hprt0 & ~USB_HPRT0_W1C_MASK) | USB_HPRT0_PRTCONNDET;
            usb_reg_write(USB_HPRT0, clear);
        }

        // yield()-paced, not a bare spin — this is the loop that
        // actually deadlocked the system on real hardware the first
        // time (docs/devlog.md): a genuinely syscall-free poll here
        // can never be preempted once the shell is idling on a
        // keystroke (SYS_GETCHAR), since this kernel's own design
        // means that alone holds interrupts globally disabled for as
        // long as it lasts.
        ulong poll_start = rdtime();
        while (rdtime() - poll_start < usb_us_to_ticks(100000)) { yield(); }
    }
}
