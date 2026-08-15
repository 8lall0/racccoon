ENTRY(boot)

/* UNCONFIRMED PLACEHOLDER — do not treat as a real address until Stage
   0.1/0.2 of the port plan (~/.claude/plans/giggly-prancing-iverson.md)
   confirm it against a real duo-buildroot-sdk build. Must land somewhere
   that doesn't collide with OpenSBI's own reserved region near
   0x80000000 (or anything else fiptool packs into the same fip.bin) —
   see docs/devlog.md for the research behind this file. */
__loader2nd_runaddr = 0x80400000;

SECTIONS {
    . = __loader2nd_runaddr;

    /* fiptool's LOADER_2ND ("BL33") header — JUMP0/MAGIC/CKSUM/SIZE/
       RUNADDR/RESERVED1/RESERVED2, 32 bytes total (see the FSBL source,
       fsbl/plat/cv180x/bl2/bl2_opt.c and fiptool.py's ldr_2nd_hdr in
       duo-buildroot-sdk). FSBL reads exactly these 32 bytes as a header
       and starts real execution right after them
       (loader_2nd_entry = loader_2nd_header->runaddr + sizeof(header)) —
       this reservation is what makes that line up with .text.boot below
       instead of the header overwriting our first instructions.
       The header's actual bytes are NOT emitted by this linker script —
       they get prepended to the raw kernel binary by whatever packages
       the image for fiptool, a separate build step outside racccoon's
       own compile. This just reserves the matching address space so
       __kernel_base comes out at RUNADDR + 32, where FSBL will actually
       jump. */
    . += 32;
    __kernel_base = .;

    .text.boot : {
        KEEP(*(.text.boot));
    } :text

    /* See src/kernel.ld's matching comment — kernel_entry (the trap
       handler) must land on a real 4-byte boundary; stvec's low 2 bits
       are the trap mode field per the RISC-V spec. */
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
    . += 64 * 1024 * 1024; /* 64MB — CV1800B's actual populated DDR2, per the datasheet */
    __free_ram_end = .;
}
