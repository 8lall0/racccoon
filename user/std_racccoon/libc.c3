module libc @feat(CUSTOM_LIBC);

// Userspace counterpart to src/libc/libc.c3 (the kernel's own
// custom-libc override, same @feat(CUSTOM_LIBC) hook the real c3
// stdlib's std::libc/std::io reach for when link-libc is off) — same
// shape, `sbi::__putchar` swapped for rcsys::rc_putchar (SYS_PUTCHAR):
// the kernel calls straight into the console UART, a /bin program has
// to go through the syscall. See docs/devlog.md ("std::io on
// racccoon") for why this file exists at all instead of a real libc.
import rcsys;

alias memcpy = mem::__memcpy;
alias memmove = mem::__memcpy;
alias memset = mem::__memset;

// Create dummy CFile structures and pointers
CFile __stdout_struct;
CFile __stderr_struct;
CFile __stdin_struct;

// Export as global pointers - these MUST be non-weak
CFile* stdout @export("stdout") = &__stdout_struct;
CFile* stderr @export("stderr") = &__stderr_struct;
CFile* stdin @export("stdin")   = &__stdin_struct;

// No stub below may be `unreachable()`: at -O2 that compiles to zero
// bytes, the linker folds the empty bodies onto their neighbours, and a
// call silently runs fwrite or fputc instead (devlog 2026-10-21). They
// fail the way C says instead, or really work for stdin.
//
// The only stream that can be read is stdin — SYS_GETCHAR, which is the
// console or the pipe the shell wired up. std::io's stdin File carries a
// null handle on this target, so null counts as stdin too.
bool stdin_eof;

fn bool is_stdin(CFile* stream) @private
{
	return stream == null || stream == stdin;
}

fn void die(String what) @private
{
	rcsys::rc_write(what.ptr, what.len);
	rcsys::rc_write(" unavailable on racccoon\n", 25);
	rcsys::rc_exit(127);
}

fn void longjmp(JmpBuf* buffer, CInt value) @weak @cname("longjmp") @nostrip
{
	die("longjmp");
}

fn CInt setjmp(JmpBuf* buffer) @weak @cname("setjmp") @nostrip
{
	return 0;   // nothing can longjmp back (see longjmp)
}

fn void* malloc(usz size) @weak @cname("malloc") @nostrip
{
	return null;
}

fn void* calloc(usz count, usz size) @weak @cname("calloc") @nostrip
{
	return null;
}

fn void free(void* ptr) @weak @cname("free") @nostrip
{
	// Do nothing
}

fn void* realloc(void* ptr, usz size) @weak @cname("realloc") @nostrip
{
	return null;
}

fn int fseek(CFile* stream, SeekIndex offset, int whence) @weak @cname("fseek") @nostrip
{
	return -1;
}

fn CFile* fopen(ZString filename, ZString mode) @weak @cname("fopen") @nostrip
{
	return null;
}

fn CFile* freopen(ZString filename, ZString mode, CFile* stream) @weak @cname("freopen") @nostrip
{
	return null;
}

// CRITICAL: std::io uses fwrite for output
fn usz fwrite(void* ptr, usz size, usz nmemb, CFile* stream) @cname("fwrite") @nostrip
{
	rcsys::rc_write((char*)ptr, size * nmemb);
	return nmemb;
}

fn usz fread(void* ptr, usz size, usz nmemb, CFile* stream) @weak @cname("fread") @nostrip
{
	if (!is_stdin(stream) || size == 0) return 0;
	// C semantics: fill all of it unless stdin ends first.
	char* p = ptr;
	usz want = size * nmemb;
	usz got = 0;
	while (got < want)
	{
		int c = fgetc(stream);
		if (c < 0) break;
		p[got++] = (char)c;
	}
	return got / size;
}

fn int fclose(CFile* stream) @weak @cname("fclose") @nostrip
{
	return 0;   // nothing to release: no fopen, and stdin/stdout stay open
}

fn int fflush(CFile* stream) @cname("fflush") @nostrip
{
	return 0;
}

fn int fputc(int c, CFile* stream) @cname("fputc") @nostrip
{
	rcsys::rc_putchar((char)c);
	return c;
}

fn char* fgets(ZString str, int n, CFile* stream) @weak @cname("fgets") @nostrip
{
	if (n <= 0) return null;
	int i = 0;
	while (i < n - 1)
	{
		int c = fgetc(stream);
		if (c < 0) break;
		str[i++] = (char)c;
		if (c == '\n') break;
	}
	if (i == 0) return null;
	str[i] = '\0';
	return (char*)str;
}

fn int fgetc(CFile* stream) @weak @cname("fgetc") @nostrip
{
	if (!is_stdin(stream) || stdin_eof) return -1;
	int c = rcsys::rc_getchar();
	if (c < 0) stdin_eof = true;
	return c;
}

fn int feof(CFile* stream) @weak @cname("feof") @nostrip
{
	return is_stdin(stream) && stdin_eof ? 1 : 0;
}

fn int putc(int c, CFile* stream) @cname("putc") @nostrip
{
	rcsys::rc_putchar((char)c);
	return c;
}

fn int putchar(int c) @cname("putchar") @nostrip
{
	rcsys::rc_putchar((char)c);
	return c;
}

fn int puts(ZString str) @cname("puts") @nostrip
{
	int i = 0;
	while (str[i] != '\0')
	{
		rcsys::rc_putchar(str[i]);
		i++;
	}
	rcsys::rc_putchar('\n');
	return i;
}

fn int fputs(ZString str, CFile* stream) @cname("fputs") @nostrip
{
	int i = 0;
	while (str[i] != '\0')
	{
		rcsys::rc_putchar(str[i]);
		i++;
	}
	return i;
}

extern fn CFile tmpfile();
extern fn void exit(CInt status);

fn usz strlen(char* s) @cname("strlen") @nostrip @weak
{
	char* p = s;
	while (*p) p++;
	return (usz)(p - s);
}
