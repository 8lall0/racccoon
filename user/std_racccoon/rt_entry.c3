module rt_entry @feat(CUSTOM_LIBC);
import rcsys, rcsys_heap;
import std::core::mem;

// Entry point for a /bin program built WITH the real c3 stdlib
// (std::io, std::core::mem, ...) instead of std::nolibc — see
// docs/devlog.md ("std::io on racccoon"). Every other /bin program
// gets its entry from std::nolibc::main_stub's @main_no_args /
// @main_args, forwarding macros the compiler's OWN synthetic-main
// generator looks up by name; that generator still runs here too
// (nothing in this file replaces it) and produces the real, exported
// `main(int, char**)` — sema_create_synthetic_main in the real c3c's
// sema_decls.c, extname literally "main" — the same as any hosted c3
// program's `fn void main()`. What's missing on a target with no OS is
// the thing that calls that `main`: this supplies `_start` by hand,
// matching lib/racccoon-libc/src/start.c's own shape (this project's
// existing C crt0) rather than reinventing it — set sp from the
// linker script's __stack_top (lib/racccoon-libc/racccoon-libc.ld,
// reused verbatim: ENTRY(_start), same USER_BASE layout as user/user.ld),
// call `main`, then exit cleanly if it ever returns. rcsys, not
// user.c3, for the exit syscall — same reasoning as rcsys.c3's own
// comment (user.c3's exported names would collide with libc.c3's).
//
// `fn void main()` (no args) is all this path supports for now — a
// real argc/argv parse (SYS_EXEC's blob, same convention main_stub.c3
// already decodes) would be the natural next step if a std::io program
// ever needs its own arguments.
extern fn void real_main() @cname("main");

// racccoon-libc.ld's own comment explains what these are and why they
// have to be walked by hand: c3's module-level static initializers
// (dtable/type-introspection registration among them — without this,
// any `(Allocator)`-style interface call panics "No method '...' could
// be found on target" the first time it's actually invoked, not at
// compile time).
extern char __init_array_start;
extern char __init_array_end;
alias InitFn = fn void();

// `_start` itself has to be raw asm (no C3 code runs before `sp`/`tp`
// are set), but everything after that needs real C3, not more asm. So
// `_start` only sets `sp`/`tp` and jumps into this — the first real C3
// code in the process — which runs the init_array, wires up heap.c3's
// allocator (mem::@scoped — thread_allocator is @private to the real
// stdlib's own allocators module, only reachable through its own
// public helpers), runs `main` with it scoped in for the whole call,
// then exits cleanly.
fn void _rt_run() @export("_rt_run")
{
    InitFn* p = (InitFn*)&__init_array_start;
    InitFn* end = (InitFn*)&__init_array_end;
    while (p < end) { (*p)(); p++; }

    rcsys_heap::heap_init();
    mem::@scoped(&rcsys_heap::heap)
    {
        real_main();
    };
    rcsys::rc_exit(0);
}

// `tp` (thread pointer) has to be set here too, before anything can
// touch a tlocal variable (thread_allocator, reached inside
// _rt_run's mem::@scoped) — see racccoon-libc.ld's own comment on
// __tls_start for why tp = __tls_start exactly, no header offset.
// The kernel zeroes tp for a fresh process/exec (src/entry.c3's
// sys_exec, src/process.c3's user_entry — same fix, same day this
// was found) so a leftover value can't leak in, but only THIS
// program's own crt0 knows where ITS OWN .tdata/.tbss actually
// landed, so only it can point tp at the right place.
fn void _start() @section(".text.start") @naked @noinline @nostrip @export("_start")
{
    asm(`la sp, __stack_top
    la tp, __tls_start
    call _rt_run`);
}
