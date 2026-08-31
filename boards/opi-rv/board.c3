module board;

import kernel;
import sbi;

// Orange Pi RV (StarFive JH7110) implementation of the `board` contract.
// See boards/qemu/board.c3's header for what this module is; see
// docs/opi-rv-plan.md for the staged bring-up plan and the sourcing
// behind every value below.
//
// STATUS: scaffold. This compiles and is shaped to boot to the embedded
// shell with NO filesystem (HAS_BLOCK_DEVICE = false), the same first
// milestone the Milk-V Duo port started from. Every peripheral flag is
// false; the addresses that are filled in are sourced from the JH7110
// devicetree / VisionFive 2 U-Boot (the Orange Pi RV shares the SoC),
// the ones left at 0 are honest "not sourced / not needed yet" stubs
// exactly as boards/qemu/board.c3 does for its absent peripherals.
//
// The JH7110 differs from QEMU virt in three ways that matter here:
//   1. DRAM base is 0x40000000, not 0x80000000 (see kernel.ld).
//   2. Hart 0 is a SiFive S7 "monitor" core with only an M-mode PLIC
//      context; the four U74 application cores are harts 1..4. So the
//      S-mode PLIC context of the hart racccoon actually runs on is
//      NOT 1 (see PLIC_S_CONTEXT).
//   3. timebase-frequency is 4 MHz (see TIMEBASE_HZ).
// The PLIC register block itself is a stock SiFive design at the same
// 0x0c000000 QEMU virt uses, so the offset formulas are unchanged.

// JH7110 U74 core-complex PLIC. "sifive,plic-1.0.0" / "riscv,plic0",
// reg = <0x0 0x0c000000 0x0 0x04000000>, riscv,ndev = 136 (JH7110
// devicetree, jh7110.dtsi). Stock SiFive layout — identical register
// math to boards/qemu/board.c3.
const uptr PLIC_BASE = 0x0c000000;

// SiFive U74 is a plain RV64GC core — no T-Head MAEE PTE-attribute
// quirk (that is a C906-only thing, see boards/duo/board.c3). Device
// MMIO works with ordinary PTEs, same as QEMU's generic core: the
// JH7110's physical memory map fixes 0x00000000-0x40000000 as
// strongly-ordered I/O in hardware, so no per-page attribute is needed
// to keep MMIO ordered.
const ulong PTE_EXTRA_BITS  = 0;
const ulong PTE_DEVICE_BITS = 0;

// No virtio-mmio block device on real JH7110 hardware. 0 = "not
// applicable", the same sentinel boards/duo/board.c3 uses — it can
// never spuriously match plic_claim()'s "nothing pending" return.
const uint IRQ_VIRTIO_BLK = 0;

// PLIC context = (hart, privilege) pair the interrupt targets. The
// JH7110 devicetree's plic `interrupts-extended` enumerates them in
// this order:
//   context 0 : hart 0 (S7)  M-mode          <&cpu0_intc 0xffffffff>
//   context 1 : hart 1 (U74) M-mode          <&cpu1_intc 11>
//   context 2 : hart 1 (U74) S-mode          <&cpu1_intc 9>
//   context 3 : hart 2 (U74) M-mode
//   context 4 : hart 2 (U74) S-mode          ... etc.
// i.e. for U74 hart h (h >= 1) the S-mode context is 2*h. racccoon is
// single-hart and does not read its own hartid — it runs on whichever
// hart OpenSBI/U-Boot hands it. On VisionFive 2 that is hart 1, giving
// S-context 2. If the Orange Pi RV's firmware starts the S-mode payload
// on a different U74, this must become 2*that-hart.
//
// THIS IS THE #1 THING TO CHECK ON FIRST HARDWARE BOOT. If interrupts
// never fire (or plic_claim() always returns 0 while sip.SEIP stays
// asserted), the running hart's S-context does not match this value —
// fix it here, nothing else in the kernel changes. The `board` seam
// exists for exactly this.
const uptr PLIC_S_CONTEXT = 2;

const uptr PLIC_PRIORITY_BASE = PLIC_BASE;                                     // + 4*irq
const uptr PLIC_ENABLE_BASE   = PLIC_BASE + 0x2000 + PLIC_S_CONTEXT * 0x80;     // + (irq/32)*4, bit irq%32
const uptr PLIC_THRESHOLD     = PLIC_BASE + 0x200000 + PLIC_S_CONTEXT * 0x1000;
const uptr PLIC_CLAIM         = PLIC_BASE + 0x200004 + PLIC_S_CONTEXT * 0x1000;

const uptr PLIC_PRIORITY_PAGE = PLIC_PRIORITY_BASE & (uptr)~(kernel::PAGE_SIZE - 1);
const uptr PLIC_ENABLE_PAGE   = PLIC_ENABLE_BASE & (uptr)~(kernel::PAGE_SIZE - 1);
const uptr PLIC_CLAIM_PAGE    = PLIC_CLAIM & (uptr)~(kernel::PAGE_SIZE - 1);

// --- Block storage -----------------------------------------------------
// The JH7110 has no virtio-mmio; its storage is a Synopsys DesignWare
// MSHC ("snps,dw-mshc" / "starfive,jh7110-mmc", sdio0 @ 0x16010000,
// sdio1 @ 0x16020000) — a DIFFERENT controller from the Duo's Cvitek
// SDHCI (user/block/sdhci.c3), so it needs its own driver. Milestone 3
// in docs/opi-rv-plan.md. Until then this board boots with no fs, the
// same way the Duo port's Stage 1 did: HAS_BLOCK_DEVICE false, diskd /
// fsd never spawn, the shell's file commands fail cleanly.
const bool HAS_BLOCK_DEVICE = false;
const bool HAS_SD_BLOCK     = false;
const bool HAS_VIRTIO_BLOCK = false;

// Not applicable until the dw-mshc driver lands (see above). 0 stubs,
// same convention as boards/qemu/board.c3's absent SD hardware —
// process.c3's setup_sdd_mappings references these unconditionally but
// never runs them while HAS_SD_BLOCK is false.
const uptr SD_MMIO_BASE   = 0;
const uptr SD_TOP_PAGE    = 0;
const uptr SD_PINMUX_PAGE = 0;
const uptr SD_CLOCK_PAGE  = 0;
const uint IRQ_SDHCI      = 0;

// fsd's per-board partition offset (learned via syscall, see fsd.c3).
// Meaningless while HAS_BLOCK_DEVICE is false; the real value comes from
// `sfdisk`/`lsblk` against the actual Orange Pi RV SD card once the
// dw-mshc driver can read it.
const uint FS_PARTITION_START_SECTOR = 0;

const bool HAS_SECOND_FS_PARTITION  = false;
const uint FS_PARTITION_2_START_SECTOR = 0;

// --- USB -------------------------------------------------------------
// JH7110 USB is a Cadence USBSS-DRD controller ("cdns,usb3" @
// 0x10100000) — not the Duo's DWC2. Needs its own driver; deferred well
// past this scaffold. 0 stubs, same as boards/qemu/board.c3.
const uptr USB_MMIO_BASE     = 0;
const uptr USB_TOP_CTRL_PAGE = 0;
const uptr USB_TOP_RST_PAGE  = 0;
const uptr USB_CLK_PAGE      = 0;
const uptr USB_PINMUX_PAGE   = 0;
const uint IRQ_USB           = 0;
const bool HAS_USB           = false;

// --- GPIO -----------------------------------------------------------
// JH7110 pin control is "starfive,jh7110-sys-pinctrl" @ 0x13040000 — a
// different block from the Duo's Synopsys DW-APB GPIO. Deferred. 0
// stubs, same as boards/qemu/board.c3.
const uptr GPIO_BANK_A_BASE = 0;
const uptr GPIO_BANK_C_BASE = 0;
const uptr GPIO_PINMUX_PAGE = 0;
const bool HAS_GPIO = false;

// --- Ethernet ------------------------------------------------------
// JH7110 has two GMACs ("starfive,jh7110-dwmac" wrapping a Synopsys
// DWMAC 5.20, gmac0 @ 0x16030000, gmac1 @ 0x16040000). The core is the
// same DesignWare MAC family user/net/dwmac.c3 already targets for the
// Duo, so that driver is a partial head start — but the StarFive glue
// (clock/reset/PHY-mode via syscon) and the external PHY (the Orange Pi
// RV uses a real PHY chip on the RJ45, not a SoC-internal one like the
// Duo) are new. Deferred. 0 stubs, same as boards/qemu/board.c3's
// absent MAC.
const uptr VIRTIO_NET_PADDR  = 0;
const uint IRQ_VIRTIO_NET    = 0;
const bool HAS_ETH           = false;
const bool HAS_ETH_MAC       = false;
const bool HAS_VIRTIO_NET    = false;

const uptr ETH_MMIO_BASE       = 0;
const uptr ETH_DMA_PAGE        = 0;
const uptr ETH_PHY_PAGE        = 0;
const uptr ETH_CLK_PAGE        = 0;
const uptr ETH_LED_PINMUX_PAGE = 0;
const uptr ETH_SD1_SELPHY_PAGE = 0;
const uptr ETH_EFUSE_PAGE_0    = 0;
const uptr ETH_EFUSE_PAGE_1    = 0;
const uint IRQ_ETH             = 0;

// rdtime()'s tick rate. JH7110 devicetree: `cpus { timebase-frequency =
// <4000000>; }` — 4 MHz, well-known for this SoC (VisionFive 2, Star64,
// Milk-V Mars all share it). Used kernel-side to arm the SBI timer (see
// entry.c3's arm_timer) and by fsd/sdd via the SYS_TIMEBASE syscall.
const ulong TIMEBASE_HZ = 4000000;

// Only the block-device IRQ would ever be armed here, and this board
// has no block device yet — so this is the QEMU-shaped minimum: set a
// threshold of 0 and nothing else. When the dw-mshc / dwmac drivers
// land they add their own priority+enable writes here, following
// boards/duo/board.c3's INTERRUPT_DRIVEN_* pattern.
fn void plic_init()
{
	uint* threshold = (uint*)PLIC_THRESHOLD;
	mem::store(threshold, 0u, 4, true);
}

fn void plic_set_enabled(uint irq, bool on)
{
	uint* word = (uint*)(PLIC_ENABLE_BASE + (uptr)((irq / 32) * 4));
	uint cur = mem::load(word, 4, true);
	uint bit = 1u << (irq % 32);
	mem::store(word, on ? (cur | bit) : (cur & ~bit), 4, true);
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

// JH7110's OpenSBI (fw_dynamic, built by the vendor / mainline) wires
// the SBI console (DBCN + the legacy putchar/getchar) to UART0 @
// 0x10000000 — the 3-pin debug header on VisionFive 2, and the debug
// serial on the Orange Pi RV. Same ecall path as QEMU and the Duo.
//
// Raw-MMIO fallback if the SBI console turns out not to be wired: UART0
// is a stock 8250/DW-APB (reg-shift 2, reg-io-width 4) at 0x10000000,
// same shape a small 16550 driver would target — replace just these two
// function bodies, nothing else in the kernel changes. Not written
// until proven necessary (same stance as boards/duo/board.c3).
fn int console_putchar(int ch)
{
	return sbi::__putchar(ch);
}

fn int console_getchar()
{
	return sbi::__getchar();
}
