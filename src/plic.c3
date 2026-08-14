module kernel;

// QEMU's virt machine PLIC. Register layout matches the standard
// SiFive-style PLIC used across RISC-V platforms (same one xv6-riscv
// targets): a small handful of scattered pages, not one contiguous block,
// which is why create_process maps three specific pages for it rather
// than a range.
const uint PLIC_BASE = 0x0c000000;

// virtio-mmio devices on QEMU's virt board get IRQ N for slot N; we only
// ever attach one device (bus=virtio-mmio-bus.0, slot 0), so IRQ 1.
const uint IRQ_VIRTIO_BLK = 1;

// Context = (hart, privilege mode) pair the PLIC targets. QEMU virt wires
// context 2*hart for M-mode and 2*hart+1 for S-mode; single-hart S-mode
// kernel, so context 1.
const uint PLIC_S_CONTEXT = 1;

const uint PLIC_PRIORITY_BASE = PLIC_BASE;                                    // + 4*irq
const uint PLIC_ENABLE_BASE   = PLIC_BASE + 0x2000 + PLIC_S_CONTEXT * 0x80;    // + (irq/32)*4, bit irq%32
const uint PLIC_THRESHOLD     = PLIC_BASE + 0x200000 + PLIC_S_CONTEXT * 0x1000;
const uint PLIC_CLAIM         = PLIC_BASE + 0x200004 + PLIC_S_CONTEXT * 0x1000;

// Page-aligned bases of the three distinct pages the registers above fall
// in (PLIC_ENABLE_BASE and PLIC_THRESHOLD/PLIC_CLAIM aren't page-aligned
// themselves), for create_process to map into every process's page table.
const uint PLIC_PRIORITY_PAGE = PLIC_PRIORITY_BASE & (uint)~(PAGE_SIZE - 1);
const uint PLIC_ENABLE_PAGE   = PLIC_ENABLE_BASE & (uint)~(PAGE_SIZE - 1);
const uint PLIC_CLAIM_PAGE    = PLIC_CLAIM & (uint)~(PAGE_SIZE - 1);

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
