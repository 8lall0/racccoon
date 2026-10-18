module user;

import std::nolibc::main_stub;

// cifd: driver for the CV1800B's MIPI CSI-2 receiver — "csi_mac0"
// (0x0A0C2000) + "csi_wrap0" (0x0A0D0000) in cv180x_base.dtsi's own
// "mipi_rx: cif" node. Stage 3 of docs/camera-plan.md: bring the
// D-PHY/CSI-2 link up and confirm it's clean (a valid packet header
// decoded, no ECC/CRC/word-count errors) — no DMA, no pixels reaching
// DRAM yet (that's the closed `vi` block, Stage 4+).
//
// Register field sourcing, corrected 2026-09-13: the first attempt
// used the FreeRTOS cv1835 CIF HAL (cif_drv.c + reg_fields_csi_
// {mac,wrap}.h, duo-buildroot-sdk) — real, open source, but for a
// *different chip*. Its base addresses happen to match CV1800B's own
// devicetree (cv180x_base.dtsi's "mipi_rx: cif" node), which was taken
// as license to trust its internal register layout too. That was
// wrong: real-hardware diagnostics proved some cv1835-derived fields
// simply didn't exist at the addresses used (writes silently landing
// nowhere), most damningly SENSOR_MAC_MODE — cv1835 has this as a
// 2-bit field defaulting to CSI, so leaving it untouched seemed safe;
// CV1800B's real 3-bit field defaults to 0 = *Disable*, meaning the
// whole MAC sat disabled for this entire arc's first pass regardless
// of how correct anything else was. The actual source that fixed this,
// found only after being asked to check the SDK more thoroughly rather
// than accept the wall: milkv-duo/duo-files' own CV1800B-CV1801B
// Preliminary Datasheet (a real 692-page register-level TRM, not just
// the short overview PDF fetched earlier) — section 9.1.6 for the MAC
// TOP block, 9.2.5 for the PHY/CSI blocks. Every offset/bit-position
// constant below cites that document, not the cv1835 driver, except
// where noted as confirmed-identical between the two.
//
// The devicetree's own RST_CSIPHY0/RST_CSIPHY0RST_APB and
// clk_src_vip_sys_2 (this project's second time hitting the "some
// peripheral's reset/clock was never touched before, deassert it
// yourself" pattern i2cd.c3 already ran into for RST_I2C1) turned out
// fine as originally found — the datasheet correction only concerns
// the CSI/D-PHY control registers themselves, not these. The same
// devicetree node's "snsr-reset = <&porta 2 ...>" property was NOT
// used for SENSOR_RSTN either way — that's a generic SoC-level
// placeholder in the shared base dtsi, not a board override; the real,
// board-specific wiring (XGPIOC[8], hw-verified working since Stage 1)
// came from Milk-V's own schematic + the real vendor U-Boot board-init
// table, both independently agreeing — see boards/duo/board.c3's own
// camera comment.
//
// Lane *selection* is the one thing this file deliberately does NOT
// configure, despite Stage 1/2's own schematic-derived "clock<-pad 3,
// data0<-pad 2, data1<-pad 4" mapping (from Milk-V's sensor_cfg_
// GC2083.ini): the real WRAP_L0_LANE_SEL/WRAP_L0_CK_SEL registers are
// 2-bit fields (max value 3) with no documented translation from the
// schematic's own "PAD_MIPIRXn" pin numbering, and their reset values
// (d0<-1, d1<-2, ck<-0) are left alone rather than risk misdirecting
// the mux with values transplanted from cv1835's different, 5-lane,
// 3-bit numbering scheme. See WRAP_L0_LANE_SEL's own comment.
//
// Poll-only (no PLIC interrupt wiring), same reasoning as every other
// driver in this project.

// --- csi_mac0 (0x0A0C2000): TOP sub-block @ +0x000, CSI sub-block @ +0x400 ---
//
// All offsets/bit positions below are transcribed from the REAL
// CV1800B-CV1801B Preliminary Datasheet (milkv-duo/duo-files' own
// full 692-page TRM, section 9.1.6 "VI register overview" for the MAC
// TOP block and 9.2.5 "MIPI Rx Register Overview" for the PHY/CSI
// blocks) — fetched and read this session after the FreeRTOS cv1835
// cif_drv.c reference (used for the first attempt) turned out to only
// match CV1800B's *base addresses*, not its internal register layout.
// Real-hardware diagnostics (2026-09-13) proved this the hard way:
// WRAP REG_00 (this datasheet's own PD_CTRL) correctly reflected every
// write, but the cv1835-derived "lane select"/"clock channel" fields
// at offsets that don't even exist as such on real CV1800B silicon
// read back unchanged no matter what was written there.
const uint CIF_MAC_BASE = 0x0A0C2000;
const uint CIF_MAC_TOP_REG_00 = 0x000; // SENSOR_MAC_MODE[2:0] CSI_CTRL_ENABLE[4] CSI_VS_INV[5] CSI_HS_INV[6]
const uint CIF_MAC_CSI_REG_00 = 0x400; // CSI_LANE_MODE[2:0]
const uint CIF_MAC_CSI_REG_04 = 0x404; // CSI_INTR_MASK[7:0] CSI_INTR_CLR[15:8] CSI_HDR_EN[16] CSI_HDR_MODE[17]
const uint CIF_MAC_CSI_REG_40 = 0x440; // error/status bits, see below
const uint CIF_MAC_CSI_REG_60 = 0x460; // CSI_INTR_STATUS[7:0]
const uint CIF_MAC_CSI_REG_70 = 0x470; // CSI_VS_GEN_MODE[1:0] (reset=2) CSI_VS_GEN_BY_VCSET[4] (reset=0)

// SENSOR_MAC_MODE (3 bits, reset value 0!): 0=Disable, 1=CSI, 2=Sub-LVDS,
// 3=TTL. The single most important fix this session's real-datasheet
// read turned up — every previous attempt left this at its own reset
// value assuming (from cv1835's own, different, 2-bit encoding) that 0
// already meant CSI. On real CV1800B silicon, 0 means the whole MAC is
// disabled: nothing downstream could ever have worked, regardless of
// how correct anything else was.
const uint MAC_TOP_SENSOR_MAC_MODE_CSI = 1;
const uint MAC_TOP_CSI_CTRL_ENABLE = 1u << 4;
const uint MAC_TOP_CSI_VS_INV      = 1u << 5; // reset already 1, written for certainty
const uint MAC_TOP_CSI_HS_INV      = 1u << 6; // reset already 1, written for certainty

// REG_40 (0x440) bit layout — the actual "is the link clean" register,
// confirmed to match cv1835's own layout bit-for-bit (unlike the WRAP
// block, this one checks out):
const uint CSI_ECC_NO_ERROR        = 1u << 0;
const uint CSI_ECC_CORRECTED_ERROR = 1u << 1;
const uint CSI_ECC_ERROR           = 1u << 2;
const uint CSI_CRC_ERROR           = 1u << 4;
const uint CSI_WC_ERROR            = 1u << 5;
const uint CSI_FIFO_FULL           = 1u << 8;
const uint CSI_DECODE_FORMAT_SHIFT = 16; // 6 bits [21:16]: bit0=YUV422-8 bit1=YUV422-10 bit2=RAW8 bit3=RAW10 bit4=RAW12 bit5=RAW16
const uint CSI_DECODE_FORMAT_MASK  = 0x3F;
// Any of these set means the link is NOT clean:
const uint CSI_ERROR_BITS = CSI_ECC_ERROR | CSI_CRC_ERROR | CSI_WC_ERROR;

fn uint mac_reg_read(uint offset) { return mmio_read32((uptr)(CIF_MAC_BASE + offset)); }
fn void mac_reg_write(uint offset, uint v) { mmio_write32((uptr)(CIF_MAC_BASE + offset), v); }

// --- csi_wrap0 (0x0A0D0000) ---
//
// Real layout (per the datasheet, NOT cv1835's): a base "PHY analog"
// block at +0x000 shared across both possible MIPI-RX links, then a
// per-link "digital lane config" block — link0 at +0x300, link1 (this
// board doesn't use it) at +0x600.
//
// Correction within a correction: an earlier pass of this same
// datasheet misread the *link1* copy of this block (its own
// documented field widths differ — 2-bit *_sel fields there, vs. the
// link0 block's real 3-bit fields below; whether that's a genuine
// hardware difference between the two links or a documentation
// inconsistency in the vendor's own manual wasn't resolved, but link0
// is the one this board actually wires up) and concluded the lane-
// select reset defaults couldn't be safely reinterpreted. Re-reading
// the *real* link0 section (Offset = 0x0A0D0300) shows 3-bit fields
// with reset defaults d0<-1, d1<-2, d2<-3, d3<-4, ck<-0 — a generic
// "identity" default (each logical role assigned the physical pad of
// the same number) with no reason to already match this board's own,
// different physical wiring. This is also the same 3-bit/5-lane
// numbering the very first (cv1835-derived) attempt used — meaning
// that attempt's actual *lane values* (ck<-3, d0<-2, d1<-4, from
// Milk-V's own sensor_cfg_GC2083.ini "lane_id = 3, 2, 4, -1, -1",
// cross-checked against the schematic's own net names) were right all
// along; only the register *offset* (cv1835's wrong 0x028, not real
// CV1800B's 0x304/0x308) was ever actually wrong.
const uint CIF_WRAP_BASE = 0x0A0D0000;
const uint WRAP_PD_CTRL       = 0x000; // reg_mipirx_pd_ibias[14] reg_mipirx_pd_rxlp[21:16]
const uint WRAP_REG_04        = 0x004; // reg_mipirx_sel_clk_channel[21:16] reg_mipimpll_clk_csi_en[31]

// reg_mipirx_sel_clk_channel: a 6-bit field at WRAP+0x004[21:16], reset
// 0x0. Distinct from WRAP_L0_CK_SEL below — that one is link0's own
// *digital* lane-routing mux (which physical lane feeds link0's clock
// slot); this one lives at the WRAP's global level, alongside 6 other
// clearly-per-physical-lane registers (REG_34-48's "analog lane 0-5
// calibration result", REG_80's "AD clock lane0-5 inverse") — strong
// evidence it's a one-hot mask selecting which physical analog lane
// the clock-recovery PLL actually listens to, not just another copy of
// the same digital route. Left untouched (at its reset value, lane 0)
// through every earlier attempt; this is the first one to set it,
// matching the same physical lane (3, from the schematic + Milk-V's
// own sensor_cfg_GC2083.ini) as WRAP_L0_CK_SEL already uses.
const uint WRAP_SEL_CLK_CHANNEL_SHIFT = 16;
const uint WRAP_SEL_CLK_CHANNEL_PHYS_LANE = 3;

const uint WRAP_LINK0_BASE    = 0x300;
const uint WRAP_L0_SENSOR_MODE  = WRAP_LINK0_BASE + 0x00; // reg_sensor_mode[1:0]: 0=CSI 1=SubLVDS&HiSPi 2=SLVSEC
const uint WRAP_L0_LANE_SEL     = WRAP_LINK0_BASE + 0x04; // reg_csi_lane_d{0,1,2,3}_sel, 3 bits each at [2:0]/[6:4]/[10:8]/[14:12]
const uint WRAP_L0_CK_SEL       = WRAP_LINK0_BASE + 0x08; // reg_csi_lane_ck_sel[2:0] + pnswap bits[11:8]/[4] + ck_phase[23:16]
const uint WRAP_L0_CSI_GLB_CTL0 = WRAP_LINK0_BASE + 0x0C; // reg_deskew_lane_en[3:0]: 0=none 1=1-lane 3=2-lane 0xf=4-lane

const uint WRAP_L0_D0_SEL_SHIFT = 0;
const uint WRAP_L0_D1_SEL_SHIFT = 4;
const uint WRAP_L0_CK_SEL_SHIFT = 0;

const uint WRAP_PD_IBIAS_BIT  = 1u << 14;
const uint WRAP_PD_RXLP_SHIFT = 16;
const uint WRAP_PD_RXLP_MASK  = (uint)0x3F << WRAP_PD_RXLP_SHIFT; // 6 bits, reset value 0x3f (all powered down)

fn uint wrap_reg_read(uint offset) { return mmio_read32((uptr)(CIF_WRAP_BASE + offset)); }
fn void wrap_reg_write(uint offset, uint v) { mmio_write32((uptr)(CIF_WRAP_BASE + offset), v); }

// --- shared CLOCK_BASE/RESET_BASE pages — see user/i2c/i2cd.c3's own
// copies of these same two physical pages for the general pattern.
const uint CLOCK_BASE = 0x03002000;
const uint RESET_BASE = 0x03003000;
fn uint clock_reg_read(uint offset) { return mmio_read32((uptr)(CLOCK_BASE + offset)); }
fn void clock_reg_write(uint offset, uint v) { mmio_write32((uptr)(CLOCK_BASE + offset), v); }
fn uint reset_reg_read(uint offset) { return mmio_read32((uptr)(RESET_BASE + offset)); }
fn void reset_reg_write(uint offset, uint v) { mmio_write32((uptr)(RESET_BASE + offset), v); }

const uint REG_CLK_EN_2 = 0x008;
const uint REG_CLK_EN_3 = 0x00c;
const uint CLK_EN_2_CAM0_BIT        = 1u << 16; // clk_cam0 — same bit i2cd.c3 already gates; redundant OR-in is harmless
const uint CLK_EN_3_VIP_SYS_2_BIT   = 1u << 29; // clk_src_vip_sys_2 — one of the "mipi_rx: cif" devicetree node's own listed clocks

// A SoC-level gate for csi_mac0's own clock, entirely separate from
// clk_cam0 above — found in the real Linux clock driver (linux_5.10/
// drivers/clk/cvitek/clk-cv180x.c: `CV180X_CLK_CSI_MAC0_VIP`,
// "clk_csi_mac0_vip", parented from "clk_axi_vip", not clk_cam0's own
// tree) after round 2's VIP_SYS-internal clock-enable fix (a
// different, lower tier — the "csi_mac0" reset/clock gate *inside* the
// VIP_SYS block itself, base 0x0A0C8000) turned out not to be the
// answer either: same register (REG_CLK_EN_2, already written above)
// but a different bit this driver had never touched. cv180x_base.
// dtsi's own "mipi_rx: cif" node clock list never mentions this one by
// name either — this is a genuinely separate finding from that
// devicetree node, only visible by reading the real Linux clock driver
// source directly instead of trusting the devicetree binding to be
// exhaustive.
const uint CLK_EN_2_CSI_MAC0_VIP_BIT = 1u << 18;

// clk_csi_mac0_vip's own parent clock (same file: `CV180X_CLK_AXI_VIP`,
// "clk_axi_vip", parent list {osc, clk_mipimpll, clk_cam0pll,
// clk_disppll, clk_fpll}) — REG_CLK_EN_2 bit 4, same register again,
// yet another bit never touched. Enabling a child gate without its
// parent gate also enabled would leave the child clock permanently
// starved regardless of the child's own bit — this one has to be set
// too. Its own bypass-select bit (REG_CLK_BYP_0 == REG_CLK_BYPASS_SEL0
// == the same 0x03002030 FSBL already writes at boot) is confirmed
// cleared (not bypassed) by FSBL's own platform.c ("byp0_value &=
// (1<<8 | 1<<19)" keeps only clk_spi_nand/clk_axi4 in bypass, clearing
// every other bit including this one) — so bypass isn't in play here,
// only this enable gate.
const uint CLK_EN_2_AXI_VIP_BIT = 1u << 4;

// RST_CSIPHY0 = reset-controller index 70, RST_CSIPHY0RST_APB = 71
// (linux_5.10/include/dt-bindings/reset/cv180x-resets.h). bank = id/32
// = 2 -> register offset 0x08 (bank 0 is offset 0x00, same formula
// i2cd.c3's own RST_I2C1 used); bit = id%32 -> 6 and 7.
const uint REG_SOFT_RST_2 = 0x008;
const uint SOFT_RST_2_CSIPHY0_BIT     = 1u << 6;
const uint SOFT_RST_2_CSIPHY0_APB_BIT = 1u << 7;

// --- VIP_SYS (0x0A0C8000): the actual root cause this session's round
// 2 found, after the pn-swap sweep's total invariance (0x00000000 on
// literally every combination tested) pointed away from anything the
// CV1800B TRM itself documents. Not in that TRM at all — found instead
// by taking the user's "you have a working Linux/U-Boot driver, why
// aren't you using it" push seriously and reading the REAL production
// driver source (u-boot-2021.10/drivers/video/cvitek/vip_sys.c,
// reg_vip_sys.h) rather than re-deriving everything from the datasheet
// by hand. cv180x_base.dtsi's own "base" node (`compatible =
// "cvitek,base"`, reg-names = "vip_sys") gives the real base address;
// the C driver's own vip_get_reset()/vip_set_reset() — not just the
// header's raw bit-offset comments, which describe an older pre-ECO
// silicon revision — is what's authoritative for where CSI_MAC0's
// reset bit actually lives on this stepping.
//
// This is a THIRD tier of clock/reset gating, entirely separate from
// the SoC-level CLK_EN_2/3 + RESET_BASE bits above (which only cover
// clk_cam0/clk_src_vip_sys_2 and RST_CSIPHY0 — the D-PHY analog front
// end's own domain) and from MIPIMPLL (the PLL feeding the HS sampling
// clock, confirmed correctly configured by FSBL). This one gates the
// CSI MAC's own *decode logic* clock specifically — its register file
// stays readable/writable either way (a separate, always-on APB bus
// clock backs plain register access), which is exactly why every
// other register in this driver reads back whatever was written to it
// while CSI_STATUS never moved: the datapath that would actually
// populate it was never clocked in the first place.
//
// The Duo has no display wired up (no devicetree node referencing this
// "vip_sys" block on this board), so nothing in the boot chain —
// including the reused vendor FSBL, which only programs top-level SoC
// PLLs, not per-subsystem VIP_SYS gates — was ever touching it; it
// plausibly sat at its untouched power-on-reset default (clock gated
// off) this entire arc, with every fix so far correctly configuring
// registers that simply couldn't do anything downstream of this gate.
const uint VIP_SYS_BASE = 0x0a0c8000;
fn uint vipsys_reg_read(uint offset) { return mmio_read32((uptr)(VIP_SYS_BASE + offset)); }
fn void vipsys_reg_write(uint offset, uint v) { mmio_write32((uptr)(VIP_SYS_BASE + offset), v); }

const uint VIP_SYS_REG_00 = 0x000; // rst_axi[0] rst_isp_top[1] ... clk_isp_top_en[18] clk_axi_isp_en[19] clk_csi_mac0_en[20] clk_csi_mac1_en[21]
const uint VIP_SYS_REG_04 = 0x004; // rst_csi_mac0[0] rst_csi_mac1[1] — moved here by an "ECO" silicon revision; NOT bits 12/13 of REG_00 as an older header revision's own (non-ECO) comment claims, confirmed by reading the real driver's vip_get_reset()/vip_set_reset() logic itself rather than trusting the header's bit-offset comment in isolation

const uint VIP_RST_AXI          = 1u << 0; // 1 = held in reset (opposite polarity convention from RST_CSIPHY0's SoC-level reset controller above — SET here means asserted, not running)
const uint VIP_RST_ISP_TOP      = 1u << 1;
const uint VIP_CLK_ISP_TOP_EN   = 1u << 18;
const uint VIP_CLK_AXI_ISP_EN   = 1u << 19;
const uint VIP_CLK_CSI_MAC0_EN  = 1u << 20;
const uint VIP_CLK_CSI_MAC1_EN  = 1u << 21;
const uint VIP_ENABLE_RST_CSI_MAC0 = 1u << 0; // REG_04, 1 = held in reset
const uint VIP_ENABLE_RST_CSI_MAC1 = 1u << 1;

// First attempt here faithfully replayed the vendor's own full
// vip_isp_clk_reset() sequence (axi + isp_top + csi_mac0/1, with a
// reset-assert/clock-pulse/reset-deassert dance for each) — real
// hardware then faulted (scause=5, load access fault) on cifd's own
// *later* access to CIF_MAC_BASE, a register this same driver had
// already read/written successfully dozens of times earlier in the
// exact same session, with nothing else having changed about how that
// page is mapped. The most likely explanation: toggling the axi/
// isp_top reset domains — genuinely unrelated to CIF, shared with the
// ISP/display pipeline this driver never uses — destabilized the AXI-
// to-register-bus bridge csi_mac0's own register block sits behind, in
// a way this project doesn't have the tooling to fully characterize.
// Narrowed to exactly what this driver needs: csi_mac0's own clock-
// enable + reset bits, set directly (no reset-pulse dance, no touching
// axi/isp_top/csi_mac1 at all). Whatever csi_mac0's own POR state
// already was, this either confirms it or fixes it without disturbing
// any other VIP_SYS-gated domain.
fn void vip_sys_bring_up()
{
    uint reg0 = vipsys_reg_read(VIP_SYS_REG_00);
    reg0 |= VIP_CLK_CSI_MAC0_EN;
    vipsys_reg_write(VIP_SYS_REG_00, reg0);

    uint reg4 = vipsys_reg_read(VIP_SYS_REG_04);
    reg4 &= ~VIP_ENABLE_RST_CSI_MAC0;
    vipsys_reg_write(VIP_SYS_REG_04, reg4);

    print("cifd: [diag] VIP_SYS REG_00 (0x0a0c8000)=0x"); print_hex32(vipsys_reg_read(VIP_SYS_REG_00)); print("\n");
    print("cifd: [diag] VIP_SYS REG_04 (0x0a0c8004)=0x"); print_hex32(vipsys_reg_read(VIP_SYS_REG_04)); print("\n");
}

fn void cif_init()
{
    uint clk_en_2 = clock_reg_read(REG_CLK_EN_2);
    clk_en_2 |= CLK_EN_2_CAM0_BIT | CLK_EN_2_CSI_MAC0_VIP_BIT | CLK_EN_2_AXI_VIP_BIT;
    clock_reg_write(REG_CLK_EN_2, clk_en_2);

    // clk_axi_vip's own divider+mux register (linux_5.10/drivers/clk/
    // cvitek/clk-cv180x.c: REG_DIV_CLK_AXI_VIP = CLOCK_BASE+0xc8 — div
    // field [19:16] width 4, mux field [9:8] width 2 selecting among
    // {clk_mipimpll, clk_cam0pll, clk_disppll, clk_fpll} when not
    // bypassed to raw osc via the separate REG_CLK_BYP_0 bit22, already
    // confirmed clear by FSBL's own boot-time bypass cleanup).
    //
    // The actual reason this needed fixing at all: gcore_gc2083's own
    // real sensor-attribute struct (middleware/v2/component/isp/sensor/
    // cv180x/gcore_gc2083/gc2083_cmos_param.h) explicitly specifies
    // `.mac_clk = RX_MAC_CLK_200M` — the real production driver
    // requires the CSI MAC's clock domain running at 200MHz.
    // clk_csi_mac0_vip (REG_CLK_EN_2 bit18, just above) is a pure gate
    // with no divider of its own (linux_5.10/drivers/clk/cvitek/
    // clk-cv180x.c's own CV180X_CLK_CSI_MAC0_VIP entry has all div/mux
    // fields at their unused sentinel) — its entire effective rate IS
    // clk_axi_vip's rate. Read back before this fix: mux=0 (osc, 25MHz)
    // div=3 — roughly 6-8MHz, a ~25-30x deficiency from the required
    // 200MHz. This is the first configuration change in this whole arc
    // targeting the MAC's actual *decode-datapath* clock rate rather
    // than a plain on/off gate, and the first one grounded in a
    // concrete vendor-specified target frequency rather than "some
    // clock is enabled" being assumed sufficient.
    //
    // MIPIMPLL is independently confirmed running at 900MHz (this same
    // file's own CSR readback, matching FSBL's programmed value).
    // 900/4 = 225MHz — not an exact match for 200MHz (no divider here
    // gets 900MHz to exactly 200MHz with an integer ratio), but close,
    // and — more importantly — a normal, safe operating frequency for
    // an AXI/APB-class bus clock on this class of SoC, not a guess at
    // the edge of any rating. mux=0 (first non-osc parent, mipimpll,
    // per the parent-array ordering) matches: {osc(via bypass), 0:
    // clk_mipimpll, 1: clk_cam0pll, 2: clk_disppll, 3: clk_fpll}.
    uint div_reg = clock_reg_read(0x0c8);
    print("cifd: [diag] REG_DIV_CLK_AXI_VIP before=0x"); print_hex32(div_reg); print("\n");
    div_reg &= ~((uint)0xF << 16); // clear div field
    div_reg &= ~((uint)0x3 << 8);  // clear mux field -> 0 = clk_mipimpll
    div_reg |= (uint)3 << 16;      // divide-by-4 (N+1 encoding, matching Linux's own initval=3 for its own default divider setting)
    clock_reg_write(0x0c8, div_reg);
    print("cifd: [diag] REG_DIV_CLK_AXI_VIP after=0x"); print_hex32(clock_reg_read(0x0c8)); print("\n");

    uint clk_en_3 = clock_reg_read(REG_CLK_EN_3);
    clk_en_3 |= CLK_EN_3_VIP_SYS_2_BIT;
    clock_reg_write(REG_CLK_EN_3, clk_en_3);

    uint soft_rst_2 = reset_reg_read(REG_SOFT_RST_2);
    soft_rst_2 |= SOFT_RST_2_CSIPHY0_BIT | SOFT_RST_2_CSIPHY0_APB_BIT;
    reset_reg_write(REG_SOFT_RST_2, soft_rst_2);
    print("cifd: [diag] REG_SOFT_RST_2 readback=0x"); print_hex32(reset_reg_read(REG_SOFT_RST_2)); print("\n");

    // Read-only sanity check, not a config write: MIPIMPLL (the PLL
    // that actually generates the D-PHY receiver's own HS sampling/
    // byte clock — cv180x_base.dtsi's "cif" node lists it as one of
    // this block's clocks, alongside clk_cam0/clk_sys_2 which cif_init
    // already gates) is supposed to be programmed to 900MHz and taken
    // out of powerdown unconditionally by FSBL's own sys_pll_od()/
    // sys_pll_nd() (fsbl/plat/cv180x/platform.c: mmio_write_32(
    // 0x03002808, 0x05488101) then clearing REG_PLL_G2_CTRL's PD bits)
    // — before racccoon's own kernel/cifd ever runs, on the exact same
    // FSBL binary this project's own reflash reuses unchanged. If real
    // hardware disagrees with that (CSR != 0x05488101, or G2_STATUS
    // bit0 stuck busy), that's the actual missing piece; if it
    // matches, this PLL is confirmed not the problem.
    print("cifd: [diag] MIPIMPLL_CSR (0x03002808) readback=0x"); print_hex32(clock_reg_read(0x808)); print("\n");
    print("cifd: [diag] PLL_G2_STATUS (0x03002804) readback=0x"); print_hex32(clock_reg_read(0x804)); print("\n");

    // The actual fix this round found: VIP_SYS's own csi_mac0 clock/
    // reset gate — see vip_sys_bring_up()'s own comment. Never touched
    // before; this board's boot chain has no display, so nothing else
    // was ever bringing it up either.
    vip_sys_bring_up();

    print("cifd: clocks/reset done — MAC/lane config + analog enable deferred to cif_stream_enable()\n");
}

fn void busy_wait_us(ulong us)
{
    ulong hz = timebase_hz();
    ulong deadline = rdtime() + (hz / 1000000) * us;
    while (rdtime() < deadline) { yield(); }
}

// The MAC/lane config (cif_drv.c's own cif_config(), specifically
// _cif_csi_config()) + the analog front-end/lane enable dance
// (cif_drv.c's own cif_stream_enable(on=1), with PD_CTRL's real
// CV1800B bit positions). Deliberately NOT run as part of cif_init()
// (boot time, well before any sensor is even reset/configured over
// I2C) — moved to this on-demand call, triggered once the sensor is
// confirmed streaming, after two real findings this session:
//
// 1. Splitting "config" from "analog enable" isn't enough on its own
//    (tried first, no change) — cif_streaming()'s own real sequence is
//    `if (on) { cif_config(...); cif_hdr_enable(...); cif_stream_
//    enable(...,on); }`: cif_config() itself runs *every time*,
//    immediately before the analog enable, as one atomic operation —
//    not once at driver boot, arbitrarily long before. This driver's
//    first restructuring still ran the MAC/lane config at boot and
//    only deferred the analog dance, which doesn't match that shape.
// 2. Whether the D-PHY's own internal calibration genuinely needs the
//    sensor's clock lane already toggling *during* the analog enable
//    to lock (plausible for this class of receiver) is unconfirmed,
//    but running the whole thing after the sensor is known to be
//    streaming, instead of an untested number of seconds before, is
//    the correct order regardless.
//
// pnswap_bits (bit0=clock, bit1=data0, bit2=data1) drives WRAP_L0_CK_
// SEL's own reg_csi_lane_{ck,d0,d1}_pnswap fields — a targeted,
// bounded (8-combination) hardware test, not blind guessing: a
// reversed differential pair is one of the single most common
// real-world MIPI wiring defects, especially plausible here since this
// is a third-party GC2083 breakout, not Milk-V's own official camera
// FPC. Every other identifiable register is now datasheet-verified
// correct via direct hardware readback; this is the next concrete,
// well-justified thing left to try, driven from cifinit.c3's own
// sweep rather than fixed in the driver.
fn void cif_stream_enable(uint pnswap_bits)
{
    // MAC TOP: CSI mode. SENSOR_MAC_MODE=1 is the fix that actually
    // matters — see its own comment above. VS_INV/HS_INV are already 1
    // at reset; written explicitly for certainty, not because they
    // were wrong before.
    uint mac_top = mac_reg_read(CIF_MAC_TOP_REG_00);
    mac_top &= ~(uint)0x7; // clear SENSOR_MAC_MODE first — 0 (Disable) is the reset value being replaced, not a bit to OR around
    mac_top |= MAC_TOP_SENSOR_MAC_MODE_CSI | MAC_TOP_CSI_VS_INV | MAC_TOP_CSI_HS_INV | MAC_TOP_CSI_CTRL_ENABLE;
    mac_reg_write(CIF_MAC_TOP_REG_00, mac_top);

    // MAC CSI: 2 lanes (reg_csi_lane_mode: 0=1-lane 1=2-lane 3=4-lane 7=8-lane).
    mac_reg_write(CIF_MAC_CSI_REG_00, 1);
    // Unmask + clear interrupt status, HDR off (bits 16/17 of this same
    // register — the real CSI_HDR_EN/CSI_HDR_MODE location, not a
    // separate REG_08 as the cv1835 reference implied).
    mac_reg_write(CIF_MAC_CSI_REG_04, 0x0000FF00); // CSI_INTR_CLR=0xff, CSI_INTR_MASK=0 (unmasked), HDR bits 16/17=0
    // CSI_VS_GEN_MODE reset value is 2 ("vs gen by FS & FE") — written
    // explicitly rather than left alone, but NOT overridden to 0 the
    // way the first attempt's (wrong, cv1835-derived) "HDR fix" did.
    mac_reg_write(CIF_MAC_CSI_REG_70, 2);

    // WRAP: link0's own digital lane config block (+0x300) — CSI mode,
    // lane mapping.
    wrap_reg_write(WRAP_L0_SENSOR_MODE, 0);

    // Lane select — see WRAP_L0_LANE_SEL's own comment on the sourcing:
    // Milk-V's own sensor_cfg_GC2083.ini ("lane_id = 3, 2, 4, -1, -1"),
    // cross-checked against the mainboard schematic's own net names
    // (pad group 3 = MIPI0_CKN/CKP, pad group 2 = MIPI0_DN0/DP0, pad
    // group 4 = MIPI0_DN1/DP1 — the sensor's own "D_0"/"D_1" naming
    // lines up with which physical pad each one actually lands on).
    uint lane_sel = 0;
    lane_sel |= 2u << WRAP_L0_D0_SEL_SHIFT; // data0 <- physical pad 2
    lane_sel |= 4u << WRAP_L0_D1_SEL_SHIFT; // data1 <- physical pad 4
    wrap_reg_write(WRAP_L0_LANE_SEL, lane_sel);

    uint ck_sel = wrap_reg_read(WRAP_L0_CK_SEL);
    ck_sel &= ~(uint)0x7;
    ck_sel |= 3u << WRAP_L0_CK_SEL_SHIFT; // clock <- physical pad 3
    // pnswap bits, same register: bit4=ck, bit8=d0, bit9=d1 (datasheet
    // Offset 0x0A0D0300+0x08 — this register, confirmed twice over at
    // two different documented offsets in the source PDF).
    ck_sel &= ~(uint)((1u<<4) | (1u<<8) | (1u<<9));
    if ((pnswap_bits & 1u) != 0) { ck_sel |= 1u << 4; }
    if ((pnswap_bits & 2u) != 0) { ck_sel |= 1u << 8; }
    if ((pnswap_bits & 4u) != 0) { ck_sel |= 1u << 9; }
    wrap_reg_write(WRAP_L0_CK_SEL, ck_sel);

    // Analog clock-channel select — see its own comment above. Same
    // physical lane (3) as WRAP_L0_CK_SEL, one-hot at the global level.
    uint wrap_reg04 = wrap_reg_read(WRAP_REG_04);
    wrap_reg04 &= ~((uint)0x3F << WRAP_SEL_CLK_CHANNEL_SHIFT);
    wrap_reg04 |= (1u << WRAP_SEL_CLK_CHANNEL_PHYS_LANE) << WRAP_SEL_CLK_CHANNEL_SHIFT;
    wrap_reg_write(WRAP_REG_04, wrap_reg04);

    uint pd = wrap_reg_read(WRAP_PD_CTRL);
    pd |= WRAP_PD_IBIAS_BIT | WRAP_PD_RXLP_MASK;
    wrap_reg_write(WRAP_PD_CTRL, pd);

    pd = wrap_reg_read(WRAP_PD_CTRL);
    pd &= ~WRAP_PD_IBIAS_BIT;
    wrap_reg_write(WRAP_PD_CTRL, pd);

    uint glb = wrap_reg_read(WRAP_L0_CSI_GLB_CTL0);
    glb &= ~(uint)0xF; // reg_deskew_lane_en is a 4-bit VALUE (0/1/3/0xf), not independent bits — clear the whole field
    wrap_reg_write(WRAP_L0_CSI_GLB_CTL0, glb);

    pd = wrap_reg_read(WRAP_PD_CTRL);
    pd &= ~WRAP_PD_RXLP_MASK;
    wrap_reg_write(WRAP_PD_CTRL, pd);

    busy_wait_us(20);

    glb = wrap_reg_read(WRAP_L0_CSI_GLB_CTL0);
    glb = (glb & ~(uint)0xF) | 0x3; // reg_deskew_lane_en = 2-lane
    wrap_reg_write(WRAP_L0_CSI_GLB_CTL0, glb);

    print("cifd: stream enabled (analog front-end powered up, 2 lanes deskew-enabled)\n");
    print("cifd: [diag] WRAP PD_CTRL=0x"); print_hex32(wrap_reg_read(WRAP_PD_CTRL)); print("\n");
    print("cifd: [diag] WRAP L0_CSI_GLB_CTL0=0x"); print_hex32(wrap_reg_read(WRAP_L0_CSI_GLB_CTL0)); print("\n");
    print("cifd: [diag] WRAP REG_04 (sel_clk_channel)=0x"); print_hex32(wrap_reg_read(WRAP_REG_04)); print("\n");
}

// Wire protocol: request is a single verb byte, plus for CIF_IPC_
// STREAM_ENABLE one payload byte (byte0 = pnswap_bits, see cif_stream_
// enable()'s own comment; ignored/unused for CIF_IPC_GET_STATUS). Reply
// is 8 bytes: byte0 = CIF_STATUS_* below, bytes 1-4 = raw REG_0x440
// (the MAC's own CSI_STATUS — error bits + CSI_DECODE_FORMAT, both
// datasheet-confirmed), bytes 5-7 unused.
//
// There is no documented "D-PHY lane HS state" register on real
// CV1800B silicon at all (the cv1835 reference's own DBG_300 doesn't
// appear anywhere in the real CV1800B datasheet — likely cv1835-only,
// or an internal-only debug register CV1800B's own public TRM omits).
// CSI_DECODE_FORMAT actually becoming non-zero is a *better* signal
// than raw lane electrical state anyway: it only latches once the MAC
// has successfully decoded a real CSI-2 packet header, proving the
// link works end-to-end at the protocol level, not just electrically.
const uint CIF_IPC_GET_STATUS    = 1;
const uint CIF_IPC_STREAM_ENABLE = 2; // no payload either way; reply mirrors GET_STATUS's own format
const uint CIF_IPC_MSG_MAX    = 8;

const int CIF_STATUS_LOCKED     = 0; // a valid packet header has been decoded, no errors
const int CIF_STATUS_NOT_LOCKED = 1; // no errors seen, but no packet decoded yet either
const int CIF_STATUS_ERROR      = 2; // ECC/CRC/WC error bit set

fn void cifd_ipc_poll()
{
    char[CIF_IPC_MSG_MAX] buf @noinit;
    uint verb = 0;
    int from = ipc_poll_type(&buf[0], (int)CIF_IPC_MSG_MAX, &verb);
    if (from < 0) { return; }
    if (verb != CIF_IPC_GET_STATUS && verb != CIF_IPC_STREAM_ENABLE) { return; }

    if (verb == CIF_IPC_STREAM_ENABLE) { cif_stream_enable((uint)(char)buf[0]); }

    uint status_reg = mac_reg_read(CIF_MAC_CSI_REG_40);
    uint decode_fmt = (status_reg >> CSI_DECODE_FORMAT_SHIFT) & CSI_DECODE_FORMAT_MASK;

    int status;
    if ((status_reg & CSI_ERROR_BITS) != 0) { status = CIF_STATUS_ERROR; }
    else if (decode_fmt != 0) { status = CIF_STATUS_LOCKED; }
    else { status = CIF_STATUS_NOT_LOCKED; }

    // reply[5] carries PD_CTRL's own IBIAS/RXLP bits, shifted down so
    // they land in one byte (bit14=ibias -> reply bit0, bits[21:16]=
    // rxlp -> reply bits[7:1]) — not relied on for the LOCKED/ERROR
    // decision, purely so a caller can confirm cif_stream_enable()
    // actually powered the analog front end up without trusting this
    // driver's own print() output: a print from deep in this same IPC
    // poll call chain silently failed to reach the console this
    // session (i2cd.c3 hit the identical symptom once already), so the
    // wire reply is the only way to know for sure.
    uint pd_ctrl = wrap_reg_read(WRAP_PD_CTRL);
    char[CIF_IPC_MSG_MAX] reply @noinit;
    reply[0] = (char)status;
    reply[1] = (char)(status_reg & 0xff);
    reply[2] = (char)((status_reg >> 8) & 0xff);
    reply[3] = (char)((status_reg >> 16) & 0xff);
    reply[4] = (char)((status_reg >> 24) & 0xff);
    reply[5] = (char)((pd_ctrl >> 14) & 0xff);
    reply[6] = (char)0;
    reply[7] = (char)0;

    ipc_reply(from, verb, &reply[0], (int)CIF_IPC_MSG_MAX, 0);
}

fn void main()
{
    cif_init();

    srv_post("cifd");
    print("cifd: init done\n");

    for (;;)
    {
        cifd_ipc_poll();
        yield();
    }
}
