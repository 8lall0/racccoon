module kernel;

import panic;
import libc;
import std::io;
import board;

// Was 8 — too tight even before the second fsd instance: 6 permanent
// boot processes (idle/echod/diskd-or-sdd/fsd/fsd2/shell) left only 2
// spare for every test command's own children/threads combined, and
// racetest alone needs 2 (its two racing threadcreate() threads) on top
// of whatever rforktest/sandboxtest's own still-live children are
// already holding. Root-caused a misleading "racetest: a=0 b=0" result
// (looked like IPC/rendezvous corruption, wasn't) to exactly this: no
// free slots left meant threadcreate() silently returned -1 for both
// threads, and join() on a pid that never existed returns immediately —
// see docs/devlog.md. 16 gives real headroom: the 6 permanent processes
// plus up to 10 concurrent test/child/thread slots, costing an extra
// 8 * STACK_SIZE (512KB) of static kernel memory — negligible against
// the 64MB DRAM budget on both QEMU and the Duo (whose own linker
// script already sizes free_ram against whatever's left over, so it
// self-adjusts rather than risking an overflow).
const PROCS_MAX     = 16; // Maximum number of processes
const PROC_UNUSED   = 0; // Unused process control structure
const PROC_RUNNABLE = 1; // Runnable process
const PROC_BLOCKED  = 2; // Waiting on SYS_IPC_RECV for a message to arrive

// Every process's IPC inbox (Process.msg_data). Sized for the largest
// thing anyone speaks over IPC, not per-conversation. 8 KiB: raised from
// 1128 (= 100-byte name + header + one 1024-byte file block) so bulk
// transfers — FS_READ/FS_WRITE payloads, and diskd's new multi-sector
// batches (up to 15 × 512 B + header) — carry ~8x more per round trip.
// Cost: PROCS_MAX (16) inboxes × 8 KiB = 128 KiB kernel BSS. Must stay
// == user.c3's FS_MSG_MAX; DISKD_MSG_MAX (user/fs/fsd.c3, user/block/
// diskd.c3) must stay <= this.
const MSG_MAX = 8192;
                     // yield()'s scan only matches PROC_RUNNABLE, so
                     // PROC_BLOCKED is automatically skipped without any
                     // scheduler change.

// The disk driver process (see user/diskd.c3). diskd_vq_paddr/
// diskd_req_paddr are the physical addresses of its virtqueue and
// request buffer, allocated once at diskd's creation time (see
// setup_diskd_mappings) and handed back to diskd itself via the
// SYS_DISKD_INFO syscall — diskd's own user-mode code has no other way
// to learn them, since it can't call alloc_pages() directly and its own
// per-page image mapping can't guarantee the physical contiguity DMA
// needs. Its PLIC interrupt is routed to it via the Irq_route table
// below (registered by setup_diskd_mappings).
uptr diskd_vq_paddr;
uptr diskd_req_paddr;

// sdd (see user/sdd.c3) is Duo's real-hardware counterpart to diskd,
// mutually exclusive with it at runtime (board::HAS_SD_BLOCK/
// HAS_VIRTIO_BLOCK, kernel.c3). Its PLIC source is routed via the
// Irq_route table below.
// sdd's SDMA staging buffer — one identity-mapped, uncached page,
// allocated at spawn (setup_sdd_mappings) and handed back via
// SYS_SDD_INFO. Same pattern/reasoning as usbd_dma_paddr: the SDHCI
// SDMA engine's own address register needs a real physical address and
// sdd can't learn its virtual pages' physical backing otherwise. sdd
// only ever moves one 512-byte block per request, so one page is
// plenty. 0 until sdd is spawned (Duo only — HAS_SD_BLOCK).
uptr sdd_dma_paddr;

// usbd's own single-page DMA buffer (Phase 2: control transfers over
// the DWC2 host channels) — same pattern as diskd_vq_paddr/
// diskd_req_paddr above: allocated once at usbd's creation time
// (setup_usbd_mappings below), identity-mapped into its own page
// table, handed back via SYS_USBD_INFO. One page is comfortably enough
// for control-transfer payloads this phase needs (an 8-byte SETUP
// packet, an 18-byte device descriptor, a handful-of-bytes hub
// descriptor, a 4-byte port status) — nothing here approaches 4KB.
uptr usbd_dma_paddr;

// ethd's own single-page DMA region (Ethernet Phase 2: real packet
// TX/RX) — one TX descriptor, one RX descriptor, one TX buffer, one RX
// buffer, back to back (user/net/dwmac.c3's own eth_dma_init() knows
// the fixed offsets) — same pattern as usbd_dma_paddr above, allocated
// once at ethd's creation time (setup_ethd_mappings below), uncached-
// mapped (map_device_page, not map_page — same real-DMA-cache-
// incoherency reasoning as usbd_dma_paddr's own comment; ethd is the
// first driver doing genuine DMA against real Duo hardware since
// usbd), handed back via SYS_ETHD_INFO.
uptr ethd_dma_paddr;

// The virtio-net driver process (see user/net/netd.c3) — QEMU only
// (board::HAS_VIRTIO_NET). A real pair of virtqueues, unlike ethd —
// virtio-net's spec requires an RX and TX queue configured before
// DRIVER_OK. Fully poll-driven (netd busy-polls used.index), so no
// Irq_route entry.
uptr netd_rxq_paddr;
uptr netd_txq_paddr;
// netd's own packet-buffer page (Ethernet Phase 2) — RX buffer at
// offset 0, TX buffer right after (user/net/netd.c3's own fixed
// offsets), each big enough for a legacy virtio-net header (10 bytes)
// plus a full Ethernet frame. Cacheable map_page(), same as the
// virtqueues above and for the same reason — QEMU-only, no real
// cache-incoherency to hit.
uptr netd_pktbuf_paddr;

// --- Interrupt-driven driver IRQ routing -----------------------------
// Replaces the per-device `if (irq == board::IRQ_X && X_pid != 0)`
// branches that used to accumulate in handle_trap, and the pid-switch
// in SYS_DRIVER_IRQ_ARM. Each driver that services a device PLIC source
// registers ONE route from its setup_*_mappings below — it knows its
// own pid and its board::IRQ_* constant right there. Adding another
// interrupt-driven driver (ethd RX, gpiod) is then a one-line
// irq_route_register() call plus arming the source in board::plic_init;
// no handle_trap or syscall edit.
//
// handle_trap looks the claimed IRQ up here, wakes the owning process
// with the DISKD_IRQ_NOTIFY sentinel — reusing that driver's single-
// slot IPC inbox, which is safe because a driver only ever waits for
// this notify right after kicking its device, never with an unconsumed
// client request sitting in the inbox (see user/diskd.c3's loop) — and
// then, for a `level` source (device status line stays asserted until
// the driver clears its own status register, and this SoC re-traps at
// sret while a source is still pending), disables it; the driver
// re-arms via SYS_DRIVER_IRQ_ARM before its next wait. Edge/latched
// sources (virtio-mmio, acked through the virtio ISR register) register
// level=false and are left enabled.
const int IRQ_ROUTE_MAX = 8;
struct Irq_route
{
	uint irq;
	int  pid;
	bool level;
	bool used;
}
Irq_route[IRQ_ROUTE_MAX] irq_routes;

// irq 0 is the "device not present on this board" sentinel (board::
// IRQ_USB etc. are 0 on QEMU) and also plic_claim()'s spurious return —
// never a real route. A repeat register for the same IRQ (driver
// respawn) overwrites in place.
fn void irq_route_register(uint irq, int pid, bool level)
{
	if (irq == 0 || pid == 0) { return; }
	for (int i = 0; i < IRQ_ROUTE_MAX; i++)
	{
		if (irq_routes[i].used && irq_routes[i].irq == irq)
		{
			irq_routes[i].pid   = pid;
			irq_routes[i].level = level;
			return;
		}
	}
	for (int i = 0; i < IRQ_ROUTE_MAX; i++)
	{
		if (!irq_routes[i].used)
		{
			irq_routes[i].irq   = irq;
			irq_routes[i].pid   = pid;
			irq_routes[i].level = level;
			irq_routes[i].used  = true;
			return;
		}
	}
}

fn Irq_route* irq_route_by_irq(uint irq)
{
	if (irq == 0) { return null; }
	for (int i = 0; i < IRQ_ROUTE_MAX; i++)
	{
		if (irq_routes[i].used && irq_routes[i].irq == irq) { return &irq_routes[i]; }
	}
	return null;
}

fn Irq_route* irq_route_by_pid(int pid)
{
	if (pid == 0) { return null; }
	for (int i = 0; i < IRQ_ROUTE_MAX; i++)
	{
		if (irq_routes[i].used && irq_routes[i].pid == pid) { return &irq_routes[i]; }
	}
	return null;
}

// The filesystem server (see user/fsd.c3) — 0 until created, consulted
// only by create_process below to populate every new process's default
// namespace. Unlike diskd, fsd is meant to be reached by ordinary
// clients (the shell), so it's addressed through namespace resolution,
// not a hardcoded pid — see the "" catch-all mount below.
int fsd_pid = 0;

// The IPC test/demo server (user/echod.c3) — spawned first of all, so it
// used to be guaranteed pid 2 and the default namespace hardcoded that.
// Captured here now (kernel.c3 sets it) and read into namespace[0] like
// every other server, so echod can move slots / be respawned by the
// supervisor without anything breaking.
int echod_pid = 0;

// The block-storage driver (diskd on QEMU, sdd on the Duo — mutually
// exclusive). fsd's only client; fsd used to hardcode its pid as 3.
// Handed to fsd via SYS_FS_PARTITION_INFO now (kernel.c3 sets it at
// spawn). 0 on a board with no block device.
int storage_pid = 0;

// A second, simultaneously-mounted fsd instance (see kernel.c3's own
// spawn code, gated on board::HAS_SECOND_FS_PARTITION) — reachable under
// the "/2/" prefix instead of fsd_pid's "" catch-all. Exactly two static
// mounts, not a general N — see docs/devlog.md for why a fully dynamic
// runtime mount syscall wasn't needed to solve the actual problem this
// was built for (testing FAT32 and ext2 simultaneously without
// physically swapping board::FS_PARTITION_START_SECTOR and reflashing).
int fsd2_pid = 0;

// The process-info server (see user/procd.c3) — 0 until created,
// reachable under the "/proc/" prefix. Unlike fsd/fsd2, spawned
// unconditionally on every board (kernel.c3) — it has no storage
// hardware dependency, just SYS_PROC_INFO, which every process can
// already call.
int procd_pid = 0;

// The per-process environment-variable server (see user/envd.c3) — 0
// until created, reachable under the "/env/" prefix. Same "no storage
// hardware dependency, spawned unconditionally" reasoning as procd_pid
// above: envd only ever needs SYS_IPC_RECV_GEN/SYS_PROC_INFO, which
// every process can already reach regardless of board.
int envd_pid = 0;

const NS_MOUNTS_MAX = 16;  // Five static entries at boot ("/srv/echo/" ->
                            // echod, "" -> fsd, "/2/" -> fsd2, "/proc/" ->
                            // procd, "/env/" -> envd) plus headroom for
                            // SYS_NS_MOUNT / SYS_NS_BIND to add runtime ones
                            // — including union members (`bind -a`, several
                            // entries sharing one prefix), which want more
                            // than the old 8 gave. Was 8, was 5.
const NS_PREFIX_MAX = 32;  // Longest path prefix a mount entry can match.
const NS_TARGET_MAX = 64;  // Longest rewrite target (Mount.target) — deeper
                            // than a prefix (`/usr/somelongname/bin`), so its
                            // own size, not NS_PREFIX_MAX's.

// A small, kernel-global (not per-process — discoverable *by name*,
// unlike Mount below) registry of servers that have posted themselves via
// SYS_SRV_POST (src/entry.c3) — the "srv" half of the real Plan 9
// post+mount two-step SYS_NS_MOUNT (also src/entry.c3) is the other half
// of. Deliberately separate from Mount/namespace: posting is global and
// name-keyed ("any process, anywhere, that knows the name can find it"),
// mounting is per-process and path-keyed (today's existing namespace
// model, unchanged) — the two only meet at SYS_NS_MOUNT, which looks a
// name up here and adds a *path* binding into the calling process's own
// namespace, same as create_process's static population already does,
// just at runtime and by explicit request instead of unconditionally.
const SRV_MAX = 8;        // Small fixed table, same sizing philosophy as NS_MOUNTS_MAX.
const SRV_NAME_MAX = 16;  // Short identifiers ("echo2"), not paths — no need for NS_PREFIX_MAX's 32.

// pid == 0 marks an unused slot, same convention as Mount.server_pid.
// generation is captured at post time and re-checked at every
// SYS_NS_MOUNT lookup, same generation-safety pattern
// Mount.server_generation's own comment explains — a posting process that
// has since exited and had its slot reused must never be silently handed
// back as if it were still the same server.
struct Srv_entry
{
	char[SRV_NAME_MAX] name;
	int                pid;
	uint               generation;
}
Srv_entry[SRV_MAX] srv_table;

// One binding in a process's namespace: any path starting with `prefix`
// resolves to `server_pid`. A zero server_pid marks an unused slot.
//
// server_generation closes a real hazard found while building the
// second, simultaneously-mounted fsd (docs/devlog.md): server_pid alone
// is a plain pid snapshot taken once at the resolving process's own
// creation time, never refreshed. If the original target process later
// exits and its slot gets reused (create_process's own first-free-slot
// scan doesn't pin a slot against reuse just because some other
// process's stale namespace still names its old pid), server_pid can
// start silently matching whatever unrelated process now occupies that
// slot — worst case, the resolving process's own pid, which deadlocks
// SYS_IPC_SEND. server_generation records the target's Process.generation
// at the moment this entry was bound; SYS_NS_RESOLVE (entry.c3) requires
// a live match on both pid and generation before handing server_pid
// back, the same "this exact instance, not a reused slot" distinction
// SYS_JOIN already relies on for its own, different purpose.
// MNT_CREATE: in a union (several Mounts sharing one prefix), this is the
// member that receives file/dir creation — Plan 9's `bind -c`. At most one
// per prefix; when none is flagged, creation falls to the first member.
const uint MNT_CREATE = 1;

struct Mount
{
	char[NS_PREFIX_MAX] prefix;
	int                 server_pid;
	uint                server_generation;
	// Path rewrite: after `prefix` is stripped from a resolving path, this
	// is prepended before the server sees the remainder. "" (the common
	// case, every boot-seeded mount) = identity, i.e. exactly the old
	// "strip the prefix, send the bare remainder" behaviour. Non-empty for
	// a `bind <path> <prefix>` that aliases one subtree onto another
	// within the same server — see docs/bin-layout.md.
	char[NS_TARGET_MAX] target;
	// Union support: several Mount entries may share one `prefix`; array
	// order is search order. flags carries MNT_CREATE. 0 for a plain
	// single mount.
	uint                flags;
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

	// This process's own correct resume address, restored into the real
	// sepc CSR right before handle_trap (entry.c3) returns — not relied
	// on to survive untouched in the single, non-banked hardware sepc
	// register across any yield() a trap's own handling might call.
	// Needed for real preemption (a timer interrupt calling yield() mid-
	// handling): before this field existed, sepc was only ever written
	// once, immediately before an *uninterrupted* sret (no yield()
	// between the write and the sret, true of every existing blocking-
	// syscall yield() loop) — a real correctness bug waiting to happen
	// the moment that stopped being true. See docs/devlog.md.
	ulong saved_sepc;

	// Next free user virtual address for SYS_MAP (entry.c3) — a bump
	// pointer just past this process's mapped image (+ argv for an
	// exec()'d one). Grows upward, never shrinks; every page it hands
	// out is PAGE_U so proc_destroy's page walk frees it on exit. Set by
	// create_process / sys_exec; 0 until then (SYS_MAP checks). Bounded
	// per process (HEAP_MAX_BYTES) so a runaway map can't OOM the kernel.
	uptr heap_top;

	// The bottom of the lazily-mapped SYS_MAP region: heap_top's value
	// right after the image + argv are mapped. SYS_MAP hands out address
	// space between map_floor and heap_top without allocating any
	// physical pages; a page fault in [map_floor, heap_top) demand-maps
	// one zero page (entry.c3's try_lazy_fault). Everything below
	// map_floor (the image, argv) is eagerly mapped, so a fault there is
	// a real bug. Set by create_process / sys_exec alongside heap_top.
	uptr map_floor;

	// FP register file save slot: f0-f31 as raw 64-bit bit patterns
	// [0..31], then fcsr [32]. Written by fp_save() / read by fp_restore()
	// (below), which yield() calls to bracket every switch_context —
	// switch_context is @naked and preserves no FP regs, and the C906's
	// f-registers are a single non-banked set, so a preempted FP
	// computation would otherwise be silently clobbered by the next
	// process's FP use. Eager (every switch), not lazy — see yield().
	ulong[33] fp_area;

	// Set (to the user-space futex word's address) while this process is
	// PROC_BLOCKED inside SYS_FUTEX_WAIT, cleared back to 0 the instant
	// SYS_FUTEX_WAKE wakes it — see src/entry.c3's own cases for both.
	// 0 the rest of the time (every other PROC_BLOCKED reason, e.g.
	// SYS_IPC_RECV, leaves this untouched at its reset value).
	uptr futex_addr;

	// Bumped every time this slot is (re)used — never reset, persists
	// across a slot's unused periods. Exists purely so SYS_JOIN
	// (entry.c3) can tell "the process I was waiting for exited" apart
	// from "this pid got reused by an unrelated process, coincidentally
	// landing in the same slot" — pids alone can't distinguish those,
	// since a slot's next occupant always gets the exact same pid
	// (pid = slot index + 1). See docs/devlog.md for the race this
	// closes.
	uint generation;

	// 0 means "no parent" — the state every create_process()'d process
	// starts in (echod, fsd, a respawned shell, ...), explicitly reset
	// there on every call since 0 is never a valid pid but a reused slot
	// could otherwise leak a previous occupant's real parent_pid. Set to
	// the forking process's own (pid, generation) only by SYS_RFORK
	// (src/entry.c3), right alongside where it already populates
	// everything else about the child. Exists for user/envd.c3's own
	// lazy env-inheritance (SYS_PARENT_INFO, entry.c3) — parent_generation
	// is what lets a caller confirm the named parent is still the exact
	// instance it forked from, same staleness guard as
	// Mount.server_generation/Srv_entry.generation elsewhere.
	int  parent_pid;
	uint parent_generation;

	// This process's owner — 0 (root) for every create_process()'d
	// boot-time server, explicitly set there for the same "explicit, not
	// relied-on zero-init" reason as parent_pid above. SYS_RFORK
	// (entry.c3) inherits this into the child unchanged; SYS_EXEC doesn't
	// touch it at all, same as pid/namespace. The only way it ever
	// changes after that is SYS_SETUID, and only while still 0 — see its
	// own comment. Gates SYS_KILL (root or same-uid only) and
	// SYS_SRV_POST's reclaim-an-existing-name case; deliberately doesn't
	// touch SYS_IPC_SEND/RECV or SYS_NS_MOUNT — see docs/devlog.md for
	// why those stay open.
	int uid;

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

	// Monotonic count of IPC messages this process has actually consumed
	// (ipc_recv / ipc_recv_gen / ipc_call reply / ipc_poll, and a
	// driver's IRQ-notify via ipc_poll). The supervisor watchdog
	// (src/supervisor.c3) samples it each tick: a server with has_message
	// stuck true is only "wedged" if this hasn't advanced either — a
	// driver hammered with thousands of requests between ticks is busy,
	// not hung, even if it happens to have one unconsumed at the sample.
	uint ipc_progress;

	// Set to the peer's (pid, generation) while this process is blocked
	// inside SYS_IPC_SEND / SYS_IPC_REPLY waiting on that peer — 0/stale
	// the rest of the time (only read while ipc_wait_pid != 0). If the
	// peer exits or is killed mid-rendezvous, sys_exit / sys_kill's
	// sweep sets ipc_peer_died on us and marks us RUNNABLE; the
	// send/reply loop then returns -1 instead of blocking forever on a
	// rendezvous that can never complete. See docs/roadmap.md §5.
	int  ipc_wait_pid;
	uint ipc_wait_generation;
	bool ipc_peer_died;

	// True for the whole duration of a SYS_IPC_CALL — reserves this
	// process's inbox so only ipc_wait_pid (the call target) can write
	// it, and the reply can't be pre-empted by a stray ipc_send from a
	// third party (which just waits in its own phase-A loop until the
	// call completes). Replaces user-space p9_call's old P9_STRAY bounce.
	bool in_call_reply_wait;

	uint msg_from_generation; // sender's own Process.generation, captured at delivery — lets
	                          // a receiver that intends to reply later (SYS_IPC_RECV_GEN/
	                          // SYS_IPC_REPLY, src/entry.c3) confirm msg_from still names the
	                          // same process instance it received this message from, closing
	                          // the reply-side counterpart of the stale-pid hazard
	                          // Mount.server_generation/SYS_JOIN already close elsewhere.
	uint msg_type;
	char[MSG_MAX] msg_data;
	bool msg_acked; // set by the receiver once *this* process's own pending send has been consumed

	// An interrupt-driven driver's pending device-completion notify —
	// SEPARATE from the inbox above, so routing an IRQ can never clobber
	// (or be clobbered by) a real client request. service_pending_external_irq()
	// (entry.c3) sets it; the driver's SYS_IPC_POLL wait reports it as a
	// DISKD_IRQ_NOTIFY and clears it. Was routed through has_message /
	// msg_type; that collided once SYS_IPC_POLL started draining the PLIC
	// itself (see docs/devlog.md).
	bool driver_irq_pending;

	// Per-process namespace: path prefix -> server pid. Every process gets
	// an identical default namespace today (populated in create_process) —
	// there's no fork()/namespace inheritance yet to make private ones
	// meaningful — but the table itself already lives on the Process
	// struct, not a global, so a future sandboxed process can get a
	// restricted view later without a redesign.
	Mount[NS_MOUNTS_MAX] namespace;

	// Current working directory, absolute, no trailing slash. "" = the
	// root. SYS_CHDIR sets it (the shell's `cd`), SYS_GETCWD reads it
	// (`pwd`, the prompt). Inherited across rfork and unchanged by exec,
	// same as uid/namespace. The fs_* user wrappers prepend it to any
	// path that isn't already absolute.
	char[100] cwd;

	// stdout / stdin redirection for `|` and `>`/`<` (src/pipe.c3):
	// -1 = the console (the default). A pipe id otherwise — SYS_PUTCHAR
	// / SYS_GETCHAR route through it. Reset to -1 in create_process and
	// the rfork child (a fresh process gets the console); the shell
	// sets a child's ends explicitly via SYS_PIPE_SETOUT/SETIN, and
	// SYS_EXEC keeps them.
	int stdout_pipe;
	int stdin_pipe;

	// fsd-only: which partition SYS_FS_PARTITION_INFO (entry.c3) hands
	// back to *this specific* process. Per-process, not a plain kernel
	// global the way diskd_vq_paddr etc. are — those stay globals because
	// there's only ever one diskd; now that two fsd instances can exist
	// simultaneously, each needs its own answer to the same syscall. Set
	// by setup_fsd_mappings() right after create_process() spawns an fsd,
	// same "extra per-process setup after the generic call" pattern as
	// setup_diskd_mappings()/setup_sdd_mappings() below.
	uint fs_partition_start;

	// True for every kernel-spawned boot server (fsd, sdd/diskd, usbd,
	// ethd, netd, gpiod, procd, envd, echod) — set right after
	// create_process() in kernel.c3 / supervisor_spawn(). Once the shell
	// calls SYS_BOOT_QUIET, SYS_PUTCHAR from these is dropped so their
	// late init logs stop landing on the prompt. The shell and its
	// exec()'d children leave this false and print normally.
	bool is_boot_server;

	// fsd-only, same "set by setup_fsd_mappings, handed back via a
	// SYS_FS_PARTITION_INFO out-pointer" shape as fs_partition_start
	// above — lets fsd.c3 (user-space, can't see the kernel-only board
	// module) tell whether it's the root fsd or the second one, needed
	// to decide whether to srv_post() itself for real /mnt binding (see
	// user/fsd.c3's own comment).
	bool is_secondary_fs;

	// True while this process is inside one of the handful of blocking,
	// multi-yield() syscalls (SYS_JOIN/SYS_GETCHAR/SYS_IPC_RECV[_GEN]/
	// SYS_FUTEX_WAIT/SYS_NS_MOUNT_WAIT, entry.c3) — set right before that
	// syscall's own poll loop, cleared right after. Not derived from
	// `state`: SYS_JOIN/SYS_GETCHAR/SYS_NS_MOUNT_WAIT deliberately stay
	// PROC_RUNNABLE throughout their own loops (see SYS_JOIN's own
	// comment for why), so PROC_BLOCKED alone can't tell "is this
	// specific process mid one of these waits" reliably. Exists purely
	// so SYS_KILL can decrement the matching global blocking_depth
	// (below) if it kills a process while this is true — otherwise a
	// killed process's own increment would leak forever, permanently
	// wedging interrupt delivery for the whole system. See
	// blocking_depth's own comment for the real bug this closes.
	bool in_blocking_wait;

	char[STACK_SIZE] stack; // Kernel stack
}

// How many processes, system-wide, are currently inside one of the
// blocking, multi-yield() syscalls (see Process.in_blocking_wait's own
// comment for the exact list). Real bug this exists to fix, found
// building hot-plug support (docs/devlog.md): sstatus's SPIE bit — what
// every sret restores the live SIE bit from — is a single, unbanked
// hardware register; switch_context() (yield()'s own cooperative stack
// swap) never touches it, only a genuine trap-entry/sret pair does. A
// freshly-rfork()'d child's own *synthetic* first sret (fork_entry()
// below never touched sstatus at all before this fix) has no real,
// corresponding trap-entry of its own to restore SPIE from — it just
// inherits whatever the global register currently holds, which could be
// another process's still-open blocking wait's own "interrupts were on
// before I entered this syscall" snapshot, incorrectly re-enabling
// interrupts early. fork_entry() (below) consults this live, at the
// exact moment its own sret is about to fire, forcing SPIE off whenever
// it's nonzero — checked live, not baked in earlier (e.g. at SYS_RFORK
// time), since this can change after rfork() returns but before the
// child's first real turn.
//
// Deliberately NOT also consulted at kernel_entry's own shared trap-exit
// tail (handle_trap()'s end, entry.c3) — tried that first, found the
// hard way it's wrong: blocking_depth is *effectively always* nonzero
// during normal operation (echod/fsd/procd/envd — every idle server —
// sit permanently blocked in SYS_IPC_RECV waiting for their next
// client; that's their normal steady state, not a transient window).
// Gating the shared tail on it disabled real timer-interrupt preemption
// for the *entire system*, forever, from very early in boot onward —
// confirmed directly when hotplugtest itself started hanging with that
// version in place. The shared tail's own sret already correctly
// restores SIE from *that specific process's own* sstatus snapshot,
// auto-captured at *that same trap's* own entry — already safe by the
// existing, proven invariant (enable_timer_interrupts()'s own comment,
// entry.c3): SIE only actually needs forcing off for a synthetic sret
// with no real corresponding trap-entry of its own, which only ever
// happens in fork_entry().
// @export: fork_entry()'s own raw asm (below) reads this directly by
// its bare linker name — same reason read_reg_tmp/write_sepc_tmp
// (entry.c3) are exported, without it the symbol gets the usual
// module-mangled name (`kernel.blocking_depth`) asm can't reference.
int blocking_depth @export("blocking_depth") = 0;

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

// --- exit-status side table --------------------------------------------
// sys_exit / sys_kill drop a (pid, generation, code) here as they tear a
// process down; sys_join picks it up once it sees the slot is gone, so
// the shell's `&&` / `||` can tell whether a command succeeded. Only
// non-zero codes from a process that had a parent are recorded (a clean
// exit is the absence of a record — join returns 0). Round-robin and
// small: the shell joins its children promptly, so an unreaped entry
// just gets overwritten. generation stops a recycled pid from matching a
// stale record.
const int EXIT_RECORDS = 8;

struct Exit_record
{
	int  pid;
	uint generation;
	int  code;
	bool used;
}

Exit_record[EXIT_RECORDS] exit_records;
int exit_record_next;

fn void proc_record_exit(int pid, uint generation, int parent_pid, int code)
{
	if (parent_pid == 0 || code == 0) return;
	for (int i = 0; i < EXIT_RECORDS; i++)
	{
		if (exit_records[i].used && exit_records[i].pid == pid && exit_records[i].generation == generation)
		{
			exit_records[i].code = code;
			return;
		}
	}
	exit_records[exit_record_next].pid        = pid;
	exit_records[exit_record_next].generation = generation;
	exit_records[exit_record_next].code       = code;
	exit_records[exit_record_next].used       = true;
	exit_record_next = (exit_record_next + 1) % EXIT_RECORDS;
}

fn int proc_take_exit(int pid, uint generation)
{
	for (int i = 0; i < EXIT_RECORDS; i++)
	{
		if (exit_records[i].used && exit_records[i].pid == pid && exit_records[i].generation == generation)
		{
			int c = exit_records[i].code;
			exit_records[i].used = false;
			return c;
		}
	}
	return 0;
}

// One attempt at "look srv_name up in srv_table and, if it names a
// still-live server, bind it at prefix in current_proc's own
// namespace" — the shared logic SYS_NS_MOUNT (entry.c3) and
// SYS_NS_MOUNT_WAIT (entry.c3, a retry loop around this exact same
// attempt) both need. A stale/dead post (the poster's own generation
// no longer matches — same check SYS_NS_RESOLVE already uses for
// existing mounts) is treated as "not found," never bound. Idempotent
// by exact prefix, same as SYS_NS_UNMOUNT's own matching: an existing
// entry with this prefix is rebound in place rather than duplicated.
fn bool ns_mount_try(char* prefix, char* srv_name)
{
	int srv_pid = 0;
	uint srv_generation = 0;
	for (int i = 0; i < SRV_MAX; i++)
	{
		if (srv_table[i].pid == 0) continue;
		if (!str_eq(&srv_table[i].name[0], srv_name)) continue;
		Process* target = proc_by_pid(srv_table[i].pid);
		if (!target || target.generation != srv_table[i].generation) break;
		srv_pid = srv_table[i].pid;
		srv_generation = srv_table[i].generation;
		break;
	}
	if (srv_pid == 0) return false;

	int free_slot = -1;
	for (int m = 0; m < NS_MOUNTS_MAX; m++)
	{
		if (current_proc.namespace[m].server_pid == 0)
		{
			if (free_slot == -1) free_slot = m;
			continue;
		}
		if (str_eq(&current_proc.namespace[m].prefix[0], prefix))
		{
			current_proc.namespace[m].server_pid = srv_pid;
			current_proc.namespace[m].server_generation = srv_generation;
			return true;
		}
	}
	if (free_slot != -1)
	{
		str_copy(&current_proc.namespace[free_slot].prefix[0], prefix, NS_PREFIX_MAX);
		current_proc.namespace[free_slot].server_pid = srv_pid;
		current_proc.namespace[free_slot].server_generation = srv_generation;
		return true;
	}
	return false;
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

// SYS_EXEC (entry.c3) remaps this process's own USER_BASE pages in place —
// no satp write happens (same process, same page table physical address),
// so switch_context's own sfence.vma (above) never fires for it. Without
// this, the CPU can keep serving the *old* image's translations out of the
// TLB after the remap, executing stale/freed physical pages instead of the
// new ones. Global (not ASID-scoped) flush — this kernel doesn't use ASIDs.
fn void flush_tlb() @naked @noinline
{
	asm(`
        sfence.vma
        ret
    `);
}

// Targeted flush for a single just-mapped page (a0 = its virtual
// address) — the lazy-SYS_MAP demand-fault path (entry.c3) runs on
// every touched page of a Go arena, so a global sfence.vma each time
// would be a real cost. Making a previously-invalid PTE valid still
// needs a flush: the RISC-V spec permits an implementation to cache the
// non-leaf walk or a negative result.
fn void flush_tlb_page(uptr vaddr) @naked @noinline
{
	asm(`
        sfence.vma a0
        ret
    `);
}

// --- FP register file save/restore ----------------------------------------
// a0 = &Process.fp_area (ulong[33]: f0-f31 at 8*0..8*31, fcsr at 8*32).
// Opaque asm — block asm{} doesn't recognise fsd/fld/frcsr/fscsr. Called
// from yield() around switch_context (and fp_save from sys_rfork). Needs
// sstatus.FS >= Initial (set at boot, kernel.c3) or the FP ops trap.
fn void fp_save(uptr area) @naked @noinline @nostrip
{
	asm(`
        fsd f0,  8 * 0(a0)
        fsd f1,  8 * 1(a0)
        fsd f2,  8 * 2(a0)
        fsd f3,  8 * 3(a0)
        fsd f4,  8 * 4(a0)
        fsd f5,  8 * 5(a0)
        fsd f6,  8 * 6(a0)
        fsd f7,  8 * 7(a0)
        fsd f8,  8 * 8(a0)
        fsd f9,  8 * 9(a0)
        fsd f10, 8 * 10(a0)
        fsd f11, 8 * 11(a0)
        fsd f12, 8 * 12(a0)
        fsd f13, 8 * 13(a0)
        fsd f14, 8 * 14(a0)
        fsd f15, 8 * 15(a0)
        fsd f16, 8 * 16(a0)
        fsd f17, 8 * 17(a0)
        fsd f18, 8 * 18(a0)
        fsd f19, 8 * 19(a0)
        fsd f20, 8 * 20(a0)
        fsd f21, 8 * 21(a0)
        fsd f22, 8 * 22(a0)
        fsd f23, 8 * 23(a0)
        fsd f24, 8 * 24(a0)
        fsd f25, 8 * 25(a0)
        fsd f26, 8 * 26(a0)
        fsd f27, 8 * 27(a0)
        fsd f28, 8 * 28(a0)
        fsd f29, 8 * 29(a0)
        fsd f30, 8 * 30(a0)
        fsd f31, 8 * 31(a0)
        frcsr t0
        sd t0, 8 * 32(a0)
        ret
    `);
}

fn void fp_restore(uptr area) @naked @noinline @nostrip
{
	asm(`
        fld f0,  8 * 0(a0)
        fld f1,  8 * 1(a0)
        fld f2,  8 * 2(a0)
        fld f3,  8 * 3(a0)
        fld f4,  8 * 4(a0)
        fld f5,  8 * 5(a0)
        fld f6,  8 * 6(a0)
        fld f7,  8 * 7(a0)
        fld f8,  8 * 8(a0)
        fld f9,  8 * 9(a0)
        fld f10, 8 * 10(a0)
        fld f11, 8 * 11(a0)
        fld f12, 8 * 12(a0)
        fld f13, 8 * 13(a0)
        fld f14, 8 * 14(a0)
        fld f15, 8 * 15(a0)
        fld f16, 8 * 16(a0)
        fld f17, 8 * 17(a0)
        fld f18, 8 * 18(a0)
        fld f19, 8 * 19(a0)
        fld f20, 8 * 20(a0)
        fld f21, 8 * 21(a0)
        fld f22, 8 * 22(a0)
        fld f23, 8 * 23(a0)
        fld f24, 8 * 24(a0)
        fld f25, 8 * 25(a0)
        fld f26, 8 * 26(a0)
        fld f27, 8 * 27(a0)
        fld f28, 8 * 28(a0)
        fld f29, 8 * 29(a0)
        fld f30, 8 * 30(a0)
        fld f31, 8 * 31(a0)
        ld t0, 8 * 32(a0)
        fscsr t0
        ret
    `);
}

// Zero every FP register + fcsr — SYS_EXEC uses this so a fresh image
// starts with a clean rounding mode / no sticky flags, not the previous
// image's leftover FP state.
fn void fp_reset() @naked @noinline @nostrip
{
	asm(`
        fmv.d.x f0,  x0
        fmv.d.x f1,  x0
        fmv.d.x f2,  x0
        fmv.d.x f3,  x0
        fmv.d.x f4,  x0
        fmv.d.x f5,  x0
        fmv.d.x f6,  x0
        fmv.d.x f7,  x0
        fmv.d.x f8,  x0
        fmv.d.x f9,  x0
        fmv.d.x f10, x0
        fmv.d.x f11, x0
        fmv.d.x f12, x0
        fmv.d.x f13, x0
        fmv.d.x f14, x0
        fmv.d.x f15, x0
        fmv.d.x f16, x0
        fmv.d.x f17, x0
        fmv.d.x f18, x0
        fmv.d.x f19, x0
        fmv.d.x f20, x0
        fmv.d.x f21, x0
        fmv.d.x f22, x0
        fmv.d.x f23, x0
        fmv.d.x f24, x0
        fmv.d.x f25, x0
        fmv.d.x f26, x0
        fmv.d.x f27, x0
        fmv.d.x f28, x0
        fmv.d.x f29, x0
        fmv.d.x f30, x0
        fmv.d.x f31, x0
        fscsr x0
        ret
    `);
}

const SSTATUS_SPIE = (1 << 5);
const SSTATUS_SUM   = (1 << 18); // let S-mode access U-mode pages (needed for syscalls like readfile/writefile that dereference user pointers directly)
                                  // Same bit positions on RV64: sstatus's low, commonly-used bits are defined identically across XLEN in the priv spec.

fn void user_entry() @naked @noinline @noreturn
{
	// USER_BASE (kernel.c3's const of the same name) and
	// SSTATUS_SPIE|SSTATUS_SUM|FS_INITIAL (0x42020 = 0x40020 | (1<<13),
	// this file's consts above + entry.c3's SSTATUS_FS_INITIAL)
	// hardcoded: compile-time asm() only supports %s substitution, so the
	// constants can't be interpolated here. The FS bit starts a fresh
	// process with the FPU usable (its f-regs were zeroed by
	// create_process + loaded by yield()'s fp_restore). USER_BASE must
	// also match user/user.ld's base address. `li` with a small constant
	// like this compiles the same way regardless of XLEN.
	//
	// a0/a1 explicitly zeroed: user/user.c3's start() (this process's
	// very first instruction after sret) passes a0/a1 straight through
	// as main()'s own argc/argv parameters — SYS_EXEC (entry.c3) sets
	// both deliberately for an exec()'d process, but this path is for a
	// brand new process create_process() is booting for the first time,
	// where a0/a1 would otherwise still hold whatever the kernel's own
	// boot-time code last left in the physical registers. Zeroing here
	// is what makes every create_process()'d server (echod, diskd, fsd,
	// procd, envd, shell) reliably see an empty args (String[] of
	// length 0, via std::nolibc::main_stub's @main_args) instead of
	// reading that leftover garbage as if it meant something.
	asm(`
        li t0, 0x1000000
        csrw sepc, t0
        li t1, 0x42020
        csrw sstatus, t1
        li a0, 0
        li a1, 0
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

        csrr t0, sstatus
        la t1, blocking_depth
        lw t1, 0(t1)
        beqz t1, 1f
        li t2, -33
        and t0, t0, t2
    1:
        csrw sstatus, t0

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

// Mount.server_generation's own value at namespace-population time — see
// that field's comment. 0 for a pid that doesn't currently exist (0
// itself, or a slot that's PROC_UNUSED), matching server_pid's existing
// "0 means nothing bound here" convention: SYS_NS_RESOLVE already skips
// server_pid == 0 first, so this value is never actually consulted in
// that case.
fn uint mount_generation(int pid)
{
	Process* p = proc_by_pid(pid);
	return p ? p.generation : 0;
}

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
	// separate pages, not a range — see plic.c3. Kernel-only (no PAGE_U).
	// _PAGE is the virtual page, _PHYS_PAGE the PLIC physical page — equal
	// on the Duo, aliased apart on QEMU so the PLIC stays clear of large
	// user heaps (see boards/qemu/board.c3's PLIC_BASE comment).
	map_device_page(page_table, board::PLIC_PRIORITY_PAGE, board::PLIC_PRIORITY_PHYS_PAGE, PAGE_R | PAGE_W);
	map_device_page(page_table, board::PLIC_ENABLE_PAGE, board::PLIC_ENABLE_PHYS_PAGE, PAGE_R | PAGE_W);
	map_device_page(page_table, board::PLIC_CLAIM_PAGE, board::PLIC_CLAIM_PHYS_PAGE, PAGE_R | PAGE_W);

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
	// SYS_MAP bump pointer starts one page past the mapped image (which
	// includes .bss + the 64KB user stack — see user/user.ld). A
	// create_process()'d process has no argv; sys_exec sets its own.
	proc.heap_top = (uptr)USER_BASE + (uptr)((image_size + PAGE_SIZE - 1) / PAGE_SIZE * PAGE_SIZE);
	proc.map_floor = proc.heap_top; // lazy SYS_MAP: nothing above here is mapped yet
	// create_process() never has a "parent" in the fork sense (a fresh
	// boot-time spawn or a shell respawn, not an existing process
	// splitting in two) — explicit, not relied-on zero-init, since a
	// reused slot could otherwise leak a previous occupant's real
	// parent_pid. See Process.parent_pid's own comment above.
	proc.parent_pid = 0;
	proc.parent_generation = 0;
	// Every boot-time server is root — same explicit-zero-init reasoning
	// as parent_pid above. See Process.uid's own comment.
	proc.uid = 0;
	// Same explicit-zero-init reasoning as parent_pid/uid above — a
	// reused slot must never inherit a stale `true` left behind by a
	// previous occupant that happened to be killed mid a blocking wait.
	// See Process.in_blocking_wait's own comment.
	proc.in_blocking_wait = false;
	// Same reason: a reused slot must not inherit "I'm waiting on pid X"
	// or a stale "my peer died" from a previous occupant.
	proc.ipc_wait_pid = 0;
	proc.ipc_wait_generation = 0;
	proc.ipc_peer_died = false;
	proc.in_call_reply_wait = false;
	// A reused slot must not start life with a previous occupant's
	// unconsumed inbox message (sys_rfork clears this for the same
	// reason). Missing this let a supervisor-respawned server "consume"
	// a stale request left by the instance the watchdog just killed and
	// reply into a rendezvous nobody was waiting on — a deadlock.
	proc.has_message = false;
	proc.ipc_progress = 0; // watchdog progress counter — fresh slot, fresh count
	proc.msg_acked = false;
	proc.msg_from = 0;
	// Same reused-slot hygiene sys_rfork already does: a slot whose
	// previous occupant left driver_irq_pending set would otherwise make
	// a respawned driver's very first SYS_IPC_POLL return the synthetic
	// DISKD_IRQ_NOTIFY instead of its real inbox state. Missing here was
	// a gap — create_process is the supervisor's respawn path.
	proc.driver_irq_pending = false;
	proc.is_boot_server = false; // kernel.c3 / supervisor_spawn set it for servers
	proc.cwd[0] = 0; // root
	proc.stdout_pipe = -1;
	proc.stdin_pipe = -1;
	// A reused slot must not start with a previous occupant's f-regs /
	// fcsr — yield()'s fp_restore loads this on the first schedule.
	for (int k = 0; k < 33; k++) { proc.fp_area[k] = 0; }

	// Default namespace: "/srv/echo/" resolves to echod, which is always
	// pid 2 (see kernel.c3 — it's the first process spawned after idle,
	// deterministically). Real Plan 9 convention: /srv is where server
	// processes get *named* in the namespace — this is the mount's
	// original placeholder binding (shell.c3's p9test used to hardcode
	// pid 2 directly) finally landing on the right prefix, not just a
	// real lookup replacing a hardcoded one. It used to be bound to bare
	// "/" instead — semantically backwards (echod is a service, not the
	// filesystem root) and purely an artifact of predating this rename;
	// see docs/devlog.md. Trailing slash deliberately, matching "/2/"'s
	// own convention below, so a future "/srv/echo2" can't accidentally
	// prefix-match too.
	str_copy(&proc.namespace[0].prefix[0], "/srv/echo/", NS_PREFIX_MAX);
	proc.namespace[0].server_pid = echod_pid;
	proc.namespace[0].server_generation = mount_generation(echod_pid);

	// "" is a catch-all — str_starts_with treats an empty prefix as
	// matching everything, and its zero length always loses a longest-
	// prefix-match tie against any of the real prefixes above/below — so
	// this only ever wins for paths that don't start with "/" at all:
	// plain filenames like "hello.txt", exactly how user.c3's
	// fs_read/fs_write call ns_resolve(). Also, now that nothing claims
	// bare "/" anymore, this transparently catches absolute paths like
	// "/hello.txt" too — no separate "/" -> fsd mount needed. Routes to
	// fsd (0 — "unused" — for any process created before fsd exists,
	// namely idle/echod/diskd themselves, none of which ever need this).
	str_copy(&proc.namespace[1].prefix[0], "", NS_PREFIX_MAX);
	proc.namespace[1].server_pid = fsd_pid;
	proc.namespace[1].server_generation = mount_generation(fsd_pid);

	// "/mnt/fs2/" — the second, simultaneously-mounted fsd instance (see
	// fsd2_pid's own comment above), Plan9-style: an ordinary directory
	// other services get mounted onto, not root itself (see
	// docs/devlog.md). Same "harmless 0 for any process created before
	// it exists" pattern as namespace[1] — SYS_NS_RESOLVE (entry.c3)
	// already skips any mount with server_pid == 0. This default binding
	// stays statically set here rather than raced against fsd2's own
	// boot-time mount via a real ns_mount() call — see user/fsd.c3's own
	// comment for why fsd2 also srv_post()s itself under "fs2", proven
	// genuinely rebindable post-boot by shell.c3's own mounttest.
	str_copy(&proc.namespace[2].prefix[0], "/mnt/fs2/", NS_PREFIX_MAX);
	proc.namespace[2].server_pid = fsd2_pid;
	proc.namespace[2].server_generation = mount_generation(fsd2_pid);

	// "/proc/" — the process-info server (see procd_pid's own comment
	// above, user/procd.c3). Same harmless-0-before-creation pattern as
	// namespace[1]/[2].
	str_copy(&proc.namespace[3].prefix[0], "/proc/", NS_PREFIX_MAX);
	proc.namespace[3].server_pid = procd_pid;
	proc.namespace[3].server_generation = mount_generation(procd_pid);

	// "/env/" — the per-process environment-variable server (see
	// envd_pid's own comment above, user/envd.c3). Same harmless-0-
	// before-creation pattern as namespace[1]/[2]/[3].
	str_copy(&proc.namespace[4].prefix[0], "/env/", NS_PREFIX_MAX);
	proc.namespace[4].server_pid = envd_pid;
	proc.namespace[4].server_generation = mount_generation(envd_pid);

	for (int m = 5; m < NS_MOUNTS_MAX; m++)
	{
		proc.namespace[m].server_pid = 0;
	}

	// Every boot-seeded mount is a plain, identity binding (no rewrite, no
	// union). Explicit, not relied-on zero-init — a reused procs[] slot
	// could otherwise leak a previous occupant's `bind` target/flags. Any
	// process wanting a rewriting or union mount adds it at runtime via
	// SYS_NS_BIND.
	for (int m = 0; m < NS_MOUNTS_MAX; m++)
	{
		proc.namespace[m].target[0] = 0;
		proc.namespace[m].flags = 0;
	}

	proc.fs_partition_start = 0; // meaningful only once setup_fsd_mappings() sets it
	proc.is_secondary_fs = false; // same — meaningful only once setup_fsd_mappings() sets it

	return proc;
}

// Maps a small, fixed list of device-register pages (identity-mapped,
// the standard PAGE_U|R|W a driver process needs for its own MMIO)
// into a process's page table — the repeated shape every setup_xxx_
// mappings function below used to spell out one map_device_page() call
// at a time, each restating proc.page_table and the same flags. NOT
// for a DMA buffer's own multi-page allocation (diskd/usbd/ethd/netd's
// own dma_paddr/vq_paddr loops still do that by hand, page by page,
// since alloc_pages() has to run first and map_page() — not
// map_device_page() — is the right call for some of them) — just the
// fixed, compile-time-known register pages a driver already knows by
// address before it's even created.
fn void map_device_pages(Process* proc, uptr* addrs, int count)
{
	for (int i = 0; i < count; i++)
	{
		map_device_page(proc.page_table, addrs[i], addrs[i], PAGE_U | PAGE_R | PAGE_W);
	}
}

// Called once, right after create_process() spawns an fsd instance (see
// kernel.c3 — called for both the first and, if board::
// HAS_SECOND_FS_PARTITION, the second), to tell it which partition it
// owns. No MMIO/paging work needed here, unlike setup_diskd_mappings/
// setup_sdd_mappings below — fsd never touches hardware directly, it
// only needs these two facts, handed back via SYS_FS_PARTITION_INFO
// (entry.c3) reading current_proc.fs_partition_start/is_secondary_fs.
// is_secondary is a plain bool kernel.c3 already knows unambiguously
// at each of its own two call sites (its own code is what conditionally
// creates the second instance at all) — see is_secondary_fs's own
// comment for why fsd.c3 needs this at all.
fn void setup_fsd_mappings(Process* proc, uint partition_start, bool is_secondary)
{
	proc.fs_partition_start = partition_start;
	proc.is_secondary_fs = is_secondary;
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

	// virtio-mmio interrupt: edge/latched, acked via the virtio ISR
	// register in diskd itself — level=false, handle_trap leaves the
	// PLIC source enabled.
	irq_route_register(board::IRQ_VIRTIO_BLK, proc.pid, false);
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
	// SD_MMIO_BASE, then the pad/power/clock one-time bring-up registers
	// (see board.c3's own comment on those three) — separate pages from
	// SD_MMIO_BASE and from each other.
	uptr[4] sdd_pages = { board::SD_MMIO_BASE, board::SD_TOP_PAGE, board::SD_PINMUX_PAGE, board::SD_CLOCK_PAGE };
	map_device_pages(proc, &sdd_pages[0], 4);

	// SDMA staging buffer — identity-mapped, uncached (map_device_page,
	// not map_page — same real-hardware DMA cache-incoherency reasoning
	// as usbd_dma_paddr's own comment).
	uptr dma_paddr = alloc_pages(1);
	map_device_page(proc.page_table, dma_paddr, dma_paddr, PAGE_U | PAGE_R | PAGE_W);
	sdd_dma_paddr = dma_paddr;

	// SDHCI interrupt: level-high, cleared by sdd writing SD_INT_STATUS
	// — same handle_trap disable / SYS_DRIVER_IRQ_ARM re-arm dance as
	// usbd. Inert unless board::plic_init armed IRQ_SDHCI
	// (INTERRUPT_DRIVEN_SD) and sdd unmasked the controller interrupt.
	irq_route_register(board::IRQ_SDHCI, proc.pid, true);
}

fn void setup_usbd_mappings(Process* proc)
{
	// USB_MMIO_BASE, the TOP-block one-time bring-up registers (see
	// board.c3's own comment on those two — separate pages from
	// USB_MMIO_BASE and from each other), the USB PHY's own reference
	// clocks (USB_CLK_PAGE), and PAD_USB_VBUS_DET's pinmux function-
	// select (USB_PINMUX_PAGE) — see each constant's own comment in
	// board.c3 for why it's needed.
	uptr[5] usbd_pages = { board::USB_MMIO_BASE, board::USB_TOP_CTRL_PAGE, board::USB_TOP_RST_PAGE, board::USB_CLK_PAGE, board::USB_PINMUX_PAGE };
	map_device_pages(proc, &usbd_pages[0], 5);

	// Phase 2's own DMA buffer — see usbd_dma_paddr's own comment above
	// for why this is identity-mapped, the same reasoning as diskd's
	// virtqueue/request buffers (setup_diskd_mappings above): the DWC2
	// host channel's HCDMA register needs a real physical address, and
	// usbd (like every other user process) otherwise has no way to
	// learn its own virtual pages' physical backing.
	//
	// map_device_page(), NOT map_page(), despite this being ordinary
	// RAM, not a hardware register — deliberately uncached. This is
	// the one real difference from diskd's own virtqueue mapping, and
	// it matters here in a way it never has before: diskd only ever
	// runs against QEMU's virtio-mmio (HAS_VIRTIO_BLOCK is QEMU-only),
	// a software-emulated device that just reads the guest's memory
	// buffer directly — no real cache-incoherency effect exists to
	// hit there at all. usbd is the first driver in this project's
	// history doing genuine DMA against real Duo hardware, where a
	// cacheable mapping (map_page()'s own PTE_EXTRA_BITS = SHARE|
	// CACHE|BUF, see its own comment) risks the DWC2 core's own DMA
	// engine — a separate AHB bus master — reading stale memory the
	// CPU's write never made it past its own cache line for. A real
	// hardware round hit a persistent, deterministic STALL on the
	// very first control transfer, unaffected by every content/timing
	// fix tried, which is exactly the signature of the *actual*
	// transmitted bytes silently differing from what this driver's
	// own debug prints (reading the original stack buffer, not the
	// DMA buffer) had been trusted as confirming correct.
	uptr dma_paddr = alloc_pages(1);
	map_device_page(proc.page_table, dma_paddr, dma_paddr, PAGE_U | PAGE_R | PAGE_W);
	usbd_dma_paddr = dma_paddr;

	// DWC2 core interrupt (GINTMSK.HCHINT etc., see user/usb/dwc2.c3):
	// level-high, cleared only by usbd writing HCINT — handle_trap
	// disables the source on each fire, usbd re-arms via
	// SYS_DRIVER_IRQ_ARM. Inert unless board::plic_init armed IRQ_USB
	// (INTERRUPT_DRIVEN_USB) and dwc2.c3 unmasked the core interrupt.
	irq_route_register(board::IRQ_USB, proc.pid, true);
}

// Called once, right after create_process() spawns gpiod (see
// kernel.c3), to give it access to GPIO bank C's own registers and the
// shared pinmux page every pad's own function-select register lives
// on — see board::GPIO_BANK_C_BASE/GPIO_PINMUX_PAGE's own comments.
// No DMA buffer, no SYS_GPIOD_INFO syscall needed: same reasoning as
// setup_sdd_mappings above — every register gpiod touches is a fixed,
// compile-time-known physical address, not something kernel-allocated
// at spawn time.
fn void setup_gpiod_mappings(Process* proc)
{
	uptr[3] gpiod_pages = { board::GPIO_BANK_A_BASE, board::GPIO_BANK_C_BASE, board::GPIO_PINMUX_PAGE };
	map_device_pages(proc, &gpiod_pages[0], 3);
}

// Called once, right after create_process() spawns ethd (see
// kernel.c3), to give it access to the DesignWare Ethernet MAC's own
// registers, the embedded PHY's register block, the clock-controller
// page it needs one bit in, and (Ethernet Phase 2) a single-page DMA
// region for its descriptor ring/packet buffers. Identity-mapped for
// the same reason as every other real-device MMIO mapping in this
// file.
fn void setup_ethd_mappings(Process* proc)
{
	// ETH_MMIO_BASE; ETH_DMA_PAGE (the MAC's own DMA register block,
	// Ethernet Phase 2 — a separate mapping from ETH_MMIO_BASE);
	// ETH_PHY_PAGE (the embedded PHY's own register block);
	// ETH_CLK_PAGE (clk_500m_eth0/clk_axi4_eth0 — same physical page
	// USB_CLK_PAGE/SD_CLOCK_PAGE also map, for their own unrelated
	// bits); ETH_LED_PINMUX_PAGE/ETH_SD1_SELPHY_PAGE
	// (cv180x_ephy_led_pinmux()'s own two register pages); and the real,
	// complete PHY analog bring-up's own efuse trim pages
	// (ETH_EFUSE_PAGE_0/_1). See each constant's own comment in
	// board.c3 for why it's needed.
	uptr[8] ethd_pages = {
		board::ETH_MMIO_BASE, board::ETH_DMA_PAGE, board::ETH_PHY_PAGE, board::ETH_CLK_PAGE,
		board::ETH_LED_PINMUX_PAGE, board::ETH_SD1_SELPHY_PAGE, board::ETH_EFUSE_PAGE_0, board::ETH_EFUSE_PAGE_1
	};
	map_device_pages(proc, &ethd_pages[0], 8);

	// Phase 2's own DMA region — see ethd_dma_paddr's own comment above
	// for the layout and why this is uncached (map_device_page, not
	// map_page): same real-DMA-cache-incoherency reasoning as
	// usbd_dma_paddr, this being the second driver (after usbd) doing
	// genuine DMA against real Duo hardware.
	uptr dma_paddr = alloc_pages(1);
	map_device_page(proc.page_table, dma_paddr, dma_paddr, PAGE_U | PAGE_R | PAGE_W);
	ethd_dma_paddr = dma_paddr;

	// dwmac RX/TX-done interrupt: level, cleared by ethd writing the DMA
	// status register. Registered now so interrupt-driven RX only needs
	// board::plic_init to arm IRQ_ETH + ethd to unmask + wait on the
	// notify — no kernel routing edit. Inert until then (source never
	// fires).
	irq_route_register(board::IRQ_ETH, proc.pid, true);
}

// Called once, right after create_process() spawns netd (see
// kernel.c3), to give it access to virtio-net's own virtio-mmio
// registers and two virtqueues (RX and TX — virtio-net's own spec
// requires both configured before DRIVER_OK, even though Phase 1
// doesn't push anything through them yet). Cacheable map_page(), same
// as diskd's own virtqueue above and for the same reason: netd only
// ever runs against QEMU's software-emulated virtio-mmio
// (board::HAS_VIRTIO_NET is QEMU-only), which has no real
// cache-incoherency to hit — see usbd_dma_paddr's own comment
// (map_device_page, not map_page) for why that reasoning does NOT
// carry over to a real-hardware DMA buffer.
fn void setup_netd_mappings(Process* proc)
{
	map_device_page(proc.page_table, board::VIRTIO_NET_PADDR, board::VIRTIO_NET_PADDR, PAGE_U | PAGE_R | PAGE_W);

	uint vq_pages = (uint)(mem::aligned_offset((sz)Virtio_virtq::size, PAGE_SIZE) / PAGE_SIZE);

	uptr rxq_paddr = alloc_pages(vq_pages);
	for (uint off = 0; off < vq_pages * PAGE_SIZE; off += PAGE_SIZE)
	{
		map_page(proc.page_table, rxq_paddr + off, rxq_paddr + off, PAGE_U | PAGE_R | PAGE_W);
	}

	uptr txq_paddr = alloc_pages(vq_pages);
	for (uint off = 0; off < vq_pages * PAGE_SIZE; off += PAGE_SIZE)
	{
		map_page(proc.page_table, txq_paddr + off, txq_paddr + off, PAGE_U | PAGE_R | PAGE_W);
	}

	// Phase 2's own packet-buffer page — see netd_pktbuf_paddr's own
	// comment above for the layout.
	uptr pktbuf_paddr = alloc_pages(1);
	map_page(proc.page_table, pktbuf_paddr, pktbuf_paddr, PAGE_U | PAGE_R | PAGE_W);

	netd_rxq_paddr    = rxq_paddr;
	netd_txq_paddr    = txq_paddr;
	netd_pktbuf_paddr = pktbuf_paddr;
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

	// Bracket the switch with an FP save/restore — switch_context is
	// @naked (preserves no FP regs, incl. callee-saved fs0-fs11) and is
	// its only caller, so this one spot covers every context switch.
	//
	// Conditional save: sstatus.FS is Dirty iff `prev` wrote an f-reg
	// since we last fp_restore'd it — otherwise prev.fp_area is still
	// current and the ~66-op save is wasted. fp_restore itself dirties
	// FS (fld/fscsr), so force it back to Clean afterward or every
	// subsequent yield would see Dirty and save. kernel_entry doesn't
	// snapshot sstatus, so this Clean value rides through the switch to
	// `next` and out via its sret. Matters: an exec yields thousands of
	// times and the Go/tcc/toolchain workloads are FP-free.
	if ((read_reg("sstatus") & SSTATUS_FS_MASK) == SSTATUS_FS_DIRTY)
	{
		fp_save((uptr)&prev.fp_area);
	}
	fp_restore((uptr)&next.fp_area);
	write_csr("sstatus", (read_reg("sstatus") & ~SSTATUS_FS_MASK) | SSTATUS_FS_CLEAN);

	switch_context(&prev.sp, &next.sp, ((ulong)(uptr)next.page_table >> 12) | SATP_SV39, (uptr)&next.stack + STACK_SIZE);
}
