module user;

import std::nolibc::mem;

// dwc2: register-level DWC2 (Synopsys DesignWare USB2 OTG core) driver
// for the Milk-V Duo's USB host controller — the "how" layer for
// user/usb/usbd.c3's own orchestration (main()/usb_enumerate_device()).
//
// Covers: core/PHY bring-up (usbd_init(), usb_core_reset()), host
// channel 0 transfers — plain and USB 2.0 split (SSPLIT/CSPLIT), needed
// whenever the root port negotiates Hi-Speed but the target device is
// only full/low-speed — and the USB-standard/hub-class request builders.
//
// Confirmed working on real hardware: host-mode bring-up, full device
// enumeration (including through the Duo IO board's own onboard hub),
// and non-split control/bulk transfers. Split *control/bulk* transfers
// are also confirmed working (a full multi-packet config descriptor
// fetch through the hub). Split *interrupt* transfers are not yet
// confirmed — see hc_transfer_once_split()'s own comment.
//
// Sourcing:
//   - DWC2 core/host-channel registers: duo-buildroot-sdk's
//     u-boot-2021.10/drivers/usb/host/dwc2.c/.h (the generic DWC2 host
//     driver CV1800B's own devicetree binds to unmodified) and
//     linux_5.10/drivers/usb/dwc2/core.c/platform.c/hw.h (the real
//     vendor Linux glue — core-reset write-back quirk, HCSPLT/HCINT
//     bit layout, FIFO sizing).
//   - TOP-block SoC-specific registers: u-boot-2021.10/board/cvitek/
//     cv180x/board.c, cv180x_reg.h, and the real CV1800B/CV1801B
//     datasheet register reference (PHY_CTRL VBUS bits, not present in
//     any reference driver this project has source for).
//   - Split-transaction (SSPLIT/CSPLIT) engine: circle-stdlib
//     (github.com/rsta2/circle) lib/usb/dwhciframeschedper.cpp
//     (CDWHCIFrameSchedulerPeriodic — interrupt/isoc splits) and
//     dwhciframeschednper.cpp (CDWHCIFrameSchedulerNonPeriodic —
//     control/bulk splits), cross-checked against the real state
//     machine driving them in dwhcidevice.cpp
//     (StageStateStartSplit/StageStateCompleteSplit). Circle's own
//     "dwhci" core is the same DWC2 IP family, proven on real hardware
//     (a working Xbox 360-behind-a-hub driver, usbgamepadxbox360.cpp).

// Off by default — set true for verbose register-level bring-up
// tracing (RST_USB toggled, PHY_CTRL set, core reset done, FIFO sizing,
// etc.) and the per-poll interrupt-split diagnostic prints. Meaningful,
// low-frequency status (device connected, enumerated device info, hub
// port status, real errors) always prints regardless.
const bool USBD_VERBOSE = false;

// --- DWC2 core registers (relative to board::USB_MMIO_BASE) — all fit
// in the first 4KB page, nothing here needs the other 15 pages of the
// core's own 64KB window.
const uint USB_GOTGCTL  = 0x000;
const uint USB_GAHBCFG  = 0x008;
const uint USB_GAHBCFG_GLBL_INTR_EN = 1 << 0; // real DWC2 silicon gates internal core event processing behind this, not just the external IRQ line — required even though this driver polls HCINT directly and never handles a real CPU interrupt (GINTMSK stays fully masked, so this can't cause a spurious one). Confirmed needed: without it, every periodic (interrupt-type) transfer NAKed forever while control transfers on the same channel worked fine.
const uint USB_GUSBCFG  = 0x00C;
const uint USB_GRSTCTL  = 0x010;
const uint USB_GINTSTS  = 0x014;
const uint USB_GRXFSIZ   = 0x024;
const uint USB_GNPTXFSIZ = 0x028;
const uint USB_GSNPSID  = 0x040;
const uint USB_GHWCFG2  = 0x048; // fixed, synthesis-time core capability bits (HS_PHY_TYPE, ARCHITECTURE, NUM_HOST_CHAN) — see usbd_init()'s own readback
const uint USB_GHWCFG3  = 0x04C; // fixed, synthesis-time — DFIFO_DEPTH field is this core's total shared FIFO RAM, in 32-bit words
const uint USB_HPTXFSIZ = 0x100;
const uint USB_GDFIFOCFG = 0x05C; // required whenever "dedicated/multiple Tx FIFO" mode is active (GHWCFG2.DYNAMIC_FIFO=1 on this core)
const uint USB_HCFG     = 0x400;
const uint USB_HFNUM    = 0x408; // host frame number — low 3 bits are the current microframe (0-7), used for periodic split scheduling; struct dwc2_host_regs: hcfg(0x400), hfir(0x404), hfnum(0x408)
const uint USB_HPRT0    = 0x440;
// Power and Clock Gating Control — U-Boot's own dwc_otg_core_host_init()
// writes 0 here as its very first host-init step ("Restart the Phy
// Clock" — clears STOPPCLK/GATEHCLK/PWRCLMP/etc). Required: without it
// HPRT0/GOTGCTL.CONIDSTS stay frozen at reset defaults regardless of any
// other register fix — the signature of an entire clock domain gated
// off, not a wrong bit value.
const uint USB_PCGCCTL  = 0xE00;

// --- Host channel 0 registers — every real device this driver
// enumerates directly (the IO board's own hub, and whatever's plugged
// into one of its ports) uses channel 0 only, no multi-channel
// scheduling. Offsets/bit fields sourced from duo-buildroot-sdk's own
// U-Boot dwc2.c/.h (struct dwc2_hc_regs, channel 0 base 0x500, 0x20
// bytes per channel) and cross-checked against real vendor Linux's
// drivers/usb/dwc2/hw.h.
const uint USB_HC0_HCCHAR   = 0x500;
const uint USB_HC0_HCSPLT   = 0x504;
const uint USB_HC0_HCINT    = 0x508;
const uint USB_HC0_HCINTMSK = 0x50C;
const uint USB_HC0_HCTSIZ   = 0x510;
const uint USB_HC0_HCDMA    = 0x514;

const uint USB_HCCHAR_MPS_MASK      = 0x7FF;      // bits 10:0
const uint USB_HCCHAR_EPNUM_SHIFT   = 11;
const uint USB_HCCHAR_EPDIR         = 1 << 15;    // 1 = IN
const uint USB_HCCHAR_LSPDDEV       = 1 << 17;    // low-speed device — set whenever g_device_is_low_speed is, regardless of split/non-split (see that global's own comment)
const uint USB_HCCHAR_EPTYPE_SHIFT  = 18;
const uint USB_HCCHAR_EPTYPE_CONTROL = 0;
const uint USB_HCCHAR_EPTYPE_BULK = 2;
const uint USB_HCCHAR_EPTYPE_INTERRUPT = 3;
const uint USB_HCCHAR_MULTICNT_SHIFT = 20;
const uint USB_HCCHAR_DEVADDR_SHIFT = 22;
const uint USB_HCCHAR_CHDIS         = 1 << 30;
const uint USB_HCCHAR_CHEN          = 0x80000000; // bit 31 — plain hex literal: a left-shift by 31 overflows int32 as a shift expression in this language
const uint USB_HCCHAR_ODDFRM        = 1 << 29; // periodic (interrupt/isoc) endpoints only — schedules the channel for the odd-vs-even microframe slot; see usb_split_periodic_oddfrm()

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

// HCSPLT fields — sourced from real vendor Linux (drivers/usb/dwc2/hw.h)
// and cross-checked against U-Boot's own dwc2.h — both agree exactly.
const uint USB_HCSPLT_PRTADDR_SHIFT = 0;   // hub's own downstream port number
const uint USB_HCSPLT_HUBADDR_SHIFT = 7;   // the hub's own USB device address
const uint USB_HCSPLT_XACTPOS_SHIFT = 14;
const uint USB_HCSPLT_XACTPOS_ALL   = 3;   // this driver only ever does single-packet splits (control/interrupt payloads always fit in one packet), so XACTPOS is always ALL, never BEGIN/MID/END
const uint USB_HCSPLT_COMPSPLT      = 1 << 16;
const uint USB_HCSPLT_SPLTENA       = 0x80000000; // bit 31 — see USB_HCCHAR_CHEN's own comment

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
const uint USB_ENUM_ADDR  = 1; // the root-port device (the hub)
const uint USB_DOWNSTREAM_ADDR = 2; // whatever's plugged into one of the hub's ports

// Mass Storage Class (USB Mass Storage Class Bulk-Only Transport spec):
// interface class 0x08, subclass 0x06 (SCSI transparent command set —
// the overwhelming majority of real USB flash drives/card readers),
// protocol 0x50 (Bulk-Only Transport, "BBB" — the only transport this
// driver implements; CBI/CB are obsolete and effectively unused today).
const uint USB_CLASS_MASS_STORAGE     = 0x08;
const uint USB_MSC_SUBCLASS_SCSI      = 0x06;
const uint USB_MSC_PROTOCOL_BULK_ONLY = 0x50;

// HID class (USB HID 1.11): interface class 0x03. Subclass 1 = "boot
// interface" (a fixed report layout the host can use without parsing
// the report descriptor); interface protocol 1 = keyboard, 2 = mouse.
// A gaming mouse commonly exposes BOTH a boot-mouse interface and a
// boot-keyboard companion interface (for its programmable buttons) —
// usbd.c3's dispatch checks mouse before keyboard so such a device is
// treated as the mouse it is.
const uint USB_CLASS_HID              = 0x03;
const uint USB_HID_SUBCLASS_BOOT     = 0x01;
const uint USB_HID_PROTOCOL_KEYBOARD = 0x01;
const uint USB_HID_PROTOCOL_MOUSE    = 0x02;

// Endpoint descriptor accessors (USB 2.0 spec chapter 9) — plain
// functions on a raw pointer into a Configuration descriptor blob,
// same style as eth_proto.c3's own read_be16/read_be32 helpers, rather
// than a @packed struct overlay: simpler for a handful of small
// fixed-offset reads.
const uint USB_EP_ATTR_XFERTYPE_MASK = 0x3; // bmAttributes bits [1:0]
const uint USB_EP_XFERTYPE_BULK      = 2;
const uint USB_EP_XFERTYPE_INTERRUPT = 3;

fn uint usb_ep_desc_address(char* ep_desc) { return (uint)ep_desc[2] & 0xFF; }
fn uint usb_ep_desc_xfer_type(char* ep_desc) { return (uint)ep_desc[3] & USB_EP_ATTR_XFERTYPE_MASK; }
fn uint usb_ep_desc_max_packet(char* ep_desc) { return ((uint)ep_desc[4] & 0xFF) | (((uint)ep_desc[5] & 0xFF) << 8); }
fn uint usb_ep_desc_interval(char* ep_desc) { return (uint)ep_desc[6] & 0xFF; }

// GOTGCTL — "Host only" mode bits, per the real CV1800B/CV1801B
// datasheet (register reference, section 12.6): a second, core-level
// VBUS-valid override, complementary to the TOP-block usb_phy_ctrl_reg
// bits below. Not used by usbd_init() (see its own comment for why) —
// kept here only because USB_TOP_PHY_CTRL's own comment refers to it.
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

// FIFO sizing fields — see usbd_init()'s own FIFO-sizing block for why
// GRXFSIZ/GNPTXFSIZ/HPTXFSIZ need explicit programming at all. Sourced
// from real vendor Linux (drivers/usb/dwc2/hw.h).
const uint USB_GRXFSIZ_DEPTH_MASK       = 0xFFFF;
const uint USB_FIFOSIZE_DEPTH_SHIFT     = 16;
const uint USB_FIFOSIZE_DEPTH_MASK      = 0xFFFF0000; // see USB_HCCHAR_CHEN's own comment for bit-31-and-above constants
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
// Diagnostic-only bits, not written — PRTLNSTS is a raw sample of the
// D+/D- differential pair (bit10=DP, bit11=DM on this core), true
// regardless of whether the core's own connect-detect state machine
// ever asserts PRTCONNSTS: 00 (SE0) with a device plugged in means the
// PHY isn't seeing any voltage on the bus at all (pinmux/pad/power,
// upstream of anything DWC2-register-level).
const uint USB_HPRT0_PRTLNSTS_SHIFT = 10;
const uint USB_HPRT0_PRTLNSTS_MASK  = 0x3 << USB_HPRT0_PRTLNSTS_SHIFT;
const uint USB_HPRT0_PRTSPD_SHIFT   = 17;
const uint USB_HPRT0_PRTSPD_MASK    = 0x3 << USB_HPRT0_PRTSPD_SHIFT;

// --- TOP-block registers (SoC-specific). Offsets relative to
// board::USB_TOP_CTRL_PAGE/USB_TOP_RST_PAGE respectively, each its own
// separate mapped page.
const uint USB_TOP_PHY_CTRL_OFFSET = 0x48;
// bits 0-1: real CV1800B/CV1801B datasheet ("usb_phy_ctrl_reg" @
// 0x048), not present in any reference driver this project has source
// for (they all assume an earlier boot stage already asserted them).
// Both default to 0 (VBUS treated as invalid, VBUS power not driven) —
// without them the PHY never enables its own downstream connect-
// detection logic at all.
const uint USB_TOP_PHY_CTRL_EXTERNAL_VBUSVALID = 1 << 0; // "external vbus status" — tells the PHY to treat VBUS as valid
const uint USB_TOP_PHY_CTRL_DRIVE_VBUS         = 1 << 1; // "drive vbus power"
const uint USB_TOP_PHY_CTRL_ID_OVERRIDE_ENABLE = 1 << 6;
const uint USB_TOP_PHY_CTRL_ID_VALUE           = 1 << 7; // 0=host/A-side, 1=device/B-side
const uint USB_TOP_PHY_CTRL_MASK               = 0xC3;   // bits 0,1,6,7

const uint USB_TOP_SOFT_RST_OFFSET = 0x00;
const uint USB_TOP_SOFT_RST_USB    = 1 << 11;

// ECO (engineering-change-order) errata-fix register — same physical
// page as USB_TOP_PHY_CTRL_OFFSET above. Sourced from U-Boot's own
// board_usb_init() (board/cvitek/cv180x/board.c) — written
// unconditionally, right after the PHY_CTRL write, in every mode that
// board.c initializes USB for.
const uint USB_TOP_ECO_OFFSET   = 0xB4;
const uint USB_TOP_ECO_RX_FLUSH = 0x80;

// PAD_USB_VBUS_DET pinmux function-select register — see
// board::USB_PINMUX_PAGE's own comment. Offset/mask/value sourced from
// cv180x_reg_fmux_gpio.h (FMUX_GPIO_FUNCSEL_USB_VBUS_DET) and
// cv180x_pinlist_swconfig.h (USB_VBUS_DET__USB_VBUS_DET = 0) — the same
// PINMUX_CONFIG(USB_VBUS_DET, USB_VBUS_DET) call U-Boot's own
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
const uint USB_CLK_EN_1_33K_USB  = 0x80000000; // clk_33k_usb, bit 31 — see USB_HCCHAR_CHEN's own comment
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

// Single-page DMA buffer — see process.c3's usbd_dma_paddr for the full
// explanation. Set once in main() (user/usb/usbd.c3), before
// usbd_init() runs. Real physical address AND the virtual address this
// driver reads/writes through — identity-mapped, same as every device
// MMIO page this driver already touches.
uptr usb_dma_paddr;

// Split-transaction context — set once per device before talking to
// it, consulted by hc_transfer_once for every transfer to that device
// until reset for the next one. Global, single-context state is safe
// here the same way usb_dma_paddr is: this driver only ever talks to
// one device at a time, sequentially, single-threaded. Never split when
// talking to the hub itself (its own control/status-endpoint transfers
// always go straight to the root port) — only set true for a
// downstream device that isn't itself Hi-Speed while the root port
// negotiated Hi-Speed.
bool g_split_active = false;
uint g_split_hub_addr = 0;
uint g_split_hub_port = 0;
uint g_split_intr_diag_count = 0; // diagnostic-only, see hc_transfer_once_split's own USBD_VERBOSE-gated prints

// Real, sourced gap found on real hardware (docs/devlog.md): every
// device this driver had ever talked to before now was full or
// Hi-Speed, so HCCHAR.LSPDDEV ("low-speed device") was never once
// exercised — a genuinely low-speed device behind the hub immediately
// failed enumeration (start-split not ACKed / STALL nonsense) the
// first time one showed up. Scoped the same way g_split_active/
// g_split_hub_addr/g_split_hub_port already are: single global device-
// context state, set once per device in usb_set_split_context, since
// this driver only ever talks to one device at a time.
bool g_device_is_low_speed = false;

fn void usb_set_split_context(bool active, uint hub_addr, uint hub_port, bool is_low_speed)
{
    g_split_active = active;
    g_split_hub_addr = hub_addr;
    g_split_hub_port = hub_port;
    g_device_is_low_speed = is_low_speed;
}

const char[16] HEX_DIGITS = "0123456789abcdef";

fn void print_hex32(uint v)
{
    for (int shift = 28; shift >= 0; shift -= 4)
    {
        putchar(HEX_DIGITS[(v >> shift) & 0xF]);
    }
}

fn void print_hex8(uint v)
{
    putchar(HEX_DIGITS[(v >> 4) & 0xF]);
    putchar(HEX_DIGITS[v & 0xF]);
}

// Gated by USBD_VERBOSE — for the one-time-but-verbose register-level
// bring-up milestones. Meaningful, low-frequency status uses plain
// print() and stays visible regardless — see USBD_VERBOSE's own
// comment.
fn void usbd_vprint(char* msg)
{
    if (!USBD_VERBOSE) { return; }
    print("usbd: ");
    print(msg);
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
// through a reset). Sequence matches real Linux dwc2_core_reset()
// (duo-buildroot-sdk's linux_5.10/drivers/usb/dwc2/core.c), not
// U-Boot's simpler version:
//   1. CSFTRST is asserted immediately, with no AHBIDLE poll before it
//      — Linux only checks AHBIDLE AFTER the reset completes.
//   2. For cores at or above revision 4.20a (this core's GSNPSID reads
//      back as exactly 0x4f54420a, DWC2_CORE_REV_4_20a), after seeing
//      GSFTRST_DONE set, Linux does an explicit write-back: read
//      GRSTCTL, clear CSFTRST, set CSFTRST_DONE, write it back.
// The flat ≥100ms settle delay at the end (U-Boot's own comment: "very
// important, otherwise core will not stay in host mode") is kept even
// though real Linux has no equivalent fixed sleep here — cheap
// insurance, harmless either way.
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
    // PAD_USB_VBUS_DET pinmux — mirrors U-Boot's own board_init()
    // ordering (pinmux_config(PINMUX_USB) runs before board_usb_init()
    // touches any DWC2/TOP-block register at all).
    uint pinmux = pinmux_read(USB_PINMUX_VBUS_DET_OFFSET);
    pinmux = (pinmux & ~USB_PINMUX_VBUS_DET_MASK) | USB_PINMUX_VBUS_DET_FUNC;
    pinmux_write(USB_PINMUX_VBUS_DET_OFFSET, pinmux);
    usbd_vprint("PAD_USB_VBUS_DET pinmux set\n");

    // The USB PHY's own reference clocks — clk_125m_usb/clk_33k_usb
    // (REG_CLK_EN_1 bits 30/31) and clk_12m_usb (REG_CLK_EN_2 bit 0).
    // Done first, before touching RST_USB: these feed the analog PHY
    // itself, separate from clk_axi4_usb/clk_apb_usb (bits 28/29,
    // already enabled by default — proven by every DWC2 register
    // read/write below succeeding). Read-modify-write: REG_CLK_EN_1/_2
    // control many other, unrelated peripherals' own clocks too.
    uint clk_en_1 = clk_reg_read(USB_CLK_EN_1_OFFSET);
    clk_en_1 |= USB_CLK_EN_1_125M_USB | USB_CLK_EN_1_33K_USB;
    clk_reg_write(USB_CLK_EN_1_OFFSET, clk_en_1);
    uint clk_en_2 = clk_reg_read(USB_CLK_EN_2_OFFSET);
    clk_en_2 |= USB_CLK_EN_2_12M_USB;
    clk_reg_write(USB_CLK_EN_2_OFFSET, clk_en_2);
    usbd_vprint("PHY reference clocks enabled\n");

    // TOP block: RST_USB assert -> real delay -> deassert.
    uint soft_rst = top_rst_read(USB_TOP_SOFT_RST_OFFSET);
    top_rst_write(USB_TOP_SOFT_RST_OFFSET, soft_rst & ~USB_TOP_SOFT_RST_USB);
    ulong rst_start = rdtime();
    while (rdtime() - rst_start < usb_us_to_ticks(50)) { yield(); }
    soft_rst = top_rst_read(USB_TOP_SOFT_RST_OFFSET);
    top_rst_write(USB_TOP_SOFT_RST_OFFSET, soft_rst | USB_TOP_SOFT_RST_USB);
    usbd_vprint("RST_USB toggled\n");

    // TOP block: force OTG ID override to host/A-side. Matches, bit-
    // for-bit, the real vendor Linux DWC2 glue driver's own
    // dwc2_set_hw_id() (duo-buildroot-sdk's
    // linux_5.10/drivers/usb/dwc2/platform.c) — the mechanism behind
    // /mnt/system/usb-host.sh's `echo host > /proc/cviusb/otg_role`.
    // Its host-mode write is `(read & ~0xC0) | 0x40` — clear bits 6-7,
    // set bit6 only. Never touches bits 0-1 (EXTERNAL_VBUSVALID/
    // DRIVE_VBUS) and never sets ID_VALUE (bit7) either. Host mode
    // itself comes entirely from GUSBCFG.FORCEHOSTMODE below, not from
    // GOTGCTL.CONIDSTS.
    uint phy_ctrl = top_ctrl_read(USB_TOP_PHY_CTRL_OFFSET);
    phy_ctrl = (phy_ctrl & ~(USB_TOP_PHY_CTRL_ID_OVERRIDE_ENABLE | USB_TOP_PHY_CTRL_ID_VALUE))
        | USB_TOP_PHY_CTRL_ID_OVERRIDE_ENABLE;
    top_ctrl_write(USB_TOP_PHY_CTRL_OFFSET, phy_ctrl);
    usbd_vprint("PHY_CTRL ID override -> host (A-side), matching vendor dwc2_set_hw_id()\n");

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
    // else — same pattern user/block/diskd.c3's own VIRTIO_REG_MAGIC
    // check already establishes.
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

    // GHWCFG2 — fixed, synthesis-time core capability bits (unlike
    // everything else this driver touches). HS_PHY_TYPE confirms the
    // UTMI+ assumption (GUSBCFG.PHYIF below); ARCHITECTURE determines
    // whether GAHBCFG needs DMA-related bits set.
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

    // GAHBCFG — internal-DMA cores (GHWCFG2.ARCHITECTURE==2, this core)
    // get HBURSTLEN_INCR4, matching the real devicetree node's own
    // `g-use-dma;`. GLBL_INTR_EN set too — see its own constant comment
    // above for why.
    uint architecture = (hwcfg2 >> 3) & 0x3;
    uint ahbcfg = 1 << 5; // DMAENABLE
    if (architecture == 2) // int_dma
    {
        ahbcfg |= (3 << 1); // HBURSTLEN_INCR4
    }
    ahbcfg |= USB_GAHBCFG_GLBL_INTR_EN;
    usb_reg_write(USB_GAHBCFG, ahbcfg);
    usbd_vprint("GAHBCFG programmed (DMA enabled, GLBL_INTR_EN set)\n");

    // Restart the PHY clock — see USB_PCGCCTL's own comment. This is
    // dwc_otg_core_host_init()'s own first step in the reference
    // driver, right after forcing host mode and before HCFG/HPRT0.
    usb_reg_write(USB_PCGCCTL, 0);
    usbd_vprint("PCGCCTL cleared (PHY clock restarted)\n");

    // HCFG: FSLSPCLKSEL = 30-60MHz, correct for the HS UTMI PHY. This
    // driver lets the root port negotiate its native Hi-Speed (no
    // FSLSSUPP force-full-speed-only) and uses real split transactions
    // (hc_transfer_once_split) for any downstream device that isn't
    // itself Hi-Speed.
    uint hcfg = usb_reg_read(USB_HCFG);
    hcfg = (hcfg & ~USB_HCFG_FSLSPCLKSEL_MASK) | USB_HCFG_FSLSPCLKSEL_30_60MHZ;
    usb_reg_write(USB_HCFG, hcfg);

    // Rx FIFO / Non-periodic Tx FIFO / Periodic Tx FIFO sizing —
    // required because GHWCFG2.DYNAMIC_FIFO=1 on this core, meaning
    // these three FIFOs share one contiguous block of FIFO RAM and
    // their DEPTH+START-ADDRESS fields must be explicitly written at
    // host init. Values are the real vendor Linux 5.10's own computed
    // `params` for this exact board (confirmed via its debugfs
    // /sys/kernel/debug/usb/4340000.usb/hw_params on real hardware):
    // host_rx_fifo_size=530, host_nperio_tx_fifo_size=256,
    // host_perio_tx_fifo_size=768 (sum 1554, comfortably under the
    // real 3072-word total budget reported by GHWCFG3.DFIFO_DEPTH,
    // leaving spare room for the "dedicated/multiple Tx FIFO" per-
    // channel table GDFIFOCFG points at below). Hardcoded, not
    // recomputed — this is the same physical silicon every time.
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

    // GDFIFOCFG.EPINFOBASE — points at where the per-channel dedicated
    // FIFO info table begins, right after the three main FIFOs
    // actually end (rx_depth+nptx_depth+ptx_depth), not the full
    // total_fifo_words budget.
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
    // risks sampling a genuine power-up transient.
    ulong power_settle_start = rdtime();
    while (rdtime() - power_settle_start < usb_us_to_ticks(100000)) { yield(); }
    print_hprt0_raw("post-power-settle");

    // Clear any stale W1C event bits (PRTCONNDET/PRTENCHNG/etc) that
    // may have latched during power-up, so the main polling loop below
    // starts from a genuinely clean slate.
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

// --- Host-channel transfer engine, and the USB/hub-class request
// builders on top of it.

// Waits for CHHLTD (channel halted — the transfer attempt is over, one
// way or another). Shared by every transfer path below (plain, split
// start, split complete). Returns 0 with *hcint_out set on success, -1
// on a real timeout (2s budget — generous, real transfers complete in
// microseconds to low milliseconds; only ever fires on a genuinely
// wedged channel).
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

// Single host-channel transfer, no split: programs HCTSIZ/HCDMA/HCCHAR,
// enables the channel, and waits for CHHLTD. Returns 0 on real success
// (XFERCOMP), 1 on NAK/FRMOVRUN (caller should retry — completely
// normal while a device is still processing a request), -1 on anything
// else (STALL, transaction/babble error, or a CHHLTD timeout).
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
        | (dev_addr << USB_HCCHAR_DEVADDR_SHIFT)
        | (g_device_is_low_speed ? USB_HCCHAR_LSPDDEV : 0);
    usb_reg_write(USB_HC0_HCCHAR, hcchar);

    // Explicitly disable split (SPLTENA) in case a stray bit survived
    // from an earlier split-transaction attempt on this same channel.
    usb_reg_write(USB_HC0_HCSPLT, 0);

    // Clear stale interrupt state before this attempt — standard DWC2
    // idiom.
    usb_reg_write(USB_HC0_HCINT, USB_HCINT_ALL_MASK);

    // Periodic (interrupt/isoc) endpoints are scheduled against the
    // core's own internal odd/even frame list — U-Boot's own
    // chunk_msg() reads HFNUM and sets HCCHAR.ODDFRM for exactly this
    // case, leaving it 0 (even) for every other endpoint type.
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

// Current microframe (0-7) — the low 3 bits of HFNUM's own frame
// counter, which increments once per microframe (125us) regardless of
// device speed. Used only by the periodic (interrupt) split scheduler
// below; circle-stdlib's own CDWHCIFrameSchedulerPeriodic (Raspberry
// Pi's "dwhci" driver for the same DWC2 IP family) reads this exact
// field the same way.
fn uint usb_hfnum_microframe() { return usb_reg_read(USB_HFNUM) & 0x7; }

// Busy-waits, deliberately WITHOUT yield(), until the current
// microframe equals target_mf. Real hardware split-transaction
// scheduling for a periodic endpoint is microframe-precise (125us) —
// see CDWHCIFrameSchedulerPeriodic::WaitForFrame() in circle-stdlib's
// lib/usb/dwhciframeschedper.cpp, which does the same busy-wait against
// this same field, bare-metal with no scheduler underneath it at all.
//
// This driver's own yield() (src/process.c3's own fn yield()) is not a
// lightweight "let something else run if it wants to" — it
// unconditionally round-robins to the next RUNNABLE process and full-
// context-switches to it, only returning once every other runnable
// process (ethd, fsd, the shell — always present in this environment)
// has had its own turn, easily costing far more than 125us. Kept
// yield()-free even though a real-hardware round with it removed
// changed nothing: same 100%-reproducible, zero-variance complete-split
// NAK as with yield() in the loop (see hc_transfer_once_split's own
// header comment for the full trace, docs/devlog.md) — ruling out
// scheduling jitter as the cause of that specific failure, but this is
// still the architecturally correct way to hit a 125us target, so it
// stays.
//
// This is a deliberate, narrow exception to the yield()-everywhere
// convention elsewhere in this driver (see SYS_YIELD's own comment,
// src/entry.c3, for the real deadlock it exists to avoid: SIE stays
// globally disabled while the shell idles in SYS_GETCHAR, so a
// genuinely unbounded syscall-free spin elsewhere can wedge the whole
// system). That risk doesn't apply here in the same way: this loop is
// bounded to a short, fixed real-time budget via rdtime() — a plain CSR
// read, no syscall, unaffected by SIE — so it always terminates on its
// own regardless of interrupt state; worst case is a brief, bounded
// stall of interrupt servicing (a few hundred us, at most a handful of
// times per bInterval poll), not a hang.
fn void usb_wait_for_microframe(uint target_mf)
{
    ulong start = rdtime();
    ulong budget = usb_us_to_ticks(3000);
    while (usb_hfnum_microframe() != target_mf)
    {
        if (rdtime() - start > budget) { return; }
    }
}

// ODDFRM for the current instant, circle-stdlib's own polarity
// (CDWHCIFrameSchedulerPeriodic::IsOddFrame(): set HCCHAR.ODDFRM when
// the current frame counter reads odd). Read right before each
// channel-enable, after any microframe alignment wait, so it reflects
// the frame the transaction will actually execute in.
fn uint usb_split_periodic_oddfrm()
{
    return (usb_reg_read(USB_HFNUM) & 0x1) != 0 ? USB_HCCHAR_ODDFRM : 0;
}

// Split-transaction (SSPLIT/CSPLIT) version of hc_transfer_once — used
// whenever g_split_active is set: the root port negotiated Hi-Speed but
// the target device, behind the IO board's own hub, is only full/low-
// speed.
//
// One logical transfer attempt here is two physical bus transactions: a
// start-split (COMPSPLT=0) addressed to the HUB, asking it to relay the
// real transaction to the downstream device; then one or more complete-
// split (COMPSPLT=1) polls asking the hub "is the relayed result ready
// yet." Returns 0 on real success (XFERCOMP), 1 on a retryable outcome
// (caller should try again — usb_control_transfer's own NAK-budget
// retry loop, or the next externally bInterval-paced call to
// usb_interrupt_poll), -1 on a real error.
//
// Control/bulk splits (eptype != INTERRUPT) use circle-stdlib's own
// CDWHCIFrameSchedulerNonPeriodic shape: no microframe alignment, retry
// the SAME complete-split within a short elapsed-frame budget. Real-
// hardware confirmed working end to end (a full multi-packet
// configuration descriptor fetch through the hub).
//
// Interrupt splits use circle-stdlib's own CDWHCIFrameSchedulerPeriodic
// shape instead (lib/usb/dwhciframeschedper.cpp, cross-checked against
// the StageStateStartSplit/StageStateCompleteSplit state machine in
// lib/usb/dwhcidevice.cpp that drives it) — every prior attempt at this
// driver's own interrupt-split logic (faithfully replicating mainline
// Linux, U-Boot, and TinyUSB's own retry shape, all frame- not
// microframe-scheduled, and all conflating NAK with NYET) produced a
// deterministic NYET with no XFERCOMP ever, on real hardware (full
// trace in docs/devlog.md). This is a materially different, real
// algorithm — confirmed real-hardware-working for the OUT direction
// (usbd.c3's own xpad LED-set command completes with a clean XFERCOMP,
// the first split interrupt transaction of any direction this project
// has ever gotten to complete), still not observed on the IN direction
// despite that confirmation — the scheduling mechanics below are sound;
// whatever's stopping the pad's own interrupt IN endpoint from ever
// returning real data is downstream of this function, not in it. Full
// shape:
//   - Start-split issues at a specific target microframe: current+1,
//     bumped to 7 if that lands on 6 (microframe 6 is always skipped).
//   - Anything but a clean ACK on the start-split is a hard give-up for
//     this poll (no internal retry loop) — the caller's own bInterval
//     pacing is what re-submits a fresh start-split, exactly as
//     circle's own QueueDelayedTransaction()/PeriodicDelay() do.
//   - The first complete-split poll targets start_mf+2; each retry
//     after a NYET/ACK advances the target by exactly 1 microframe.
//   - Retry budget is 3 (2 if start_mf==5, matching circle's own
//     near-end-of-window adjustment), checked-then-decremented so the
//     real attempt count is budget+1.
//   - NAK on a complete-split is NOT retried — immediate give-up.
//     Per USB2 semantics a complete-split NAK usually means "the hub
//     has nothing new to report" (the normal steady state for an idle
//     interrupt endpoint), while NYET means "still relaying, ask again
//     very soon" — every prior version of this driver conflated the
//     two, retrying NAK the same as NYET and burning the whole budget
//     on polls that could never turn into data this cycle.
fn int hc_transfer_once_split(uint dev_addr, uint ep_num, uint eptype, bool is_in, uint pid, uint max_packet, uint xfer_len, uint num_packets, uint* actual_len_out)
{
    bool is_interrupt = eptype == USB_HCCHAR_EPTYPE_INTERRUPT;

    // MULTICNT=3 for interrupt/isoc splits, matching real vendor Linux
    // 5.10's own dwc2_hc_start_transfer() (duo-buildroot-sdk's
    // linux_5.10/drivers/usb/dwc2/hcd.c: `if (ep_type == INT || ISOC)
    // ec_mc = 3; else ec_mc = 1;`, its own comment: "for immediate
    // retries") — the authoritative reference for THIS exact silicon,
    // and the same value U-Boot's own chunk_msg() independently uses.
    // circle-stdlib always uses 1 instead, but circle targets a
    // different SoC's own DWC2 integration (Raspberry Pi's "dwhci"),
    // not this one — real-hardware A/B round on this exact board found
    // zero observable difference between 1 and 3 either way (same
    // complete-split NAK signature, byte-identical — docs/devlog.md),
    // so this follows the SoC-matched reference rather than circle's
    // own value where the two genuinely disagree.
    uint multicnt = is_interrupt ? 3 : 1;
    uint hcchar = (max_packet & USB_HCCHAR_MPS_MASK)
        | (ep_num << USB_HCCHAR_EPNUM_SHIFT)
        | (is_in ? USB_HCCHAR_EPDIR : 0)
        | (eptype << USB_HCCHAR_EPTYPE_SHIFT)
        | (multicnt << USB_HCCHAR_MULTICNT_SHIFT)
        | (dev_addr << USB_HCCHAR_DEVADDR_SHIFT)
        | (g_device_is_low_speed ? USB_HCCHAR_LSPDDEV : 0);

    uint hcsplt_base = USB_HCSPLT_SPLTENA
        | (g_split_hub_addr << USB_HCSPLT_HUBADDR_SHIFT)
        | (g_split_hub_port << USB_HCSPLT_PRTADDR_SHIFT)
        | (USB_HCSPLT_XACTPOS_ALL << USB_HCSPLT_XACTPOS_SHIFT);

    bool diag_this_call = USBD_VERBOSE && is_interrupt && g_split_intr_diag_count < 10;

    // --- Start-split. Interrupt splits align to a specific target
    // microframe first (see this function's own header comment);
    // control/bulk splits issue immediately, matching circle's own
    // CDWHCIFrameSchedulerNonPeriodic::WaitForFrame(), which is a no-op
    // for the polling (non-SOF-interrupt) case this driver's own
    // architecture matches.
    uint start_oddfrm = 0;
    if (is_interrupt)
    {
        uint target_mf = (usb_hfnum_microframe() + 1) & 0x7;
        if (target_mf == 6) { target_mf = 7; }
        usb_wait_for_microframe(target_mf);
        start_oddfrm = usb_split_periodic_oddfrm();
    }

    uint start_hctsiz = (xfer_len & USB_HCTSIZ_XFERSIZE_MASK)
        | (num_packets << USB_HCTSIZ_PKTCNT_SHIFT)
        | (pid << USB_HCTSIZ_PID_SHIFT);
    usb_reg_write(USB_HC0_HCTSIZ, start_hctsiz);
    usb_reg_write(USB_HC0_HCDMA, (uint)usb_dma_paddr);
    usb_reg_write(USB_HC0_HCCHAR, hcchar);
    usb_reg_write(USB_HC0_HCSPLT, hcsplt_base);
    usb_reg_write(USB_HC0_HCINT, USB_HCINT_ALL_MASK);
    usb_reg_write(USB_HC0_HCCHAR, hcchar | USB_HCCHAR_CHEN | start_oddfrm);

    uint hcint;
    if (hc_wait_chhltd(&hcint) != 0) { return -1; }
    usb_reg_write(USB_HC0_HCINT, USB_HCINT_ALL_MASK);

    if (!(hcint & USB_HCINT_ACK))
    {
        if (hcint & USB_HCINT_NAK) { return 1; }
        if (hcint & USB_HCINT_FRMOVRUN) { return 1; }
        print("usbd: hc_transfer_once_split: start-split not ACKed, HCINT=0x");
        print_hex32(hcint);
        print("\n");
        return -1;
    }

    uint start_mf = usb_hfnum_microframe();
    uint cur_pid = pid;

    if (is_interrupt)
    {
        // --- Complete-split, periodic scheduling (circle's
        // CDWHCIFrameSchedulerPeriodic::CompleteSplit()/
        // TransactionComplete() — see this function's own header
        // comment for the full shape).
        uint tries = start_mf == 5 ? 2 : 3;
        uint target_mf = (start_mf + 2) & 0x7;

        for (;;)
        {
            usb_wait_for_microframe(target_mf);
            uint csplit_oddfrm = usb_split_periodic_oddfrm();

            // Real vendor Linux 5.10's own dwc2_hc_start_transfer()
            // (duo-buildroot-sdk's linux_5.10/drivers/usb/dwc2/hcd.c):
            // "For CSPLIT OUT Transfer, set the size to 0 so the core
            // doesn't expect any data written to the FIFO" — the OUT
            // payload was already pushed during the start-split; a
            // complete-split OUT only polls "is it done," no new FIFO
            // write. IN keeps the real max_packet size regardless of
            // start/complete, matching that same function's own
            // `chan->ep_is_in || ... ` branch.
            uint csplit_xfer_len = is_in ? xfer_len : 0;
            uint csplit_hctsiz = (csplit_xfer_len & USB_HCTSIZ_XFERSIZE_MASK)
                | (num_packets << USB_HCTSIZ_PKTCNT_SHIFT)
                | (cur_pid << USB_HCTSIZ_PID_SHIFT);
            usb_reg_write(USB_HC0_HCTSIZ, csplit_hctsiz);
            usb_reg_write(USB_HC0_HCDMA, (uint)usb_dma_paddr);
            usb_reg_write(USB_HC0_HCCHAR, hcchar);
            usb_reg_write(USB_HC0_HCSPLT, hcsplt_base | USB_HCSPLT_COMPSPLT);
            usb_reg_write(USB_HC0_HCINT, USB_HCINT_ALL_MASK);
            usb_reg_write(USB_HC0_HCCHAR, hcchar | USB_HCCHAR_CHEN | csplit_oddfrm);

            if (hc_wait_chhltd(&hcint) != 0) { return -1; }

            uint hctsiz_after = usb_reg_read(USB_HC0_HCTSIZ);
            uint remaining = hctsiz_after & USB_HCTSIZ_XFERSIZE_MASK;
            *actual_len_out = xfer_len - remaining;
            cur_pid = (hctsiz_after >> USB_HCTSIZ_PID_SHIFT) & 0x3;
            usb_reg_write(USB_HC0_HCINT, USB_HCINT_ALL_MASK);

            if (hcint & (USB_HCINT_STALL | USB_HCINT_XACTERR | USB_HCINT_BBLERR | USB_HCINT_FRMOVRUN))
            {
                print("usbd: hc_transfer_once_split: complete-split real error, HCINT=0x");
                print_hex32(hcint);
                print(hcint & USB_HCINT_STALL ? " (STALL)" : "");
                print(hcint & USB_HCINT_XACTERR ? " (XACTERR)" : "");
                print(hcint & USB_HCINT_BBLERR ? " (BBLERR)" : "");
                print(hcint & USB_HCINT_FRMOVRUN ? " (FRMOVRUN)" : "");
                print("\n");

                // Real recovery action for exactly this signature — see
                // usb_clear_tt_buffer's own header comment. Not STALL:
                // a STALL is the *device* deliberately refusing the
                // request, not a TT-buffer-level error, and real Linux
                // doesn't clear the TT for that case either.
                if (hcint & (USB_HCINT_XACTERR | USB_HCINT_BBLERR | USB_HCINT_FRMOVRUN))
                {
                    if (usb_clear_tt_buffer(g_split_hub_addr, g_split_hub_port, dev_addr, ep_num, eptype, is_in))
                    {
                        print("usbd: hc_transfer_once_split: CLEAR_TT_BUFFER sent\n");
                    }
                    else
                    {
                        print("usbd: hc_transfer_once_split: CLEAR_TT_BUFFER failed\n");
                    }
                }
                return -1;
            }

            if (hcint & USB_HCINT_XFERCOMP)
            {
                if (diag_this_call)
                {
                    g_split_intr_diag_count++;
                    print("usbd: split intr diag #");
                    print_uint(g_split_intr_diag_count);
                    print(": XFERCOMP\n");
                }
                return 0;
            }

            if (hcint & (USB_HCINT_NYET | USB_HCINT_ACK))
            {
                if (tries == 0)
                {
                    if (diag_this_call)
                    {
                        g_split_intr_diag_count++;
                        print("usbd: split intr diag #");
                        print_uint(g_split_intr_diag_count);
                        print(": gave up, last HCINT=0x");
                        print_hex32(hcint);
                        print("\n");
                    }
                    return 1;
                }
                tries--;
                target_mf = (target_mf + 1) & 0x7;
                continue;
            }

            // NAK — no retry, see this function's own header comment.
            if (diag_this_call)
            {
                g_split_intr_diag_count++;
                print("usbd: split intr diag #");
                print_uint(g_split_intr_diag_count);
                print(": complete-split NAK, no retry\n");
            }
            return 1;
        }
    }

    // --- Complete-split, control/bulk (non-periodic): retry the SAME
    // complete-split within a short elapsed-frame budget. Real,
    // sourced from U-Boot's own chunk_msg() and confirmed working —
    // kept exactly as-is.
    uint ssplit_frame = usb_reg_read(USB_HFNUM) & 0xFFFF;
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
        usb_reg_write(USB_HC0_HCCHAR, hcchar | USB_HCCHAR_CHEN);

        if (hc_wait_chhltd(&hcint) != 0) { return -1; }

        uint hctsiz_after = usb_reg_read(USB_HC0_HCTSIZ);
        uint remaining = hctsiz_after & USB_HCTSIZ_XFERSIZE_MASK;
        *actual_len_out = xfer_len - remaining;
        cur_pid = (hctsiz_after >> USB_HCTSIZ_PID_SHIFT) & 0x3;
        usb_reg_write(USB_HC0_HCINT, USB_HCINT_ALL_MASK);

        if (hcint & USB_HCINT_XFERCOMP) { return 0; }

        if (hcint & (USB_HCINT_NYET | USB_HCINT_NAK))
        {
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
}

// Full 3-stage control transfer: SETUP (always 8 bytes, PID=SETUP) ->
// optional DATA stage (buf_len bytes, PID starts DATA1 — control
// endpoints always restart their toggle at DATA1 after a SETUP stage,
// regardless of any previous transfer's own final toggle state) ->
// STATUS stage (zero length, opposite direction of the data stage, or
// IN if there was no data stage at all). setup8 must point at exactly 8
// bytes, formatted per USB 2.0 spec chapter 9's own SETUP packet
// layout. On a successful IN data stage, copies up to buf_len bytes (or
// however many the device actually returned, if fewer) into out_buf.
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
    // stage — back-to-back reprogramming with zero delay after CHHLTD
    // has produced a persistent STALL on real hardware.
    ulong interstage_start = rdtime();
    while (rdtime() - interstage_start < usb_us_to_ticks(2000)) { yield(); }

    if (buf_len > 0)
    {
        if (g_split_active)
        {
            // A split transaction can only relay one packet per
            // SSPLIT/CSPLIT cycle — unlike a non-split transfer, where
            // HCTSIZ.PktCnt lets the DMA engine autonomously burst
            // through every packet in a single hc_transfer_once call.
            // U-Boot's own chunk_msg() handles this by forcing
            // num_packets=1 and looping at the message level for every
            // max_packet-sized chunk, reusing one small DMA bounce
            // buffer — this does the same, reusing this driver's own
            // single usb_dma_paddr buffer per chunk since transfers are
            // always sequential.
            uint done = 0;
            // Successive packets within one multi-packet DATA stage
            // alternate DATA1/DATA0 (standard USB toggle rule) —
            // normally autonomous within a single non-split
            // hc_transfer_once call, but here this loop issues each
            // packet itself, so it tracks the toggle explicitly.
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
            // Every current caller only ever does IN data stages
            // (GET_*), so this is currently unreachable — kept for
            // correctness anyway, symmetric with the IN-side copy
            // below.
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

// --- Bulk transfers — same shape as usb_control_transfer()'s own DATA
// stage (split-aware chunking with manual PID-toggle tracking when
// g_split_active, single multi-packet burst otherwise) but standalone:
// no SETUP/STATUS wrapping, and the PID toggle persists ACROSS calls
// via *pid_toggle_inout, the same contract as usb_interrupt_poll()'s
// own pid_toggle_inout — bulk endpoints are hardware-toggle-maintained
// exactly like interrupt ones (USB 2.0 spec 5.8.4); the toggle only
// resets on SET_CONFIGURATION/SET_INTERFACE/CLEAR_FEATURE(ENDPOINT_HALT),
// never per-transfer.
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
    // blind software flip.
    uint hctsiz_after = usb_reg_read(USB_HC0_HCTSIZ);
    *pid_toggle_inout = (hctsiz_after >> USB_HCTSIZ_PID_SHIFT) & 0x3;
    return true;
}

// --- Interrupt transfers — a single DATA-stage-shaped IN poll, no
// SETUP/STATUS wrapping unlike a control transfer (confirmed against
// U-Boot's own dwc2.c: its own interrupt-transfer path is really just
// the bulk path — chunk_msg()/wait_for_chhltd() reused as-is, called
// repeatedly by the polling caller).
//
// PID toggle is NOT reset to DATA1 every call the way control's own
// DATA/STATUS stages always are — interrupt/bulk endpoints persist
// their own toggle ACROSS transfers, hardware-maintained: HCTSIZ.PID
// after a successful transfer already holds the value the NEXT
// transfer should use. *pid_toggle_inout carries that state across
// calls.
//
// Returns true only on a real new report (XFERCOMP). NAK is not an
// error here, unlike usb_control_transfer()'s own budget-and-fail
// policy — for a HID-style interrupt endpoint NAK just means "nothing
// new since last poll," so this returns false immediately rather than
// retrying against a timeout. A genuine STALL or transaction error also
// returns false (hc_transfer_once/hc_transfer_once_split already
// printed the detail).
uint g_usb_intr_poll_count = 0; // diagnostic-only, USBD_VERBOSE-gated below

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

// One-shot interrupt OUT transfer — for device-specific init commands
// sent right after enumeration, before any polling starts (e.g. the
// xpad LED-set command usbd.c3's own xpad enumeration sends; see that
// call site's own comment for why this exists at all). PID hardcoded
// to DATA0: interrupt/bulk endpoints always start at DATA0 right after
// SET_CONFIGURATION (same reasoning as usbd_xpad_read_loop's own
// pid_toggle initialization), and this is only ever used for the very
// first OUT transfer to a freshly configured endpoint — a real toggle-
// tracking *pid_toggle_inout would be needed for a second call, not
// implemented since nothing in this driver sends more than one.
fn bool usb_interrupt_transfer_out(uint dev_addr, uint ep_num, uint max_packet, void* buf, uint buf_len)
{
    mem::copy((void*)usb_dma_paddr, buf, buf_len);

    uint actual_len;
    int result;
    ulong nak_budget = usb_us_to_ticks(1000000);
    ulong stage_start = rdtime();
    for (;;)
    {
        result = hc_transfer_once(dev_addr, ep_num, USB_HCCHAR_EPTYPE_INTERRUPT, false, USB_PID_DATA0, max_packet, buf_len, 1, &actual_len);
        if (result == 0) return true;
        if (result == 1 && rdtime() - stage_start < nak_budget) { yield(); continue; }
        print("usbd: interrupt OUT transfer failed\n");
        return false;
    }
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
// wIndex=iface_num, no data stage. Real mainline Linux's own
// hub_configure() (drivers/usb/core/hub.c) sends exactly this —
// SET_INTERFACE(hub, 0, 1) — for any Hi-Speed hub reporting
// bDeviceProtocol==2 (USB_HUB_PR_HS_MULTI_TT), switching it from its
// default shared-TT behavior into "one Transaction Translator per port"
// mode.
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

// HID class request SET_PROTOCOL (HID 1.11 section 7.2.6): select boot
// (0) or report (1) protocol on a HID interface. bmRequestType 0x21 =
// host-to-device, class, interface; wValue = protocol; wIndex =
// interface; no data stage. A plain boot keyboard powers up in report
// protocol, so this is what actually pins the report format to the
// fixed 8-byte boot layout kbd.c3 parses.
fn bool usb_hid_set_protocol(uint dev_addr, uint max_packet0, uint iface_num, uint protocol)
{
    char[8] setup;
    setup[0] = (char)0x21;
    setup[1] = (char)0x0B; // SET_PROTOCOL
    setup[2] = (char)(protocol & 0xFF);
    setup[3] = (char)0;
    setup[4] = (char)(iface_num & 0xFF);
    setup[5] = (char)0;
    setup[6] = (char)0;
    setup[7] = (char)0;
    return usb_control_transfer(dev_addr, max_packet0, &setup[0], null, 0, true);
}

// HID class request SET_IDLE (HID 1.11 section 7.2.4): how often the
// device re-sends an unchanged report. duration is in 4ms units;
// duration 0 = "only when the report actually changes", which is what
// this driver wants (no polling-driven duplicate reports, and no
// hardware key auto-repeat — software repeat is handled later). wValue
// hi byte = duration, lo byte = report ID (0 = all reports).
fn bool usb_hid_set_idle(uint dev_addr, uint max_packet0, uint iface_num, uint duration)
{
    char[8] setup;
    setup[0] = (char)0x21;
    setup[1] = (char)0x0A; // SET_IDLE
    setup[2] = (char)0;                  // wValue lo = report ID 0
    setup[3] = (char)(duration & 0xFF);  // wValue hi = duration
    setup[4] = (char)(iface_num & 0xFF);
    setup[5] = (char)0;
    setup[6] = (char)0;
    setup[7] = (char)0;
    return usb_control_transfer(dev_addr, max_packet0, &setup[0], null, 0, true);
}

// HID class request SET_REPORT (HID 1.11 section 7.2.2), used here only
// to push the keyboard's LED state (an Output report). bmRequestType
// 0x21, bRequest 0x09; wValue hi = report type 2 (Output), lo = report
// ID 0; wIndex = interface; one data byte = the LED bitmap (bit0
// NumLock, bit1 CapsLock, bit2 ScrollLock).
fn bool usb_hid_set_report_leds(uint dev_addr, uint max_packet0, uint iface_num, char leds)
{
    char[8] setup;
    setup[0] = (char)0x21;
    setup[1] = (char)0x09; // SET_REPORT
    setup[2] = (char)0;    // wValue lo = report ID 0
    setup[3] = (char)0x02; // wValue hi = report type Output
    setup[4] = (char)(iface_num & 0xFF);
    setup[5] = (char)0;
    setup[6] = (char)1;    // wLength = 1
    setup[7] = (char)0;
    char[1] data;
    data[0] = leds;
    return usb_control_transfer(dev_addr, max_packet0, &setup[0], &data[0], 1, false);
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

// Configuration descriptor — two-step fetch: the first 9 (fixed-size
// header) bytes to learn the real wTotalLength (the blob also includes
// every nested Interface/Endpoint descriptor, so its true size isn't
// known in advance), then the full blob, capped at buf_len.
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
// class. On a match, *iface_num_out gets the interface's own
// bInterfaceNumber, *num_endpoints_out gets its own bNumEndpoints (read
// directly from the interface descriptor, not back-derived), and
// *ep_start_offset_out gets the byte offset (within config_buf) where
// its endpoint descriptors begin — standard USB descriptor layout puts
// them immediately after their interface, which the caller walks
// directly via usb_ep_desc_*().
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

// Generic fallback finder: the first interrupt IN endpoint in ANY
// interface, regardless of class/subclass/protocol — for the "does
// split-interrupt IN even work through this hub, at all, for some
// completely different and boring device" diagnostic
// (usbd_generic_interrupt_read_loop, usbd.c3): a plain USB mouse/
// keyboard's own descriptors, unlike a vendor-specific XInput pad, are
// arbitrary and not worth matching by class/subclass/protocol the way
// usb_find_interface above does — the goal here is just "any interrupt
// IN endpoint at all," full stop.
fn bool usb_find_any_interrupt_in(char* config_buf, uint len, uint* ep_addr_out, uint* max_packet_out, uint* interval_out)
{
    uint i = 0;
    while (i + 1 < len)
    {
        uint b_length = (uint)config_buf[i] & 0xFF;
        uint b_type = (uint)config_buf[i + 1] & 0xFF;
        if (b_length == 0) { break; }
        if (b_type == USB_DESC_TYPE_ENDPOINT && i + 6 < len)
        {
            char* ep_desc = &config_buf[i];
            uint xfer_type = usb_ep_desc_xfer_type(ep_desc);
            uint addr = usb_ep_desc_address(ep_desc);
            if (xfer_type == USB_EP_XFERTYPE_INTERRUPT && (addr & 0x80) != 0)
            {
                *ep_addr_out = addr;
                *max_packet_out = usb_ep_desc_max_packet(ep_desc);
                *interval_out = usb_ep_desc_interval(ep_desc);
                return true;
            }
        }
        i += b_length;
    }
    return false;
}

// Like usb_find_any_interrupt_in, but scoped to ONE interface: walks
// endpoint descriptors starting at ep_start (the offset
// usb_find_interface hands back), bounded by num_endpoints real
// endpoint descriptors or the next Interface descriptor, whichever
// comes first. This is what a composite device (keyboard + consumer-
// control, keyboard + mouse) needs — usb_find_any_interrupt_in would
// happily return a sibling interface's endpoint.
fn bool usb_iface_first_interrupt_in(char* config_buf, uint len, uint ep_start, uint num_endpoints, uint* ep_addr_out, uint* max_packet_out, uint* interval_out)
{
    uint off = ep_start;
    uint eps_seen = 0;
    while (off + 1 < len && eps_seen < num_endpoints)
    {
        uint b_length = (uint)config_buf[off] & 0xFF;
        if (b_length == 0) { break; }
        uint b_type = (uint)config_buf[off + 1] & 0xFF;
        if (b_type == USB_DESC_TYPE_INTERFACE) { break; }
        if (b_type == USB_DESC_TYPE_ENDPOINT)
        {
            char* ep_desc = &config_buf[off];
            uint addr = usb_ep_desc_address(ep_desc);
            if (usb_ep_desc_xfer_type(ep_desc) == USB_EP_XFERTYPE_INTERRUPT && (addr & 0x80) != 0)
            {
                *ep_addr_out = addr;
                *max_packet_out = usb_ep_desc_max_packet(ep_desc);
                *interval_out = usb_ep_desc_interval(ep_desc);
                return true;
            }
            eps_seen++;
        }
        off += b_length;
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
const uint USB_PORT_STATUS_CONNECTION = 1 << 0; // GetPortStatus wPortStatus bit 0 — USB_PORT_STAT_CONNECTION, include/uapi/linux/usb/ch11.h
const uint USB_PORT_STATUS_ENABLE     = 1 << 1; // GetPortStatus wPortStatus bit 1
const uint USB_PORT_STATUS_RESET      = 1 << 4; // GetPortStatus wPortStatus bit 4 — USB_PORT_STAT_RESET, still set while a reset is in progress
// wPortStatus bits 9/10 (USB 2.0 spec Table 11-15) — within the
// GetPortStatus response's second byte (port_status[1]), so the local
// bit position within that byte is (9-8)=1 and (10-8)=2. Neither bit
// set means full-speed; the two are mutually exclusive per spec.
// Real bug found and fixed this session: these two were swapped. Real
// vendor Linux 5.10's own include/uapi/linux/usb/ch11.h:
// USB_PORT_STAT_LOW_SPEED=0x0200 (global wPortStatus bit 9),
// USB_PORT_STAT_HIGH_SPEED=0x0400 (bit 10) — confirmed directly, not
// re-guessed. port_status[1] is byte 1 of the 4-byte GetPortStatus
// reply (bits 8-15 of wPortStatus), so the local bit position is
// (global_bit - 8): LOW_SPEED -> bit 1, HIGH_SPEED -> bit 2. The
// previous version of this file had them backwards — harmless for a
// genuinely full-speed device (neither bit set, falls through to the
// FULL branch correctly either way), but a real Hi-Speed device (e.g.
// a USB 3.0 drive's own USB2 fallback, which negotiates Hi-Speed) was
// silently misreported as low-speed, and vice versa. That
// misclassification alone explains a real-hardware round that looked
// like a hub/cable/device incompatibility: this driver then wrongly
// forced split transactions (SSPLIT/CSPLIT via the hub's own TT) onto
// a device that should have been addressed directly at Hi-Speed, no
// splitting at all — producing exactly the observed start-split-not-
// ACKed/STALL failures.
const uint USB_PORT_STATUS_LOW_SPEED_B1  = 1 << 1; // bit 9
const uint USB_PORT_STATUS_HIGH_SPEED_B1 = 1 << 2; // bit 10

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

// Real hub-downstream-port reset — the missing piece between
// "GetPortStatus says something's connected" and actually being able to
// talk to it: an unpowered-then-unreset port never leaves the
// electrical/protocol state a fresh device resets into. Also reports
// the device's own negotiated speed (USB_DEV_SPEED_*, from wPortStatus
// bits 9/10) — the caller needs it to decide whether split transactions
// apply to this device (see g_split_active's own comment): this
// driver's root port itself negotiates whatever the hub natively
// supports, so a downstream device that isn't itself Hi-Speed needs
// every transfer split.
//
// Sequence sourced directly from real vendor Linux 5.10's own
// hub_port_reset() (duo-buildroot-sdk's linux_5.10/drivers/usb/core/
// hub.c), not just the USB 2.0 spec's own bare minimums — this
// driver's earlier version (single fixed 50ms wait, one status check,
// no post-enable settle) followed the spec minimums but skipped two
// things real Linux does that affect how much time the device actually
// gets before the host starts hammering it with control transfers:
//   1. Polls GetPortStatus repeatedly for RESET to clear AND CONNECTION
//      to stay set (hub_port_wait_reset()), instead of trusting one
//      fixed-duration wait — a real reset can legitimately take longer
//      than the spec minimum on real hardware.
//   2. An explicit *additional* settle delay AFTER the port reports
//      enabled, before ANY further communication — real Linux's own
//      comment: "TRSTRCY = 10ms; plus some extra", reset_recovery_time
//      = 10+40 = 50ms, done via msleep() right there in hub_port_reset()
//      before update_devnum()/any control transfer. This driver had no
//      equivalent at all: it went from "port reports enabled" straight
//      into SET_ADDRESS/GET_DESCRIPTOR with zero recovery time. Real-
//      hardware motivation: the Xbox 360 pad behind this exact hub
//      never does its own power-on self-test buzz under this driver,
//      despite doing so reliably under real Linux on the same physical
//      hardware — since the wiring/power path is demonstrably capable
//      (Linux proves it), the gap has to be in software sequencing/
//      timing, and this is the first concrete, sourced difference from
//      Linux's own real sequence.
fn bool usb_reset_hub_port(uint hub_addr, uint max_packet0, uint port, uint* speed_out)
{
    char[4] port_status;
    bool enabled = false;

    // PORT_RESET_TRIES in real Linux's own hub.c is 5 (or 2 under
    // CONFIG_USB_FEW_INIT_RETRIES) — 3 matches this driver's own
    // established retry-count convention elsewhere (e.g.
    // usb_enumerate_device()'s own initial GET_DESCRIPTOR retry) rather
    // than importing a separate magic number.
    for (int attempt = 0; attempt < 3 && !enabled; attempt++)
    {
        if (!usb_set_port_feature(hub_addr, max_packet0, port, USB_HUB_FEATURE_PORT_RESET))
        {
            print("usbd: hub port ");
            print_uint(port);
            print(": SetPortFeature(PORT_RESET) failed\n");
            return false;
        }

        // Poll for RESET to clear and CONNECTION to still be set,
        // instead of trusting one fixed-duration wait — real Linux's
        // own hub_port_wait_reset(), simplified (no HUB_RESET_TIMEOUT
        // long-delay-after-two-short-failures ramp, just one steady
        // 20ms poll interval up to an 800ms total budget, matching
        // real Linux's own HUB_RESET_TIMEOUT).
        ulong poll_start = rdtime();
        ulong poll_budget = usb_us_to_ticks(800000);
        for (;;)
        {
            ulong step_start = rdtime();
            while (rdtime() - step_start < usb_us_to_ticks(20000)) { yield(); }

            if (!usb_get_port_status(hub_addr, max_packet0, port, &port_status[0]))
            {
                print("usbd: hub port ");
                print_uint(port);
                print(": GET_PORT_STATUS after reset failed\n");
                return false;
            }
            uint status_b0 = (uint)port_status[0] & 0xFF;
            if (!(status_b0 & USB_PORT_STATUS_RESET) && (status_b0 & USB_PORT_STATUS_CONNECTION))
            {
                enabled = (status_b0 & USB_PORT_STATUS_ENABLE) != 0;
                break;
            }
            if (!(status_b0 & USB_PORT_STATUS_CONNECTION))
            {
                print("usbd: hub port ");
                print_uint(port);
                print(": device disconnected during reset\n");
                return false;
            }
            if (rdtime() - poll_start > poll_budget) { break; } // still resetting after the real Linux budget — give up this attempt, try again
        }
    }

    if (!enabled)
    {
        print("usbd: hub port ");
        print_uint(port);
        print(": did not report PORT_ENABLE after reset\n");
        return false;
    }

    // Post-enable reset-recovery settle — see this function's own
    // header comment for the real sourcing (Linux's own
    // reset_recovery_time = 10+40 = 50ms). Nothing talks to the device
    // until this elapses.
    ulong recovery_start = rdtime();
    while (rdtime() - recovery_start < usb_us_to_ticks(50000)) { yield(); }

    uint status_b1 = (uint)port_status[1] & 0xFF;
    if (USBD_VERBOSE)
    {
        print("usbd: hub port ");
        print_uint(port);
        print(": raw port_status bytes: ");
        print_hex8((uint)port_status[0] & 0xFF);
        print(" ");
        print_hex8(status_b1);
        print("\n");
    }
    if (status_b1 & USB_PORT_STATUS_HIGH_SPEED_B1) { *speed_out = USB_DEV_SPEED_HIGH; }
    else if (status_b1 & USB_PORT_STATUS_LOW_SPEED_B1) { *speed_out = USB_DEV_SPEED_LOW; }
    else { *speed_out = USB_DEV_SPEED_FULL; }
    return true;
}

// CLEAR_TT_BUFFER — USB 2.0 spec section 11.24.2.3, a hub class request
// sourced directly from real vendor Linux 5.10's own
// hub_clear_tt_buffer() (duo-buildroot-sdk's linux_5.10/drivers/usb/
// core/hub.c). A Hi-Speed hub's Transaction Translator relays split
// transactions to/from a full/low-speed device on its own internal
// buffer; when a split transaction gets a genuine error (XACTERR,
// babble, stall), that buffer can be left in a state a plain host-side
// channel reset can't clear — only this explicit request, sent to the
// HUB itself (not the downstream device), actually resets it. This
// driver never implemented it before now: real hardware round (see
// hc_transfer_once_split's own header comment, docs/devlog.md) hit
// exactly this signature — a clean run of complete-split NAKs
// eventually degrading into a persistent, never-recovering XACTERR —
// the textbook case this request exists for.
//
// devinfo bit layout matches Linux's own exactly: bits[3:0]=endpoint
// number, bits[10:4]=device address, bits[12:11]=endpoint type
// (0=control,1=isoc,2=bulk,3=interrupt — same encoding as this file's
// own USB_HCCHAR_EPTYPE_* constants), bit[15]=direction (1=IN).
// max_packet0 for the hub's own control endpoint is hardcoded to 64,
// not passed in or rediscovered — the same real, spec-fixed fact this
// driver already relies on elsewhere (usbd.c3's own bootstrap_mps0):
// EP0's max packet size for a Hi-Speed device (this driver's hub is
// always Hi-Speed) is fixed at 64, never ambiguous the way full/low-
// speed EP0 sizes are.
//
// Temporarily clears g_split_active around the request itself — this
// goes directly to the hub's own control endpoint on the root port,
// never split, regardless of whatever downstream split context was
// active when the error that triggered this happened — then restores
// it, since the caller (hc_transfer_once_split) is still mid-way
// through handling that downstream device's own transfer.
fn bool usb_clear_tt_buffer(uint hub_addr, uint hub_port, uint dev_addr, uint ep_num, uint ep_type, bool is_in)
{
    uint devinfo = (ep_num & 0xF) | ((dev_addr & 0x7F) << 4) | ((ep_type & 0x3) << 11) | (is_in ? 0x8000 : 0);

    bool saved_split_active = g_split_active;
    uint saved_split_hub_addr = g_split_hub_addr;
    uint saved_split_hub_port = g_split_hub_port;
    g_split_active = false;

    char[8] setup;
    setup[0] = (char)0x23; // OUT, class, other (port) — same bmRequestType as usb_set_port_feature's own
    setup[1] = (char)0x08; // HUB_CLEAR_TT_BUFFER
    setup[2] = (char)(devinfo & 0xFF);
    setup[3] = (char)((devinfo >> 8) & 0xFF);
    setup[4] = (char)(hub_port & 0xFF);
    setup[5] = (char)0;
    setup[6] = (char)0;
    setup[7] = (char)0;
    bool ok = usb_control_transfer(hub_addr, 64, &setup[0], null, 0, true);

    g_split_active = saved_split_active;
    g_split_hub_addr = saved_split_hub_addr;
    g_split_hub_port = saved_split_hub_port;
    return ok;
}
