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
// Physical base of QEMU virt's PLIC.
const uptr PLIC_PHYS_BASE = 0x0c000000;

// PLIC_BASE is the *virtual* base the kernel dereferences the PLIC
// through (all the PLIC_* register constants below derive from it), and
// the base of the three kernel-only pages create_process maps into
// every process's page table.
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

const uptr PLIC_PRIORITY_BASE = PLIC_BASE;                                    // + 4*irq
const uptr PLIC_ENABLE_BASE   = PLIC_BASE + 0x2000 + PLIC_S_CONTEXT * 0x80;    // + (irq/32)*4, bit irq%32
const uptr PLIC_THRESHOLD     = PLIC_BASE + 0x200000 + PLIC_S_CONTEXT * 0x1000;
const uptr PLIC_CLAIM         = PLIC_BASE + 0x200004 + PLIC_S_CONTEXT * 0x1000;

// Page-aligned bases of the distinct pages the registers above fall in
// (PLIC_ENABLE_BASE and PLIC_THRESHOLD/PLIC_CLAIM aren't page-aligned
// themselves), for process.c3's create_process to map into every
// process's page table — _PAGE is the virtual page it maps at,
// _PHYS_PAGE the physical PLIC page it points to. (On the Duo the two
// are equal; here they differ — see PLIC_BASE's comment.)
const uptr PLIC_PRIORITY_PAGE = PLIC_PRIORITY_BASE & (uptr)~(kernel::PAGE_SIZE - 1);
const uptr PLIC_ENABLE_PAGE   = PLIC_ENABLE_BASE & (uptr)~(kernel::PAGE_SIZE - 1);
const uptr PLIC_CLAIM_PAGE    = PLIC_CLAIM & (uptr)~(kernel::PAGE_SIZE - 1);
const uptr PLIC_PRIORITY_PHYS_PAGE = (PLIC_PRIORITY_PAGE - PLIC_BASE) + PLIC_PHYS_BASE;
const uptr PLIC_ENABLE_PHYS_PAGE   = (PLIC_ENABLE_PAGE - PLIC_BASE) + PLIC_PHYS_BASE;
const uptr PLIC_CLAIM_PHYS_PAGE    = (PLIC_CLAIM_PAGE - PLIC_BASE) + PLIC_PHYS_BASE;

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
const uint IRQ_VIRTIO_NET   = 2; // declared, not routed: netd is fully poll-driven

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
// virtio-net: RX and TX virtqueues plus a packet-buffer page (Ethernet
// Phase 2 — user/net/netd.c3's own fixed offsets), in netd_info()'s order.
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
		.dma = { { .pages = kernel::VIRTQ_PAGES, .cached = true },
		         { .pages = kernel::VIRTQ_PAGES, .cached = true },
		         { .pages = 1, .cached = true } },
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

// Largest image SYS_EXEC will install (src/entry.c3's EXEC_MAX_IMAGE_SIZE
// and the ~96 KiB staging arrays it sizes at this value). 32 MiB on QEMU
// — RAM is plentiful (1792 MiB free_ram) and Stage 4 of the Go port runs
// `go tool compile`, a ~23 MiB GOOS=tamago binary (docs/go-port-plan.md).
// Ordinary Go programs are 1.5-2 MiB, the C toolchain ~640 KiB. The Duo
// keeps 1 MiB (boards/duo/board.c3) — 64 MiB DRAM, no Go.
const EXEC_MAX_IMAGE_SIZE = 33554432;

// Per-process SYS_MAP ceiling (src/entry.c3's HEAP_MAX_BYTES). 512 MiB
// on QEMU — the free_ram window is 1792 MiB (src/kernel.ld, -m 2G), and
// a Go process reserves a 64/448 MiB heap arena (lazy since 2026-09-02,
// docs/devlog.md) with room for the GC to cycle. The Duo keeps 16 MiB
// (boards/duo/board.c3) — 64 MiB DRAM total.
const uptr HEAP_MAX_BYTES = 512 * 1024 * 1024;

// Console input: 0 = read it through the SBI legacy getchar (sbi::__getchar),
// which works on QEMU and the Duo. A board whose firmware mangles that call
// sets this to the UART's page and does the read itself in console_getchar()
// (see boards/opi-rv/board.c3); process.c3's map_console_mmio then maps it
// kernel-only into every page table.
const uptr CONSOLE_MMIO_PAGE = 0;

fn void plic_init()
{
	// Runs from kernel_main *before* the first switch_context — bare-mode, satp
	// still 0, so vaddr == paddr and the PLIC alias (PLIC_BASE, virtual, not
	// mapped yet) would hit nothing: use the physical addresses. Which sources
	// get armed is not decided here — see plic_arm() and the Device table.
	uptr poff = PLIC_PHYS_BASE - PLIC_BASE;

	// Threshold 0: forward any interrupt with priority > 0 (i.e. all of
	// them, since we only ever set priority 1).
	uint* threshold = (uint*)(PLIC_THRESHOLD + poff);
	mem::store(threshold, 0u, 4, true);
}

// Arm one PLIC source for the S-mode context at boot: priority 1 (0 means
// "never interrupt") plus its enable bit (one word per 32 sources). Called by
// kernel.c3's plic_arm_devices() for every board Device with `irq_armed` —
// bare mode, satp still 0, so PHYSICAL addresses. Runtime enable/disable of an
// already-routed source is plic_set_enabled() below (through the mapped alias).
fn void plic_arm(uint irq)
{
	uptr poff = PLIC_PHYS_BASE - PLIC_BASE;
	uint* priority = (uint*)(PLIC_PRIORITY_BASE + poff + (uptr)(4 * irq));
	mem::store(priority, 1u, 4, true);
	uint* enable = (uint*)(PLIC_ENABLE_BASE + poff + (uptr)((irq / 32) * 4));
	uint cur = mem::load(enable, 4, true);
	mem::store(enable, cur | (1u << (irq % 32)), 4, true);
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
// (no "usb" device, usbd never spawned).
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
