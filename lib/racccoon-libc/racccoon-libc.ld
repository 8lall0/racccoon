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

    /* Module-level static initializers (c3's own — the real stdlib's
       "std::io on racccoon" path is the first thing here to need any;
       plain C programs from lib/racccoon-libc/build.sh don't emit
       this). Empirically: c3's runtime type-introspection data (the
       per-type "dtable" a `(Allocator)`-style interface call looks up
       its method through — "No method 'acquire' could be found on
       target" otherwise) gets built by functions placed here, not by
       anything that just runs at load time — user/std_racccoon/
       rt_entry.c3's _start has to walk this array and call each one
       before `main`, same as any real crt0 would. */
    .init_array : ALIGN(8) {
        __init_array_start = .;
        *(.init_array .init_array.*)
        __init_array_end = .;
    }

    /* Thread-local storage (c3's `tlocal` — std::core::mem::allocators::
       thread_allocator is the one that surfaced this, "std::io on
       racccoon"). No real per-thread anything here (one execution
       context per process) — .tdata/.tbss just need SOME real,
       adjacent memory and a symbol marking its start, so
       user/std_racccoon/rt_entry.c3's _start can point tp straight at
       it (`la tp, __tls_start`), matching the TCB-less convention
       LLVM's static riscv64 codegen assumes for tp-relative access
       here (empirically: a tlocal var's own load offset is exactly
       its distance from .tdata's start, no header). Harmless for the
       plain C programs (lib/racccoon-libc/build.sh) that also link
       against this script and never declare a _Thread_local — these
       sections are just empty for them. */
    .tdata : ALIGN(8) {
        __tls_start = .;
        *(.tdata .tdata.*)
    }

    .tbss : ALIGN(8) {
        *(.tbss .tbss.*)
    }

    .bss : ALIGN(8) {
        *(.bss .bss.* .sbss .sbss.* COMMON)

        . = ALIGN(16);
        . += 64 * 1024;  /* 64 KiB stack */
        __stack_top = .;

        ASSERT(. < 0x1040000, "C program image too large (>256 KiB — EXEC_MAX_IMAGE_SIZE)")
    }
}
