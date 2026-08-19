module sbi;

struct Sbiret
{
	long error;
	long value;
}

fn Sbiret sbi_call(long arg0, long arg1, long arg2, long arg3, long arg4, long arg5, long fid, long eid)
{
	Sbiret output;
	long error;
	long value;

	asm
	{
		mv $a0, arg0;
		mv $a1, arg1;
		mv $a2, arg2;
		mv $a3, arg3;
		mv $a4, arg4;
		mv $a5, arg5;
		mv $a6, fid;
		mv $a7, eid;

		ecall;

		sd $a0, [&error];
		sd $a1, [&value];
	}

	output.value = value;
	output.error = error;

	return output;
}

fn int __putchar(int ch)
{
	sbi_call((long)ch, 0, 0, 0, 0, 0, 0, 1);
	return ch;
}

fn int __getchar()
{
	Sbiret ret = sbi_call(0, 0, 0, 0, 0, 0, 0, 2);
	return (int)ret.error;
}

// Legacy SBI extension 0 (sbi_set_timer) — asks M-mode firmware to
// program the real hardware timer comparator (mtimecmp, M-mode-only)
// on our behalf and arrange delivery of the next S-mode timer
// interrupt once `stime_value` (an absolute time, same units as the
// `time` CSR) is reached. Deliberately not direct stimecmp CSR access
// (the sstc extension's own S-mode-writable register): confirmed on
// real Milk-V Duo hardware that writing stimecmp directly hangs the
// board silently (see docs/devlog.md) — likely menvcfg.STCE, the
// M-mode bit that permits S-mode stimecmp access at all, not being set
// by the Duo's own firmware, unlike QEMU's OpenSBI. This ecall-based
// path needs no such permission — M-mode does the actual CSR
// programming itself — same reasoning __putchar/__getchar above
// already rely on for the console.
fn void __set_timer(ulong stime_value)
{
	sbi_call((long)stime_value, 0, 0, 0, 0, 0, 0, 0);
}