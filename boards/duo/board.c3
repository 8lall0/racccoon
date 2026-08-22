module board;

import kernel;
import sbi;

// See boards/qemu/board.c3's header comment for what this module is
// and why it exists. This is the Milk-V Duo (CV1800B) implementation —
// see docs/devlog.md and ~/.claude/plans/giggly-prancing-iverson.md for
// the sourcing behind every address below and what's still unconfirmed.

// PLIC base confirmed from an upstream Linux devicetree patch for
// cv1800b.dtsi (compatible "sophgo,cv1800b-plic", "thead,c900-plic",
// reg = <0x70000000 0x4000000>, riscv,ndev = 101) — not inferred from a
// sibling chip. UNVERIFIED: whether the register *offsets* below
// (priority/enable/threshold/claim, and the context-numbering
// convention) actually match QEMU virt's SiFive-style PLIC just as
// closely as the base address alone suggests — "thead,c900-plic" is
// documented as PLIC-compatible, but that's not the same as confirmed
// identical register layout. Kept identical to boards/qemu/board.c3's
// formulas for now, on the working assumption that they match; if
// Stage 2's real hardware boot shows interrupts don't behave (IRQs
// never firing, or firing on the wrong claim value), this is the first
// place to look — the `board` contract exists specifically so fixing
// this means editing this file, not restructuring the kernel.
const uptr PLIC_BASE = 0x70000000;

// T-Head C906's MAEE (Memory Attribute Extended Encoding) quirk. FSBL
// (fsbl/lib/cpu/riscv/bl2_entrypoint.S in duo-buildroot-sdk) sets the
// M-mode-only mxstatus CSR to 0xc0638000 unconditionally before ever
// handing off to S-mode — bit 21 of that value is MAEE, and there is no
// way for S-mode code to turn it back off. Once enabled, the C906
// repurposes Sv39's normally-reserved PTE bits 63:59 as real memory-
// attribute fields (SO/C/B/SH/SEC, matching this exact SDK's own Linux
// fork's arch/riscv/include/asm/pgtable-bits.h) — SHARE|CACHE|BUF
// (bits 60-62) is the encoding Linux's own PAGE_KERNEL/_PAGE_BASE use
// for ordinary cacheable memory, applied at every page-table level (see
// page.c3's map_page). Kept as a correctness measure for cache
// attributes — NOTE this turned out NOT to be the cause of the real
// hardware hang chased through most of this board's bring-up (that was
// missing PAGE_A/PAGE_D — see page.c3's own comment and docs/devlog.md
// for the full elimination trail); MAEE may still matter for cache
// coherency even though it wasn't the hang's root cause.
const ulong PTE_EXTRA_BITS = (1UL << 60) | (1UL << 61) | (1UL << 62);

// No virtio-mmio (or any confirmed IRQ source) wired up for this
// platform yet — 0 rather than a real vendor IRQ number, matching
// plic_claim()'s own "0 = nothing pending" sentinel, so the
// diskd-wake check in entry.c3's handle_trap (`irq == IRQ_VIRTIO_BLK`)
// can never spuriously match a real interrupt. Harmless either way
// since HAS_BLOCK_DEVICE below means diskd never actually gets
// spawned, so diskd_pid stays 0 and that check's other half already
// short-circuits it — but 0 here is the more honest value than
// pretending a real vendor IRQ number.
const uint IRQ_VIRTIO_BLK = 0;

// Context = (hart, privilege mode) pair the PLIC targets — UNVERIFIED
// for c900-plic, kept as QEMU virt's own convention (context 1 =
// hart0 S-mode) pending real confirmation. See PLIC_BASE's comment.
const uptr PLIC_S_CONTEXT = 1;

const uptr PLIC_PRIORITY_BASE = PLIC_BASE;
const uptr PLIC_ENABLE_BASE   = PLIC_BASE + 0x2000 + PLIC_S_CONTEXT * 0x80;
const uptr PLIC_THRESHOLD     = PLIC_BASE + 0x200000 + PLIC_S_CONTEXT * 0x1000;
const uptr PLIC_CLAIM         = PLIC_BASE + 0x200004 + PLIC_S_CONTEXT * 0x1000;

// Context-independent, system-wide pending bitmap — unlike CLAIM (which
// is per-context and consumes/clears as it's read), this just reflects
// raw hardware pending state for every IRQ source, one bit each. Used
// only as a diagnostic (entry.c3's handle_trap) while chasing the
// IRQ_SDHCI claim-storm bug — see docs/devlog.md.
const uptr PLIC_PENDING_BASE = PLIC_BASE + 0x1000;

const uptr PLIC_PRIORITY_PAGE = PLIC_PRIORITY_BASE & (uptr)~(kernel::PAGE_SIZE - 1);
const uptr PLIC_ENABLE_PAGE   = PLIC_ENABLE_BASE & (uptr)~(kernel::PAGE_SIZE - 1);
const uptr PLIC_CLAIM_PAGE    = PLIC_CLAIM & (uptr)~(kernel::PAGE_SIZE - 1);
const uptr PLIC_PENDING_PAGE  = PLIC_PENDING_BASE & (uptr)~(kernel::PAGE_SIZE - 1);

// SDHCI-compliant SD controller (cvitek,cv180x-sd), sourced from
// duo-buildroot-sdk's own U-Boot driver (drivers/mmc/cvitek/sdhci-cv180x.c)
// and arch/riscv/dts/cv180x_base.dtsi's `sd:` node — a real, documented
// register layout, not reverse-engineered. See user/sdd.c3 for the driver
// that actually owns this (pad/power/clock bring-up, standard SD command
// sequence, PIO block transfers — no DMA, no PLIC involvement in v1).
const uptr SD_MMIO_BASE = 0x04310000;
const uint IRQ_SDHCI    = 36; // routed through plic_init()/handle_trap
                               // (entry.c3) the same way IRQ_VIRTIO_BLK
                               // is on QEMU — sdd.c3 blocks on it for
                               // block-transfer completion instead of
                               // busy-polling INT_STATUS.

// Real, confirmed timebase-frequency (rdtime()'s own tick rate), not
// guessed — read directly from the real devicetree shipped in
// duo-buildroot-sdk (build/boards/default/dts/cv180x_riscv/
// cv180x_base_riscv.dtsi), same sourcing already used for user/sdd.c3's
// own SD_TIMEBASE_HZ duplicate (board is kernel-only, unreachable from
// user-mode code — see that file's own header comment for why it can't
// just reference this constant directly). Kernel-side use: arming
// `stimecmp` for a real timer interrupt (see entry.c3's enable_timer_
// interrupts/arm_timer).
const ulong TIMEBASE_HZ = 25000000;

// One-time SD pad/power/clock bring-up (see user/sdd.c3's sdd_init) needs
// three more, separate MMIO pages besides SD_MMIO_BASE itself — none of
// them adjacent to it or to each other, so all three (plus SD_MMIO_BASE)
// get mapped individually by setup_sdd_mappings (process.c3). Register
// offsets within these pages are sdd.c3's concern, not this file's — this
// is just the page-granularity access list the page table needs.
const uptr SD_TOP_PAGE    = 0x03000000; // REG_TOP_SD_PWRSW_CTRL @ +0x1F4
const uptr SD_PINMUX_PAGE = 0x03001000; // PAD_SDIO0_* function-select +
                                          // REG_SDIO0_*_PAD_REG drive-
                                          // strength regs, both in range
const uptr SD_CLOCK_PAGE  = 0x03002000; // pll_reg @ +0x70,
                                          // CLOCK_BYPASS_SELECT_REGISTER @ +0x30

// This board has a block device (real SD storage, via sdd — see
// user/sdd.c3) but no virtio-mmio (a QEMU paravirtual device with no
// physical equivalent on real hardware). HAS_BLOCK_DEVICE gates whether
// kernel.c3 spawns *any* storage driver + fsd; HAS_SD_BLOCK/HAS_VIRTIO_BLOCK
// (mutually exclusive, both boards define both) tell it *which* driver
// process and kernel-side mapping helper to use for the one this board
// has. See boards/qemu/board.c3 for the mirror image.
const bool HAS_BLOCK_DEVICE = true;
const bool HAS_SD_BLOCK     = true;
const bool HAS_VIRTIO_BLOCK = false;

// USB host controller (Synopsys DesignWare USB2 OTG core, "DWC2") —
// see user/usbd.c3 for the driver (Phase 1: host-mode bring-up + HPRT
// connect/disconnect polling only, no enumeration/transfers/interrupts
// yet). Sourced directly from duo-buildroot-sdk's own U-Boot driver
// (drivers/usb/host/dwc2.c/.h — the generic DWC2 host driver CV1800B's
// devicetree binds to unmodified) and the SoC-specific TOP-block
// registers it also touches (board/cvitek/cv180x/board.c,
// cv180x_reg.h) — real, confirmed offsets, not reverse-engineered.
//
// The devicetree's own second `reg` range for this device (0x03006000,
// labeled "USB 2.0 PHY" in the source) is never actually written by
// any driver in that SDK — not mapped here at all. The real
// SoC-specific registers this driver needs live in the separate TOP
// control block instead, at the two small offsets below.
const uptr USB_MMIO_BASE     = 0x04340000; // DWC2 core — GOTGCTL/GAHBCFG/GUSBCFG/GRSTCTL/GINTSTS/GSNPSID/HCFG/HPRT0 all fit in the first 4KB page
const uptr USB_TOP_CTRL_PAGE = 0x03000000; // REG_TOP_USB_PHY_CTRL @ +0x48 (same physical page SD_TOP_PAGE above also maps, for unrelated registers — independent per-process page tables, no conflict)
const uptr USB_TOP_RST_PAGE  = 0x03003000; // REG_TOP_SOFT_RST @ +0x0 (RST_USB, bit11)
// The USB PHY's own reference clocks — clk_125m_usb/clk_33k_usb
// (REG_CLK_EN_1 bits 30/31) and clk_12m_usb (REG_CLK_EN_2 bit 0),
// confirmed via duo-buildroot-sdk's own Linux clock driver
// (drivers/clk/cvitek/clk-cv180x.c) and the devicetree's own
// clock-controller node (base 0x03002000, same physical page
// SD_CLOCK_PAGE above also maps, for its own unrelated PLL register —
// independent per-process page tables, no conflict). NOT documented
// in the real CV1800B/CV1801B datasheet's own clk_en_1 register table
// at all (which lists bits 31:30 as "Reserved" — the Linux driver is
// the more trustworthy, proven-on-real-silicon source here). Separate
// from clk_axi4_usb/clk_apb_usb (REG_CLK_EN_1 bits 28/29, confirmed
// enabled by default in the datasheet — those feed the DWC2 core's
// own digital register access, already working; these three feed the
// analog PHY itself).
const uptr USB_CLK_PAGE      = 0x03002000;
// PAD_USB_VBUS_DET function-select register (PINMUX_BASE+0xac, same
// physical page SD_PINMUX_PAGE above also maps, for unrelated SDIO0
// pad registers — independent per-process page tables, no conflict).
// U-Boot's own board_init() calls pinmux_config(PINMUX_USB) for every
// boot, unconditionally (not gated behind USB gadget/host mode) —
// found by reading board.c3/cv180x_reg_fmux_gpio.h directly this
// round, after two straight real-hardware failures (USB3 drive, then
// a genuine USB2-only Xbox 360 controller) with no HPRT0.PRTCONNSTS
// reaction at all despite every DWC2-core and TOP-block VBUS/clock bit
// already being set — this driver had never touched pinmux at all
// until now.
const uptr USB_PINMUX_PAGE   = 0x03001000;
const uint IRQ_USB           = 30; // declared, deliberately NOT wired into plic_init() yet — see IRQ_SDHCI's own claim-storm lesson above; Phase 1 polls HPRT0 instead
const bool HAS_USB           = true;

// Ethernet MAC (Synopsys DesignWare/"stmmac" core, wrapped by the
// vendor's own "cvitek,ethernet" devicetree compatible string — the
// register layout itself is the standard, widely-documented DW MAC
//10/100/1000 Universal, confirmed via duo-buildroot-sdk's own U-Boot
// driver, drivers/net/designware.c/.h) — see user/ethd.c3 for the
// driver (Phase 1: MAC+PHY bring-up and MDIO link-status polling only,
// no packet TX/RX yet, mirroring user/usbd.c3's own Phase 1 scope).
// MAC registers at +0x0 (conf/framefilt/miiaddr/miidata/intreg/
// macaddr0hi/lo), DMA registers at +0x1000 (busmode/status/opmode/
// rxdesclistaddr/txdesclistaddr) — both comfortably within the first
// 8KB, this board's own devicetree node reserves a full 64KB window.
const uptr ETH_MMIO_BASE     = 0x04070000;
// The MAC's own DMA register block (Ethernet Phase 2: real packet
// TX/RX — user/net/dwmac.c3's own ETH_DMA_BASE) — a genuinely
// separate 4KB page from ETH_MMIO_BASE above, not covered by that
// mapping alone; found the hard way on real hardware (a store page
// fault at exactly 0x04071000, ethd's very first DMA_BUS_MODE soft-
// reset write) before this page was ever mapped.
const uptr ETH_DMA_PAGE      = 0x04071000;
// The embedded Ethernet PHY's own register block — genuinely separate
// hardware from the MAC above, SoC-internal (this board's physical
// RJ45 port, per the IO board's own pinout, is wired through this,
// not an external PHY chip). Real, complete init sequence sourced
// directly from U-Boot's own cv180x_ephy_id_init()
// (board/cvitek/cv180x/board.c) — called unconditionally in
// board_init() on real ASIC hardware, previously read this project's
// own USB Phase 1 research and dismissed as irrelevant then; it's
// actually the Ethernet PHY bring-up.
const uptr ETH_PHY_PAGE       = 0x03009000;
// clk_500m_eth0 (REG_CLK_EN_0 bit 25) / clk_axi4_eth0 (bit 26) — same
// physical clock-controller page USB_CLK_PAGE/SD_CLOCK_PAGE above
// also map, for their own unrelated bits — REG_CLK_EN_0 itself is a
// different register (+0x000) from REG_CLK_EN_1/_2 (+0x004/+0x008)
// those use. Marked CLK_IS_CRITICAL in the real Linux clock driver
// (drivers/clk/cvitek/clk-cv180x.c) — plausibly already enabled by an
// earlier boot stage, same as USB's own clk_axi4_usb/clk_apb_usb, but
// enabled defensively here anyway, same reasoning as every other
// "redoing it is safe either way" clock/reset write in this project.
const uptr ETH_CLK_PAGE       = 0x03002000;
// U-Boot's own board_init() calls cv180x_ephy_led_pinmux() together
// with cv180x_ephy_id_init() above, unconditionally, under the same
// #if defined(CONFIG_PHY_CVITEK) guard — this driver had only
// replicated the first of the two until a real hardware round showed
// every digital PHY-side fact healthy (PLL locked, BMCR clean, MDIO
// working, clocks enabled) with genuinely zero link ever detected by
// three independent peer devices. Despite its name ("LED PAD MUX"),
// this second function's own comments ("SD1_CLK selphy"/"SD1_CMD
// selphy") suggest it may be repurposing shared pins for the PHY
// itself, not just driving status LEDs — worth testing given nothing
// else has explained the symptom. Same physical page as
// USB_PINMUX_PAGE above (0x03001000, offsets +0x9c/+0xa0).
const uptr ETH_LED_PINMUX_PAGE = 0x03001000;
// A second, genuinely new page (0x05027000, offsets +0xb0/+0xb4) —
// never touched by anything else in this driver or user/usbd.c3.
const uptr ETH_SD1_SELPHY_PAGE = 0x05027000;
// The REAL, complete PHY analog bring-up — u-boot-2021.10/drivers/net/
// phy/cvitek.c's own cv182xa_ephy_init(), called from the actual PHY
// framework's own .config callback, not board.c's cv180x_ephy_id_init()
// (which this same file's own comments mark "/* do this in board.c */"
// for the specific subset it overlaps with — the two were always meant
// to run together, board.c first). Contains everything board.c's own
// sequence never touched: efuse-based analog trim (TX bias/echo/
// termination), MLT3 line-coding phase tables, link-pulse waveform
// shape, TP_IDLE, 10BaseT tables, LPF/HPF filter coefficients, and two
// registers never written at all before now — the real "start
// auto-negotiation" trigger (0x03009800=0x090e, distinct from board.c's
// own 0x0906) and a force-full-duplex bit (0x03009000). Found only by
// reading the actual PHY driver file (previously seen in an initial
// directory listing but never opened) after every fact checkable via
// MDIO/BMCR/PLL-lock came back healthy with genuinely zero link ever
// detected by three independent peer devices — exactly the signature
// analog-layer miscalibration (rather than a digital/control-plane
// gap) would produce.
//
// Efuse trim values live on two more, genuinely new pages.
const uptr ETH_EFUSE_PAGE_0 = 0x03050000; // EPHY_EFUSE_VALID_BIT_BASE @ +0x120
const uptr ETH_EFUSE_PAGE_1 = 0x03051000; // trim values @ +0x020, +0x024
const uint IRQ_ETH            = 31; // declared, not wired into plic_init() yet — Phase 1 polls PHY link status directly, same reasoning as IRQ_USB above
const bool HAS_ETH            = true;
const bool HAS_ETH_MAC        = true;
const bool HAS_VIRTIO_NET     = false;

// process.c3's setup_netd_mappings references these unconditionally,
// same reasoning as IRQ_VIRTIO_BLK's own "0 = not applicable" pattern
// above — this board has a real MAC, no virtio-mmio at all, never
// dereferenced since HAS_VIRTIO_NET is false here.
const uptr VIRTIO_NET_PADDR = 0;
const uint IRQ_VIRTIO_NET   = 0;

// fsd mounts EXT2TEST (ext2) as this board's own root — the real,
// physical start sector, confirmed via `sfdisk`/`lsblk` against the
// actual card. DUOBOOT (FAT32, sector 2048) deliberately isn't this
// value anymore: it stays physically on the SD card purely for the
// SoC's own boot ROM, which reads fip.bin from it via its own
// independent FAT32 walk before racccoon's kernel even starts —
// already fully decoupled from anything fsd does (confirmed via
// scripts/flash_duo.sh's own header comment) — racccoon's own fsd
// simply never mounts it. Matches this project's own Plan9-style
// reorganization (see docs/devlog.md): ext2 is root everywhere, FAT32
// is boot-partition-only everywhere, and this board only ever needed
// one fsd instance in the first place — HAS_SECOND_FS_PARTITION below
// reflects that now.
const uint FS_PARTITION_START_SECTOR = 2099200;

// No second fsd on this board — see FS_PARTITION_START_SECTOR's own
// comment. DUOBOOT stays on the card at sector 2048 for the boot ROM's
// own sake, but racccoon's own namespace has nothing bound to it.
const bool HAS_SECOND_FS_PARTITION = false;
const uint FS_PARTITION_2_START_SECTOR = 2048;

// Same register formulas as boards/qemu/board.c3 — see this file's own
// PLIC_BASE comment for why these are unverified rather than assumed
// safe.
fn void plic_init()
{
	uint* priority_virtio = (uint*)(PLIC_PRIORITY_BASE + 4 * IRQ_VIRTIO_BLK);
	mem::store(priority_virtio, 1u, 4, true);
	uint* enable = (uint*)PLIC_ENABLE_BASE;
	mem::store(enable, (1u << IRQ_VIRTIO_BLK), 4, true);

	// IRQ_SDHCI (36) falls outside the first 32 IRQs IRQ_VIRTIO_BLK's
	// own enable word covers — needs its own priority word (still inside
	// PLIC_PRIORITY_PAGE: priorities are one word per IRQ, and IRQ 36's
	// offset is well within the first page) and the *second* enable word
	// (IRQ/32 = 1, i.e. PLIC_ENABLE_BASE+4 — still inside PLIC_ENABLE_PAGE,
	// just 4 bytes further into the same page).
	uint* priority_sdhci = (uint*)(PLIC_PRIORITY_BASE + 4 * IRQ_SDHCI);
	mem::store(priority_sdhci, 1u, 4, true);

	// ISOLATION EXPERIMENT, temporary: every real-hardware test so far
	// has changed this enable-bit write and user/sdd.c3's own
	// SIGNAL_ENABLE/INT_ENABLE writes together, every single time — so
	// every failure so far is equally consistent with "the PLIC enable
	// bit itself is the problem" and "the device's own interrupt
	// generation is the problem." Two targeted fixes at the device-status
	// level (widening what gets cleared, and unconditionally completing
	// at the PLIC level) both left the storm's exact signature
	// unchanged (claim()=0 AND the raw pending bitmap=0 on every single
	// sample, forever), which argues against a device-status-clearing
	// explanation and toward something at the PLIC/enable level instead
	// — this line is the one thing that's never been isolated. Leaving
	// priority_sdhci's write in place (harmless alone: priority without
	// an enable bit can never deliver anything per PLIC semantics) and
	// skipping ONLY the enable-bit write, to see whether the storm
	// requires this bit being set at all, independent of whether the
	// device ever actually asserts. See docs/devlog.md for the full
	// elimination trail this session before this test.
	// uint* enable_word1 = (uint*)(PLIC_ENABLE_BASE + 4);
	// mem::store(enable_word1, (1u << (IRQ_SDHCI % 32)), 4, true);

	uint* threshold = (uint*)PLIC_THRESHOLD;
	mem::store(threshold, 0u, 4, true);
}

fn uint plic_claim()
{
	uint* claim = (uint*)PLIC_CLAIM;
	return mem::load(claim, 4, true);
}

fn void plic_complete(uint irq)
{
	uint* complete = (uint*)PLIC_CLAIM;
	mem::store(complete, irq, 4, true);
}

// Primary console path: same SBI-ecall mechanism as QEMU, unchanged.
// The boot chain research (BootROM -> FSBL -> OpenSBI -> payload,
// S-mode) makes this plausible, but it's genuinely unconfirmed whether
// the vendor's OpenSBI build actually wires its console extension to
// the board's actual debug UART the way QEMU's does.
//
// If a raw-MMIO fallback ever needs writing, target UART3
// (0x04170000, per the datasheet's per-UART base table — see
// docs/devlog.md), not UART0: the Duo's physically exposed debug
// header (pins 6/7) is wired to UART3, confirmed from Milk-V's own
// getting-started docs, not UART0 as earlier notes in this file
// assumed before that was checked.
//
// If Stage 2's real boot shows no console output at all (and the rest
// of the boot sequence otherwise looks alive — no immediate trap/panic),
// this is the fallback: a small raw MMIO 16550 driver talking directly
// to UART0's registers, bypassing SBI console calls entirely. Not
// written yet — no point building a driver for a problem that might
// not exist. When it is needed, it replaces just the two function
// bodies below; nothing else in the kernel changes, since callers only
// ever go through board::console_putchar/console_getchar.
fn int console_putchar(int ch)
{
	return sbi::__putchar(ch);
}

fn int console_getchar()
{
	return sbi::__getchar();
}
