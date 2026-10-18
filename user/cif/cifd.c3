module user;

import std::nolibc::main_stub;
import std::nolibc::mem;

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
const uint VIP_ENABLE_RST_CSI_MAC0 = 1u << 0; // REG_04 bit 0 — actually clk_axi_isp_top_en (riscv64 reg_vip_sys.h; the vi driver's _vi_clk_ctrl sets it), not a reset: Linux runs with it 1
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
    // Polarity as Milk-V's Linux actually runs it while streaming: REG_00
    // bit 20 CLEAR and REG_04 bit 0 SET (0x00000000 / 0x0000ffff,
    // docs/camera-linux-regs-2026-10-18.txt) — the opposite of what the
    // header naming (clk_*_en, rst_*) suggested, which this used to do.
    uint reg0 = vipsys_reg_read(VIP_SYS_REG_00);
    reg0 &= ~VIP_CLK_CSI_MAC0_EN;
    vipsys_reg_write(VIP_SYS_REG_00, reg0);

    uint reg4 = vipsys_reg_read(VIP_SYS_REG_04);
    reg4 |= VIP_ENABLE_RST_CSI_MAC0;
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

    // Milk-V's Linux, read back while it streamed this sensor on this
    // board (docs/camera-linux-regs-2026-10-18.txt), also has these, which
    // nothing above sets. Applied verbatim: they're the vendor driver's
    // working configuration; a rough on-board ablation (docs/devlog.md
    // 2026-10-18) pointed at the analog block and the lane selects, but
    // which of these are strictly needed hasn't been pinned down.
    wrap_reg_write(WRAP_REG_04, 0x00080080);    // clk channel = phys lane 3 (one-hot) + bit 7 (Linux), not bit 6
    wrap_reg_write(0x07c, 0x00230023);          // D-PHY analog front end (per-lane settings)
    wrap_reg_write(0x080, 0x0014003f);
    wrap_reg_write(0x084, 0x00082020);
    wrap_reg_write(0x088, 0x00002003);
    wrap_reg_write(0x110, 0x00080000);
    wrap_reg_write(0x114, 0x00000003);
    wrap_reg_write(WRAP_L0_LANE_SEL, lane_sel | (1u << 12));  // + d3 <- 1, as Linux has it
    wrap_reg_write(WRAP_LINK0_BASE + 0x10, 0x00000210);       // Linux: 0x210 (bit 17 clear)
    mac_reg_write(CIF_MAC_CSI_REG_04, 0x000c0000);
    mac_reg_write(CIF_MAC_CSI_REG_70, 0x00000f00);

    print("cifd: stream enabled (analog front-end powered up, 2 lanes deskew-enabled)\n");
    print("cifd: [diag] WRAP PD_CTRL=0x"); print_hex32(wrap_reg_read(WRAP_PD_CTRL)); print("\n");
    print("cifd: [diag] WRAP L0_CSI_GLB_CTL0=0x"); print_hex32(wrap_reg_read(WRAP_L0_CSI_GLB_CTL0)); print("\n");
    print("cifd: [diag] WRAP REG_04 (sel_clk_channel)=0x"); print_hex32(wrap_reg_read(WRAP_REG_04)); print("\n");
}

// --- Stage 4: raw capture through the `vi` block (0x0A000000) -----------
//
// The only route from the CSI MAC to DRAM. The register map is
// duo-buildroot-sdk's middleware/v2/include/linux/{isp_reg.h,
// vi_reg_blocks.h, vi_reg_fields.h} (cv180x); the sequence below follows
// the open vi driver, github.com/sophgo/osdrv interdrv/vi/chip/cv180x (a
// symlink to cv181x, with explicit __CV180X__ branches), on its raw-dump
// path (vi_raw_dump.c): CSI MAC -> pre_raw_fe0 -> its CSI bridge
// (CSIBDG0) -> the bridge's write DMA (DMA_CTL6, "fe0_csibdg_le") ->
// DRAM, 12-bit packed, 2 pixels per 3 bytes. Nothing past the front end
// (BE, raw/rgb/yuv tops) is involved. Function names in the comments are
// the driver's.
const uint VI_BASE        = 0x0a000000;
const uint VI_PRE_RAW_FE0 = VI_BASE + 0x00000;
const uint VI_CSIBDG0     = VI_BASE + 0x00800;
const uint VI_DMA_CTL6    = VI_BASE + 0x00b00;
const uint VI_ISPTOP      = VI_BASE + 0x70000;

// PRE_RAW_FE (REG_PRE_RAW_FE_T)
const uint FE_PRE_RAW_CTRL       = 0x000;
const uint FE_PRE_RAW_FRAME_SIZE = 0x004; // FRAME_WIDTHM1[12:0] FRAME_HEIGHTM1[28:16]
const uint FE_PRE_RAW_FRAME_VLD  = 0x028; // FE_FRAME_VLD_CH0[0] FE_PQ_VLD_CH0[4]

// CSI bridge (REG_ISP_CSI_BDG_T)
const uint BDG_TOP_CTRL       = 0x000;
const uint BDG_INTERRUPT_CTRL = 0x004; // CHn_VS_INT_EN at bit 4n
const uint BDG_DMA_DPCM_MODE  = 0x008;
const uint BDG_CH0_SIZE       = 0x010; // CH1..3 at +4 each: WIDTHM1[12:0] HEIGHTM1[28:16]
const uint BDG_PAT_GEN_CTRL   = 0x060; // PAT_EN[0]
const uint BDG_PAT_IDX_CTRL   = 0x064; // PAT_PRD[7:0] PAT_IDX[12:8]
const uint BDG_PAT_COLOR_0    = 0x068; // R[11:0] G[27:16]
const uint BDG_PAT_COLOR_1    = 0x06c; // B[11:0]
const uint BDG_BG_COLOR_0     = 0x070;
const uint BDG_BG_COLOR_1     = 0x074;
const uint BDG_FIX_COLOR_0    = 0x078;
const uint BDG_FIX_COLOR_1    = 0x07c;
const uint BDG_MDE_V_SIZE     = 0x080; // STR[12:0] STP[28:16], same layout for the next five
const uint BDG_MDE_H_SIZE     = 0x084;
const uint BDG_FDE_V_SIZE     = 0x088;
const uint BDG_FDE_H_SIZE     = 0x08c;
const uint BDG_HSYNC_CTRL     = 0x090;
const uint BDG_VSYNC_CTRL     = 0x094;
const uint BDG_TGEN_TT_SIZE   = 0x098; // HTT[12:0] VTT[28:16]
const uint BDG_CH0_DEBUG_0    = 0x0a0; // CH0_PXL_CNT
const uint BDG_INT_STATUS_0   = 0x0e0; // write-1-to-clear
const uint BDG_INT_STATUS_1   = 0x0e4; // FIFO_OVERFLOW[0] RESOLUTION_OVER_MAX[1] DMA_ERROR[4]
const uint BDG_WDMA_CH0_CROP_EN   = 0x110;
const uint BDG_WDMA_CH0_HORZ_CROP = 0x114; // START[12:0] END[28:16]
const uint BDG_WDMA_CH0_VERT_CROP = 0x118;

const uint BDG_TOP_CSI_MODE_SENSOR = 1;       // CSI_MODE[1:0]: 1 = from the CSI MAC, 3 = pattern generator
const uint BDG_TOP_CSI_MODE_PATGEN = 3;
const uint BDG_TOP_CH0_DMA_WR_EN   = 1u << 6;
const uint BDG_TOP_PXL_DATA_SEL    = 1u << 10; // 1 = pixels from the pattern generator
const uint BDG_TOP_CSI_ENABLE      = 1u << 24;
const uint BDG_TOP_TGEN_ENABLE     = 1u << 25;
const uint BDG_TOP_CSI_UP_REG      = 1u << 31; // latch the shadowed config

// Write DMA channel (REG_ISP_DMA_CTL_T)
const uint DMA_SYS_CONTROL = 0x000; // BASEH[15:8] BASE_SEL[16] STRIDE_SEL[17] SEGLEN_SEL[18] SEGNUM_SEL[19]
const uint DMA_BASE_ADDR   = 0x004;
const uint DMA_SEGLEN      = 0x008;
const uint DMA_STRIDE      = 0x00c;
const uint DMA_SEGNUM      = 0x010;
const uint DMA_STATUS      = 0x014;
const uint DMA_SW_MODE     = (1u << 16) | (1u << 17) | (1u << 18) | (1u << 19);

// ISPTOP (REG_ISP_TOP_T)
const uint TOP_INT_EVENT0    = 0x000; // FRAME_DONE_FE0[3:0], write-1-to-clear
const uint TOP_INT_EVENT2    = 0x008; // FRAME_START_FE0[3:0] FRAME_ERR[8] INT_DMA_ERR[16]
const uint TOP_INT_EVENT0_EN = 0x010;
const uint TOP_INT_EVENT2_EN = 0x018;
const uint TOP_SW_CTRL_0     = 0x020; // SHAW_UP_FE0[19:16]
const uint TOP_SW_CTRL_1     = 0x024; // PQ_UP_FE0[3:0]
const uint TOP_CTRL_MODE_SEL0 = 0x028; // TRIG_STR_SEL_FE0[3:0] SHAW_UP_SEL_FE0[19:16]
const uint TOP_CTRL_MODE_SEL1 = 0x02c; // PQ_UP_SEL_FE0[3:0]
const uint TOP_SCENARIOS_CTRL = 0x030;
const uint TOP_SW_RST        = 0x034; // ISP_RST[0] CSI0_RST[1] ... AXI_RST[6] ... RAW_RST[9]
const uint TOP_INT_EVENT1    = 0x004;
// FE -> DRAM only: FE_DMA_SHARE_ENABLE alone. The reset default has
// PRE2BE_L_ENABLE (FE0 streams online into the back end) and the online
// RGB map set; with no back end running that back-pressures the bridge
// into a FIFO overflow after its first line (seen on the board).
const uint TOP_SCENARIO_FE_TO_DRAM = 1u << 22;

// The GC2083's full frame — CSIBDG's channel sizes describe what arrives,
// the WDMA crop picks the window written to DRAM.
const uint VI_SENSOR_W = 1920;
const uint VI_SENSOR_H = 1080;

// Clock gates of the vi node's clock list (cv180x_base.dtsi: clk_src_vip_
// sys_0..3, clk_axi_vip, clk_csi_be_vip, clk_raw_vip, clk_isp_top_vip,
// clk_csi_mac0_vip), mapped to bits by linux_5.10/drivers/clk/cvitek/
// clk-cv180x.c. Milk-V's Linux has all of them on while streaming.
const uint REG_CLK_EN_4 = 0x010;
const uint VI_CLK_EN_2_BITS = (1u << 4) | (1u << 5) | (1u << 6) | (1u << 18) | (1u << 20);
const uint VI_CLK_EN_3_BITS = 1u << 29;
const uint VI_CLK_EN_4_BITS = (1u << 8) | (1u << 15) | (1u << 18);

// VIP_SYS words the link didn't need but the ISP does, as Linux has them
// (docs/camera-linux-regs-2026-10-18.txt; names from freertos/cvitek/
// common/include/interdrv/chip/riscv64/reg_vip_sys.h). +0x38's divider
// 10 (ratio (10+1)/32: 594 MHz -> ~204 MHz) is the vi driver's own
// cv180x value — clk_mac must stay <= 2x the back end's clock.
const uint VIP_SYS_AXI_SW            = 0x010;
const uint VIP_SYS_LP_CTRL_AXI_RT    = 0x020;
const uint VIP_SYS_LP_CTRL_X2P       = 0x028;
const uint VIP_SYS_CLK_RATIO_CSI_MAC0 = 0x038; // NORM_DIV_EN[0] UPDATE_SEL[2] NORM_DIV_VAL[20:16]

const uint VI_FRAME_BYTES = 760 * 4096; // must match boards/duo/board.c3 VI_FRAME_PAGES
uptr g_vi_frame_paddr;  // cifd's DMA region (boards/duo/board.c3 VI_FRAME_PAGES), identity-mapped, uncached
uint g_vi_frame_bytes;  // what the last capture wrote

fn uint vi_rd(uint a) { return mmio_read32((uptr)a); }
fn void vi_wr(uint a, uint v) { mmio_write32((uptr)a, v); }

fn uint vi_stride(uint w) { return (3 * ((w + 1) / 2) + 0xf) & ~(uint)0xf; } // VI_ALIGN(3 * UPPER(w, 1))

// Everything the ISP needs powered that the link alone didn't. ORs gates
// in, never pulses a reset: toggling VIP_SYS's axi/isp_top resets once
// left the CSI MAC's registers faulting (see vip_sys_bring_up).
fn void vi_power_up()
{
    clock_reg_write(REG_CLK_EN_2, clock_reg_read(REG_CLK_EN_2) | VI_CLK_EN_2_BITS);
    clock_reg_write(REG_CLK_EN_3, clock_reg_read(REG_CLK_EN_3) | VI_CLK_EN_3_BITS);
    clock_reg_write(REG_CLK_EN_4, clock_reg_read(REG_CLK_EN_4) | VI_CLK_EN_4_BITS);
    vipsys_reg_write(VIP_SYS_AXI_SW, 0x0000000f);
    vipsys_reg_write(VIP_SYS_LP_CTRL_AXI_RT, 0x00000c01);
    vipsys_reg_write(VIP_SYS_LP_CTRL_X2P, 0x00000c01);
    uint ratio = vipsys_reg_read(VIP_SYS_CLK_RATIO_CSI_MAC0);
    ratio = (ratio & ~(uint)0x001f0000) | (10u << 16) | 1u | 4u;
    vipsys_reg_write(VIP_SYS_CLK_RATIO_CSI_MAC0, ratio);
    vipsys_reg_write(VIP_SYS_REG_04, vipsys_reg_read(VIP_SYS_REG_04) | 1u); // clk_axi_isp_top_en (the driver's _vi_clk_ctrl)
}

// Pattern generator timing (_patgen_config_timing, cv180x values: htt*vtt
// *fps must fit the ~204 MHz clk_mac).
fn void vi_patgen_setup()
{
    uint b = VI_CSIBDG0;
    uint hm1 = VI_SENSOR_H - 1;
    vi_wr(b + BDG_MDE_V_SIZE, (hm1 << 16) | 0);
    vi_wr(b + BDG_MDE_H_SIZE, ((VI_SENSOR_W - 1) << 16) | 0);
    vi_wr(b + BDG_FDE_V_SIZE, ((0x10 + hm1) << 16) | 0x10);
    vi_wr(b + BDG_FDE_H_SIZE, ((0x10 + VI_SENSOR_W - 1) << 16) | 0x10);
    vi_wr(b + BDG_HSYNC_CTRL, (5u << 16) | 4);
    vi_wr(b + BDG_VSYNC_CTRL, (5u << 16) | 4);
    vi_wr(b + BDG_TGEN_TT_SIZE, (0x7d0u << 16) | 0x1000);
    // _patgen_config_pat: PAT_IDX 7 with fixed MDE colours, so a correct
    // capture has known pixel values (R 0x457, G 0x8ae, B 0xd05).
    vi_wr(b + BDG_PAT_GEN_CTRL, 1);              // PAT_EN, everything else off, BAYER_ID 0
    vi_wr(b + BDG_PAT_IDX_CTRL, 7u << 8);
    vi_wr(b + BDG_PAT_COLOR_0, (0xfffu << 16) | 0xfff);
    vi_wr(b + BDG_PAT_COLOR_1, 0xfff);
    vi_wr(b + BDG_BG_COLOR_0, (1u << 16) | 0);
    vi_wr(b + BDG_BG_COLOR_1, 2);
    vi_wr(b + BDG_FIX_COLOR_0, (0x8aeu << 16) | 0x457);
    vi_wr(b + BDG_FIX_COLOR_1, 0xd05);
}

// Result of one capture, in the CAPTURE reply.
struct Vi_result
{
    uint int_event0;   // ISPTOP INT_EVENT0 when done (or at the timeout)
    uint int_event2;
    uint bdg_status;   // CSIBDG0 INTERRUPT_STATUS_0
    uint bdg_status1;  // CSIBDG0 INTERRUPT_STATUS_1
    uint pxl_cnt;      // CSIBDG0 CH0_PXL_CNT
    uint dma_status;   // DMA_CTL6 DMA_STATUS
    uint bytes;        // stride * h
    bool done;         // FRAME_DONE_FE0 seen
}

// One frame of the (cx, cy, cw, ch) window into the DMA region. patgen =
// the bridge's own pattern generator instead of the sensor (cifinit must
// have locked the link first for the sensor path).
fn void vi_capture(bool patgen, uint cx, uint cy, uint cw, uint ch, Vi_result* r)
{
    *r = {};
    uint stride = vi_stride(cw);
    if (g_vi_frame_paddr == 0 || cw == 0 || ch == 0 || cx + cw > VI_SENSOR_W || cy + ch > VI_SENSOR_H
        || (ulong)stride * ch > (ulong)VI_FRAME_BYTES) { return; }

    vi_power_up();

    // The ISP's own soft reset (isp_reset, run first by vi_start_streaming):
    // hardware triggers back on, AXI first, then every block. Internal to
    // ISPTOP — not VIP_SYS's isp_top reset. Without it a bridge left mid-
    // frame by an earlier capture stays wedged at line 1.
    vi_wr(VI_ISPTOP + TOP_CTRL_MODE_SEL0, vi_rd(VI_ISPTOP + TOP_CTRL_MODE_SEL0) | 0xf);
    vi_wr(VI_ISPTOP + TOP_SW_RST, 0x040);
    vi_wr(VI_ISPTOP + TOP_SW_RST, 0x37f);
    vi_wr(VI_ISPTOP + TOP_SW_RST, 0x040);
    vi_wr(VI_ISPTOP + TOP_SW_RST, 0);

    // ISPTOP (ispblk_isptop_config): FE0 triggered and shadow-updated by
    // hardware (sensor online), frame-done/frame-start events on, and the
    // FE -> DRAM scenario.
    vi_wr(VI_ISPTOP + TOP_INT_EVENT0, 0xffffffff);
    vi_wr(VI_ISPTOP + TOP_INT_EVENT1, 0xffffffff);
    vi_wr(VI_ISPTOP + TOP_INT_EVENT2, 0xffffffff);
    vi_wr(VI_ISPTOP + TOP_INT_EVENT0_EN, 0xf);
    vi_wr(VI_ISPTOP + TOP_INT_EVENT2_EN, 0xf);
    vi_wr(VI_ISPTOP + TOP_CTRL_MODE_SEL0, (1u << 16) | 1u);
    vi_wr(VI_ISPTOP + TOP_CTRL_MODE_SEL1, 1u);
    vi_wr(VI_ISPTOP + TOP_SCENARIOS_CTRL, TOP_SCENARIO_FE_TO_DRAM);

    // pre_raw_fe0 (ispblk_preraw_fe_config): frame size, Bayer type left 0.
    vi_wr(VI_PRE_RAW_FE0 + FE_PRE_RAW_FRAME_SIZE, ((VI_SENSOR_H - 1) << 16) | (VI_SENSOR_W - 1));

    // CSI bridge (ispblk_csibdg_config + _wdma_crop_config + _dma_wr_en).
    uint b = VI_CSIBDG0;
    uint top = BDG_TOP_CH0_DMA_WR_EN | (patgen ? (BDG_TOP_CSI_MODE_PATGEN | BDG_TOP_PXL_DATA_SEL) : BDG_TOP_CSI_MODE_SENSOR);
    vi_wr(b + BDG_TOP_CTRL, top);
    for (uint c = 0; c < 4; c++) { vi_wr(b + BDG_CH0_SIZE + 4 * c, ((VI_SENSOR_H - 1) << 16) | (VI_SENSOR_W - 1)); }
    vi_wr(b + BDG_DMA_DPCM_MODE, 0);
    vi_wr(b + BDG_INTERRUPT_CTRL, (1u << 0) | (1u << 4) | (1u << 8) | (1u << 12));
    vi_wr(b + BDG_INT_STATUS_0, vi_rd(b + BDG_INT_STATUS_0));
    vi_wr(b + BDG_INT_STATUS_1, vi_rd(b + BDG_INT_STATUS_1));
    if (patgen) { vi_patgen_setup(); } else { vi_wr(b + BDG_PAT_GEN_CTRL, 0); }
    vi_wr(b + BDG_WDMA_CH0_HORZ_CROP, ((cx + cw - 1) << 16) | cx);
    vi_wr(b + BDG_WDMA_CH0_VERT_CROP, ((cy + ch - 1) << 16) | cy);
    vi_wr(b + BDG_WDMA_CH0_CROP_EN, 1);

    // Its write DMA (ispblk_dma_set_sw_mode + ispblk_dma_config).
    mem::set((void*)g_vi_frame_paddr, 0, (usz)VI_FRAME_BYTES);
    uint d = VI_DMA_CTL6;
    uint sys = vi_rd(d + DMA_SYS_CONTROL);
    sys = (sys & ~(uint)0xff00) | DMA_SW_MODE | (uint)(((ulong)g_vi_frame_paddr >> 32) & 0xff) << 8;
    vi_wr(d + DMA_SYS_CONTROL, sys);
    vi_wr(d + DMA_SEGLEN, stride);
    vi_wr(d + DMA_STRIDE, stride);
    vi_wr(d + DMA_SEGNUM, ch);
    vi_wr(d + DMA_BASE_ADDR, (uint)g_vi_frame_paddr);

    // Stream on (isp_streaming), then the first-frame trigger (isp_pre_trig).
    vi_wr(VI_ISPTOP + TOP_SW_CTRL_1, 1u);
    vi_wr(VI_ISPTOP + TOP_SW_CTRL_0, 1u << 16);
    vi_wr(b + BDG_TOP_CTRL, top | BDG_TOP_CSI_UP_REG | BDG_TOP_CSI_ENABLE | (patgen ? BDG_TOP_TGEN_ENABLE : 0));
    vi_wr(VI_PRE_RAW_FE0 + FE_PRE_RAW_FRAME_VLD, vi_rd(VI_PRE_RAW_FE0 + FE_PRE_RAW_FRAME_VLD) | (1u << 4) | 1u);

    ulong hz = timebase_hz();
    ulong deadline = rdtime() + hz / 2;
    while (rdtime() < deadline)
    {
        if ((vi_rd(VI_ISPTOP + TOP_INT_EVENT0) & 0x1) != 0) { r.done = true; break; }
        yield();
    }
    r.int_event0 = vi_rd(VI_ISPTOP + TOP_INT_EVENT0);
    r.int_event2 = vi_rd(VI_ISPTOP + TOP_INT_EVENT2);
    r.bdg_status = vi_rd(b + BDG_INT_STATUS_0);
    r.bdg_status1 = vi_rd(b + BDG_INT_STATUS_1);
    r.pxl_cnt    = vi_rd(b + BDG_CH0_DEBUG_0);
    r.dma_status = vi_rd(d + DMA_STATUS);

    // Stream off, so the next frame can't overwrite this one.
    vi_wr(b + BDG_TOP_CTRL, top & ~BDG_TOP_CH0_DMA_WR_EN);
    r.bytes = stride * ch;
    g_vi_frame_bytes = r.done ? r.bytes : 0;
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
// Debug access for bring-up (the dev shell's cifpeek/cifpoke/cifdiff/
// cifgolden): read or write one 32-bit word, restricted to the pages this
// driver maps. PEEK: req[0..3] = addr; reply[0] = 0 ok / 1 refused,
// reply[1..4] = value. POKE: req[0..3] = addr, req[4..7] = value;
// reply[0] = 0 / 1. All little-endian.
const uint CIF_IPC_PEEK = 3;
const uint CIF_IPC_POKE = 4;
const uint CIF_IPC_MSG_MAX    = 8;
// Stage 4 raw capture. CAPTURE: req[0] = 1 patgen / 0 sensor, then
// x, y, w, h as little-endian u16 at req[1..8]; reply = 0 ok / 1 no
// frame-done / 2 bad request, then INT_EVENT0, INT_EVENT2, CSIBDG
// INTERRUPT_STATUS_0, CH0_PXL_CNT, DMA_STATUS, the byte count and CSIBDG
// INTERRUPT_STATUS_1, all u32 LE (29 bytes). FRAME_READ: req[0..3] = offset; reply = up to
// CIF_FRAME_CHUNK bytes of the last capture from there (0 past its end).
const uint CIF_IPC_CAPTURE    = 5;
const uint CIF_IPC_FRAME_READ = 6;
const uint CIF_IPC_REQ_MAX    = 16;
const uint CIF_CAPTURE_REPLY  = 29;
const uint CIF_FRAME_CHUNK    = 4096;

const int CIF_STATUS_LOCKED     = 0; // a valid packet header has been decoded, no errors
const int CIF_STATUS_NOT_LOCKED = 1; // no errors seen, but no packet decoded yet either
const int CIF_STATUS_ERROR      = 2; // ECC/CRC/WC error bit set

// One request, blocking until it arrives (ipc_recv_type_gen). This used
// to be ipc_poll_type + yield() in main's loop: an always-runnable
// process that made every scheduler round longer, and with two such
// servers burst console input on the Duo arrived corrupted (the shell
// drained the UART too slowly; docs/devlog.md 2026-10-18).
// The pages boards/duo/board.c3's "cif" device maps for this process —
// anything else would fault the driver. Word-aligned only.
fn bool cif_addr_mapped(uint a)
{
    if ((a & 3) != 0) { return false; }
    uint page = a & ~(uint)0xfff;
    return page == CIF_MAC_BASE || page == CIF_WRAP_BASE || page == VIP_SYS_BASE
        || page == CLOCK_BASE || page == RESET_BASE
        || page == VI_PRE_RAW_FE0 || page == VI_ISPTOP || page == VI_ISPTOP + 0x2000; // + WDMA_CORE0
}

fn void cifd_ipc_serve()
{
    char[CIF_IPC_REQ_MAX] buf @noinit;
    uint verb = 0;
    uint from_gen = 0;
    int from = ipc_recv_type_gen(&buf[0], (int)CIF_IPC_REQ_MAX, &verb, &from_gen);
    if (from <= 0) { return; }
    if (verb == CIF_IPC_CAPTURE)
    {
        uint[4] win;
        for (int i = 0; i < 4; i++) { win[i] = (uint)buf[1 + 2 * i] | ((uint)buf[2 + 2 * i] << 8); }
        Vi_result r;
        vi_capture(buf[0] != 0, win[0], win[1], win[2], win[3], &r);
        char[CIF_CAPTURE_REPLY] cr;
        cr[0] = r.bytes == 0 ? (char)2 : (r.done ? (char)0 : (char)1);
        uint[7] f = { r.int_event0, r.int_event2, r.bdg_status, r.pxl_cnt, r.dma_status, r.bytes, r.bdg_status1 };
        for (int i = 0; i < 7; i++) { for (int k = 0; k < 4; k++) { cr[1 + 4 * i + k] = (char)(f[i] >> (8 * k)); } }
        ipc_reply(from, verb, &cr[0], (int)CIF_CAPTURE_REPLY, from_gen);
        return;
    }
    if (verb == CIF_IPC_FRAME_READ)
    {
        uint off = (uint)buf[0] | ((uint)buf[1] << 8) | ((uint)buf[2] << 16) | ((uint)buf[3] << 24);
        uint n = 0;
        if (off < g_vi_frame_bytes) { n = g_vi_frame_bytes - off; if (n > CIF_FRAME_CHUNK) { n = CIF_FRAME_CHUNK; } }
        ipc_reply(from, verb, (char*)(g_vi_frame_paddr + off), (int)n, from_gen);
        return;
    }
    if (verb == CIF_IPC_PEEK || verb == CIF_IPC_POKE)
    {
        uint addr = (uint)buf[0] | ((uint)buf[1] << 8) | ((uint)buf[2] << 16) | ((uint)buf[3] << 24);
        char[CIF_IPC_MSG_MAX] pr;
        bool ok = cif_addr_mapped(addr);
        uint v = 0;
        if (ok && verb == CIF_IPC_POKE)
        {
            v = (uint)buf[4] | ((uint)buf[5] << 8) | ((uint)buf[6] << 16) | ((uint)buf[7] << 24);
            mmio_write32((uptr)addr, v);
        }
        else if (ok) { v = mmio_read32((uptr)addr); }
        pr[0] = ok ? (char)0 : (char)1;
        pr[1] = (char)(v & 0xff); pr[2] = (char)((v >> 8) & 0xff); pr[3] = (char)((v >> 16) & 0xff); pr[4] = (char)((v >> 24) & 0xff);
        ipc_reply(from, verb, &pr[0], (int)CIF_IPC_MSG_MAX, from_gen);
        return;
    }
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

    ipc_reply(from, verb, &reply[0], (int)CIF_IPC_MSG_MAX, from_gen);
}

fn void main()
{
    cif_init();
    uptr frame = 0;
    if (dev_info(&frame, 1) >= 1) { g_vi_frame_paddr = frame; }
    print("cifd: raw frame buffer at 0x"); print_hex32((uint)g_vi_frame_paddr); print("\n");

    srv_post("cifd");
    print("cifd: init done\n");

    for (;;)
    {
        cifd_ipc_serve();
    }
}
