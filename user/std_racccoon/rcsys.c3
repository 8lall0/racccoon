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

// Same asm{} shape as user.c3's own syscall() — all-local operands,
// the form actually proven to work on this target.
fn int rc_syscall(long sysno, long arg0, long arg1, long arg2)
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
	return (int)result;
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
