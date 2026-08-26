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

// Regression guard for the PPN-masking bug itself (docs/devlog.md):
// board::PTE_EXTRA_BITS is 0 on QEMU, which makes a masking bug in the
// two functions above structurally invisible to the QEMU regression
// suite no matter what code path runs them or when — it's not about
// exercising the right *scenario*, it's that QEMU has no board-specific
// "reserved" bits to corrupt anything with in the first place. Recreate
// the actual bug shape directly instead: a synthetic PTE with T-Head's
// real MAEE bit pattern set, independent of whatever this board's own
// PTE_EXTRA_BITS happens to be, so this can never again pass on a board
// that doesn't need it while silently failing on one that does. Called
// once at boot, before any real page table exists.
fn void self_test_pte_roundtrip()
{
	uptr test_paddr = (uptr)&__free_ram;
	ulong fake_extra_bits = (1UL << 60) | (1UL << 61) | (1UL << 62);
	ulong entry = paddr_to_ppn_field(test_paddr) | PAGE_V | fake_extra_bits;
	if (pte_to_paddr(entry) != test_paddr)
	{
		panic::panic("pte_to_paddr round-trip self-test failed");
	}
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
// Walks (allocating on demand) down to the leaf (3rd-level) table for
// `vaddr`, creating table2/table1 entries as needed — shared by
// map_page() and map_device_page() below, since both need the identical
// intermediate-table walk and only differ in what they put in the final
// leaf entry.
//
// board::PTE_EXTRA_BITS (see boards/duo/board.c3): applied to every
// intermediate level here — this SoC's table walker apparently needs it
// on intermediate table-pointer entries too, unlike this exact SDK's own
// Linux fork (whose _PAGE_TABLE omits them); found by testing leaf-only
// first, which made no observable difference at all to a real-hardware
// hang, meaning the walk was failing before ever reaching the leaf. This
// is a table-walker requirement, independent of whatever the *leaf*
// mapping's own memory type should be (see map_device_page()'s comment
// for why that part does need to differ).
fn ulong* walk_to_leaf_table(ulong* table2, uptr vaddr)
{
	uint vpn2 = (uint)((vaddr >> 30) & 0x1ff);
	if ((table2[vpn2] & PAGE_V) == 0)
	{
		uptr pt_paddr = alloc_pages(1);
		table2[vpn2] = paddr_to_ppn_field(pt_paddr) | PAGE_V | board::PTE_EXTRA_BITS;
	}
	ulong* table1 = (ulong*)pte_to_paddr(table2[vpn2]);

	uint vpn1 = (uint)((vaddr >> 21) & 0x1ff);
	if ((table1[vpn1] & PAGE_V) == 0)
	{
		uptr pt_paddr = alloc_pages(1);
		table1[vpn1] = paddr_to_ppn_field(pt_paddr) | PAGE_V | board::PTE_EXTRA_BITS;
	}
	return (ulong*)pte_to_paddr(table1[vpn1]);
}

// Validates that every page in [vaddr, vaddr+len) is present in
// `table2`, user-accessible, and has the requested permission — the
// check every syscall taking a raw user pointer/length needs before
// dereferencing it, since sstatus.SUM (process.c3's user_entry) lets
// S-mode read/write PAGE_U pages unconditionally otherwise: with no
// check at all, a process could pass any address — including kernel
// RAM mapped PAGE_R|PAGE_W|PAGE_X but not PAGE_U into every process's
// own table (process.c3's create_process) — and the kernel would read
// or write it on the process's behalf.
//
// Deliberately non-allocating, unlike walk_to_leaf_table(): a missing
// intermediate table means the address was never validly mapped at
// all, which must fail closed (false), not silently allocate a fresh
// empty table and then fail the leaf check anyway. Walks one page at a
// time rather than reusing walk_to_leaf_table's cached table1 pointer
// across pages — this is a boundary check on the way to a handful of
// syscall arguments, not a hot path, so the extra per-page walk cost
// isn't worth the complexity of short-circuiting it.
fn bool user_range_valid(ulong* table2, uptr vaddr, ulong len, bool want_write)
{
	if (len == 0) return true;
	if (vaddr + len < vaddr) return false; // overflow

	uptr start_page = vaddr & ~(uptr)(PAGE_SIZE - 1);
	uptr end_page = (vaddr + len - 1) & ~(uptr)(PAGE_SIZE - 1);

	for (uptr page_addr = start_page; ; page_addr += PAGE_SIZE)
	{
		uint vpn2 = (uint)((page_addr >> 30) & 0x1ff);
		if ((table2[vpn2] & PAGE_V) == 0) return false;
		ulong* table1 = (ulong*)pte_to_paddr(table2[vpn2]);

		uint vpn1 = (uint)((page_addr >> 21) & 0x1ff);
		if ((table1[vpn1] & PAGE_V) == 0) return false;
		ulong* table0 = (ulong*)pte_to_paddr(table1[vpn1]);

		uint vpn0 = (uint)((page_addr >> 12) & 0x1ff);
		ulong pte = table0[vpn0];
		if ((pte & PAGE_V) == 0) return false;
		if ((pte & PAGE_U) == 0) return false;
		if (want_write && (pte & PAGE_W) == 0) return false;
		if (!want_write && (pte & PAGE_R) == 0) return false;

		if (page_addr == end_page) break;
	}
	return true;
}

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

	ulong* table0 = walk_to_leaf_table(table2, vaddr);

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
	// board::PTE_EXTRA_BITS at the leaf: SHARE|CACHE|BUF — the correct
	// memory type for ordinary RAM (kernel/user image pages, page
	// tables), matching this exact SDK's own Linux fork's PAGE_KERNEL.
	// NOT correct for device MMIO — see map_device_page() below, which
	// every genuine hardware-register mapping in this codebase should
	// use instead of this function.
	uint vpn0 = (uint)((vaddr >> 12) & 0x1ff);
	table0[vpn0] = paddr_to_ppn_field(paddr) | (ulong)flags | PAGE_V | PAGE_A | PAGE_D | board::PTE_EXTRA_BITS;
}

// Same as map_page(), for genuine device MMIO (PLIC, virtio-blk,
// user/sdd.c3's SDHCI/pad-mux/clock registers, and any future real
// hardware register block) rather than ordinary RAM. The one difference:
// no board::PTE_EXTRA_BITS at the leaf.
//
// This isn't a style choice — board::PTE_EXTRA_BITS's SHARE|CACHE|BUF
// combination (see map_page()'s own comment) marks a mapping cacheable,
// which is correct for RAM but wrong for a hardware register: a cached
// write can sit in the CPU's own cache line and never actually reach the
// device at all until that line happens to get evicted, and a cached
// read can just as easily return a stale value instead of the device's
// live state, instead of silently doing the right thing the way it
// would for RAM. docs/devlog.md already noted this in passing during
// the original Sv39 bring-up ("leaving them zero reads as
// Strong-Order/non-cacheable") but every map_page() call site at the time
// happened to be RAM, so it never mattered in practice until this: every
// map_page() call for real device MMIO on this board (PLIC included) was
// silently marking those registers cacheable the whole time — found only
// once user/sdd.c3's PIO-polling SD driver made the effect impossible to
// miss (register writes reading back correctly — cache hit on the same
// line — while the actual hardware never showed any sign of having
// received them at all).
fn void map_device_page(ulong* table2, uptr vaddr, uptr paddr, uint flags)
{
	if (!mem::ptr_is_aligned((void*)vaddr, PAGE_SIZE))
	{
		panic::panic("unaligned vaddr");
	}
	if (!mem::ptr_is_aligned((void*)paddr, PAGE_SIZE))
	{
		panic::panic("unaligned paddr");
	}

	ulong* table0 = walk_to_leaf_table(table2, vaddr);

	uint vpn0 = (uint)((vaddr >> 12) & 0x1ff);
	table0[vpn0] = paddr_to_ppn_field(paddr) | (ulong)flags | PAGE_V | PAGE_A | PAGE_D;
}
