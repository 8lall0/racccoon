// Adapted from the real c3 stdlib's std::atomic::types/std::atomic
// (/usr/lib/c3c/lib/std/atomic.c3) — same module names, same API shape
// for the operations kept (load/store/compare_exchange/add), but
// trimmed and made fully self-contained: user-mode binaries build with
// --use-stdlib=no (see scripts/build_user.sh), so the real module isn't
// reachable at all, and what it depends on (std::core::mem's
// AtomicOrdering/compare_exchange, std::core::types' reflection
// helpers, std::math) isn't either. The AtomicOrdering enum below is
// copied verbatim (same members, same order, so .ordinal matches what
// the $$atomic_* compiler builtins expect) rather than imported.
//
// Confirmed lowering to real RV64 'A'-extension instructions, not a
// libcall this freestanding build has nothing to link against (see
// build.sh's own comment on missing libclang_rt.builtins-riscv64):
// compare_exchange -> lr.w.aqrl/sc.w.rl, add -> amoadd.w.aqrl, plain
// load/store -> fence-wrapped ld/sd (RV64 has no lr/sc-free single
// instruction for a bare seq-consistent load/store, this is the
// correct, standard lowering for it).
module std::atomic::types;

enum AtomicOrdering : int
{
	NOT_ATOMIC,
	UNORDERED,
	RELAXED,
	ACQUIRE,
	RELEASE,
	ACQUIRE_RELEASE,
	SEQ_CONSISTENT,
}

struct Atomic <Type>
{
	Type data;
}

macro Type Atomic.load(&self, AtomicOrdering $ordering = SEQ_CONSISTENT)
{
	return $$atomic_load(&self.data, false, $ordering.ordinal, 0);
}

macro void Atomic.store(&self, Type value, AtomicOrdering $ordering = SEQ_CONSISTENT)
{
	$$atomic_store(&self.data, value, false, $ordering.ordinal, 0);
}

// Same semantics as the real std::atomic::types.Atomic.compare_exchange:
// true and *self updated to `desired` if *self == *expected; otherwise
// false and *expected updated to whatever *self actually was.
macro bool Atomic.compare_exchange(&self, Type* expected, Type desired, AtomicOrdering $success = SEQ_CONSISTENT, AtomicOrdering $failure = SEQ_CONSISTENT)
{
	Type witnessed = $$compare_exchange(&self.data, *expected, desired, true, false, $success.ordinal, $failure.ordinal, 0);
	if (witnessed == *expected) return true;
	*expected = witnessed;
	return false;
}

// Returns the previous value, before the addition — same as the real
// std::atomic::types.Atomic.add.
macro Type Atomic.add(&self, Type value, AtomicOrdering $ordering = SEQ_CONSISTENT)
{
	return $$atomic_fetch_add(&self.data, value, false, $ordering.ordinal, 0);
}

module std::atomic;
