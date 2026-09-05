module trunctfdf2_stub @feat(CUSTOM_LIBC);
import rcsys;

// Userspace counterpart to src/kernel/softfloat_f128_stubs.c3: racccoon
// has no f128 (Q ext) on the C906, but std::io's float formatter has
// one f128 -> double truncation in its float-arg path
// (formatter_private.c3's float_from_any, reachable in principle from
// a %f / %e / %g specifier), and LLVM lowers that to a soft-float
// call regardless of whether the path is ever actually taken. Same
// "resolve the symbol, die loudly if a future change ever routes an
// f128 through a formatter" deal as the kernel's stub — a std::io
// program using only %s/%d/%x/%v (as this project's own do) never hits
// this.
fn double __trunctfdf2() @export("__trunctfdf2")
{
    rcsys::rc_exit(134);
}
