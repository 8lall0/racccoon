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

const uptr PLIC_PRIORITY_PAGE = PLIC_PRIORITY_BASE & (uptr)~(kernel::PAGE_SIZE - 1);
const uptr PLIC_ENABLE_PAGE   = PLIC_ENABLE_BASE & (uptr)~(kernel::PAGE_SIZE - 1);
const uptr PLIC_CLAIM_PAGE    = PLIC_CLAIM & (uptr)~(kernel::PAGE_SIZE - 1);

// No virtio-blk (or any storage driver at all yet) on real hardware —
// virtio-mmio is a QEMU paravirtual device with no physical equivalent.
// kernel.c3 skips spawning diskd/fsd entirely when this is false; the
// shell loses readfile/writefile until a real SD/eMMC driver exists —
// explicit, flagged scope cut (see the plan file), not silently
// dropped.
const bool HAS_BLOCK_DEVICE = false;

// Same register formulas as boards/qemu/board.c3 — see this file's own
// PLIC_BASE comment for why these are unverified rather than assumed
// safe.
fn void plic_init()
{
	uint* priority = (uint*)(PLIC_PRIORITY_BASE + 4 * IRQ_VIRTIO_BLK);
	mem::store(priority, 1u, 4, true);
	uint* enable = (uint*)PLIC_ENABLE_BASE;
	mem::store(enable, (1u << IRQ_VIRTIO_BLK), 4, true);
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
