ENTRY(boot)

SECTIONS {
    /* JH7110 DRAM base is 0x40000000 (not 0x80000000 like QEMU virt and
       the Milk-V Duo). The S-mode payload runs at DRAM_BASE + 2MiB, the
       same offset QEMU and the Duo use and the address VisionFive 2's
       U-Boot proper itself runs at — it clears OpenSBI's PMP-protected
       fw_dynamic reservation at the bottom of DRAM (0x40000000, up to
       512KiB). Load racccoon here with the vendor U-Boot's `bootelf`
       (keeps this entry point, jumps in S-mode with a0=hartid,
       a1=dtb — racccoon ignores both). See docs/opi-rv-plan.md. */
    . = 0x40200000;

    /* Equal to __kernel_base on every board without a firmware header to
       skip (QEMU, and this one) — see src/kernel.ld's comment. The Duo
       is the exception (32-byte fiptool LOADER_2ND header). */
    __kernel_map_base = .;
    __kernel_base = .;

    .text.boot : {
        KEEP(*(.text.boot));
    } :text

    /* kernel_entry (trap handler) must sit on a 4-byte boundary —
       stvec's low 2 bits are the trap-mode field. See src/kernel.ld and
       entry.c3's comment on kernel_entry. */
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
    /* The Orange Pi RV ships in 1/2/4/8 GiB variants; every variant has
       at least this much contiguous DRAM above the kernel, so a flat
       64MiB window (same as src/kernel.ld for QEMU) is safe on all of
       them and needs no runtime DT probe. Raise it once a real board is
       in hand and the smallest target variant is known — unlike the
       Duo (64MiB total, tight), there is genuine headroom here. */
    . += 64 * 1024 * 1024;
    __free_ram_end = .;
}
