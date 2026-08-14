module std::core::mem @if(env::CUSTOM_LIBC);

fn CInt __memcmp(void* s1, void* s2, usz n) @weak @export("memcmp")
{
	char* p1 = s1;
	char* p2 = s2;
	for (usz i = 0; i < n; i++, p1++, p2++)
	{
		char c1 = *p1;
		char c2 = *p2;
		if (c1 < c2) return -1;
		if (c1 > c2) return 1;
	}
	return 0;
}

fn void* __memset(void* str, CInt c, usz n) @weak @export("memset")
{
	char* p = str;
	char cc = (char)c;
	for (usz i = 0; i < n; i++, p++)
	{
		*p = cc;
	}
	return str;
}

fn void* __memcpy(void* dst, void* src, usz n) @weak @export("memcpy")
{
	char* d = dst;
	char* s = src;
	for (usz i = 0; i < n; i++, d++, s++)
	{
		*d = *s;
	}
	return dst;
}

fn void* __memmove(void* dst, void* src, usz n) @weak @export("memmove")
{
	return __memcpy(dst, src, n);
}