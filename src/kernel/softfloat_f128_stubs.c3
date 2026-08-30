module kernel;

import panic;

// racccoon builds rv64imafdc now (scripts/build.sh) — hardware F+D, so
// every f32/f64 operation is a native instruction and the ~23 old
// __*df3 / __*sf3 / __fix* / __float* compiler-rt stubs are gone.
//
// But there is NO quad (Q / f128) extension on the C906, and C3's
// std::io float formatter has one f128 → double truncation in its
// float-arg path (formatter_private.c3's float_from_any, reachable in
// principle from a %f / %e / %g / %v specifier — std.io.ll:3311,
// `fptrunc fp128 to double`). LLVM lowers that to a soft-float call.
// racccoon's own printfn calls are all %s / %d / %x, so it is never
// actually taken — same "resolve the symbol, panic loudly if a future
// change ever routes a float through printfn" deal the old stub file
// had. Just one symbol now instead of a screenful.
fn double __trunctfdf2() @export("__trunctfdf2")
{
	panic::panic("unreachable soft-float builtin: __trunctfdf2 (racccoon has no f128)");
}
