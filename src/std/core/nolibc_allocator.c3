module std::core::mem::allocator @feat(CUSTOM_LIBC);
import std::io;
import std::os;
import libc;

<*
 The LibcAllocator is a wrapper around malloc to conform to the Allocator interface.
*>
typedef LibcAllocator (Allocator) = uptr;
const LibcAllocator LIBC_ALLOCATOR = { };

fn void*? LibcAllocator.acquire(&self, sz bytes, AllocInitType init_type, sz alignment) @dynamic
{
	return null;
}

fn void*? LibcAllocator.resize(&self, void* old_ptr, sz new_bytes, sz alignment) @dynamic
{
	return null;
}

fn void LibcAllocator.release(&self, void* old_ptr, bool aligned) @dynamic
{
	libc::free(old_ptr);
}