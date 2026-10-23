module kernel;

import board;

// The PLIC driver, shared by every board.
//
// All four targets (QEMU virt, Milk-V Duo's c900-plic, the JH7110 and QEMU
// sifive_u) carry the standard SiFive PLIC register layout, so the register
// formulas and the claim/complete/enable code live here once. A board states
// only the three facts that actually differ (boards/<name>/board.c3):
//
//   board::PLIC_PHYS_BASE  where the PLIC sits physically
//   board::PLIC_BASE       the virtual address the kernel reaches it through
//                          once paging is on — == PLIC_PHYS_BASE (identity) on
//                          the real boards, aliased apart on QEMU virt (see
//                          boards/qemu/board.c3's PLIC_BASE comment)
//   board::PLIC_S_CONTEXT_BASE  where the S-mode contexts start: hart h's
//                          is BASE + 2*h on every board here (1 on QEMU virt
//                          / Duo, whose hart 0 has M + S; 0 on JH7110 /
//                          sifive_u, whose hart 0 is M-only, so hart 1's S
//                          context is 2)
//
// The context is the BOOT hart's, picked at plic_init(): OpenSBI may start
// racccoon on any hart (the Orange Pi's harts 1-4), and the boot hart is
// the one that takes external interrupts. A fixed context silently lost
// every interrupt whenever it wasn't hart 1.
//
// A small handful of scattered pages, not one contiguous block — which is why
// map_plic() maps three separate pages, not a range. Addresses are uptr; the
// registers themselves stay 32-bit (irq numbers, priority, enable bitmask) —
// PLIC register width is fixed by the spec, independent of hart XLEN.

const uptr PLIC_PRIORITY_BASE = board::PLIC_BASE;                                          // + 4*irq

// The S-mode context in use (plic_init sets it from the boot hart; until
// then hart 0's, which nothing uses — plic_init runs before any process).
uptr g_plic_ctx = board::PLIC_S_CONTEXT_BASE;

fn uptr plic_enable_base() { return board::PLIC_BASE + 0x2000 + g_plic_ctx * 0x80; }   // + (irq/32)*4, bit irq%32
fn uptr plic_threshold() { return board::PLIC_BASE + 0x200000 + g_plic_ctx * 0x1000; }
fn uptr plic_claim_addr() { return board::PLIC_BASE + 0x200004 + g_plic_ctx * 0x1000; }

// Virtual-minus-physical: add to a PLIC_* address to get the physical one.
// Zero on identity-mapped boards. Used by the bare-mode boot path (satp still
// 0, the alias not mapped yet) — plic_init() and plic_arm().
const uptr PLIC_PHYS_OFFSET = board::PLIC_PHYS_BASE - board::PLIC_BASE;

// Page-aligned bases of the distinct pages the registers above fall in
// (the enable words and threshold/claim aren't page-aligned themselves;
// each context's threshold/claim pair has a page of its own).
const uptr PLIC_PRIORITY_PAGE = PLIC_PRIORITY_BASE & (uptr)~(PAGE_SIZE - 1);
fn uptr plic_enable_page() { return plic_enable_base() & (uptr)~(PAGE_SIZE - 1); }
fn uptr plic_claim_page() { return plic_claim_addr() & (uptr)~(PAGE_SIZE - 1); }

// Map the PLIC's three pages, kernel-only (no PAGE_U), into a page table:
// handle_trap's plic_claim()/plic_complete() run under whichever process's
// page table is active when the interrupt arrives. Virtual PLIC_*_PAGE ->
// its physical page. Every page table a process can run on needs this —
// create_process and SYS_RFORK's child table both call it.
fn void map_plic(ulong* page_table)
{
	map_device_page(page_table, PLIC_PRIORITY_PAGE, PLIC_PRIORITY_PAGE + PLIC_PHYS_OFFSET, PAGE_R | PAGE_W);
	map_device_page(page_table, plic_enable_page(), plic_enable_page() + PLIC_PHYS_OFFSET, PAGE_R | PAGE_W);
	map_device_page(page_table, plic_claim_page(), plic_claim_page() + PLIC_PHYS_OFFSET, PAGE_R | PAGE_W);
}

// Runs from kernel_main *before* the first switch_context — bare mode, so
// physical addresses. Threshold 0: forward any interrupt with priority > 0
// (i.e. all of them, since we only ever set priority 1). Which sources get
// armed is not decided here — see plic_arm() and plic_arm_devices().
fn void plic_init(uint boot_hart)
{
	g_plic_ctx = board::PLIC_S_CONTEXT_BASE + 2 * (uptr)boot_hart;
	uint* threshold = (uint*)(plic_threshold() + PLIC_PHYS_OFFSET);
	mem::store(threshold, 0u, 4, true);
}

// Arm one PLIC source for the S-mode context at boot: priority 1 (0 means
// "never interrupt") plus its enable bit (one word per 32 sources). Called by
// device.c3's plic_arm_devices() for every board Device with `irq_armed` —
// bare mode, so PHYSICAL addresses. Runtime enable/disable of an
// already-routed source is plic_set_enabled() below (through the mapped alias).
fn void plic_arm(uint irq)
{
	uint* priority = (uint*)(PLIC_PRIORITY_BASE + PLIC_PHYS_OFFSET + (uptr)(4 * irq));
	mem::store(priority, 1u, 4, true);
	uint* enable = (uint*)(plic_enable_base() + PLIC_PHYS_OFFSET + (uptr)((irq / 32) * 4));
	uint cur = mem::load(enable, 4, true);
	mem::store(enable, cur | (1u << (irq % 32)), 4, true); // e.g. Duo IRQ_SDHCI 36 -> second word, bit 4
}

// Toggle a single S-context enable bit. handle_trap disables a
// level-triggered source (Duo USB) the instant it fires — the device line
// stays asserted until the driver clears it and the SoC re-traps before the
// returned-to context runs an instruction, so leaving it enabled is a hard
// hang. The driver re-arms via SYS_DRIVER_IRQ_ARM.
fn void plic_set_enabled(uint irq, bool on)
{
	uint* word = (uint*)(plic_enable_base() + (uptr)((irq / 32) * 4));
	uint cur = mem::load(word, 4, true);
	uint bit = 1u << (irq % 32);
	mem::store(word, on ? (cur | bit) : (cur & ~bit), 4, true);
}

// Claiming an IRQ both tells us which one fired and acknowledges it to the
// PLIC (clears it from pending) — returns 0 if nothing is actually pending
// (spurious claim).
fn uint plic_claim()
{
	uint* claim = (uint*)plic_claim_addr();
	return mem::load(claim, 4, true);
}

// Must be called after handling an IRQ obtained via plic_claim(), or the
// PLIC will never forward that source again.
fn void plic_complete(uint irq)
{
	uint* complete = (uint*)plic_claim_addr();
	mem::store(complete, irq, 4, true);
}
