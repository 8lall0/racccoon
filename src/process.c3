module kernel;

import panic;
import libc;
import std::io;
import board;

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
uptr diskd_vq_paddr;
uptr diskd_req_paddr;

// The SD driver process (see user/sdd.c3) — Duo's real-hardware
// counterpart to diskd above, mutually exclusive with it at runtime (see
// board::HAS_SD_BLOCK/HAS_VIRTIO_BLOCK, kernel.c3). No vq/req physical
// addresses to track here: sdd talks to its SDHCI controller in PIO mode,
// not DMA, so it needs no physically-contiguous buffer handed back the
// way diskd does — see setup_sdd_mappings below.
int sdd_pid = 0;

// The filesystem server (see user/fsd.c3) — 0 until created, consulted
// only by create_process below to populate every new process's default
// namespace. Unlike diskd, fsd is meant to be reached by ordinary
// clients (the shell), so it's addressed through namespace resolution,
// not a hardcoded pid — see the "" catch-all mount below.
int fsd_pid = 0;

// A second, simultaneously-mounted fsd instance (see kernel.c3's own
// spawn code, gated on board::HAS_SECOND_FS_PARTITION) — reachable under
// the "/2/" prefix instead of fsd_pid's "" catch-all. Exactly two static
// mounts, not a general N — see docs/devlog.md for why a fully dynamic
// runtime mount syscall wasn't needed to solve the actual problem this
// was built for (testing FAT32 and ext2 simultaneously without
// physically swapping board::FS_PARTITION_START_SECTOR and reflashing).
int fsd2_pid = 0;

const NS_MOUNTS_MAX = 4;   // Small fixed table — three real entries now
                            // ("/" -> echod, "" -> fsd, "/2/" -> fsd2),
                            // one spare.
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
	uptr sp; // Stack pointer
	ulong* page_table; // Sv39 top-level (root) table — see page.c3

	// Bumped every time this slot is (re)used — never reset, persists
	// across a slot's unused periods. Exists purely so SYS_JOIN
	// (entry.c3) can tell "the process I was waiting for exited" apart
	// from "this pid got reused by an unrelated process, coincidentally
	// landing in the same slot" — pids alone can't distinguish those,
	// since a slot's next occupant always gets the exact same pid
	// (pid = slot index + 1). See docs/devlog.md for the race this
	// closes.
	uint generation;

	// Single-slot inbox, now a true two-sided rendezvous (src/entry.c3's
	// SYS_IPC_SEND/RECV/POLL): SEND blocks until the target's inbox is
	// actually free before depositing (never silently overwrites an
	// unconsumed message), then blocks *again* until the receiver has
	// genuinely consumed what it just deposited — RECV/POLL wake it via
	// msg_acked, targeted at the specific sender (msg_from), not just by
	// the inbox looking empty again (which could just as easily mean a
	// different sender's message arrived and got consumed instead).
	// Earlier versions of this kernel had SEND never block at all — a
	// documented v1 simplification, safe only by accident of nothing yet
	// sending concurrently; tightened once rfork/threadcreate made real
	// concurrent senders possible (see docs/devlog.md).
	bool has_message;
	int  msg_from;
	uint msg_type;
	char[MSG_MAX] msg_data;
	bool msg_acked; // set by the receiver once *this* process's own pending send has been consumed

	// Per-process namespace: path prefix -> server pid. Every process gets
	// an identical default namespace today (populated in create_process) —
	// there's no fork()/namespace inheritance yet to make private ones
	// meaningful — but the table itself already lives on the Process
	// struct, not a global, so a future sandboxed process can get a
	// restricted view later without a redesign.
	Mount[NS_MOUNTS_MAX] namespace;

	// fsd-only: which partition SYS_FS_PARTITION_INFO (entry.c3) hands
	// back to *this specific* process. Per-process, not a plain kernel
	// global the way diskd_vq_paddr etc. are — those stay globals because
	// there's only ever one diskd; now that two fsd instances can exist
	// simultaneously, each needs its own answer to the same syscall. Set
	// by setup_fsd_mappings() right after create_process() spawns an fsd,
	// same "extra per-process setup after the generic call" pattern as
	// setup_diskd_mappings()/setup_sdd_mappings() below.
	uint fs_partition_start;

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

// Also moved from the deleted src/fs.c3 — needed again by
// SYS_NS_UNMOUNT (entry.c3), which unmounts by exact prefix match, not
// the longest-prefix match SYS_NS_RESOLVE uses.
fn bool str_eq(char* a, char* b)
{
	uint i = 0;
	while (a[i] != 0 && b[i] != 0)
	{
		if (a[i] != b[i]) return false;
		i++;
	}
	return a[i] == b[i];
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

// RV64 port: sd/ld instead of sw/lw, 8*N offsets instead of 4*N — every
// register (including satp/sscratch's own carrier args) is now 8 bytes,
// not 4. Same 13-word (ra + s0-s11) shape as the RV32 version, just twice
// the byte stride. satp is a genuine ulong here (Sv39's MODE field lives
// in the top 4 bits of a 64-bit register, not RV32's single top bit — see
// page.c3's SATP_SV39), not merely "an address happens to be pointer-sized".
fn void switch_context(uptr* prev_sp, uptr* next_sp, ulong satp, uptr sscratch) @naked @noinline
{
	asm(`
        addi sp, sp, -13 * 8
        sd ra,  0  * 8(sp)
        sd s0,  1  * 8(sp)
        sd s1,  2  * 8(sp)
        sd s2,  3  * 8(sp)
        sd s3,  4  * 8(sp)
        sd s4,  5  * 8(sp)
        sd s5,  6  * 8(sp)
        sd s6,  7  * 8(sp)
        sd s7,  8  * 8(sp)
        sd s8,  9  * 8(sp)
        sd s9,  10 * 8(sp)
        sd s10, 11 * 8(sp)
        sd s11, 12 * 8(sp)
        sd sp, (a0)

        sfence.vma
        csrw satp, a2
        sfence.vma
        csrw sscratch, a3

        ld sp, (a1)
        ld ra,  0  * 8(sp)
        ld s0,  1  * 8(sp)
        ld s1,  2  * 8(sp)
        ld s2,  3  * 8(sp)
        ld s3,  4  * 8(sp)
        ld s4,  5  * 8(sp)
        ld s5,  6  * 8(sp)
        ld s6,  7  * 8(sp)
        ld s7,  8  * 8(sp)
        ld s8,  9  * 8(sp)
        ld s9,  10 * 8(sp)
        ld s10, 11 * 8(sp)
        ld s11, 12 * 8(sp)
        addi sp, sp, 13 * 8
        ret
    `);
}

const SSTATUS_SPIE = (1 << 5);
const SSTATUS_SUM   = (1 << 18); // let S-mode access U-mode pages (needed for syscalls like readfile/writefile that dereference user pointers directly)
                                  // Same bit positions on RV64: sstatus's low, commonly-used bits are defined identically across XLEN in the priv spec.

fn void user_entry() @naked @noinline @noreturn
{
	// USER_BASE (kernel.c3's const of the same name) and
	// SSTATUS_SPIE|SSTATUS_SUM (0x40020, this file's consts above)
	// hardcoded: compile-time asm() only supports %s substitution, so the
	// constants can't be interpolated here. USER_BASE must also match
	// user/user.ld's base address. `li` with a small constant like this
	// compiles the same way regardless of XLEN, so this function is
	// otherwise unchanged from the RV32 version.
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
//
// RV64 port: sd/ld and 8*N offsets, same as switch_context above — the
// 32-word block is now 256 bytes, not 124.
fn void fork_entry() @naked @noinline @noreturn
{
	asm(`
        addi t0, sp, 8 * 31
        ld t0, 0(t0)
        csrw sepc, t0

        ld ra,  8 * 0(sp)
        ld gp,  8 * 1(sp)
        ld tp,  8 * 2(sp)
        ld t0,  8 * 3(sp)
        ld t1,  8 * 4(sp)
        ld t2,  8 * 5(sp)
        ld t3,  8 * 6(sp)
        ld t4,  8 * 7(sp)
        ld t5,  8 * 8(sp)
        ld t6,  8 * 9(sp)
        ld a0,  8 * 10(sp)
        ld a1,  8 * 11(sp)
        ld a2,  8 * 12(sp)
        ld a3,  8 * 13(sp)
        ld a4,  8 * 14(sp)
        ld a5,  8 * 15(sp)
        ld a6,  8 * 16(sp)
        ld a7,  8 * 17(sp)
        ld s0,  8 * 18(sp)
        ld s1,  8 * 19(sp)
        ld s2,  8 * 20(sp)
        ld s3,  8 * 21(sp)
        ld s4,  8 * 22(sp)
        ld s5,  8 * 23(sp)
        ld s6,  8 * 24(sp)
        ld s7,  8 * 25(sp)
        ld s8,  8 * 26(sp)
        ld s9,  8 * 27(sp)
        ld s10, 8 * 28(sp)
        ld s11, 8 * 29(sp)
        ld sp,  8 * 30(sp)
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

	uptr* sp = (uptr*)&proc.stack;
	sp += STACK_SIZE / 8;
	for (int j = 0; j < 12; j++)
	{
		*(--sp) = 0;
	}
	// Setting RA
	*(--sp) = (uptr)&user_entry;

	ulong* page_table = (ulong*)alloc_pages(1);
	for (uptr paddr = (uptr)&__kernel_map_base; paddr < (uptr)&__free_ram_end; paddr += PAGE_SIZE)
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
	map_device_page(page_table, board::PLIC_PRIORITY_PAGE, board::PLIC_PRIORITY_PAGE, PAGE_R | PAGE_W);
	map_device_page(page_table, board::PLIC_ENABLE_PAGE, board::PLIC_ENABLE_PAGE, PAGE_R | PAGE_W);
	map_device_page(page_table, board::PLIC_CLAIM_PAGE, board::PLIC_CLAIM_PAGE, PAGE_R | PAGE_W);
	map_device_page(page_table, board::PLIC_PENDING_PAGE, board::PLIC_PENDING_PAGE, PAGE_R | PAGE_W);

	// Copy the process image into freshly allocated user pages, page by page.
	char* img = image;
	for (uint off = 0; off < image_size; off += PAGE_SIZE)
	{
		uptr page          = alloc_pages(1);
		uint remaining     = image_size - off;
		uint copy_size     = remaining < PAGE_SIZE ? remaining : PAGE_SIZE;

		mem::copy((void*)page, img + off, (sz)copy_size);
		map_page(page_table, (uptr)USER_BASE + (uptr)off, page, PAGE_U | PAGE_R | PAGE_W | PAGE_X);
	}

	// Initialize fields.
	proc.pid = i + 1;
	proc.generation++;
	proc.state = PROC_RUNNABLE;
	proc.sp = (uptr)sp;
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

	// "/2/" — the second, simultaneously-mounted fsd instance (see
	// fsd2_pid's own comment above). Same "harmless 0 for any process
	// created before it exists" pattern as namespace[1] — SYS_NS_RESOLVE
	// (entry.c3) already skips any mount with server_pid == 0.
	str_copy(&proc.namespace[2].prefix[0], "/2/", NS_PREFIX_MAX);
	proc.namespace[2].server_pid = fsd2_pid;

	for (int m = 3; m < NS_MOUNTS_MAX; m++)
	{
		proc.namespace[m].server_pid = 0;
	}

	proc.fs_partition_start = 0; // meaningful only once setup_fsd_mappings() sets it

	return proc;
}

// Called once, right after create_process() spawns an fsd instance (see
// kernel.c3 — called for both the first and, if board::
// HAS_SECOND_FS_PARTITION, the second), to tell it which partition it
// owns. No MMIO/paging work needed here, unlike setup_diskd_mappings/
// setup_sdd_mappings below — fsd never touches hardware directly, it
// only needs this one fact, handed back via SYS_FS_PARTITION_INFO
// (entry.c3) reading current_proc.fs_partition_start.
fn void setup_fsd_mappings(Process* proc, uint partition_start)
{
	proc.fs_partition_start = partition_start;
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
	map_device_page(proc.page_table, VIRTIO_BLK_PADDR, VIRTIO_BLK_PADDR, PAGE_U | PAGE_R | PAGE_W);

	uint vq_pages = (uint)(mem::aligned_offset((sz)Virtio_virtq::size, PAGE_SIZE) / PAGE_SIZE);
	uptr vq_paddr = alloc_pages(vq_pages);
	for (uint off = 0; off < vq_pages * PAGE_SIZE; off += PAGE_SIZE)
	{
		map_page(proc.page_table, vq_paddr + off, vq_paddr + off, PAGE_U | PAGE_R | PAGE_W);
	}

	uint req_pages = (uint)(mem::aligned_offset((sz)Virtio_blk_req::size, PAGE_SIZE) / PAGE_SIZE);
	uptr req_paddr = alloc_pages(req_pages);
	for (uint off = 0; off < req_pages * PAGE_SIZE; off += PAGE_SIZE)
	{
		map_page(proc.page_table, req_paddr + off, req_paddr + off, PAGE_U | PAGE_R | PAGE_W);
	}

	diskd_pid       = proc.pid;
	diskd_vq_paddr  = vq_paddr;
	diskd_req_paddr = req_paddr;
}

// Called once, right after create_process() spawns sdd (see kernel.c3),
// to give it access to the SDHCI controller's MMIO registers. Identity-
// mapped for the same reason as diskd's virtio-blk MMIO above — not that
// it matters for translation here (PIO never needs sdd to hand a physical
// address to the device), just kept consistent with this codebase's one
// existing MMIO-mapping convention. No virtqueue/request-buffer
// allocation, no SYS_*_INFO syscall needed: unlike diskd, sdd never has
// to tell the kernel-allocated DMA buffer's physical address to a device,
// because there isn't one — block data is read/written one 32-bit word at
// a time through the SDHCI buffer-data-port register, into/out of
// ordinary memory already inside sdd's own process image.
fn void setup_sdd_mappings(Process* proc)
{
	map_device_page(proc.page_table, board::SD_MMIO_BASE, board::SD_MMIO_BASE, PAGE_U | PAGE_R | PAGE_W);

	// Pad/power/clock one-time bring-up registers (see board.c3's own
	// comment on these three) — separate pages from SD_MMIO_BASE and from
	// each other.
	map_device_page(proc.page_table, board::SD_TOP_PAGE, board::SD_TOP_PAGE, PAGE_U | PAGE_R | PAGE_W);
	map_device_page(proc.page_table, board::SD_PINMUX_PAGE, board::SD_PINMUX_PAGE, PAGE_U | PAGE_R | PAGE_W);
	map_device_page(proc.page_table, board::SD_CLOCK_PAGE, board::SD_CLOCK_PAGE, PAGE_U | PAGE_R | PAGE_W);

	sdd_pid = proc.pid;
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

	switch_context(&prev.sp, &next.sp, ((ulong)(uptr)next.page_table >> 12) | SATP_SV39, (uptr)&next.stack + STACK_SIZE);
}
