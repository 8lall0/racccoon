module user;

// Shared decimal digit-formatting logic. Used to be duplicated near-
// verbatim three times — user.c3's own print_uint, procd.c3's own
// procd_format_uint, shell.c3's own killtest_format_pid — because each
// binary is a separate build unit (scripts/build_user.sh) with nothing
// shared between them, so it kept getting hand-copied instead of
// written once. Not a port of anything from the real c3 stdlib (unlike
// user/atomic.c3/user/mem.c3): std::core::string's own integer-
// formatting lives inside std::io's Formatter, an allocator/stream-
// based subsystem with no small standalone piece that maps onto this
// codebase's plain char*-buffer style — this is racccoon's own logic,
// just finally written in one place instead of three.
//
// Writes n's decimal digits into buf, NOT null-terminated — callers
// that need a C-string null-terminate themselves, matching every
// existing call site's own convention. Returns the digit count. Never
// more than 10 digits (uint::max is 4294967295).
fn int format_uint(uint n, char* buf)
{
    if (n == 0)
    {
        buf[0] = '0';
        return 1;
    }
    char[10] digits @noinit;
    int count = 0;
    while (n > 0)
    {
        digits[count] = (char)('0' + n % 10);
        n /= 10;
        count++;
    }
    for (int k = 0; k < count; k++)
    {
        buf[k] = digits[count - 1 - k];
    }
    return count;
}
