module rt_entry @feat(CUSTOM_LIBC);
import rcsys;

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
fn void _rt_after_main() @export("_rt_after_main")
{
    rcsys::rc_exit(0);
}

fn void _start() @section(".text.start") @naked @noinline @nostrip @export("_start")
{
    asm(`la sp, __stack_top
    call main
    call _rt_after_main`);
}
