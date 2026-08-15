module kernel;

import panic;
import libc;
import std::io;

const PROCS_MAX     = 8; // Maximum number of processes
const PROC_UNUSED   = 0; // Unused process control structure
const PROC_RUNNABLE = 1; // Runnable process
const PROC_BLOCKED  = 2; // Waiting on SYS_IPC_RECV for a message to arrive

// 1128 = 100-byte filename + 4-byte length header + one full 1024-byte
// file (fsd's own protocol, see user/fsd.c3 — matches the File struct's
// own data capacity there, so moving file I/O out of the kernel doesn't
// shrink the max file size the old direct SYS_WRITEFILE syscall allowed).
// Comfortably covers diskd's smaller 516-byte sector protocol too — every
// process's inbox is sized for the largest thing anyone speaks over IPC,
// not per-conversation.
const MSG_MAX = 1128;
                     // yield()'s scan only matches PROC_RUNNABLE, so
                     // PROC_BLOCKED is automatically skipped without any
                     // scheduler change.

// The disk driver process (see user/diskd.c3) — 0 until it's created and
// registered by setup_diskd_mappings, checked by handle_trap before
// routing a virtio-blk PLIC interrupt to it. diskd_vq_paddr/diskd_req_paddr
// are the physical addresses of its virtqueue and request buffer,
// allocated once at diskd's creation time (see setup_diskd_mappings) and
// handed back to diskd itself via the SYS_DISKD_INFO syscall — diskd's own
// user-mode code has no other way to learn them, since it can't call
// alloc_pages() directly and its own per-page image mapping can't
// guarantee the physical contiguity DMA needs.
int  diskd_pid = 0;
uint diskd_vq_paddr;
uint diskd_req_paddr;

// The filesystem server (see user/fsd.c3) — 0 until created, consulted
// only by create_process below to populate every new process's default
// namespace. Unlike diskd, fsd is meant to be reached by ordinary
// clients (the shell), so it's addressed through namespace resolution,
// not a hardcoded pid — see the "" catch-all mount below.
int fsd_pid = 0;

const NS_MOUNTS_MAX = 4;   // Small fixed table — two real entries today
                            // ("/" -> echod, "" -> fsd), room to grow.
const NS_PREFIX_MAX = 32;  // Longest path prefix a mount entry can match.

// One binding in a process's namespace: any path starting with `prefix`
// resolves to `server_pid`. A zero server_pid marks an unused slot.
struct Mount
{
	char[NS_PREFIX_MAX] prefix;
	int                 server_pid;
}
// 8192 was enough for the syscall-only trap path (getchar/putchar), but the
// file-system call chain (handle_syscall -> fs_lookup/fs_flush ->
// read_write_disk -> virtq_kick/virtq_is_busy) overflowed it, corrupting
// adjacent Process structs in the procs[] array. Confirmed by reproducing
// with this bumped up and the corruption disappearing.
const STACK_SIZE    = 65536; // Stack size

struct Process
{
	int pid; // Process ID
	int state; // Process state: PROC_UNUSED, PROC_RUNNABLE, or PROC_BLOCKED
	uint sp; // Stack pointer
	uint* page_table;

	// Single-slot inbox: at most one pending message per process. SEND
	// doesn't block the sender even if this is already occupied (it just
	// overwrites) — a known v1 simplification, fine as long as callers
	// keep to one outstanding request at a time (which is all this phase
	// ever does). RECV blocks (PROC_BLOCKED) until has_message is true.
	bool has_message;
	int  msg_from;
	uint msg_type;
	char[MSG_MAX] msg_data;

	// Per-process namespace: path prefix -> server pid. Every process gets
	// an identical default namespace today (populated in create_process) —
	// there's no fork()/namespace inheritance yet to make private ones
	// meaningful — but the table itself already lives on the Process
	// struct, not a global, so a future sandboxed process can get a
	// restricted view later without a redesign.
	Mount[NS_MOUNTS_MAX] namespace;

	char[STACK_SIZE] stack; // Kernel stack
}

// Moved here from the now-deleted src/fs.c3 (its tar-parsing logic moved
// to user/fsd.c3, phase 5 of the microkernel plan) — these two are still
// needed kernel-side: str_copy by create_process's default namespace
// population above, str_starts_with by entry.c3's SYS_NS_RESOLVE.
fn void str_copy(char* dst, char* src, uint max)
{
	uint i = 0;
	while (src[i] != 0 && i < max - 1)
	{
		dst[i] = src[i];
		i++;
	}
	dst[i] = 0;
}

fn bool str_starts_with(char* s, char* prefix)
{
	uint i = 0;
	while (prefix[i] != 0)
	{
		if (s[i] != prefix[i]) return false;
		i++;
	}
	return true;
}

// pid -> Process*, per how create_process assigns pid = slot index + 1.
// Returns null for an out-of-range pid or a slot that isn't actually that
// process anymore (freed and possibly reused, or never used).
fn Process* proc_by_pid(int pid)
{
	if (pid < 1 || pid > PROCS_MAX) return null;
	Process* p = &procs[pid - 1];
	if (p.pid != pid || p.state == PROC_UNUSED) return null;
	return p;
}

fn void switch_context(uint* prev_sp, uint* next_sp, uint satp, uint sscratch) @naked @noinline
{
	asm(`
        addi sp, sp, -13 * 4
        sw ra,  0  * 4(sp)
        sw s0,  1  * 4(sp)
        sw s1,  2  * 4(sp)
        sw s2,  3  * 4(sp)
        sw s3,  4  * 4(sp)
        sw s4,  5  * 4(sp)
        sw s5,  6  * 4(sp)
        sw s6,  7  * 4(sp)
        sw s7,  8  * 4(sp)
        sw s8,  9  * 4(sp)
        sw s9,  10 * 4(sp)
        sw s10, 11 * 4(sp)
        sw s11, 12 * 4(sp)
        sw sp, (a0)

        sfence.vma
        csrw satp, a2
        sfence.vma
        csrw sscratch, a3

        lw sp, (a1)
        lw ra,  0  * 4(sp)
        lw s0,  1  * 4(sp)
        lw s1,  2  * 4(sp)
        lw s2,  3  * 4(sp)
        lw s3,  4  * 4(sp)
        lw s4,  5  * 4(sp)
        lw s5,  6  * 4(sp)
        lw s6,  7  * 4(sp)
        lw s7,  8  * 4(sp)
        lw s8,  9  * 4(sp)
        lw s9,  10 * 4(sp)
        lw s10, 11 * 4(sp)
        lw s11, 12 * 4(sp)
        addi sp, sp, 13 * 4
        ret
    `);
}

const SSTATUS_SPIE = (1 << 5);
const SSTATUS_SUM   = (1 << 18); // let S-mode access U-mode pages (needed for syscalls like readfile/writefile that dereference user pointers directly)

fn void user_entry() @naked @noinline @noreturn
{
	// USER_BASE (kernel.c3's const of the same name) and
	// SSTATUS_SPIE|SSTATUS_SUM (0x40020, this file's consts above)
	// hardcoded: compile-time asm() only supports %s substitution, so the
	// constants can't be interpolated here. USER_BASE must also match
	// user/user.ld's base address.
	asm(`
        li t0, 0x1000000
        csrw sepc, t0
        li t1, 0x40020
        csrw sstatus, t1
        sret
    `);
}

// rfork's child resume point — see SYS_RFORK in entry.c3, which builds
// the 32-word block this expects at the top of the child's kernel stack
// before its first switch_context: a 31-word copy of the parent's own
// Trap_frame at the moment of the rfork ecall (word 30 is the saved
// *user-mode* sp — see Trap_frame's own layout in entry.c3 — restored
// last, same as kernel_entry's own tail), with a0 overwritten to 0 (the
// child's return value) and its own sepc as a 32nd word, since sepc is a
// single CPU CSR with nothing to inherit it from at this point — unlike
// kernel_entry's tail, which relies on write_sepc() having already set
// the CSR earlier in the *same* trap, this function is the child's very
// first instruction ever, on a different logical flow entirely.
//
// Deliberately a separate function from kernel_entry's own restore tail,
// not a shared label jumped into from two places: touching kernel_entry
// at all is exactly the kind of change this project's history (the
// stvec alignment saga, the sscratch reentrancy bug) says to avoid
// unless there's no other way. A few duplicated lines here is cheaper
// than that risk.
fn void fork_entry() @naked @noinline @noreturn
{
	asm(`
        addi t0, sp, 4 * 31
        lw t0, 0(t0)
        csrw sepc, t0

        lw ra,  4 * 0(sp)
        lw gp,  4 * 1(sp)
        lw tp,  4 * 2(sp)
        lw t0,  4 * 3(sp)
        lw t1,  4 * 4(sp)
        lw t2,  4 * 5(sp)
        lw t3,  4 * 6(sp)
        lw t4,  4 * 7(sp)
        lw t5,  4 * 8(sp)
        lw t6,  4 * 9(sp)
        lw a0,  4 * 10(sp)
        lw a1,  4 * 11(sp)
        lw a2,  4 * 12(sp)
        lw a3,  4 * 13(sp)
        lw a4,  4 * 14(sp)
        lw a5,  4 * 15(sp)
        lw a6,  4 * 16(sp)
        lw a7,  4 * 17(sp)
        lw s0,  4 * 18(sp)
        lw s1,  4 * 19(sp)
        lw s2,  4 * 20(sp)
        lw s3,  4 * 21(sp)
        lw s4,  4 * 22(sp)
        lw s5,  4 * 23(sp)
        lw s6,  4 * 24(sp)
        lw s7,  4 * 25(sp)
        lw s8,  4 * 26(sp)
        lw s9,  4 * 27(sp)
        lw s10, 4 * 28(sp)
        lw s11, 4 * 29(sp)
        lw sp,  4 * 30(sp)
        sret
    `);
}

Process[PROCS_MAX] procs; // All process control structures.

fn Process* create_process(void* image, uint image_size)
{
	// Find an unused process control structure.
	Process* proc = null;
	int i;
	for (i = 0; i < PROCS_MAX; i++)
	{
		if (procs[i].state == PROC_UNUSED)
		{
			proc = &procs[i];
			break;
		}
	}

	if (!proc)
	{
		panic::panic("no free process slots");
	}

	uint* sp = (uint*)&proc.stack;
	sp += STACK_SIZE / 4;
	for (int j = 0; j < 12; j++)
	{
		*(--sp) = 0;
	}
	// Setting RA
	*(--sp) = (uint)&user_entry;

	uint* page_table = (uint*)alloc_pages(1);
	for (uint paddr = (uint)&__kernel_base; paddr < (uint)&__free_ram_end; paddr += PAGE_SIZE)
	{
		map_page(page_table, paddr, paddr, PAGE_R | PAGE_W | PAGE_X);
	}
	// virtio-blk MMIO is deliberately NOT mapped here anymore: diskd (see
	// user/diskd.c3) is now the sole owner of the device, mapped only
	// into its own page table by setup_diskd_mappings below. No other
	// process — including the kernel's own S-mode code — touches it
	// directly; everyone else talks to diskd over IPC.

	// PLIC registers: handle_trap's plic_claim()/plic_complete() run
	// under whichever process's page table happens to be active when the
	// interrupt arrives — could be any process, or the kernel's own
	// bare-mode boot code — since it's S-mode code reached from inside a
	// trap, not something any one process specifically owns (unlike the
	// virtio-blk MMIO above, which now belongs to diskd alone). Three
	// separate pages, not a range — see plic.c3.
	map_page(page_table, PLIC_PRIORITY_PAGE, PLIC_PRIORITY_PAGE, PAGE_R | PAGE_W);
	map_page(page_table, PLIC_ENABLE_PAGE, PLIC_ENABLE_PAGE, PAGE_R | PAGE_W);
	map_page(page_table, PLIC_CLAIM_PAGE, PLIC_CLAIM_PAGE, PAGE_R | PAGE_W);

	// Copy the process image into freshly allocated user pages, page by page.
	char* img = image;
	for (uint off = 0; off < image_size; off += PAGE_SIZE)
	{
		uint page          = alloc_pages(1);
		uint remaining     = image_size - off;
		uint copy_size     = remaining < PAGE_SIZE ? remaining : PAGE_SIZE;

		mem::copy((void*)page, img + off, (sz)copy_size);
		map_page(page_table, USER_BASE + off, page, PAGE_U | PAGE_R | PAGE_W | PAGE_X);
	}

	// Initialize fields.
	proc.pid = i + 1;
	proc.state = PROC_RUNNABLE;
	proc.sp = (uint)sp;
	proc.page_table = page_table;

	// Default namespace: everything under "/" resolves to echod, which is
	// always pid 2 (see kernel.c3 — it's the first process spawned after
	// idle, deterministically). This is the same placeholder binding
	// shell.c3's p9test used to hardcode directly; now it's a real
	// per-process kernel lookup instead.
	str_copy(&proc.namespace[0].prefix[0], "/", NS_PREFIX_MAX);
	proc.namespace[0].server_pid = 2;

	// "" is a catch-all — str_starts_with treats an empty prefix as
	// matching everything, and its zero length always loses a longest-
	// prefix-match tie against "/" above — so this only ever wins for
	// paths that don't start with "/" at all: plain filenames like
	// "hello.txt", exactly how user.c3's fs_read/fs_write call
	// ns_resolve(). Routes them to fsd (0 — "unused" — for any process
	// created before fsd exists, namely idle/echod/diskd themselves,
	// none of which ever need this).
	str_copy(&proc.namespace[1].prefix[0], "", NS_PREFIX_MAX);
	proc.namespace[1].server_pid = fsd_pid;

	for (int m = 2; m < NS_MOUNTS_MAX; m++)
	{
		proc.namespace[m].server_pid = 0;
	}

	return proc;
}

// Called once, right after create_process() spawns diskd (see kernel.c3),
// to give it what it needs to own the virtio-blk device: MMIO access, plus
// a virtqueue and request buffer diskd can actually use for DMA.
//
// The virtqueue/request buffer can't just be ordinary bytes within
// diskd's own process image: create_process's per-page image-copy loop
// calls alloc_pages(1) once per page, so consecutive *virtual* pages of
// an image have no guaranteed relationship between their *physical*
// backing — but the device's QUEUE_PFN and descriptor addr fields are
// physical, and the legacy virtio layout derives the avail/used ring
// locations from a single physical base, so this memory has to be one
// physically contiguous run. alloc_pages(n) (unlike the per-page image
// loop) guarantees that.
//
// Mapped identity (vaddr == paddr) rather than at some other chosen
// virtual address: that way the same number diskd's own pointers resolve
// to *is* the physical address the device needs, and diskd never needs a
// virtual-to-physical translation of its own — it just gets told the
// number once, via SYS_DISKD_INFO (src/entry.c3), and uses it both ways.
fn void setup_diskd_mappings(Process* proc)
{
	map_page(proc.page_table, VIRTIO_BLK_PADDR, VIRTIO_BLK_PADDR, PAGE_U | PAGE_R | PAGE_W);

	uint vq_pages = (uint)(mem::aligned_offset((sz)Virtio_virtq::size, PAGE_SIZE) / PAGE_SIZE);
	uint vq_paddr = alloc_pages(vq_pages);
	for (uint off = 0; off < vq_pages * PAGE_SIZE; off += PAGE_SIZE)
	{
		map_page(proc.page_table, vq_paddr + off, vq_paddr + off, PAGE_U | PAGE_R | PAGE_W);
	}

	uint req_pages = (uint)(mem::aligned_offset((sz)Virtio_blk_req::size, PAGE_SIZE) / PAGE_SIZE);
	uint req_paddr = alloc_pages(req_pages);
	for (uint off = 0; off < req_pages * PAGE_SIZE; off += PAGE_SIZE)
	{
		map_page(proc.page_table, req_paddr + off, req_paddr + off, PAGE_U | PAGE_R | PAGE_W);
	}

	diskd_pid       = proc.pid;
	diskd_vq_paddr  = vq_paddr;
	diskd_req_paddr = req_paddr;
}

Process* current_proc; // Currently running process
Process* idle_proc;    // Idle process

fn void yield() @noinline
{
	Process* next = idle_proc;
	for (int i = 0; i < PROCS_MAX; i++)
	{
		Process* proc = &procs[(current_proc.pid + i) % PROCS_MAX];
		if (proc.state == PROC_RUNNABLE && proc.pid > 0)
		{
			next = proc;
			break;
		}
	}

	if (next == current_proc)
	{
		return;
	}

	Process* prev = current_proc;
	current_proc = next;

	switch_context(&prev.sp, &next.sp, ((uint)next.page_table >> 12) | 0x80000000, (uint)&next.stack + STACK_SIZE);
}