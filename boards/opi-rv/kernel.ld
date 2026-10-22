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

    /* boot() lives in .text.boot.entry and MUST be linked first here —
       it shares .text.boot with smp.c3's secondary_entry, and c3c's
       emission order is unstable (any kernel edit can reorder them).
       Getting this wrong means OpenSBI's fixed jump to the entry point
       lands on secondary_entry instead of boot() — silent brick, no
       output. See src/kernel.ld / boards/duo/kernel.ld's matching
       comment and docs/devlog.md's ".text.boot ordering" entry. */
    .text.boot : {
        KEEP(*(.text.boot.entry));
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
    /* 1792 MiB, like src/kernel.ld for QEMU: this board has 2 GiB
       (0x40000000-0xC0000000; U-Boot banner "DRAM: 2 GiB"), OpenSBI
       sits below the kernel at 0x40000000, and this leaves ~230 MiB of
       slack at the top. A 1 GiB Orange Pi RV would need this lowered. */
    . += 1792 * 1024 * 1024;
    __free_ram_end = .;
}
