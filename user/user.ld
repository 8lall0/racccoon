ENTRY(start)

SECTIONS {
    /* Must match kernel.c3's USER_BASE and process.c3 user_entry()'s
       hardcoded sepc value. */
    . = 0x1000000;

    /DISCARD/ : {
        *(.eh_frame .eh_frame.*)
    }

    /* machine code */
    .text :{
        KEEP(*(.text.start));
        *(.text .text.*);
    }

    /* read-only data */
    .rodata : ALIGN(4) {
        *(.rodata .rodata.*);
    }

    /* data with initial values */
    .data : ALIGN(4) {
        *(.data .data.*);
    }

    /* data that should be zero-filled at startup */
    .bss : ALIGN(4) {
        *(.bss .bss.* .sbss .sbss.*);

        . = ALIGN(16);
        . += 64 * 1024; /* 64KB */
        __stack_top = .;

       ASSERT(. < 0x1800000, "too large executable");
    }
}