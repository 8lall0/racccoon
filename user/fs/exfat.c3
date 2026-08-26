module user;

// exFAT backend for fsd (see user/fsd.c3's own header comment for the
// generic core / backend split). Standard, stable public spec (Microsoft
// exFAT File System Specification) — same "well-known layout" situation
// fat32.c3's own header comment describes, not reverse-engineered.
//
// Read-only in this pass: exfat_probe/exfat_mount/exfat_read/
// exfat_read_at/exfat_list only — no create/write/delete/mkdir/rename.
// fsd.c3's write-side dispatch (FS_WRITE/FS_DELETE/FS_MKDIR/FS_RENAME)
// already defaults to "unsupported" (result stays -1) for any fs_type it
// has no branch for, and fs_write_disabled defaults to true and is never
// flipped by exfat_mount() — see fsd.c3's own comment for that machinery.
// Matches the same incremental precedent FAT32 and ext2 both followed
// (see docs/devlog.md): read support first, write support (the riskier
// code — an allocator/directory-entry-set bug here could corrupt the very
// partition this boots from) as a deliberate, separate follow-up.
//
// exFAT's on-disk model is genuinely different from FAT32's, not just a
// renamed version of it:
//  - No 8.3/LFN split — every entry set stores its real name directly, as
//    UTF-16 (this file uses C3's own Char16/WString type family for that —
//    see exfat_ascii_to_utf16's own comment).
//  - A file/directory is a whole SET of 32-byte directory entries (one
//    primary "File Directory Entry" + one "Stream Extension" entry + as
//    many "File Name" entries as the name needs), not one self-contained
//    entry the way a FAT32 dirent (or even a FAT32 LFN chain) is.
//  - A file's data can be either a real FAT chain (like FAT32) OR fully
//    contiguous with no FAT chain at all (the Stream Extension entry's own
//    NoFatChain flag) — both are common on real volumes, and every place
//    this file walks a cluster chain has to handle both.
//  - Case-insensitive name matching is spec-defined via a per-volume
//    Up-case Table (a hidden system file), not a fixed ASCII-only fold —
//    see exfat_load_upcase_table's own comment for how much of it this
//    driver actually keeps resident.

// --- Main Boot Sector (sector 0) field offsets --------------------------
const uint EXFAT_BS_FS_NAME                   = 0x03; // 8 bytes, must be "EXFAT   "
const uint EXFAT_BS_FAT_OFFSET                = 0x50; // u32, sectors from volume start to the FAT
const uint EXFAT_BS_CLUSTER_HEAP_OFFSET       = 0x58; // u32, sectors from volume start to the cluster heap (data region)
const uint EXFAT_BS_ROOT_CLUSTER              = 0x60; // u32
const uint EXFAT_BS_BYTES_PER_SECTOR_SHIFT    = 0x6C; // u8 — sector size is 1 << shift here, not a raw value like FAT32's BPB
const uint EXFAT_BS_SECTORS_PER_CLUSTER_SHIFT = 0x6D; // u8 — same, cluster size in sectors is 1 << shift
const uint EXFAT_BS_SIGNATURE_OFFSET          = 0x1FE; // u16, must be 0xAA55, same offset/convention fat32.c3 uses

const uint EXFAT_FS_NAME_LEN = 8;
const char[8] EXFAT_FS_NAME = "EXFAT   ";

// --- Directory entry (32 bytes) type bytes and field offsets -----------
//
// EntryType's own top bit (0x80) is "in use" — a deleted entry just has
// that bit cleared, the rest of the slot untouched (unlike FAT32's
// separate 0xE5 marker byte), and its low 5 bits are a TypeCode shared
// between the in-use and deleted forms (0x85 in use / 0x05 deleted are
// both TypeCode 5, "File Directory Entry"). 0x00 (TypeCode 0, not in use)
// means "this slot and everything after it in the directory is unused" —
// same end-of-directory convention FAT32_DIRENT_FREE_REST uses.
const char EXFAT_ENTRY_TYPE_END    = (char)0x00;
const char EXFAT_ENTRY_TYPE_UPCASE = (char)0x82; // Up-case Table (root dir only) — standalone, not part of an entry set
const char EXFAT_ENTRY_TYPE_FILE   = (char)0x85; // File Directory Entry — primary entry of a file/directory's entry set

const uint EXFAT_ENTRY_INUSE_BIT     = 0x80;
const uint EXFAT_ENTRY_TYPECODE_MASK = 0x1F;
const uint EXFAT_TYPECODE_FILE       = 0x05; // (0x85 & 0x1F) == (0x05 & 0x1F) == 5 — in use or deleted, both a File Directory Entry

// File Directory Entry (primary, type 0x85/0x05) field offsets.
const uint EXFAT_FDE_SECONDARY_COUNT = 0x01; // u8 — number of Stream Extension + File Name entries following this one
const uint EXFAT_FDE_ATTRIBUTES      = 0x04; // u16
const uint EXFAT_ATTR_DIRECTORY      = 0x0010; // same bit FAT32_DIRENT_ATTR_DIRECTORY uses

// Stream Extension entry (secondary, type 0xC0, always the first entry
// right after a File Directory Entry) field offsets. ValidDataLength and
// DataLength are formally 8-byte fields on disk; only their low 4 bytes
// are ever read here (this whole project uses `uint`, 32-bit, sizes and
// offsets everywhere already — fs_read/fs_write's own `len` is `uint` —
// so a file bigger than 4GB is already out of scope regardless of this
// backend's own field width).
const uint EXFAT_STREAM_FLAGS         = 0x01; // u8 — GeneralSecondaryFlags
const uint EXFAT_STREAM_NAME_LENGTH   = 0x03; // u8 — name length in UTF-16 code units
const uint EXFAT_STREAM_FIRST_CLUSTER = 0x14; // u32
const uint EXFAT_STREAM_DATA_LENGTH   = 0x18; // u64 on disk, low 4 bytes read

const uint EXFAT_STREAM_FLAG_NO_FAT_CHAIN = 0x02; // bit 1 — data is fully contiguous, don't walk the FAT at all

// File Name entry (secondary, type 0xC1) field offsets.
const uint EXFAT_NAME_CHARS           = 0x02; // 15 UTF-16 code units (30 bytes)
const uint EXFAT_NAME_CHARS_PER_ENTRY = 15;

// Up-case Table entry (primary, type 0x82, root dir only) field offsets.
const uint EXFAT_UPCASE_FIRST_CLUSTER = 0x14; // u32
const uint EXFAT_UPCASE_DATA_LENGTH   = 0x18; // u64 on disk, low 4 bytes read

const uint EXFAT_DIRENT_SIZE = 32;

// exFAT FAT entries are full, un-masked 32-bit values (cluster indices
// never approach this range) — unlike FAT32_ENTRY_MASK's 28-bit scheme,
// no masking is needed here. 0xFFFFFFF7..0xFFFFFFFF are reserved/bad/EOC.
const uint EXFAT_EOC_MIN = 0xFFFFFFF7;

// Same cap FAT32_LFN_NAME_MAX uses, same reasoning: comfortably past any
// realistic real-world filename, keeps every name buffer here small and
// fixed-size rather than sized for the spec's own 255-UTF-16-unit
// theoretical maximum.
const int EXFAT_NAME_MAX = 128;

// --- Derived layout, cached at mount time (see exfat_mount) ------------
uint exfat_fat_start_sector;    // FatOffset field, partition-relative sectors
uint exfat_cluster_heap_offset; // ClusterHeapOffset field, partition-relative sectors
uint exfat_sectors_per_cluster; // 1 << SectorsPerClusterShift
uint exfat_root_cluster;

// Up-case Table cache — see exfat_load_upcase_table's own comment for why
// only codepoints < EXFAT_UPCASE_CACHE_SIZE are actually retained.
const int EXFAT_UPCASE_CACHE_SIZE = 256;
Char16[256] exfat_upcase_low;

fn bool exfat_probe()
{
	char[SECTOR_SIZE] boot_sector @noinit;
	if (!fs_read_sector(0, &boot_sector)) return false;
	for (uint i = 0; i < EXFAT_FS_NAME_LEN; i++)
	{
		if (boot_sector[EXFAT_BS_FS_NAME + i] != EXFAT_FS_NAME[i]) return false;
	}
	ushort* sig = (ushort*)&boot_sector[EXFAT_BS_SIGNATURE_OFFSET];
	return *sig == 0xAA55;
}

fn uint exfat_cluster_to_sector(uint cluster)
{
	return exfat_cluster_heap_offset + (cluster - 2) * exfat_sectors_per_cluster;
}

// Reads one 4-byte little-endian FAT entry — the next cluster in the
// chain, or a value >= EXFAT_EOC_MIN at the end. A read failure is
// treated as end-of-chain rather than propagated, same best-effort-reader
// precedent fat32_next_cluster's own comment documents.
fn uint exfat_next_cluster(uint cluster)
{
	uint fat_byte_offset = cluster * 4;
	uint fat_sector = exfat_fat_start_sector + (fat_byte_offset / SECTOR_SIZE);
	uint entry_offset = fat_byte_offset % SECTOR_SIZE;

	char[SECTOR_SIZE] sector_buf @noinit;
	if (!fs_read_sector(fat_sector, &sector_buf)) return EXFAT_EOC_MIN;

	uint* entry = (uint*)&sector_buf[entry_offset];
	return *entry;
}

// Widens a plain, null-terminated ASCII path segment (every filename this
// backend is ever actually asked to resolve — the shell/user.c3 wire
// format is plain `char*` throughout this project, see fsd.c3's own
// filename field) into raw UTF-16 code units, one-to-one — no real
// transcoding needed since the input is already ASCII. Case folding
// happens later, per-character, via exfat_upcase() at comparison time,
// not here.
fn int exfat_ascii_to_utf16(char* ascii, Char16* out, int max)
{
	int i = 0;
	while (ascii[i] != 0 && i < max)
	{
		out[i] = (Char16)((uint)ascii[i] & 0xFF);
		i++;
	}
	return i;
}

// Case-folds one UTF-16 code unit via the volume's real Up-case Table
// (exfat_upcase_low) — codepoints outside the cached range self-map,
// exactly what the on-disk table itself would say for any codepoint that
// was never given an explicit, non-identity mapping (see
// exfat_load_upcase_table's own comment).
fn Char16 exfat_upcase(Char16 c)
{
	if ((uint)c < (uint)EXFAT_UPCASE_CACHE_SIZE) return exfat_upcase_low[c];
	return c;
}

fn bool exfat_name_eq_ci(Char16* a, int a_len, Char16* b, int b_len)
{
	if (a_len != b_len) return false;
	for (int i = 0; i < a_len; i++)
	{
		if (exfat_upcase(a[i]) != exfat_upcase(b[i])) return false;
	}
	return true;
}

// --- Directory entry cursor ---------------------------------------------
//
// A cursor over one directory's cluster chain, one 32-byte entry at a
// time, hiding the cluster/sector/slot nesting fat32.c3's own directory
// loops repeat inline for each caller. exFAT's entry-set model (several
// slots making up one logical file, with the Stream Extension entry's own
// NoFatChain flag deciding how the *next* cluster in the chain is even
// found) needs to look at slots one at a time, across that nesting, more
// often than FAT32 ever did (LFN accumulation was FAT32's only case) — so
// this is pulled out once here rather than repeated in
// exfat_find_in_dir/exfat_list/exfat_load_upcase_table.
struct Exfat_dir_cursor
{
	uint cluster;
	bool no_fat_chain;
	uint sector_in_cluster;
	uint entry_in_sector;
	char[SECTOR_SIZE] sector_buf;
	bool sector_loaded;
}

fn void exfat_cursor_init(Exfat_dir_cursor* cur, uint dir_cluster, bool no_fat_chain)
{
	cur.cluster = dir_cluster;
	cur.no_fat_chain = no_fat_chain;
	cur.sector_in_cluster = 0;
	cur.entry_in_sector = 0;
	cur.sector_loaded = false;
}

// Returns a pointer to the next 32-byte entry (valid only until the next
// call to this function — same "process it before advancing" discipline
// every caller here already follows), or null at end-of-chain / on a read
// error.
fn char* exfat_cursor_next(Exfat_dir_cursor* cur)
{
	if (cur.cluster == 0 || cur.cluster >= EXFAT_EOC_MIN) return null;

	if (!cur.sector_loaded)
	{
		uint sector = exfat_cluster_to_sector(cur.cluster) + cur.sector_in_cluster;
		if (!fs_read_sector(sector, &cur.sector_buf)) return null;
		cur.sector_loaded = true;
	}

	char* entry = &cur.sector_buf[cur.entry_in_sector * EXFAT_DIRENT_SIZE];

	cur.entry_in_sector++;
	if (cur.entry_in_sector >= SECTOR_SIZE / EXFAT_DIRENT_SIZE)
	{
		cur.entry_in_sector = 0;
		cur.sector_loaded = false;
		cur.sector_in_cluster++;
		if (cur.sector_in_cluster >= exfat_sectors_per_cluster)
		{
			cur.sector_in_cluster = 0;
			cur.cluster = cur.no_fat_chain ? cur.cluster + 1 : exfat_next_cluster(cur.cluster);
		}
	}
	return entry;
}

// Reads one complete directory entry set, starting at the cursor position
// right after `fde_entry` (a File Directory Entry slot the caller has
// already fetched and type-checked). Consumes exactly `fde_entry`'s own
// SecondaryCount further slots from the cursor regardless of whether the
// set turns out in-use — a deleted entry set's slots still have to be
// consumed to keep the cursor aligned with the next real entry, same
// reasoning fat32_list's own deleted-marker handling documents, just
// spanning multiple slots here instead of one.
//
// Returns false (fde_entry wasn't in use, or the cursor ran out mid-set —
// a truncated/corrupt directory) without touching any out-parameter other
// than having already advanced the cursor; true with every out-parameter
// filled in. Doesn't compute/check NameHash — a real optimization exFAT
// readers use, but exact post-fold name comparison is already correct
// without it (see exfat_find_in_dir), and this is a narrower first pass.
fn bool exfat_read_entry_set(Exfat_dir_cursor* cur, char* fde_entry, ushort* out_attr, uint* out_first_cluster, uint* out_data_length, bool* out_no_fat_chain, Char16* out_name, int* out_name_len)
{
	bool in_use = ((uint)fde_entry[0] & EXFAT_ENTRY_INUSE_BIT) != 0;
	int secondary_remaining = (int)((uint)fde_entry[EXFAT_FDE_SECONDARY_COUNT] & 0xFF);
	ushort* attr_field = (ushort*)&fde_entry[EXFAT_FDE_ATTRIBUTES];
	ushort attr = *attr_field;

	bool stream_seen = false;
	bool no_fat_chain = false;
	uint first_cluster = 0;
	uint data_length = 0;
	int name_len = 0;

	for (int i = 0; i < secondary_remaining; i++)
	{
		char* entry = exfat_cursor_next(cur);
		if (entry == null) return false; // truncated directory

		if (!stream_seen)
		{
			no_fat_chain = ((uint)entry[EXFAT_STREAM_FLAGS] & EXFAT_STREAM_FLAG_NO_FAT_CHAIN) != 0;
			name_len = (int)((uint)entry[EXFAT_STREAM_NAME_LENGTH] & 0xFF);
			uint* cluster_field = (uint*)&entry[EXFAT_STREAM_FIRST_CLUSTER];
			uint* length_field  = (uint*)&entry[EXFAT_STREAM_DATA_LENGTH];
			first_cluster = *cluster_field;
			data_length   = *length_field;
			stream_seen = true;
		}
		else
		{
			int base = (i - 1) * EXFAT_NAME_CHARS_PER_ENTRY;
			for (int k = 0; k < EXFAT_NAME_CHARS_PER_ENTRY; k++)
			{
				int pos = base + k;
				if (pos >= name_len || pos >= EXFAT_NAME_MAX) break;
				Char16* ch = (Char16*)&entry[EXFAT_NAME_CHARS + k * 2];
				out_name[pos] = *ch;
			}
		}
	}

	*out_attr = attr;
	*out_first_cluster = first_cluster;
	*out_data_length = data_length;
	*out_no_fat_chain = no_fat_chain;
	*out_name_len = name_len;
	return in_use && stream_seen;
}

// Walks dir_cluster's entry sets looking for a name match (post-upcase-
// fold, see exfat_name_eq_ci). dir_no_fat_chain describes dir_cluster's
// OWN chain (root is always false — see this file's header comment — a
// subdirectory's is whatever its own Stream Extension entry said, thread-
// ed in by the caller).
fn bool exfat_find_in_dir(uint dir_cluster, bool dir_no_fat_chain, Char16* name_utf16, int name_len, uint* out_first_cluster, uint* out_data_length, ushort* out_attr, bool* out_no_fat_chain)
{
	Exfat_dir_cursor cur @noinit;
	exfat_cursor_init(&cur, dir_cluster, dir_no_fat_chain);

	Char16[EXFAT_NAME_MAX] candidate @noinit;

	for (;;)
	{
		char* entry = exfat_cursor_next(&cur);
		if (entry == null) return false; // end of chain
		if (entry[0] == EXFAT_ENTRY_TYPE_END) return false; // end of directory

		uint type_byte = (uint)entry[0] & 0xFF;
		if ((type_byte & EXFAT_ENTRY_TYPECODE_MASK) != EXFAT_TYPECODE_FILE) continue; // bitmap/upcase/label/unknown — one standalone slot, skip

		uint first_cluster; uint data_length; ushort attr; bool no_fat_chain; int candidate_len;
		bool valid = exfat_read_entry_set(&cur, entry, &attr, &first_cluster, &data_length, &no_fat_chain, &candidate, &candidate_len);
		if (!valid) continue;

		if (exfat_name_eq_ci(name_utf16, name_len, &candidate, candidate_len))
		{
			*out_first_cluster = first_cluster;
			*out_data_length = data_length;
			*out_attr = attr;
			*out_no_fat_chain = no_fat_chain;
			return true;
		}
	}
}

// Same segment-by-segment walk as fat32_resolve_dir, but also threads the
// NoFatChain flag through: unlike FAT32, an exFAT subdirectory's own
// chain can be contiguous too (its Stream Extension entry carries the
// same flag a regular file's does), so every directory-cluster reference
// past the root has to travel with its own no_fat_chain bit, not just a
// bare cluster number.
fn bool exfat_resolve_dir(char* path, uint* out_dir_cluster, bool* out_no_fat_chain)
{
	uint dir_cluster = exfat_root_cluster;
	bool no_fat_chain = false; // root directory's chain is always FAT-walked — it has no Stream Extension entry of its own, see this file's header comment
	uint seg_start = 0;
	uint i = 0;
	for (;;)
	{
		if (path[i] != '/' && path[i] != 0) { i++; continue; }

		uint seg_len = i - seg_start;
		if (seg_len > 0 && path[i] == '/')
		{
			char[64] seg_buf @noinit;
			uint copy_len = seg_len < 63 ? seg_len : 63;
			for (uint k = 0; k < copy_len; k++) seg_buf[k] = path[seg_start + k];
			seg_buf[copy_len] = 0;

			Char16[EXFAT_NAME_MAX] seg_utf16 @noinit;
			int seg_len16 = exfat_ascii_to_utf16(&seg_buf, &seg_utf16, EXFAT_NAME_MAX);

			uint next_cluster; uint dummy_len; ushort attr; bool next_no_fat_chain;
			if (!exfat_find_in_dir(dir_cluster, no_fat_chain, &seg_utf16, seg_len16, &next_cluster, &dummy_len, &attr, &next_no_fat_chain)) return false;
			if (((uint)attr & EXFAT_ATTR_DIRECTORY) == 0) return false;
			dir_cluster = next_cluster;
			no_fat_chain = next_no_fat_chain;
		}

		if (path[i] == 0) break;
		seg_start = i + 1;
		i++;
	}
	*out_dir_cluster = dir_cluster;
	*out_no_fat_chain = no_fat_chain;
	return true;
}

// The final path component (after the last '/', or the whole string if
// there's none) — a pointer into `path` itself, no copy. Identical to
// fat32_leaf_name.
fn char* exfat_leaf_name(char* path)
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

// Follows first_cluster's chain (contiguous or FAT-linked, per
// no_fat_chain), copying up to `len` bytes from the start of the data
// into dst. Same shape as fat32_read_file, generalized with the one flag
// exFAT needs and FAT32 never did.
fn uint exfat_read_chain(uint first_cluster, bool no_fat_chain, char* dst, uint len)
{
	uint cluster = first_cluster;
	uint bytes_read = 0;
	char[SECTOR_SIZE] sector_buf @noinit;

	while (cluster != 0 && cluster < EXFAT_EOC_MIN && bytes_read < len)
	{
		uint sector = exfat_cluster_to_sector(cluster);
		for (uint s = 0; s < exfat_sectors_per_cluster && bytes_read < len; s++)
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
		cluster = no_fat_chain ? cluster + 1 : exfat_next_cluster(cluster);
	}
	return bytes_read;
}

// Entry point dispatched from fsd.c3 for FS_READ.
fn int exfat_read(char* name, char* dst, uint len)
{
	uint dir_cluster; bool dir_no_fat_chain;
	if (!exfat_resolve_dir(name, &dir_cluster, &dir_no_fat_chain)) return -1;
	char* leaf = exfat_leaf_name(name);

	Char16[EXFAT_NAME_MAX] leaf_utf16 @noinit;
	int leaf_len16 = exfat_ascii_to_utf16(leaf, &leaf_utf16, EXFAT_NAME_MAX);

	uint first_cluster; uint data_length; ushort attr; bool no_fat_chain;
	if (!exfat_find_in_dir(dir_cluster, dir_no_fat_chain, &leaf_utf16, leaf_len16, &first_cluster, &data_length, &attr, &no_fat_chain)) return -1;
	if (((uint)attr & EXFAT_ATTR_DIRECTORY) != 0) return -1; // a directory isn't file content

	uint read_len = len;
	if (read_len > data_length) read_len = data_length;

	return (int)exfat_read_chain(first_cluster, no_fat_chain, dst, read_len);
}

// Same chain-walk as exfat_read_chain, but starts copying from `offset`
// bytes into the data. No resume cache the way fat32_read_file_at grew
// one (fat32_cache_resume_offset/cluster) — a deliberately narrower first
// pass (see this file's header comment): exec()'s chunked reads still
// work correctly here, just without that O(1)-per-call optimization, and
// a contiguous (no_fat_chain) file doesn't need one anyway — its target
// cluster is a direct jump, not a walk, regardless.
fn uint exfat_read_chain_at(uint first_cluster, bool no_fat_chain, char* dst, uint len, uint offset)
{
	uint cluster_size = exfat_sectors_per_cluster * SECTOR_SIZE;

	uint cluster;
	uint cluster_start_offset;
	if (no_fat_chain)
	{
		uint cluster_index = offset / cluster_size;
		cluster = first_cluster + cluster_index;
		cluster_start_offset = cluster_index * cluster_size;
	}
	else
	{
		cluster = first_cluster;
		cluster_start_offset = 0;
		while (cluster_start_offset + cluster_size <= offset && cluster != 0 && cluster < EXFAT_EOC_MIN)
		{
			cluster = exfat_next_cluster(cluster);
			cluster_start_offset += cluster_size;
		}
	}

	uint offset_in_cluster = offset - cluster_start_offset;
	uint sectors_to_skip = offset_in_cluster / SECTOR_SIZE;
	uint skip_in_sector = offset_in_cluster % SECTOR_SIZE;

	uint bytes_read = 0;
	char[SECTOR_SIZE] sector_buf @noinit;
	bool at_start = true;

	while (cluster != 0 && cluster < EXFAT_EOC_MIN && bytes_read < len)
	{
		uint sector = exfat_cluster_to_sector(cluster);
		uint start_s = at_start ? sectors_to_skip : 0;
		for (uint s = start_s; s < exfat_sectors_per_cluster && bytes_read < len; s++)
		{
			if (!fs_read_sector(sector + s, &sector_buf)) return bytes_read;

			uint sk = at_start ? skip_in_sector : 0;
			uint available = SECTOR_SIZE - sk;
			uint chunk = len - bytes_read;
			if (chunk > available) chunk = available;
			for (uint i = 0; i < chunk; i++)
			{
				dst[bytes_read + i] = sector_buf[sk + i];
			}
			bytes_read += chunk;
			at_start = false;
		}
		if (bytes_read >= len) break;
		cluster = no_fat_chain ? cluster + 1 : exfat_next_cluster(cluster);
	}
	return bytes_read;
}

// Entry point dispatched from fsd.c3 for FS_READ_AT — same lookup shape
// as exfat_read above, returns 0 (clean EOF, not -1) once `offset` reaches
// or passes the file's own size, same distinction fat32_read_at's own
// comment documents.
fn int exfat_read_at(char* name, char* dst, uint len, uint offset)
{
	uint dir_cluster; bool dir_no_fat_chain;
	if (!exfat_resolve_dir(name, &dir_cluster, &dir_no_fat_chain)) return -1;
	char* leaf = exfat_leaf_name(name);

	Char16[EXFAT_NAME_MAX] leaf_utf16 @noinit;
	int leaf_len16 = exfat_ascii_to_utf16(leaf, &leaf_utf16, EXFAT_NAME_MAX);

	uint first_cluster; uint data_length; ushort attr; bool no_fat_chain;
	if (!exfat_find_in_dir(dir_cluster, dir_no_fat_chain, &leaf_utf16, leaf_len16, &first_cluster, &data_length, &attr, &no_fat_chain)) return -1;
	if (((uint)attr & EXFAT_ATTR_DIRECTORY) != 0) return -1;

	if (offset >= data_length) return 0;

	uint remaining = data_length - offset;
	uint read_len = len;
	if (read_len > remaining) read_len = remaining;

	return (int)exfat_read_chain_at(first_cluster, no_fat_chain, dst, read_len, offset);
}

// Entry point dispatched from fsd.c3 for FS_LIST. Same shape as
// fat32_list, minus the "." / ".." skip — exFAT has no pseudo-entries for
// self/parent at all (there's simply nothing to point back at a parent
// directory in this format), so there's nothing to filter out here.
fn bool exfat_list(char* path, char* out_buf, int max_entries, int* out_count)
{
	uint dir_cluster; bool dir_no_fat_chain;
	if (path[0] == 0)
	{
		dir_cluster = exfat_root_cluster;
		dir_no_fat_chain = false;
	}
	else
	{
		uint parent_cluster; bool parent_no_fat_chain;
		if (!exfat_resolve_dir(path, &parent_cluster, &parent_no_fat_chain)) return false;
		char* leaf = exfat_leaf_name(path);
		Char16[EXFAT_NAME_MAX] leaf_utf16 @noinit;
		int leaf_len16 = exfat_ascii_to_utf16(leaf, &leaf_utf16, EXFAT_NAME_MAX);

		uint cluster; uint dummy_len; ushort attr; bool no_fat_chain;
		if (!exfat_find_in_dir(parent_cluster, parent_no_fat_chain, &leaf_utf16, leaf_len16, &cluster, &dummy_len, &attr, &no_fat_chain)) return false;
		if (((uint)attr & EXFAT_ATTR_DIRECTORY) == 0) return false;
		dir_cluster = cluster;
		dir_no_fat_chain = no_fat_chain;
	}

	Exfat_dir_cursor cur @noinit;
	exfat_cursor_init(&cur, dir_cluster, dir_no_fat_chain);

	int count = 0;
	Char16[EXFAT_NAME_MAX] name_buf @noinit;

	while (count < max_entries)
	{
		char* entry = exfat_cursor_next(&cur);
		if (entry == null) break; // end of chain
		if (entry[0] == EXFAT_ENTRY_TYPE_END) break; // end of directory

		uint type_byte = (uint)entry[0] & 0xFF;
		if ((type_byte & EXFAT_ENTRY_TYPECODE_MASK) != EXFAT_TYPECODE_FILE) continue;

		uint first_cluster; uint data_length; ushort attr; bool no_fat_chain; int name_len;
		bool valid = exfat_read_entry_set(&cur, entry, &attr, &first_cluster, &data_length, &no_fat_chain, &name_buf, &name_len);
		if (!valid) continue;

		// Truncated to FS_LIST_NAME_MAX-1 for display, same precedent
		// fat32_list's own LFN handling uses (user.c3's own comment).
		// Non-ASCII code units are shown as '?' in this capped display
		// buffer only — exfat_read/exfat_read_at never round-trip through
		// it, they resolve names from the caller's own path directly.
		char* rec = &out_buf[(uint)count * FS_LIST_ENTRY_SIZE];
		int ni = 0;
		while (ni < (int)FS_LIST_NAME_MAX - 1 && ni < name_len)
		{
			Char16 c = name_buf[ni];
			rec[ni] = ((uint)c < 0x80) ? (char)c : '?';
			ni++;
		}
		rec[ni] = 0;
		rec[FS_LIST_NAME_MAX] = (((uint)attr & EXFAT_ATTR_DIRECTORY) != 0) ? (char)1 : (char)0;
		count++;
	}
	*out_count = count;
	return true;
}

// Locates the volume's Up-case Table (root-directory entry type 0x82) and
// decompresses just enough of it to case-fold ASCII/Latin-1 names — real
// parsing of the real on-disk table, not a hardcoded fold, per its own
// format: a stream of Char16 values where 0xFFFF is an escape (the next
// value is a run length N, meaning the next N implied codepoints map to
// themselves) and any other value is the real mapping for the current
// implied codepoint, which then advances by 1.
//
// Every codepoint this project's own filenames (disk/, disk-ext2/) or
// this driver's shell paths will ever use is ASCII, and the format itself
// already treats an unmapped codepoint as self-mapping — so rather than
// materializing all 65536 possible entries (128KB, wildly out of scale
// with every other fixed buffer in this codebase — fat32.c3's biggest is
// FAT32_LFN_NAME_MAX at 128 code units), this only *records* mappings for
// implied codepoints < EXFAT_UPCASE_CACHE_SIZE (256 — ASCII + Latin-1) and
// stops decompressing once the stream passes that point, which in
// practice is early: the default Windows-shipped table maps most of the
// Latin range within its first few dozen bytes. A codepoint beyond that
// range is treated as self-mapping, exactly what the real table would say
// for the overwhelming majority of such codepoints anyway (this is a
// disclosed scope line, not a silent shortcut — see docs/devlog.md).
fn void exfat_load_upcase_table()
{
	for (int i = 0; i < EXFAT_UPCASE_CACHE_SIZE; i++) exfat_upcase_low[i] = (Char16)i;

	Exfat_dir_cursor cur @noinit;
	exfat_cursor_init(&cur, exfat_root_cluster, false); // root dir is always FAT-walked, never contiguous-only

	uint upcase_cluster = 0;
	uint upcase_length = 0;
	for (;;)
	{
		char* entry = exfat_cursor_next(&cur);
		if (entry == null) break;
		if (entry[0] == EXFAT_ENTRY_TYPE_END) break;
		if (entry[0] == EXFAT_ENTRY_TYPE_UPCASE)
		{
			uint* cluster_field = (uint*)&entry[EXFAT_UPCASE_FIRST_CLUSTER];
			uint* length_field  = (uint*)&entry[EXFAT_UPCASE_DATA_LENGTH];
			upcase_cluster = *cluster_field;
			upcase_length  = *length_field;
			break;
		}

		// A File Directory Entry set has to be skipped whole (its own
		// secondary entries would otherwise be misread as unrelated
		// top-level slots) — same reasoning exfat_find_in_dir/exfat_list
		// apply via exfat_read_entry_set, done inline here since this
		// scan only cares about finding one specific standalone entry,
		// not about decoding any file's own name/size.
		uint type_byte = (uint)entry[0] & 0xFF;
		if ((type_byte & EXFAT_ENTRY_TYPECODE_MASK) == EXFAT_TYPECODE_FILE)
		{
			int secondary_count = (int)((uint)entry[EXFAT_FDE_SECONDARY_COUNT] & 0xFF);
			for (int i = 0; i < secondary_count; i++)
			{
				if (exfat_cursor_next(&cur) == null) break;
			}
		}
	}

	if (upcase_cluster == 0)
	{
		print("fsd: exFAT volume has no Up-case Table -- case folding stays identity-only\n");
		return;
	}

	char[SECTOR_SIZE] sector_buf @noinit;
	uint codepoint = 0;
	uint bytes_read = 0;
	uint cluster = upcase_cluster;
	bool pending_run = false;

	while (cluster != 0 && cluster < EXFAT_EOC_MIN && bytes_read < upcase_length && codepoint < (uint)EXFAT_UPCASE_CACHE_SIZE)
	{
		uint sector = exfat_cluster_to_sector(cluster);
		for (uint s = 0; s < exfat_sectors_per_cluster && bytes_read < upcase_length && codepoint < (uint)EXFAT_UPCASE_CACHE_SIZE; s++)
		{
			if (!fs_read_sector(sector + s, &sector_buf)) { cluster = 0; break; }
			for (uint e = 0; e < SECTOR_SIZE && bytes_read < upcase_length && codepoint < (uint)EXFAT_UPCASE_CACHE_SIZE; e += 2)
			{
				Char16* val_ptr = (Char16*)&sector_buf[e];
				Char16 val = *val_ptr;
				bytes_read += 2;

				if (pending_run)
				{
					codepoint += (uint)val;
					pending_run = false;
					continue;
				}
				if (val == (Char16)0xFFFF)
				{
					pending_run = true;
					continue;
				}
				if (codepoint < (uint)EXFAT_UPCASE_CACHE_SIZE) exfat_upcase_low[codepoint] = val;
				codepoint += 1;
			}
		}
		if (cluster == 0) break;
		cluster = exfat_next_cluster(cluster);
	}
}

fn void exfat_mount()
{
	char[SECTOR_SIZE] boot_sector @noinit;
	if (!fs_read_sector(0, &boot_sector))
	{
		fs_panic("failed to read boot sector");
	}

	// Signature already confirmed by exfat_probe() (fs_mount() only calls
	// this after that returned true) — not re-checked here, same
	// precedent fat32_mount() follows.
	uint sector_shift = (uint)boot_sector[EXFAT_BS_BYTES_PER_SECTOR_SHIFT] & 0xFF;
	if (sector_shift != 9)
	{
		// Every other part of this project assumes 512-byte sectors —
		// panic clearly rather than silently mishandle a nonstandard one,
		// same precedent fat32_mount()'s own check follows.
		fs_panic("exFAT volume doesn't use 512-byte sectors");
	}

	uint cluster_shift = (uint)boot_sector[EXFAT_BS_SECTORS_PER_CLUSTER_SHIFT] & 0xFF;
	uint* fat_offset_field   = (uint*)&boot_sector[EXFAT_BS_FAT_OFFSET];
	uint* heap_offset_field  = (uint*)&boot_sector[EXFAT_BS_CLUSTER_HEAP_OFFSET];
	uint* root_cluster_field = (uint*)&boot_sector[EXFAT_BS_ROOT_CLUSTER];

	exfat_sectors_per_cluster = (uint)1 << cluster_shift;
	exfat_fat_start_sector    = *fat_offset_field;
	exfat_cluster_heap_offset = *heap_offset_field;
	exfat_root_cluster        = *root_cluster_field;

	exfat_load_upcase_table();

	print("fsd: exFAT mounted, partition_start=");
	print_uint(fs_partition_start);
	print(" root_cluster=");
	print_uint(exfat_root_cluster);
	print(" sectors_per_cluster=");
	print_uint(exfat_sectors_per_cluster);
	print("\n");
}
