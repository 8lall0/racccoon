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

// Finds n consecutive free pages by scanning for a run of n clear bits,
// marks them used, and returns the physical address of the first page.
fn uint alloc_pages(uint n)
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

			uint paddr = (uint)&__free_ram + run_start * PAGE_SIZE;
			mem::set((void*)paddr, 0, (sz)(n * PAGE_SIZE));
			return paddr;
		}
	}

	panic::panic("Out of memory");
}

fn void free_pages(uint paddr, uint n)
{
	uint start_idx = (paddr - (uint)&__free_ram) / PAGE_SIZE;
	for (uint j = start_idx; j < start_idx + n; j++)
	{
		clear_bit(j);
	}
}
