module rcsys_heap @feat(CUSTOM_LIBC);
import std::core::mem, std::core::mem::allocators;
import rcsys;

// A REAL, working allocator for std::core::mem::allocators::
// thread_allocator — without it, the real stdlib defaults to
// &NULL_ALLOCATOR (base_allocator() in allocators_heap.c3, picked
// whenever env::LIBC is false, which --link-libc=no always makes it
// here) — a valid Allocator that FAILS CLEANLY (mem::OUT_OF_MEMORY)
// rather than crashing, which is why plain %s/%d/%x formatting works
// with no allocator at all (Formatter's small-case path never calls
// it), but real allocation (std::collections, DString, %f/%v, ...)
// needs something that actually succeeds. rt_entry.c3 wires this in
// via mem::@scoped (thread_allocator itself is @private to the real
// stdlib's own allocators module — only reachable through its own
// public helpers, not a direct assignment from outside).
//
// Rather than writing a free-list heap by hand, this wraps racccoon's
// SYS_MAP (there's no malloc/brk) as a MemoryAllocFn and hands it to
// std::core::mem::allocators::SimpleHeapAllocator — a real allocator
// already in the stdlib, built for exactly this ("environments where
// there isn't any native libc malloc, and it has to be emulated from
// a memory region", its own doc comment's wording — the same shape
// WASM's own allocator uses, mem.c3:669 wasm_allocator).
const uint HEAP_BLOCK_MIN = 65536;   // 64 KiB per SYS_MAP call — a few big blocks beat many small ones

SimpleHeapAllocator heap;

fn char[]? heap_block(sz bytes) @private
{
    uint want = (uint)bytes;
    if (want < HEAP_BLOCK_MIN) { want = HEAP_BLOCK_MIN; }
    void* p = rcsys::rc_map_pages(want);
    if (!p) { return mem::OUT_OF_MEMORY~; }
    return ((char*)p)[:want];
}

// Called from rt_entry.c3's _start, before `main` — every std::io
// program built this way gets a working heap with no setup of its own.
fn void heap_init() @export("rcsys_heap_init")
{
    heap.init(&heap_block);
}
