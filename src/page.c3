module kernel;

import panic;
import board;

// Sv39, not Sv32: RV64 port. MODE=8 in the top 4 bits of the 64-bit
// satp register (Sv32's mode was a single bit at position 31 — a real
// encoding change, not just a width bump). See docs/devlog.md.
const ulong SATP_SV39 = (8ul << 60);
const PAGE_V    = (1 << 0); // "Valid" bit (entry is enabled)
const PAGE_R    = (1 << 1); // Readable
const PAGE_W    = (1 << 2); // Writable
const PAGE_X    = (1 << 3); // Executable
const PAGE_U    = (1 << 4); // User (accessible in user mode)
const PAGE_G    = (1 << 5); // Global (same mapping across all address spaces)
const PAGE_A    = (1 << 6); // Accessed
const PAGE_D    = (1 << 7); // Dirty — cores without hardware A/D auto-set
                             // are spec-required to fault on a PTE with
                             // A=0 (D=0 for a write); this exact SDK's own
                             // Linux fork always sets both (PAGE_KERNEL's
                             // _PAGE_ACCESSED|_PAGE_DIRTY) and we never
                             // have — see the devlog entry for the hang
                             // this was found chasing.

// Sv39's PPN field is 44 bits (entry bits 53:10). Needed to mask entries
// back down before recovering a physical address from one — without it,
// board::PTE_EXTRA_BITS (bits 62/63 after surviving a >>10<<12 round
// trip; bit 62 of the original PTE shifts out past bit 63 and is lost,
// but 60/61 land at 62/63) corrupts every table1/table0 pointer computed
// from a parent entry on any board where PTE_EXTRA_BITS is nonzero. Hit
// this for real: QEMU (PTE_EXTRA_BITS=0) never showed it.
const ulong PPN_MASK = (1UL << 44) - 1;

// The only two places a PTE's PPN field should ever be built or read
// back — encoding (paddr_to_ppn_field) and decoding (pte_to_paddr) both
// used to be repeated inline at every call site instead (three copies
// of the encode shape in this file alone; the decode shape duplicated
// again in entry.c3's exit free-loop and its SYS_RFORK copy-on-write
// walk). That duplication is exactly how the PPN_MASK bug above shipped
// in three different places before it was fixed in all of them — see
// docs/devlog.md. Every table pointer recovery and every PTE
// construction in this codebase should go through one of these two
// functions, not reimplement the shift/mask by hand.
fn ulong paddr_to_ppn_field(uptr paddr)
{
	return (((ulong)paddr >> 12) & PPN_MASK) << 10;
}

fn uptr pte_to_paddr(ulong entry)
{
	return (uptr)(((entry >> 10) & PPN_MASK) * PAGE_SIZE);
}

// Sv39 is 3-level (VPN2[38:30], VPN1[29:21], VPN0[20:12], each 9 bits,
// 12-bit offset) where Sv32 was 2-level (VPN1[31:22], VPN0[21:12], each
// 10 bits) — a real structural difference, not just wider fields. The
// PTE encoding itself carries over unchanged in shape: low bits 0-4 are
// still V/R/W/X/U, and `paddr_to_ppn_field(paddr) | flags | PAGE_V` is
// still the right formula — only the PPN field is wider (44 bits vs 22),
// which a 64-bit table entry (`ulong`, not `uint`) naturally
// accommodates. Each level's table is still exactly one page, holding
// 512 entries now (4096 / 8 bytes per PTE) instead of 1024.
fn void map_page(ulong* table2, uptr vaddr, uptr paddr, uint flags)
{
	if (!mem::ptr_is_aligned((void*)vaddr, PAGE_SIZE))
	{
		panic::panic("unaligned vaddr");
	}
	if (!mem::ptr_is_aligned((void*)paddr, PAGE_SIZE))
	{
		panic::panic("unaligned paddr");
	}

	// board::PTE_EXTRA_BITS (see boards/duo/board.c3): applied to every
	// level here, not just the leaf — this SoC's table walker apparently
	// needs it on intermediate table-pointer entries too, unlike this
	// exact SDK's own Linux fork (whose _PAGE_TABLE omits them); found by
	// testing leaf-only first, which made no observable difference at
	// all to a real-hardware hang, meaning the walk was failing before
	// ever reaching the leaf.
	uint vpn2 = (uint)((vaddr >> 30) & 0x1ff);
	if ((table2[vpn2] & PAGE_V) == 0)
	{
		// Create the 2nd level page table if it doesn't exist.
		uptr pt_paddr = alloc_pages(1);
		table2[vpn2] = paddr_to_ppn_field(pt_paddr) | PAGE_V | board::PTE_EXTRA_BITS;
	}
	ulong* table1 = (ulong*)pte_to_paddr(table2[vpn2]);

	uint vpn1 = (uint)((vaddr >> 21) & 0x1ff);
	if ((table1[vpn1] & PAGE_V) == 0)
	{
		// Create the 1st level page table if it doesn't exist.
		uptr pt_paddr = alloc_pages(1);
		table1[vpn1] = paddr_to_ppn_field(pt_paddr) | PAGE_V | board::PTE_EXTRA_BITS;
	}
	ulong* table0 = (ulong*)pte_to_paddr(table1[vpn1]);

	// Set the leaf (3rd level) page table entry to map the physical page.
	//
	// PAGE_A | PAGE_D: the actual root cause of a real-hardware hang on
	// Milk-V Duo — this T-Head C906 core doesn't implement hardware
	// auto-setting of the Accessed/Dirty bits (no Svade-equivalent), and
	// per the RISC-V privileged spec, a core without that must fault on
	// any access through a PTE with A=0. Leaving these bits 0 (as every
	// other board we've targeted allowed) didn't produce a clean
	// architectural fault here — the very first instruction fetch
	// through a freshly Sv39-enabled mapping hard-hung instead, no trap,
	// nothing printed. Traced by bisecting against this exact SDK's own
	// Linux fork's PAGE_KERNEL/_PAGE_ACCESSED|_PAGE_DIRTY, which always
	// sets both — see docs/devlog.md for the full elimination trail (six
	// other theories ruled out first: PTE attribute bits alone, fence.i,
	// clearing mxstatus, the official prebuilt firmware, an explicit
	// D-cache flush, and a full U-Boot-mediated boot).
	//
	// board::PTE_EXTRA_BITS: T-Head's C906 repurposes Sv39's normally-
	// reserved PTE bits 63:59 as memory-attribute bits (SO/C/B/SH/SEC)
	// once its M-mode-only `mxstatus` MAEE bit is set — kept here as a
	// correctness measure for cache attributes even though it wasn't
	// what fixed the hang itself (tested and ruled out in isolation).
	uint vpn0 = (uint)((vaddr >> 12) & 0x1ff);
	table0[vpn0] = paddr_to_ppn_field(paddr) | (ulong)flags | PAGE_V | PAGE_A | PAGE_D | board::PTE_EXTRA_BITS;
}
