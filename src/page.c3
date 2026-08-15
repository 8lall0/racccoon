module kernel;

import panic;

// Sv39, not Sv32: RV64 port. MODE=8 in the top 4 bits of the 64-bit
// satp register (Sv32's mode was a single bit at position 31 — a real
// encoding change, not just a width bump). See docs/devlog.md.
const ulong SATP_SV39 = (8ul << 60);
const PAGE_V    = (1 << 0); // "Valid" bit (entry is enabled)
const PAGE_R    = (1 << 1); // Readable
const PAGE_W    = (1 << 2); // Writable
const PAGE_X    = (1 << 3); // Executable
const PAGE_U    = (1 << 4); // User (accessible in user mode)

// Sv39 is 3-level (VPN2[38:30], VPN1[29:21], VPN0[20:12], each 9 bits,
// 12-bit offset) where Sv32 was 2-level (VPN1[31:22], VPN0[21:12], each
// 10 bits) — a real structural difference, not just wider fields. The
// PTE encoding itself carries over unchanged in shape: low bits 0-4 are
// still V/R/W/X/U, and `(paddr >> 12) << 10 | flags | PAGE_V` is still
// the right formula — only the PPN field is wider (44 bits vs 22),
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

	uint vpn2 = (uint)((vaddr >> 30) & 0x1ff);
	if ((table2[vpn2] & PAGE_V) == 0)
	{
		// Create the 2nd level page table if it doesn't exist.
		uptr pt_paddr = alloc_pages(1);
		table2[vpn2] = ((pt_paddr >> 12) << 10) | PAGE_V;
	}
	ulong* table1 = (ulong*)(uptr)((table2[vpn2] >> 10) * PAGE_SIZE);

	uint vpn1 = (uint)((vaddr >> 21) & 0x1ff);
	if ((table1[vpn1] & PAGE_V) == 0)
	{
		// Create the 1st level page table if it doesn't exist.
		uptr pt_paddr = alloc_pages(1);
		table1[vpn1] = ((pt_paddr >> 12) << 10) | PAGE_V;
	}
	ulong* table0 = (ulong*)(uptr)((table1[vpn1] >> 10) * PAGE_SIZE);

	// Set the leaf (3rd level) page table entry to map the physical page.
	uint vpn0 = (uint)((vaddr >> 12) & 0x1ff);
	table0[vpn0] = ((paddr >> 12) << 10) | (ulong)flags | PAGE_V;
}
