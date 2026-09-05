module stdiotest;
import std::io;
import std::core::dstring;
import std::collections::list;

// Proof-of-concept /bin program built against the REAL c3 stdlib
// (std::io, std::core::mem, std::collections) instead of
// std::nolibc — see docs/devlog.md ("std::io on racccoon") and
// user/std_racccoon/ for how, including heap.c3's SYS_MAP-backed
// allocator wired into thread_allocator. Every other /bin program
// hand-rolls its own print()/print_uint() over raw fixed-size arrays;
// this one goes through io::printn/printfn's real Formatter/DString
// machinery and a genuine heap (List, DString), at the cost of a much
// bigger image — worth it only when a program actually wants dynamic
// growth or %-style formatting, not a blanket replacement for the
// existing convention.
alias IntList = List {int};

fn void main()
{
    io::printn("stdiotest: hello from std::io");
    io::printfn("stdiotest: %d + %d = %d", 2, 3, 5);
    io::printfn("stdiotest: hex=%x", (uint)0xdeadbeef);

    // DString: dynamic string building, proves the heap allocator
    // (thread_allocator, wired by heap.c3) actually works, not just
    // fails cleanly — Formatter's plain %d/%s/%x path above never
    // touches it at all.
    DString d;
    d.init(mem);
    d.appendf("stdiotest: dstring says %d*%d=%d", 6, 7, 42);
    io::printn(d.str_view());
    d.free();

    // A real dynamically-growing collection, same heap.
    IntList nums;
    nums.init(mem);
    for (int i = 1; i <= 5; i++) { nums.push(i * i); }
    int total = 0;
    foreach (int n : nums) { total += n; }
    io::printfn("stdiotest: list sum(1..5 squared)=%d (len=%d)", total, nums.len());
    nums.free();

    // %f/%e/%g: confirmed working (2026-09-05, docs/devlog.md) — none
    // of them actually reach user/std_racccoon/trunctfdf2_stub.c3's
    // f128->double stub (an f128 conversion was the only theoretical
    // risk, per that file's own comment); kept as a real regression
    // guard now that it's a known-good path, not just an open question.
    io::printfn("stdiotest: pi~=%f e~=%e tiny~=%g", 3.14, 12345.6789, 0.0001234);
}
