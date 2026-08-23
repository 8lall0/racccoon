module user;

import std::nolibc::mem;

// dwc2: register-level DWC2 (Synopsys DesignWare USB2 OTG core) driver
// for the Milk-V Duo's USB host controller — the "how" layer for
// user/usb/usbd.c3's own orchestration (main()/usb_enumerate_device()).
// Split out from what used to be one combined file once both grew
// large enough to make "the part that talks to the wire" and "the part
// that decides what to do next" hard to tell apart (docs/devlog.md).
//
// Covers: core/PHY bring-up (usbd_init(), usb_core_reset()), host
// channel 0 control transfers (hc_transfer_once(),
// usb_control_transfer()), and the USB-standard/hub-class request
// builders (usb_get_descriptor(), usb_set_address(),
// usb_set_configuration(), usb_get_hub_descriptor(),
// usb_set_port_feature(), usb_get_port_status()) — everything
// usbd.c3's own orchestration calls into, nothing that decides *when*
// to call it.
//
// Confirmed working on real hardware: host-mode bring-up (HPRT0
// connect/disconnect detection) and full device enumeration (including
// through the Duo IO board's own onboard hub), both verified against
// real silicon, not just QEMU (which has no DWC2 equivalent at all —
// its own USB path, if ever added, would be PCIe+XHCI, a completely
// different controller).
//
// Register offsets/bit layouts sourced directly from duo-buildroot-sdk's
// own driver code, read directly this project's own USB bring-up
// session — not reverse-engineered, not secondary documentation:
//   - DWC2 core registers: u-boot-2021.10/drivers/usb/host/dwc2.c/.h
//     (the generic DWC2 host driver CV1800B's own devicetree binds to
//     unmodified — "cvitek,cv182x-usb" only changes software
//     parameters, linux_5.10/drivers/usb/dwc2/params.c, never register
//     addresses) and linux_5.10/drivers/usb/dwc2/core.c/platform.c
//     (the real vendor Linux glue — the exact byte-for-byte host-mode
//     value and the core-reset write-back this exact core revision
//     needs both came from here, not U-Boot, which only supports
//     gadget/device mode on this SoC).
//   - TOP-block SoC-specific registers: u-boot-2021.10/board/cvitek/
//     cv180x/board.c and cv180x_reg.h. Confirmed: the devicetree's own
//     second `reg` range for this device (0x03006000, "USB 2.0 PHY" in
//     the source comment) is never actually written by any driver in
//     that SDK — not used here at all. The real SoC-specific registers
//     this driver needs live in the TOP control block instead
//     (board::USB_TOP_CTRL_PAGE/USB_TOP_RST_PAGE, boards/duo/board.c3).

// Gates the noisy, repeating diagnostic prints (periodic raw HPRT0
// dumps, the raw SETUP-byte dump on every control-transfer stage) —
// off by default now that Phase 1+2 are both confirmed working on
// real hardware (docs/devlog.md), same pattern user/block/sdd.c3's own
// SDD_VERBOSE already established. Meaningful, non-repeating output
// (device connected/disconnected, enumerated device info, hub port
// status, real error messages) stays on regardless — this only trims
// the high-frequency/high-volume stuff that was necessary while
// actively debugging the DWC2 bring-up and enumeration, not useful
// day to day. Flip to true if a real hardware bug ever needs that
// level of detail again.
const bool USBD_VERBOSE = false; // interrupt-transfer split support (g_split_active) still doesn't complete on real hardware — see docs/devlog.md for the full trace of what's been ruled out, including hub multi-TT mode. Flip back to true for that investigation's own diagnostic prints (hc_transfer_once_split, usb_interrupt_poll).

// --- DWC2 core registers (relative to board::USB_MMIO_BASE) — all fit
// in the first 4KB page, nothing here needs the other 15 pages of the
// core's own 64KB window.
const uint USB_GOTGCTL  = 0x000;
const uint USB_GAHBCFG  = 0x008;
const uint USB_GAHBCFG_GLBL_INTR_EN = 1 << 0; // see usbd_init()'s own GAHBCFG comment for why this driver sets it despite never handling a real CPU interrupt
const uint USB_GUSBCFG  = 0x00C;
const uint USB_GRSTCTL  = 0x010;
const uint USB_GINTSTS  = 0x014;
const uint USB_GRXFSIZ   = 0x024;
const uint USB_GNPTXFSIZ = 0x028;
const uint USB_GSNPSID  = 0x040;
const uint USB_GHWCFG2  = 0x048; // fixed, synthesis-time core capability bits — not software-configurable, see usbd_init()'s own readback for why this matters
const uint USB_GHWCFG3  = 0x04C; // fixed, synthesis-time — DFIFO_DEPTH field is this core's total shared FIFO RAM, in 32-bit words
const uint USB_HPTXFSIZ = 0x100;
const uint USB_GDFIFOCFG = 0x05C; // required when "dedicated/multiple Tx FIFO" mode is active — see usbd_init()'s own comment for why this core needs it
const uint USB_HCFG     = 0x400;
const uint USB_HFNUM    = 0x408; // host frame number — struct dwc2_host_regs: hcfg(0x400), hfir(0x404), hfnum(0x408)
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

// --- Host channel 0 registers (Phase 2: control transfers) — real
// devices behind the root port that this driver enumerates directly
// (the IO board's own hub, and later whatever mass-storage device
// enumeration finds behind it) are full-speed and directly on the
// root port from the DWC2 core's own point of view, so this driver
// only ever uses one channel, no split transactions. Offsets/bit
// fields sourced the same way as everything else in this file —
// duo-buildroot-sdk's own U-Boot dwc2.c/.h (struct dwc2_hc_regs,
// channel 0 base 0x500, 0x20 bytes per channel).
const uint USB_HC0_HCCHAR   = 0x500;
const uint USB_HC0_HCSPLT   = 0x504;
const uint USB_HC0_HCINT    = 0x508;
const uint USB_HC0_HCINTMSK = 0x50C;
const uint USB_HC0_HCTSIZ   = 0x510;
const uint USB_HC0_HCDMA    = 0x514;

const uint USB_HCCHAR_MPS_MASK      = 0x7FF;      // bits 10:0
const uint USB_HCCHAR_EPNUM_SHIFT   = 11;
const uint USB_HCCHAR_EPDIR         = 1 << 15;    // 1 = IN
const uint USB_HCCHAR_LSPDDEV       = 1 << 17;    // low-speed device — never set, this driver only ever talks to full-speed devices
const uint USB_HCCHAR_EPTYPE_SHIFT  = 18;
const uint USB_HCCHAR_EPTYPE_CONTROL = 0;
const uint USB_HCCHAR_EPTYPE_BULK = 2; // DWC2_HCCHAR_EPTYPE_BULK in U-Boot's own dwc2.h — same encoding table as EPTYPE_INTR below
const uint USB_HCCHAR_EPTYPE_INTERRUPT = 3; // DWC2_HCCHAR_EPTYPE_INTR in U-Boot's own dwc2.h — sourced, not guessed (see usb_interrupt_poll's own comment)
const uint USB_HCCHAR_MULTICNT_SHIFT = 20;
const uint USB_HCCHAR_DEVADDR_SHIFT = 22;
const uint USB_HCCHAR_CHDIS         = 1 << 30;
const uint USB_HCCHAR_CHEN          = 0x80000000; // bit 31 — see USB_GRSTCTL_AHBIDLE's own comment for why bit-31 constants use a plain hex literal
const uint USB_HCCHAR_ODDFRM        = 1 << 29; // periodic (interrupt/isoc) endpoints only — see hc_transfer_once's own comment

const uint USB_HCINT_XFERCOMP   = 1 << 0;
const uint USB_HCINT_CHHLTD     = 1 << 1;
const uint USB_HCINT_STALL      = 1 << 3;
const uint USB_HCINT_NAK        = 1 << 4;
const uint USB_HCINT_ACK        = 1 << 5;  // split transactions only — start-split accepted by the hub
const uint USB_HCINT_NYET       = 1 << 6;  // split transactions only — complete-split not ready yet, retry
const uint USB_HCINT_XACTERR    = 1 << 7;
const uint USB_HCINT_BBLERR     = 1 << 8;
const uint USB_HCINT_FRMOVRUN   = 1 << 9;
const uint USB_HCINT_ALL_MASK   = 0x3FFF; // enough bits to clear every real HCINT status this core defines

// HCSPLT fields — USB 2.0 split transactions (SSPLIT/CSPLIT), needed
// whenever the root port negotiates Hi-Speed but the target device
// (behind the IO board's own hub) is only full/low-speed. Sourced
// from the real vendor Linux driver (drivers/usb/dwc2/hw.h in
// duo-buildroot-sdk's linux_5.10) and cross-checked against U-Boot's
// own dwc2.h — both agree exactly on these offsets.
const uint USB_HCSPLT_PRTADDR_SHIFT = 0;   // hub's own downstream port number
const uint USB_HCSPLT_HUBADDR_SHIFT = 7;   // the hub's own USB device address
const uint USB_HCSPLT_XACTPOS_SHIFT = 14;
const uint USB_HCSPLT_XACTPOS_ALL   = 3;   // this driver only ever does single-packet splits (control/interrupt payloads always fit in one packet), so XACTPOS is always ALL, never BEGIN/MID/END
const uint USB_HCSPLT_COMPSPLT      = 1 << 16;
const uint USB_HCSPLT_SPLTENA       = 0x80000000; // bit 31 — see USB_HCCHAR_CHEN's own comment for why bit-31 constants use a plain hex literal

const uint USB_HCTSIZ_XFERSIZE_MASK = 0x7FFFF;   // bits 18:0
const uint USB_HCTSIZ_PKTCNT_SHIFT  = 19;
const uint USB_HCTSIZ_PID_SHIFT     = 29;

const uint USB_PID_DATA0 = 0;
const uint USB_PID_DATA1 = 2;
const uint USB_PID_SETUP = 3;

// --- USB standard requests/descriptors (USB 2.0 spec, chapter 9 and
// chapter 11 for the hub class bits) — protocol constants, not
// hardware-specific at all.
const uint USB_DESC_TYPE_DEVICE    = 1;
const uint USB_DESC_TYPE_CONFIG    = 2;
const uint USB_DESC_TYPE_INTERFACE = 4;
const uint USB_DESC_TYPE_ENDPOINT  = 5;
const uint USB_DESC_TYPE_HUB       = 0x29;
const uint USB_CLASS_HUB           = 0x09;
// bDeviceProtocol values for a hub-class device (USB 2.0 spec table
// 11-11) — 0=full-speed hub, 1=Hi-Speed hub with a single shared TT,
// 2=Hi-Speed hub with one TT per port ("multi-TT"). Sourced from real
// Linux's own USB_HUB_PR_* constants, include/uapi/linux/usb/ch11.h.
const uint USB_HUB_PROTOCOL_MULTI_TT = 2;
const uint USB_ENUM_ADDR  = 1; // Phase 2's own root-port device (the hub) — Phase 3 (USB Phase 3, hub-downstream enumeration) assigns a second address, USB_DOWNSTREAM_ADDR, to whatever's plugged into one of its ports
const uint USB_DOWNSTREAM_ADDR = 2;

// Mass Storage Class (USB Phase 4 prep) — USB Mass Storage Class
// Bulk-Only Transport spec, not guessed: interface class 0x08,
// subclass 0x06 (SCSI transparent command set — the overwhelming
// majority of real USB flash drives/card readers), protocol 0x50
// (Bulk-Only Transport, "BBB" — the only transport this driver
// implements; CBI/CB are obsolete and effectively unused on real
// hardware today).
const uint USB_CLASS_MASS_STORAGE     = 0x08;
const uint USB_MSC_SUBCLASS_SCSI      = 0x06;
const uint USB_MSC_PROTOCOL_BULK_ONLY = 0x50;

// Endpoint descriptor accessors (USB 2.0 spec chapter 9) — plain
// functions on a raw pointer into a Configuration descriptor blob,
// same style as eth_proto.c3's own read_be16/read_be32 helpers,
// rather than a @packed struct overlay: simpler for a handful of
// small fixed-offset reads.
const uint USB_EP_ATTR_XFERTYPE_MASK = 0x3; // bmAttributes bits [1:0]
const uint USB_EP_XFERTYPE_BULK      = 2;
const uint USB_EP_XFERTYPE_INTERRUPT = 3;

fn uint usb_ep_desc_address(char* ep_desc) { return (uint)ep_desc[2] & 0xFF; }
fn uint usb_ep_desc_xfer_type(char* ep_desc) { return (uint)ep_desc[3] & USB_EP_ATTR_XFERTYPE_MASK; }
fn uint usb_ep_desc_max_packet(char* ep_desc) { return ((uint)ep_desc[4] & 0xFF) | (((uint)ep_desc[5] & 0xFF) << 8); }
fn uint usb_ep_desc_interval(char* ep_desc) { return (uint)ep_desc[6] & 0xFF; }

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

// FIFO sizing fields — GRXFSIZ/GNPTXFSIZ/HPTXFSIZ (see
// usbd_init()'s own FIFO-sizing block for why these three registers
// need explicit programming at all) and GHWCFG3's own DFIFO_DEPTH,
// all sourced from the real vendor Linux driver
// (drivers/usb/dwc2/hw.h in duo-buildroot-sdk's linux_5.10).
const uint USB_GRXFSIZ_DEPTH_MASK       = 0xFFFF;
const uint USB_FIFOSIZE_DEPTH_SHIFT     = 16;
const uint USB_FIFOSIZE_DEPTH_MASK      = 0xFFFF0000; // see USB_HCCHAR_CHEN's own comment for why bit-31-and-above constants use a plain hex literal
const uint USB_FIFOSIZE_STARTADDR_MASK  = 0xFFFF;
const uint USB_GHWCFG3_DFIFO_DEPTH_SHIFT = 16;
const uint USB_GHWCFG3_DFIFO_DEPTH_MASK  = 0xFFFF0000;
const uint USB_GDFIFOCFG_EPINFOBASE_SHIFT = 16;
const uint USB_GDFIFOCFG_EPINFOBASE_MASK  = 0xFFFF0000;

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
// convention user/block/sdd.c3's own SD_BASE/TOP_BASE/etc. already
// follow.
const uint USB_BASE          = 0x04340000;
const uint USB_TOP_CTRL_BASE = 0x03000000;
const uint USB_TOP_RST_BASE  = 0x03003000;
const uint USB_CLK_BASE      = 0x03002000;
const uint USB_PINMUX_BASE   = 0x03001000;

// Real, confirmed timebase-frequency, same sourcing as user/block/sdd.c3's
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

// Phase 2's single-page DMA buffer — see process.c3's usbd_dma_paddr
// for the full explanation. Set once in main() (user/usb/usbd.c3),
// before usbd_init() runs. Real physical address AND the virtual
// address this driver reads/writes through — identity-mapped, same as
// every device MMIO page this driver already touches.
uptr usb_dma_paddr;

// Split-transaction context (USB Phase 3b) — set once per device
// before talking to it, consulted by hc_transfer_once for every
// transfer to that device until reset for the next one. Global,
// single-context state is safe here the same way usb_dma_paddr is:
// this driver only ever talks to one device at a time, sequentially,
// single-threaded. Never split when talking to the hub itself (its
// own control/status-endpoint transfers always go straight to the
// root port) — only set true for a downstream device that isn't
// itself Hi-Speed while the root port negotiated Hi-Speed.
bool g_split_active = false;
uint g_split_hub_addr = 0;
uint g_split_hub_port = 0;
uint g_split_intr_diag_count = 0; // diagnostic-only, see hc_transfer_once_split's own USBD_VERBOSE-gated prints

fn void usb_set_split_context(bool active, uint hub_addr, uint hub_port)
{
    g_split_active = active;
    g_split_hub_addr = hub_addr;
    g_split_hub_port = hub_port;
}

const char[16] HEX_DIGITS = "0123456789abcdef";

fn void print_hex32(uint v)
{
    for (int shift = 28; shift >= 0; shift -= 4)
    {
        putchar(HEX_DIGITS[(v >> shift) & 0xF]);
    }
}

// Gated by USBD_VERBOSE — for the one-time-but-verbose register-level
// bring-up milestones (RST_USB toggled, PHY_CTRL set, core reset done,
// etc.). Meaningful, low-frequency status (device connected, enumerated
// device info, hub port status) uses plain print() and stays visible
// regardless — see USBD_VERBOSE's own comment.
fn void usbd_vprint(char* msg)
{
    if (!USBD_VERBOSE) { return; }
    print("usbd: ");
    print(msg);
}

fn void print_hex8(uint v)
{
    putchar(HEX_DIGITS[(v >> 4) & 0xF]);
    putchar(HEX_DIGITS[v & 0xF]);
}

fn void print_hprt0_raw(char* label)
{
    if (!USBD_VERBOSE) { return; }
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
    usbd_vprint("PAD_USB_VBUS_DET pinmux set\n");

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
    usbd_vprint("PHY reference clocks enabled\n");

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
    usbd_vprint("RST_USB toggled\n");

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
    usbd_vprint("PHY_CTRL ID override -> host (A-side), matching vendor dwc2_set_hw_id()\n");

    // Readback verification: did the override write actually stick, and
    // (bits 8/9 — io_usb_phy_idpad_c / toreg_usb_phy_idpad_c, both RO
    // per the real datasheet's own usb_phy_ctrl_reg field table) what
    // is the raw external ID pin reading vs. the overridden value
    // actually being forwarded downstream to the DWC2 core — the
    // direct way to tell whether this override is really reaching the
    // signal GOTGCTL.CONIDSTS reflects, or something else is.
    if (USBD_VERBOSE)
    {
        uint phy_ctrl_rb = top_ctrl_read(USB_TOP_PHY_CTRL_OFFSET);
        print("usbd: PHY_CTRL readback=0x");
        print_hex32(phy_ctrl_rb);
        print(" io_idpad_c(bit8)=");
        print_uint((phy_ctrl_rb >> 8) & 1);
        print(" toreg_idpad_c(bit9)=");
        print_uint((phy_ctrl_rb >> 9) & 1);
        print("\n");
    }

    // ECO RX-flush errata fix — see USB_TOP_ECO_OFFSET's own comment.
    uint eco = top_ctrl_read(USB_TOP_ECO_OFFSET);
    top_ctrl_write(USB_TOP_ECO_OFFSET, eco | USB_TOP_ECO_RX_FLUSH);
    usbd_vprint("ECO RX_FLUSH set\n");

    // Sanity check the core responds at all before trusting anything
    // else — same reasoning user/block/diskd.c3's own VIRTIO_REG_MAGIC
    // check already established as this project's pattern.
    uint snpsid = usb_reg_read(USB_GSNPSID);
    if (USBD_VERBOSE)
    {
        print("usbd: GSNPSID=0x");
        print_hex32(snpsid);
        print("\n");
    }
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
    if (USBD_VERBOSE)
    {
        print("usbd: GHWCFG2=0x");
        print_hex32(hwcfg2);
        print(" hs_phy_type=");
        print_uint((hwcfg2 >> 6) & 0x3);
        print(" (0=none,1=UTMI+,2=ULPI,3=both) architecture=");
        print_uint((hwcfg2 >> 3) & 0x3);
        print(" (0=slave,1=ext_dma,2=int_dma) num_host_chan=");
        print_uint(((hwcfg2 >> 14) & 0xF) + 1);
        print("\n");
    }

    if (!usb_core_reset())
    {
        usbd_panic("initial core soft reset failed");
    }
    usbd_vprint("core reset (1/2) done\n");

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
    usbd_vprint("core reset (2/2) done\n");

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
    // GLBL_INTR_EN — real hardware round (docs/devlog.md): every
    // interrupt-type (periodic) transfer to every device this driver
    // has ever tried, root-port or hub-relayed, NAKed forever
    // (HCINT=CHHLTD|NAK) — byte-identical result across every other
    // fix tried (frame parity, bInterval pacing, FIFO/GDFIFOCFG
    // sizing), while control transfers on the exact same channel/
    // device always worked. Booting the real vendor Linux 5.10 on
    // this exact board (same hub, same pad, same physical setup) and
    // driving a raw usbfs interrupt transfer directly (bypassing any
    // class driver) got 50/50 successes immediately — proving the
    // hardware itself is fine and this is a real driver gap. Linux's
    // own dwc2_core_init() (drivers/usb/dwc2/core.c) sets this bit
    // UNCONDITIONALLY, not gated behind whether interrupt-driven I/O
    // is actually used at the HCD level — this driver never has,
    // since it polls HCINT directly, and never set this bit either.
    // Plausible mechanism: on real DWC2 silicon this top-level enable
    // may gate internal core event processing generally, not just the
    // external IRQ line — which would explain simple, immediate-
    // completion control transfers working regardless while the more
    // involved internal periodic-scheduling machinery genuinely needs
    // it. GINTMSK (which event types actually reach the IRQ line)
    // stays fully masked/untouched either way, so this can't cause a
    // spurious CPU interrupt — polling is unaffected.
    ahbcfg |= USB_GAHBCFG_GLBL_INTR_EN;
    usb_reg_write(USB_GAHBCFG, ahbcfg);
    usbd_vprint("GAHBCFG programmed (DMA enabled, GLBL_INTR_EN set)\n");

    // Restart the PHY clock — see USB_PCGCCTL's own comment. This is
    // dwc_otg_core_host_init()'s own first step in the reference
    // driver, right after forcing host mode and before HCFG/HPRT0.
    usb_reg_write(USB_PCGCCTL, 0);
    usbd_vprint("PCGCCTL cleared (PHY clock restarted)\n");

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
    //
    // FSLSSUPP (forcing Full/Low-Speed-only) used to be set here — a
    // real hardware round hit XACTERR on every control transfer to a
    // full-speed device behind the IO board's own hub, root-caused to
    // the hub negotiating Hi-Speed on the root port while this driver
    // never implemented USB 2.0 split transactions. Forcing FSLSSUPP
    // "fixed" that by making the whole host negotiate Full-Speed only,
    // sidestepping the need for splits entirely — but it never
    // resolved interrupt-type transfers, which NAKed forever
    // regardless (docs/devlog.md has the long trace: frame parity,
    // FIFO/GDFIFOCFG sizing, GLBL_INTR_EN, bInterval pacing — all
    // correct, all sourced, none of it moved the failure). Booting the
    // real vendor Linux 5.10 on this exact board confirmed the actual
    // difference: it lets the hub negotiate its native Hi-Speed and
    // uses real split transactions, and got 50/50 successful interrupt
    // transfers immediately — a wire path this driver, under forced
    // FSLSSUPP, had never actually exercised. Real split-transaction
    // support (hc_transfer_once_split, g_split_active) replaces the
    // FSLSSUPP workaround now instead of papering over its absence.
    uint hcfg = usb_reg_read(USB_HCFG);
    hcfg = (hcfg & ~USB_HCFG_FSLSPCLKSEL_MASK) | USB_HCFG_FSLSPCLKSEL_30_60MHZ;
    usb_reg_write(USB_HCFG, hcfg);

    // Rx FIFO / Non-periodic Tx FIFO / Periodic Tx FIFO sizing —
    // required because GHWCFG2.DYNAMIC_FIFO=1 on this core (confirmed
    // from GHWCFG2=0x228f5c52, bit 19 set, printed above), meaning
    // these three FIFOs share one contiguous block of FIFO RAM and
    // their DEPTH+START-ADDRESS fields must be explicitly written at
    // host init. Never done anywhere in this driver before now — a
    // real gap, root-caused on real hardware (docs/devlog.md): control
    // transfers to every device this driver has ever talked to,
    // root-port or hub-relayed, all succeed; every interrupt-type
    // transfer to every device, root-port (the IO board hub's own
    // status-change endpoint) or hub-relayed (the xpad controller),
    // NAKed forever (HCINT=CHHLTD|NAK) — identical symptom regardless
    // of topology, ruling out anything hub-specific.
    //
    // First attempt (see docs/devlog.md) followed the real vendor
    // Linux driver's own dwc2_config_fifos() shape (drivers/usb/dwc2/
    // hcd.c in duo-buildroot-sdk's linux_5.10) exactly: keep whatever
    // depth each FIFO's register already reports at reset. Real
    // hardware round disproved that on THIS silicon: GHWCFG3.DFIFO_
    // DEPTH read back total=3072 words, but the reset-time GRXFSIZ/
    // GNPTXFSIZ/HPTXFSIZ depth fields were 1536/1536/1536 — summing to
    // 4608, well past the real 3072-word budget. Confirmed via the
    // real vendor Linux 5.10's own debugfs
    // (/sys/kernel/debug/usb/4340000.usb/hw_params) on THIS exact
    // board: that's the raw, untrustworthy hw_params reading, not what
    // Linux actually programs — its own computed `params` (same
    // debugfs directory) use host_rx_fifo_size=530,
    // host_nperio_tx_fifo_size=256, host_perio_tx_fifo_size=768
    // instead (sum 1554, comfortably under the 3072 budget, real
    // spare room left over). Second attempt (also since disproven, see
    // docs/devlog.md) computed a naive even three-way split of the
    // full 3072 instead — consumed the ENTIRE budget, leaving zero
    // spare FIFO RAM for whatever "dedicated/multiple Tx FIFO" mode
    // (en_multiple_tx_fifo=1, confirmed both in this same real debugfs
    // params dump and via GHWCFG2.DYNAMIC_FIFO) needs beyond these
    // three main FIFOs — a very plausible reason periodic transfers
    // (MULTICNT=3) never worked while control (MULTICNT=1) did.
    // Hardcoded to Linux's own exact real values now, not recomputed —
    // this is the same physical silicon, so there's nothing to
    // recompute, only to match.
    uint total_fifo_words = (usb_reg_read(USB_GHWCFG3) & USB_GHWCFG3_DFIFO_DEPTH_MASK) >> USB_GHWCFG3_DFIFO_DEPTH_SHIFT;
    uint rx_depth = 530;
    uint nptx_depth = 256;
    uint ptx_depth = 768;

    usb_reg_write(USB_GRXFSIZ, rx_depth & USB_GRXFSIZ_DEPTH_MASK);

    uint nptxfsiz = (nptx_depth << USB_FIFOSIZE_DEPTH_SHIFT) | (rx_depth & USB_FIFOSIZE_STARTADDR_MASK);
    usb_reg_write(USB_GNPTXFSIZ, nptxfsiz);

    uint ptx_startaddr = rx_depth + nptx_depth;
    uint hptxfsiz = (ptx_depth << USB_FIFOSIZE_DEPTH_SHIFT) | (ptx_startaddr & USB_FIFOSIZE_STARTADDR_MASK);
    usb_reg_write(USB_HPTXFSIZ, hptxfsiz);

    // GDFIFOCFG.EPINFOBASE — "dedicated fifos" (DWC2's
    // en_multiple_tx_fifo feature, confirmed both via the real Linux
    // debugfs params dump above and GHWCFG2.DYNAMIC_FIFO) needs this
    // pointing at where the per-channel dedicated FIFO info table
    // begins — i.e. right after the three main FIFOs actually end
    // (rx_depth+nptx_depth+ptx_depth = 1554), NOT the full 3072-word
    // budget this used to use before rx/nptx/ptx were corrected to
    // Linux's own real values above. Using the full budget here left
    // zero real space for that per-channel table even though the
    // register write itself "looked" valid — a very plausible reason
    // periodic transfers never worked while control did.
    uint dfifocfg = usb_reg_read(USB_GDFIFOCFG);
    uint epinfobase = rx_depth + nptx_depth + ptx_depth;
    dfifocfg = (dfifocfg & ~USB_GDFIFOCFG_EPINFOBASE_MASK) | ((epinfobase << USB_GDFIFOCFG_EPINFOBASE_SHIFT) & USB_GDFIFOCFG_EPINFOBASE_MASK);
    usb_reg_write(USB_GDFIFOCFG, dfifocfg);

    if (USBD_VERBOSE)
    {
        print("usbd: FIFO sizing: total=");
        print_uint(total_fifo_words);
        print(" rx_depth=");
        print_uint(rx_depth);
        print(" nptx_depth=");
        print_uint(nptx_depth);
        print(" ptx_depth=");
        print_uint(ptx_depth);
        print(" ptx_startaddr=");
        print_uint(ptx_startaddr);
        print(" gdfifocfg=0x");
        print_hex32(dfifocfg);
        print("\n");
    }

    // Real, observable checkpoint: did host mode actually take effect,
    // not just "we wrote the bits and hoped."
    uint gintsts = usb_reg_read(USB_GINTSTS);
    if (USBD_VERBOSE)
    {
        print("usbd: GINTSTS.CURMODE=");
        print_uint(gintsts & USB_GINTSTS_CURMODE_HOST);
        print(gintsts & USB_GINTSTS_CURMODE_HOST ? " (host mode active)\n" : " (still device mode — something above didn't take)\n");
    }

    // Port power on — read-modify-write, clearing the W1C status bits
    // from the read value first so writing them back as 0 doesn't
    // accidentally clear a real pending event (standard DWC2 HPRT0
    // idiom).
    uint hprt0 = usb_reg_read(USB_HPRT0);
    hprt0 &= ~USB_HPRT0_W1C_MASK;
    hprt0 |= USB_HPRT0_PRTPWR;
    usb_reg_write(USB_HPRT0, hprt0);
    usbd_vprint("HPRT0 port power on\n");

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

    if (USBD_VERBOSE)
    {
        uint gotgctl_final = usb_reg_read(USB_GOTGCTL);
        print("usbd: GOTGCTL=0x");
        print_hex32(gotgctl_final);
        print(" conidsts=");
        print_uint((gotgctl_final >> 16) & 1);
        print(" (0=A-device/host, 1=B-device/device)\n");
    }
}

// --- Control transfers over host channel 0, and the request builders
// on top of them.
//
// IMPORTANT: implemented from real, sourced DWC2 register facts
// (U-Boot's own chunk_msg()/_submit_control_msg()/wait_for_chhltd(),
// duo-buildroot-sdk's u-boot-2021.10/drivers/usb/host/dwc2.c),
// confirmed working on real hardware — full device enumeration through
// the Duo IO board's own onboard hub, including hub-class
// SET_CONFIGURATION/SetPortFeature(PORT_POWER)/GetPortStatus, all
// verified against real silicon (see docs/devlog.md).

// Single host-channel transfer: programs HCTSIZ/HCDMA/HCCHAR, enables
// the channel, and waits for CHHLTD (channel halted — the transfer
// attempt is over, one way or another). Returns 0 on real success
// (XFERCOMP), 1 on NAK/FRMOVRUN (caller should retry — completely
// normal while a device is still processing a request), -1 on
// anything else (STALL, transaction/babble error, or this function's
// own CHHLTD timeout).
//
// ep_num/eptype added for USB Phase 3 (interrupt transfers, see
// usb_interrupt_poll below) — every existing control-transfer caller
// passes ep_num=0 (endpoint 0 is implicit/hardwired for control,
// matching this function's own original unconditional behavior
// exactly: `0 << USB_HCCHAR_EPNUM_SHIFT` is a no-op) and
// eptype=USB_HCCHAR_EPTYPE_CONTROL, so nothing about existing control-
// transfer behavior changes.
// Waits for CHHLTD (channel halted — the transfer attempt is over,
// one way or another), same 2-second timeout budget and real-error
// print every hc_transfer_once caller already relied on. Shared by
// the plain and split-transaction transfer paths below — a genuine
// 3-way duplication once splits needed their own SSPLIT/CSPLIT waits,
// not premature abstraction.
fn int hc_wait_chhltd(uint* hcint_out)
{
    ulong start = rdtime();
    ulong budget = usb_us_to_ticks(2000000);
    for (;;)
    {
        uint hcint = usb_reg_read(USB_HC0_HCINT);
        if (hcint & USB_HCINT_CHHLTD) { *hcint_out = hcint; return 0; }
        if (rdtime() - start > budget)
        {
            print("usbd: hc_transfer_once timed out waiting for CHHLTD, HCINT=0x");
            print_hex32(hcint);
            print("\n");
            return -1;
        }
        yield();
    }
}

// Split-transaction (SSPLIT/CSPLIT) version of hc_transfer_once —
// used whenever g_split_active is set: the root port negotiated
// Hi-Speed (this driver no longer forces Full/Low-Speed-only) but the
// target device, behind the IO board's own hub, is only full/low-
// speed. Sourced exactly from U-Boot's own chunk_msg()
// (drivers/usb/host/dwc2.c in duo-buildroot-sdk's u-boot-2021.10) —
// the only real reference implementation of this protocol this
// project has direct access to, cross-checked field-by-field against
// the real vendor Linux driver's own HCSPLT/HCINT bit definitions.
//
// One logical transfer attempt here is actually two physical bus
// transactions: a start-split (COMPSPLT=0) addressed to the HUB,
// asking it to relay the real transaction to the downstream device;
// then one or more complete-split (COMPSPLT=1) polls asking the hub
// "is the relayed result ready yet" — NYET means "not yet," retried
// immediately (no real hardware SOF-driven delay needed for a full/
// low-speed device behind a full/low-speed-negotiated link's own
// polling cadence) up to a real elapsed-frame budget (>4 frames since
// the start-split, matching U-Boot's own cutoff) before giving up as
// a retryable failure — the caller's own existing NAK-budget retry
// loop (usb_control_transfer) or steady-state poll loop
// (usb_interrupt_poll) already handles "try again," so this returns 1
// (not -1) for that case, same as a plain NAK.
fn int hc_transfer_once_split(uint dev_addr, uint ep_num, uint eptype, bool is_in, uint pid, uint max_packet, uint xfer_len, uint num_packets, uint* actual_len_out)
{
    // For split INT (this driver has no ISOC), U-Boot's own chunk_msg()
    // sets ec_mc (this field, HCCHAR.MULTICNT) to 3 rather than 1 — "for
    // immediate retries," its own comment says. Control splits keep 1.
    uint multicnt = eptype == USB_HCCHAR_EPTYPE_INTERRUPT ? 3 : 1;
    uint hcchar = (max_packet & USB_HCCHAR_MPS_MASK)
        | (ep_num << USB_HCCHAR_EPNUM_SHIFT)
        | (is_in ? USB_HCCHAR_EPDIR : 0)
        | (eptype << USB_HCCHAR_EPTYPE_SHIFT)
        | (multicnt << USB_HCCHAR_MULTICNT_SHIFT)
        | (dev_addr << USB_HCCHAR_DEVADDR_SHIFT);

    uint hcsplt_base = USB_HCSPLT_SPLTENA
        | (g_split_hub_addr << USB_HCSPLT_HUBADDR_SHIFT)
        | (g_split_hub_port << USB_HCSPLT_PRTADDR_SHIFT)
        | (USB_HCSPLT_XACTPOS_ALL << USB_HCSPLT_XACTPOS_SHIFT);

    bool diag_this_call = USBD_VERBOSE && eptype == USB_HCCHAR_EPTYPE_INTERRUPT && g_split_intr_diag_count < 10;

    // Real vendor Linux (traced via dwc2_hc_nyet_intr(),
    // drivers/usb/dwc2/hcd_intr.c) never retries a STALE complete-
    // split for periodic (interrupt/isoc) endpoints — on NYET it
    // halts the channel and its own SOF-interrupt-driven scheduler
    // issues a completely FRESH start-split on a later frame. A real
    // hardware round confirmed retrying the same complete-split never
    // works here (100-frame budget, always NYET, never XFERCOMP) —
    // but giving up after exactly one fresh start-split per external
    // bInterval-paced poll (this function's own immediately-prior
    // version) also never once succeeded, over 2000+ genuinely fresh
    // attempts. Real Linux's SOF scheduler can reschedule far more
    // often than once per bInterval, within the SAME overall polling
    // window — this outer loop approximates that with its own
    // polling: fresh start-split, one complete-split check, and on
    // NYET/NAK go around again with ANOTHER fresh start-split
    // (never a stale complete-split), bounded by outer_budget_us
    // real time rather than U-Boot's frame-count style budget, since
    // this loop's own per-iteration cost (each a fresh SSPLIT+CSPLIT
    // round trip) doesn't cleanly map to a fixed frame count. Control/
    // bulk splits are unaffected — they still retry the SAME complete-
    // split within a short frame budget, exactly as before (proven
    // working: full enumeration through this exact hub, including a
    // multi-packet 139-byte config descriptor fetch, every time).
    // SAFETY REVERT (docs/devlog.md): a 20ms/~160-fresh-start-split
    // version of this budget got ZERO completions across those 160
    // independent attempts (spread over ~20 different frames) — real
    // evidence this was never a timing/scheduling problem, not just
    // an unlucky window — and the hammering itself correlated with a
    // NEW failure mode afterward (hc_transfer_once timing out
    // entirely, HCINT=0x0, on plain non-split control transfers too),
    // suggesting it was actively destabilizing the host controller's
    // channel state rather than converging on anything. Back to a
    // single fresh start-split attempt per external poll (outer
    // budget effectively 0) until this gets a real root cause instead
    // of another retry-shape guess.
    ulong outer_start = rdtime();
    ulong outer_budget_us = 0;
    uint outer_attempts = 0;

    for (;;)
    {
        outer_attempts++;
        uint oddfrm = 0;
        if (eptype == USB_HCCHAR_EPTYPE_INTERRUPT)
        {
            uint hfnum_snapshot = usb_reg_read(USB_HFNUM);
            if ((hfnum_snapshot & 0x1) == 0) { oddfrm = USB_HCCHAR_ODDFRM; }
        }

        uint start_hctsiz = (xfer_len & USB_HCTSIZ_XFERSIZE_MASK)
            | (num_packets << USB_HCTSIZ_PKTCNT_SHIFT)
            | (pid << USB_HCTSIZ_PID_SHIFT);

        // Start-split.
        usb_reg_write(USB_HC0_HCTSIZ, start_hctsiz);
        usb_reg_write(USB_HC0_HCDMA, (uint)usb_dma_paddr);
        usb_reg_write(USB_HC0_HCCHAR, hcchar);
        usb_reg_write(USB_HC0_HCSPLT, hcsplt_base);
        usb_reg_write(USB_HC0_HCINT, USB_HCINT_ALL_MASK);
        usb_reg_write(USB_HC0_HCCHAR, hcchar | USB_HCCHAR_CHEN | oddfrm);

        uint hcint;
        if (hc_wait_chhltd(&hcint) != 0) { return -1; }
        usb_reg_write(USB_HC0_HCINT, USB_HCINT_ALL_MASK);

        if (!(hcint & USB_HCINT_ACK))
        {
            if (hcint & USB_HCINT_NAK)
            {
                if (eptype == USB_HCCHAR_EPTYPE_INTERRUPT && rdtime() - outer_start < outer_budget_us) { continue; }
                return 1;
            }
            if (hcint & USB_HCINT_FRMOVRUN) { return 1; }
            print("usbd: hc_transfer_once_split: start-split not ACKed, HCINT=0x");
            print_hex32(hcint);
            print("\n");
            return -1;
        }

        uint ssplit_frame = usb_reg_read(USB_HFNUM) & 0xFFFF;
        uint cur_pid = pid;
        bool retry_fresh_split = false;

        // Complete-split. Control/bulk retries THIS SAME complete-
        // split within a short frame budget; interrupt/isoc checks
        // exactly once, then falls through to the outer loop above
        // for a fresh start-split — see this function's own top
        // comment for why.
        for (;;)
        {
            uint csplit_hctsiz = (xfer_len & USB_HCTSIZ_XFERSIZE_MASK)
                | (num_packets << USB_HCTSIZ_PKTCNT_SHIFT)
                | (cur_pid << USB_HCTSIZ_PID_SHIFT);
            usb_reg_write(USB_HC0_HCTSIZ, csplit_hctsiz);
            usb_reg_write(USB_HC0_HCDMA, (uint)usb_dma_paddr);
            usb_reg_write(USB_HC0_HCCHAR, hcchar);
            usb_reg_write(USB_HC0_HCSPLT, hcsplt_base | USB_HCSPLT_COMPSPLT);
            usb_reg_write(USB_HC0_HCINT, USB_HCINT_ALL_MASK);
            usb_reg_write(USB_HC0_HCCHAR, hcchar | USB_HCCHAR_CHEN | oddfrm);

            if (hc_wait_chhltd(&hcint) != 0) { return -1; }

            uint hctsiz_after = usb_reg_read(USB_HC0_HCTSIZ);
            uint remaining = hctsiz_after & USB_HCTSIZ_XFERSIZE_MASK;
            *actual_len_out = xfer_len - remaining;
            cur_pid = (hctsiz_after >> USB_HCTSIZ_PID_SHIFT) & 0x3;
            usb_reg_write(USB_HC0_HCINT, USB_HCINT_ALL_MASK);

            if (hcint & USB_HCINT_XFERCOMP)
            {
                if (diag_this_call && outer_attempts > 1)
                {
                    g_split_intr_diag_count++;
                    print("usbd: split intr diag #");
                    print_uint(g_split_intr_diag_count);
                    print(": XFERCOMP after ");
                    print_uint(outer_attempts);
                    print(" fresh start-split attempts\n");
                }
                return 0;
            }

            if (hcint & (USB_HCINT_NYET | USB_HCINT_NAK))
            {
                if (eptype == USB_HCCHAR_EPTYPE_INTERRUPT)
                {
                    retry_fresh_split = true;
                    break;
                }

                uint frame_now = usb_reg_read(USB_HFNUM) & 0xFFFF;
                uint elapsed = (frame_now - ssplit_frame) & 0xFFFF;
                if (elapsed > 4) { return 1; }
                continue;
            }

            if (hcint & USB_HCINT_FRMOVRUN) { return 1; }

            print("usbd: hc_transfer_once_split: complete-split real error, HCINT=0x");
            print_hex32(hcint);
            print(hcint & USB_HCINT_STALL ? " (STALL)" : "");
            print(hcint & USB_HCINT_XACTERR ? " (XACTERR)" : "");
            print(hcint & USB_HCINT_BBLERR ? " (BBLERR)" : "");
            print("\n");
            return -1;
        }

        if (retry_fresh_split && rdtime() - outer_start < outer_budget_us) { continue; }

        if (diag_this_call)
        {
            g_split_intr_diag_count++;
            print("usbd: split intr diag #");
            print_uint(g_split_intr_diag_count);
            print(": gave up after ");
            print_uint(outer_attempts);
            print(" fresh start-split attempts\n");
        }
        return 1;
    }
}

fn int hc_transfer_once(uint dev_addr, uint ep_num, uint eptype, bool is_in, uint pid, uint max_packet, uint xfer_len, uint num_packets, uint* actual_len_out)
{
    if (g_split_active)
    {
        return hc_transfer_once_split(dev_addr, ep_num, eptype, is_in, pid, max_packet, xfer_len, num_packets, actual_len_out);
    }

    uint hctsiz = (xfer_len & USB_HCTSIZ_XFERSIZE_MASK)
        | (num_packets << USB_HCTSIZ_PKTCNT_SHIFT)
        | (pid << USB_HCTSIZ_PID_SHIFT);
    usb_reg_write(USB_HC0_HCTSIZ, hctsiz);
    usb_reg_write(USB_HC0_HCDMA, (uint)usb_dma_paddr);

    uint hcchar = (max_packet & USB_HCCHAR_MPS_MASK)
        | (ep_num << USB_HCCHAR_EPNUM_SHIFT)
        | (is_in ? USB_HCCHAR_EPDIR : 0)
        | (eptype << USB_HCCHAR_EPTYPE_SHIFT)
        | (1 << USB_HCCHAR_MULTICNT_SHIFT)
        | (dev_addr << USB_HCCHAR_DEVADDR_SHIFT);
    usb_reg_write(USB_HC0_HCCHAR, hcchar);

    // No split needed for this transfer (see g_split_active's own
    // comment for when it is) — explicitly disable it anyway, same as
    // this driver has always done, in case a stray SPLTENA bit
    // survived from an earlier split-transaction attempt on this same
    // physical channel.
    usb_reg_write(USB_HC0_HCSPLT, 0);

    // Clear stale interrupt state before this attempt — standard DWC2
    // idiom (matches U-Boot's own transfer_chunk()), same reasoning as
    // every other W1C register this driver already clears before use.
    usb_reg_write(USB_HC0_HCINT, USB_HCINT_ALL_MASK);

    // Periodic (interrupt/isoc) endpoints are scheduled against the
    // core's own internal odd/even frame list — real, sourced
    // difference from control/bulk transfers: U-Boot's own
    // chunk_msg() reads HFNUM and sets HCCHAR.ODDFRM for exactly this
    // case (`if (eptype == DWC2_HCCHAR_EPTYPE_INTR) ... odd_frame =
    // !(hfnum & 1)`), leaving it 0 (even) for every other endpoint
    // type.
    uint enable_hcchar = hcchar | USB_HCCHAR_CHEN;
    if (eptype == USB_HCCHAR_EPTYPE_INTERRUPT)
    {
        uint hfnum_snapshot = usb_reg_read(USB_HFNUM);
        if ((hfnum_snapshot & 0x1) == 0) { enable_hcchar |= USB_HCCHAR_ODDFRM; }
    }
    usb_reg_write(USB_HC0_HCCHAR, enable_hcchar);

    uint hcint;
    if (hc_wait_chhltd(&hcint) != 0) { return -1; }

    uint hctsiz_after = usb_reg_read(USB_HC0_HCTSIZ);
    uint remaining = hctsiz_after & USB_HCTSIZ_XFERSIZE_MASK;
    *actual_len_out = xfer_len - remaining;

    usb_reg_write(USB_HC0_HCINT, USB_HCINT_ALL_MASK);

    if (hcint & USB_HCINT_XFERCOMP) return 0;
    if (hcint & USB_HCINT_NAK) return 1;
    if (hcint & USB_HCINT_FRMOVRUN) return 1;

    print("usbd: hc_transfer_once real error, HCINT=0x");
    print_hex32(hcint);
    print(hcint & USB_HCINT_STALL ? " (STALL)" : "");
    print(hcint & USB_HCINT_XACTERR ? " (XACTERR)" : "");
    print(hcint & USB_HCINT_BBLERR ? " (BBLERR)" : "");
    print("\n");
    return -1;
}

// Full 3-stage control transfer: SETUP (always 8 bytes, PID=SETUP) ->
// optional DATA stage (buf_len bytes, PID starts DATA1 — control
// endpoints always restart their toggle at DATA1 after a SETUP stage,
// regardless of any previous transfer's own final toggle state, so no
// per-endpoint toggle tracking is needed here) -> STATUS stage (zero
// length, opposite direction of the data stage, or IN if there was no
// data stage at all). setup8 must point at exactly 8 bytes, formatted
// per USB 2.0 spec chapter 9's own SETUP packet layout. On a
// successful IN data stage, copies up to buf_len bytes (or however
// many the device actually returned, if fewer) into out_buf.
fn bool usb_control_transfer(uint dev_addr, uint max_packet0, char* setup8, void* out_buf, uint buf_len, bool data_is_in)
{
    mem::copy((void*)usb_dma_paddr, setup8, 8);

    if (USBD_VERBOSE)
    {
        print("usbd: SETUP bytes:");
        for (int i = 0; i < 8; i++)
        {
            putchar(' ');
            print_hex8((uint)setup8[i] & 0xFF);
        }
        print("\n");
    }

    uint actual_len;
    int result;
    ulong nak_budget = usb_us_to_ticks(3000000);

    ulong stage_start = rdtime();
    for (;;)
    {
        result = hc_transfer_once(dev_addr, 0, USB_HCCHAR_EPTYPE_CONTROL, false, USB_PID_SETUP, max_packet0, 8, 1, &actual_len);
        if (result == 0) break;
        if (result == 1 && rdtime() - stage_start < nak_budget) { yield(); continue; }
        print("usbd: control transfer failed at SETUP stage\n");
        return false;
    }

    // Small settle delay before reprogramming the channel for the next
    // stage — a real hardware round hit a persistent STALL on the very
    // first DATA stage, immediately following a successful SETUP, with
    // zero delay between CHHLTD firing and the channel being
    // reprogrammed; this tests whether that back-to-back timing itself
    // is the problem, independent of anything about the transfer's own
    // content (which was separately confirmed correct via the raw
    // SETUP byte dump above).
    ulong interstage_start = rdtime();
    while (rdtime() - interstage_start < usb_us_to_ticks(2000)) { yield(); }

    if (buf_len > 0)
    {
        if (g_split_active)
        {
            // A split transaction can only relay one packet per
            // SSPLIT/CSPLIT cycle (see hc_transfer_once_split's own
            // comment) — unlike a non-split transfer, where
            // HCTSIZ.PktCnt lets the DMA engine autonomously burst
            // through every packet in a single hc_transfer_once call.
            // U-Boot's own chunk_msg() handles exactly this by forcing
            // num_packets=1 and looping at the message level for
            // every max_packet-sized chunk, re-assembling the real
            // buffer via a copy per chunk (its own aligned_buffer is
            // exactly this pattern: a small reusable DMA bounce
            // buffer, not one big multi-packet burst) — this does the
            // same, reusing this driver's own single usb_dma_paddr
            // buffer per chunk since transfers are always sequential.
            uint done = 0;
            // Successive packets within one multi-packet DATA stage
            // must alternate DATA1/DATA0 — standard USB toggle rule,
            // normally handled autonomously by hardware within a
            // single non-split hc_transfer_once call (HCTSIZ.PID
            // advances on its own across the whole PktCnt burst), but
            // here this loop IS what issues each packet, so it must
            // track and advance the toggle itself. A real bug hit on
            // the first hardware round of this chunking loop: every
            // chunk hardcoded USB_PID_DATA1, and the second packet of
            // a 3-packet fetch came back HCINT=CHHLTD|DATATGLERR
            // (bit 10) — exactly this mistake.
            uint chunk_pid = USB_PID_DATA1;
            stage_start = rdtime();
            while (done < buf_len)
            {
                uint chunk_len = buf_len - done < max_packet0 ? buf_len - done : max_packet0;
                if (!data_is_in)
                {
                    mem::copy((void*)usb_dma_paddr, (void*)((uptr)out_buf + done), chunk_len);
                }
                for (;;)
                {
                    result = hc_transfer_once(dev_addr, 0, USB_HCCHAR_EPTYPE_CONTROL, data_is_in, chunk_pid, max_packet0, chunk_len, 1, &actual_len);
                    if (result == 0) break;
                    if (result == 1 && rdtime() - stage_start < nak_budget) { yield(); continue; }
                    print("usbd: control transfer failed at DATA stage (split chunk)\n");
                    return false;
                }
                if (data_is_in && out_buf != null)
                {
                    uint copy_len = actual_len < chunk_len ? actual_len : chunk_len;
                    mem::copy((void*)((uptr)out_buf + done), (void*)usb_dma_paddr, copy_len);
                }
                done += actual_len;
                chunk_pid = chunk_pid == USB_PID_DATA1 ? USB_PID_DATA0 : USB_PID_DATA1;
                if (actual_len < chunk_len) { break; } // short packet — real transfer ends early
            }
        }
        else
        {
            uint num_packets = (buf_len + max_packet0 - 1) / max_packet0;
            // Every Phase 2 caller only ever does IN data stages
            // (GET_*), so this is currently unreachable — kept for
            // correctness anyway, symmetric with the IN-side copy
            // below, since an OUT data stage without this would
            // silently send whatever stale bytes were already in the
            // DMA buffer.
            if (!data_is_in)
            {
                mem::copy((void*)usb_dma_paddr, out_buf, buf_len);
            }
            stage_start = rdtime();
            for (;;)
            {
                result = hc_transfer_once(dev_addr, 0, USB_HCCHAR_EPTYPE_CONTROL, data_is_in, USB_PID_DATA1, max_packet0, buf_len, num_packets, &actual_len);
                if (result == 0) break;
                if (result == 1 && rdtime() - stage_start < nak_budget) { yield(); continue; }
                print("usbd: control transfer failed at DATA stage\n");
                return false;
            }
            if (data_is_in && out_buf != null)
            {
                uint copy_len = actual_len < buf_len ? actual_len : buf_len;
                mem::copy(out_buf, (void*)usb_dma_paddr, copy_len);
            }
        }

        interstage_start = rdtime();
        while (rdtime() - interstage_start < usb_us_to_ticks(2000)) { yield(); }
    }

    bool status_is_in = buf_len > 0 ? !data_is_in : true;
    stage_start = rdtime();
    for (;;)
    {
        result = hc_transfer_once(dev_addr, 0, USB_HCCHAR_EPTYPE_CONTROL, status_is_in, USB_PID_DATA1, max_packet0, 0, 1, &actual_len);
        if (result == 0) break;
        if (result == 1 && rdtime() - stage_start < nak_budget) { yield(); continue; }
        print("usbd: control transfer failed at STATUS stage\n");
        return false;
    }

    return true;
}

// --- Bulk transfers (USB Phase 4, Mass Storage prep) — same shape as
// usb_control_transfer()'s own DATA stage (split-aware chunking with
// manual PID-toggle tracking when g_split_active, single multi-packet
// burst otherwise) but standalone: no SETUP/STATUS wrapping, and the
// PID toggle persists ACROSS calls via *pid_toggle_inout, the same
// contract as usb_interrupt_poll()'s own pid_toggle_inout — bulk
// endpoints are hardware-toggle-maintained exactly like interrupt
// ones (USB 2.0 spec 5.8.4), the toggle only resets on
// SET_CONFIGURATION/SET_INTERFACE/CLEAR_FEATURE(ENDPOINT_HALT), never
// per-transfer. Deliberately reuses hc_transfer_once() (not a new
// bulk-specific state machine) — split bulk and split interrupt only
// differ in HCSPLT.XACTPOS/MULTICNT handling and NYET semantics,
// which hc_transfer_once_split() already keys off of `eptype`.
//
// Caller is expected to only invoke this with buf_len > 0 — MSC's own
// CBW (31 bytes)/CSW (13 bytes)/data-stage transfers are never
// zero-length, so no zero-length special case is implemented.
fn bool usb_bulk_transfer(uint dev_addr, uint ep_num, uint max_packet, uint* pid_toggle_inout, bool is_in, void* buf, uint buf_len, uint* actual_len_out)
{
    uint actual_len;
    int result;
    ulong nak_budget = usb_us_to_ticks(3000000);

    if (g_split_active)
    {
        uint done = 0;
        ulong stage_start = rdtime();
        while (done < buf_len)
        {
            uint chunk_len = buf_len - done < max_packet ? buf_len - done : max_packet;
            if (!is_in)
            {
                mem::copy((void*)usb_dma_paddr, (void*)((uptr)buf + done), chunk_len);
            }
            for (;;)
            {
                result = hc_transfer_once(dev_addr, ep_num, USB_HCCHAR_EPTYPE_BULK, is_in, *pid_toggle_inout, max_packet, chunk_len, 1, &actual_len);
                if (result == 0) break;
                if (result == 1 && rdtime() - stage_start < nak_budget) { yield(); continue; }
                print("usbd: bulk transfer failed (split chunk)\n");
                return false;
            }
            if (is_in)
            {
                uint copy_len = actual_len < chunk_len ? actual_len : chunk_len;
                mem::copy((void*)((uptr)buf + done), (void*)usb_dma_paddr, copy_len);
            }
            done += actual_len;
            *pid_toggle_inout = *pid_toggle_inout == USB_PID_DATA1 ? USB_PID_DATA0 : USB_PID_DATA1;
            if (actual_len < chunk_len) { break; } // short packet — real transfer ends early
        }
        *actual_len_out = done;
        return true;
    }

    uint num_packets = (buf_len + max_packet - 1) / max_packet;
    if (!is_in)
    {
        mem::copy((void*)usb_dma_paddr, buf, buf_len);
    }
    ulong stage_start = rdtime();
    for (;;)
    {
        result = hc_transfer_once(dev_addr, ep_num, USB_HCCHAR_EPTYPE_BULK, is_in, *pid_toggle_inout, max_packet, buf_len, num_packets, &actual_len);
        if (result == 0) break;
        if (result == 1 && rdtime() - stage_start < nak_budget) { yield(); continue; }
        print("usbd: bulk transfer failed\n");
        return false;
    }
    if (is_in)
    {
        uint copy_len = actual_len < buf_len ? actual_len : buf_len;
        mem::copy(buf, (void*)usb_dma_paddr, copy_len);
    }
    *actual_len_out = actual_len;

    // Hardware already advanced HCTSIZ.PID past this successful
    // transfer — read back the real value for the next call, not a
    // blind software flip (same rationale as usb_interrupt_poll()'s
    // own read-back).
    uint hctsiz_after = usb_reg_read(USB_HC0_HCTSIZ);
    *pid_toggle_inout = (hctsiz_after >> USB_HCTSIZ_PID_SHIFT) & 0x3;
    return true;
}

// --- Interrupt transfers (USB Phase 3) — a single DATA-stage-shaped
// IN poll, no SETUP/STATUS wrapping unlike a control transfer (real,
// sourced difference from usb_control_transfer(), confirmed against
// U-Boot's own dwc2.c: its own interrupt-transfer path is really just
// the bulk path — chunk_msg()/wait_for_chhltd() reused as-is, no
// SETUP/STATUS stages, called repeatedly by the polling caller).
//
// PID toggle is NOT reset to DATA1 every call the way control's own
// DATA/STATUS stages always are — control endpoints restart their
// toggle at DATA1 after every SETUP, but interrupt/bulk endpoints
// persist their own toggle ACROSS transfers, hardware-maintained:
// HCTSIZ.PID after a successful transfer already holds the value the
// NEXT transfer should use. *pid_toggle_inout carries that state
// across calls — read before, written back after every poll.
//
// Returns true only on a real new report (XFERCOMP). NAK is not
// treated as an error here, unlike usb_control_transfer()'s own
// budget-and-fail policy — for a HID-style interrupt endpoint NAK
// just means "nothing new since last poll," the normal, expected
// steady-state condition between real reports, so this returns false
// immediately rather than retrying against a timeout. A genuine STALL
// or transaction error also returns false (hc_transfer_once already
// printed the detail).
// Diagnostic-only, USBD_VERBOSE-gated: first few polls plus every
// 500th, same rationale as this driver's earlier debugging rounds —
// enough to tell "never once succeeded" apart from silence caused by
// an unchanged (all-idle) report.
uint g_usb_intr_poll_count = 0;

fn bool usb_interrupt_poll(uint dev_addr, uint ep_num, uint max_packet, uint* pid_toggle_inout, void* out_buf, uint buf_len, uint* actual_len_out)
{
    int result = hc_transfer_once(dev_addr, ep_num, USB_HCCHAR_EPTYPE_INTERRUPT, true, *pid_toggle_inout, max_packet, buf_len, 1, actual_len_out);
    g_usb_intr_poll_count++;
    if (USBD_VERBOSE && (g_usb_intr_poll_count < 6 || g_usb_intr_poll_count % 500 == 0))
    {
        print("usbd: xpad: poll #");
        print_uint(g_usb_intr_poll_count);
        print(" result=");
        print_int(result);
        if (result == 0)
        {
            print(" actual_len=");
            print_uint(*actual_len_out);
        }
        print("\n");
    }
    if (result != 0) { return false; }

    uint copy_len = *actual_len_out < buf_len ? *actual_len_out : buf_len;
    mem::copy(out_buf, (void*)usb_dma_paddr, copy_len);

    // Hardware already advanced HCTSIZ.PID past this successful
    // transfer — read back the real value for the next poll, not a
    // blind software flip.
    uint hctsiz_after = usb_reg_read(USB_HC0_HCTSIZ);
    *pid_toggle_inout = (hctsiz_after >> USB_HCTSIZ_PID_SHIFT) & 0x3;
    return true;
}

fn bool usb_get_descriptor(uint dev_addr, uint max_packet0, uint desc_type, uint desc_index, void* buf, uint len)
{
    char[8] setup;
    setup[0] = (char)0x80; // IN, standard, device
    setup[1] = (char)0x06; // GET_DESCRIPTOR
    setup[2] = (char)desc_index;
    setup[3] = (char)desc_type;
    setup[4] = (char)0;
    setup[5] = (char)0;
    setup[6] = (char)(len & 0xFF);
    setup[7] = (char)((len >> 8) & 0xFF);
    return usb_control_transfer(dev_addr, max_packet0, &setup[0], buf, len, true);
}

fn bool usb_set_address(uint max_packet0, uint new_addr)
{
    char[8] setup;
    setup[0] = (char)0x00; // OUT, standard, device
    setup[1] = (char)0x05; // SET_ADDRESS
    setup[2] = (char)(new_addr & 0xFF);
    setup[3] = (char)0;
    setup[4] = (char)0;
    setup[5] = (char)0;
    setup[6] = (char)0;
    setup[7] = (char)0;
    // Still addressed as 0 (the default address) — the device hasn't
    // taken on its new address yet until this very request completes.
    return usb_control_transfer(0, max_packet0, &setup[0], null, 0, true);
}

fn bool usb_set_configuration(uint dev_addr, uint max_packet0, uint config_value)
{
    char[8] setup;
    setup[0] = (char)0x00; // OUT, standard, device
    setup[1] = (char)0x09; // SET_CONFIGURATION
    setup[2] = (char)(config_value & 0xFF);
    setup[3] = (char)0;
    setup[4] = (char)0;
    setup[5] = (char)0;
    setup[6] = (char)0;
    setup[7] = (char)0;
    return usb_control_transfer(dev_addr, max_packet0, &setup[0], null, 0, true);
}

// USB 2.0 spec chapter 9 standard request, wValue=alt_setting,
// wIndex=iface_num, no data stage. Real, sourced motivation
// (docs/devlog.md): mainline Linux's own hub_configure()
// (drivers/usb/core/hub.c) sends exactly this — SET_INTERFACE(hub, 0,
// 1) — for any Hi-Speed hub reporting bDeviceProtocol==2
// (USB_HUB_PR_HS_MULTI_TT), switching it from its default shared-TT
// behavior into "one Transaction Translator per port" mode. This
// driver never did that before; a shared TT has to serialize/schedule
// split transactions across every port together, plausible enough to
// explain occasional one-off control transfers working while a
// sustained periodic interrupt poll — competing for the same shared
// TT resource on every single poll — never lines up.
fn bool usb_set_interface(uint dev_addr, uint max_packet0, uint iface_num, uint alt_setting)
{
    char[8] setup;
    setup[0] = (char)0x01; // OUT, standard, interface
    setup[1] = (char)0x0B; // SET_INTERFACE
    setup[2] = (char)(alt_setting & 0xFF);
    setup[3] = (char)0;
    setup[4] = (char)(iface_num & 0xFF);
    setup[5] = (char)0;
    setup[6] = (char)0;
    setup[7] = (char)0;
    return usb_control_transfer(dev_addr, max_packet0, &setup[0], null, 0, true);
}

fn bool usb_get_hub_descriptor(uint dev_addr, uint max_packet0, void* buf, uint len)
{
    char[8] setup;
    setup[0] = (char)0xA0; // IN, class, device
    setup[1] = (char)0x06; // GET_DESCRIPTOR
    setup[2] = (char)0;
    setup[3] = (char)USB_DESC_TYPE_HUB;
    setup[4] = (char)0;
    setup[5] = (char)0;
    setup[6] = (char)(len & 0xFF);
    setup[7] = (char)((len >> 8) & 0xFF);
    return usb_control_transfer(dev_addr, max_packet0, &setup[0], buf, len, true);
}

// Configuration descriptor (USB Phase 3) — two-step fetch: the first
// 9 (fixed-size header) bytes to learn the real wTotalLength (the
// blob also includes every nested Interface/Endpoint descriptor, so
// its true size isn't known in advance), then the full blob, capped
// at buf_len (the caller's own fixed buffer size — plenty for any
// device this driver has needed to inspect so far).
fn bool usb_get_configuration_descriptor(uint dev_addr, uint max_packet0, void* buf, uint buf_len)
{
    char[9] header;
    if (!usb_get_descriptor(dev_addr, max_packet0, USB_DESC_TYPE_CONFIG, 0, &header[0], 9)) { return false; }
    uint total_len = ((uint)header[2] & 0xFF) | (((uint)header[3] & 0xFF) << 8);
    if (total_len > buf_len) { total_len = buf_len; }
    return usb_get_descriptor(dev_addr, max_packet0, USB_DESC_TYPE_CONFIG, 0, buf, total_len);
}

// Walks a raw Configuration descriptor blob (as returned by
// usb_get_configuration_descriptor above) looking for an Interface
// descriptor matching the given class/subclass/protocol — generic
// TLV-walking (bLength/bDescriptorType), not tied to any one device
// class, reusable for any future USB class driver. On a match,
// *iface_num_out gets the interface's own bInterfaceNumber,
// *num_endpoints_out gets its own bNumEndpoints (read directly from
// the interface descriptor itself, not back-derived from
// *ep_start_offset_out — robust even if a real device's own bLength
// isn't exactly the usual 9), and *ep_start_offset_out gets the byte
// offset (within config_buf) where its endpoint descriptors begin —
// standard USB descriptor layout puts them immediately after their
// interface, *num_endpoints_out of them, which the caller walks
// directly via usb_ep_desc_*() rather than this function returning a
// fixed-shape result.
fn bool usb_find_interface(char* config_buf, uint len, uint want_class, uint want_subclass, uint want_protocol, uint* iface_num_out, uint* num_endpoints_out, uint* ep_start_offset_out)
{
    uint i = 0;
    while (i + 1 < len)
    {
        uint b_length = (uint)config_buf[i] & 0xFF;
        uint b_type = (uint)config_buf[i + 1] & 0xFF;
        if (b_length == 0) { break; } // malformed — avoid an infinite loop rather than trust a hostile/broken device
        if (b_type == USB_DESC_TYPE_INTERFACE && i + 8 < len)
        {
            uint if_class = (uint)config_buf[i + 5] & 0xFF;
            uint if_subclass = (uint)config_buf[i + 6] & 0xFF;
            uint if_protocol = (uint)config_buf[i + 7] & 0xFF;
            if (if_class == want_class && if_subclass == want_subclass && if_protocol == want_protocol)
            {
                *iface_num_out = (uint)config_buf[i + 2] & 0xFF;
                *num_endpoints_out = (uint)config_buf[i + 4] & 0xFF;
                *ep_start_offset_out = i + b_length;
                return true;
            }
        }
        i += b_length;
    }
    return false;
}

fn bool usb_get_port_status(uint dev_addr, uint max_packet0, uint port, void* buf4)
{
    char[8] setup;
    setup[0] = (char)0xA3; // IN, class, other (port)
    setup[1] = (char)0x00; // GET_STATUS
    setup[2] = (char)0;
    setup[3] = (char)0;
    setup[4] = (char)(port & 0xFF); // wIndex = port number, 1-based
    setup[5] = (char)0;
    setup[6] = (char)4;
    setup[7] = (char)0;
    return usb_control_transfer(dev_addr, max_packet0, &setup[0], buf4, 4, true);
}

const uint USB_HUB_FEATURE_PORT_POWER = 8; // USB 2.0 spec Table 11-17
const uint USB_HUB_FEATURE_PORT_RESET = 4; // USB 2.0 spec Table 11-17, alongside PORT_POWER above
const uint USB_PORT_STATUS_ENABLE     = 1 << 1; // GetPortStatus wPortStatus bit 1
// wPortStatus bits 9/10 (USB 2.0 spec Table 11-15) — within the
// GetPortStatus response's second byte (port_status[1]), so the local
// bit position within that byte is (9-8)=1 and (10-8)=2. Neither bit
// set means full-speed; the two are mutually exclusive per spec.
const uint USB_PORT_STATUS_HIGH_SPEED_B1 = 1 << 1; // bit 9
const uint USB_PORT_STATUS_LOW_SPEED_B1  = 1 << 2;  // bit 10

const uint USB_DEV_SPEED_FULL = 0;
const uint USB_DEV_SPEED_LOW  = 1;
const uint USB_DEV_SPEED_HIGH = 2;

fn bool usb_set_port_feature(uint dev_addr, uint max_packet0, uint port, uint feature)
{
    char[8] setup;
    setup[0] = (char)0x23; // OUT, class, other (port)
    setup[1] = (char)0x03; // SET_FEATURE
    setup[2] = (char)(feature & 0xFF);
    setup[3] = (char)0;
    setup[4] = (char)(port & 0xFF); // wIndex = port number, 1-based
    setup[5] = (char)0;
    setup[6] = (char)0;
    setup[7] = (char)0;
    return usb_control_transfer(dev_addr, max_packet0, &setup[0], null, 0, true);
}

// USB Phase 3: real hub-downstream-port reset, the missing piece
// between "GetPortStatus says something's connected" (Phase 2's own
// scope) and actually being able to talk to it — an unpowered-then-
// unreset port never leaves the electrical/protocol state a fresh
// device resets into. Also reports the device's own negotiated speed
// (USB_DEV_SPEED_*, from wPortStatus bits 9/10) — the caller needs it
// to decide whether split transactions apply to this device (see
// g_split_active's own comment): this driver's root port itself
// negotiates whatever the hub natively supports (Hi-Speed, for the
// real hub this project has tested against), so a downstream device
// that isn't itself Hi-Speed needs every transfer split.
fn bool usb_reset_hub_port(uint hub_addr, uint max_packet0, uint port, uint* speed_out)
{
    if (!usb_set_port_feature(hub_addr, max_packet0, port, USB_HUB_FEATURE_PORT_RESET))
    {
        print("usbd: hub port ");
        print_uint(port);
        print(": SetPortFeature(PORT_RESET) failed\n");
        return false;
    }

    // USB 2.0 spec's own minimum reset duration is 10ms; matching
    // this driver's own established generous-margin convention
    // elsewhere (e.g. usb_enumerate_device()'s own 50ms root-port
    // reset pulse) rather than cutting it close.
    ulong reset_start = rdtime();
    while (rdtime() - reset_start < usb_us_to_ticks(50000)) { yield(); }

    char[4] port_status;
    if (!usb_get_port_status(hub_addr, max_packet0, port, &port_status[0]))
    {
        print("usbd: hub port ");
        print_uint(port);
        print(": GET_PORT_STATUS after reset failed\n");
        return false;
    }
    bool enabled = ((uint)port_status[0] & USB_PORT_STATUS_ENABLE) != 0;
    if (!enabled)
    {
        print("usbd: hub port ");
        print_uint(port);
        print(": did not report PORT_ENABLE after reset\n");
        return false;
    }

    uint status_b1 = (uint)port_status[1] & 0xFF;
    if (status_b1 & USB_PORT_STATUS_HIGH_SPEED_B1) { *speed_out = USB_DEV_SPEED_HIGH; }
    else if (status_b1 & USB_PORT_STATUS_LOW_SPEED_B1) { *speed_out = USB_DEV_SPEED_LOW; }
    else { *speed_out = USB_DEV_SPEED_FULL; }
    return true;
}
