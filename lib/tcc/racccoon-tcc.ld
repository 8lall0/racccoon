/* Linker script for TinyCC-on-racccoon (roadmap §7.7).
 *
 * Same load layout as lib/racccoon-libc/racccoon-libc.ld, but sized for
 * a compiler: tcc's image is ~450 KiB (a 128 KiB static ident-hash
 * table dominates .bss) and it recurses through the C grammar, so the
 * stack is 256 KiB, not 64. Total stays well under the kernel's
 * EXEC_MAX_IMAGE_SIZE (1 MiB, src/entry.c3). */
ENTRY(_start)

SECTIONS {
    . = 0x1000000;

    /DISCARD/ : {
        *(.eh_frame .eh_frame.* .note.* .comment .riscv.attributes)
    }

    .text : {
        KEEP(*(.text.start))
        *(.text .text.*)
    }
    .rodata : ALIGN(8) { *(.rodata .rodata.* .srodata .srodata.*) }
    .data   : ALIGN(8) { *(.data .data.* .sdata .sdata.*) }
    .bss    : ALIGN(8) {
        *(.bss .bss.* .sbss .sbss.* COMMON)
        . = ALIGN(16);
        . += 256 * 1024;   /* stack — the C grammar recurses */
        __stack_top = .;
        ASSERT(. < 0x10F0000, "tcc image too large (>~960 KiB — EXEC_MAX_IMAGE_SIZE)")
    }
}
