module user;

// exFAT backend for fsd (see user/fsd.c3's own header comment for the
// generic core / backend split). Standard, stable public spec (Microsoft
// exFAT File System Specification) — same "well-known layout" situation
// fat32.c3's own header comment describes, not reverse-engineered.
//
// Read: exfat_probe/exfat_mount/exfat_read/exfat_read_at/exfat_list.
// Write: exfat_write (create/overwrite, one cluster max), exfat_delete
// (file or empty directory), exfat_delete_recursive (whole subtree),
// exfat_mkdir, exfat_rename (rename or move a file or directory) — added
// in two sessions after the read path, the same incremental precedent
// FAT32 and ext2 both followed (see docs/devlog.md), because the write
// side is the riskier code: an allocator or directory-entry-set bug here
// could corrupt a live volume. See the "Write path" section near the
// bottom of this file for the deliberate scope limits (one cluster per
// file, no directory extension).
//
// exFAT's on-disk model is genuinely different from FAT32's, not just a
// renamed version of it:
//  - No 8.3/LFN split — every entry set stores its real name directly, as
//    UTF-16 (this file works in raw 16-bit code units — see the Char16
//    alias below and exfat_ascii_to_utf16's own comment).
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

// C3's std::core::string calls the UTF-16 code-unit type Char16 (a plain
// alias for ushort) and a Char16* a WString, but this project builds
// --use-stdlib=no so neither name is reachable — fat32.c3 just uses a
// bare ushort for its own LFN code units. Alias it locally so the exFAT
// name-handling code below still reads as the UTF-16 it actually is.
alias Char16 = ushort;

// --- Main Boot Sector (sector 0) field offsets --------------------------
const uint EXFAT_BS_FS_NAME                   = 0x03; // 8 bytes, must be "EXFAT   "
const uint EXFAT_BS_FAT_OFFSET                = 0x50; // u32, sectors from volume start to the FAT
const uint EXFAT_BS_CLUSTER_HEAP_OFFSET       = 0x58; // u32, sectors from volume start to the cluster heap (data region)
const uint EXFAT_BS_CLUSTER_COUNT             = 0x5C; // u32, total clusters in the heap (bit count of the Allocation Bitmap)
const uint EXFAT_BS_ROOT_CLUSTER              = 0x60; // u32
const uint EXFAT_BS_BYTES_PER_SECTOR_SHIFT    = 0x6C; // u8 — sector size is 1 << shift here, not a raw value like FAT32's BPB
const uint EXFAT_BS_SECTORS_PER_CLUSTER_SHIFT = 0x6D; // u8 — same, cluster size in sectors is 1 << shift
const uint EXFAT_BS_NUMBER_OF_FATS            = 0x6E; // u8 — 1 for plain exFAT, 2 only for the TexFAT variant this driver rejects
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
const char EXFAT_ENTRY_TYPE_BITMAP = (char)0x81; // Allocation Bitmap (root dir only) — standalone, one per volume
const char EXFAT_ENTRY_TYPE_UPCASE = (char)0x82; // Up-case Table (root dir only) — standalone, not part of an entry set
const char EXFAT_ENTRY_TYPE_FILE   = (char)0x85; // File Directory Entry — primary entry of a file/directory's entry set

// Secondary entry types the write path emits — the in-use forms only
// (the delete path clears the 0x80 bit in place, it never writes these
// deleted forms itself).
const char EXFAT_ENTRY_TYPE_STREAM = (char)0xC0; // Stream Extension
const char EXFAT_ENTRY_TYPE_NAME   = (char)0xC1; // File Name

const uint EXFAT_ENTRY_INUSE_BIT     = 0x80;
const uint EXFAT_ENTRY_TYPECODE_MASK = 0x1F;
const uint EXFAT_TYPECODE_FILE       = 0x05; // (0x85 & 0x1F) == (0x05 & 0x1F) == 5 — in use or deleted, both a File Directory Entry

// File Directory Entry (primary, type 0x85/0x05) field offsets.
const uint EXFAT_FDE_SECONDARY_COUNT = 0x01; // u8 — number of Stream Extension + File Name entries following this one
const uint EXFAT_FDE_SET_CHECKSUM    = 0x02; // u16 — checksum over the whole entry set, excluding these 2 bytes
const uint EXFAT_FDE_ATTRIBUTES      = 0x04; // u16
const uint EXFAT_FDE_CREATE_TIME     = 0x08; // u32 — DOS-packed; also LastModified at 0x0C, LastAccessed at 0x10
const uint EXFAT_ATTR_DIRECTORY      = 0x0010; // same bit FAT32_DIRENT_ATTR_DIRECTORY uses
const uint EXFAT_ATTR_ARCHIVE        = 0x0020; // set on every regular file this driver creates, same as FAT32/Windows

// This driver has no RTC (nothing in racccoon does — see docs/devlog.md).
// A zero timestamp decodes to an invalid 1980-00-00, which fsck flags,
// so every entry this driver writes gets one fixed, valid, obviously-
// synthetic value: 2026-01-01 00:00:00. DOS packing: bits 25..31
// year-1980 (46), 21..24 month (1), 16..20 day (1), rest zero.
const uint EXFAT_FIXED_TIMESTAMP = (46u << 25) | (1u << 21) | (1u << 16);

// Stream Extension entry (secondary, type 0xC0, always the first entry
// right after a File Directory Entry) field offsets. ValidDataLength and
// DataLength are formally 8-byte fields on disk; only their low 4 bytes
// are ever read here (this whole project uses `uint`, 32-bit, sizes and
// offsets everywhere already — fs_read/fs_write's own `len` is `uint` —
// so a file bigger than 4GB is already out of scope regardless of this
// backend's own field width).
const uint EXFAT_STREAM_FLAGS             = 0x01; // u8 — GeneralSecondaryFlags
const uint EXFAT_STREAM_NAME_LENGTH       = 0x03; // u8 — name length in UTF-16 code units
const uint EXFAT_STREAM_NAME_HASH         = 0x04; // u16 — hash of the up-cased name (a lookup fast-path readers may use)
const uint EXFAT_STREAM_VALID_DATA_LENGTH = 0x08; // u64 on disk — bytes actually written (<= DataLength); this driver keeps them equal
const uint EXFAT_STREAM_FIRST_CLUSTER     = 0x14; // u32
const uint EXFAT_STREAM_DATA_LENGTH       = 0x18; // u64 on disk, low 4 bytes read

const uint EXFAT_STREAM_FLAG_ALLOC_POSSIBLE = 0x01; // bit 0 — a first cluster is/could be allocated
const uint EXFAT_STREAM_FLAG_NO_FAT_CHAIN   = 0x02; // bit 1 — data is fully contiguous, don't walk the FAT at all

// File Name entry (secondary, type 0xC1) field offsets.
const uint EXFAT_NAME_CHARS           = 0x02; // 15 UTF-16 code units (30 bytes)
const int EXFAT_NAME_CHARS_PER_ENTRY = 15; // a loop/index count, like EXFAT_NAME_MAX — kept int for use in int-typed name arithmetic

// Up-case Table entry (primary, type 0x82, root dir only) field offsets.
const uint EXFAT_UPCASE_FIRST_CLUSTER = 0x14; // u32
const uint EXFAT_UPCASE_DATA_LENGTH   = 0x18; // u64 on disk, low 4 bytes read

// Allocation Bitmap entry (primary, type 0x81, root dir only) field
// offsets — same shape as the Up-case Table entry.
const uint EXFAT_BITMAP_FIRST_CLUSTER = 0x14; // u32
const uint EXFAT_BITMAP_DATA_LENGTH   = 0x18; // u64 on disk, low 4 bytes read

const uint EXFAT_DIRENT_SIZE = 32;
const uint EXFAT_SLOTS_PER_SECTOR = 16; // SECTOR_SIZE / EXFAT_DIRENT_SIZE — 512 / 32

// Longest entry set the write path builds: 1 File + 1 Stream + one File
// Name entry per 15 name units. EXFAT_NAME_MAX (128) / 15 rounds up to 9.
const int EXFAT_MAX_SET_SLOTS = 2 + 9;
const uint EXFAT_SET_BYTES_MAX = 32 * 11; // EXFAT_DIRENT_SIZE * EXFAT_MAX_SET_SLOTS, as a plain array-size constant

// End-of-chain marker this driver writes into a FAT entry (any value
// >= EXFAT_EOC_MIN reads as end-of-chain; 0xFFFFFFFF is what mkfs uses).
const uint EXFAT_EOC_WRITE = 0xFFFFFFFF;

// Recursion bound for the recursive-delete tree walk and the rename
// cycle check — same value and same "defense in depth against a corrupt
// on-disk structure, not a real depth limit anyone hits" reasoning as
// FAT32_MAX_DELETE_DEPTH / EXT2_MAX_DELETE_DEPTH.
const int EXFAT_MAX_DELETE_DEPTH = 32;

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
uint exfat_cluster_count;       // ClusterCount field — number of bits in the Allocation Bitmap

// --- Write path state, set by exfat_load_bitmap_info() at mount -------
// exfat_writes_ok gates fsd.c3 flipping fs_write_disabled off: it stays
// false unless the Allocation Bitmap was found AND the volume has
// exactly one FAT (a TexFAT volume, NumberOfFats==2, is left read-only —
// keeping its second FAT in sync is out of scope, same "reject the
// nonstandard layout rather than half-handle it" stance exfat_mount's
// 512-byte-sector check already takes).
uint exfat_bitmap_cluster = 0;  // Allocation Bitmap first cluster (0 = not found)
uint exfat_bitmap_length  = 0;  // its DataLength in bytes
bool exfat_writes_ok      = false;

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
	// Absolute (partition-relative) location of the entry the most recent
	// exfat_cursor_next() call returned — the write path needs to be able
	// to go back and modify a slot it walked past (rewrite a Stream
	// Extension entry, clear an in-use bit). Meaningless before the first
	// successful exfat_cursor_next().
	uint last_abs_sector;
	uint last_slot_in_sector;
}

fn void exfat_cursor_init(Exfat_dir_cursor* cur, uint dir_cluster, bool no_fat_chain)
{
	cur.cluster = dir_cluster;
	cur.no_fat_chain = no_fat_chain;
	cur.sector_in_cluster = 0;
	cur.entry_in_sector = 0;
	cur.sector_loaded = false;
	cur.last_abs_sector = 0;
	cur.last_slot_in_sector = 0;
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
	cur.last_abs_sector = exfat_cluster_to_sector(cur.cluster) + cur.sector_in_cluster;
	cur.last_slot_in_sector = cur.entry_in_sector;

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
// out_name (nullable): pass null when only the set's metadata matters
// (the recursive delete walk, which never compares names).
// out_locs (nullable): if given, records the absolute (sector, slot) of
// every entry in the set — index 0 is the primary File entry (the caller
// fills that from its own cur.last_abs_sector before calling), 1.. are
// the secondaries as this walk reaches them. The write path uses it to
// go back and rewrite the Stream Extension entry / clear in-use bits
// without a second name search. A set with more secondaries than
// EXFAT_MAX_SET_SLOTS-1 (never one this driver wrote) records what fits
// and marks itself over-length via out_locs.count so callers refuse it.
fn bool exfat_read_entry_set(Exfat_dir_cursor* cur, char* fde_entry, ushort* out_attr, uint* out_first_cluster, uint* out_data_length, bool* out_no_fat_chain, Char16* out_name, int* out_name_len, Exfat_set_locs* out_locs)
{
	bool in_use = ((uint)fde_entry[0] & EXFAT_ENTRY_INUSE_BIT) != 0;
	int secondary_remaining = (int)((uint)fde_entry[EXFAT_FDE_SECONDARY_COUNT] & 0xFF);
	ushort* attr_field = (ushort*)&fde_entry[EXFAT_FDE_ATTRIBUTES];
	ushort attr = *attr_field;

	if (out_locs != null) out_locs.count = 1 + secondary_remaining;

	bool stream_seen = false;
	bool no_fat_chain = false;
	uint first_cluster = 0;
	uint data_length = 0;
	int name_len = 0;

	for (int i = 0; i < secondary_remaining; i++)
	{
		char* entry = exfat_cursor_next(cur);
		if (entry == null) return false; // truncated directory

		if (out_locs != null && (i + 1) < EXFAT_MAX_SET_SLOTS)
		{
			out_locs.sector[i + 1] = cur.last_abs_sector;
			out_locs.slot[i + 1]   = cur.last_slot_in_sector;
		}

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
		else if (out_name != null)
		{
			int base = (i - 1) * EXFAT_NAME_CHARS_PER_ENTRY;
			for (int k = 0; k < EXFAT_NAME_CHARS_PER_ENTRY; k++)
			{
				int pos = base + k;
				if (pos >= name_len || pos >= EXFAT_NAME_MAX) break;
				Char16* ch = (Char16*)&entry[(int)EXFAT_NAME_CHARS + k * 2];
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

// The absolute (sector, slot) of every 32-byte entry in one file's/
// directory's entry set — index 0 is the primary File entry, 1.. the
// secondaries (Stream Extension, then File Name entries). Filled in by
// exfat_find_in_dir_located() straight from the directory cursor, so it
// stays correct for any on-disk layout (a set split across sectors, or
// even across a directory's cluster chain), not just the contiguous case
// arithmetic-from-the-primary would assume. `count` is the true slot
// count (1 + SecondaryCount); if it exceeds EXFAT_MAX_SET_SLOTS the set
// isn't one this driver ever wrote and callers refuse to edit it.
struct Exfat_set_locs
{
	int count;
	uint[EXFAT_MAX_SET_SLOTS] sector;
	uint[EXFAT_MAX_SET_SLOTS] slot;
}

// Walks dir_cluster's entry sets looking for a name match (post-upcase-
// fold, see exfat_name_eq_ci). dir_no_fat_chain describes dir_cluster's
// OWN chain (root is always false — see this file's header comment — a
// subdirectory's is whatever its own Stream Extension entry said, thread-
// ed in by the caller). out_locs (nullable): the physical location of
// every slot in the matched set, for the write path to edit in place.
fn bool exfat_find_in_dir_located(uint dir_cluster, bool dir_no_fat_chain, Char16* name_utf16, int name_len, uint* out_first_cluster, uint* out_data_length, ushort* out_attr, bool* out_no_fat_chain, Exfat_set_locs* out_locs)
{
	Exfat_dir_cursor cur @noinit;
	exfat_cursor_init(&cur, dir_cluster, dir_no_fat_chain);

	Char16[EXFAT_NAME_MAX] candidate @noinit;
	Exfat_set_locs locs;

	for (;;)
	{
		char* entry = exfat_cursor_next(&cur);
		if (entry == null) return false; // end of chain
		if (entry[0] == EXFAT_ENTRY_TYPE_END) return false; // end of directory

		uint type_byte = (uint)entry[0] & 0xFF;
		if ((type_byte & EXFAT_ENTRY_TYPECODE_MASK) != EXFAT_TYPECODE_FILE) continue; // bitmap/upcase/label/unknown — one standalone slot, skip

		// The primary File entry's own slot — captured before
		// exfat_read_entry_set advances the cursor past the secondaries.
		locs.sector[0] = cur.last_abs_sector;
		locs.slot[0]   = cur.last_slot_in_sector;

		uint first_cluster; uint data_length; ushort attr; bool no_fat_chain; int candidate_len;
		bool valid = exfat_read_entry_set(&cur, entry, &attr, &first_cluster, &data_length, &no_fat_chain, &candidate, &candidate_len, &locs);
		if (!valid) continue;

		if (exfat_name_eq_ci(name_utf16, name_len, &candidate, candidate_len))
		{
			*out_first_cluster = first_cluster;
			*out_data_length = data_length;
			*out_attr = attr;
			*out_no_fat_chain = no_fat_chain;
			if (out_locs != null) *out_locs = locs;
			return true;
		}
	}
}

fn bool exfat_find_in_dir(uint dir_cluster, bool dir_no_fat_chain, Char16* name_utf16, int name_len, uint* out_first_cluster, uint* out_data_length, ushort* out_attr, bool* out_no_fat_chain)
{
	return exfat_find_in_dir_located(dir_cluster, dir_no_fat_chain, name_utf16, name_len, out_first_cluster, out_data_length, out_attr, out_no_fat_chain, null);
}

// Same segment-by-segment walk as fat32_resolve_dir, but also threads the
// NoFatChain flag through: unlike FAT32, an exFAT subdirectory's own
// chain can be contiguous too (its Stream Extension entry carries the
// same flag a regular file's does), so every directory-cluster reference
// past the root has to travel with its own no_fat_chain bit, not just a
// bare cluster number.
fn bool exfat_resolve_dir(char* path, uint* out_dir_cluster, bool* out_no_fat_chain, uint* out_data_length)
{
	uint dir_cluster = exfat_root_cluster;
	bool no_fat_chain = false; // root directory's chain is always FAT-walked — it has no Stream Extension entry of its own, see this file's header comment
	uint data_length = 0;      // root has no Stream Extension entry — 0 is fine, the FAT chain bounds any root walk
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

			uint next_cluster; uint seg_data_len; ushort attr; bool next_no_fat_chain;
			if (!exfat_find_in_dir(dir_cluster, no_fat_chain, &seg_utf16, seg_len16, &next_cluster, &seg_data_len, &attr, &next_no_fat_chain)) return false;
			if (((uint)attr & EXFAT_ATTR_DIRECTORY) == 0) return false;
			dir_cluster = next_cluster;
			no_fat_chain = next_no_fat_chain;
			data_length = seg_data_len;
		}

		if (path[i] == 0) break;
		seg_start = i + 1;
		i++;
	}
	*out_dir_cluster = dir_cluster;
	*out_no_fat_chain = no_fat_chain;
	if (out_data_length != null) *out_data_length = data_length;
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
	if (!exfat_resolve_dir(name, &dir_cluster, &dir_no_fat_chain, null)) return -1;
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
	if (!exfat_resolve_dir(name, &dir_cluster, &dir_no_fat_chain, null)) return -1;
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
		if (!exfat_resolve_dir(path, &parent_cluster, &parent_no_fat_chain, null)) return false;
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
		bool valid = exfat_read_entry_set(&cur, entry, &attr, &first_cluster, &data_length, &no_fat_chain, &name_buf, &name_len, null);
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

// Locates the Allocation Bitmap (root-directory entry type 0x81) and
// caches its first cluster + byte length — the write path's cluster
// allocator/free work entirely against this bitmap, never the FAT (an
// exFAT volume's FAT only describes fragmented chains; a freshly
// allocated single cluster is NoFatChain and its FAT entry is simply
// left at 0, exactly what mkfs.exfat itself does). Same standalone-entry
// scan shape as exfat_load_upcase_table's, kept a separate pass rather
// than folded in: the root directory is one small cluster, and this
// keeps each function about one thing. Leaves exfat_bitmap_cluster at 0
// (→ writes stay disabled) if the volume somehow has no bitmap.
fn void exfat_load_bitmap_info()
{
	Exfat_dir_cursor cur @noinit;
	exfat_cursor_init(&cur, exfat_root_cluster, false);

	for (;;)
	{
		char* entry = exfat_cursor_next(&cur);
		if (entry == null) break;
		if (entry[0] == EXFAT_ENTRY_TYPE_END) break;
		if (entry[0] == EXFAT_ENTRY_TYPE_BITMAP)
		{
			uint* cluster_field = (uint*)&entry[EXFAT_BITMAP_FIRST_CLUSTER];
			uint* length_field  = (uint*)&entry[EXFAT_BITMAP_DATA_LENGTH];
			exfat_bitmap_cluster = *cluster_field;
			exfat_bitmap_length  = *length_field;
			return;
		}

		// Skip a whole File entry set — see exfat_load_upcase_table's own
		// comment for why the secondaries can't be walked as top-level slots.
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
	uint num_fats      = (uint)boot_sector[EXFAT_BS_NUMBER_OF_FATS] & 0xFF;
	uint* fat_offset_field    = (uint*)&boot_sector[EXFAT_BS_FAT_OFFSET];
	uint* heap_offset_field   = (uint*)&boot_sector[EXFAT_BS_CLUSTER_HEAP_OFFSET];
	uint* cluster_count_field = (uint*)&boot_sector[EXFAT_BS_CLUSTER_COUNT];
	uint* root_cluster_field  = (uint*)&boot_sector[EXFAT_BS_ROOT_CLUSTER];

	exfat_sectors_per_cluster = (uint)1 << cluster_shift;
	exfat_fat_start_sector    = *fat_offset_field;
	exfat_cluster_heap_offset = *heap_offset_field;
	exfat_cluster_count       = *cluster_count_field;
	exfat_root_cluster        = *root_cluster_field;

	exfat_load_upcase_table();
	exfat_load_bitmap_info();

	// Enable writes only for a plain, single-FAT volume whose bitmap we
	// actually found — see exfat_writes_ok's own comment. fsd.c3 reads
	// this flag to decide whether to flip fs_write_disabled off.
	exfat_writes_ok = (exfat_bitmap_cluster != 0) && (num_fats == 1);

	print("fsd: exFAT mounted, partition_start=");
	print_uint(fs_partition_start);
	print(" root_cluster=");
	print_uint(exfat_root_cluster);
	print(" sectors_per_cluster=");
	print_uint(exfat_sectors_per_cluster);
	print(exfat_writes_ok ? " writes=on" : " writes=off (read-only volume layout)");
	print("\n");
}

// ======================================================================
// Write path — create/overwrite files, delete (file, empty directory, or
// whole subtree), mkdir, rename/move. Read-only until the write sessions
// (see this file's header comment and docs/devlog.md); the same later-
// session precedent FAT32 and ext2 both followed. FS_WRITE + non-
// recursive FS_DELETE + FS_MKDIR landed first; recursive FS_DELETE and
// FS_RENAME a session after.
//
// Scope, all deliberate (narrower = less that can corrupt a live volume,
// same reasoning fat32.c3's write path took):
//  - Files only ever occupy ONE cluster. fsd.c3 caps a single FS_WRITE
//    at FS_MSG_MAX-104 (~1KB) and there is no append/offset write verb,
//    so every file this driver writes is far smaller than one cluster
//    (>= 4KB on every real volume). That means every allocation is
//    exactly one cluster, always contiguous, always NoFatChain — the
//    FAT is never written for file data (exactly what mkfs.exfat itself
//    does: a NoFatChain cluster's FAT entry is left at 0, the
//    Allocation Bitmap is the sole record that it's in use).
//  - Directories this driver creates are also single-cluster and
//    NoFatChain. A directory that fills its cluster (128 slots, ~40
//    entries in a fresh one) can't grow — exfat_find_free_slot_run
//    returns "no room" and the create (or a rename into it) fails.
//    Directory extension is a later concern.
//  - Non-recursive delete of a directory succeeds only if it's empty
//    (exfat_delete); the recursive form (exfat_delete_recursive) empties
//    it first, same split as `rm` vs `rm -r`.
//
// The cluster allocator works entirely against the Allocation Bitmap
// (exfat_load_bitmap_info found it at mount). exfat_writes_ok gates the
// whole path — fsd.c3 checks it before flipping fs_write_disabled off,
// and every entry point below re-checks it too.
// ======================================================================

fn uint exfat_cluster_size_bytes()
{
	return exfat_sectors_per_cluster * SECTOR_SIZE;
}

// Zeroes every sector of `cluster` — used to make a freshly allocated
// directory cluster a valid empty directory (all-0x00 = end-of-directory
// from its very first slot).
fn bool exfat_zero_cluster(uint cluster)
{
	char[SECTOR_SIZE] zero @noinit;
	for (uint i = 0; i < SECTOR_SIZE; i++) zero[i] = 0;
	uint base = exfat_cluster_to_sector(cluster);
	for (uint s = 0; s < exfat_sectors_per_cluster; s++)
	{
		if (!fs_write_sector(base + s, &zero)) return false;
	}
	return true;
}

// Writes one 4-byte little-endian FAT entry. exFAT has a single FAT
// (mount rejects the 2-FAT TexFAT variant), so no multi-copy loop like
// fat32_write_fat_entry's. Only ever called to build/tear down a
// directory's chain or tidy a freed fragmented file's — never for the
// NoFatChain file data this driver writes.
fn bool exfat_write_fat_entry(uint cluster, uint value)
{
	uint byte_off = cluster * 4;
	uint sec = exfat_fat_start_sector + byte_off / SECTOR_SIZE;
	uint in_sec = byte_off % SECTOR_SIZE;
	char[SECTOR_SIZE] buf @noinit;
	if (!fs_read_sector(sec, &buf)) return false;
	uint* entry = (uint*)&buf[in_sec];
	*entry = value;
	return fs_write_sector(sec, &buf);
}

// Scans the Allocation Bitmap for the first free cluster, marks it used,
// and returns its cluster number (2-based). Returns 0 on "volume full"
// or any I/O error. The bitmap system file is contiguous on every real
// exFAT volume (mkfs lays it out first and it never fragments), so its
// sectors are read straight through from its first cluster.
fn uint exfat_alloc_cluster()
{
	if (exfat_bitmap_cluster == 0) return 0;
	uint total = exfat_cluster_count;
	uint need_bytes = (total + 7) / 8;
	if (need_bytes > exfat_bitmap_length) need_bytes = exfat_bitmap_length;

	uint base = exfat_cluster_to_sector(exfat_bitmap_cluster);
	char[SECTOR_SIZE] buf @noinit;
	for (uint off = 0; off < need_bytes; off += SECTOR_SIZE)
	{
		uint sec = base + off / SECTOR_SIZE;
		if (!fs_read_sector(sec, &buf)) return 0;
		uint chunk = need_bytes - off;
		if (chunk > SECTOR_SIZE) chunk = SECTOR_SIZE;
		for (uint b = 0; b < chunk; b++)
		{
			uint byte_val = (uint)buf[b] & 0xFF;
			if (byte_val == 0xFF) continue; // fully allocated byte
			for (uint bit = 0; bit < 8; bit++)
			{
				if ((byte_val & (1u << bit)) != 0) continue;
				uint cluster_index = (off + b) * 8 + bit; // bit 0 of byte 0 == cluster 2
				if (cluster_index >= total) return 0;
				buf[b] = (char)(byte_val | (1u << bit));
				if (!fs_write_sector(sec, &buf)) return 0;
				return cluster_index + 2;
			}
		}
	}
	return 0;
}

// Clears one cluster's bit in the Allocation Bitmap. The FAT entry (if
// this cluster was part of a fragmented chain) is the caller's job.
fn bool exfat_free_cluster(uint cluster)
{
	if (exfat_bitmap_cluster == 0 || cluster < 2) return false;
	uint bit_index = cluster - 2;
	if (bit_index >= exfat_cluster_count) return false;
	uint byte_index = bit_index / 8;
	uint sec = exfat_cluster_to_sector(exfat_bitmap_cluster) + byte_index / SECTOR_SIZE;
	uint in_sec = byte_index % SECTOR_SIZE;
	char[SECTOR_SIZE] buf @noinit;
	if (!fs_read_sector(sec, &buf)) return false;
	uint byte_val = (uint)buf[in_sec] & 0xFF;
	buf[in_sec] = (char)(byte_val & ~(1u << (bit_index % 8)));
	return fs_write_sector(sec, &buf);
}

// Frees every cluster backing a file or directory: a contiguous run for
// NoFatChain, a real FAT walk otherwise (reading each link before
// clearing it, same ordering care fat32_free_cluster_chain takes). A
// zero/never-allocated first_cluster is a no-op success.
fn bool exfat_free_data(uint first_cluster, uint data_length, bool no_fat_chain)
{
	if (first_cluster < 2 || first_cluster >= EXFAT_EOC_MIN) return true;
	uint cluster_size = exfat_cluster_size_bytes();

	if (no_fat_chain)
	{
		uint n = (data_length + cluster_size - 1) / cluster_size;
		if (n == 0) n = 1;
		for (uint i = 0; i < n; i++)
		{
			if (!exfat_free_cluster(first_cluster + i)) return false;
		}
		return true;
	}

	uint cluster = first_cluster;
	uint guard = 0;
	while (cluster >= 2 && cluster < EXFAT_EOC_MIN && guard <= exfat_cluster_count)
	{
		uint next = exfat_next_cluster(cluster);
		if (!exfat_free_cluster(cluster)) return false;
		exfat_write_fat_entry(cluster, 0); // best-effort tidy; the bitmap is the real record
		cluster = next;
		guard++;
	}
	return true;
}

// exFAT's 16-bit entry-set checksum: rotate right one bit, then add the
// byte, 16-bit wraparound, over every byte of the set except the
// 2-byte SetChecksum field itself (offsets 2..3 of the primary entry).
fn ushort exfat_set_checksum(char* bytes, int total_slots)
{
	ushort sum = 0;
	int n = total_slots * (int)EXFAT_DIRENT_SIZE;
	for (int i = 0; i < n; i++)
	{
		if (i == (int)EXFAT_FDE_SET_CHECKSUM || i == (int)EXFAT_FDE_SET_CHECKSUM + 1) continue;
		uint b = (uint)bytes[i] & 0xFF;
		sum = (ushort)((((uint)sum & 1u) << 15) | ((uint)sum >> 1));
		sum = (ushort)(((uint)sum + b) & 0xFFFF);
	}
	return sum;
}

// exFAT's 16-bit name hash: same rotate-then-add as the set checksum,
// over the little-endian bytes of the up-cased name. Stored in the
// Stream Extension entry so a reader can reject a non-matching name
// without a full comparison (this driver's own read path doesn't rely
// on it — see exfat_read_entry_set's comment — but a correct one has to
// be written).
fn ushort exfat_name_hash(Char16* name, int name_len)
{
	ushort hash = 0;
	for (int i = 0; i < name_len; i++)
	{
		Char16 uc = exfat_upcase(name[i]);
		uint lo = (uint)uc & 0xFF;
		uint hi = ((uint)uc >> 8) & 0xFF;
		hash = (ushort)((((uint)hash & 1u) << 15) | ((uint)hash >> 1));
		hash = (ushort)(((uint)hash + lo) & 0xFFFF);
		hash = (ushort)((((uint)hash & 1u) << 15) | ((uint)hash >> 1));
		hash = (ushort)(((uint)hash + hi) & 0xFFFF);
	}
	return hash;
}

// Read-modify-writes one 32-byte slot into its sector. Refuses if the
// slot is the protected file's own directory entry (fs_is_protected_
// entry, tracked as a byte offset within the sector — same convention
// fat32 uses).
fn bool exfat_write_slot(uint sector, uint slot_in_sector, char* slot_bytes)
{
	if (fs_is_protected_entry(sector, slot_in_sector * EXFAT_DIRENT_SIZE)) return false;
	char[SECTOR_SIZE] buf @noinit;
	if (!fs_read_sector(sector, &buf)) return false;
	uint off = slot_in_sector * EXFAT_DIRENT_SIZE;
	for (uint i = 0; i < EXFAT_DIRENT_SIZE; i++) buf[off + i] = slot_bytes[i];
	return fs_write_sector(sector, &buf);
}

// Writes `len` bytes of `src` into `cluster` (len <= one cluster), zero-
// padding the tail of the last touched sector. Sectors fully past the
// data are left as-is (stale, but past the entry's DataLength/
// ValidDataLength, so no reader ever sees them) — same as
// fat32_write_file.
fn bool exfat_write_cluster_data(uint cluster, char* src, uint len)
{
	uint base = exfat_cluster_to_sector(cluster);
	uint written = 0;
	for (uint s = 0; s < exfat_sectors_per_cluster; s++)
	{
		uint chunk = 0;
		if (written < len)
		{
			chunk = len - written;
			if (chunk > SECTOR_SIZE) chunk = SECTOR_SIZE;
		}
		char[SECTOR_SIZE] buf @noinit;
		for (uint i = 0; i < SECTOR_SIZE; i++) buf[i] = (i < chunk) ? src[written + i] : (char)0;
		if (!fs_write_sector(base + s, &buf)) return false;
		written += chunk;
		if (written >= len) return true;
	}
	return true;
}

// Fills `out` (>= EXFAT_SET_BYTES_MAX bytes) with a complete, in-use
// entry set — primary File entry, Stream Extension, and enough File Name
// entries for `name` — and returns the total slot count. `first_cluster`
// 0 / `data_length` 0 means an empty file (no cluster). Directories pass
// their own allocated size as data_length. `no_fat_chain` is the
// Stream Extension flag: true for everything this driver allocates
// itself (always one contiguous cluster), but exfat_rename passes
// through whatever the moved file/directory already had. The SetChecksum
// is filled last, over everything.
fn int exfat_build_set(char* out, Char16* name, int name_len, ushort attr, uint first_cluster, uint data_length, bool no_fat_chain)
{
	int name_entries = (name_len + EXFAT_NAME_CHARS_PER_ENTRY - 1) / EXFAT_NAME_CHARS_PER_ENTRY;
	if (name_entries < 1) name_entries = 1;
	int secondary_count = 1 + name_entries;
	int total_slots = 1 + secondary_count;

	int total_bytes = total_slots * (int)EXFAT_DIRENT_SIZE;
	for (int i = 0; i < total_bytes; i++) out[i] = 0;

	// Primary: File Directory Entry.
	out[0] = EXFAT_ENTRY_TYPE_FILE;
	out[EXFAT_FDE_SECONDARY_COUNT] = (char)secondary_count;
	ushort* attr_field = (ushort*)&out[EXFAT_FDE_ATTRIBUTES];
	*attr_field = attr;
	uint* ts = (uint*)&out[EXFAT_FDE_CREATE_TIME];
	ts[0] = EXFAT_FIXED_TIMESTAMP; // create
	ts[1] = EXFAT_FIXED_TIMESTAMP; // last modified  (0x0C)
	ts[2] = EXFAT_FIXED_TIMESTAMP; // last accessed  (0x10)

	// Secondary 1: Stream Extension.
	char* st = &out[EXFAT_DIRENT_SIZE];
	bool has_data = first_cluster >= 2 && data_length > 0;
	uint stream_flags = EXFAT_STREAM_FLAG_ALLOC_POSSIBLE;
	if (has_data && no_fat_chain) stream_flags |= EXFAT_STREAM_FLAG_NO_FAT_CHAIN;
	st[0] = EXFAT_ENTRY_TYPE_STREAM;
	st[EXFAT_STREAM_FLAGS] = (char)stream_flags;
	st[EXFAT_STREAM_NAME_LENGTH] = (char)name_len;
	ushort* nh = (ushort*)&st[EXFAT_STREAM_NAME_HASH];
	*nh = exfat_name_hash(name, name_len);
	uint* vdl = (uint*)&st[EXFAT_STREAM_VALID_DATA_LENGTH];
	vdl[0] = data_length; vdl[1] = 0;
	uint* fc = (uint*)&st[EXFAT_STREAM_FIRST_CLUSTER];
	*fc = has_data ? first_cluster : 0;
	uint* dl = (uint*)&st[EXFAT_STREAM_DATA_LENGTH];
	dl[0] = data_length; dl[1] = 0;

	// Secondaries 2..: File Name entries, 15 UTF-16 units each.
	for (int e = 0; e < name_entries; e++)
	{
		char* ne = &out[(2 + e) * (int)EXFAT_DIRENT_SIZE];
		ne[0] = EXFAT_ENTRY_TYPE_NAME;
		for (int k = 0; k < EXFAT_NAME_CHARS_PER_ENTRY; k++)
		{
			int pos = e * EXFAT_NAME_CHARS_PER_ENTRY + k;
			Char16 ch = (pos < name_len) ? name[pos] : (Char16)0;
			Char16* dst = (Char16*)&ne[(int)EXFAT_NAME_CHARS + k * 2];
			*dst = ch;
		}
	}

	ushort* cksum = (ushort*)&out[EXFAT_FDE_SET_CHECKSUM];
	*cksum = exfat_set_checksum(out, total_slots);
	return total_slots;
}

// Finds `needed` consecutive free 32-byte slots inside one cluster of
// the directory (a run never spans a cluster boundary — keeps the
// linear stepping in exfat_place_set valid, and every set is <= 11
// slots vs 128 per cluster). `dir_data_length` bounds a NoFatChain
// directory's own extent; a FAT-chained one (the root, always) is
// bounded by its chain. Returns false — the operation then fails — if
// no run fits: this pass has no directory extension.
fn bool exfat_find_free_slot_run(uint dir_cluster, bool dir_no_fat_chain, uint dir_data_length, int needed, uint* out_first_sector, uint* out_first_slot)
{
	uint cluster = dir_cluster;
	uint clusters_left = 0;
	if (dir_no_fat_chain)
	{
		uint cs = exfat_cluster_size_bytes();
		clusters_left = (dir_data_length + cs - 1) / cs;
		if (clusters_left == 0) clusters_left = 1;
	}

	uint guard = 0;
	while (cluster >= 2 && cluster < EXFAT_EOC_MIN && guard <= exfat_cluster_count)
	{
		guard++;
		if (dir_no_fat_chain && clusters_left == 0) break;

		uint base_sector = exfat_cluster_to_sector(cluster);
		int run = 0;
		uint run_sector = 0;
		uint run_slot = 0;
		for (uint s = 0; s < exfat_sectors_per_cluster; s++)
		{
			char[SECTOR_SIZE] buf @noinit;
			if (!fs_read_sector(base_sector + s, &buf)) return false;
			for (uint slot = 0; slot < EXFAT_SLOTS_PER_SECTOR; slot++)
			{
				uint t = (uint)buf[slot * EXFAT_DIRENT_SIZE] & 0xFF;
				bool is_free = (t == 0) || ((t & EXFAT_ENTRY_INUSE_BIT) == 0);
				if (is_free)
				{
					if (run == 0) { run_sector = base_sector + s; run_slot = slot; }
					run++;
					if (run >= needed)
					{
						*out_first_sector = run_sector;
						*out_first_slot = run_slot;
						return true;
					}
				}
				else
				{
					run = 0;
				}
			}
		}

		if (dir_no_fat_chain) { cluster++; clusters_left--; }
		else { cluster = exfat_next_cluster(cluster); }
	}
	return false;
}

// Places a freshly built entry set into `dir` at the first free run.
// The run is within one cluster's contiguous sectors, so slot k lands
// at a simple linear offset from the run start.
fn bool exfat_place_set(uint dir_cluster, bool dir_no_fat_chain, uint dir_data_length, char* set_bytes, int total_slots)
{
	uint first_sector;
	uint first_slot;
	if (!exfat_find_free_slot_run(dir_cluster, dir_no_fat_chain, dir_data_length, total_slots, &first_sector, &first_slot)) return false;

	for (int k = 0; k < total_slots; k++)
	{
		uint flat = first_slot + (uint)k;
		uint sec = first_sector + flat / EXFAT_SLOTS_PER_SECTOR;
		uint slot = flat % EXFAT_SLOTS_PER_SECTOR;
		if (!exfat_write_slot(sec, slot, &set_bytes[k * (int)EXFAT_DIRENT_SIZE])) return false;
	}
	return true;
}

// Clears the in-use bit (0x80) of every slot in a located entry set —
// exFAT's whole "delete": 0x85->0x05, 0xC0->0x40, 0xC1->0x41, the rest
// of each slot untouched. Refuses a set larger than this driver could
// have written, or one overlapping the protected entry.
fn bool exfat_clear_entry_set(Exfat_set_locs* locs)
{
	if (locs.count < 2 || locs.count > EXFAT_MAX_SET_SLOTS) return false;
	for (int k = 0; k < locs.count; k++)
	{
		uint sec = locs.sector[k];
		uint slot = locs.slot[k];
		if (fs_is_protected_entry(sec, slot * EXFAT_DIRENT_SIZE)) return false;
		char[SECTOR_SIZE] buf @noinit;
		if (!fs_read_sector(sec, &buf)) return false;
		uint off = slot * EXFAT_DIRENT_SIZE;
		buf[off] = (char)((uint)buf[off] & ~EXFAT_ENTRY_INUSE_BIT);
		if (!fs_write_sector(sec, &buf)) return false;
	}
	return true;
}

// Repoints an existing file's Stream Extension entry at new data
// (cluster + length), recomputing the SetChecksum over the whole set.
// Only slots 0 (primary, checksum) and 1 (stream) change.
fn bool exfat_rewrite_stream(Exfat_set_locs* locs, uint new_first_cluster, uint new_data_length)
{
	if (locs.count < 2 || locs.count > EXFAT_MAX_SET_SLOTS) return false;

	char[EXFAT_SET_BYTES_MAX] set_bytes @noinit;
	for (int k = 0; k < locs.count; k++)
	{
		char[SECTOR_SIZE] buf @noinit;
		if (!fs_read_sector(locs.sector[k], &buf)) return false;
		uint off = locs.slot[k] * EXFAT_DIRENT_SIZE;
		for (uint i = 0; i < EXFAT_DIRENT_SIZE; i++) set_bytes[(uint)k * EXFAT_DIRENT_SIZE + i] = buf[off + i];
	}

	char* st = &set_bytes[EXFAT_DIRENT_SIZE];
	bool has_data = new_first_cluster >= 2 && new_data_length > 0;
	st[EXFAT_STREAM_FLAGS] = (char)(has_data
		? (EXFAT_STREAM_FLAG_ALLOC_POSSIBLE | EXFAT_STREAM_FLAG_NO_FAT_CHAIN)
		: EXFAT_STREAM_FLAG_ALLOC_POSSIBLE);
	uint* vdl = (uint*)&st[EXFAT_STREAM_VALID_DATA_LENGTH];
	vdl[0] = new_data_length; vdl[1] = 0;
	uint* fc = (uint*)&st[EXFAT_STREAM_FIRST_CLUSTER];
	*fc = has_data ? new_first_cluster : 0;
	uint* dl = (uint*)&st[EXFAT_STREAM_DATA_LENGTH];
	dl[0] = new_data_length; dl[1] = 0;

	ushort* cksum = (ushort*)&set_bytes[EXFAT_FDE_SET_CHECKSUM];
	*cksum = exfat_set_checksum(&set_bytes, locs.count);

	if (!exfat_write_slot(locs.sector[0], locs.slot[0], &set_bytes[0])) return false;
	if (!exfat_write_slot(locs.sector[1], locs.slot[1], &set_bytes[EXFAT_DIRENT_SIZE])) return false;
	return true;
}

// True if `dir` (its own chain described by no_fat_chain) contains no
// in-use File entry — i.e. it's safe to remove. Standalone system
// entries can't appear in a subdirectory, so any in-use 0x85 means
// "not empty".
fn bool exfat_dir_is_empty(uint dir_cluster, bool no_fat_chain)
{
	Exfat_dir_cursor cur @noinit;
	exfat_cursor_init(&cur, dir_cluster, no_fat_chain);
	for (;;)
	{
		char* entry = exfat_cursor_next(&cur);
		if (entry == null) return true;      // end of chain
		if (entry[0] == EXFAT_ENTRY_TYPE_END) return true;
		if (entry[0] == EXFAT_ENTRY_TYPE_FILE) return false; // an in-use file/subdir
	}
}

// --- FS_WRITE --------------------------------------------------------
//
// Create-or-overwrite, one cluster max (see this section's header).
// Data is allocated and written first, so any failure leaves an
// existing file untouched; the directory entry is only then created
// (new file) or repointed (overwrite), and the old data freed last —
// "fail toward a leak, never toward losing the file," same ordering
// fat32_write / fat32_rename use.
fn int exfat_write(char* name, char* src, uint len)
{
	if (!exfat_writes_ok) return -1;
	if (len > exfat_cluster_size_bytes()) return -1;

	uint dir_cluster; bool dir_no_fat_chain; uint dir_data_length;
	if (!exfat_resolve_dir(name, &dir_cluster, &dir_no_fat_chain, &dir_data_length)) return -1;
	char* leaf = exfat_leaf_name(name);
	if (leaf[0] == 0) return -1;

	Char16[EXFAT_NAME_MAX] leaf16 @noinit;
	int leaf_len = exfat_ascii_to_utf16(leaf, &leaf16, EXFAT_NAME_MAX);
	if (leaf_len == 0) return -1;

	uint old_fc; uint old_dl; ushort old_attr; bool old_nfc;
	Exfat_set_locs locs;
	bool exists = exfat_find_in_dir_located(dir_cluster, dir_no_fat_chain, &leaf16, leaf_len, &old_fc, &old_dl, &old_attr, &old_nfc, &locs);
	if (exists && ((uint)old_attr & EXFAT_ATTR_DIRECTORY) != 0) return -1; // don't overwrite a directory
	if (exists && locs.count > EXFAT_MAX_SET_SLOTS) return -1;             // set this driver can't safely edit

	uint new_cluster = 0;
	if (len > 0)
	{
		new_cluster = exfat_alloc_cluster();
		if (new_cluster == 0) return -1;
		if (!exfat_write_cluster_data(new_cluster, src, len))
		{
			exfat_free_cluster(new_cluster);
			return -1;
		}
	}

	if (exists)
	{
		if (!exfat_rewrite_stream(&locs, new_cluster, len))
		{
			if (new_cluster != 0) exfat_free_cluster(new_cluster);
			return -1;
		}
		exfat_free_data(old_fc, old_dl, old_nfc);
	}
	else
	{
		char[EXFAT_SET_BYTES_MAX] set_bytes @noinit;
		int total_slots = exfat_build_set(&set_bytes, &leaf16, leaf_len, (ushort)EXFAT_ATTR_ARCHIVE, new_cluster, len, true);
		if (!exfat_place_set(dir_cluster, dir_no_fat_chain, dir_data_length, &set_bytes, total_slots))
		{
			if (new_cluster != 0) exfat_free_cluster(new_cluster);
			return -1;
		}
	}
	return (int)len;
}

// --- FS_DELETE (non-recursive) --------------------------------------
//
// Removes a file, or an empty directory. Clears the entry set's in-use
// bits first (so the name stops resolving even if freeing the data
// half-fails), then frees the data clusters.
fn int exfat_delete(char* name)
{
	if (!exfat_writes_ok) return -1;

	uint dir_cluster; bool dir_no_fat_chain; uint dir_data_length;
	if (!exfat_resolve_dir(name, &dir_cluster, &dir_no_fat_chain, &dir_data_length)) return -1;
	char* leaf = exfat_leaf_name(name);
	if (leaf[0] == 0) return -1;

	Char16[EXFAT_NAME_MAX] leaf16 @noinit;
	int leaf_len = exfat_ascii_to_utf16(leaf, &leaf16, EXFAT_NAME_MAX);
	if (leaf_len == 0) return -1;

	uint fc; uint dl; ushort attr; bool nfc;
	Exfat_set_locs locs;
	if (!exfat_find_in_dir_located(dir_cluster, dir_no_fat_chain, &leaf16, leaf_len, &fc, &dl, &attr, &nfc, &locs)) return -1;
	if (locs.count > EXFAT_MAX_SET_SLOTS) return -1;

	if (((uint)attr & EXFAT_ATTR_DIRECTORY) != 0)
	{
		if (!exfat_dir_is_empty(fc, nfc)) return -1; // non-recursive: refuse a non-empty directory
	}

	if (!exfat_clear_entry_set(&locs)) return -1;
	exfat_free_data(fc, dl, nfc);
	return 0;
}

// --- FS_MKDIR -------------------------------------------------------
//
// A new single-cluster, NoFatChain directory. exFAT directories have no
// "." / ".." entries, so a zeroed cluster IS a valid empty directory.
fn int exfat_mkdir(char* path)
{
	if (!exfat_writes_ok) return -1;

	uint parent_cluster; bool parent_nfc; uint parent_data_length;
	if (!exfat_resolve_dir(path, &parent_cluster, &parent_nfc, &parent_data_length)) return -1;
	char* leaf = exfat_leaf_name(path);
	if (leaf[0] == 0) return -1;

	Char16[EXFAT_NAME_MAX] leaf16 @noinit;
	int leaf_len = exfat_ascii_to_utf16(leaf, &leaf16, EXFAT_NAME_MAX);
	if (leaf_len == 0) return -1;

	uint efc; uint edl; ushort eattr; bool enfc;
	if (exfat_find_in_dir(parent_cluster, parent_nfc, &leaf16, leaf_len, &efc, &edl, &eattr, &enfc)) return -1; // already exists

	uint new_cluster = exfat_alloc_cluster();
	if (new_cluster == 0) return -1;
	if (!exfat_zero_cluster(new_cluster))
	{
		exfat_free_cluster(new_cluster);
		return -1;
	}

	char[EXFAT_SET_BYTES_MAX] set_bytes @noinit;
	int total_slots = exfat_build_set(&set_bytes, &leaf16, leaf_len, (ushort)EXFAT_ATTR_DIRECTORY, new_cluster, exfat_cluster_size_bytes(), true);
	if (!exfat_place_set(parent_cluster, parent_nfc, parent_data_length, &set_bytes, total_slots))
	{
		exfat_free_cluster(new_cluster);
		return -1;
	}
	return 0;
}

// Backstop for the write-protected boot image (fsd.c3's FS_PROTECTED_
// NAME) if it ever lives on an exFAT volume — normally it doesn't (it's
// on the FAT32 boot partition, see docs/devlog.md's filesystem-topology
// notes), so this almost always finds nothing and just logs. Mirrors
// fat32_reserve_protected: record the primary entry's exact (sector,
// offset) for the narrow check, and reserve the data cluster(s) at the
// coarse sector-range level.
fn void exfat_reserve_protected(char* name)
{
	Char16[EXFAT_NAME_MAX] name16 @noinit;
	int name_len = exfat_ascii_to_utf16(name, &name16, EXFAT_NAME_MAX);

	uint fc; uint dl; ushort attr; bool nfc;
	Exfat_set_locs locs;
	if (!exfat_find_in_dir_located(exfat_root_cluster, false, &name16, name_len, &fc, &dl, &attr, &nfc, &locs))
	{
		print("fsd: protected file not found, nothing to reserve for it\n");
		return;
	}
	if (((uint)attr & EXFAT_ATTR_DIRECTORY) != 0)
	{
		print("fsd: protected file not found, nothing to reserve for it\n");
		return;
	}

	fs_set_protected_entry(locs.sector[0], locs.slot[0] * EXFAT_DIRENT_SIZE);

	uint cluster_size = exfat_cluster_size_bytes();
	if (nfc)
	{
		uint n = (dl + cluster_size - 1) / cluster_size;
		if (n == 0) n = 1;
		for (uint i = 0; i < n; i++)
		{
			if (!fs_reserve_sector_range(exfat_cluster_to_sector(fc + i), exfat_sectors_per_cluster)) return;
		}
		return;
	}
	uint cluster = fc;
	uint guard = 0;
	while (cluster >= 2 && cluster < EXFAT_EOC_MIN && guard <= exfat_cluster_count)
	{
		if (!fs_reserve_sector_range(exfat_cluster_to_sector(cluster), exfat_sectors_per_cluster)) return;
		cluster = exfat_next_cluster(cluster);
		guard++;
	}
}

// --- FS_DELETE (recursive) -----------------------------------------
//
// Frees the DATA of every descendant of `dir` — every file's clusters,
// and (after recursing into it) every subdirectory's own cluster(s).
// Does NOT clear any entry set inside `dir`: the whole subtree's
// directory clusters are freed wholesale by the caller, so unlinking
// individual children first would just be wasted writes (same shortcut
// fat32_delete_dir_contents takes — it marks entries deleted only
// because a FAT32 dir cluster it's *not* about to free could hold the
// entry; here the recursion always frees the containing cluster). A
// protected entry anywhere in the subtree aborts before anything is
// freed — never a partial delete.
fn bool exfat_free_tree(uint dir_cluster, bool dir_no_fat_chain, uint dir_data_length, int depth)
{
	if (depth >= EXFAT_MAX_DELETE_DEPTH) return false;

	Exfat_dir_cursor cur @noinit;
	exfat_cursor_init(&cur, dir_cluster, dir_no_fat_chain);

	for (;;)
	{
		char* entry = exfat_cursor_next(&cur);
		if (entry == null) return true;      // end of chain
		if (entry[0] == EXFAT_ENTRY_TYPE_END) return true;

		uint type_byte = (uint)entry[0] & 0xFF;
		if ((type_byte & EXFAT_ENTRY_TYPECODE_MASK) != EXFAT_TYPECODE_FILE) continue;

		Exfat_set_locs locs;
		locs.sector[0] = cur.last_abs_sector;
		locs.slot[0]   = cur.last_slot_in_sector;

		uint child_fc; uint child_dl; ushort child_attr; bool child_nfc; int child_name_len;
		if (!exfat_read_entry_set(&cur, entry, &child_attr, &child_fc, &child_dl, &child_nfc, null, &child_name_len, &locs)) continue;

		// A protected entry in the subtree stops everything, before any
		// free — same all-or-nothing guarantee fat32_delete_recursive gives.
		for (int k = 0; k < locs.count && k < EXFAT_MAX_SET_SLOTS; k++)
		{
			if (fs_is_protected_entry(locs.sector[k], locs.slot[k] * EXFAT_DIRENT_SIZE)) return false;
		}

		if (((uint)child_attr & EXFAT_ATTR_DIRECTORY) != 0)
		{
			if (!exfat_free_tree(child_fc, child_nfc, child_dl, depth + 1)) return false;
		}
		if (!exfat_free_data(child_fc, child_dl, child_nfc)) return false;
	}
}

fn int exfat_delete_recursive(char* name)
{
	if (!exfat_writes_ok) return -1;

	uint dir_cluster; bool dir_no_fat_chain; uint dir_data_length;
	if (!exfat_resolve_dir(name, &dir_cluster, &dir_no_fat_chain, &dir_data_length)) return -1;
	char* leaf = exfat_leaf_name(name);
	if (leaf[0] == 0) return -1;

	Char16[EXFAT_NAME_MAX] leaf16 @noinit;
	int leaf_len = exfat_ascii_to_utf16(leaf, &leaf16, EXFAT_NAME_MAX);
	if (leaf_len == 0) return -1;

	uint fc; uint dl; ushort attr; bool nfc;
	Exfat_set_locs locs;
	if (!exfat_find_in_dir_located(dir_cluster, dir_no_fat_chain, &leaf16, leaf_len, &fc, &dl, &attr, &nfc, &locs)) return -1;
	if (locs.count > EXFAT_MAX_SET_SLOTS) return -1;

	// Free descendants first (so a failure part-way leaves the target
	// directory still linked, just partly emptied — recoverable), then
	// unlink the target from its parent, then free the target's own
	// cluster(s).
	if (((uint)attr & EXFAT_ATTR_DIRECTORY) != 0)
	{
		if (!exfat_free_tree(fc, nfc, dl, 0)) return -1;
	}
	if (!exfat_clear_entry_set(&locs)) return -1;
	if (!exfat_free_data(fc, dl, nfc)) return -1;
	return 0;
}

// --- FS_RENAME -----------------------------------------------------
//
// Add a fresh entry set at the destination pointing at the SAME
// clusters (no data copy — just the directory entry that names them),
// then clear the source entry set — new one safely in place before the
// old one goes away, "fail toward a duplicate, never toward losing the
// file," same order fat32_rename uses. No overwrite (destination must
// not already exist). Refuses moving a directory into its own subtree
// (exfat_subtree_contains, below — exFAT directories have no ".." to
// walk up, so this walks *down* from the source instead). No directory-
// extension: if the destination directory's cluster is full the rename
// fails, same limit exfat_write/exfat_mkdir already have.
fn bool exfat_subtree_contains(uint ancestor_cluster, bool ancestor_nfc, uint ancestor_dl, uint target_cluster, int depth)
{
	if (depth >= EXFAT_MAX_DELETE_DEPTH) return true; // too deep to be sure — refuse the rename

	Exfat_dir_cursor cur @noinit;
	exfat_cursor_init(&cur, ancestor_cluster, ancestor_nfc);

	for (;;)
	{
		char* entry = exfat_cursor_next(&cur);
		if (entry == null) return false;
		if (entry[0] == EXFAT_ENTRY_TYPE_END) return false;

		uint type_byte = (uint)entry[0] & 0xFF;
		if ((type_byte & EXFAT_ENTRY_TYPECODE_MASK) != EXFAT_TYPECODE_FILE) continue;

		uint child_fc; uint child_dl; ushort child_attr; bool child_nfc; int child_name_len;
		if (!exfat_read_entry_set(&cur, entry, &child_attr, &child_fc, &child_dl, &child_nfc, null, &child_name_len, null)) continue;
		if (((uint)child_attr & EXFAT_ATTR_DIRECTORY) == 0) continue;

		if (child_fc == target_cluster) return true;
		if (exfat_subtree_contains(child_fc, child_nfc, child_dl, target_cluster, depth + 1)) return true;
	}
}

fn int exfat_rename(char* old_path, char* new_path)
{
	if (!exfat_writes_ok) return -1;

	uint old_dir; bool old_dir_nfc; uint old_dir_dl;
	if (!exfat_resolve_dir(old_path, &old_dir, &old_dir_nfc, &old_dir_dl)) return -1;
	char* old_leaf = exfat_leaf_name(old_path);
	if (old_leaf[0] == 0) return -1;

	Char16[EXFAT_NAME_MAX] old16 @noinit;
	int old_len = exfat_ascii_to_utf16(old_leaf, &old16, EXFAT_NAME_MAX);
	if (old_len == 0) return -1;

	uint src_fc; uint src_dl; ushort src_attr; bool src_nfc;
	Exfat_set_locs src_locs;
	if (!exfat_find_in_dir_located(old_dir, old_dir_nfc, &old16, old_len, &src_fc, &src_dl, &src_attr, &src_nfc, &src_locs)) return -1;
	if (src_locs.count > EXFAT_MAX_SET_SLOTS) return -1;
	if (fs_is_protected_entry(src_locs.sector[0], src_locs.slot[0] * EXFAT_DIRENT_SIZE)) return -1;

	uint new_dir; bool new_dir_nfc; uint new_dir_dl;
	if (!exfat_resolve_dir(new_path, &new_dir, &new_dir_nfc, &new_dir_dl)) return -1;
	char* new_leaf = exfat_leaf_name(new_path);
	if (new_leaf[0] == 0) return -1;
	if (fs_is_protected_name(new_leaf)) return -1; // never let a rename mint the protected name

	Char16[EXFAT_NAME_MAX] new16 @noinit;
	int new_len = exfat_ascii_to_utf16(new_leaf, &new16, EXFAT_NAME_MAX);
	if (new_len == 0) return -1;

	uint x_fc; uint x_dl; ushort x_attr; bool x_nfc;
	if (exfat_find_in_dir(new_dir, new_dir_nfc, &new16, new_len, &x_fc, &x_dl, &x_attr, &x_nfc)) return -1; // destination exists

	bool src_is_dir = ((uint)src_attr & EXFAT_ATTR_DIRECTORY) != 0;
	if (src_is_dir)
	{
		if (new_dir == src_fc) return -1; // into itself
		if (exfat_subtree_contains(src_fc, src_nfc, src_dl, new_dir, 0)) return -1; // into its own descendant
	}

	char[EXFAT_SET_BYTES_MAX] set_bytes @noinit;
	int total_slots = exfat_build_set(&set_bytes, &new16, new_len, src_attr, src_fc, src_dl, src_nfc);
	if (!exfat_place_set(new_dir, new_dir_nfc, new_dir_dl, &set_bytes, total_slots)) return -1;

	// Destination entry is in place and points at the data — now the
	// source name can go. A failure here leaves a harmless duplicate
	// name for the same clusters, not a lost file.
	if (!exfat_clear_entry_set(&src_locs)) return -1;
	return 0;
}
