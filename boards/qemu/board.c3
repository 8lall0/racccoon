module board;

import kernel;
import sbi;

// The `board` module is the one seam the rest of the kernel is allowed
// to reach through for anything platform-specific — memory map, PLIC base,
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

// QEMU's virt machine PLIC — a standard SiFive-style PLIC; the driver
// itself (register formulas, claim/complete, map_plic) is src/plic.c3.
// A board states only these three facts. Physical base of QEMU virt's PLIC.
const uptr PLIC_PHYS_BASE = 0x0c000000;

// PLIC_BASE is the *virtual* base the kernel dereferences the PLIC
// through (src/plic.c3's register constants derive from it), and the
// base of the three kernel-only pages map_plic maps into every
// process's page table.
//
// NOT identity-mapped to PLIC_PHYS_BASE: 0x0c000000 is only ~192 MiB
// up, right in the middle of the userspace virtual range (USER_BASE
// 0x1000000 + a per-process heap up to board::HEAP_MAX_BYTES). A
// process with a big enough SYS_MAP region — the on-device Go
// toolchain's ~448 MiB arena — grows straight into the identity-mapped
// PLIC pages and store-faults on a present-but-kernel-only PTE (found
// 2026-09-02, docs/devlog.md). The old eager SYS_MAP hid this by
// clobbering the PLIC PTE with a user page, which silently broke the
// kernel's own plic_claim() from that process's context. Aliasing the
// PLIC up here — well above any user allocation, well below the kernel
// identity map at 0x80200000 — keeps it clear of both. The Duo
// (boards/duo/board.c3) keeps identity mapping: its PLIC is already at
// 0x70000000, far above any 16 MiB Duo heap.
const uptr PLIC_BASE = 0x7a000000;

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

// virtio-mmio transport: QEMU virt's own is 8 fixed slots at
// 0x10001000-0x10008000 (0x1000 apart, IRQ = slot number) — confirmed via
// `-machine virt,dumpdtb=...` + dtc, same sourcing this project's own
// TIMEBASE_HZ below already used. Slot 0 (IRQ 1) is virtio-blk
// (scripts/launch64.sh), slot 1 virtio-net.
const uptr VIRTIO_BLK_PADDR = 0x10001000;
const uptr VIRTIO_NET_PADDR = 0x10002000;
const uint IRQ_VIRTIO_NET   = 2; // level (see DEVICES); netd acks the virtio ISR, then re-arms

// The devices the kernel hands to boot drivers (src/device.c3). QEMU virt
// has virtio-blk (diskd) and virtio-net (netd) and nothing else — no SD
// controller, no DWC2 USB, no real Ethernet MAC, no GPIO — so those
// drivers simply never spawn here. Nothing on this board is real DMA
// hardware (virtio is a software model), so every region is `cached`.
//
// virtio-blk: a virtqueue and a request buffer, in the order diskd's
// diskd_info() reads them, plus the fsd<->diskd payload arena
// (docs/ipc-rings.md). Edge/latched interrupt, acked via the virtio ISR
// register in diskd itself.
// virtio-net: RX and TX virtqueues, then the RX and TX packet buffers
// (NETD_RING_N 2 KiB slots each — user/net/netd.c3), in that order.
// Interrupt-driven: netd sleeps in await_any(AW_IRQ | AW_WAKE).
const Device[*] DEVICES = {
	{
		.name = "virtio-blk",
		.mmio = { VIRTIO_BLK_PADDR },
		.irq = IRQ_VIRTIO_BLK,
		.irq_level = false,
		.irq_armed = true,
		.dma = { { .pages = kernel::VIRTQ_PAGES, .cached = true },
		         { .pages = kernel::VIRTIO_BLK_REQ_PAGES, .cached = true } },
		.disk_arena = true,
	},
	{
		.name = "virtio-net",
		.mmio = { VIRTIO_NET_PADDR },
		.irq = IRQ_VIRTIO_NET,
		// Level, not edge like virtio-blk: the virtio-mmio line stays up
		// until the ISR is acked, and netd sleeps between interrupts
		// (diskd spins) — left enabled it re-fires on every return to user
		// mode until netd gets to run, starving everyone else. Masked on
		// each fire; netd re-arms it after acking.
		.irq_level = true,
		.irq_armed = true,
		.dma = { { .pages = kernel::VIRTQ_PAGES, .cached = true },
		         { .pages = kernel::VIRTQ_PAGES, .cached = true },
		         { .pages = 8, .cached = true },
		         { .pages = 8, .cached = true } },
	},
};

// Real, confirmed timebase-frequency, not guessed — extracted directly
// from this exact qemu-system-riscv64 binary via
// `-machine virt,dumpdtb=...` + `dtc` (same sourcing already used for
// the real timer primitive work, docs/devlog.md). See boards/duo/
// board.c3's matching comment for the Duo's own value and what this is
// used for kernel-side.
const ulong TIMEBASE_HZ = 10000000;

// Ceiling on the harts src/smp.c3's scaffold will try to bring up. QEMU
// virt exposes exactly as many as `-smp N` (default 1); the kernel
// probes via SBI HSM and silently skips hartids that don't answer, so
// this is just an upper bound — 8 covers any reasonable `-smp`. The
// secondaries only announce themselves and park (no SMP scheduler yet).
const uint SMP_MAX_HARTS = 8;

// The lowest hart racccoon may start (src/smp.c3's smp_start_secondaries
// starts SMP_MAX_HARTS of them from here). 0 here.
const uint SMP_HART_MIN = 0;

// Largest image SYS_EXEC will install (src/syscalls.c3's EXEC_MAX_IMAGE_SIZE
// and the staging arrays it sizes at this value, 12 bytes per page: 384 KiB
// of kernel .bss here). 128 MiB on QEMU — RAM is plentiful (1792 MiB
// free_ram). The LLVM tools set it: llc is 27.8 MiB, ld.lld 32.3 MiB, and
// c3c with LLVM + lld inside will be bigger (docs/manual.md §9.8). `go
// tool compile` is ~23 MiB, ordinary Go programs 1.5-2 MiB. The Duo keeps
// 4 MiB (boards/duo/board.c3) — 64 MiB DRAM.
const EXEC_MAX_IMAGE_SIZE = 134217728;

// Per-process SYS_MAP ceiling (src/syscalls.c3's HEAP_MAX_BYTES). 512 MiB
// on QEMU — the free_ram window is 1792 MiB (src/kernel.ld, -m 2G), and
// a Go process reserves a 64/448 MiB heap arena (lazy since 2026-09-02,
// docs/devlog.md) with room for the GC to cycle. The Duo keeps 16 MiB
// (boards/duo/board.c3) — 64 MiB DRAM total.
const uptr HEAP_MAX_BYTES = 1536 * 1024 * 1024;

// Console input: 0 = read it through the SBI legacy getchar (sbi::__getchar),
// which works on QEMU and the Duo. A board whose firmware mangles that call
// sets this to the UART's page and does the read itself in console_getchar()
// (see boards/opi-rv/board.c3); process.c3's map_console_mmio then maps it
// kernel-only into every page table.
const uptr CONSOLE_MMIO_PAGE = 0;
const uptr CONSOLE_MMIO_PHYS = 0; // physical page behind CONSOLE_MMIO_PAGE (unused at 0)

// No hole in the user heap's address range on this board (see
// boards/opi-rv/board.c3's USER_VA_HOLE_START).
const uptr USER_VA_HOLE_START = 0;
const uptr USER_VA_HOLE_END   = 0;

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
