module libc @feat(CUSTOM_LIBC);

import sbi;

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

fn void longjmp(JmpBuf* buffer, CInt value) @weak @cname("longjmp") @nostrip
{
	unreachable("longjmp unavailable");
}

fn CInt setjmp(JmpBuf* buffer) @weak @cname("setjmp") @nostrip
{
	unreachable("setjmp unavailable");
}

fn void* malloc(usz size) @weak @cname("malloc") @nostrip
{
	unreachable("malloc unavailable");
}

fn void* calloc(usz count, usz size) @weak @cname("calloc") @nostrip
{
	unreachable("calloc unavailable");
}

fn void free(void* ptr) @weak @cname("free") @nostrip
{
	// Do nothing
}

fn void* realloc(void* ptr, usz size) @weak @cname("realloc") @nostrip
{
	unreachable("realloc unavailable");
}

fn int fseek(CFile* stream, SeekIndex offset, int whence) @weak @cname("fseek") @nostrip
{
	unreachable("'fseek' not available.");
}

fn CFile* fopen(ZString filename, ZString mode) @weak @cname("fopen") @nostrip
{
	unreachable("'fopen' not available.");
}

fn CFile* freopen(ZString filename, ZString mode, CFile* stream) @weak @cname("freopen") @nostrip
{
	unreachable("'freopen' not available.");
}

// CRITICAL: std::io uses fwrite for output
fn usz fwrite(void* ptr, usz size, usz nmemb, CFile* stream) @cname("fwrite") @nostrip
{
	char* str = (char*)ptr;
	usz total = size * nmemb;
	for (usz i = 0; i < total; i++)
	{
		sbi::__putchar(str[i]);
	}
	return nmemb;
}

fn usz fread(void* ptr, usz size, usz nmemb, CFile* stream) @weak @cname("fread") @nostrip
{
	unreachable("'fread' not available.");
}

fn int fclose(CFile* stream) @weak @cname("fclose") @nostrip
{
	unreachable("'fclose' not available.");
}

fn int fflush(CFile* stream) @cname("fflush") @nostrip
{
	return 0;
}

fn int fputc(int c, CFile* stream) @cname("fputc") @nostrip
{
	return sbi::__putchar(c);
}

fn char* fgets(ZString str, int n, CFile* stream) @weak @cname("fgets") @nostrip
{
	unreachable("'fgets' not available.");
}

fn int fgetc(CFile* stream) @weak @cname("fgetc") @nostrip
{
	unreachable("'fgetc' not available.");
}

fn int feof(CFile* stream) @weak @cname("feof") @nostrip
{
	unreachable("'feof' not available.");
}

fn int putc(int c, CFile* stream) @cname("putc") @nostrip
{
	return sbi::__putchar(c);
}

fn int putchar(int c) @cname("putchar") @nostrip
{
	return sbi::__putchar(c);
}

fn int puts(ZString str) @cname("puts") @nostrip
{
	int i = 0;
	while (str[i] != '\0')
	{
		sbi::__putchar(str[i]);
		i++;
	}
	sbi::__putchar('\n');
	return i;
}

fn int fputs(ZString str, CFile* stream) @cname("fputs") @nostrip
{
	int i = 0;
	while (str[i] != '\0')
	{
		sbi::__putchar(str[i]);
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