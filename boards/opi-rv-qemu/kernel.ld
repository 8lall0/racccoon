ENTRY(boot)

SECTIONS {
    /* QEMU `-machine sifive_u` DRAM base is 0x80000000 (its devicetree
       `memory@80000000`, 128 MiB by default — raise with `-m` if ever
       needed, the harness doesn't). This is the ONE place the sifive_u
       verification harness diverges from boards/opi-rv/kernel.ld, which
       links at the JH7110's real 0x40200000. The S-mode payload runs at
       DRAM_BASE + 2 MiB, the same offset every other board uses, clearing
       OpenSBI's fw_dynamic reservation at the bottom of DRAM. Loaded by
       QEMU's `-kernel` (no U-Boot in the loop) — see
       scripts/launch_opi_qemu.sh. Because DRAM base differs from the real
       board, this ELF is NOT loadable on hardware; that is by design
       (see boards/opi-rv-qemu/board.c3's header). */
    . = 0x80200000;

    __kernel_map_base = .;
    __kernel_base = .;

    /* boot() lives in .text.boot.entry and MUST be linked first — it
       shares .text.boot with smp.c3's secondary_entry and c3c's emission
       order is unstable. Getting this wrong lands OpenSBI's entry jump on
       secondary_entry — silent brick. See boards/opi-rv/kernel.ld and
       docs/devlog.md's ".text.boot ordering" entry. This harness makes
       that failure mode cheap to catch: it would brick in QEMU in
       seconds instead of on a scarce, half-flaky real board. */
    .text.boot : {
        KEEP(*(.text.boot.entry));
        KEEP(*(.text.boot));
    } :text

    /* kernel_entry (trap handler) must sit on a 4-byte boundary —
       stvec's low 2 bits are the trap-mode field. */
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
    /* Flat 64 MiB window — same size as boards/opi-rv/kernel.ld, and it
       fits inside sifive_u's default 128 MiB (kernel at DRAM_BASE + 2 MiB
       leaves ~126 MiB, so 64 MiB clears it with room for OpenSBI's FDT
       and reservations near the top). */
    . += 64 * 1024 * 1024;
    __free_ram_end = .;
}
