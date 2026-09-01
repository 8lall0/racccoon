module kernel;

import panic;

const PAGE_SIZE = 4096;

// The page bitmap's ceiling — it must be >= the largest `__free_ram`
// reservation any board's kernel.ld makes, NOT necessarily equal to any
// one of them. __free_ram/__free_ram_end are linker symbols — only their
// *addresses* are known, and only at link time — so the bitmap's size
// can't be derived from them directly; it needs its own compile-time
// constant, and it's one binary's constant shared by every board (a
// per-board `board::RAM_SIZE` would circular-import board <-> kernel).
// ram_page_count() caps the allocator to each board's *real* linker span,
// so a board whose pool is smaller than this just leaves the bitmap's
// tail words unused: QEMU's src/kernel.ld reserves 768 MiB, the Duo's
// ~59 MiB, the JH7110 / Orange Pi RV up to this ceiling out of its 2 GiB
// DRAM (docs/opi-rv-plan.md, docs/go-port-plan.md — Go's toolchain wants
// the headroom). 1920 MiB / 4 KiB / 8 = 60 KiB of BSS, negligible even on
// the 64 MiB Duo. The medany code model the kernel is built with
// (scripts/build.sh, llc -code-model=medium) sets this ceiling: every
// global reference must land within +/-2 GiB of the kernel text PC, so
// __free_ram_end can't run much past ~1.9 GiB from a kernel linked at
// DRAM_BASE + 2 MiB regardless of how much DRAM the board has. Kept just
// under 2^31 so the constant stays a plain 32-bit int.
const RAM_SIZE = 1920 * 1024 * 1024;

const BITS_PER_WORD = 32;
const TOTAL_PAGES   = RAM_SIZE / PAGE_SIZE;

// One bit per page over the whole __free_ram pool: 0 = free, 1 = used.
// Sized for the RAM_SIZE ceiling; a board with less usable free RAM
// (the Duo — see ram_page_count) just leaves the tail words unused.
uint[TOTAL_PAGES / BITS_PER_WORD] bitmap;

// The actual number of allocatable pages: the real distance between the
// linker's __free_ram and __free_ram_end, in pages, capped at
// TOTAL_PAGES (the bitmap's size). QEMU's src/kernel.ld reserves 768 MiB,
// well under TOTAL_PAGES, so the bitmap's tail words go unused there; the
// Duo's boards/duo/kernel.ld pins __free_ram_end to the real 64 MiB DRAM
// window minus the kernel image, the stack, and the reserved top 768 KiB
// — ~59 MiB. Scanning past the real span hands out addresses beyond
// physical DRAM; the zero-fill in try_alloc_pages then faults → panic.
// Only ever hit by something that genuinely exhausts RAM (oomtest).
fn uint ram_page_count()
{
	uptr span = (uptr)&__free_ram_end - (uptr)&__free_ram;
	uint pages = (uint)(span / PAGE_SIZE);
	return pages < TOTAL_PAGES ? pages : TOTAL_PAGES;
}

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
	uint limit = ram_page_count();
	for (uint i = 0; i < limit; i++)
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
// Allocation rover: alloc_scan starts here, not at page 0. Without it a
// run of sequential single-page allocs — SYS_MAP's eager per-page loop
// for a Go process mapping a ~64 MiB heap arena — is O(n²): the k-th
// alloc rescans the k already-set bits from the bottom. With the rover
// it's amortized O(1). free_page() lowers it so reclaimed space is
// reused. Same technique as fat32.c3's fat32_alloc_hint.
uint alloc_rover = 0;

// Claim the first free run of `n` contiguous pages in [lo, hi) (a run
// never crosses hi). Sets the bits, zero-fills, advances alloc_rover
// past the run, returns the physical base — or 0 if no such run.
fn uptr alloc_scan(uint lo, uint hi, uint n)
{
	uint run_start = 0;
	uint run_len   = 0;

	for (uint i = lo; i < hi; i++)
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
			alloc_rover = i + 1;

			uptr paddr = (uptr)&__free_ram + (uptr)(run_start * PAGE_SIZE);
			mem::set((void*)paddr, 0, (sz)(n * PAGE_SIZE));
			return paddr;
		}
	}

	return 0;
}

fn uptr try_alloc_pages(uint n)
{
	uint limit = ram_page_count();
	if (alloc_rover >= limit) alloc_rover = 0;

	// Scan from the rover to the end, then wrap once to cover
	// [0, rover) — a page freed below the rover is still found.
	uptr paddr = alloc_scan(alloc_rover, limit, n);
	if (paddr == 0 && alloc_rover > 0)
	{
		paddr = alloc_scan(0, alloc_rover, n);
	}
	return paddr;
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
	// Pull the rover back so the just-freed pages are reused before the
	// scan runs off the end again (a Go process exiting frees its whole
	// arena — the next one should land right back in it).
	if (start_idx < alloc_rover) alloc_rover = start_idx;
}
