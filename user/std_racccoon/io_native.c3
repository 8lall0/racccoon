module io_native @feat(CUSTOM_LIBC);
import rcsys;
import std::io;
import libc;

// Userspace counterpart to src/std/io/io_native.c3 — the fopen/fwrite/
// fputc/etc. hooks std::io::os's file_nolibc.c3 calls through
// (native_fopen_fn / native_fwrite_fn / ...). Same shape as the
// kernel's, `sbi::__putchar` swapped for rcsys::rc_putchar. Wired to
// those hook globals below by user/std_racccoon/os.c3 (a copy of
// src/std/io/os/os.c3, whose bottom half does exactly that at file
// scope — no explicit init call needed in main()).

fn void*? my_fopen(String filename, String mode)
{
	return io::UNSUPPORTED_OPERATION~;
}

fn void? my_fclose(void* file)
{
	// Only stdin/stdout/stderr exist (my_fopen refuses), and they stay open.
}

fn void*? my_freopen(void* file, String filename, String mode)
{
	return io::UNSUPPORTED_OPERATION~;
}

fn void? my_fseek(void* file, long offset, SeekOrigin seek_mode)
{
	return io::UNSUPPORTED_OPERATION~;
}

fn long? my_ftell(void* file)
{
	return io::UNSUPPORTED_OPERATION~;
}

fn sz? my_fwrite(void* file, char[] buffer)
{
	rcsys::rc_write(buffer.ptr, buffer.len);
	return buffer.len;
}

// stdin only (std::io's stdin File has a null handle here): like
// read(2) on a terminal, return at the end of a line, so a line-reading
// caller doesn't block for a full buffer. 0 = end of input.
fn sz? my_fread(void* file, char[] buffer)
{
	sz n = 0;
	while (n < buffer.len)
	{
		int c = libc::fgetc(file);   // -1 for anything but stdin
		if (c < 0) break;
		buffer[n++] = (char)c;
		if (c == '\n') break;
	}
	return n;
}

fn void? my_fputc(int c, void* file)
{
	rcsys::rc_putchar(c);
}

fn void? my_remove(String filename)
{
	return io::UNSUPPORTED_OPERATION~;
}
