module kernel;

import panic;

const SATP_SV32 = (1u << 31);
const PAGE_V = (1 << 0);        // "Valid" bit (entry is enabled)
const PAGE_R = (1 << 1);        // Readable
const PAGE_W = (1 << 2);        // Writable
const PAGE_X = (1 << 3);        // Executable
const PAGE_U = (1 << 4);        // User (accessible in user mode)

fn void map_page(uint *table1, uint vaddr, uint paddr, uint flags) {
    if (!mem::ptr_is_aligned((void*)vaddr, PAGE_SIZE)) {
        panic::panic("unaligned vaddr");
    }
    if (!mem::ptr_is_aligned((void*)paddr, PAGE_SIZE)) {
        panic::panic("unaligned paddr");
    }

    uint vpn1 = (vaddr >> 22) & 0x3ff;
    if ((table1[vpn1] & PAGE_V) == 0) {
        // Create the 1st level page table if it doesn't exist.
        uint pt_paddr = alloc_pages(1);
        table1[vpn1] = (((uint)(pt_paddr >> 12)) << 10) | PAGE_V;
    }

    // Set the 2nd level page table entry to map the physical page.
    uint vpn0 = (vaddr >> 12) & 0x3ff;
    uint *table0 = (uint *) ((table1[vpn1] >> 10) * PAGE_SIZE);
    table0[vpn0] = (((uint)(paddr >> 12)) << 10) | flags | PAGE_V;
}