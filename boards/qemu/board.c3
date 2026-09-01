module board;

import kernel;
import sbi;

// The `board` module is the one seam the rest of the kernel is allowed
// to reach through for anything platform-specific — memory map, PLIC,
// console. Adding a new target means adding a new `boards/<name>/`
// directory implementing this same contract, not re-touching
// entry.c3/process.c3/kernel.c3 again. See docs/devlog.md for why this
// exists (Milk-V Duo hardware bring-up) and
// ~/.claude/plans/giggly-prancing-iverson.md for the port plan.
//
// This file is QEMU's implementation — a straight refactor of what
// used to live directly in src/plic.c3/src/kernel/sbi.c3, not new
// logic. It should produce an identical boot to what existed before
// this refactor; that's the regression check for the abstraction
// itself.

// QEMU's virt machine PLIC. Register layout matches the standard
// SiFive-style PLIC used across RISC-V platforms (same one xv6-riscv
// targets): a small handful of scattered pages, not one contiguous
// block, which is why the PLIC_*_PAGE constants below are three
// separate pages, not a range. Addresses are uptr (pointer-sized, not
// a fixed 32-bit uint); the *registers themselves* stay 32-bit values
// (irq numbers, priority, enable bitmask) — PLIC register width is
// fixed by the hardware spec, independent of hart XLEN.
const uptr PLIC_BASE = 0x0c000000;

// No T-Head MAEE-style PTE attribute quirk on QEMU's generic SiFive-style
// core — see boards/duo/board.c3's PTE_EXTRA_BITS for what this is and
// why it exists at all.
const ulong PTE_EXTRA_BITS = 0;

// No MAEE on QEMU's generic core — device MMIO just works with plain
// PTEs. See boards/duo/board.c3's PTE_DEVICE_BITS.
const ulong PTE_DEVICE_BITS = 0;

// virtio-mmio devices on QEMU's virt board get IRQ N for slot N; we only
// ever attach one device (bus=virtio-mmio-bus.0, slot 0), so IRQ 1.
const uint IRQ_VIRTIO_BLK = 1;

// Context = (hart, privilege mode) pair the PLIC targets. QEMU virt wires
// context 2*hart for M-mode and 2*hart+1 for S-mode; single-hart S-mode
// kernel, so context 1.
const uptr PLIC_S_CONTEXT = 1;

const uptr PLIC_PRIORITY_BASE = PLIC_BASE;                                    // + 4*irq
const uptr PLIC_ENABLE_BASE   = PLIC_BASE + 0x2000 + PLIC_S_CONTEXT * 0x80;    // + (irq/32)*4, bit irq%32
const uptr PLIC_THRESHOLD     = PLIC_BASE + 0x200000 + PLIC_S_CONTEXT * 0x1000;
const uptr PLIC_CLAIM         = PLIC_BASE + 0x200004 + PLIC_S_CONTEXT * 0x1000;

// Page-aligned bases of the distinct pages the registers above fall in
// (PLIC_ENABLE_BASE and PLIC_THRESHOLD/PLIC_CLAIM aren't page-aligned
// themselves), for process.c3's create_process to map into every
// process's page table.
const uptr PLIC_PRIORITY_PAGE = PLIC_PRIORITY_BASE & (uptr)~(kernel::PAGE_SIZE - 1);
const uptr PLIC_ENABLE_PAGE   = PLIC_ENABLE_BASE & (uptr)~(kernel::PAGE_SIZE - 1);
const uptr PLIC_CLAIM_PAGE    = PLIC_CLAIM & (uptr)~(kernel::PAGE_SIZE - 1);

// QEMU's virt board always has virtio-blk attached (see scripts/launch64.sh) —
// diskd/fsd get spawned and the shell has real file access.
const bool HAS_BLOCK_DEVICE = true;

// Which driver process/kernel mapping helper kernel.c3 should use for the
// block device HAS_BLOCK_DEVICE above promises — QEMU has virtio-mmio, not
// real SD hardware. See boards/duo/board.c3 for the mirror image (SD, no
// virtio-mmio).
const bool HAS_SD_BLOCK     = false;
const bool HAS_VIRTIO_BLOCK = true;

// fsd.c3 (see its own header comment) adds this to every logical sector
// number before touching the disk — see boards/duo/board.c3's matching
// comment. QEMU's own default test image (scripts/build.sh's disk.img)
// is formatted whole-disk (no MBR/partition table, the simplest thing
// mkfs.vfat can produce), so 0. Two other, separate test images exist
// for other purposes: disk_ext2.img (whole-disk ext2, scripts/
// launch64_ext2.sh) and disk_dual.img (both partitions at once,
// scripts/launch64_dual.sh, matching the two sector numbers below) —
// neither is the default `disk.img` this constant describes.
const uint FS_PARTITION_START_SECTOR = 0;

// disk_dual.img's own layout (scripts/build.sh): FAT32 at sector 0 (same
// as the default disk.img above — FS_PARTITION_START_SECTOR is one
// constant shared by both images) and ext2 at sector 18432. Confirmed by
// actually building the image and booting it, not assumed — an earlier
// attempt put FAT32 at sector 2048 instead and the first fsd correctly,
// harmlessly found nothing there (see FS_PARTITION_START_SECTOR's own
// value, unaffected by this constant). Only meaningful when booting
// against that specific image; booting the default `disk.img` (a single,
// whole-disk FAT32 volume, no second partition to find at all) with this
// flag on just means the second fsd instance finds nothing and stays
// inactive — see kernel.c3's own spawn code and docs/devlog.md for why
// that's an accepted, harmless side effect, not a bug.
const bool HAS_SECOND_FS_PARTITION = true;
const uint FS_PARTITION_2_START_SECTOR = 18432;

// process.c3's setup_sdd_mappings references these unconditionally (one
// kernel source tree, compiled separately per board — see this file's
// header comment), even though QEMU never actually calls it
// (HAS_SD_BLOCK is false here). No real SD hardware on QEMU, so no real
// addresses to source — 0 is fine, same reasoning as IRQ_VIRTIO_BLK's "0
// = not applicable on this board" convention in boards/duo/board.c3.
const uptr SD_MMIO_BASE   = 0;
const uptr SD_TOP_PAGE    = 0;
const uptr SD_PINMUX_PAGE = 0;
const uptr SD_CLOCK_PAGE  = 0;

// entry.c3's handle_trap references board::IRQ_SDHCI unconditionally,
// same reasoning as the SD_* constants above — 0 is this PLIC's own
// "nothing pending" sentinel, so it can never spuriously match a real
// claimed IRQ, matching IRQ_VIRTIO_BLK's own "0 = not applicable"
// convention on the Duo.
const uint IRQ_SDHCI = 0;

// process.c3's setup_usbd_mappings references these unconditionally,
// same reasoning as the SD_* constants above — QEMU's riscv64 virt
// machine has no DWC2 equivalent at all (its own USB path, if any, is
// PCIe+XHCI — a completely different controller, later phase), so 0 is
// fine, never dereferenced since HAS_USB is false here.
const uptr USB_MMIO_BASE     = 0;
const uptr USB_TOP_CTRL_PAGE = 0;
const uptr USB_TOP_RST_PAGE  = 0;
const uptr USB_CLK_PAGE      = 0;
const uptr USB_PINMUX_PAGE   = 0;
const uint IRQ_USB           = 0;
const bool HAS_USB           = false;

// GPIO — no meaningful QEMU virt equivalent for "toggle a real pin";
// same Duo-only reasoning as HAS_USB above. process.c3's
// setup_gpiod_mappings references GPIO_BANK_C_BASE/GPIO_PINMUX_PAGE
// unconditionally (same "0 = not applicable, never dereferenced since
// HAS_GPIO is false" pattern as USB_MMIO_BASE etc. above), and
// kernel.c3 still links gpiod.bin.o in on this board even though
// HAS_GPIO gates it from ever actually spawning — see
// scripts/build_duo.sh's own comment on diskd/sdd for why.
const uptr GPIO_BANK_A_BASE = 0;
const uptr GPIO_BANK_C_BASE = 0;
const uptr GPIO_PINMUX_PAGE = 0;
const bool HAS_GPIO = false;

// Ethernet — QEMU's virt board has no real DesignWare MAC equivalent,
// but unlike USB it DOES have a genuine, real network path via
// virtio-net on the same virtio-mmio bus virtio-blk already uses. This
// board gets its own driver, user/netd.c3 (Phase 1: virtio-net device
// bring-up and link-status query only, mirroring user/ethd.c3's own
// Phase 1 scope on the Duo — see boards/duo/board.c3's own comment) —
// see HAS_ETH_MAC/HAS_VIRTIO_NET below for which driver kernel.c3
// spawns on which board, same shape as HAS_SD_BLOCK/HAS_VIRTIO_BLOCK
// above.
//
// QEMU virt's own virtio-mmio transport is 8 fixed slots at
// 0x10001000-0x10008000 (0x1000 apart, IRQ = slot number) — confirmed
// via `-machine virt,dumpdtb=...` + dtc, same sourcing this project's
// own TIMEBASE_HZ above already used. Slot 0 (0x10001000, IRQ 1) is
// virtio-blk (scripts/launch64.sh); slot 1 here for virtio-net.
const uptr VIRTIO_NET_PADDR  = 0x10002000;
const uint IRQ_VIRTIO_NET    = 2;
const bool HAS_ETH           = true;
const bool HAS_ETH_MAC       = false;
const bool HAS_VIRTIO_NET    = true;

// process.c3's setup_ethd_mappings references these unconditionally,
// same reasoning as the SD_*/USB_* constants above — QEMU has no real
// DesignWare MAC or embedded PHY at all, never dereferenced since
// HAS_ETH_MAC is false here.
const uptr ETH_MMIO_BASE = 0;
const uptr ETH_DMA_PAGE  = 0;
const uptr ETH_PHY_PAGE  = 0;
const uptr ETH_CLK_PAGE  = 0;
const uptr ETH_LED_PINMUX_PAGE = 0;
const uptr ETH_SD1_SELPHY_PAGE = 0;
const uptr ETH_EFUSE_PAGE_0 = 0;
const uptr ETH_EFUSE_PAGE_1 = 0;
const uint IRQ_ETH       = 0;

// Real, confirmed timebase-frequency, not guessed — extracted directly
// from this exact qemu-system-riscv64 binary via
// `-machine virt,dumpdtb=...` + `dtc` (same sourcing already used for
// the real timer primitive work, docs/devlog.md). See boards/duo/
// board.c3's matching comment for the Duo's own value and what this is
// used for kernel-side.
const ulong TIMEBASE_HZ = 10000000;

// Largest image SYS_EXEC will install (src/entry.c3's EXEC_MAX_IMAGE_SIZE
// and the staging arrays it sizes). 4 MiB on QEMU — RAM is plentiful and
// this unblocks the Go port (a GOOS=tamago static binary is 1-4 MiB —
// docs/go-port-plan.md); the C toolchain (~640 KiB TinyCC) fits either
// way. The Duo keeps 1 MiB (boards/duo/board.c3) — 64 MiB, no Go.
const EXEC_MAX_IMAGE_SIZE = 4194304;

// Per-process SYS_MAP ceiling (src/entry.c3's HEAP_MAX_BYTES). 64 MiB on
// QEMU — the free_ram window is 112 MiB (src/kernel.ld), and a Go
// process eagerly SYS_MAPs a ~48 MiB heap arena (docs/go-port-plan.md).
// The Duo keeps 16 MiB (boards/duo/board.c3) — 64 MiB DRAM total.
const uptr HEAP_MAX_BYTES = 64 * 1024 * 1024;

fn void plic_init()
{
	// Priority must be > 0 for the PLIC to ever forward the interrupt at
	// all (0 means "never interrupt", regardless of enable bits).
	uint* priority = (uint*)(PLIC_PRIORITY_BASE + 4 * IRQ_VIRTIO_BLK);
	mem::store(priority, 1u, 4, true);

	// Enable this IRQ for our S-mode context.
	uint* enable = (uint*)PLIC_ENABLE_BASE;
	mem::store(enable, (1u << IRQ_VIRTIO_BLK), 4, true);

	// Threshold 0: forward any interrupt with priority > 0 (i.e. all of
	// them, since we only ever set priority 1).
	uint* threshold = (uint*)PLIC_THRESHOLD;
	mem::store(threshold, 0u, 4, true);
}

// Claiming an IRQ both tells us which one fired and acknowledges it to
// the PLIC (clears it from pending) — returns 0 if nothing is actually
// pending (spurious claim).
fn uint plic_claim()
{
	uint* claim = (uint*)PLIC_CLAIM;
	return mem::load(claim, 4, true);
}

// Must be called after handling an IRQ obtained via plic_claim(), or the
// PLIC will never forward that source again.
fn void plic_complete(uint irq)
{
	uint* complete = (uint*)PLIC_CLAIM;
	mem::store(complete, irq, 4, true);
}

// See boards/duo/board.c3's plic_set_enabled — kept here for symbol
// parity (shared kernel code calls it). Never exercised on QEMU
// (HAS_USB false, usbd never spawned).
fn void plic_set_enabled(uint irq, bool on)
{
	uint* word = (uint*)(PLIC_ENABLE_BASE + (uptr)((irq / 32) * 4));
	uint cur = mem::load(word, 4, true);
	uint bit = 1u << (irq % 32);
	mem::store(word, on ? (cur | bit) : (cur & ~bit), 4, true);
}

// QEMU's OpenSBI wires its console extension straight to the virt
// board's UART — the ecall round trip already proven working since the
// very first RV32 slice of this project.
fn int console_putchar(int ch)
{
	return sbi::__putchar(ch);
}

fn int console_getchar()
{
	return sbi::__getchar();
}
