ENTRY(boot)

/* DRAM_BASE + 2MiB. Confirmed, not guessed: matches the vendor SDK's own
   committed board memmap for milkv-duo-sd
   (duo-buildroot-sdk/build/boards/cv180x/cv1800b_milkv_duo_sd/memmap.py —
   CONFIG_SYS_TEXT_BASE = DRAM_BASE + 2*SIZE_1M), which is where the
   vendor's own U-Boot runs as the LOADER_2ND/"BL33" payload that racccoon
   replaces. Leaves ~1.5MB of headroom below it (OpenSBI's MONITOR slot
   is 512KB, ending at DRAM_BASE + 0x80000), and FSBL's own bounds check
   (IN_RANGE(runaddr, DRAM_BASE, DRAM_SIZE) in bl2_opt.c) only requires
   it fall inside the 64MB DRAM window — see docs/devlog.md for the full
   fiptool/FSBL packaging chain this was traced through. */
__loader2nd_runaddr = 0x80200000;

/* CV1800B has only 64MB of populated DDR2 total (0x80000000-0x84000000,
   per the datasheet and memmap.py's DRAM_SIZE) — unlike QEMU virt, which
   is given far more than it needs, so a flat "64MB after the stack"
   free_ram region (what src/kernel.ld does for QEMU) would overrun the
   real DRAM window here by whatever the loader2nd offset + image +
   stack already consumed. free_ram is sized against the real DRAM end
   instead. Also reserves the top 768KB (memmap.py's FREERTOS_SIZE), the
   region the vendor's own firmware treats as the second C906 core's —
   racccoon is single-hart and never touches that core, but keeping the
   same boundary costs nothing and avoids ever depending on silicon that
   isn't confirmed free. */
__dram_end = 0x80000000 + 64 * 1024 * 1024 - 768 * 1024;

SECTIONS {
    . = __loader2nd_runaddr;

    /* Page-aligned (RUNADDR itself always is — see this file's own
       RUNADDR comment) start of the kernel-range identity mapping that
       process.c3's create_process and entry.c3's rfork COW-copy path
       build with map_page() in PAGE_SIZE steps up to __free_ram_end.
       Deliberately NOT __kernel_base: that symbol sits 32 bytes higher
       (past the LOADER_2ND header reserved below), and map_page() panics
       ("unaligned vaddr") on anything that isn't page-aligned — hit this
       for real on first hardware boot. src/kernel.ld defines the same
       symbol equal to __kernel_base there, since QEMU has no header to
       offset past. */
    __kernel_map_base = .;

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
        /* boot() must be first — see src/kernel.ld's matching comment
           (c3c emission order once put smp.c3's secondary_entry ahead of
           it; the FSBL jumps to __kernel_base and would land in the
           wrong function). Pinned via its own subsection. */
        KEEP(*(.text.boot.entry));
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
    __free_ram_end = __dram_end;
}
