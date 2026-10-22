module kernel;

// Named shared-memory segments — Plan 9's segattach, racccoon-sized.
//
// SYS_SEGATTACH(name, size) maps a named run of physical pages into the
// caller's address space, creating (and zero-filling) it the first time
// that name is used. A second process attaching the same name gets the
// same physical pages — that's the sharing. The pages are mapped
// PAGE_SHARED (page.c3), so the existing teardown paths (proc_destroy,
// exec's address-space clear) never free them as the process's own, and
// rfork's copy walk maps them into the child instead of copying.
// Lifetime is a reference count of *attachments*; the last detach (or
// the last attached address space going away) frees the pages.
//
// Attachments are keyed by address space (page table), not process: two
// RFMEM threads share one table and therefore one attachment, and a
// non-RFMEM rfork child gets its own (seg_dup_attachments).
//
// Permission: the creator's uid owns a segment; root or the owner may
// attach it. Names are global, like srv names.

const int  SEG_MAX        = 16;
const int  SEG_ATTACH_MAX = 64;
const int  SEG_NAME_MAX   = 16;   // NUL included
const uint SEG_MAX_PAGES  = 1024; // 4 MiB per segment

struct Segment
{
	bool used;
	char[SEG_NAME_MAX] name;
	uptr paddr;      // one physically contiguous, zero-filled run
	uint npages;
	int  refs;       // live attachments
	int  owner_uid;
}

struct Seg_attach
{
	bool   used;
	int    seg;      // index into segments
	ulong* table;    // the address space it's mapped into
	uptr   vaddr;
}

Segment[SEG_MAX] segments;
Seg_attach[SEG_ATTACH_MAX] seg_attachments;

fn void seg_unref(int si) @noinline
{
	Segment* sg = &segments[si];
	sg.refs--;
	if (sg.refs <= 0)
	{
		free_pages(sg.paddr, sg.npages);
		sg.used = false;
		sg.refs = 0;
	}
}

fn int seg_attach_free_slots() @noinline
{
	int n = 0;
	for (int i = 0; i < SEG_ATTACH_MAX; i++) { if (!seg_attachments[i].used) { n++; } }
	return n;
}

fn int seg_attachments_of(ulong* table) @noinline
{
	int n = 0;
	for (int i = 0; i < SEG_ATTACH_MAX; i++)
	{
		if (seg_attachments[i].used && seg_attachments[i].table == table) { n++; }
	}
	return n;
}

// Every attachment in `table` goes away — the address space is being
// torn down (proc_destroy) or wiped (exec). The PTEs themselves are the
// caller's business (cleared or freed along with the table).
fn void seg_release_table(ulong* table) @noinline
{
	for (int i = 0; i < SEG_ATTACH_MAX; i++)
	{
		Seg_attach* a = &seg_attachments[i];
		if (a.used && a.table == table)
		{
			a.used = false;
			seg_unref(a.seg);
		}
	}
}

// A non-RFMEM rfork just mapped the parent's PAGE_SHARED pages into
// `child` at the same addresses: give the child its own attachment (and
// reference) for each segment the parent had. The caller checked
// seg_attach_free_slots() >= seg_attachments_of(parent) first.
fn void seg_dup_attachments(ulong* parent, ulong* child) @noinline
{
	for (int i = 0; i < SEG_ATTACH_MAX; i++)
	{
		Seg_attach* a = &seg_attachments[i];
		if (!a.used || a.table != parent) { continue; }
		for (int j = 0; j < SEG_ATTACH_MAX; j++)
		{
			Seg_attach* b = &seg_attachments[j];
			if (b.used) { continue; }
			b.used = true;
			b.seg = a.seg;
			b.table = child;
			b.vaddr = a.vaddr;
			segments[a.seg].refs++;
			break;
		}
	}
}

// SYS_SEGATTACH: a0 = name (NUL-terminated, < SEG_NAME_MAX), a1 = size in
// bytes (needed to create; 0 = attach whatever exists). Returns the
// vaddr it's mapped at, or -1. Attaching a name this address space
// already has just returns the existing mapping.
fn void sys_segattach(Trap_frame* f) @noinline
{
	char* uname = (char*)(uptr)f.a0;
	ulong size = f.a1;
	char[SEG_NAME_MAX] name;
	int i = 0;
	for (; i < SEG_NAME_MAX; i++)
	{
		if (!user_range_valid(current_proc.page_table, (uptr)(uname + i), 1, false))
		{
			f.a0 = (ulong)(-1);
			return;
		}
		name[i] = uname[i];
		if (name[i] == 0) { break; }
	}
	if (i == 0 || i == SEG_NAME_MAX) { f.a0 = (ulong)(-1); return; }

	int si = -1;
	for (int k = 0; k < SEG_MAX; k++)
	{
		if (segments[k].used && str_eq(&segments[k].name[0], &name[0])) { si = k; break; }
	}

	if (si >= 0)
	{
		Segment* sg = &segments[si];
		if (current_proc.uid != 0 && current_proc.uid != sg.owner_uid) { f.a0 = (ulong)(-1); return; }
		if (size > (ulong)sg.npages * PAGE_SIZE) { f.a0 = (ulong)(-1); return; }
		for (int k = 0; k < SEG_ATTACH_MAX; k++)
		{
			Seg_attach* a = &seg_attachments[k];
			if (a.used && a.seg == si && a.table == current_proc.page_table)
			{
				f.a0 = (ulong)a.vaddr;
				return;
			}
		}
	}
	if (seg_attach_free_slots() == 0) { f.a0 = (ulong)(-1); return; }

	bool created = false;
	if (si < 0)
	{
		if (size == 0 || size > (ulong)SEG_MAX_PAGES * PAGE_SIZE) { f.a0 = (ulong)(-1); return; }
		for (int k = 0; k < SEG_MAX; k++) { if (!segments[k].used) { si = k; break; } }
		if (si < 0) { f.a0 = (ulong)(-1); return; }
		uint np = (uint)((size + PAGE_SIZE - 1) / PAGE_SIZE);
		uptr pa = try_alloc_pages(np); // zero-filled
		if (pa == 0) { f.a0 = (ulong)(-1); return; }
		Segment* nsg = &segments[si];
		nsg.used = true;
		for (int k = 0; k < SEG_NAME_MAX; k++) { nsg.name[k] = name[k]; if (name[k] == 0) { break; } }
		nsg.paddr = pa;
		nsg.npages = np;
		nsg.refs = 0;
		nsg.owner_uid = current_proc.uid;
		created = true;
	}

	Segment* sg = &segments[si];
	uptr base = user_map_place(current_proc.heap_top, (uptr)sg.npages * PAGE_SIZE);
	if (base == 0)
	{
		if (created) { sg.refs = 1; seg_unref(si); }
		f.a0 = (ulong)(-1);
		return;
	}
	for (uint p = 0; p < sg.npages; p++)
	{
		if (!try_map_page(current_proc.page_table, base + (uptr)p * PAGE_SIZE, sg.paddr + (uptr)p * PAGE_SIZE,
			PAGE_U | PAGE_R | PAGE_W | PAGE_SHARED))
		{
			// Out of memory for a page-table page: undo what's mapped.
			for (uint q = 0; q < p; q++)
			{
				ulong* t0 = walk_to_leaf_table(current_proc.page_table, base + (uptr)q * PAGE_SIZE);
				t0[((base + (uptr)q * PAGE_SIZE) >> 12) & 0x1ff] = 0;
			}
			flush_tlb();
			if (created) { sg.refs = 1; seg_unref(si); }
			f.a0 = (ulong)(-1);
			return;
		}
	}
	flush_tlb();
	current_proc.heap_top = base + (uptr)sg.npages * PAGE_SIZE;

	for (int k = 0; k < SEG_ATTACH_MAX; k++)
	{
		Seg_attach* a = &seg_attachments[k];
		if (a.used) { continue; }
		a.used = true;
		a.seg = si;
		a.table = current_proc.page_table;
		a.vaddr = base;
		break;
	}
	sg.refs++;
	f.a0 = (ulong)base;
}

// SYS_SEGDETACH: a0 = the vaddr SYS_SEGATTACH returned. Unmaps it from
// this address space and drops the reference. 0, or -1 if nothing is
// attached there. (The address range stays reserved; touching it again
// demand-maps fresh zero pages, like any SYS_MAP'd address.)
fn void sys_segdetach(Trap_frame* f) @noinline
{
	uptr va = (uptr)f.a0;
	for (int k = 0; k < SEG_ATTACH_MAX; k++)
	{
		Seg_attach* a = &seg_attachments[k];
		if (!a.used || a.table != current_proc.page_table || a.vaddr != va) { continue; }
		Segment* sg = &segments[a.seg];
		for (uint p = 0; p < sg.npages; p++)
		{
			uptr pv = va + (uptr)p * PAGE_SIZE;
			ulong* t0 = walk_to_leaf_table(current_proc.page_table, pv);
			t0[(pv >> 12) & 0x1ff] = 0;
		}
		flush_tlb();
		a.used = false;
		seg_unref(a.seg);
		f.a0 = 0;
		return;
	}
	f.a0 = (ulong)(-1);
}
