module user;

// fsd: the file system, moved out of the trusted kernel into its own
// user-mode process (microkernel plan phase 5 — see docs/devlog.md).
// It's a 9P-lite-style client of diskd/sdd (phase 4) for raw sector I/O,
// and a server to everyone else (today just the shell) over the
// FS_READ/FS_WRITE verbs below. SYS_READFILE/SYS_WRITEFILE are gone from
// the kernel entirely now — this is the only way to touch a file.
//
// Reads and writes a real FAT32 filesystem — not the tar-based format
// this file used to speak. On the Duo, this is the *same* FAT32
// partition (see fs_partition_info()/board::FS_PARTITION_START_SECTOR)
// that already holds this board's own bootable fip.bin. v1 scope,
// deliberately limited: root directory only (fsd had no subdirectory
// concept before this either — not a regression), 8.3 short filenames
// only (long filename / LFN directory entries are skipped, not parsed),
// no caching at boot — every FS_READ/FS_WRITE walks the root directory
// fresh and follows the matched file's cluster chain on demand, since
// there's no reasonable fixed-size cache for "however many files happen
// to be on someone's real SD card."
//
// Write support (create, overwrite, grow — see fs_do_write()) started
// read-only-only and was extended deliberately: a parsing bug can
// misread data, but a write bug can corrupt the very partition that
// boots this board. The safety net isn't just "don't write to
// fip.bin by name" — it's structural: fs_init() looks up each protected
// file's directory entry and its ENTIRE cluster chain once at mount
// time and records every cluster it occupies (see
// fs_reserve_protected_file()/fs_reserved_clusters), and diskd_rw() —
// the ONE function every write in this file funnels through, whether
// it's file data, a FAT-table update, or a directory entry — refuses
// any write that would land on one of those clusters. That means a bug
// in the allocator or directory code can't reach a protected file
// either, not just a filename check that a different code path could
// bypass. See docs/devlog.md for the FAT32 entries covering both the
// read-only and write-support work.
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
// above, just the client side of it.
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

// --- FAT32 on-disk structures. Standard, stable public spec — offsets
// below are the well-known FAT32 layout (same one Linux's fs/fat and
// every other FAT32 reader implements), not vendor-specific or
// reverse-engineered the way this project's SDHCI register maps were.

// BPB (BIOS Parameter Block) field offsets within the boot sector
// (sector 0 of the partition).
const uint BPB_BYTES_PER_SECTOR    = 0x0B; // u16
const uint BPB_SECTORS_PER_CLUSTER = 0x0D; // u8
const uint BPB_RESERVED_SECTORS    = 0x0E; // u16
const uint BPB_NUM_FATS            = 0x10; // u8
const uint BPB_TOTAL_SECTORS_32    = 0x20; // u32, the only valid total-volume-size field in FAT32 (the u16 field @0x13 is always 0)
const uint BPB_FAT_SIZE_32         = 0x24; // u32, sectors per FAT
const uint BPB_ROOT_CLUSTER        = 0x2C; // u32
const uint BPB_SIGNATURE_OFFSET    = 0x1FE; // u16, must be 0xAA55 (little-endian 0x55,0xAA)

// Directory entry (32 bytes) field offsets.
const uint DIRENT_SIZE           = 32;
const uint DIRENT_NAME           = 0x00; // 11 bytes, 8.3 short name, space-padded, uppercase
const uint DIRENT_ATTR           = 0x0B; // u8
const uint DIRENT_CLUSTER_HI     = 0x14; // u16
const uint DIRENT_CLUSTER_LO     = 0x1A; // u16
const uint DIRENT_FILE_SIZE      = 0x1C; // u32

const char DIRENT_FREE_REST   = (char)0x00; // this entry and all following are unused
const char DIRENT_DELETED     = (char)0xE5; // this entry is deleted, keep scanning
const char DIRENT_ATTR_LFN    = (char)0x0F; // long-filename entry, not a real file — skip
const char DIRENT_ATTR_VOLUME = (char)0x08; // volume label bit — skip, never a real file

const uint FAT_ENTRY_MASK = 0x0FFFFFFF; // low 28 bits significant
const uint FAT_EOC_MIN    = 0x0FFFFFF8; // cluster values at or above this mean end-of-chain

// Derived layout, computed once by fat32_init() and cached — cheap,
// board-static-ish facts about the volume, unlike per-file data (which
// is deliberately never cached — see this file's header comment).
uint fs_partition_start; // board::FS_PARTITION_START_SECTOR, learned via syscall
uint fs_fat_start_sector;
uint fs_data_start_sector;
uint fs_sectors_per_cluster;
uint fs_root_cluster;
uint fs_num_fats;      // needed by the write path to mirror every FAT update across all copies
uint fs_fat_size_32;   // sectors per FAT copy — same
uint fs_total_clusters; // upper bound for fat32_alloc_cluster()'s scan

// --- Write protection: a reserved-cluster allowlist, enforced in
// diskd_rw() — see this file's own header comment for the full
// rationale. Cluster numbers, not raw sectors: a protected file's whole
// chain is typically a handful to a few hundred clusters even for a
// multi-MB fip.bin (32KB/cluster at 64 sectors/cluster on the real
// card), far more compact than tracking individual sectors would be.
const uint FS_RESERVED_MAX = 512;
uint[FS_RESERVED_MAX] fs_reserved_clusters;
uint fs_reserved_count = 0;
// Fails CLOSED (see fs_reserve_cluster()) rather than risk protecting
// only part of a file: if the reservation list would overflow, or the
// write path is asked to operate before fs_init() has finished building
// it, every write is refused for the rest of this process's life.
bool fs_write_disabled = true;

// A protected file's own directory ENTRY is deliberately NOT protected
// via the cluster-reservation list above: in FAT32 the root directory is
// itself just an ordinary cluster chain, shared by every file's entry —
// reserving "the cluster containing fip.bin's entry" would reserve the
// WHOLE root directory cluster, silently blocking every other file's
// entry from ever being created or updated there too (found exactly
// this way, on real hardware — see docs/devlog.md's FAT32 write-support
// entry). Instead, the entry's exact (sector, offset) is tracked here
// and checked explicitly by the two places that ever write directory-
// entry bytes (fat32_create_file, fat32_update_entry_size) — narrower
// than the cluster-level check, but still independent of the filename
// comparison in fs_is_protected_name(), so it still catches a bug that
// landed on the right slot through some other path.
uint fs_protected_entry_sector = 0;
uint fs_protected_entry_offset = 0;
bool fs_has_protected_entry = false;

// 8.3-form name of the one file this driver refuses to ever write to,
// no matter what: the real, on-disk name the flashing workflow uses for
// this board's bootable image (see scripts/build_duo_fip.sh and the
// flash steps in docs/devlog.md) — "fip.bin", padded/uppercased to raw
// FAT32 short-name form. QEMU's disposable test image has no such file,
// so this list is simply never matched there — harmless.
const char[11] FS_PROTECTED_NAME_1 = "FIP     BIN";

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

fn void print_uint(uint v)
{
	char[10] digits @noinit;
	int n = 0;
	if (v == 0)
	{
		putchar('0');
		return;
	}
	while (v > 0 && n < 10)
	{
		digits[n] = (char)('0' + (v % 10));
		v /= 10;
		n++;
	}
	while (n > 0)
	{
		n--;
		putchar(digits[n]);
	}
}

const char[16] HEX_DIGITS = "0123456789abcdef";

fn void print_hex32(uint v)
{
	for (int shift = 28; shift >= 0; shift -= 4)
	{
		putchar(HEX_DIGITS[(v >> shift) & 0xF]);
	}
}

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
	// to partition-relative before checking against fs_reserved_clusters,
	// which is expressed in the same relative terms fs_init() computed
	// the volume layout in.
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
// why this exists and what it's set to per board.
fn bool fat32_read_sector(uint sector, char* buf)
{
	return diskd_rw(buf, fs_partition_start + sector, false);
}

// Write counterpart to fat32_read_sector — every FAT32-level write in
// this file (data, FAT entries, directory entries) goes through this,
// which goes through diskd_rw()'s reserved-sector check.
fn bool fat32_write_sector(uint sector, char* buf)
{
	return diskd_rw(buf, fs_partition_start + sector, true);
}

fn uint cluster_to_sector(uint cluster)
{
	return fs_data_start_sector + (cluster - 2) * fs_sectors_per_cluster;
}

fn bool fs_cluster_is_reserved(uint cluster)
{
	for (uint i = 0; i < fs_reserved_count; i++)
	{
		if (fs_reserved_clusters[i] == cluster) return true;
	}
	return false;
}

// See fs_protected_entry_sector's own comment for why a protected file's
// directory entry is checked at this exact-slot granularity instead of
// the coarser cluster-reservation list.
fn bool fs_is_protected_entry(uint sector, uint offset)
{
	return fs_has_protected_entry && sector == fs_protected_entry_sector && offset == fs_protected_entry_offset;
}

// `sector` here is partition-relative (see diskd_rw's own comment on the
// one call site that converts before calling this). Sectors below
// fs_data_start_sector (the FAT region itself) are never cluster-
// addressable and aren't covered by this check — fat32_write_fat_entry
// is the one trusted primitive responsible for FAT-table correctness,
// the same way diskd_rw is trusted for raw I/O; this allowlist exists to
// stop bugs in the allocator/directory code from reaching a protected
// file's *data* or *directory entry*, both of which live in the
// cluster-addressable data region in FAT32 (the root directory is just
// an ordinary cluster chain here, unlike FAT12/16).
fn bool fs_sector_is_reserved(uint sector)
{
	if (sector < fs_data_start_sector) return false;
	uint cluster = (sector - fs_data_start_sector) / fs_sectors_per_cluster + 2;
	return fs_cluster_is_reserved(cluster);
}

// Reads one 4-byte little-endian FAT entry and returns its low 28 bits —
// the next cluster in the chain (or a value >= FAT_EOC_MIN at the end).
// A read failure is treated as end-of-chain rather than propagated: this
// is a best-effort read-only reader, not a filesystem that needs to
// distinguish "corrupt" from "empty" for correctness anywhere it's used.
fn uint fat_next_cluster(uint cluster)
{
	uint fat_byte_offset = cluster * 4;
	uint fat_sector = fs_fat_start_sector + (fat_byte_offset / SECTOR_SIZE);
	uint entry_offset = fat_byte_offset % SECTOR_SIZE;

	char[SECTOR_SIZE] sector_buf @noinit;
	if (!fat32_read_sector(fat_sector, &sector_buf)) return FAT_EOC_MIN;

	uint* entry = (uint*)&sector_buf[entry_offset];
	return *entry & FAT_ENTRY_MASK;
}

// Converts a plain, null-terminated, lowercase-or-mixed-case filename
// like "hello.txt" into raw 8.3 short-name form: 11 bytes, space-padded,
// uppercase, no dot — "HELLO   TXT" — ready to compare byte-for-byte
// against a directory entry's own DIRENT_NAME field (already stored in
// exactly this form on disk). Truncates silently past 8 name / 3
// extension characters — no long-filename support in v1 (see this
// file's header comment).
fn void name_to_8_3(char* input, char* out11)
{
	for (int i = 0; i < 11; i++) out11[i] = ' ';

	int i = 0;
	int out_i = 0;
	while (input[i] != 0 && input[i] != '.' && out_i < 8)
	{
		char c = input[i];
		if (c >= 'a' && c <= 'z') c = (char)(c - 'a' + 'A');
		out11[out_i] = c;
		out_i++;
		i++;
	}
	while (input[i] != 0 && input[i] != '.') i++;
	if (input[i] == '.') i++;

	int ext_i = 8;
	while (input[i] != 0 && ext_i < 11)
	{
		char c = input[i];
		if (c >= 'a' && c <= 'z') c = (char)(c - 'a' + 'A');
		out11[ext_i] = c;
		ext_i++;
		i++;
	}
}

// Walks the root directory's own cluster chain looking for a name11
// (already in raw 8.3 form — see name_to_8_3) match. Returns true and
// fills *out_cluster/*out_size/*out_entry_sector/*out_entry_offset on a
// hit — the latter two (the entry's own location, not the file's data)
// are needed by the write path (updating file_size in place) and by
// fs_reserve_protected_file() (protecting the entry itself, not just the
// file's data clusters); the read path just ignores them.
fn bool fat32_find_in_root(char* name11, uint* out_cluster, uint* out_size, uint* out_entry_sector, uint* out_entry_offset)
{
	uint cluster = fs_root_cluster;
	char[SECTOR_SIZE] sector_buf @noinit;

	while (cluster != 0 && cluster < FAT_EOC_MIN)
	{
		uint sector = cluster_to_sector(cluster);
		for (uint s = 0; s < fs_sectors_per_cluster; s++)
		{
			if (!fat32_read_sector(sector + s, &sector_buf)) return false;

			for (uint e = 0; e < SECTOR_SIZE / DIRENT_SIZE; e++)
			{
				char* entry = &sector_buf[e * DIRENT_SIZE];
				if (entry[0] == DIRENT_FREE_REST) return false; // end of directory
				if (entry[0] == DIRENT_DELETED) continue;

				char attr = entry[DIRENT_ATTR];
				if (attr == DIRENT_ATTR_LFN) continue;
				if ((attr & DIRENT_ATTR_VOLUME) != 0) continue;

				bool match = true;
				for (uint k = 0; k < 11; k++)
				{
					if (entry[DIRENT_NAME + k] != name11[k])
					{
						match = false;
						break;
					}
				}
				if (!match) continue;

				ushort* cluster_hi = (ushort*)&entry[DIRENT_CLUSTER_HI];
				ushort* cluster_lo = (ushort*)&entry[DIRENT_CLUSTER_LO];
				uint*   size_field = (uint*)&entry[DIRENT_FILE_SIZE];
				*out_cluster = ((uint)*cluster_hi << 16) | (uint)*cluster_lo;
				*out_size    = *size_field;
				*out_entry_sector = sector + s;
				*out_entry_offset = e * DIRENT_SIZE;
				return true;
			}
		}
		cluster = fat_next_cluster(cluster);
	}
	return false;
}

// Follows first_cluster's chain, copying up to `len` bytes (already
// clamped by the caller against the file's real size — see main()) into
// dst starting from the beginning of the file. Returns the number of
// bytes actually copied — normally equal to len, but can come up short
// (rather than leave dst partially uninitialized) if the chain turns
// out shorter than the directory entry's own size field claimed.
fn uint fat32_read_file(uint first_cluster, char* dst, uint len)
{
	uint cluster = first_cluster;
	uint bytes_read = 0;
	char[SECTOR_SIZE] sector_buf @noinit;

	while (cluster != 0 && cluster < FAT_EOC_MIN && bytes_read < len)
	{
		uint sector = cluster_to_sector(cluster);
		for (uint s = 0; s < fs_sectors_per_cluster && bytes_read < len; s++)
		{
			if (!fat32_read_sector(sector + s, &sector_buf)) return bytes_read;

			uint chunk = len - bytes_read;
			if (chunk > SECTOR_SIZE) chunk = SECTOR_SIZE;
			for (uint i = 0; i < chunk; i++)
			{
				dst[bytes_read + i] = sector_buf[i];
			}
			bytes_read += chunk;
		}
		cluster = fat_next_cluster(cluster);
	}
	return bytes_read;
}

// --- Write path -------------------------------------------------------

// Writes one 4-byte little-endian FAT entry (low 28 bits of `value`,
// preserving whatever's in the top 4 reserved bits) to EVERY FAT copy
// (fs_num_fats of them, each fs_fat_size_32 sectors apart) — a real
// FAT32 reader is free to trust either copy, so leaving them out of sync
// is a real, if usually low-severity, corruption. Read-modify-write per
// copy since sectors are the smallest unit fat32_write_sector can touch.
fn bool fat32_write_fat_entry(uint cluster, uint value)
{
	uint fat_byte_offset = cluster * 4;
	uint fat_sector_rel = fat_byte_offset / SECTOR_SIZE;
	uint entry_offset = fat_byte_offset % SECTOR_SIZE;

	for (uint copy = 0; copy < fs_num_fats; copy++)
	{
		uint fat_sector = fs_fat_start_sector + copy * fs_fat_size_32 + fat_sector_rel;
		char[SECTOR_SIZE] sector_buf @noinit;
		if (!fat32_read_sector(fat_sector, &sector_buf)) return false;
		uint* entry = (uint*)&sector_buf[entry_offset];
		*entry = (*entry & ~FAT_ENTRY_MASK) | (value & FAT_ENTRY_MASK);
		if (!fat32_write_sector(fat_sector, &sector_buf)) return false;
	}
	return true;
}

// Records that `cluster` must never be written to (see this file's
// header comment). Returns false and disables ALL writes for the rest
// of this process's life if the reservation list is full — failing
// closed rather than risk protecting only part of a file.
fn bool fs_reserve_cluster(uint cluster)
{
	if (fs_cluster_is_reserved(cluster)) return true;
	if (fs_reserved_count >= FS_RESERVED_MAX)
	{
		print("fsd: protected-file reservation list full, disabling all writes\n");
		fs_write_disabled = true;
		return false;
	}
	fs_reserved_clusters[fs_reserved_count] = cluster;
	fs_reserved_count++;
	return true;
}

// Looks up a protected file by its 8.3 name: records its directory
// entry's exact (sector, offset) — see fs_protected_entry_sector's own
// comment for why that's checked separately rather than folded into the
// cluster-reservation list — and reserves every cluster in its DATA
// chain at the coarser, cluster-granular level (safe there: unlike the
// shared root directory, one cluster only ever belongs to one file's
// data). A file that isn't found (QEMU's disposable test image has no
// fip.bin) is simply nothing to protect — logged so it's visible, not
// silently skipped.
fn void fs_reserve_protected_file(char* name11)
{
	uint cluster;
	uint size;
	uint entry_sector;
	uint entry_offset;
	if (!fat32_find_in_root(name11, &cluster, &size, &entry_sector, &entry_offset))
	{
		print("fsd: protected file not found, nothing to reserve for it\n");
		return;
	}

	fs_protected_entry_sector = entry_sector;
	fs_protected_entry_offset = entry_offset;
	fs_has_protected_entry = true;

	while (cluster != 0 && cluster < FAT_EOC_MIN)
	{
		if (!fs_reserve_cluster(cluster)) return;
		cluster = fat_next_cluster(cluster);
	}
}

// Linear scan for a free (FAT entry == 0) cluster, starting at 2 (the
// first real cluster number). Marks it FAT_EOC_MIN in every FAT copy
// immediately, before returning it, closing the window where a second
// allocation later in the same request could pick the same cluster
// twice. Also skips any cluster already in fs_reserved_clusters — a
// correctly maintained FAT should never mark a reserved cluster free,
// but this is cheap insurance against exactly the kind of FAT-
// corruption-then-cascading-allocation bug the reserved list exists to
// guard against in the first place. Returns 0 (never a valid cluster
// number) on "no free space" or any read failure along the way.
fn uint fat32_alloc_cluster()
{
	for (uint cluster = 2; cluster < fs_total_clusters + 2; cluster++)
	{
		if (fs_cluster_is_reserved(cluster)) continue;
		if (fat_next_cluster(cluster) == 0)
		{
			if (!fat32_write_fat_entry(cluster, FAT_EOC_MIN)) return 0;
			return cluster;
		}
	}
	return 0;
}

// Walks the root directory looking for a reusable entry slot (first byte
// 0x00 "free, and everything after" or 0xE5 "deleted"). Always fills
// *out_last_cluster with the final cluster of the root chain as it
// walks — needed by the caller to extend the chain if no free slot
// turns up, and harmless to compute even when one is found. Returns
// false (chain needs extending) only after scanning the whole chain
// without finding a slot.
fn bool fat32_find_free_dirent(uint* out_entry_sector, uint* out_entry_offset, uint* out_last_cluster)
{
	uint cluster = fs_root_cluster;
	char[SECTOR_SIZE] sector_buf @noinit;

	while (cluster != 0 && cluster < FAT_EOC_MIN)
	{
		*out_last_cluster = cluster;
		uint sector = cluster_to_sector(cluster);
		for (uint s = 0; s < fs_sectors_per_cluster; s++)
		{
			if (!fat32_read_sector(sector + s, &sector_buf)) return false;

			for (uint e = 0; e < SECTOR_SIZE / DIRENT_SIZE; e++)
			{
				char* entry = &sector_buf[e * DIRENT_SIZE];
				if (entry[0] == DIRENT_FREE_REST || entry[0] == DIRENT_DELETED)
				{
					*out_entry_sector = sector + s;
					*out_entry_offset = e * DIRENT_SIZE;
					return true;
				}
			}
		}
		cluster = fat_next_cluster(cluster);
	}
	return false;
}

// Creates a new, empty (zero-size) directory entry for name11 and
// allocates its first data cluster. Extends the root directory's own
// chain with a freshly zero-filled cluster if it has no free slot — a
// directory cluster's bytes are always interpreted as entries (unlike
// file data past the declared size, which is never exposed to a
// reader), so unlike fat32_write_file below, this really does need
// zero-filling for correctness, not just tidiness.
fn bool fat32_create_file(char* name11, uint* out_first_cluster)
{
	uint first_cluster = fat32_alloc_cluster();
	if (first_cluster == 0) return false;

	uint entry_sector;
	uint entry_offset;
	uint last_dir_cluster;
	if (!fat32_find_free_dirent(&entry_sector, &entry_offset, &last_dir_cluster))
	{
		uint new_dir_cluster = fat32_alloc_cluster();
		if (new_dir_cluster == 0) return false;

		char[SECTOR_SIZE] zero_buf @noinit;
		for (uint i = 0; i < SECTOR_SIZE; i++) zero_buf[i] = 0;
		for (uint s = 0; s < fs_sectors_per_cluster; s++)
		{
			if (!fat32_write_sector(cluster_to_sector(new_dir_cluster) + s, &zero_buf)) return false;
		}

		if (!fat32_write_fat_entry(last_dir_cluster, new_dir_cluster)) return false;
		if (!fat32_write_fat_entry(new_dir_cluster, FAT_EOC_MIN)) return false;

		entry_sector = cluster_to_sector(new_dir_cluster);
		entry_offset = 0;
	}

	// Defense in depth — see fs_is_protected_entry's own comment.
	// Structurally unreachable in practice: fat32_find_free_dirent only
	// ever returns a free/deleted slot, and a protected file's real entry
	// is neither, so this would require a bug in that scan to ever fire.
	if (fs_is_protected_entry(entry_sector, entry_offset)) return false;

	char[SECTOR_SIZE] sector_buf @noinit;
	if (!fat32_read_sector(entry_sector, &sector_buf)) return false;

	char* entry = &sector_buf[entry_offset];
	for (uint i = 0; i < 11; i++) entry[DIRENT_NAME + i] = name11[i];
	entry[DIRENT_ATTR] = (char)0x20; // ARCHIVE — an ordinary file
	// Reserved/create-time/create-date/last-access-date fields (bytes
	// 0x0C-0x13, between ATTR and cluster-hi) — zeroed explicitly rather
	// than left as whatever a reused 0xE5 (deleted) slot's old file had
	// in them. Every FAT32 reader tolerates an all-zero date (shows as
	// 1980-01-01), so this is a real correctness cleanup, not required
	// for safety.
	for (uint i = 0x0C; i < 0x14; i++) entry[i] = 0;
	ushort* cluster_hi = (ushort*)&entry[DIRENT_CLUSTER_HI];
	ushort* cluster_lo = (ushort*)&entry[DIRENT_CLUSTER_LO];
	uint*   size_field  = (uint*)&entry[DIRENT_FILE_SIZE];
	*cluster_hi = (ushort)(first_cluster >> 16);
	*cluster_lo = (ushort)(first_cluster & 0xFFFF);
	*size_field = 0;

	if (!fat32_write_sector(entry_sector, &sector_buf)) return false;

	*out_first_cluster = first_cluster;
	return true;
}

// Writes `len` bytes from `src` into first_cluster's chain, starting
// from the beginning of the file, extending the chain (allocating new
// clusters, one at a time, as needed) if `len` needs more space than the
// chain currently has. Returns the number of bytes actually written —
// short only on a genuine failure (out of space, a reserved-cluster
// refusal, an I/O error) partway through, in which case the file is left
// with whatever prefix did get written; the caller updates the
// directory entry's size field to match what actually happened, not
// what was requested (see fs_do_write()).
fn uint fat32_write_file(uint first_cluster, char* src, uint len)
{
	uint cluster = first_cluster;
	uint bytes_written = 0;
	char[SECTOR_SIZE] sector_buf @noinit;

	while (bytes_written < len)
	{
		uint sector = cluster_to_sector(cluster);
		for (uint s = 0; s < fs_sectors_per_cluster && bytes_written < len; s++)
		{
			uint chunk = len - bytes_written;
			if (chunk > SECTOR_SIZE) chunk = SECTOR_SIZE;
			// Partial-sector write: read the real, existing content
			// first so bytes beyond `chunk` in this sector (if any)
			// keep their current on-disk value instead of being
			// clobbered — matches fat32_read_file's own read-what's-
			// really-there discipline.
			if (chunk < SECTOR_SIZE)
			{
				if (!fat32_read_sector(sector + s, &sector_buf)) return bytes_written;
			}
			for (uint i = 0; i < chunk; i++)
			{
				sector_buf[i] = src[bytes_written + i];
			}
			if (!fat32_write_sector(sector + s, &sector_buf)) return bytes_written;
			bytes_written += chunk;
		}

		if (bytes_written >= len) break;

		uint next = fat_next_cluster(cluster);
		if (next >= FAT_EOC_MIN)
		{
			next = fat32_alloc_cluster();
			if (next == 0) return bytes_written;
			if (!fat32_write_fat_entry(cluster, next)) return bytes_written;
			if (!fat32_write_fat_entry(next, FAT_EOC_MIN)) return bytes_written;
		}
		cluster = next;
	}
	return bytes_written;
}

fn bool fat32_update_entry_size(uint entry_sector, uint entry_offset, uint new_size)
{
	// Real backstop here, unlike fat32_create_file's — fs_is_protected_name()
	// already rejects the literal name "fip.bin" before fs_do_write ever
	// reaches this function, but this check doesn't depend on that
	// string comparison staying correct or every future caller
	// remembering to check it first.
	if (fs_is_protected_entry(entry_sector, entry_offset)) return false;

	char[SECTOR_SIZE] sector_buf @noinit;
	if (!fat32_read_sector(entry_sector, &sector_buf)) return false;
	uint* size_field = (uint*)&sector_buf[entry_offset + DIRENT_FILE_SIZE];
	*size_field = new_size;
	return fat32_write_sector(entry_sector, &sector_buf);
}

fn bool fs_is_protected_name(char* name11)
{
	for (uint i = 0; i < 11; i++)
	{
		if (name11[i] != FS_PROTECTED_NAME_1[i]) return false;
	}
	return true;
}

// Top-level write handler: the protected-name check here is a fast,
// obvious first gate; diskd_rw()'s reserved-sector check (see this
// file's header comment) is the real backstop if this one is ever
// bypassed or the protected-name list gets out of sync with the
// reserved-cluster list. Creates the file if it doesn't exist yet,
// writes the data (extending its chain as needed), then re-locates its
// directory entry to update the size field — done as a fresh lookup
// rather than threading the entry's location through the create-vs-
// overwrite paths separately, simpler and more robust.
fn int fs_do_write(char* name11, char* src, uint len)
{
	if (fs_write_disabled) return -1;
	if (fs_is_protected_name(name11)) return -1;

	uint cluster;
	uint size;
	uint entry_sector;
	uint entry_offset;
	bool exists = fat32_find_in_root(name11, &cluster, &size, &entry_sector, &entry_offset);

	if (!exists)
	{
		if (!fat32_create_file(name11, &cluster)) return -1;
	}

	uint written = fat32_write_file(cluster, src, len);

	uint final_cluster;
	uint final_size;
	if (!fat32_find_in_root(name11, &final_cluster, &final_size, &entry_sector, &entry_offset))
	{
		return -1; // should be unreachable — don't claim success if it is
	}
	if (!fat32_update_entry_size(entry_sector, entry_offset, written)) return -1;

	return (int)written;
}

fn void fs_init()
{
	if (fs_partition_info(&fs_partition_start) < 0)
	{
		fs_panic("failed to get partition info");
	}

	char[SECTOR_SIZE] boot_sector @noinit;
	if (!fat32_read_sector(0, &boot_sector))
	{
		fs_panic("failed to read boot sector");
	}

	ushort* sig = (ushort*)&boot_sector[BPB_SIGNATURE_OFFSET];
	if (*sig != 0xAA55)
	{
		fs_panic("bad FAT32 boot sector signature");
	}

	ushort* bytes_per_sector = (ushort*)&boot_sector[BPB_BYTES_PER_SECTOR];
	if (*bytes_per_sector != SECTOR_SIZE)
	{
		// Every other part of this project assumes 512-byte sectors —
		// panic clearly rather than silently mishandle a nonstandard one.
		fs_panic("FAT32 volume doesn't use 512-byte sectors");
	}

	char   sectors_per_cluster = boot_sector[BPB_SECTORS_PER_CLUSTER];
	ushort* reserved_sectors   = (ushort*)&boot_sector[BPB_RESERVED_SECTORS];
	char   num_fats            = boot_sector[BPB_NUM_FATS];
	uint*  fat_size_32         = (uint*)&boot_sector[BPB_FAT_SIZE_32];
	uint*  root_cluster        = (uint*)&boot_sector[BPB_ROOT_CLUSTER];
	uint*  total_sectors_32    = (uint*)&boot_sector[BPB_TOTAL_SECTORS_32];

	// `& 0xFF` rather than a straight (uint) cast: char's signedness in
	// this dialect isn't relied on elsewhere in this codebase, and
	// masking gives the correct unsigned byte value either way — a
	// signed char holding the bit pattern for 255 would otherwise
	// sign-extend to 0xFFFFFFFF on a plain widening cast.
	fs_sectors_per_cluster = (uint)sectors_per_cluster & 0xFF;
	fs_fat_start_sector    = (uint)*reserved_sectors;
	fs_num_fats            = (uint)num_fats & 0xFF;
	fs_fat_size_32         = *fat_size_32;
	fs_data_start_sector   = fs_fat_start_sector + fs_num_fats * fs_fat_size_32;
	fs_root_cluster        = *root_cluster;
	fs_total_clusters      = (*total_sectors_32 - fs_data_start_sector) / fs_sectors_per_cluster;

	print("fsd: FAT32 mounted, partition_start=");
	print_uint(fs_partition_start);
	print(" root_cluster=");
	print_uint(fs_root_cluster);
	print(" sectors_per_cluster=");
	print_uint(fs_sectors_per_cluster);
	print("\n");

	// Write protection: build the reserved-cluster allowlist before ever
	// allowing a write — fs_write_disabled starts true (see its own
	// comment) and only comes down once this succeeds without overflow.
	fs_write_disabled = false;
	fs_reserve_protected_file(&FS_PROTECTED_NAME_1);
	print("fsd: write-protected ");
	print_uint(fs_reserved_count);
	print(" cluster(s)");
	if (fs_write_disabled) print(" — writes DISABLED");
	print("\n");
}

fn void main() @export("main")
{
	fs_init();

	for (;;)
	{
		char[FS_MSG_MAX] buf @noinit;
		uint verb = 0;
		int from = ipc_recv_type(&buf, FS_MSG_MAX, &verb);
		if (from <= 0) continue;
		if (verb != FS_READ && verb != FS_WRITE) continue;

		int* result_len_field = (int*)&buf;

		// Pull the filename and requested length out before touching buf
		// again — the reply reuses the same offsets for different things
		// (result length at 0..3, data at 4..), so anything needed from
		// the request has to be captured first. Shared prefix layout for
		// both verbs (see user.c3's wire-format comment) — FS_WRITE's
		// data follows at byte 104, read directly out of `buf` below
		// rather than copied, same as FS_READ writes its reply directly
		// into `buf` without an intermediate copy.
		char[100] filename @noinit;
		for (int i = 0; i < 100; i++)
		{
			filename[i] = buf[i];
		}
		uint* len_field = (uint*)&buf[100];
		int req_len = (int)*len_field;
		// Untrusted input — clamp rather than trust the caller not to
		// set the field's high bit. See docs/devlog.md for the same
		// hardening pass that added this check.
		if (req_len < 0) req_len = 0;

		char[11] name11 @noinit;
		name_to_8_3(&filename, &name11);

		if (verb == FS_WRITE)
		{
			if (req_len > (int)(FS_MSG_MAX - 104)) req_len = (int)(FS_MSG_MAX - 104);
			int result = fs_do_write(&name11, &buf[104], (uint)req_len);
			*result_len_field = result;
			ipc_send(from, verb, &buf, FS_MSG_MAX);
			continue;
		}

		uint first_cluster;
		uint file_size;
		uint entry_sector;
		uint entry_offset;
		if (!fat32_find_in_root(&name11, &first_cluster, &file_size, &entry_sector, &entry_offset))
		{
			*result_len_field = -1;
			ipc_send(from, verb, &buf, FS_MSG_MAX);
			continue;
		}

		int read_len = req_len;
		if (read_len > (int)file_size) read_len = (int)file_size;
		if (read_len > (int)(FS_MSG_MAX - 4)) read_len = (int)(FS_MSG_MAX - 4);

		uint actually_read = fat32_read_file(first_cluster, &buf[4], (uint)read_len);
		*result_len_field = (int)actually_read;

		ipc_send(from, verb, &buf, FS_MSG_MAX);
	}
}
