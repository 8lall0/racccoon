module kernel;

import panic;

const PAGE_SIZE = 4096;

fn uint alloc_pages(uint n) {
    static uint next_paddr = (uint) &__free_ram;
    uint paddr = next_paddr;
    next_paddr += n * PAGE_SIZE;

    if (next_paddr > (uint) &__free_ram_end) {
        panic::panic("Out of memory");
    }

    mem::set((void *) paddr, 0, n * PAGE_SIZE);
    return paddr;
}