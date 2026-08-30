/* Linker script for a C program on racccoon. Same layout as
   user/user.ld (the C3 side): load at USER_BASE, .text.start first, a
   64 KiB stack in .bss with __stack_top after it. ENTRY is _start (the
   crt0 in lib/racccoon-libc/src/start.c), not the C3 `start`. */
ENTRY(_start)

SECTIONS {
    /* Must match kernel.c3's USER_BASE / process.c3 user_entry()'s sepc. */
    . = 0x1000000;

    /DISCARD/ : {
        *(.eh_frame .eh_frame.* .note.* .comment .riscv.attributes)
    }

    .text : {
        KEEP(*(.text.start))
        *(.text .text.*)
    }

    .rodata : ALIGN(8) {
        *(.rodata .rodata.* .srodata .srodata.*)
    }

    .data : ALIGN(8) {
        *(.data .data.* .sdata .sdata.*)
    }

    .bss : ALIGN(8) {
        *(.bss .bss.* .sbss .sbss.* COMMON)

        . = ALIGN(16);
        . += 64 * 1024;  /* 64 KiB stack */
        __stack_top = .;

        ASSERT(. < 0x1040000, "C program image too large (>256 KiB — EXEC_MAX_IMAGE_SIZE)")
    }
}
