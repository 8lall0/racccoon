module user;

// FAT32 backend for fsd (see user/fsd.c3's own header comment for the
// generic core / backend split). Standard, stable public spec — offsets
// below are the well-known FAT32 layout (same one Linux's fs/fat and
// every other FAT32 reader implements), not vendor-specific or
// reverse-engineered the way this project's SDHCI register maps were.
//
// v1 scope, deliberately limited: 8.3 short filenames only (long
// filename / LFN directory entries are skipped, not parsed), no
// caching — every call walks the relevant directory fresh (root, or a
// subdirectory reached via fat32_resolve_dir — see its own comment)
// and follows the matched file's cluster chain on demand, since
// there's no reasonable fixed-size cache for "however many files
// happen to be on someone's real SD card."
//
// Write support (create, overwrite, grow — see fat32_write()) started
// read-only-only and was extended deliberately — see user/fsd.c3's own
// header comment for the full write-protection rationale (the reserved-
// sector-range allowlist and exact protected-entry check this backend
// populates but doesn't enforce itself; enforcement lives in fsd.c3's
// diskd_rw(), the one function every write here funnels through via
// fs_write_sector()).

// BPB (BIOS Parameter Block) field offsets within the boot sector
// (sector 0 of the partition).
const uint FAT32_BPB_BYTES_PER_SECTOR    = 0x0B; // u16
const uint FAT32_BPB_SECTORS_PER_CLUSTER = 0x0D; // u8
const uint FAT32_BPB_RESERVED_SECTORS    = 0x0E; // u16
const uint FAT32_BPB_NUM_FATS            = 0x10; // u8
const uint FAT32_BPB_TOTAL_SECTORS_32    = 0x20; // u32, the only valid total-volume-size field in FAT32 (the u16 field @0x13 is always 0)
const uint FAT32_BPB_FAT_SIZE_32         = 0x24; // u32, sectors per FAT
const uint FAT32_BPB_ROOT_CLUSTER        = 0x2C; // u32
const uint FAT32_BPB_SIGNATURE_OFFSET    = 0x1FE; // u16, must be 0xAA55 (little-endian 0x55,0xAA)

// Directory entry (32 bytes) field offsets.
const uint FAT32_DIRENT_SIZE           = 32;
const uint FAT32_DIRENT_NAME           = 0x00; // 11 bytes, 8.3 short name, space-padded, uppercase
const uint FAT32_DIRENT_ATTR           = 0x0B; // u8
const uint FAT32_DIRENT_CLUSTER_HI     = 0x14; // u16
const uint FAT32_DIRENT_CLUSTER_LO     = 0x1A; // u16
const uint FAT32_DIRENT_FILE_SIZE      = 0x1C; // u32

const char FAT32_DIRENT_FREE_REST   = (char)0x00; // this entry and all following are unused
const char FAT32_DIRENT_DELETED     = (char)0xE5; // this entry is deleted, keep scanning
const char FAT32_DIRENT_ATTR_LFN    = (char)0x0F; // long-filename entry, not a real file — skip
const char FAT32_DIRENT_ATTR_VOLUME = (char)0x08; // volume label bit — skip, never a real file
const char FAT32_DIRENT_ATTR_DIRECTORY = (char)0x10; // subdirectory, not a regular file — see fat32_find_in_dir

const uint FAT32_ENTRY_MASK = 0x0FFFFFFF; // low 28 bits significant
const uint FAT32_EOC_MIN    = 0x0FFFFFF8; // cluster values at or above this mean end-of-chain

// Derived layout, computed once by fat32_mount() and cached — cheap,
// board-static-ish facts about the volume, unlike per-file data (which
// is deliberately never cached — see this file's header comment).
uint fat32_fat_start_sector;
uint fat32_data_start_sector;
uint fat32_sectors_per_cluster;
uint fat32_root_cluster;
uint fat32_num_fats;      // needed by the write path to mirror every FAT update across all copies
uint fat32_fat_size_32;   // sectors per FAT copy — same
uint fat32_total_clusters; // upper bound for fat32_alloc_cluster()'s scan

fn bool fat32_probe()
{
	char[SECTOR_SIZE] boot_sector @noinit;
	if (!fs_read_sector(0, &boot_sector)) return false;
	ushort* sig = (ushort*)&boot_sector[FAT32_BPB_SIGNATURE_OFFSET];
	return *sig == 0xAA55;
}

fn uint fat32_cluster_to_sector(uint cluster)
{
	return fat32_data_start_sector + (cluster - 2) * fat32_sectors_per_cluster;
}

// Reads one 4-byte little-endian FAT entry and returns its low 28 bits —
// the next cluster in the chain (or a value >= FAT32_EOC_MIN at the end).
// A read failure is treated as end-of-chain rather than propagated: this
// is a best-effort reader, not a filesystem that needs to distinguish
// "corrupt" from "empty" for correctness anywhere it's used.
fn uint fat32_next_cluster(uint cluster)
{
	uint fat_byte_offset = cluster * 4;
	uint fat_sector = fat32_fat_start_sector + (fat_byte_offset / SECTOR_SIZE);
	uint entry_offset = fat_byte_offset % SECTOR_SIZE;

	char[SECTOR_SIZE] sector_buf @noinit;
	if (!fs_read_sector(fat_sector, &sector_buf)) return FAT32_EOC_MIN;

	uint* entry = (uint*)&sector_buf[entry_offset];
	return *entry & FAT32_ENTRY_MASK;
}

// Converts a plain, null-terminated, lowercase-or-mixed-case filename
// like "hello.txt" into raw 8.3 short-name form: 11 bytes, space-padded,
// uppercase, no dot — "HELLO   TXT" — ready to compare byte-for-byte
// against a directory entry's own FAT32_DIRENT_NAME field (already stored in
// exactly this form on disk). Truncates silently past 8 name / 3
// extension characters — no long-filename support in v1 (see this
// file's header comment).
fn void fat32_name_to_8_3(char* input, char* out11)
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
// (already in raw 8.3 form — see fat32_name_to_8_3) match. Returns true
// and fills *out_cluster/*out_size/*out_entry_sector/*out_entry_offset/
// *out_attr on a hit. The only remaining caller is
// fat32_reserve_protected() (read/write both go through
// fat32_find_in_dir instead, see this file's own subdirectory-support
// section) — out_attr lets it refuse a same-named directory rather
// than reserving its own cluster chain as if it were "the protected
// file"'s data, a real category error, not just imprecise.
fn bool fat32_find_in_root(char* name11, uint* out_cluster, uint* out_size, uint* out_entry_sector, uint* out_entry_offset, char* out_attr)
{
	uint cluster = fat32_root_cluster;
	char[SECTOR_SIZE] sector_buf @noinit;

	while (cluster != 0 && cluster < FAT32_EOC_MIN)
	{
		uint sector = fat32_cluster_to_sector(cluster);
		for (uint s = 0; s < fat32_sectors_per_cluster; s++)
		{
			if (!fs_read_sector(sector + s, &sector_buf)) return false;

			for (uint e = 0; e < SECTOR_SIZE / FAT32_DIRENT_SIZE; e++)
			{
				char* entry = &sector_buf[e * FAT32_DIRENT_SIZE];
				if (entry[0] == FAT32_DIRENT_FREE_REST) return false; // end of directory
				if (entry[0] == FAT32_DIRENT_DELETED) continue;

				char attr = entry[FAT32_DIRENT_ATTR];
				if (attr == FAT32_DIRENT_ATTR_LFN) continue;
				if ((attr & FAT32_DIRENT_ATTR_VOLUME) != 0) continue;

				bool match = true;
				for (uint k = 0; k < 11; k++)
				{
					if (entry[FAT32_DIRENT_NAME + k] != name11[k])
					{
						match = false;
						break;
					}
				}
				if (!match) continue;

				ushort* cluster_hi = (ushort*)&entry[FAT32_DIRENT_CLUSTER_HI];
				ushort* cluster_lo = (ushort*)&entry[FAT32_DIRENT_CLUSTER_LO];
				uint*   size_field = (uint*)&entry[FAT32_DIRENT_FILE_SIZE];
				*out_cluster      = ((uint)*cluster_hi << 16) | (uint)*cluster_lo;
				*out_size         = *size_field;
				*out_entry_sector = sector + s;
				*out_entry_offset = e * FAT32_DIRENT_SIZE;
				*out_attr         = attr;
				return true;
			}
		}
		cluster = fat32_next_cluster(cluster);
	}
	return false;
}

// --- Subdirectory support (read and write) ------------------------------
//
// fat32_read (below) and fat32_write (further down — create/overwrite/
// grow a file inside a subdirectory, not just the root, generalizing
// fat32_find_free_dirent/fat32_create_file the same way) both walk into
// a subdirectory using the functions below. fat32_find_in_root and its
// one remaining caller, fat32_reserve_protected, stay root-only on
// purpose: the one file that ever needs protecting (fip.bin) is always
// in the root regardless of what this feature does. Real filesystem,
// standard on-disk format: a subdirectory is just an ordinary directory
// entry (FAT32_DIRENT_ATTR_DIRECTORY set) whose own cluster chain holds
// more directory entries, same shape as the root directory itself — so
// fat32_find_in_dir is fat32_find_in_root generalized to take any
// starting cluster, not new logic.

// Same walk as fat32_find_in_root, but over any directory's cluster
// chain, not just the root — and reports the matched entry's attribute
// byte too, so a caller can tell a subdirectory entry from a regular
// file before deciding what to do with the cluster it points at.
// out_entry_sector/out_entry_offset are the entry's own location (same
// as fat32_find_in_root's), needed by the write path (updating
// file_size in place, the protected-entry check) — fat32_resolve_dir's
// own directory-walking use just discards them into local dummies.
fn bool fat32_find_in_dir(uint dir_cluster, char* name11, uint* out_cluster, uint* out_size, uint* out_entry_sector, uint* out_entry_offset, char* out_attr)
{
	uint cluster = dir_cluster;
	char[SECTOR_SIZE] sector_buf @noinit;

	while (cluster != 0 && cluster < FAT32_EOC_MIN)
	{
		uint sector = fat32_cluster_to_sector(cluster);
		for (uint s = 0; s < fat32_sectors_per_cluster; s++)
		{
			if (!fs_read_sector(sector + s, &sector_buf)) return false;

			for (uint e = 0; e < SECTOR_SIZE / FAT32_DIRENT_SIZE; e++)
			{
				char* entry = &sector_buf[e * FAT32_DIRENT_SIZE];
				if (entry[0] == FAT32_DIRENT_FREE_REST) return false;
				if (entry[0] == FAT32_DIRENT_DELETED) continue;

				char attr = entry[FAT32_DIRENT_ATTR];
				if (attr == FAT32_DIRENT_ATTR_LFN) continue;
				if ((attr & FAT32_DIRENT_ATTR_VOLUME) != 0) continue;

				bool match = true;
				for (uint k = 0; k < 11; k++)
				{
					if (entry[FAT32_DIRENT_NAME + k] != name11[k])
					{
						match = false;
						break;
					}
				}
				if (!match) continue;

				ushort* cluster_hi = (ushort*)&entry[FAT32_DIRENT_CLUSTER_HI];
				ushort* cluster_lo = (ushort*)&entry[FAT32_DIRENT_CLUSTER_LO];
				uint*   size_field = (uint*)&entry[FAT32_DIRENT_FILE_SIZE];
				*out_cluster      = ((uint)*cluster_hi << 16) | (uint)*cluster_lo;
				*out_size         = *size_field;
				*out_entry_sector = sector + s;
				*out_entry_offset = e * FAT32_DIRENT_SIZE;
				*out_attr         = attr;
				return true;
			}
		}
		cluster = fat32_next_cluster(cluster);
	}
	return false;
}

// Splits `path` on '/' and walks from the root through every directory
// component but the last, requiring each to actually be a directory
// (FAT32_DIRENT_ATTR_DIRECTORY) — a path component that matches a
// regular file instead fails the resolve, same as one that doesn't
// match anything. A bare filename with no '/' at all resolves trivially
// to the root, unchanged from every existing single-level caller.
// Empty segments (a leading '/', a doubled '//') are skipped rather
// than treated as a lookup failure.
fn bool fat32_resolve_dir(char* path, uint* out_dir_cluster)
{
	uint dir_cluster = fat32_root_cluster;
	uint seg_start = 0;
	uint i = 0;
	for (;;)
	{
		if (path[i] != '/' && path[i] != 0)
		{
			i++;
			continue;
		}

		uint seg_len = i - seg_start;
		if (seg_len > 0 && path[i] == '/')
		{
			char[64] seg_buf @noinit;
			uint copy_len = seg_len < 63 ? seg_len : 63;
			for (uint k = 0; k < copy_len; k++) seg_buf[k] = path[seg_start + k];
			seg_buf[copy_len] = 0;

			char[11] seg11 @noinit;
			fat32_name_to_8_3(&seg_buf, &seg11);

			uint next_cluster;
			uint dummy_size;
			uint dummy_sector;
			uint dummy_offset;
			char attr;
			if (!fat32_find_in_dir(dir_cluster, &seg11, &next_cluster, &dummy_size, &dummy_sector, &dummy_offset, &attr)) return false;
			if ((attr & FAT32_DIRENT_ATTR_DIRECTORY) == 0) return false;
			dir_cluster = next_cluster;
		}

		if (path[i] == 0) break;
		seg_start = i + 1;
		i++;
	}
	*out_dir_cluster = dir_cluster;
	return true;
}

// The final path component (after the last '/', or the whole string if
// there's none) — a pointer into `path` itself, no copy.
fn char* fat32_leaf_name(char* path)
{
	char* leaf = path;
	uint i = 0;
	while (path[i] != 0)
	{
		if (path[i] == '/') leaf = &path[i + 1];
		i++;
	}
	return leaf;
}

// Follows first_cluster's chain, copying up to `len` bytes (already
// clamped by the caller against the file's real size) into dst starting
// from the beginning of the file. Returns the number of bytes actually
// copied — normally equal to len, but can come up short (rather than
// leave dst partially uninitialized) if the chain turns out shorter than
// the directory entry's own size field claimed.
fn uint fat32_read_file(uint first_cluster, char* dst, uint len)
{
	uint cluster = first_cluster;
	uint bytes_read = 0;
	char[SECTOR_SIZE] sector_buf @noinit;

	while (cluster != 0 && cluster < FAT32_EOC_MIN && bytes_read < len)
	{
		uint sector = fat32_cluster_to_sector(cluster);
		for (uint s = 0; s < fat32_sectors_per_cluster && bytes_read < len; s++)
		{
			if (!fs_read_sector(sector + s, &sector_buf)) return bytes_read;

			uint chunk = len - bytes_read;
			if (chunk > SECTOR_SIZE) chunk = SECTOR_SIZE;
			for (uint i = 0; i < chunk; i++)
			{
				dst[bytes_read + i] = sector_buf[i];
			}
			bytes_read += chunk;
		}
		cluster = fat32_next_cluster(cluster);
	}
	return bytes_read;
}

// Entry point dispatched from fsd.c3's main() for FS_READ. `name` is a
// plain, null-terminated filename — 8.3 conversion happens here, not in
// the caller. Returns -1 if not found, else bytes actually read
// (already clamped to the file's real size).
fn int fat32_read(char* name, char* dst, uint len)
{
	uint dir_cluster;
	if (!fat32_resolve_dir(name, &dir_cluster)) return -1;
	char* leaf = fat32_leaf_name(name);

	char[11] name11 @noinit;
	fat32_name_to_8_3(leaf, &name11);

	uint first_cluster;
	uint file_size;
	uint dummy_sector;
	uint dummy_offset;
	char attr;
	if (!fat32_find_in_dir(dir_cluster, &name11, &first_cluster, &file_size, &dummy_sector, &dummy_offset, &attr))
	{
		return -1;
	}
	// A directory isn't file content — refuse rather than hand back
	// whatever bytes its own directory-entry cluster happens to hold.
	if ((attr & FAT32_DIRENT_ATTR_DIRECTORY) != 0) return -1;

	uint read_len = len;
	if (read_len > file_size) read_len = file_size;

	return (int)fat32_read_file(first_cluster, dst, read_len);
}

// --- Write path -------------------------------------------------------

// Writes one 4-byte little-endian FAT entry (low 28 bits of `value`,
// preserving whatever's in the top 4 reserved bits) to EVERY FAT copy
// (fat32_num_fats of them, each fat32_fat_size_32 sectors apart) — a real
// FAT32 reader is free to trust either copy, so leaving them out of sync
// is a real, if usually low-severity, corruption. Read-modify-write per
// copy since sectors are the smallest unit fs_write_sector can touch.
fn bool fat32_write_fat_entry(uint cluster, uint value)
{
	uint fat_byte_offset = cluster * 4;
	uint fat_sector_rel = fat_byte_offset / SECTOR_SIZE;
	uint entry_offset = fat_byte_offset % SECTOR_SIZE;

	for (uint copy = 0; copy < fat32_num_fats; copy++)
	{
		uint fat_sector = fat32_fat_start_sector + copy * fat32_fat_size_32 + fat_sector_rel;
		char[SECTOR_SIZE] sector_buf @noinit;
		if (!fs_read_sector(fat_sector, &sector_buf)) return false;
		uint* entry = (uint*)&sector_buf[entry_offset];
		*entry = (*entry & ~FAT32_ENTRY_MASK) | (value & FAT32_ENTRY_MASK);
		if (!fs_write_sector(fat_sector, &sector_buf)) return false;
	}
	return true;
}

// Looks up a protected file (plain name, e.g. "fip.bin" — 8.3 conversion
// happens here) and: records its directory entry's exact (sector,
// offset) via fs_set_protected_entry() — see that function's own
// comment in fsd.c3 for why that's checked separately rather than
// folded into the range allowlist — and reserves every cluster in its
// DATA chain at the coarser, range-granular level (safe there: unlike
// the shared root directory, one cluster only ever belongs to one
// file's data). A file that isn't found (QEMU's disposable test image
// has no fip.bin) is simply nothing to protect — logged so it's
// visible, not silently skipped.
fn void fat32_reserve_protected(char* name)
{
	char[11] name11 @noinit;
	fat32_name_to_8_3(name, &name11);

	uint cluster;
	uint size;
	uint entry_sector;
	uint entry_offset;
	char attr;
	if (!fat32_find_in_root(&name11, &cluster, &size, &entry_sector, &entry_offset, &attr))
	{
		print("fsd: protected file not found, nothing to reserve for it\n");
		return;
	}
	// A same-named directory isn't the protected file — treated the
	// same as "not found" rather than reserving its own cluster chain
	// as if it were "the protected file"'s data (see fat32_find_in_
	// root's own comment).
	if ((attr & FAT32_DIRENT_ATTR_DIRECTORY) != 0)
	{
		print("fsd: protected file not found, nothing to reserve for it\n");
		return;
	}

	fs_set_protected_entry(entry_sector, entry_offset);

	while (cluster != 0 && cluster < FAT32_EOC_MIN)
	{
		if (!fs_reserve_sector_range(fat32_cluster_to_sector(cluster), fat32_sectors_per_cluster)) return;
		cluster = fat32_next_cluster(cluster);
	}
}

// Linear scan for a free (FAT entry == 0) cluster, starting at 2 (the
// first real cluster number). Marks it FAT32_EOC_MIN in every FAT copy
// immediately, before returning it, closing the window where a second
// allocation later in the same request could pick the same cluster
// twice. Returns 0 (never a valid cluster number) on "no free space" or
// any read failure along the way. Doesn't separately skip reserved
// clusters here: a correctly maintained FAT never marks a reserved
// cluster free, and fs_write_sector's own reserved-sector check (via
// fat32_write_fat_entry below) would refuse the marking write anyway if
// it somehow did — the allowlist's enforcement point is deliberately
// singular (see fsd.c3's header comment), not duplicated per caller.
fn uint fat32_alloc_cluster()
{
	for (uint cluster = 2; cluster < fat32_total_clusters + 2; cluster++)
	{
		if (fat32_next_cluster(cluster) == 0)
		{
			if (!fat32_write_fat_entry(cluster, FAT32_EOC_MIN)) return 0;
			return cluster;
		}
	}
	return 0;
}

// Walks dir_cluster's own chain (root or a subdirectory — see
// fat32_write's own comment on write-into-subdirectory support) looking
// for a reusable entry slot (first byte 0x00 "free, and everything
// after" or 0xE5 "deleted"). Always fills *out_last_cluster with the
// final cluster of that chain as it walks — needed by the caller to
// extend the chain if no free slot turns up, and harmless to compute
// even when one is found. Returns false (chain needs extending) only
// after scanning the whole chain without finding a slot.
fn bool fat32_find_free_dirent(uint dir_cluster, uint* out_entry_sector, uint* out_entry_offset, uint* out_last_cluster)
{
	uint cluster = dir_cluster;
	char[SECTOR_SIZE] sector_buf @noinit;

	while (cluster != 0 && cluster < FAT32_EOC_MIN)
	{
		*out_last_cluster = cluster;
		uint sector = fat32_cluster_to_sector(cluster);
		for (uint s = 0; s < fat32_sectors_per_cluster; s++)
		{
			if (!fs_read_sector(sector + s, &sector_buf)) return false;

			for (uint e = 0; e < SECTOR_SIZE / FAT32_DIRENT_SIZE; e++)
			{
				char* entry = &sector_buf[e * FAT32_DIRENT_SIZE];
				if (entry[0] == FAT32_DIRENT_FREE_REST || entry[0] == FAT32_DIRENT_DELETED)
				{
					*out_entry_sector = sector + s;
					*out_entry_offset = e * FAT32_DIRENT_SIZE;
					return true;
				}
			}
		}
		cluster = fat32_next_cluster(cluster);
	}
	return false;
}

// Creates a new, empty (zero-size) directory entry for name11 inside
// dir_cluster (root or a subdirectory) and allocates its first data
// cluster. Extends dir_cluster's own chain with a freshly zero-filled
// cluster if it has no free slot — a directory cluster's bytes are
// always interpreted as entries (unlike file data past the declared
// size, which is never exposed to a reader), so unlike
// fat32_write_file below, this really does need zero-filling for
// correctness, not just tidiness.
fn bool fat32_create_file(uint dir_cluster, char* name11, uint* out_first_cluster)
{
	uint first_cluster = fat32_alloc_cluster();
	if (first_cluster == 0) return false;

	uint entry_sector;
	uint entry_offset;
	uint last_dir_cluster;
	if (!fat32_find_free_dirent(dir_cluster, &entry_sector, &entry_offset, &last_dir_cluster))
	{
		uint new_dir_cluster = fat32_alloc_cluster();
		if (new_dir_cluster == 0) return false;

		char[SECTOR_SIZE] zero_buf @noinit;
		for (uint i = 0; i < SECTOR_SIZE; i++) zero_buf[i] = 0;
		for (uint s = 0; s < fat32_sectors_per_cluster; s++)
		{
			if (!fs_write_sector(fat32_cluster_to_sector(new_dir_cluster) + s, &zero_buf)) return false;
		}

		if (!fat32_write_fat_entry(last_dir_cluster, new_dir_cluster)) return false;
		if (!fat32_write_fat_entry(new_dir_cluster, FAT32_EOC_MIN)) return false;

		entry_sector = fat32_cluster_to_sector(new_dir_cluster);
		entry_offset = 0;
	}

	// Defense in depth — see fs_is_protected_entry's own comment in
	// fsd.c3. Structurally unreachable in practice: fat32_find_free_dirent
	// only ever returns a free/deleted slot, and a protected file's real
	// entry is neither, so this would require a bug in that scan to ever
	// fire.
	if (fs_is_protected_entry(entry_sector, entry_offset)) return false;

	char[SECTOR_SIZE] sector_buf @noinit;
	if (!fs_read_sector(entry_sector, &sector_buf)) return false;

	char* entry = &sector_buf[entry_offset];
	for (uint i = 0; i < 11; i++) entry[FAT32_DIRENT_NAME + i] = name11[i];
	entry[FAT32_DIRENT_ATTR] = (char)0x20; // ARCHIVE — an ordinary file
	// Reserved/create-time/create-date/last-access-date fields (bytes
	// 0x0C-0x13, between ATTR and cluster-hi) — zeroed explicitly rather
	// than left as whatever a reused 0xE5 (deleted) slot's old file had
	// in them. Every FAT32 reader tolerates an all-zero date (shows as
	// 1980-01-01), so this is a real correctness cleanup, not required
	// for safety.
	for (uint i = 0x0C; i < 0x14; i++) entry[i] = 0;
	ushort* cluster_hi = (ushort*)&entry[FAT32_DIRENT_CLUSTER_HI];
	ushort* cluster_lo = (ushort*)&entry[FAT32_DIRENT_CLUSTER_LO];
	uint*   size_field  = (uint*)&entry[FAT32_DIRENT_FILE_SIZE];
	*cluster_hi = (ushort)(first_cluster >> 16);
	*cluster_lo = (ushort)(first_cluster & 0xFFFF);
	*size_field = 0;

	if (!fs_write_sector(entry_sector, &sector_buf)) return false;

	*out_first_cluster = first_cluster;
	return true;
}

// Writes `len` bytes from `src` into first_cluster's chain, starting
// from the beginning of the file, extending the chain (allocating new
// clusters, one at a time, as needed) if `len` needs more space than the
// chain currently has. Returns the number of bytes actually written —
// short only on a genuine failure (out of space, a reserved-sector
// refusal, an I/O error) partway through, in which case the file is left
// with whatever prefix did get written; the caller updates the
// directory entry's size field to match what actually happened, not
// what was requested (see fat32_write()).
fn uint fat32_write_file(uint first_cluster, char* src, uint len)
{
	uint cluster = first_cluster;
	uint bytes_written = 0;
	char[SECTOR_SIZE] sector_buf @noinit;

	while (bytes_written < len)
	{
		uint sector = fat32_cluster_to_sector(cluster);
		for (uint s = 0; s < fat32_sectors_per_cluster && bytes_written < len; s++)
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
				if (!fs_read_sector(sector + s, &sector_buf)) return bytes_written;
			}
			for (uint i = 0; i < chunk; i++)
			{
				sector_buf[i] = src[bytes_written + i];
			}
			if (!fs_write_sector(sector + s, &sector_buf)) return bytes_written;
			bytes_written += chunk;
		}

		if (bytes_written >= len) break;

		uint next = fat32_next_cluster(cluster);
		if (next >= FAT32_EOC_MIN)
		{
			next = fat32_alloc_cluster();
			if (next == 0) return bytes_written;
			if (!fat32_write_fat_entry(cluster, next)) return bytes_written;
			if (!fat32_write_fat_entry(next, FAT32_EOC_MIN)) return bytes_written;
		}
		cluster = next;
	}
	return bytes_written;
}

fn bool fat32_update_entry_size(uint entry_sector, uint entry_offset, uint new_size)
{
	// Real backstop here, unlike fat32_create_file's — fsd.c3's
	// fs_is_protected_name() already rejects the literal protected name
	// before this backend is ever called for a write, but this check
	// doesn't depend on that string comparison staying correct or every
	// future caller remembering to check it first.
	if (fs_is_protected_entry(entry_sector, entry_offset)) return false;

	char[SECTOR_SIZE] sector_buf @noinit;
	if (!fs_read_sector(entry_sector, &sector_buf)) return false;
	uint* size_field = (uint*)&sector_buf[entry_offset + FAT32_DIRENT_FILE_SIZE];
	*size_field = new_size;
	return fs_write_sector(entry_sector, &sector_buf);
}

// Entry point dispatched from fsd.c3's main() for FS_WRITE — only ever
// called once fsd.c3's own fs_is_protected_name() check has already
// passed, so no protected-name check here; fs_write_disabled and the
// reserved-sector-range check are enforced even lower, in fs_write_sector
// (via diskd_rw), so not duplicated here either. `name` is a plain,
// null-terminated filename — 8.3 conversion happens here. Creates the
// file if it doesn't exist yet, writes the data (extending its chain as
// needed), then re-locates its directory entry to update the size field
// — done as a fresh lookup rather than threading the entry's location
// through the create-vs-overwrite paths separately, simpler and more
// robust.
//
// Write-into-subdirectory: resolves the containing directory the same
// way fat32_read does (fat32_resolve_dir/fat32_leaf_name), then does
// everything else — existence check, create, find-free-slot, chain
// extension — against that directory's cluster instead of always the
// root. fat32_find_in_root/its own root-only fat32_reserve_protected
// caller are untouched: the one file that ever needs protecting
// (fip.bin) is always in the root, found and reserved once at mount
// time regardless of what this function does afterward.
fn int fat32_write(char* name, char* src, uint len)
{
	uint dir_cluster;
	if (!fat32_resolve_dir(name, &dir_cluster)) return -1;
	char* leaf = fat32_leaf_name(name);

	char[11] name11 @noinit;
	fat32_name_to_8_3(leaf, &name11);

	uint cluster;
	uint size;
	uint entry_sector;
	uint entry_offset;
	char attr;
	bool exists = fat32_find_in_dir(dir_cluster, &name11, &cluster, &size, &entry_sector, &entry_offset, &attr);
	// A directory isn't file content — refuse rather than overwrite
	// whatever it points at, same refusal fat32_read gives.
	if (exists && (attr & FAT32_DIRENT_ATTR_DIRECTORY) != 0) return -1;

	if (!exists)
	{
		if (!fat32_create_file(dir_cluster, &name11, &cluster)) return -1;
	}

	uint written = fat32_write_file(cluster, src, len);

	uint final_cluster;
	uint final_size;
	char final_attr;
	if (!fat32_find_in_dir(dir_cluster, &name11, &final_cluster, &final_size, &entry_sector, &entry_offset, &final_attr))
	{
		return -1; // should be unreachable — don't claim success if it is
	}
	if (!fat32_update_entry_size(entry_sector, entry_offset, written)) return -1;

	return (int)written;
}

// Frees every cluster in first_cluster's chain, marking each 0 (free)
// in every FAT copy. Reads each cluster's own next-link before
// clearing its entry — clearing first would lose the rest of the
// chain, same ordering concern fat32_write_file's own chain-extension
// code has in reverse.
fn bool fat32_free_cluster_chain(uint first_cluster)
{
	uint cluster = first_cluster;
	while (cluster != 0 && cluster < FAT32_EOC_MIN)
	{
		uint next = fat32_next_cluster(cluster);
		if (!fat32_write_fat_entry(cluster, 0)) return false;
		cluster = next;
	}
	return true;
}

// Checks whether a directory's cluster chain contains any real entry
// besides "." and ".." (the two entries every subdirectory has by
// convention — this driver never creates them itself, having no
// mkdir, but real FAT32 tools always do). fat32_name_to_8_3 doesn't
// handle "." or ".." correctly — it treats the leading dot as "start
// of the extension", producing an all-spaces 8.3 name for either — so
// they're matched directly against their real, fixed byte patterns
// instead. Fails closed (returns false, "not empty") on any read
// error, rather than risk letting fat32_delete free a directory it
// couldn't actually confirm was empty.
fn bool fat32_dir_is_empty(uint dir_cluster)
{
	uint cluster = dir_cluster;
	char[SECTOR_SIZE] sector_buf @noinit;

	while (cluster != 0 && cluster < FAT32_EOC_MIN)
	{
		uint sector = fat32_cluster_to_sector(cluster);
		for (uint s = 0; s < fat32_sectors_per_cluster; s++)
		{
			if (!fs_read_sector(sector + s, &sector_buf)) return false;

			for (uint e = 0; e < SECTOR_SIZE / FAT32_DIRENT_SIZE; e++)
			{
				char* entry = &sector_buf[e * FAT32_DIRENT_SIZE];
				if (entry[0] == FAT32_DIRENT_FREE_REST) return true;
				if (entry[0] == FAT32_DIRENT_DELETED) continue;

				char attr = entry[FAT32_DIRENT_ATTR];
				if (attr == FAT32_DIRENT_ATTR_LFN) continue;
				if ((attr & FAT32_DIRENT_ATTR_VOLUME) != 0) continue;

				bool is_dot    = entry[FAT32_DIRENT_NAME] == '.' && entry[FAT32_DIRENT_NAME + 1] == ' ';
				bool is_dotdot = entry[FAT32_DIRENT_NAME] == '.' && entry[FAT32_DIRENT_NAME + 1] == '.' && entry[FAT32_DIRENT_NAME + 2] == ' ';
				if (is_dot || is_dotdot) continue;

				return false;
			}
		}
		cluster = fat32_next_cluster(cluster);
	}
	return true;
}

// Entry point dispatched from fsd.c3's main() for a non-recursive
// FS_DELETE. Handles both a regular file and an *empty* directory
// (fat32_dir_is_empty, above — a non-empty one is refused, matching
// real rmdir()'s own semantics: no recursive auto-delete here; see
// fat32_delete_recursive below for that). Marks the directory entry
// FAT32_DIRENT_DELETED — the same value fat32_find_free_dirent already
// recognizes as reusable —
// *before* freeing the cluster chain, not after: if freeing fails
// partway, an entry that's already invisible to lookups with some of
// its clusters still marked used is a leak, safe; freeing the chain
// first and then failing to mark the entry deleted would leave a
// still-visible file pointing at clusters that could already be
// handed out to something else — a real two-files-one-cluster
// corruption risk, not just a leak.
fn int fat32_delete(char* name)
{
	uint dir_cluster;
	if (!fat32_resolve_dir(name, &dir_cluster)) return -1;
	char* leaf = fat32_leaf_name(name);

	char[11] name11 @noinit;
	fat32_name_to_8_3(leaf, &name11);

	uint cluster;
	uint size;
	uint entry_sector;
	uint entry_offset;
	char attr;
	if (!fat32_find_in_dir(dir_cluster, &name11, &cluster, &size, &entry_sector, &entry_offset, &attr)) return -1;
	if (fs_is_protected_entry(entry_sector, entry_offset)) return -1;
	if ((attr & FAT32_DIRENT_ATTR_DIRECTORY) != 0)
	{
		if (!fat32_dir_is_empty(cluster)) return -1;
	}

	char[SECTOR_SIZE] sector_buf @noinit;
	if (!fs_read_sector(entry_sector, &sector_buf)) return -1;
	sector_buf[entry_offset] = FAT32_DIRENT_DELETED;
	if (!fs_write_sector(entry_sector, &sector_buf)) return -1;

	return fat32_free_cluster_chain(cluster) ? 0 : -1;
}

// Defense-in-depth bound on fat32_delete_dir_contents' own recursion —
// not reachable through any well-formed FAT32 tree (a directory's
// cluster chain can only ever point at its *children*, never back at
// an ancestor), but nothing on-disk actually prevents a corrupted or
// adversarially crafted image from containing one anyway, and a real
// cycle would otherwise recurse forever and eventually blow this
// process's own stack instead of failing cleanly. 32 comfortably covers
// any real directory tree a human would actually create.
const int FAT32_MAX_DELETE_DEPTH = 32;

// Empties a directory's cluster chain by deleting everything inside it
// — files freed directly, subdirectories recursed into first — walking
// raw directory entries by cluster/sector/offset the same way
// fat32_dir_is_empty already does, rather than reconstructing 8.3 names
// into path strings and going back through fat32_find_in_dir/
// fat32_delete for each child (this driver has no long-filename
// support to round-trip through anyway, and every name it would need
// is already right here in the raw entry). Leaves dir_cluster's own
// chain allocated — freeing *that* is the caller's job, same as
// fat32_delete_recursive frees the top-level target's own chain once
// this returns.
fn bool fat32_delete_dir_contents(uint dir_cluster, int depth)
{
	if (depth >= FAT32_MAX_DELETE_DEPTH) return false;

	uint cluster = dir_cluster;
	while (cluster != 0 && cluster < FAT32_EOC_MIN)
	{
		uint sector = fat32_cluster_to_sector(cluster);
		for (uint s = 0; s < fat32_sectors_per_cluster; s++)
		{
			char[SECTOR_SIZE] sector_buf @noinit;
			if (!fs_read_sector(sector + s, &sector_buf)) return false;

			bool sector_modified = false;
			for (uint e = 0; e < SECTOR_SIZE / FAT32_DIRENT_SIZE; e++)
			{
				char* entry = &sector_buf[e * FAT32_DIRENT_SIZE];
				if (entry[0] == FAT32_DIRENT_FREE_REST) break;
				if (entry[0] == FAT32_DIRENT_DELETED) continue;

				char attr = entry[FAT32_DIRENT_ATTR];
				if (attr == FAT32_DIRENT_ATTR_LFN) continue;
				if ((attr & FAT32_DIRENT_ATTR_VOLUME) != 0) continue;

				bool is_dot    = entry[FAT32_DIRENT_NAME] == '.' && entry[FAT32_DIRENT_NAME + 1] == ' ';
				bool is_dotdot = entry[FAT32_DIRENT_NAME] == '.' && entry[FAT32_DIRENT_NAME + 1] == '.' && entry[FAT32_DIRENT_NAME + 2] == ' ';
				if (is_dot || is_dotdot) continue;

				uint entry_sector = sector + s;
				uint entry_offset = e * FAT32_DIRENT_SIZE;
				if (fs_is_protected_entry(entry_sector, entry_offset)) return false;

				ushort* child_cluster_hi = (ushort*)&entry[FAT32_DIRENT_CLUSTER_HI];
				ushort* child_cluster_lo = (ushort*)&entry[FAT32_DIRENT_CLUSTER_LO];
				uint child_cluster = ((uint)*child_cluster_hi << 16) | (uint)*child_cluster_lo;

				if ((attr & FAT32_DIRENT_ATTR_DIRECTORY) != 0)
				{
					if (!fat32_delete_dir_contents(child_cluster, depth + 1)) return false;
				}

				entry[0] = FAT32_DIRENT_DELETED;
				sector_modified = true;

				if (!fat32_free_cluster_chain(child_cluster)) return false;
			}
			if (sector_modified)
			{
				if (!fs_write_sector(sector + s, &sector_buf)) return false;
			}
		}
		cluster = fat32_next_cluster(cluster);
	}
	return true;
}

// Same as fat32_delete, but a non-empty directory is emptied first
// (fat32_delete_dir_contents, above) instead of refused — the real,
// separate, genuinely destructive operation fat32_delete's own comment
// deliberately deferred. A protected entry anywhere in the subtree
// (checked by fat32_delete_dir_contents for every child, and here for
// the target itself) aborts the whole operation before anything is
// freed — never a partial delete that silently skips just the
// protected part.
fn int fat32_delete_recursive(char* name)
{
	uint dir_cluster;
	if (!fat32_resolve_dir(name, &dir_cluster)) return -1;
	char* leaf = fat32_leaf_name(name);

	char[11] name11 @noinit;
	fat32_name_to_8_3(leaf, &name11);

	uint cluster;
	uint size;
	uint entry_sector;
	uint entry_offset;
	char attr;
	if (!fat32_find_in_dir(dir_cluster, &name11, &cluster, &size, &entry_sector, &entry_offset, &attr)) return -1;
	if (fs_is_protected_entry(entry_sector, entry_offset)) return -1;
	if ((attr & FAT32_DIRENT_ATTR_DIRECTORY) != 0)
	{
		if (!fat32_delete_dir_contents(cluster, 0)) return -1;
	}

	char[SECTOR_SIZE] sector_buf2 @noinit;
	if (!fs_read_sector(entry_sector, &sector_buf2)) return -1;
	sector_buf2[entry_offset] = FAT32_DIRENT_DELETED;
	if (!fs_write_sector(entry_sector, &sector_buf2)) return -1;

	return fat32_free_cluster_chain(cluster) ? 0 : -1;
}

// Entry point dispatched from fsd.c3's main() for FS_LIST. Lists
// dir_cluster's own entries (path == "" means the root) into out_buf,
// one fixed-size FS_LIST_ENTRY_SIZE record per real entry ("."/".."
// skipped, same as fat32_dir_is_empty/fat32_delete_dir_contents),
// stopping at max_entries — v1 scope, no pagination, matching every
// other "single reply, no continuation" limit in this codebase (see
// fsd.c3's own header comment). Converts each 8.3 on-disk name (always
// space-padded to 11 bytes) back into a normal display string
// ("NAME.EXT", no trailing dot if the extension is empty) — the
// inverse of fat32_name_to_8_3, needed here specifically because a
// listing is the one place this driver ever hands a raw on-disk name
// back to a caller instead of just matching against one.
fn bool fat32_list(char* path, char* out_buf, int max_entries, int* out_count)
{
	uint dir_cluster;
	if (path[0] == 0)
	{
		dir_cluster = fat32_root_cluster;
	}
	else
	{
		uint parent_cluster;
		if (!fat32_resolve_dir(path, &parent_cluster)) return false;
		char* leaf = fat32_leaf_name(path);
		char[11] name11 @noinit;
		fat32_name_to_8_3(leaf, &name11);
		uint cluster;
		uint size;
		uint entry_sector;
		uint entry_offset;
		char attr;
		if (!fat32_find_in_dir(parent_cluster, &name11, &cluster, &size, &entry_sector, &entry_offset, &attr)) return false;
		if ((attr & FAT32_DIRENT_ATTR_DIRECTORY) == 0) return false;
		dir_cluster = cluster;
	}

	int count = 0;
	uint cluster = dir_cluster;
	char[SECTOR_SIZE] sector_buf @noinit;
	while (cluster != 0 && cluster < FAT32_EOC_MIN && count < max_entries)
	{
		uint sector = fat32_cluster_to_sector(cluster);
		for (uint s = 0; s < fat32_sectors_per_cluster && count < max_entries; s++)
		{
			if (!fs_read_sector(sector + s, &sector_buf)) return false;

			for (uint e = 0; e < SECTOR_SIZE / FAT32_DIRENT_SIZE && count < max_entries; e++)
			{
				char* entry = &sector_buf[e * FAT32_DIRENT_SIZE];
				if (entry[0] == FAT32_DIRENT_FREE_REST) { *out_count = count; return true; }
				if (entry[0] == FAT32_DIRENT_DELETED) continue;

				char attr = entry[FAT32_DIRENT_ATTR];
				if (attr == FAT32_DIRENT_ATTR_LFN) continue;
				if ((attr & FAT32_DIRENT_ATTR_VOLUME) != 0) continue;

				bool is_dot    = entry[FAT32_DIRENT_NAME] == '.' && entry[FAT32_DIRENT_NAME + 1] == ' ';
				bool is_dotdot = entry[FAT32_DIRENT_NAME] == '.' && entry[FAT32_DIRENT_NAME + 1] == '.' && entry[FAT32_DIRENT_NAME + 2] == ' ';
				if (is_dot || is_dotdot) continue;

				char* rec = &out_buf[(uint)count * FS_LIST_ENTRY_SIZE];
				int ni = 0;
				for (uint k = 0; k < 8 && entry[FAT32_DIRENT_NAME + k] != ' '; k++)
				{
					rec[ni] = entry[FAT32_DIRENT_NAME + k];
					ni++;
				}
				if (entry[FAT32_DIRENT_NAME + 8] != ' ')
				{
					rec[ni] = '.';
					ni++;
					for (uint k = 8; k < 11 && entry[FAT32_DIRENT_NAME + k] != ' '; k++)
					{
						rec[ni] = entry[FAT32_DIRENT_NAME + k];
						ni++;
					}
				}
				rec[ni] = 0; // ni is always well under FS_LIST_NAME_MAX (11-byte 8.3 names + 1 dot)
				rec[FS_LIST_NAME_MAX] = ((attr & FAT32_DIRENT_ATTR_DIRECTORY) != 0) ? (char)1 : (char)0;
				count++;
			}
		}
		cluster = fat32_next_cluster(cluster);
	}
	*out_count = count;
	return true;
}

// Entry point dispatched from fsd.c3's main() for FS_MKDIR. Creates an
// empty directory at `path` — refuses if anything (file or directory)
// already exists there, or if the parent doesn't. Self-contained
// rather than sharing fat32_create_file's own "find/extend a free
// dirent slot" logic: close enough in shape, but a directory also
// needs its own first cluster pre-seeded with real "." and ".."
// entries (fat32_create_file's files are legitimately empty — zero
// clusters — until something writes to them), which doesn't fit
// naturally into that function without a flag threading through it.
//
// ".." points at 0 (not fat32_root_cluster) when the new directory's
// parent is the root — the real, standard FAT32 convention every
// reader (including this driver's own fat32_delete_dir_contents,
// which never inspects "."/".." clusters at all) expects, not
// something this driver invented.
fn int fat32_mkdir(char* path)
{
	uint parent_cluster;
	if (!fat32_resolve_dir(path, &parent_cluster)) return -1;
	char* leaf = fat32_leaf_name(path);

	char[11] name11 @noinit;
	fat32_name_to_8_3(leaf, &name11);

	uint existing_cluster;
	uint existing_size;
	uint existing_sector;
	uint existing_offset;
	char existing_attr;
	if (fat32_find_in_dir(parent_cluster, &name11, &existing_cluster, &existing_size, &existing_sector, &existing_offset, &existing_attr))
	{
		return -1; // already exists (file or directory)
	}

	uint new_cluster = fat32_alloc_cluster();
	if (new_cluster == 0) return -1;

	char[SECTOR_SIZE] zero_buf @noinit;
	for (uint i = 0; i < SECTOR_SIZE; i++) zero_buf[i] = 0;
	for (uint s = 0; s < fat32_sectors_per_cluster; s++)
	{
		if (!fs_write_sector(fat32_cluster_to_sector(new_cluster) + s, &zero_buf)) return -1;
	}

	uint dotdot_target = (parent_cluster == fat32_root_cluster) ? 0 : parent_cluster;

	char[SECTOR_SIZE] dir_buf @noinit;
	if (!fs_read_sector(fat32_cluster_to_sector(new_cluster), &dir_buf)) return -1;

	char* dot_entry = &dir_buf[0];
	dot_entry[0] = '.';
	for (uint i = 1; i < 11; i++) dot_entry[i] = ' ';
	dot_entry[FAT32_DIRENT_ATTR] = FAT32_DIRENT_ATTR_DIRECTORY;
	ushort* dot_hi = (ushort*)&dot_entry[FAT32_DIRENT_CLUSTER_HI];
	ushort* dot_lo = (ushort*)&dot_entry[FAT32_DIRENT_CLUSTER_LO];
	*dot_hi = (ushort)(new_cluster >> 16);
	*dot_lo = (ushort)(new_cluster & 0xFFFF);

	char* dotdot_entry = &dir_buf[FAT32_DIRENT_SIZE];
	dotdot_entry[0] = '.';
	dotdot_entry[1] = '.';
	for (uint i = 2; i < 11; i++) dotdot_entry[i] = ' ';
	dotdot_entry[FAT32_DIRENT_ATTR] = FAT32_DIRENT_ATTR_DIRECTORY;
	ushort* dotdot_hi = (ushort*)&dotdot_entry[FAT32_DIRENT_CLUSTER_HI];
	ushort* dotdot_lo = (ushort*)&dotdot_entry[FAT32_DIRENT_CLUSTER_LO];
	*dotdot_hi = (ushort)(dotdot_target >> 16);
	*dotdot_lo = (ushort)(dotdot_target & 0xFFFF);

	if (!fs_write_sector(fat32_cluster_to_sector(new_cluster), &dir_buf)) return -1;

	uint entry_sector;
	uint entry_offset;
	uint last_parent_cluster;
	if (!fat32_find_free_dirent(parent_cluster, &entry_sector, &entry_offset, &last_parent_cluster))
	{
		uint new_parent_cluster = fat32_alloc_cluster();
		if (new_parent_cluster == 0) return -1;
		for (uint s = 0; s < fat32_sectors_per_cluster; s++)
		{
			if (!fs_write_sector(fat32_cluster_to_sector(new_parent_cluster) + s, &zero_buf)) return -1;
		}
		if (!fat32_write_fat_entry(last_parent_cluster, new_parent_cluster)) return -1;
		if (!fat32_write_fat_entry(new_parent_cluster, FAT32_EOC_MIN)) return -1;
		entry_sector = fat32_cluster_to_sector(new_parent_cluster);
		entry_offset = 0;
	}

	if (fs_is_protected_entry(entry_sector, entry_offset)) return -1;

	char[SECTOR_SIZE] sector_buf @noinit;
	if (!fs_read_sector(entry_sector, &sector_buf)) return -1;

	char* entry = &sector_buf[entry_offset];
	for (uint i = 0; i < 11; i++) entry[FAT32_DIRENT_NAME + i] = name11[i];
	entry[FAT32_DIRENT_ATTR] = FAT32_DIRENT_ATTR_DIRECTORY;
	for (uint i = 0x0C; i < 0x14; i++) entry[i] = 0;
	ushort* cluster_hi = (ushort*)&entry[FAT32_DIRENT_CLUSTER_HI];
	ushort* cluster_lo = (ushort*)&entry[FAT32_DIRENT_CLUSTER_LO];
	uint*   size_field  = (uint*)&entry[FAT32_DIRENT_FILE_SIZE];
	*cluster_hi = (ushort)(new_cluster >> 16);
	*cluster_lo = (ushort)(new_cluster & 0xFFFF);
	*size_field = 0;

	if (!fs_write_sector(entry_sector, &sector_buf)) return -1;

	return 0;
}

// Entry point dispatched from fsd.c3's main() for FS_RENAME. Handles
// both a pure rename (same parent directory) and a real move (a
// different one) uniformly: adds a brand-new entry at the destination
// — same cluster/size/attr as the source, so no file *data* is ever
// copied, only the directory entry that points at it — then removes
// the source entry, in that order (new one safely in place before the
// old one goes away, same "fail toward a leak/duplicate, never toward
// losing the file" reasoning fat32_delete's own comment gives). A
// same-parent rename could reuse the source's own slot in place
// instead of consuming a fresh one, cheaper but real extra complexity
// for one case; not done here — same "documented inefficiency, not a
// correctness gap" tradeoff fat32_write's own header comment already
// accepts elsewhere in this driver.
//
// dir_cluster's own ".." entry, read directly rather than through the
// normal named-lookup path: fat32_name_to_8_3("..") would mangle it
// into something that never matches what fat32_mkdir actually wrote
// (see that function's own header comment — the leading dot is treated
// as the start of an extension). mkdir always places "." as a
// directory's first entry and ".." as its second, both in the first
// sector of its first cluster (fat32_mkdir's own dir_buf write, and
// fat32_rename's existing ".." fixup above already reads/writes this
// exact same fixed offset) — read that sector directly and pull the
// cluster field out by fixed offset instead. Translates the on-disk
// "0 means root" convention (fat32_mkdir's own dotdot_target) back into
// a real cluster number, so callers never need to know about it.
fn uint fat32_get_parent_cluster(uint dir_cluster)
{
	char[SECTOR_SIZE] sector_buf @noinit;
	if (!fs_read_sector(fat32_cluster_to_sector(dir_cluster), &sector_buf)) return fat32_root_cluster;
	char* dotdot_entry = &sector_buf[FAT32_DIRENT_SIZE];
	ushort* cluster_hi = (ushort*)&dotdot_entry[FAT32_DIRENT_CLUSTER_HI];
	ushort* cluster_lo = (ushort*)&dotdot_entry[FAT32_DIRENT_CLUSTER_LO];
	uint parent = ((uint)*cluster_hi << 16) | (uint)*cluster_lo;
	return parent == 0 ? fat32_root_cluster : parent;
}

// Walks from candidate_dir_cluster up through ".." entries — a plain
// bounded iteration, not recursion, but the same "never trust an
// on-disk structure to be well-formed enough for an unbounded walk"
// caution fat32_delete_dir_contents' own recursion depth cap already
// takes (reusing that exact constant: a directory tree deeper than
// that was already being refused elsewhere, so a cycle-detection walk
// doesn't need a more generous bound). Returns true (refuse the rename)
// if forbidden_cluster is ever found among candidate_dir_cluster's own
// ancestors, including candidate_dir_cluster itself — the case
// fat32_rename actually calls this for is "is the destination's parent
// directory forbidden_cluster itself, or somewhere inside it," which is
// exactly "moving forbidden_cluster into its own subtree."
fn bool fat32_would_create_cycle(uint candidate_dir_cluster, uint forbidden_cluster)
{
	uint cluster = candidate_dir_cluster;
	for (int depth = 0; depth < FAT32_MAX_DELETE_DEPTH; depth++)
	{
		if (cluster == forbidden_cluster) return true;
		if (cluster == fat32_root_cluster) return false;
		cluster = fat32_get_parent_cluster(cluster);
	}
	return true; // depth exhausted without reaching root — refuse rather than risk missing a real cycle
}

// Refuses outright (destination must not already exist — no silent
// overwrite the way POSIX rename(2) allows), refuses a source that's
// the write-protected file, and — see fat32_would_create_cycle's own
// comment — refuses "moving a directory into its own subtree" (a real
// cycle), closing what used to be a genuine known gap here.
fn int fat32_rename(char* old_path, char* new_path)
{
	uint old_parent_cluster;
	if (!fat32_resolve_dir(old_path, &old_parent_cluster)) return -1;
	char* old_leaf = fat32_leaf_name(old_path);
	char[11] old_name11 @noinit;
	fat32_name_to_8_3(old_leaf, &old_name11);

	uint cluster;
	uint size;
	uint old_entry_sector;
	uint old_entry_offset;
	char attr;
	if (!fat32_find_in_dir(old_parent_cluster, &old_name11, &cluster, &size, &old_entry_sector, &old_entry_offset, &attr)) return -1;
	if (fs_is_protected_entry(old_entry_sector, old_entry_offset)) return -1;

	uint new_parent_cluster;
	if (!fat32_resolve_dir(new_path, &new_parent_cluster)) return -1;
	char* new_leaf = fat32_leaf_name(new_path);
	char[11] new_name11 @noinit;
	fat32_name_to_8_3(new_leaf, &new_name11);

	// Moving a directory: refuse if the destination's own parent chain
	// runs through the directory being moved — see
	// fat32_would_create_cycle's own comment. Files can never create a
	// cycle (they have no children to contain anything), so this only
	// applies to attr's directory bit.
	if ((attr & FAT32_DIRENT_ATTR_DIRECTORY) != 0 && fat32_would_create_cycle(new_parent_cluster, cluster))
	{
		return -1;
	}

	uint existing_cluster;
	uint existing_size;
	uint existing_sector;
	uint existing_offset;
	char existing_attr;
	if (fat32_find_in_dir(new_parent_cluster, &new_name11, &existing_cluster, &existing_size, &existing_sector, &existing_offset, &existing_attr))
	{
		return -1; // destination already exists
	}

	uint new_entry_sector;
	uint new_entry_offset;
	uint last_new_parent_cluster;
	if (!fat32_find_free_dirent(new_parent_cluster, &new_entry_sector, &new_entry_offset, &last_new_parent_cluster))
	{
		uint new_dir_cluster = fat32_alloc_cluster();
		if (new_dir_cluster == 0) return -1;
		char[SECTOR_SIZE] zero_buf @noinit;
		for (uint i = 0; i < SECTOR_SIZE; i++) zero_buf[i] = 0;
		for (uint s = 0; s < fat32_sectors_per_cluster; s++)
		{
			if (!fs_write_sector(fat32_cluster_to_sector(new_dir_cluster) + s, &zero_buf)) return -1;
		}
		if (!fat32_write_fat_entry(last_new_parent_cluster, new_dir_cluster)) return -1;
		if (!fat32_write_fat_entry(new_dir_cluster, FAT32_EOC_MIN)) return -1;
		new_entry_sector = fat32_cluster_to_sector(new_dir_cluster);
		new_entry_offset = 0;
	}
	if (fs_is_protected_entry(new_entry_sector, new_entry_offset)) return -1;

	char[SECTOR_SIZE] new_sector_buf @noinit;
	if (!fs_read_sector(new_entry_sector, &new_sector_buf)) return -1;
	char* new_entry = &new_sector_buf[new_entry_offset];
	for (uint i = 0; i < 11; i++) new_entry[FAT32_DIRENT_NAME + i] = new_name11[i];
	new_entry[FAT32_DIRENT_ATTR] = attr;
	for (uint i = 0x0C; i < 0x14; i++) new_entry[i] = 0;
	ushort* new_cluster_hi = (ushort*)&new_entry[FAT32_DIRENT_CLUSTER_HI];
	ushort* new_cluster_lo = (ushort*)&new_entry[FAT32_DIRENT_CLUSTER_LO];
	uint*   new_size_field  = (uint*)&new_entry[FAT32_DIRENT_FILE_SIZE];
	*new_cluster_hi = (ushort)(cluster >> 16);
	*new_cluster_lo = (ushort)(cluster & 0xFFFF);
	*new_size_field = size;
	if (!fs_write_sector(new_entry_sector, &new_sector_buf)) return -1;

	// Moving a directory to a genuinely different parent: fix up its
	// own ".." entry, same cluster-0-means-root convention fat32_mkdir
	// uses.
	if ((attr & FAT32_DIRENT_ATTR_DIRECTORY) != 0 && new_parent_cluster != old_parent_cluster)
	{
		uint dotdot_target = (new_parent_cluster == fat32_root_cluster) ? 0 : new_parent_cluster;
		char[SECTOR_SIZE] dir_buf @noinit;
		if (!fs_read_sector(fat32_cluster_to_sector(cluster), &dir_buf)) return -1;
		char* dotdot_entry = &dir_buf[FAT32_DIRENT_SIZE];
		ushort* dotdot_hi = (ushort*)&dotdot_entry[FAT32_DIRENT_CLUSTER_HI];
		ushort* dotdot_lo = (ushort*)&dotdot_entry[FAT32_DIRENT_CLUSTER_LO];
		*dotdot_hi = (ushort)(dotdot_target >> 16);
		*dotdot_lo = (ushort)(dotdot_target & 0xFFFF);
		if (!fs_write_sector(fat32_cluster_to_sector(cluster), &dir_buf)) return -1;
	}

	char[SECTOR_SIZE] old_sector_buf @noinit;
	if (!fs_read_sector(old_entry_sector, &old_sector_buf)) return -1;
	old_sector_buf[old_entry_offset] = FAT32_DIRENT_DELETED;
	if (!fs_write_sector(old_entry_sector, &old_sector_buf)) return -1;

	return 0;
}

fn void fat32_mount()
{
	char[SECTOR_SIZE] boot_sector @noinit;
	if (!fs_read_sector(0, &boot_sector))
	{
		fs_panic("failed to read boot sector");
	}

	// Signature already confirmed by fat32_probe() (fs_mount() only
	// calls this after that returned true) — not re-checked here.

	ushort* bytes_per_sector = (ushort*)&boot_sector[FAT32_BPB_BYTES_PER_SECTOR];
	if (*bytes_per_sector != SECTOR_SIZE)
	{
		// Every other part of this project assumes 512-byte sectors —
		// panic clearly rather than silently mishandle a nonstandard one.
		fs_panic("FAT32 volume doesn't use 512-byte sectors");
	}

	char   sectors_per_cluster = boot_sector[FAT32_BPB_SECTORS_PER_CLUSTER];
	ushort* reserved_sectors   = (ushort*)&boot_sector[FAT32_BPB_RESERVED_SECTORS];
	char   num_fats            = boot_sector[FAT32_BPB_NUM_FATS];
	uint*  fat_size_32         = (uint*)&boot_sector[FAT32_BPB_FAT_SIZE_32];
	uint*  root_cluster        = (uint*)&boot_sector[FAT32_BPB_ROOT_CLUSTER];
	uint*  total_sectors_32    = (uint*)&boot_sector[FAT32_BPB_TOTAL_SECTORS_32];

	// `& 0xFF` rather than a straight (uint) cast: char's signedness in
	// this dialect isn't relied on elsewhere in this codebase, and
	// masking gives the correct unsigned byte value either way — a
	// signed char holding the bit pattern for 255 would otherwise
	// sign-extend to 0xFFFFFFFF on a plain widening cast.
	fat32_sectors_per_cluster = (uint)sectors_per_cluster & 0xFF;
	fat32_fat_start_sector    = (uint)*reserved_sectors;
	fat32_num_fats            = (uint)num_fats & 0xFF;
	fat32_fat_size_32         = *fat_size_32;
	fat32_data_start_sector   = fat32_fat_start_sector + fat32_num_fats * fat32_fat_size_32;
	fat32_root_cluster        = *root_cluster;
	fat32_total_clusters      = (*total_sectors_32 - fat32_data_start_sector) / fat32_sectors_per_cluster;

	print("fsd: FAT32 mounted, partition_start=");
	print_uint(fs_partition_start);
	print(" root_cluster=");
	print_uint(fat32_root_cluster);
	print(" sectors_per_cluster=");
	print_uint(fat32_sectors_per_cluster);
	print("\n");
}
