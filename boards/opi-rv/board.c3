module board;

import kernel;
import sbi;

// Orange Pi RV (StarFive JH7110) implementation of the `board` contract.
// See boards/qemu/board.c3's header for what this module is; see
// docs/opi-rv-plan.md for the staged bring-up plan and the sourcing
// behind every value below.
//
// STATUS: scaffold. This compiles and is shaped to boot to the embedded
// shell with NO filesystem (an empty DEVICES table), the same first
// milestone the Milk-V Duo port started from. No peripheral is declared
// yet; the addresses that are filled in are sourced from the JH7110
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

// PLIC_BASE above IS the physical address (0x0c000000, well below DRAM's
// 0x40000000 base, so no QEMU-style aliasing is needed — see
// boards/qemu/board.c3's PLIC_PHYS_BASE comment for the case where it
// would collide with the free_ram pool). Identity-mapped, same stance
// as boards/duo/board.c3.
const uptr PLIC_PHYS_BASE = PLIC_BASE;
const uptr PLIC_PRIORITY_PHYS_PAGE = PLIC_PRIORITY_PAGE;
const uptr PLIC_ENABLE_PHYS_PAGE   = PLIC_ENABLE_PAGE;
const uptr PLIC_CLAIM_PHYS_PAGE    = PLIC_CLAIM_PAGE;

// Ceiling on the harts src/smp.c3's scaffold will try to bring up. Kept
// at 1 for Stage 1 first-boot bring-up: racccoon runs on whichever
// single U74 OpenSBI hands it, and SMP is an explicit non-goal until
// this port itself is booted and verified (docs/opi-rv-plan.md's
// "Non-goals"). Raise when resuming SMP Stage C3 on this board — see
// the smp memory note (racccoon_smp) — not before.
const uint SMP_MAX_HARTS = 1;

// --- Devices ------------------------------------------------------------
// No boot-driver hardware is declared yet — DEVICES below is empty, so
// sdd/diskd/fsd, usbd, ethd/netd and gpiod never spawn: this board boots
// with no fs, the same way the Duo port's Stage 1 did, and the shell's
// file commands fail cleanly. As each driver lands it gets one entry in
// DEVICES (src/device.c3) — its MMIO pages, PLIC source, DMA regions —
// and nothing in the kernel changes. What the entries will describe:
//
//  "sd"   Synopsys DesignWare MSHC ("snps,dw-mshc" / "starfive,jh7110-mmc",
//         mmc0/sdio0 @ 0x16010000 = the AP6256 Wi-Fi's SDIO; mmc1/sdio1 @
//         0x16020000 = THE MICROSD SLOT, PLIC IRQ 75 — see docs/opi-rv-plan.md) — a DIFFERENT controller
//         from the Duo's Cvitek SDHCI (user/block/sdhci.c3), so it needs its
//         own driver (Milestone 3), plus the syscrg clock/reset, sysreg
//         syscon and pinmux pages it depends on.
//  "usb"  Cadence USBSS-DRD ("cdns,usb3" @ 0x10100000) — not the Duo's DWC2.
//  "gpio" "starfive,jh7110-sys-pinctrl" @ 0x13040000 — not the Duo's
//         Synopsys DW-APB GPIO.
//  "eth-mac" two GMACs ("starfive,jh7110-dwmac", a Synopsys DWMAC 5.20,
//         gmac0 @ 0x16030000, gmac1 @ 0x16040000). The core is the same
//         DesignWare MAC family user/net/dwmac.c3 already targets, so that
//         driver is a partial head start — but the StarFive glue
//         (clock/reset/PHY-mode via syscon) and the external RJ45 PHY chip
//         are new.
const Device[] DEVICES = {};

// fsd's per-board partition offset (learned via syscall, see fsd.c3).
// Meaningless until an "sd" device exists; the real value comes from
// `sfdisk`/`lsblk` against the actual Orange Pi RV SD card once the
// dw-mshc driver can read it.
const uint FS_PARTITION_START_SECTOR = 0;

const bool HAS_SECOND_FS_PARTITION  = false;
const uint FS_PARTITION_2_START_SECTOR = 0;

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
// Console output goes through the SBI (sbi::__putchar — works fine here).
// Console INPUT does not: see CONSOLE_MMIO_PAGE above and console_getchar()
// below, which read UART0's registers directly.
fn int console_putchar(int ch)
{
	return sbi::__putchar(ch);
}

// Non-blocking, like the legacy call it replaces: the next received byte, or
// -1 if none is waiting. LSR (offset 0x14 = reg 5 << 2) bit 0 is "data
// ready"; reading RBR (offset 0) pops it. 32-bit accesses (reg-io-width 4).
// The firmware keeps using the same UART for TX (SBI putchar) — RX is ours.
fn int console_getchar()
{
	uint lsr = mem::load((uint*)(CONSOLE_MMIO_PAGE + 0x14), 4, true);
	if ((lsr & 1) == 0) { return -1; }
	return (int)(mem::load((uint*)CONSOLE_MMIO_PAGE, 4, true) & 0xFF);
}

// Largest image SYS_EXEC will install (src/entry.c3's EXEC_MAX_IMAGE_SIZE)
// and the per-process SYS_MAP ceiling (src/entry.c3's HEAP_MAX_BYTES).
// Sized like boards/duo/board.c3, not boards/qemu/board.c3: the Stage 0
// kernel.ld window here is a flat 64 MiB free_ram pool (same scale as
// the Duo's 64 MiB total DRAM), not QEMU's 1792 MiB. Raise both once
// kernel.ld's window is widened (docs/opi-rv-plan.md open question #4).
const EXEC_MAX_IMAGE_SIZE = 1048576;
const uptr HEAP_MAX_BYTES = 16 * 1024 * 1024;

// Console input is read straight from UART0's registers, NOT through the SBI
// legacy getchar: this board's OpenSBI (v1.2) logs `sbi_ecall_handler: Invalid
// error N for ext=0x2 func=0x0` for every real keystroke and returns "no
// char" instead — the legacy call hands the character back in a0, which that
// version's return-value check treats as an error and clamps (newer OpenSBI
// exempts SBI_EXT_0_1_CONSOLE_GETCHAR). Output (SBI putchar) is unaffected.
// UART0 is a Synopsys DW-APB 8250-compatible at 0x10000000, reg-shift 2,
// reg-io-width 4 (jh7110.dtsi `serial@10000000`); process.c3's
// map_console_mmio maps this page kernel-only into every page table.
const uptr CONSOLE_MMIO_PAGE = 0x10000000;
