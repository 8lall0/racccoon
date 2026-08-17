module std::io @feat(CUSTOM_LIBC);
import libc;

fn bool File.isatty(File* self)
{
	return false;
}