module rcsys @feat(CUSTOM_LIBC);

// The one raw syscall this std::io support needs: SYS_PUTCHAR (#1,
// user/user.c3's own const). Deliberately NOT `import user;` — user.c3
// exports its own `putchar` under that exact linker name
// (@export("putchar")), which would collide with libc.c3's POSIX
// `putchar` here if both were ever linked into the same binary. Kept
// as its own tiny, private wrapper instead so this std::io path stays
// decoupled from user.c3 — a program that wants both just calls
// user::fs_read/exec/etc directly and lets this handle console output.
const long SYS_PUTCHAR = 1;
const long SYS_EXIT    = 3;
const long SYS_MAP     = 47;

// Same asm{} shape as user.c3's own syscall() — all-local operands,
// the form actually proven to work on this target.
fn int rc_syscall(long sysno, long arg0, long arg1, long arg2)
{
	return (int)rc_syscall_long(sysno, arg0, arg1, arg2);
}

// user.c3 keeps this as a SEPARATE function from plain syscall()
// (not just a cast at the call site) because a return value can be a
// real 64-bit pointer — truncating to int would corrupt any address
// with bits set above 32 (map_pages hit exactly this: SimpleHeapAllocator
// faulted on a garbage pointer until this got split out to match).
fn long rc_syscall_long(long sysno, long arg0, long arg1, long arg2)
{
	long result;
	asm {
		mv $a0, arg0;
		mv $a1, arg1;
		mv $a2, arg2;
		mv $a3, sysno;
		ecall;
		mv result, $a0;
	}
	return result;
}

fn int rc_putchar(int c)
{
	rc_syscall(SYS_PUTCHAR, (long)c, 0, 0);
	return c;
}

fn void rc_exit(int code) @noreturn
{
	rc_syscall(SYS_EXIT, (long)code, 0, 0);
	for (;;) {}   // SYS_EXIT never returns; keep the compiler happy
}

// SYS_MAP: fresh zero-filled RW pages past the process image — the
// userspace "give me more memory" primitive (there's no malloc/brk).
// Same call user/user.c3's own map_pages() wraps; reimplemented
// privately here for the same decoupling-from-user.c3 reason as
// rc_putchar/rc_exit above. See heap.c3 for what uses it.
fn void* rc_map_pages(uint nbytes)
{
	long r = rc_syscall_long(SYS_MAP, (long)nbytes, 0, 0);
	if (r == -1) return null;
	return (void*)(uptr)r;
}
