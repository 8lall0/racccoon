module user;

import std::nolibc::main_stub;
import std::nolibc::mem;

// fsd: the file system, moved out of the trusted kernel into its own
// user-mode process (microkernel plan phase 5 — see docs/devlog.md).
// It's a 9P-lite-style client of diskd/sdd (phase 4) for raw sector I/O,
// and a server to everyone else (today just the shell) over the
// FS_READ/FS_WRITE verbs below. SYS_READFILE/SYS_WRITEFILE are gone from
// the kernel entirely now — this is the only way to touch a file.
//
// This file is the filesystem-agnostic core: the IPC/wire protocol,
// low-level sector I/O, and write-protection machinery — none of which
// care which on-disk format is actually mounted. Real filesystem
// structure (FAT32, ext2, exFAT) lives in user/fs/*.c3, each exposing a
// small, consistently-named set of entry points. The nine path-based
// FS_* verbs reach them through one Fs_ops function-pointer table per
// backend (see the "FS_* verb dispatch table" section below), picked
// once at mount time by probing each backend in turn (see fs_mount()).
// This is the one place the codebase uses a vtable: an earlier version
// pasted a `fs_type` FAT32/ext2/exFAT `if` triple into all nine verb
// branches, and the divergence that invites shipped a real bug (the
// empty-leaf guard existed on exFAT but not the other two — see
// docs/devlog.md). Nine verbs times three backends is past the point
// where three hand-maintained copies are the simpler thing. The P9_*
// block below is separate (its own protocol, ext2-only) and untouched.
// Every file here — fsd.c3 and every user/fs/*.c3 —
// shares `module user;` (matching every other user-mode file, e.g. how
// fsd.c3 and user.c3 already shared one module before this split), so
// functions across files call each other directly with no extra
// plumbing; see scripts/build_user.sh's fsd line for the file list.
//
// v1 scope, deliberately limited (see each backend's own header comment
// for format-specific limits): root directory only, no subdirectories
// (fsd had no subdirectory concept before FAT32 support either — not a
// regression), no caching at boot — every FS_READ/FS_WRITE walks the
// root directory fresh, since there's no reasonable fixed-size cache for
// "however many files happen to be on someone's real SD card." Both
// FAT32 and ext2 support create/overwrite/grow writes now.
//
// Write support (create, overwrite, grow — see fs/fat32.c3's
// fat32_write()/fs/ext2.c3's ext2_write()) started read-only-only and
// was extended deliberately: a parsing bug can misread data, but a
// write bug can corrupt the very partition that boots this board. The
// safety net isn't just "don't write to fip.bin by name" — it's
// structural: fs_mount() has each backend look up its own protected
// file's directory entry and its ENTIRE data chain once at mount time,
// recording every sector it occupies (see
// fs_reserve_sector_range()/fs_reserved_ranges), and diskd_rw() — the
// ONE function every write in this process funnels through, whether
// it's file data, a bitmap/FAT-table update, or a directory entry —
// refuses any write that would land on one of those sectors. That means
// a bug in a backend's allocator or directory code can't reach a
// protected file either, not just a filename check that a different
// code path could bypass. See docs/devlog.md for the entries covering
// FAT32's read-only and write-support work, the filesystem-abstraction
// split, and ext2's own read and write support.
//
// Unlike diskd, fsd is an ordinary IPC participant: nothing it waits for
// depends on a hardware interrupt firing while it's parked mid-trap, so
// plain blocking ipc_send/ipc_recv (via p9_call) is safe here — the
// sscratch/nested-trap hazard documented in src/entry.c3's SYS_IPC_POLL
// comment was specific to diskd's *interrupt* wait, not to IPC in
// general.

// FS_READ/FS_WRITE/FS_MSG_MAX are declared in user.c3, not here — this
// file is compiled together with user.c3 into the same fsd binary (see
// scripts/build_user.sh), same module, so declaring them twice would
// just be a duplicate-declaration error. See user.c3's copy for the
// wire-format comment; must match src/process.c3's MSG_MAX too.

// --- diskd's own protocol (user/diskd.c3) — unrelated to FS_READ/WRITE
// above, just the client side of it. Shared by every backend, via
// fs_read_sector/fs_write_sector below. Deliberately >100, clear of both
// the P9_* verb range (3..10) and the FS_* range (20..30): if a diskd
// reply ever lands in fsd's inbox unconsumed (a completion-IRQ delivery
// race — see docs/devlog.md), fsd's main-loop recv picks it up as a
// bogus request. With a colliding number (DISKD_READ was 10 == P9_REMOVE)
// fsd would dispatch it and reply straight back to diskd — a mutual
// deadlock. Out of range, fsd just drops it (the recv still acks diskd,
// so diskd unblocks) and recovers.
const uint DISKD_READ    = 210;
const uint DISKD_WRITE   = 211;
const uint DISKD_MSG_MAX = 516;
const uint SECTOR_SIZE   = 512;

// --- read cache -----------------------------------------------------
// Direct-mapped sector cache below fs_read_sector/fs_write_sector.
// Without it, every FS_READ walks the tree and every walk step is one
// IPC + one single-sector virtio op to diskd — loading /bin/go (13.6
// MiB) is ~26k round trips. The Go toolchain re-reads compile/link/asm
// and re-walks $GOROOT's inode-table + directory blocks constantly, so
// nearly all of that is a cache hit after the first pass.
//
// The tags are a small static array; the 512-byte payloads live in a
// lazily-backed SYS_MAP region (fs_cache_init) so the fsd .bin doesn't
// carry 512 KiB of zeros and a cold slot costs no real RAM. Keyed on
// the partition-relative sector (fsd only ever touches one partition;
// fsd2 is a separate process with its own cache). Write-through:
// diskd_rw stays the single enforcement point for the reserved-sector /
// write-disabled checks, and a successful write refreshes the slot — so
// the cache can never be staler than the disk (fsd is the sole writer,
// diskd doesn't cache, a diskd respawn leaves disk contents unchanged).
const uint FS_CACHE_ENTRIES = 1024;               // * 512 B = 512 KiB
const uint FS_CACHE_EMPTY   = 0xFFFFFFFF;

uint[FS_CACHE_ENTRIES] fs_cache_tag;              // relative sector, or FS_CACHE_EMPTY
char* fs_cache_data;                              // FS_CACHE_ENTRIES * SECTOR_SIZE, or null
ulong fs_cache_hits;
ulong fs_cache_misses;

fn void fs_cache_init()
{
	for (uint i = 0; i < FS_CACHE_ENTRIES; i++) fs_cache_tag[i] = FS_CACHE_EMPTY;
	void* region = map_pages(FS_CACHE_ENTRIES * SECTOR_SIZE);
	// SYS_MAP returns (uptr)-1 on failure (bad size / per-process
	// ceiling). Anything else is a valid lazily-backed region.
	fs_cache_data = (uptr)region == (uptr)0xFFFFFFFFFFFFFFFF ? null : (char*)region;
}

// The storage driver's pid (diskd on QEMU, sdd on the Duo). fsd learns
// it from SYS_FS_PARTITION_INFO at mount, and re-queries it if the
// driver respawns (see g_diskd_pid / diskd_rw below) — no fixed slot.
// fsd's *own* clients (the shell) go through namespace resolution, so
// they never need to know fsd's pid at all — see user.c3's fs_read.
//
// Mutable, not `const`, since a dynamically exec()'d fsd instance
// (main()'s own args.len==1 branch, for mounting a USB Mass Storage
// device — see docs/devlog.md) resolves a completely different backend
// pid at its own startup, via the same srv_post()/ns_mount_wait()
// mechanism usbrw.c3 already uses (usbd's own pid isn't fixed either).
// diskd_rw() below is otherwise unchanged — it always just targets
// whatever this holds, boot-time-fixed 3 or a dynamically resolved pid.
// Boot fsd/fsd2 overwrite this from SYS_FS_PARTITION_INFO's storage-pid
// out-param in fs_mount(); the dynamic USB instance sets it from a
// name resolution. The initial value is just a harmless placeholder.
//
// The storage driver (diskd/sdd) is supervised now, so it can respawn
// into a new pid — diskd_rw() re-queries SYS_FS_PARTITION_INFO on an IPC
// failure and retries once, which is transparent for a boot fsd. Skipped
// for the dynamic USB instance (g_fsd_dynamic): its backend is usbd,
// resolved by name, and fs_partition_info() returns nothing useful there.
int  g_diskd_pid   = 0;
bool g_fsd_dynamic = false;

// board::FS_PARTITION_START_SECTOR, learned via syscall — board is a
// kernel-only module (see user/sdd.c3's own header comment for why),
// this is fsd's only way to learn this board-specific fact. Set once by
// fs_mount(), before either backend's probe/mount runs, since both need
// it to read sector 0 / a superblock at all.
uint fs_partition_start;

// Which backend is mounted — set once by fs_mount(), still handy for the
// P9_* block below and a couple of log lines. Plain int constants, not
// an enum: no enum usage anywhere else in this codebase.
const int FS_TYPE_NONE  = 0;
const int FS_TYPE_FAT32 = 1;
const int FS_TYPE_EXT2  = 2;
const int FS_TYPE_EXFAT = 3;
int fs_type = FS_TYPE_NONE;

// --- FS_* verb dispatch table ----------------------------------------
//
// The nine path-based FS_* verbs (FS_READ/FS_READ_AT/FS_WRITE/
// FS_WRITE_AT/FS_STAT/FS_DELETE/FS_LIST/FS_MKDIR/FS_RENAME) go through
// one Fs_ops table per backend instead of a fs_type `if` triple pasted
// into every verb branch — the empty-leaf divergence that shipped a real
// bug (see docs/devlog.md's hardening entry) was exactly the kind of
// thing three hand-maintained copies invite. main()'s loop parses the
// request into an Fs_req once, does the small amount of per-verb glue
// that genuinely isn't uniform (payload offset, protected-name gate,
// fs_write_disabled gate, the append sentinel), and calls fs_ops.<verb>.
// Adding a backend is one Fs_ops literal + its adapters; the P9_* block
// is unaffected (separate protocol, ext2-only, handled before this).
struct Fs_req
{
	char* name;      // primary path, null-terminated (wire bytes 0..99)
	char* name2;     // second path — FS_RENAME only (wire bytes 100..199)
	char* data;      // write payload, a pointer into the live wire buffer
	char* buf;       // the whole IPC buffer — reply-payload verbs (read/
	                 // read_at/list) write straight into buf[4..]
	uint  len;       // requested / max length, already clamped >= 0
	uint  offset;    // FS_READ_AT / FS_WRITE_AT (append sentinel already resolved)
	uint  uid;       // requester uid, 0xFFFFFFFF if unknown — ext2 adapters only
	bool  recursive; // FS_DELETE: empty a non-empty directory instead of refusing
	uint  out_size;  // FS_STAT: filled by the adapter
	int   out_type;  // FS_STAT: filled by the adapter (0 file, 1 dir)
}

alias FsVerbFn = fn int (Fs_req*);

struct Fs_ops
{
	FsVerbFn read;
	FsVerbFn read_at;
	FsVerbFn write;
	FsVerbFn write_at;
	FsVerbFn stat;
	FsVerbFn remove;   // FS_DELETE (`delete` reads badly next to the verb name)
	FsVerbFn list;
	FsVerbFn mkdir;
	FsVerbFn rename;
	FsVerbFn chmod;    // FS_CHMOD — ext2 only; FAT32/exFAT reply -1
	FsVerbFn chown;    // FS_CHOWN — ext2 only; FAT32/exFAT reply -1
}

// Set by fs_mount() alongside fs_type; null until a backend mounts (the
// unmounted second fsd instance — every FS_* verb then replies -1).
Fs_ops* fs_ops = null;

fn int fs_list_max()
{
	// How many FS_LIST_ENTRY_SIZE records fit in one reply after the
	// 4-byte count header — no pagination, see user.c3's own comment.
	return (int)((FS_MSG_MAX - 4) / FS_LIST_ENTRY_SIZE);
}

fn int fat32_op_read(Fs_req* r)     { return fat32_read(r.name, &r.buf[4], r.len); }
fn int fat32_op_read_at(Fs_req* r)  { return fat32_read_at(r.name, &r.buf[4], r.len, r.offset); }
fn int fat32_op_write(Fs_req* r)    { return fat32_write(r.name, r.data, r.len); }
fn int fat32_op_write_at(Fs_req* r) { return fat32_write_at(r.name, r.data, r.len, r.offset); }
fn int fat32_op_stat(Fs_req* r)     { return fat32_stat(r.name, &r.out_size, &r.out_type) ? 0 : -1; }
fn int fat32_op_remove(Fs_req* r)   { return r.recursive ? fat32_delete_recursive(r.name) : fat32_delete(r.name); }
fn int fat32_op_list(Fs_req* r)     { int c = -1; if (!fat32_list(r.name, &r.buf[4], fs_list_max(), r.offset, &c)) c = -1; return c; }
fn int fat32_op_mkdir(Fs_req* r)    { return fat32_mkdir(r.name); }
fn int fat32_op_rename(Fs_req* r)   { return fat32_rename(r.name, r.name2); }

// FAT32 and exFAT keep no i_mode / i_uid on disk — FS_CHMOD / FS_CHOWN
// against a non-ext2 mount is a clean -1, not a crash (same "reject
// cleanly" shape as the unmounted-second-instance path). r.len carries
// the mode/uid arg (wire bytes 100..103), r.uid the requester.
fn int fs_op_chattr_unsupported(Fs_req* r) { return -1; }

// r.uid is the requester's uid for reads too now (fsd's dispatch sets
// it); ext2_may_read denies a non-root user a file it has no read bit
// for. Root (uid 0) and every FAT32/exFAT path are unaffected.
fn int ext2_op_read(Fs_req* r)     { return ext2_may_read(r.name, r.uid) ? ext2_read(r.name, &r.buf[4], r.len) : -1; }
fn int ext2_op_read_at(Fs_req* r)  { return ext2_may_read(r.name, r.uid) ? ext2_read_at(r.name, &r.buf[4], r.len, r.offset) : -1; }
fn int ext2_op_write(Fs_req* r)    { return ext2_write(r.name, r.data, r.len, r.uid); }
fn int ext2_op_write_at(Fs_req* r) { return ext2_write_at(r.name, r.data, r.len, r.offset, r.uid); }
fn int ext2_op_stat(Fs_req* r)     { return ext2_may_read(r.name, r.uid) && ext2_stat(r.name, &r.out_size, &r.out_type) ? 0 : -1; }
fn int ext2_op_remove(Fs_req* r)   { return r.recursive ? ext2_delete_recursive(r.name, r.uid) : ext2_delete(r.name, r.uid); }
fn int ext2_op_list(Fs_req* r)     { if (!ext2_may_read(r.name, r.uid)) return -1; int c = -1; if (!ext2_list(r.name, &r.buf[4], fs_list_max(), r.offset, &c)) c = -1; return c; }
fn int ext2_op_mkdir(Fs_req* r)    { return ext2_mkdir(r.name, r.uid); }
fn int ext2_op_rename(Fs_req* r)   { return ext2_rename(r.name, r.name2, r.uid); }
// r.len is the mode (FS_CHMOD) or owner uid (FS_CHOWN) from wire bytes
// 100..103; r.uid is the requester. Ownership policy lives in the ext2
// functions (chmod: owner-or-root; chown: root-only).
fn int ext2_op_chmod(Fs_req* r)    { return ext2_chmod(r.name, r.len, r.uid); }
fn int ext2_op_chown(Fs_req* r)    { return ext2_chown(r.name, r.len, r.uid); }

fn int exfat_op_read(Fs_req* r)     { return exfat_read(r.name, &r.buf[4], r.len); }
fn int exfat_op_read_at(Fs_req* r)  { return exfat_read_at(r.name, &r.buf[4], r.len, r.offset); }
fn int exfat_op_write(Fs_req* r)    { return exfat_write(r.name, r.data, r.len); }
fn int exfat_op_write_at(Fs_req* r) { return exfat_write_at(r.name, r.data, r.len, r.offset); }
fn int exfat_op_stat(Fs_req* r)     { return exfat_stat(r.name, &r.out_size, &r.out_type) ? 0 : -1; }
fn int exfat_op_remove(Fs_req* r)   { return r.recursive ? exfat_delete_recursive(r.name) : exfat_delete(r.name); }
fn int exfat_op_list(Fs_req* r)     { int c = -1; if (!exfat_list(r.name, &r.buf[4], fs_list_max(), r.offset, &c)) c = -1; return c; }
fn int exfat_op_mkdir(Fs_req* r)    { return exfat_mkdir(r.name); }
fn int exfat_op_rename(Fs_req* r)   { return exfat_rename(r.name, r.name2); }

const Fs_ops FAT32_OPS = {
	.read = &fat32_op_read, .read_at = &fat32_op_read_at,
	.write = &fat32_op_write, .write_at = &fat32_op_write_at,
	.stat = &fat32_op_stat, .remove = &fat32_op_remove,
	.list = &fat32_op_list, .mkdir = &fat32_op_mkdir, .rename = &fat32_op_rename,
	.chmod = &fs_op_chattr_unsupported, .chown = &fs_op_chattr_unsupported,
};
const Fs_ops EXT2_OPS = {
	.read = &ext2_op_read, .read_at = &ext2_op_read_at,
	.write = &ext2_op_write, .write_at = &ext2_op_write_at,
	.stat = &ext2_op_stat, .remove = &ext2_op_remove,
	.list = &ext2_op_list, .mkdir = &ext2_op_mkdir, .rename = &ext2_op_rename,
	.chmod = &ext2_op_chmod, .chown = &ext2_op_chown,
};
const Fs_ops EXFAT_OPS = {
	.read = &exfat_op_read, .read_at = &exfat_op_read_at,
	.write = &exfat_op_write, .write_at = &exfat_op_write_at,
	.stat = &exfat_op_stat, .remove = &exfat_op_remove,
	.list = &exfat_op_list, .mkdir = &exfat_op_mkdir, .rename = &exfat_op_rename,
	.chmod = &fs_op_chattr_unsupported, .chown = &fs_op_chattr_unsupported,
};

// Real 9P (read-only), against ext2 only — see docs/devlog.md. No new
// verb constants or client wrappers needed: P9_ATTACH/P9_WALK/
// P9_OPEN/P9_READ/P9_CLUNK and their user.c3 wrappers already exist
// (built for echod.c3's own sandbox, entries 54/55) and work against
// any pid — the actual point of building the protocol generically
// first. This is just fsd's own dispatch for those same verbs, gated
// to fs_type == FS_TYPE_EXT2 throughout (every one of these five verbs
// returns -1 otherwise — FAT32 isn't part of this project's own real
// deployment topology anymore, entry 53, and an unmounted second
// instance already degrades everything else the same way).
const int FS9_FID_MAX = 8; // matches echod's own P9_FID_MAX precedent
struct Fs9_fid_entry
{
	bool used;
	bool opened;
	bool is_dir;
	uint inode_num; // ext2 inode number — a genuinely stable identity, unlike a path (survives a rename elsewhere, unlike ext2_cache_path)
	// Added for P9_CREATE/P9_WRITE/P9_REMOVE (see docs/devlog.md): a fid
	// only remembers the resolved inode above, not which directory entry
	// points at it — P9_REMOVE needs dir_inode/entry_sector/entry_offset
	// to clear that entry via ext2_delete_resolved(), without re-walking
	// a path a second time. has_entry is false only for a bare root fid
	// (P9_ATTACH never sets it) — root has no entry of its own to remove.
	uint parent_inode;
	uint entry_sector;
	uint entry_offset;
	bool has_entry;
}
Fs9_fid_entry[FS9_FID_MAX] fs9_fids;

// --- Write protection ---------------------------------------------

// A reserved-sector-range allowlist, enforced in diskd_rw() — see this
// file's header comment for the full rationale. Ranges (start, count),
// not individual sectors or filesystem-specific units (FAT32 clusters,
// ext2 blocks): each backend computes its own protected file's ranges
// in whatever unit is natural to it (FAT32: clusters × sectors-per-
// cluster) and hands this layer plain absolute sector ranges via
// fs_reserve_sector_range() — this layer never needs to know what a
// "cluster" or "block" is.
struct Reserved_range
{
	uint start;
	uint count;
}
const uint FS_RESERVED_MAX = 512;
Reserved_range[FS_RESERVED_MAX] fs_reserved_ranges;
uint fs_reserved_count = 0;
// Fails CLOSED (see fs_reserve_sector_range()) rather than risk
// protecting only part of a file: if the reservation list would
// overflow, or a write is attempted before fs_mount() has finished
// building it, every write is refused for the rest of this process's
// life.
bool fs_write_disabled = true;

// Records that sectors [start, start+count) must never be written to.
// Returns false and disables ALL writes for the rest of this process's
// life if the reservation list is full — failing closed rather than
// risk protecting only part of a file.
fn bool fs_reserve_sector_range(uint start, uint count)
{
	if (fs_reserved_count >= FS_RESERVED_MAX)
	{
		print("fsd: protected-file reservation list full, disabling all writes\n");
		fs_write_disabled = true;
		return false;
	}
	fs_reserved_ranges[fs_reserved_count].start = start;
	fs_reserved_ranges[fs_reserved_count].count = count;
	fs_reserved_count++;
	return true;
}

fn bool fs_sector_is_reserved(uint sector)
{
	for (uint i = 0; i < fs_reserved_count; i++)
	{
		uint start = fs_reserved_ranges[i].start;
		uint count = fs_reserved_ranges[i].count;
		if (sector >= start && sector < start + count) return true;
	}
	return false;
}

// A protected file's own directory ENTRY is deliberately NOT protected
// via the sector-range allowlist above: in FAT32 the root directory is
// itself just an ordinary cluster chain, shared by every file's entry —
// reserving "the range containing fip.bin's entry" would reserve
// sectors shared by every OTHER file's entry too, silently blocking
// them from ever being created or updated (found exactly this way, on
// real hardware, while building FAT32 write support — see
// docs/devlog.md). Instead, the entry's exact (sector, offset) is
// tracked here and checked explicitly by whichever backend writes
// directory-entry bytes — narrower than the range-allowlist check, but
// still independent of the filename comparison in
// fs_is_protected_name(), so it still catches a bug that landed on the
// right slot through some other path. Set via fs_set_protected_entry()
// rather than backends touching these globals directly, so this file
// stays the sole owner of its own protection state.
uint fs_protected_entry_sector = 0;
uint fs_protected_entry_offset = 0;
bool fs_has_protected_entry = false;

fn void fs_set_protected_entry(uint sector, uint offset)
{
	fs_protected_entry_sector = sector;
	fs_protected_entry_offset = offset;
	fs_has_protected_entry = true;
}

fn bool fs_is_protected_entry(uint sector, uint offset)
{
	return fs_has_protected_entry && sector == fs_protected_entry_sector && offset == fs_protected_entry_offset;
}

// The real, on-disk name the flashing workflow uses for this board's
// bootable image (see scripts/build_duo_fip.sh and the flash steps in
// docs/devlog.md) — plain, not filesystem-specific form (FAT32's own
// 8.3 conversion happens inside fs/fat32.c3, after this check already
// passed). QEMU's disposable test images have no such file, so this is
// simply never matched there — harmless. Sized to the string's exact
// length (7), matching HEX_DIGITS-style exact-fit literals elsewhere in
// this codebase, rather than relying on any particular literal-to-array
// null-padding behavior.
const char[7] FS_PROTECTED_NAME = "fip.bin";

// Case-insensitive compare against FS_PROTECTED_NAME. `name` must be
// null-terminated — guaranteed by user.c3's fs_read/fs_write, which
// always null-terminate the wire-format filename field before sending.
fn bool fs_is_protected_name(char* name)
{
	for (uint i = 0; i < 7; i++)
	{
		char c = name[i];
		if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
		if (c != FS_PROTECTED_NAME[i]) return false;
	}
	return name[7] == 0;
}

// --- Sector I/O ------------------------------------------------------

// Same request/reply shape as diskd's own protocol (see user/diskd.c3):
// byte 0 = status, bytes 4.. = the sector's data (write request / read
// reply only). Talking to diskd/sdd is ordinary blocking IPC here — see
// this file's header comment for why that's safe, unlike diskd's own
// interrupt-wait.
fn bool diskd_rw(char* buf, uint sector, bool is_write)
{
	// The actual write-protection enforcement point — see this file's
	// header comment. `sector` here is always partition-absolute (every
	// call site adds fs_partition_start first), so it's converted back
	// to partition-relative before checking against fs_reserved_ranges,
	// which is expressed in the same relative terms each backend
	// computed its own volume layout in.
	if (is_write)
	{
		if (fs_write_disabled) return false;
		if (fs_sector_is_reserved(sector - fs_partition_start)) return false;
	}

	char[DISKD_MSG_MAX] req @noinit;
	uint* sector_field = (uint*)&req;
	*sector_field = sector;
	if (is_write)
	{
		for (uint i = 0; i < SECTOR_SIZE; i++)
		{
			req[4 + i] = buf[i];
		}
	}

	uint verb = is_write ? DISKD_WRITE : DISKD_READ;
	uint reply_verb = 0;
	int from = p9_call(g_diskd_pid, verb, &req, DISKD_MSG_MAX, &req, DISKD_MSG_MAX, &reply_verb);
	if (from <= 0 && !g_fsd_dynamic)
	{
		// The storage driver may have died and been respawned —
		// SYS_IPC_CALL aborts with -1 when its target's slot is gone.
		// Ask the kernel for the current storage pid and retry once; the
		// supervisor's re-init leaves the device usable again.
		//
		// Deliberately NOT gated on `rr_pid != g_diskd_pid`: the
		// supervisor respawns into the *same slot*, hence the same pid
		// (pid = slot + 1), with only the generation bumped — so "the
		// pid didn't change" is the common case, not a reason to skip
		// the retry. A p9_call to a genuinely-dead pid returns fast, so
		// an occasional pointless retry is cheap. (This was the Duo
		// storagekilltest failure: QEMU's respawn is fast enough that
		// the first p9_call already hits the live replacement, so the
		// retry never mattered there.)
		uint rr_part = 0;
		int  rr_pid  = 0;
		if (fs_partition_info(&rr_part, null, &rr_pid) == 0 && rr_pid > 0)
		{
			g_diskd_pid = rr_pid;
			reply_verb = 0;
			from = p9_call(g_diskd_pid, verb, &req, DISKD_MSG_MAX, &req, DISKD_MSG_MAX, &reply_verb);
		}
	}
	if (from <= 0 || reply_verb != verb) return false;

	char status = req[0];
	if (!is_write)
	{
		for (uint i = 0; i < SECTOR_SIZE; i++)
		{
			buf[i] = req[4 + i];
		}
	}
	return status == 0;
}

// Adds the board's real partition-start offset before every read — see
// board::FS_PARTITION_START_SECTOR's own comment (boards/*/board.c3) for
// why this exists and what it's set to per board. Shared by every
// backend — neither FAT32 nor ext2 touches fs_partition_start directly.
fn bool fs_read_sector(uint sector, char* buf)
{
	if (fs_cache_data != null)
	{
		uint idx = sector % FS_CACHE_ENTRIES;
		char* slot = &fs_cache_data[(uptr)idx * SECTOR_SIZE];
		if (fs_cache_tag[idx] == sector)
		{
			for (uint i = 0; i < SECTOR_SIZE; i++) buf[i] = slot[i];
			fs_cache_hits++;
			return true;
		}
		if (!diskd_rw(buf, fs_partition_start + sector, false)) return false;
		for (uint i = 0; i < SECTOR_SIZE; i++) slot[i] = buf[i];
		fs_cache_tag[idx] = sector;
		fs_cache_misses++;
		return true;
	}
	return diskd_rw(buf, fs_partition_start + sector, false);
}

// Write counterpart to fs_read_sector — every filesystem-level write in
// this process (data, FAT/inode-table entries, directory entries) goes
// through this, which goes through diskd_rw()'s reserved-sector check.
// Write-through: on success the cache slot is refreshed so a later read
// of the same sector sees the new data (diskd_rw is atomic per sector —
// it either wrote the whole sector or returned false and touched
// nothing, so the slot and the disk never disagree).
fn bool fs_write_sector(uint sector, char* buf)
{
	bool ok = diskd_rw(buf, fs_partition_start + sector, true);
	if (fs_cache_data != null)
	{
		uint idx = sector % FS_CACHE_ENTRIES;
		if (ok)
		{
			char* slot = &fs_cache_data[(uptr)idx * SECTOR_SIZE];
			for (uint i = 0; i < SECTOR_SIZE; i++) slot[i] = buf[i];
			fs_cache_tag[idx] = sector;
		}
		else if (fs_cache_tag[idx] == sector)
		{
			// A rejected write leaves the disk unchanged, but a write
			// that reached the platter then lost its reply (driver died
			// past the point of no return, retry didn't reconnect) would
			// not — drop the slot so the next read goes to disk.
			fs_cache_tag[idx] = FS_CACHE_EMPTY;
		}
	}
	return ok;
}

// --- Mount-time backend dispatch --------------------------------------

// Prints the reservation-list outcome after a backend's own
// *_reserve_protected() call — identical for every backend (there's
// nothing filesystem-specific about "how many sector ranges got
// reserved"), so shared here rather than duplicated in fs_mount()'s
// per-backend branches below.
fn void fs_reserve_protection_summary()
{
	print("fsd: write-protected ");
	print_uint(fs_reserved_count);
	print(" sector range(s)");
	if (fs_write_disabled) print(" — writes DISABLED");
	print("\n");
}

// dynamic_mode/dynamic_self_name: for a dynamically exec()'d instance
// (main()'s own args.len==1 branch) mounting a USB Mass Storage device
// instead of a board-fixed partition — see docs/devlog.md. When true,
// fs_partition_start is already set (main()'s own MBR-parse, since a
// removable drive's real filesystem doesn't start at a board-fixed
// compile-time sector the way the SD card's does) and
// fs_partition_info() is skipped entirely (meaningless here — that
// syscall only ever returns real data for the two create_process()-
// spawned instances, fsd/fsd2), and dynamic_self_name is always
// srv_post()-ed once mounted, unconditionally (there's no
// is_secondary concept for a dynamic instance — it's simply the only
// instance of itself).
fn void fs_mount(bool dynamic_mode, char* dynamic_self_name)
{
	g_fsd_dynamic = dynamic_mode;
	bool is_secondary = false;
	if (!dynamic_mode)
	{
		int resolved_storage = 0;
		if (fs_partition_info(&fs_partition_start, &is_secondary, &resolved_storage) < 0)
		{
			panic("fsd: ", "failed to get partition info");
		}
		// Boot fsd/fsd2 target whichever pid the kernel spawned the
		// block driver at — no longer a hardcoded 3. (The dynamic USB
		// instance resolves its own backend by name instead — see
		// g_diskd_pid's comment and the srv_post path below.)
		if (resolved_storage > 0) { g_diskd_pid = resolved_storage; }
	}

	// ext2 first: its magic is a specific 16-bit value at a fixed byte
	// offset, about as unambiguous as a signature check gets. FAT32's
	// own 0xAA55 is a much weaker signal (shared with plain MBRs and
	// every other x86-bootable format), so it's the fallback, not the
	// first guess.
	if (ext2_probe())
	{
		fs_type = FS_TYPE_EXT2;
		fs_ops = &EXT2_OPS;
		ext2_mount();
		// Write protection: build the reserved-range allowlist before
		// ever allowing a write — fs_write_disabled starts true (see
		// its own comment) and only comes down once this succeeds
		// without overflow. Same sequence as the FAT32 branch below —
		// see fs_reserve_protection_summary()'s own comment for why
		// it's shared rather than duplicated per backend.
		fs_write_disabled = false;
		// /tmp: a real scratch directory, self-created here rather than
		// baked into a disk image or an SD card — works identically on
		// QEMU and the real Duo with zero manual setup. Idempotent:
		// ext2_mkdir() already returns -1 ("already exists") harmlessly
		// once this has run before, which is the expected steady state
		// from the second boot on. Result deliberately ignored — a
		// failure here (e.g. fs_write_disabled flipping back on if
		// fs_reserve_sector_range overflows further down) just means
		// /tmp isn't there yet, same as if this line didn't exist.
		ext2_mkdir("tmp", 0); // owned by root — this is fsd itself creating it, at mount time, not on any particular requester's behalf
		ext2_reserve_protected(&FS_PROTECTED_NAME);
		fs_reserve_protection_summary();
		// Real Plan9-style bind/mount, for real: only the *second* fsd
		// instance ever announces itself — the root fsd never needs a
		// name, it's already reachable via the unchanged "" catch-all.
		// This is what create_process()'s own default "/mnt/fs2/" ->
		// fsd2_pid binding (src/process.c3) is itself just one static
		// use of — shell.c3's own mounttest proves the same name is
		// genuinely re-mountable later via real ns_unmount()/ns_mount()
		// syscalls, not just boot-time plumbing.
		if (dynamic_mode) { srv_post(dynamic_self_name); } else if (is_secondary) { srv_post("fs2"); }
		return;
	}
	// exFAT next: its "EXFAT   " signature (exfat_probe) is just as
	// unambiguous as ext2's magic, so it's tried before FAT32's own weak
	// 0xAA55 fallback below — same reasoning as the ext2-before-FAT32
	// ordering above.
	if (exfat_probe())
	{
		fs_type = FS_TYPE_EXFAT;
		fs_ops = &EXFAT_OPS;
		exfat_mount();
		// Writes (create/overwrite/delete/mkdir — see exfat.c3's Write
		// path section) only if exfat_mount() found a usable volume
		// layout: the Allocation Bitmap present, and exactly one FAT.
		// Otherwise the backend stays read-only, same as it was before
		// this support existed. Same protected-file sequence as the
		// FAT32/ext2 branches — see fs_reserve_protection_summary()'s
		// own comment for why it's shared.
		if (exfat_writes_ok)
		{
			fs_write_disabled = false;
			exfat_reserve_protected(&FS_PROTECTED_NAME);
			fs_reserve_protection_summary();
		}
		if (dynamic_mode) { srv_post(dynamic_self_name); } else if (is_secondary) { srv_post("fs2"); }
		return;
	}
	if (fat32_probe())
	{
		fs_type = FS_TYPE_FAT32;
		fs_ops = &FAT32_OPS;
		fat32_mount();
		fs_write_disabled = false;
		// See the ext2 branch's own comment above — same reasoning.
		fat32_mkdir("tmp");
		fat32_reserve_protected(&FS_PROTECTED_NAME);
		fs_reserve_protection_summary();
		// See the ext2 branch's own comment above — same reasoning.
		if (dynamic_mode) { srv_post(dynamic_self_name); } else if (is_secondary) { srv_post("fs2"); }
		return;
	}

	// Deliberately NOT panic()/exit() here, unlike every other failure
	// in this function — this one is a normal, expected outcome (the
	// second fsd instance, booting against an image/card that only has
	// one partition — see boards/*/board.c3's HAS_SECOND_FS_PARTITION),
	// not an internal error. exit() would free this process's pid slot,
	// which the *next* process created (ordinarily the shell) would then
	// likely inherit — silently making this server's own namespace
	// prefix (e.g. "/2/") route straight back to whatever process now
	// occupies that reused pid. Concretely, sending yourself an IPC
	// message deadlocks (SYS_IPC_SEND parks the sender waiting for a
	// receive it can't issue until the send itself returns) — found
	// exactly this way, real hardware/QEMU testing during this session's
	// multi-mount work (see docs/devlog.md). Returning normally instead
	// leaves fs_type at its default FS_TYPE_NONE, and main()'s own
	// dispatch below already handles that case correctly for every
	// verb — same "reject cleanly, don't crash" shape as an ext2-mounted
	// volume already rejects writes.
	print("fsd: no recognized filesystem found — this mount stays inactive\n");
}

// Real MBR partition table parsing — new this session (see
// docs/devlog.md), needed only by main()'s own dynamic-mount branch: a
// removable USB drive's real filesystem doesn't start at a board-fixed
// compile-time sector the way the SD card's does (board::
// FS_PARTITION_START_SECTOR), so this has to actually read and parse
// LBA 0. Standard, stable, decades-old format: 0x55AA signature at
// byte offset 510-511, four 16-byte partition entries starting at
// offset 446 (type byte at +4, LBA-start u32 LE at +8). Takes the
// FIRST non-empty (type != 0) entry — good enough for the overwhelming
// majority of real single-partition USB drives; multiple primary
// partitions, extended/logical partitions, and GPT are all real,
// deliberately out of scope for this driver, same "narrow scope
// first" approach every other feature here has used. Falls back to
// `*out_start = 0` (whole-disk, no partition table — a "superfloppy"-
// formatted drive) if the signature is missing or every entry is
// empty, rather than failing outright.
// GPT support — real, sourced necessity, not scope creep for its own
// sake: the actual USB drive this feature was built and tested against
// (a real Transcend 32GB stick) turned out to be GPT-partitioned, found
// via a raw byte dump during real-hardware testing (docs/devlog.md) —
// entry 0 was type 0xEE ("GPT Protective", the standard placeholder a
// GPT disk's own legacy MBR carries for backward compatibility) with
// LBA-start 1, which is exactly where a GPT header lives, not a real
// filesystem — treating that as a real filesystem's own start sector is
// exactly the bug that raw dump caught. Real GPT format: the header at
// LBA 1 ("EFI PART" 8-byte signature at offset 0, PartitionEntryLBA u64
// LE at offset 72), then the partition entry array (128 bytes/entry by
// convention) starting at that LBA — this only ever reads the very
// first entry, same "first partition wins" scope as the classic-MBR
// path. Only the low 32 bits of the two real 64-bit LBA fields are
// read — every sector number this driver ever handles is a plain uint
// (fs_partition_start, diskd_rw's own sector parameter), and no
// realistic USB flash drive's own partition table needs more than 32
// bits' worth of sectors (2TB+) for this to matter.
fn void fs_parse_gpt_partition_start(uint* out_start)
{
	char[SECTOR_SIZE] gpt_header @noinit;
	if (!diskd_rw(&gpt_header[0], 1, false)) { return; }

	char* sig = "EFI PART";
	for (uint i = 0; i < 8; i++)
	{
		if (gpt_header[i] != sig[i]) { return; } // not a real GPT header — leave *out_start at its caller-set default
	}

	uint* entry_lba_field = (uint*)&gpt_header[72];
	uint entry_lba = *entry_lba_field;

	char[SECTOR_SIZE] entry_sector @noinit;
	if (!diskd_rw(&entry_sector[0], entry_lba, false)) { return; }

	// PartitionTypeGUID (16 bytes, offset 0 of the first entry) —
	// all-zero means this entry slot is unused.
	bool used = false;
	for (uint i = 0; i < 16; i++)
	{
		if (entry_sector[i] != (char)0) { used = true; break; }
	}
	if (!used) { return; }

	uint* starting_lba_field = (uint*)&entry_sector[32]; // StartingLBA
	*out_start = *starting_lba_field;
}

fn void fs_parse_mbr_partition_start(uint* out_start)
{
	char[SECTOR_SIZE] mbr @noinit;
	*out_start = 0;
	if (!diskd_rw(&mbr[0], 0, false)) { return; }

	if ((mbr[510] != (char)0x55) || (mbr[511] != (char)0xAA)) { return; }

	// GPT protective MBR — see fs_parse_gpt_partition_start's own
	// comment. Real GPT disks always encode this as entry 0 specifically
	// (the spec requires it), so checking only that one entry is
	// correct, not a simplification.
	if (mbr[446 + 4] == (char)0xEE)
	{
		fs_parse_gpt_partition_start(out_start);
		return;
	}

	for (uint entry = 0; entry < 4; entry++)
	{
		uint off = 446 + entry * 16;
		char part_type = mbr[off + 4];
		if (part_type == (char)0)
		{
			continue;
		}
		uint* lba_start_field = (uint*)&mbr[off + 8];
		*out_start = *lba_start_field;
		return;
	}
}

// The uid of the process that sent request `from`, for the ext2 backend
// to enforce i_uid ownership against (fat32/exfat have no uid concept in
// their on-disk format). fsd is a boot-time server, always root, acting
// on a real requester's behalf — it can't trust its own identity the way
// SYS_KILL/SYS_SRV_POST trust current_proc, so it looks up who *actually*
// asked. A failed lookup (the requester's process is already gone, a rare
// race) returns 0xFFFFFFFF, which is never a real uid and never root, so
// the backend's own check fails closed (an existing file's overwrite gets
// refused rather than silently trusted). Every FS_WRITE / FS_WRITE_AT /
// FS_DELETE / FS_MKDIR / FS_RENAME ext2 arm, and the P9_* write arms, use
// this.
fn uint fsd_requester_uid(int from)
{
	uint uid = 0xFFFFFFFF;
	proc_info(from, null, null, (int*)&uid);
	return uid;
}

fn void main(String[] args)
{
	// Read cache — before fs_mount() so its superblock / inode-table /
	// protected-file-chain reads populate it too (those blocks stay hot).
	fs_cache_init();

	if (args.len == 1)
	{
		// Dynamic mount (e.g. "usbd" — usbd.c3's own srv_post()-ed name;
		// its usb_msc_ipc_poll() is diskd-compatible) — see this
		// function's own header comment and fs_mount()'s for the full
		// reasoning. Builds "/srv/<name>/" from args[0] since it's a real
		// runtime string, not something usbrw.c3's own hardcoded
		// "/srv/usbd/" precedent could just reuse literally.
		char[48] backend_prefix @noinit;
		char* lit = "/srv/";
		uint bp_i = 0;
		while (lit[bp_i] != 0) { backend_prefix[bp_i] = lit[bp_i]; bp_i++; }
		uint name_i = 0;
		while (args[0].ptr[name_i] != 0 && bp_i < 46) { backend_prefix[bp_i] = args[0].ptr[name_i]; bp_i++; name_i++; }
		backend_prefix[bp_i] = (char)'/';
		bp_i++;
		backend_prefix[bp_i] = 0;

		if (ns_mount_wait(&backend_prefix[0], args[0].ptr, 200) < 0)
		{
			print("fsd: dynamic backend \"");
			print(args[0].ptr);
			print("\" never posted, giving up\n");
			exit();
		}
		int resolved_pid = ns_resolve(&backend_prefix[0], null);
		if (resolved_pid < 0)
		{
			print("fsd: dynamic backend \"");
			print(args[0].ptr);
			print("\" resolved but ns_resolve failed\n");
			exit();
		}
		g_diskd_pid = resolved_pid;
		print("fsd: dynamic backend \"");
		print(args[0].ptr);
		print("\" resolved, pid=");
		print_uint((uint)resolved_pid);
		print(", reading MBR...\n");

		fs_parse_mbr_partition_start(&fs_partition_start);
		print("fsd: dynamic mount: fs_partition_start=");
		print_uint(fs_partition_start);
		print(", probing...\n");
		fs_mount(true, "usbfs");
		print("fsd: dynamic mount: fs_mount() returned, fs_type=");
		print_uint((uint)fs_type);
		print("\n");
	}
	else
	{
		fs_mount(false, null);
	}

	for (;;)
	{
		char[FS_MSG_MAX] buf @noinit;
		uint verb = 0;
		uint from_gen = 0;
		int from = ipc_recv_type_gen(&buf, FS_MSG_MAX, &verb, &from_gen);
		if (from <= 0) continue;

		// Real 9P (read-only, ext2 only) — entirely separate wire
		// layout from FS_*'s own (fid/newfid/name/offset/count at fixed
		// offsets, exactly what echod.c3 already established for these
		// same verbs), handled and replied to here before any of the
		// FS_*-specific parsing below, then `continue`s straight back
		// to the top of this loop.
		if (verb == P9_ATTACH || verb == P9_WALK || verb == P9_OPEN || verb == P9_READ || verb == P9_CLUNK
			|| verb == P9_CREATE || verb == P9_WRITE || verb == P9_REMOVE)
		{
			if (fs_type != FS_TYPE_EXT2)
			{
				int* p9_fail_field = (int*)&buf;
				*p9_fail_field = -1;
				ipc_reply(from, verb, &buf, 4, from_gen);
				continue;
			}

			if (verb == P9_ATTACH)
			{
				uint* fid_field = (uint*)&buf[0];
				uint fid = *fid_field;
				int result = -1;
				if (fid < (uint)FS9_FID_MAX && !fs9_fids[fid].used)
				{
					fs9_fids[fid].used = true;
					fs9_fids[fid].opened = false;
					fs9_fids[fid].is_dir = true;
					fs9_fids[fid].inode_num = EXT2_ROOT_INODE;
					fs9_fids[fid].has_entry = false; // root has no directory entry of its own
					result = 0;
				}
				int* result_field = (int*)&buf[0];
				*result_field = result;
				ipc_reply(from, P9_ATTACH, &buf, 4, from_gen);
			}
			else if (verb == P9_WALK)
			{
				uint* fid_field = (uint*)&buf[0];
				uint* newfid_field = (uint*)&buf[4];
				uint fid = *fid_field;
				uint newfid = *newfid_field;
				char* name = &buf[8];
				int result = -1;
				if (fid < (uint)FS9_FID_MAX && fs9_fids[fid].used && fs9_fids[fid].is_dir
					&& newfid < (uint)FS9_FID_MAX && !fs9_fids[newfid].used)
				{
					uint new_inode;
					uint new_entry_sector;
					uint new_entry_offset;
					uint mode;
					if (ext2_find_in_dir(fs9_fids[fid].inode_num, name, &new_inode, &new_entry_sector, &new_entry_offset, &mode))
					{
						fs9_fids[newfid].used = true;
						fs9_fids[newfid].opened = false;
						fs9_fids[newfid].is_dir = (mode & EXT2_S_IFDIR) != 0;
						fs9_fids[newfid].inode_num = new_inode;
						fs9_fids[newfid].parent_inode = fs9_fids[fid].inode_num;
						fs9_fids[newfid].entry_sector = new_entry_sector;
						fs9_fids[newfid].entry_offset = new_entry_offset;
						fs9_fids[newfid].has_entry = true;
						result = 0;
					}
				}
				int* result_field = (int*)&buf[0];
				*result_field = result;
				ipc_reply(from, P9_WALK, &buf, 4, from_gen);
			}
			else if (verb == P9_OPEN)
			{
				uint* fid_field = (uint*)&buf[0];
				uint fid = *fid_field;
				int result = -1;
				if (fid < (uint)FS9_FID_MAX && fs9_fids[fid].used && !fs9_fids[fid].is_dir)
				{
					// Read-permission check (ext2 only carries i_uid;
					// FAT32/exFAT have no ownership, so ext2_read_allowed
					// there just isn't consulted). Root always passes.
					Ext2_inode_info oi;
					bool may = fs_type != FS_TYPE_EXT2
						|| (ext2_read_inode(fs9_fids[fid].inode_num, &oi)
							&& ext2_read_allowed(&oi, fsd_requester_uid(from)));
					if (may)
					{
						fs9_fids[fid].opened = true;
						result = 0;
					}
				}
				int* result_field = (int*)&buf[0];
				*result_field = result;
				ipc_reply(from, P9_OPEN, &buf, 4, from_gen);
			}
			else if (verb == P9_READ)
			{
				uint* fid_field = (uint*)&buf[0];
				uint* p9_offset_field = (uint*)&buf[4];
				uint* p9_count_field = (uint*)&buf[8];
				uint fid = *fid_field;
				uint p9_offset = *p9_offset_field;
				uint p9_count = *p9_count_field;
				int result_len = -1;
				if (fid < (uint)FS9_FID_MAX && fs9_fids[fid].used && fs9_fids[fid].opened)
				{
					if (p9_count > FS_MSG_MAX - 4) p9_count = FS_MSG_MAX - 4;
					result_len = ext2_read_inode_at(fs9_fids[fid].inode_num, &buf[4], p9_count, p9_offset);
				}
				int* result_len_field2 = (int*)&buf[0];
				*result_len_field2 = result_len;
				int p9_reply_len = 4 + (result_len > 0 ? result_len : 0);
				ipc_reply(from, P9_READ, &buf, p9_reply_len, from_gen);
			}
			else if (verb == P9_CLUNK)
			{
				uint* fid_field = (uint*)&buf[0];
				uint fid = *fid_field;
				int result = -1;
				if (fid < (uint)FS9_FID_MAX && fs9_fids[fid].used)
				{
					fs9_fids[fid].used = false;
					result = 0;
				}
				int* result_field = (int*)&buf[0];
				*result_field = result;
				ipc_reply(from, P9_CLUNK, &buf, 4, from_gen);
			}
			else if (verb == P9_CREATE)
			{
				// Wire format: fid (4) + perm (4) + name (null-
				// terminated, same 32-byte-max convention P9_WALK's
				// own name field uses — see user.c3's p9_create
				// wrapper). perm & P9_DMDIR selects a real directory
				// create instead of a file — the real Plan9 DMDIR bit,
				// matching this project's existing care about real 9P
				// semantics elsewhere in this series.
				uint* fid_field = (uint*)&buf[0];
				uint* perm_field = (uint*)&buf[4];
				uint fid = *fid_field;
				uint perm = *perm_field;
				bool want_dir = (perm & P9_DMDIR) != 0;
				char* name = &buf[8];
				int result = -1;
				if (fid < (uint)FS9_FID_MAX && fs9_fids[fid].used && fs9_fids[fid].is_dir)
				{
					uint requester_uid = fsd_requester_uid(from);
					uint dir_inode = fs9_fids[fid].inode_num;
					uint new_inode_num;
					// ext2_mkdir_resolved doesn't hand back a new
					// inode number at all (unlike ext2_create_file) —
					// either way, the shared "create then re-find for
					// the entry's own position" step below is what
					// actually fills new_inode_num, same convention
					// ext2_write's own "doesn't exist yet" branch
					// already uses.
					bool created = want_dir
						? ext2_mkdir_resolved(dir_inode, name, requester_uid) == 0
						: ext2_create_file(dir_inode, name, &new_inode_num, requester_uid);
					if (created)
					{
						uint new_entry_sector;
						uint new_entry_offset;
						uint mode;
						if (ext2_find_in_dir(dir_inode, name, &new_inode_num, &new_entry_sector, &new_entry_offset, &mode))
						{
							// The fid transforms in place — real 9P's
							// own actual Tcreate semantics, not a
							// separate newfid. Only a regular file
							// comes back open, matching Tcreate's own
							// contract there (no separate Topen
							// needed); "opened" has no meaning for a
							// directory fid in this driver's own model
							// (only P9_WALK/P9_REMOVE ever touch one,
							// neither checks it — same reasoning
							// P9_ATTACH's own root fid already follows).
							fs9_fids[fid].parent_inode = dir_inode;
							fs9_fids[fid].inode_num = new_inode_num;
							fs9_fids[fid].is_dir = want_dir;
							fs9_fids[fid].entry_sector = new_entry_sector;
							fs9_fids[fid].entry_offset = new_entry_offset;
							fs9_fids[fid].has_entry = true;
							fs9_fids[fid].opened = !want_dir;
							result = 0;
						}
					}
				}
				int* result_field = (int*)&buf[0];
				*result_field = result;
				ipc_reply(from, P9_CREATE, &buf, 4, from_gen);
			}
			else if (verb == P9_WRITE)
			{
				// Wire format: fid (4) + offset (4) + count (4) + data
				// at byte 12.. — see user.c3's p9_write wrapper. Real
				// pwrite()-style offset-aware write, via
				// ext2_write_file_at() — see its own comment for why
				// writing past the current end is rejected (-1) rather
				// than silently creating a hole, and why appending
				// exactly at the current end is still allowed.
				uint* fid_field = (uint*)&buf[0];
				uint* p9_offset_field = (uint*)&buf[4];
				uint* p9_count_field = (uint*)&buf[8];
				uint fid = *fid_field;
				uint p9_offset = *p9_offset_field;
				uint p9_count = *p9_count_field;
				int result = -1;
				if (fid < (uint)FS9_FID_MAX && fs9_fids[fid].used && fs9_fids[fid].opened
					&& !fs9_fids[fid].is_dir)
				{
					if (p9_count > FS_MSG_MAX - 12) p9_count = FS_MSG_MAX - 12;
					uint requester_uid = fsd_requester_uid(from);
					// Re-read fresh rather than trust anything cached
					// on the fid — same "re-derive, don't trust stale
					// state" discipline P9_READ already follows.
					Ext2_inode_info inode;
					if (ext2_read_inode(fs9_fids[fid].inode_num, &inode) && ext2_write_allowed(&inode, requester_uid))
					{
						int written = ext2_write_file_at(&inode, &buf[12], p9_count, p9_offset);
						if (written >= 0)
						{
							uint new_end = p9_offset + (uint)written;
							if (new_end > inode.size) inode.size = new_end;
							if (ext2_write_inode(fs9_fids[fid].inode_num, &inode)) result = written;
						}
					}
				}
				int* result_field = (int*)&buf[0];
				*result_field = result;
				ipc_reply(from, P9_WRITE, &buf, 4, from_gen);
			}
			else // P9_REMOVE
			{
				uint* fid_field = (uint*)&buf[0];
				uint fid = *fid_field;
				int result = -1;
				if (fid < (uint)FS9_FID_MAX && fs9_fids[fid].used)
				{
					// The dangling-fid safety check this entry's own
					// devlog write-up is about: fids resolve to a
					// stable inode, not a path, so removing this
					// inode while another fid still references it
					// would let that fid keep reading/writing
					// freed-and-possibly-reallocated blocks. Rejected
					// outright — no on-disk removal is even attempted,
					// so (unlike a genuine attempt below) the fid
					// stays open and the caller can retry once the
					// other fid is clunked.
					bool dangling = false;
					for (uint i = 0; i < (uint)FS9_FID_MAX; i++)
					{
						if (i == fid) continue;
						if (fs9_fids[i].used && fs9_fids[i].inode_num == fs9_fids[fid].inode_num)
						{
							dangling = true;
							break;
						}
					}
					if (!dangling)
					{
						if (fs9_fids[fid].has_entry)
						{
							uint requester_uid = fsd_requester_uid(from);
							Ext2_inode_info inode;
							if (ext2_read_inode(fs9_fids[fid].inode_num, &inode))
							{
								result = ext2_delete_resolved(fs9_fids[fid].parent_inode, fs9_fids[fid].inode_num, fs9_fids[fid].entry_sector, fs9_fids[fid].entry_offset, inode.mode, requester_uid);
							}
						}
						// Matches real 9P's own Tremove contract
						// exactly: a genuinely attempted removal
						// consumes the fid regardless of whether it
						// actually succeeded.
						fs9_fids[fid].used = false;
					}
				}
				int* result_field = (int*)&buf[0];
				*result_field = result;
				ipc_reply(from, P9_REMOVE, &buf, 4, from_gen);
			}
			continue;
		}

		if (verb == FS_CACHE_STATS)
		{
			ulong* stat_out = (ulong*)&buf;
			stat_out[0] = fs_cache_hits;
			stat_out[1] = fs_cache_misses;
			ipc_reply(from, FS_CACHE_STATS, &buf, 16, from_gen);
			continue;
		}

		if (verb != FS_READ && verb != FS_READ_AT && verb != FS_WRITE && verb != FS_WRITE_AT && verb != FS_STAT && verb != FS_DELETE && verb != FS_LIST && verb != FS_MKDIR && verb != FS_RENAME && verb != FS_CHMOD && verb != FS_CHOWN) continue;

		int* result_len_field = (int*)&buf;

		// Pull the filename and requested length out before touching buf
		// again — the reply reuses the same offsets for different things
		// (result length at 0..3, data at 4..), so anything needed from
		// the request has to be captured first. Shared prefix layout for
		// both verbs (see user.c3's wire-format comment) — FS_WRITE's
		// data follows at byte 104, read directly out of `buf` below
		// rather than copied, same as FS_READ writes its reply directly
		// into `buf` without an intermediate copy. Passed to each
		// backend as a plain, null-terminated string — any filesystem-
		// specific name normalization (FAT32's 8.3 form) happens inside
		// that backend, not here.
		char[100] filename @noinit;
		mem::copy(&filename, &buf, 100);
		// The wrappers in user.c3 null-terminate at <= 99 chars, but a
		// buggy or hostile client could send 100 non-null bytes — force
		// the terminator so every backend's own string walk stays inside
		// this buffer no matter what arrived on the wire.
		filename[99] = 0;
		// Trailing-slash normalization, one place for every backend and
		// verb: the mount prefix is already stripped on the wire, so
		// what's left is a bare name that a real filesystem never spells
		// with a trailing '/'. `ls /` arrives here as "/" and `ls /bin/`
		// as "/bin/" — collapse both (the first all the way to "", which
		// every backend's own name walk already reads as "the root").
		{
			int fn_end = 0;
			while (filename[fn_end] != 0) fn_end++;
			while (fn_end > 0 && filename[fn_end - 1] == '/') { fn_end--; filename[fn_end] = 0; }
		}
		// FS_RENAME-only (see user.c3's own wire-format comment) — every
		// other verb's byte 100.. means something else entirely (a
		// length, a recursive flag, listing output), captured unconditionally
		// here anyway, same "grab everything before buf gets reused for the
		// reply" discipline this whole block already follows.
		char[100] new_filename @noinit;
		for (int i = 0; i < 100; i++)
		{
			new_filename[i] = buf[100 + i];
		}
		new_filename[99] = 0; // same untrusted-length guard as filename above
		{
			int nfn_end = 0;
			while (new_filename[nfn_end] != 0) nfn_end++;
			while (nfn_end > 0 && new_filename[nfn_end - 1] == '/') { nfn_end--; new_filename[nfn_end] = 0; }
		}
		uint* len_field = (uint*)&buf[100];
		int req_len = (int)*len_field;
		// Untrusted input — clamp rather than trust the caller not to
		// set the field's high bit. See docs/devlog.md for the same
		// hardening pass that added this check.
		if (req_len < 0) req_len = 0;
		// FS_READ_AT-only (see user.c3's own wire-format comment) — every
		// other verb's byte 104.. means something else entirely (write
		// data, listing output), captured unconditionally here anyway,
		// same "grab everything before buf gets reused for the reply"
		// discipline this whole block already follows.
		uint* offset_field = (uint*)&buf[104];
		uint req_offset = *offset_field;

		// One table lookup, then the small amount of per-verb glue that
		// genuinely isn't uniform across backends: which wire bytes the
		// payload sits at, and which gate applies (protected-name for the
		// writes, fs_write_disabled for mkdir/rename, the append
		// sentinel). Everything filesystem-specific is in fs_ops, set at
		// mount — the FS_TYPE `if` triple that used to be pasted into
		// every one of these branches is gone.
		if (fs_ops == null)
		{
			// The unmounted second fsd instance — nothing to serve.
			*result_len_field = -1;
			ipc_reply(from, verb, &buf, FS_MSG_MAX, from_gen);
			continue;
		}

		Fs_req r;
		r.name = &filename;
		r.name2 = &new_filename;
		r.buf = &buf;
		r.data = null;
		r.len = 0;
		r.offset = req_offset;
		r.uid = 0xFFFFFFFF;
		r.recursive = false;
		r.out_size = 0;
		r.out_type = 0;

		int result = -1;
		switch (verb)
		{
			case FS_READ:
			{
				if (req_len > (int)(FS_MSG_MAX - 4)) req_len = (int)(FS_MSG_MAX - 4);
				r.len = (uint)req_len;
				r.uid = fsd_requester_uid(from);
				result = fs_ops.read(&r);
			}
			case FS_READ_AT:
			{
				if (req_len > (int)(FS_MSG_MAX - 4)) req_len = (int)(FS_MSG_MAX - 4);
				r.len = (uint)req_len;
				r.uid = fsd_requester_uid(from);
				result = fs_ops.read_at(&r);
			}
			case FS_LIST:
			{
				// max_entries / no-pagination is fs_list_max()'s and
				// user.c3's concern — nothing to set up here.
				r.uid = fsd_requester_uid(from);
				result = fs_ops.list(&r);
			}
			case FS_STAT:
			{
				// Reply: 0..3 = 0/-1, 4..7 = size (uint), 8 = type
				// (0 file, 1 dir). The adapter fills r.out_size/out_type.
				r.uid = fsd_requester_uid(from);
				result = fs_ops.stat(&r);
				uint* stat_size_field = (uint*)&buf[4];
				*stat_size_field = r.out_size;
				buf[8] = (char)r.out_type;
			}
			case FS_WRITE:
			{
				if (req_len > (int)(FS_MSG_MAX - 104)) req_len = (int)(FS_MSG_MAX - 104);
				r.len = (uint)req_len;
				r.data = &buf[104];
				// Protected-name fast gate — an obvious first refusal
				// before any backend runs; diskd_rw()'s reserved-sector
				// check is the real backstop.
				if (!fs_is_protected_name(&filename))
				{
					r.uid = fsd_requester_uid(from);
					result = fs_ops.write(&r);
				}
			}
			case FS_WRITE_AT:
			{
				// Wire: len 100..103, offset 104..107, data 108.. — see
				// user.c3's fs_write_at.
				if (req_len > (int)(FS_MSG_MAX - 108)) req_len = (int)(FS_MSG_MAX - 108);
				r.len = (uint)req_len;
				r.data = &buf[108];
				r.uid = fsd_requester_uid(from);
				// FS_OFFSET_APPEND → the file's current size (0 if it
				// doesn't exist yet), so a caller can append with no
				// prior FS_STAT. The stat adapter only touches
				// r.out_size/out_type, not the reply buffer. (r.uid is
				// already the requester's, set above — so a user who
				// can't read the file it's appending to gets offset 0,
				// but the write_at below then denies it anyway.)
				if (r.offset == FS_OFFSET_APPEND)
				{
					r.offset = (fs_ops.stat(&r) == 0) ? r.out_size : 0;
				}
				if (!fs_is_protected_name(&filename))
				{
					result = fs_ops.write_at(&r);
				}
			}
			case FS_DELETE:
			{
				// req_len doubles as the recursive flag (see user.c3's
				// wire-format comment) — FS_DELETE sends no length of its
				// own. Same protected-name fast gate as FS_WRITE.
				r.recursive = req_len != 0;
				if (!fs_is_protected_name(&filename))
				{
					r.uid = fsd_requester_uid(from);
					result = fs_ops.remove(&r);
				}
			}
			case FS_MKDIR:
			{
				// No protected-name check — mkdir can't target the
				// protected file's name (the backend's own "already
				// exists" refuses it). fs_write_disabled IS checked: a
				// cheap early exit before allocating a cluster/inode the
				// next write would just get refused on anyway (the real
				// backstop is diskd_rw()).
				if (!fs_write_disabled)
				{
					r.uid = fsd_requester_uid(from);
					result = fs_ops.mkdir(&r);
				}
			}
			case FS_RENAME:
			{
				// Same fs_write_disabled early-exit reasoning as FS_MKDIR.
				if (!fs_write_disabled)
				{
					r.uid = fsd_requester_uid(from);
					result = fs_ops.rename(&r);
				}
			}
			case FS_CHMOD:
			{
				// Wire byte 100..103 = the new mode (FS_CHMOD) — reuse
				// r.len, the field already parsed from those bytes. Same
				// protected-name + fs_write_disabled gates as the write
				// verbs (chmod is a metadata write to disk); the ext2
				// backend enforces owner-or-root.
				r.len = (uint)req_len;
				if (!fs_write_disabled && !fs_is_protected_name(&filename))
				{
					r.uid = fsd_requester_uid(from);
					result = fs_ops.chmod(&r);
				}
			}
			case FS_CHOWN:
			{
				// Wire byte 100..103 = the new owner uid. Same gates;
				// the ext2 backend enforces root-only.
				r.len = (uint)req_len;
				if (!fs_write_disabled && !fs_is_protected_name(&filename))
				{
					r.uid = fsd_requester_uid(from);
					result = fs_ops.chown(&r);
				}
			}
		}

		*result_len_field = result;
		ipc_reply(from, verb, &buf, FS_MSG_MAX, from_gen);
	}
}
