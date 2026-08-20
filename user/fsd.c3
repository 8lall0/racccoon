module user;

import std::racccoon::mem;

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
// structure (FAT32, ext2, ...) lives in user/fs/*.c3, each exposing a
// small, consistently-named set of functions this file dispatches to
// based on fs_type, set once at mount time by probing each backend in
// turn (see fs_mount()). No function-pointer/vtable indirection: this
// codebase has no precedent for that anywhere (structs here are plain
// data — Process/Mount in src/process.c3, @packed wire/hardware layouts
// like Virtio_blk_req), and two backends dispatched through a couple of
// `if`s don't need it. Every file here — fsd.c3 and every user/fs/*.c3 —
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
// fs_read_sector/fs_write_sector below.
const uint DISKD_READ    = 10;
const uint DISKD_WRITE   = 11;
const uint DISKD_MSG_MAX = 516;
const uint SECTOR_SIZE   = 512;

// diskd (or sdd, on the Duo) is always pid 3: created third in a fixed
// boot-time order (idle, echod, diskd-or-sdd, fsd — see kernel.c3), same
// hardcoded-by-convention approach as echod's pid 2 in shell.c3's "ping".
// fsd is a fixed, internal-only client of a fixed, internal-only
// service; fsd's *own* clients (the shell) go through namespace
// resolution instead, so they never need to know fsd's pid at all — see
// user.c3's fs_read/fs_write.
const int DISKD_PID = 3;

// board::FS_PARTITION_START_SECTOR, learned via syscall — board is a
// kernel-only module (see user/sdd.c3's own header comment for why),
// this is fsd's only way to learn this board-specific fact. Set once by
// fs_mount(), before either backend's probe/mount runs, since both need
// it to read sector 0 / a superblock at all.
uint fs_partition_start;

// Which backend is mounted — set once by fs_mount(), read by main()'s
// dispatch. Plain int constants, not an enum: no enum usage anywhere
// else in this codebase (grepped for precedent before adding one), and
// two named constants dispatched through `if`s don't need the ceremony.
const int FS_TYPE_NONE  = 0;
const int FS_TYPE_FAT32 = 1;
const int FS_TYPE_EXT2  = 2;
int fs_type = FS_TYPE_NONE;

fn void fs_panic(char* msg)
{
	print("fsd: ");
	print(msg);
	print("\n");
	// Not an empty `for(;;){}` loop — see user/diskd.c3's diskd_panic
	// comment for why that's a real UB/optimizer hazard, not a
	// theoretical one, in this exact codebase.
	exit();
}

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
	int from = p9_call(DISKD_PID, verb, &req, DISKD_MSG_MAX, &req, DISKD_MSG_MAX, &reply_verb);
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
	return diskd_rw(buf, fs_partition_start + sector, false);
}

// Write counterpart to fs_read_sector — every filesystem-level write in
// this process (data, FAT/inode-table entries, directory entries) goes
// through this, which goes through diskd_rw()'s reserved-sector check.
fn bool fs_write_sector(uint sector, char* buf)
{
	return diskd_rw(buf, fs_partition_start + sector, true);
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

fn void fs_mount()
{
	if (fs_partition_info(&fs_partition_start) < 0)
	{
		fs_panic("failed to get partition info");
	}

	// ext2 first: its magic is a specific 16-bit value at a fixed byte
	// offset, about as unambiguous as a signature check gets. FAT32's
	// own 0xAA55 is a much weaker signal (shared with plain MBRs and
	// every other x86-bootable format), so it's the fallback, not the
	// first guess.
	if (ext2_probe())
	{
		fs_type = FS_TYPE_EXT2;
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
		ext2_mkdir("tmp");
		ext2_reserve_protected(&FS_PROTECTED_NAME);
		fs_reserve_protection_summary();
		return;
	}
	if (fat32_probe())
	{
		fs_type = FS_TYPE_FAT32;
		fat32_mount();
		fs_write_disabled = false;
		// See the ext2 branch's own comment above — same reasoning.
		fat32_mkdir("tmp");
		fat32_reserve_protected(&FS_PROTECTED_NAME);
		fs_reserve_protection_summary();
		return;
	}

	// Deliberately NOT fs_panic()/exit() here, unlike every other failure
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

fn void main() @export("main")
{
	fs_mount();

	for (;;)
	{
		char[FS_MSG_MAX] buf @noinit;
		uint verb = 0;
		uint from_gen = 0;
		int from = ipc_recv_type_gen(&buf, FS_MSG_MAX, &verb, &from_gen);
		if (from <= 0) continue;
		if (verb != FS_READ && verb != FS_WRITE && verb != FS_DELETE && verb != FS_LIST && verb != FS_MKDIR && verb != FS_RENAME) continue;

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
		uint* len_field = (uint*)&buf[100];
		int req_len = (int)*len_field;
		// Untrusted input — clamp rather than trust the caller not to
		// set the field's high bit. See docs/devlog.md for the same
		// hardening pass that added this check.
		if (req_len < 0) req_len = 0;

		if (verb == FS_DELETE)
		{
			// Same protected-name fast gate as FS_WRITE — the real
			// backstop for both is each backend's own fs_is_protected_
			// entry() check (matching the exact sector/offset reserved
			// at mount time), this is just an obvious, cheap first
			// refusal before either backend even runs.
			//
			// req_len doubles as the recursive flag here (see user.c3's
			// wire-format comment) — FS_DELETE has no length of its own
			// to send, and this byte range is already read and clamped
			// above for FS_READ/FS_WRITE's sake.
			bool recursive = req_len != 0;
			int result = -1;
			if (!fs_is_protected_name(&filename))
			{
				if (fs_type == FS_TYPE_FAT32)
				{
					result = recursive ? fat32_delete_recursive(&filename) : fat32_delete(&filename);
				}
				else if (fs_type == FS_TYPE_EXT2)
				{
					result = recursive ? ext2_delete_recursive(&filename) : ext2_delete(&filename);
				}
			}
			*result_len_field = result;
			ipc_reply(from, verb, &buf, FS_MSG_MAX, from_gen);
			continue;
		}

		if (verb == FS_LIST)
		{
			// req_len/the recursive-flag byte range aren't used here — a
			// listing only ever sends the directory path (see user.c3's
			// wire-format comment). max_entries is bounded by how many
			// FS_LIST_ENTRY_SIZE records actually fit in one reply
			// (FS_MSG_MAX - 4, the same 4-byte result-count header every
			// other verb here uses) — no pagination, see user.c3's own
			// comment.
			int max_entries = (int)((FS_MSG_MAX - 4) / FS_LIST_ENTRY_SIZE);
			int count = -1;
			if (fs_type == FS_TYPE_FAT32)
			{
				if (!fat32_list(&filename, &buf[4], max_entries, &count)) count = -1;
			}
			else if (fs_type == FS_TYPE_EXT2)
			{
				if (!ext2_list(&filename, &buf[4], max_entries, &count)) count = -1;
			}
			*result_len_field = count;
			ipc_reply(from, verb, &buf, FS_MSG_MAX, from_gen);
			continue;
		}

		if (verb == FS_MKDIR)
		{
			// No protected-name check needed here the way FS_WRITE/FS_DELETE
			// have one: mkdir can never target the protected file's own name
			// (fat32_mkdir/ext2_mkdir's own "already exists" check already
			// refuses that, since the protected file's entry is right there).
			// fs_write_disabled is still checked explicitly, though — every
			// write mkdir would attempt goes through fs_write_sector ->
			// diskd_rw(), which refuses on its own if writes are disabled
			// (mount still in progress, or fs_reserve_sector_range()
			// overflow), so this is a cheap early exit, not a correctness
			// requirement — avoids allocating a cluster/inode/block just to
			// have the very next write on it refused anyway.
			int result = -1;
			if (!fs_write_disabled)
			{
				if (fs_type == FS_TYPE_FAT32)
				{
					result = fat32_mkdir(&filename);
				}
				else if (fs_type == FS_TYPE_EXT2)
				{
					result = ext2_mkdir(&filename);
				}
			}
			*result_len_field = result;
			ipc_reply(from, verb, &buf, FS_MSG_MAX, from_gen);
			continue;
		}

		if (verb == FS_RENAME)
		{
			// Same fs_write_disabled early-exit reasoning as FS_MKDIR's own
			// comment — cheap, not a correctness requirement, the real
			// backstop is diskd_rw() itself.
			int result = -1;
			if (!fs_write_disabled)
			{
				if (fs_type == FS_TYPE_FAT32)
				{
					result = fat32_rename(&filename, &new_filename);
				}
				else if (fs_type == FS_TYPE_EXT2)
				{
					result = ext2_rename(&filename, &new_filename);
				}
			}
			*result_len_field = result;
			ipc_reply(from, verb, &buf, FS_MSG_MAX, from_gen);
			continue;
		}

		if (verb == FS_WRITE)
		{
			if (req_len > (int)(FS_MSG_MAX - 104)) req_len = (int)(FS_MSG_MAX - 104);
			// Protected-name check here is a fast, obvious first gate,
			// checked before any backend even sees the request;
			// diskd_rw()'s reserved-sector check (see this file's
			// header comment) is the real backstop if this one is ever
			// bypassed.
			int result = -1;
			if (!fs_is_protected_name(&filename))
			{
				if (fs_type == FS_TYPE_FAT32)
				{
					result = fat32_write(&filename, &buf[104], (uint)req_len);
				}
				else if (fs_type == FS_TYPE_EXT2)
				{
					result = ext2_write(&filename, &buf[104], (uint)req_len);
				}
			}
			*result_len_field = result;
			ipc_reply(from, verb, &buf, FS_MSG_MAX, from_gen);
			continue;
		}

		if (req_len > (int)(FS_MSG_MAX - 4)) req_len = (int)(FS_MSG_MAX - 4);
		int result = -1;
		if (fs_type == FS_TYPE_FAT32)
		{
			result = fat32_read(&filename, &buf[4], (uint)req_len);
		}
		else if (fs_type == FS_TYPE_EXT2)
		{
			result = ext2_read(&filename, &buf[4], (uint)req_len);
		}
		*result_len_field = result;

		ipc_reply(from, verb, &buf, FS_MSG_MAX, from_gen);
	}
}
