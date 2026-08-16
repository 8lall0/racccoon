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

// Page-aligned bases of the three distinct pages the registers above fall
// in (PLIC_ENABLE_BASE and PLIC_THRESHOLD/PLIC_CLAIM aren't page-aligned
// themselves), for process.c3's create_process to map into every
// process's page table.
const uptr PLIC_PRIORITY_PAGE = PLIC_PRIORITY_BASE & (uptr)~(kernel::PAGE_SIZE - 1);
const uptr PLIC_ENABLE_PAGE   = PLIC_ENABLE_BASE & (uptr)~(kernel::PAGE_SIZE - 1);
const uptr PLIC_CLAIM_PAGE    = PLIC_CLAIM & (uptr)~(kernel::PAGE_SIZE - 1);

// QEMU's virt board always has virtio-blk attached (see scripts/launch64.sh) —
// diskd/fsd get spawned and the shell has real file access.
const bool HAS_BLOCK_DEVICE = true;

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
