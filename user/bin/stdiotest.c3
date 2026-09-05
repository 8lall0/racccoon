module stdiotest;
import std::io;

// Proof-of-concept /bin program built against the REAL c3 stdlib
// (std::io) instead of std::nolibc — see docs/devlog.md ("std::io on
// racccoon") and user/std_racccoon/ for how. Every other /bin program
// hand-rolls its own print()/print_uint() straight over racccoon's
// syscalls; this one goes through io::printn/io::printfn's real
// Formatter/DString machinery instead, at the cost of a much bigger
// image (~165 KiB vs a few hundred bytes) — worth it only when a
// program actually wants %-style formatting, not a blanket
// replacement for the existing convention.
fn void main()
{
    io::printn("stdiotest: hello from std::io");
    io::printfn("stdiotest: %d + %d = %d", 2, 3, 5);
    io::printfn("stdiotest: hex=%x", (uint)0xdeadbeef);
}
