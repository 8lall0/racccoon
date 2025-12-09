module libc @if(env::CUSTOM_LIBC);

import sbi;

alias memcpy = mem::__memcpy;
alias memmove = mem::__memcpy;
alias memset = mem::__memset;

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
fn void* free(void*) @weak @cname("free")
{
	unreachable("free unavailable");
}

fn void* realloc(void* ptr, usz size) @weak @cname("realloc") @nostrip
{
	unreachable("realloc unavailable");
}

fn int fseek(CFile stream, SeekIndex offset, int whence) @weak @cname("fseek") @nostrip
{
	unreachable("'fseek' not available.");
}
fn CFile fopen(ZString filename, ZString mode) @weak @cname("fopen") @nostrip
{
	unreachable("'fopen' not available.");
}

fn CFile freopen(ZString filename, ZString mode, CFile stream) @weak @cname("fopen") @nostrip
{
	unreachable("'freopen' not available.");
}

fn usz fwrite(void* ptr, usz size, usz nmemb, CFile stream) @weak @cname("fwrite") @nostrip
{
	unreachable("'fwrite' not available.");
}

fn usz fread(void* ptr, usz size, usz nmemb, CFile stream) @weak @cname("fread") @nostrip
{
	unreachable("'fread' not available.");
}

fn CFile fclose(CFile) @weak @cname("fclose") @nostrip
{
	unreachable("'fclose' not available.");
}

fn int fflush(CFile stream) @weak @cname("fflush") @nostrip
{
    return 0;
}

fn int fputc(int c, CFile stream) @weak @cname("fputc") @nostrip
{
	unreachable("'fputc' not available.");
}

fn char* fgets(ZString str, int n, CFile stream) @weak @cname("fgets") @nostrip
{
	unreachable("'fgets' not available.");
}

fn int fgetc(CFile stream) @weak @cname("fgetc") @nostrip
{
	unreachable("'fgetc' not available.");
}

fn int feof(CFile stream) @weak @cname("feof") @nostrip
{
	unreachable("'feof' not available.");
}

fn int putc(int c, CFile stream) @weak @cname("putc") @nostrip
{
	unreachable("'putc' not available.");
}

fn int putchar(int c) @weak @cname("putchar") @nostrip
{
    sbi::sbi_call(c, 0, 0, 0, 0, 0, 0, 1);
    return c;
}
fn int puts(ZString str) @weak @cname("puts") @nostrip
{
	unreachable("'puts' not available.");
}

extern fn CFile tmpfile();



