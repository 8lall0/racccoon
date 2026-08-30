#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void w(const char *s) { write(STDERR_FILENO, s, strlen(s)); }

static void wnum(int v)
{
	char b[12];
	int i = 12;
	unsigned u = v < 0 ? (w("-"), (unsigned)-v) : (unsigned)v;
	if (!u) { w("0"); return; }
	while (u) { b[--i] = '0' + (u % 10); u /= 10; }
	write(STDERR_FILENO, b + i, 12 - i);
}

__attribute__((noreturn))
void __libc_assert_fail(const char *expr, const char *file, int line, const char *func)
{
	w(file); w(":"); wnum(line); w(": "); w(func);
	w(": assertion failed: "); w(expr); w("\n");
	abort();
}
