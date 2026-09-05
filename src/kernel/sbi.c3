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

// Kernel log ring — every byte the kernel prints (io::print, the libc
// puts/fwrite path, board::console_putchar, panic) funnels through
// __putchar, so teeing here captures the whole console history for
// `dmesg` (SYS_KLOG_READ, src/entry.c3). Lives in `module sbi` — a leaf
// module the kernel imports — because sbi can't import `kernel` back.
// Plain non-atomic append: single-hart today, and a torn byte in a
// debug log is harmless (see spinlock.c3's console note).
const int KLOG_SIZE = 32768;
char[KLOG_SIZE] klog_buf;
ulong klog_written = 0;          // total bytes ever, monotonic

// The two halves of console output, split so src/entry.c3's SYS_PUTCHAR
// can pick per source:
//   - klog_put:     append to the ring, no console I/O.
//   - console_emit: one legacy-SBI putchar, no ring tee.
//   - __putchar:    both — for kernel-originated output (io::print, the
//                   libc puts/fwrite path, panic).
// A plain userspace process's stdout takes console_emit only (it's
// terminal output, not kernel log — and teeing it would let `dmesg`,
// which prints what it reads, chase its own tail forever). A boot/driver
// server's stdout takes klog_put always + console_emit only when `loud`
// is set (SYS_BOOT_QUIET); `dmesg` is the normal way to read it.
fn void klog_put(int ch)
{
	klog_buf[(uint)(klog_written % KLOG_SIZE)] = (char)ch;
	klog_written++;
}

fn int console_emit(int ch)
{
	sbi_call((long)ch, 0, 0, 0, 0, 0, 0, 1);
	return ch;
}

fn int __putchar(int ch)
{
	klog_put(ch);
	return console_emit(ch);
}

// Copy log bytes newer than *cursor into out (up to max). *cursor is a
// running "bytes consumed" counter — 0 to read from the start (clamped
// to the oldest byte still in the ring). Returns bytes copied; advances
// *cursor.
fn int klog_copy(char* out, int max, ulong* cursor)
{
	ulong oldest = klog_written > KLOG_SIZE ? klog_written - KLOG_SIZE : 0;
	ulong from = *cursor < oldest ? oldest : *cursor;
	int n = 0;
	while (from < klog_written && n < max)
	{
		out[n] = klog_buf[(uint)(from % KLOG_SIZE)];
		n++;
		from++;
	}
	*cursor = from;
	return n;
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

// SBI Hart State Management extension (EID "HSM" = 0x48534D), FID 0 =
// sbi_hart_start(hartid, start_addr, opaque): bring `hartid` (currently
// STOPPED) into S-mode at `start_addr` with satp=0, a0=hartid,
// a1=opaque. See src/smp.c3. Returns SBI_SUCCESS, or e.g.
// SBI_ERR_INVALID_PARAM (-3) for a hartid the machine doesn't have,
// SBI_ERR_ALREADY_AVAILABLE (-6) for one already running.
const long SBI_EXT_HSM = 0x48534D;

fn Sbiret sbi_hart_start(ulong hartid, ulong start_addr, ulong opaque)
{
	return sbi_call((long)hartid, (long)start_addr, (long)opaque, 0, 0, 0, 0, SBI_EXT_HSM);
}