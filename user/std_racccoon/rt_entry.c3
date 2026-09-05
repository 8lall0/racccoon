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
// `int main(int argc, char** argv)` — sema_create_synthetic_main in
// the real c3c's sema_decls.c, extname literally "main", for BOTH a
// plain `fn void main()` (dispatches to std::core::main_stub's
// @main_no_args, which ignores argc/argv entirely) and a
// `fn void main(String[] args)` (dispatches to @main_args, which
// builds `args` by walking `argv` as a real array of `char*` — the
// standard C convention, NOT racccoon's own exec blob). What's
// missing on a target with no OS is the thing that calls that `main`
// with a real argc/argv in the first place: this supplies `_start` by
// hand, matching lib/racccoon-libc/src/start.c's own shape (this
// project's existing C crt0) rather than reinventing it — set sp/tp
// from the linker script's own symbols (lib/racccoon-libc/
// racccoon-libc.ld, reused verbatim: ENTRY(_start), same USER_BASE
// layout as user/user.ld), convert racccoon's own exec blob into a
// real argv[], call `main`, then exit cleanly if it ever returns.
// rcsys, not user.c3, for the exit syscall — same reasoning as
// rcsys.c3's own comment (user.c3's exported names would collide with
// libc.c3's).
extern fn int real_main(int argc, char** argv) @cname("main");

// racccoon-libc.ld's own comment explains what these are and why they
// have to be walked by hand: c3's module-level static initializers
// (dtable/type-introspection registration among them — without this,
// any `(Allocator)`-style interface call panics "No method '...' could
// be found on target" the first time it's actually invoked, not at
// compile time).
extern char __init_array_start;
extern char __init_array_end;
alias InitFn = fn void();

// Bounded, not heap-allocated — matches std::nolibc::main_stub.c3's
// own MAIN_STUB_ARGS_MAX convention (32), and avoids needing the heap
// already up before argv even exists.
const int RT_ARGV_MAX = 32;

// `_start` itself has to be raw asm (no C3 code runs before `sp`/`tp`
// are set), but everything after that needs real C3, not more asm. So
// `_start` only sets `sp`/`tp` and jumps into this — the first real C3
// code in the process — which runs the init_array, wires up heap.c3's
// allocator (mem::@scoped — thread_allocator is @private to the real
// stdlib's own allocators module, only reachable through its own
// public helpers), runs `main` with it scoped in for the whole call,
// then exits cleanly.
//
// `exec_argc`/`blob` arrive here exactly as SYS_EXEC (entry.c3) left
// them in a0/a1 — `_start`'s `la sp/tp` instructions don't touch
// those, and a plain `call` (not a C3 call expression) doesn't either,
// so whatever SYS_EXEC set is still live in a0/a1 when this function's
// own prologue runs, landing in these two parameters exactly like any
// normal two-argument function call would. Blob format: an
// NUL-separated "path\0arg1\0arg2\0..." with exec_argc counting all of
// it including string 0 (the path) — same convention
// std::nolibc::main_stub.c3's own @main_args already decodes for
// every other /bin program. Peeling string 0 off here (real_argc
// starts at 0, string 0 is walked but never stored into argv) keeps
// `main(String[] args)` seeing only the real arguments as args[0..],
// matching every existing /bin program's own convention rather than
// the POSIX one (argv[0] = own path) the real stdlib's @main_args
// would otherwise impose.
fn void _rt_run(int exec_argc, char* blob) @export("_rt_run")
{
    InitFn* p = (InitFn*)&__init_array_start;
    InitFn* end = (InitFn*)&__init_array_end;
    while (p < end) { (*p)(); p++; }

    rcsys_heap::heap_init();

    char*[RT_ARGV_MAX] argv @noinit;
    int n = exec_argc;
    if (n > RT_ARGV_MAX + 1) { n = RT_ARGV_MAX + 1; }
    char* q = blob;
    int real_argc = 0;
    for (int i = 0; i < n; i++)
    {
        if (i > 0) { argv[real_argc] = q; real_argc++; }
        while (*q) { q++; }
        q++;
    }

    mem::@scoped(&rcsys_heap::heap)
    {
        real_main(real_argc, &argv[0]);
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
