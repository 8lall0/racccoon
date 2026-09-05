module io_native @feat(CUSTOM_LIBC);
import rcsys;
import std::io;

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
	return io::UNSUPPORTED_OPERATION~;
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
	foreach (char c : buffer)
	{
		rcsys::rc_putchar(c);
	}
	return buffer.len;
}

fn sz? my_fread(void* file, char[] buffer)
{
	return io::UNSUPPORTED_OPERATION~;
}

fn void? my_fputc(int c, void* file)
{
	rcsys::rc_putchar(c);
}

fn void? my_remove(String filename)
{
	return io::UNSUPPORTED_OPERATION~;
}
