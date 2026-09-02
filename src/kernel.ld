ENTRY(boot)

SECTIONS {
    . = 0x80200000;
    /* Page-aligned start of the kernel-range identity mapping (see
       process.c3's create_process and entry.c3's rfork COW-copy path,
       both of which map_page() from here to __free_ram_end in PAGE_SIZE
       steps). Equal to __kernel_base here, but not on the Duo board,
       whose kernel.ld reserves a 32-byte fiptool header ahead of
       __kernel_base — that offset would otherwise fail map_page()'s
       alignment check on its very first iteration. Kept as a distinct
       symbol on every board so src/process.c3 and src/entry.c3 never
       need board-specific cases of their own. */
    __kernel_map_base = .;
    __kernel_base = .;

    .text.boot : {
        KEEP(*(.text.boot));
    } :text

    /* kernel_entry (the trap handler) must land on a real 4-byte boundary:
       stvec's low 2 bits are the trap mode field per the RISC-V spec, and
       a misaligned value there puts the CPU in Reserved trap mode
       (undefined behavior). @align(4) on the function alone was not
       reliably honored once other code size changed enough to shift it
       off a 4-byte boundary — this explicit, linker-enforced ALIGN() is
       the trustworthy version. See entry.c3's comment on kernel_entry. */
    .text.trap : ALIGN(4) {
        KEEP(*(.text.trap));
    } :text

    .text : {
        *(.text .text.*);
    } :text

    .rodata : ALIGN(4) {
        *(.rodata .rodata.*);
    } :text

    .data : ALIGN(4) {
        *(.data .data.*);
    } :text

    .bss : ALIGN(4) {
        __bss = .;
        *(.bss .bss.* .sbss .sbss.*);
        __bss_end = .;
    } :text

    . = ALIGN(4);
    . += 128 * 1024;
    __stack_top = .;

    . = ALIGN(4096);
    __free_ram = .;
    . += 1792 * 1024 * 1024; /* 1792MB. QEMU virt is launched with -m 2G
                               (scripts/launch64*.sh); kernel links at
                               DRAM_BASE+2MB, __free_ram_end lands ~0xF0400000,
                               ~250MB clear under the 0x100000000 top of a
                               2GB region — room for QEMU/OpenSBI's FDT and
                               reservations. History: 64MB -> 768MB (-m 1G,
                               eager Go arena) -> here. The on-device `go`
                               toolchain (a ~448MB `compile` + `link`, plus
                               `go` holding its own heap live) overcommitted
                               768MB and got OOM-killed; 1792MB gives it real
                               headroom. Boot at -m 2G with this value was
                               already proven (docs/go-port-plan.md). Must be
                               <= src/allocation.c3's RAM_SIZE (the
                               page-bitmap ceiling, 1920MB); the two need
                               not be equal — ram_page_count() caps the
                               allocator to whichever is smaller. The Duo's
                               boards/duo/kernel.ld pins its own to the real
                               64MB DRAM; the JH7110 / Orange Pi RV board
                               reserves close to the 1920MB ceiling out of
                               its 2GB. The kernel boots fine at QEMU -m 2G
                               / 4G / 8G — the old "-m >= 2G won't boot"
                               blocker cleared with the Stage 2 allocator
                               rework; see docs/go-port-plan.md. */
    __free_ram_end = .;
}