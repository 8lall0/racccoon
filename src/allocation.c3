module kernel;

import panic;

const PAGE_SIZE = 4096;

// Must match kernel.ld's `__free_ram` reservation (`. += 64 * 1024 * 1024;`).
// __free_ram/__free_ram_end are linker symbols — only their *addresses* are
// known, and only at link time — so the bitmap's size can't be derived from
// them directly; it needs its own compile-time-constant mirror of the same
// number.
const RAM_SIZE = 64 * 1024 * 1024;

const BITS_PER_WORD = 32;
const TOTAL_PAGES   = RAM_SIZE / PAGE_SIZE;

// One bit per page over the whole __free_ram pool: 0 = free, 1 = used.
uint[TOTAL_PAGES / BITS_PER_WORD] bitmap;

fn bool bit_is_set(uint page_idx)
{
	return (bitmap[page_idx / BITS_PER_WORD] & (1u << (page_idx % BITS_PER_WORD))) != 0;
}

fn void set_bit(uint page_idx)
{
	bitmap[page_idx / BITS_PER_WORD] |= (1u << (page_idx % BITS_PER_WORD));
}

fn void clear_bit(uint page_idx)
{
	bitmap[page_idx / BITS_PER_WORD] &= ~(1u << (page_idx % BITS_PER_WORD));
}

// How many pages are currently free. SYS_MAP (entry.c3) pre-checks this
// before its per-page map loop so an alloc_pages(1) inside it can never
// hit the panic path — kernel code isn't preempted, so the count stays
// valid between the check and the allocs.
fn uint free_page_count()
{
	uint free = 0;
	for (uint i = 0; i < TOTAL_PAGES; i++)
	{
		if (!bit_is_set(i)) free++;
	}
	return free;
}

// Finds n consecutive free pages by scanning for a run of n clear bits,
// marks them used, zero-fills them, and returns the first page's
// physical address — or 0 if there's no run that long. The caller must
// check: this is the fallible primitive behind alloc_pages(). Used
// directly on the runtime allocation paths (SYS_MAP / SYS_RFORK /
// SYS_EXEC) where "out of memory" has to be a −1 to the caller, not a
// dead kernel.
//
// Addresses are uptr (pointer-sized), not uint: on RV64 a plain uint is
// only 32 bits, too narrow to hold a real physical address once pointers
// are 64-bit — see docs/devlog.md for the RV64 port this was widened for.
fn uptr try_alloc_pages(uint n)
{
	uint run_start = 0;
	uint run_len   = 0;

	for (uint i = 0; i < TOTAL_PAGES; i++)
	{
		if (bit_is_set(i))
		{
			run_len = 0;
			continue;
		}

		if (run_len == 0)
		{
			run_start = i;
		}
		run_len++;

		if (run_len == n)
		{
			for (uint j = run_start; j <= i; j++)
			{
				set_bit(j);
			}

			uptr paddr = (uptr)&__free_ram + (uptr)(run_start * PAGE_SIZE);
			mem::set((void*)paddr, 0, (sz)(n * PAGE_SIZE));
			return paddr;
		}
	}

	return 0;
}

// Infallible alloc — panics on exhaustion. For the boot-time paths
// (create_process for the six servers, setup_*_mappings) where a
// failure genuinely means the system can't run, so there's no caller
// that could do anything useful with a null.
fn uptr alloc_pages(uint n)
{
	uptr p = try_alloc_pages(n);
	if (p == 0) { panic::panic("Out of memory"); }
	return p;
}

fn void free_pages(uptr paddr, uint n)
{
	// Bounds check: a process's page table can legitimately contain
	// PAGE_U leaf entries that were never alloc_pages()'d at all — an
	// MMIO identity-mapping like diskd's VIRTIO_BLK_PADDR or sdd's
	// SD_MMIO_BASE/SD_TOP_PAGE/etc (see setup_diskd_mappings/
	// setup_sdd_mappings, process.c3), both flagged PAGE_U for the same
	// reason any other private mapping is. entry.c3's SYS_EXIT free loop
	// walks every PAGE_U leaf and frees it unconditionally, so without
	// this check, a real MMIO physical address (numerically far below
	// __free_ram on both boards) underflows `paddr - __free_ram` into a
	// huge unsigned value, producing a wildly out-of-bounds `bitmap`
	// index and corrupting unrelated kernel memory. Latent since diskd's
	// mapping was first added — never triggered before because diskd
	// never legitimately called exit() in any tested path; surfaced for
	// real once sdd's own panic-then-exit path (Milk-V Duo SD bring-up,
	// see docs/devlog.md) became the first driver to actually exit with
	// an MMIO mapping still present. A no-op here is the correct
	// behavior, not a fallback: an MMIO page was never part of this
	// allocator's pool, so there's genuinely nothing to free.
	if (paddr < (uptr)&__free_ram || paddr >= (uptr)&__free_ram_end) return;

	uint start_idx = (uint)((paddr - (uptr)&__free_ram) / PAGE_SIZE);
	for (uint j = start_idx; j < start_idx + n; j++)
	{
		clear_bit(j);
	}
}
