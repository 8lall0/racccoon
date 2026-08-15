module kernel;

import panic;

// LLVM lowers every float/double operation to a runtime call on a
// soft-float target (rvimac has no F/D extension) — these are the
// standard compiler-rt symbol names it expects to find. Racccoon never
// uses floats anywhere in its own code, but std::io's generic printf
// formatter (formatter_private.c3, part of the monolithic std.io.o
// object) has a float-formatting code path compiled in unconditionally
// — reachable in principle from vprintf's runtime format-specifier
// dispatch, so the *symbols* have to resolve at link time even though
// this kernel's own io::printfn calls (all %s/%d/%x) never actually
// take that path at runtime.
//
// The real fix would be linking against a riscv64 compiler-rt/libgcc,
// but no prebuilt one exists in this project's toolchain (/opt/riscv
// only has a riscv32 copy — see docs/devlog.md for the RV64 port this
// was needed for), and building one from source is out of scope for
// getting this port booting. These stubs are a deliberate stand-in:
// each one panics with its own name if ever actually called, which
// would only happen if some future change starts passing a float
// argument to io::printfn — a real bug, and one this makes loud and
// immediate rather than silently miscomputing.
macro void @softfloat_stub(String $name)
{
	panic::panic(@sprintf("unreachable soft-float builtin: %s (racccoon doesn't use floats)", $name));
}

fn double __adddf3()      @export("__adddf3")      { @softfloat_stub("__adddf3"); }
fn double __subdf3()      @export("__subdf3")      { @softfloat_stub("__subdf3"); }
fn double __muldf3()      @export("__muldf3")      { @softfloat_stub("__muldf3"); }
fn double __divdf3()      @export("__divdf3")      { @softfloat_stub("__divdf3"); }
fn float  __addsf3()      @export("__addsf3")      { @softfloat_stub("__addsf3"); }
fn float  __subsf3()      @export("__subsf3")      { @softfloat_stub("__subsf3"); }
fn float  __mulsf3()      @export("__mulsf3")      { @softfloat_stub("__mulsf3"); }
fn float  __divsf3()      @export("__divsf3")      { @softfloat_stub("__divsf3"); }
fn double __extendsfdf2() @export("__extendsfdf2") { @softfloat_stub("__extendsfdf2"); }
fn double __trunctfdf2()  @export("__trunctfdf2")  { @softfloat_stub("__trunctfdf2"); }
fn double __floatsidf()   @export("__floatsidf")   { @softfloat_stub("__floatsidf"); }
fn double __floatunsidf() @export("__floatunsidf") { @softfloat_stub("__floatunsidf"); }
fn double __floatdidf()   @export("__floatdidf")   { @softfloat_stub("__floatdidf"); }
fn double __floatundidf() @export("__floatundidf") { @softfloat_stub("__floatundidf"); }
fn int    __fixdfsi()     @export("__fixdfsi")     { @softfloat_stub("__fixdfsi"); }
fn uint   __fixunsdfsi()  @export("__fixunsdfsi")  { @softfloat_stub("__fixunsdfsi"); }
fn int    __eqdf2()       @export("__eqdf2")       { @softfloat_stub("__eqdf2"); }
fn int    __nedf2()       @export("__nedf2")       { @softfloat_stub("__nedf2"); }
fn int    __ltdf2()       @export("__ltdf2")       { @softfloat_stub("__ltdf2"); }
fn int    __gtdf2()       @export("__gtdf2")       { @softfloat_stub("__gtdf2"); }
fn int    __nesf2()       @export("__nesf2")       { @softfloat_stub("__nesf2"); }
fn int    __ltsf2()       @export("__ltsf2")       { @softfloat_stub("__ltsf2"); }
fn int    __gtsf2()       @export("__gtsf2")       { @softfloat_stub("__gtsf2"); }
