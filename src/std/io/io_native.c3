module io_native @feat(CUSTOM_LIBC);
import sbi;
import std::io;

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
		sbi::__putchar(c);
	}
	return buffer.len;
}

fn sz? my_fread(void* file, char[] buffer)
{
	return io::UNSUPPORTED_OPERATION~;
}

fn void? my_fputc(int c, void* file)
{
	sbi::__putchar((char)c);
}

fn void? my_remove(String filename)
{
	return io::UNSUPPORTED_OPERATION~;
}