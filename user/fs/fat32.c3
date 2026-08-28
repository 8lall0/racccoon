module user;

// FAT32 backend for fsd (see user/fsd.c3's own header comment for the
// generic core / backend split). Standard, stable public spec — offsets
// below are the well-known FAT32 layout (same one Linux's fs/fat and
// every other FAT32 reader implements), not vendor-specific or
// reverse-engineered the way this project's SDHCI register maps were.
//
// Real VFAT long-filename (LFN) support: reads and writes standard
// Microsoft-defined LFN directory-entry chains alongside the 8.3 short
// name every entry still has (fat32_resolve_name11/fat32_lfn_feed/
// fat32_lfn_finish for reading, fat32_prepare_new_entry for writing —
// see their own comments). A name already exactly valid 8.3 form still
// gets a plain, LFN-free short entry exactly as before; only a name
// needing case-folding/truncation/invalid-character stripping gets a
// generated short-name alias plus a real LFN chain, matching what a
// real Windows/Linux/macOS FAT32 implementation would do. No general,
// whole-filesystem cache — every call still walks the
// relevant directory fresh (root, or a subdirectory reached via
// fat32_resolve_dir — see its own comment) and follows the matched
// file's cluster chain on demand, since there's no reasonable
// fixed-size cache for "however many files happen to be on someone's
// real SD card." The one exception is fat32_read_at's own single-slot
// exec()-loop cache (fat32_cache_path and friends, below) — narrowly
// scoped to "the one file the current chunked read is working through,"
// not a general directory/file cache; see its own comment.
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
const uint FAT32_BPB_FSINFO_SECTOR       = 0x30; // u16, sector number (partition-relative, same convention every other BPB-derived sector number here uses) of the FSInfo sector
const uint FAT32_BPB_SIGNATURE_OFFSET    = 0x1FE; // u16, must be 0xAA55 (little-endian 0x55,0xAA)

// FSInfo sector field offsets — free_count is a *hint*, not
// authoritative data (a real reader must be able to recompute it; see
// fat32_mount()'s own fallback), which is why fsck.vfat auto-corrects
// rather than errors when it's stale. next_free (offset 0x1EC) is real
// spec but unused here — fat32_alloc_cluster's own linear scan doesn't
// use a next-free hint, so nothing reads or writes it.
const uint FAT32_FSINFO_LEAD_SIG   = 0x000; // u32, must be 0x41615252
const uint FAT32_FSINFO_STRUC_SIG  = 0x1E4; // u32, must be 0x61417272
const uint FAT32_FSINFO_FREE_COUNT = 0x1E8; // u32, 0xFFFFFFFF means "unknown," must be recomputed
const uint FAT32_FSINFO_TRAIL_SIG  = 0x1FC; // u32, must be 0xAA550000

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

// VFAT long-filename (LFN) directory entry (32 bytes, same size as a
// real dirent — ATTR_LFN at the same offset as FAT32_DIRENT_ATTR marks
// it as one, and every reader that doesn't understand LFN — including
// this driver until now — sees exactly the same bytes and correctly
// skips them). Standard Microsoft VFAT extension, not vendor-specific:
// same layout every real FAT32 reader (Linux, Windows, macOS) uses.
// One entry holds 13 UTF-16LE code units of the name, split 5+6+2
// across three non-contiguous byte ranges (an original FAT32 dirent's
// own field layout — attr byte, "reserved" byte, cluster-lo — repurposed
// in place, which is why the ranges aren't contiguous).
const uint FAT32_LFN_SEQ        = 0x00; // u8: bits 0-4 = order (1-N), bit 0x40 = this is the LAST logical chunk of the name (the highest-numbered one), 0xE5 = a deleted LFN entry
const uint FAT32_LFN_NAME1      = 0x01; // 5 UTF-16LE chars (10 bytes)
const uint FAT32_LFN_ATTR       = 0x0B; // == FAT32_DIRENT_ATTR_LFN
const uint FAT32_LFN_TYPE       = 0x0C; // u8, must be 0 for a real LFN entry
const uint FAT32_LFN_CHECKSUM   = 0x0D; // u8, checksum of the short name this chain belongs to — see fat32_short_name_checksum
const uint FAT32_LFN_NAME2      = 0x0E; // 6 UTF-16LE chars (12 bytes)
const uint FAT32_LFN_CLUSTER_LO = 0x1A; // u16, always 0 for an LFN entry
const uint FAT32_LFN_NAME3      = 0x1C; // 2 UTF-16LE chars (4 bytes)

const uint FAT32_LFN_SEQ_LAST_BIT  = 0x40;
const uint FAT32_LFN_SEQ_NUM_MASK  = 0x1F;
const uint FAT32_LFN_CHARS_PER_ENTRY = 13;
// Real VFAT allows up to 20 entries (255 UTF-16 units); this driver
// caps well below that — comfortably past any realistic real-world
// filename, while keeping every LFN buffer this file holds small and
// fixed-size, same "generous but bounded" convention as e.g.
// NS_PREFIX_MAX/EXEC_MAX_ARGV_SIZE elsewhere in this project. A name
// needing more entries than this cap allows is treated as if it had no
// usable long name at all (falls back to its short-name form) rather
// than truncated silently.
const int FAT32_LFN_NAME_MAX = 128;
const int FAT32_LFN_MAX_ENTRIES = FAT32_LFN_NAME_MAX / FAT32_LFN_CHARS_PER_ENTRY;

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
uint fat32_fsinfo_sector; // partition-relative, same convention as fat32_fat_start_sector etc.
uint fat32_free_count;    // kept in sync with every alloc/free (fat32_alloc_cluster/fat32_free_cluster_chain), written back to the FSInfo sector on each change — see fat32_write_free_count's own comment

// exec()'s own chunked-read fast path (user/user.c3's exec(), FS_READ_AT)
// — same shape and reasoning as ext2's own ext2_cache_* (user/fs/ext2.c3,
// see its own comment), plus a second piece FAT32 specifically needs:
// unlike ext2's i_block[] array (an O(1) index lookup), FAT32 has no way
// to reach cluster N except by following N links from a known start, so
// caching just the file's identity (first_cluster/file_size) isn't
// enough to avoid re-walking the whole chain from scratch on every
// ~1124-byte chunk — fat32_cache_resume_offset/fat32_cache_resume_cluster
// remember the furthest cluster boundary the walk has reached so far,
// a live cursor fat32_read_file_at advances as it goes (see its own
// comment), not just a value set once per call. Every FAT32 mutation
// (fat32_write/delete/delete_recursive/mkdir/rename) invalidates this
// unconditionally, same reasoning ext2's own cache invalidation uses.
bool      fat32_cache_valid;
char[100] fat32_cache_path;      // exact bytes — 100 matches fsd.c3's own filename wire-field size, same precedent ext2_cache_path uses
uint      fat32_cache_first_cluster;
uint      fat32_cache_file_size;
uint      fat32_cache_resume_offset;  // cluster-aligned: a multiple of cluster_size
uint      fat32_cache_resume_cluster; // the cluster containing fat32_cache_resume_offset

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
// extension characters — the plain 8.3 conversion, still used directly
// for a name that's already valid short form, or as the base a long
// name's own generated alias is built from (fat32_prepare_new_entry);
// a name that needs a real LFN chain never reaches a reader as this
// truncated form, see this file's own header comment.
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

// Converts an 11-byte raw short name (space-padded, as stored on disk)
// into ordinary "name.ext" display form — e.g. "HELLO   TXT" becomes
// "HELLO.TXT". The fallback display/matching form for any entry with
// no valid LFN chain in front of it.
fn void fat32_short_name_to_display(char* name11, char* out_name)
{
	int ni = 0;
	for (int k = 0; k < 8 && name11[k] != ' '; k++)
	{
		out_name[ni] = name11[k];
		ni++;
	}
	if (name11[8] != ' ')
	{
		out_name[ni] = '.';
		ni++;
		for (int k = 8; k < 11 && name11[k] != ' '; k++)
		{
			out_name[ni] = name11[k];
			ni++;
		}
	}
	out_name[ni] = 0;
}

// Case-insensitive comparison — FAT's own name matching always is,
// long name or short.
fn bool fat32_name_eq_ci(char* a, char* b)
{
	int i = 0;
	while (a[i] != 0 && b[i] != 0)
	{
		char ca = a[i];
		char cb = b[i];
		if (ca >= 'a' && ca <= 'z') ca = (char)(ca - 'a' + 'A');
		if (cb >= 'a' && cb <= 'z') cb = (char)(cb - 'a' + 'A');
		if (ca != cb) return false;
		i++;
	}
	return a[i] == b[i];
}

// Standard Microsoft VFAT short-name checksum — every LFN entry in a
// chain carries this same value (computed over the short name the
// chain belongs to), and a real reader must verify it before trusting
// a reconstructed long name: an LFN chain surviving in front of an
// unrelated short entry that later reused its old slot would otherwise
// be misattributed to it.
fn char fat32_short_name_checksum(char* name11)
{
	uint sum = 0;
	for (int i = 0; i < 11; i++)
	{
		uint c = (uint)name11[i] & 0xFF;
		sum = (((sum & 1) != 0) ? 0x80 : 0) + (sum >> 1) + c;
		sum = sum & 0xFF;
	}
	return (char)sum;
}

// Extracts one LFN entry's own 13 UTF-16LE character slots into buf13
// (ASCII only — see this file's own header comment on character-set
// scope). A slot holding 0x0000 (the name's real terminator) or 0xFFFF
// (post-terminator padding) becomes a plain 0 byte in buf13 — both
// mean "no more real characters here," and the caller only ever cares
// about the position of the first 0 once the whole chain is
// assembled, not which sentinel produced it. Returns false (buf13
// undefined) if any slot holds a genuine non-ASCII UTF-16 character —
// the whole entry, and by extension the chain it belongs to, is
// unusable, not just that one character.
fn bool fat32_lfn_entry_chars(char* entry, char* buf13)
{
	bool ok = true;
	for (uint i = 0; i < 5; i++)
	{
		ushort* u = (ushort*)&entry[FAT32_LFN_NAME1 + i * 2];
		uint v = (uint)*u;
		if (v == 0 || v == 0xFFFF) { buf13[i] = 0; }
		else if (v > 0x7E) { buf13[i] = 0; ok = false; }
		else { buf13[i] = (char)v; }
	}
	for (uint i = 0; i < 6; i++)
	{
		ushort* u = (ushort*)&entry[FAT32_LFN_NAME2 + i * 2];
		uint v = (uint)*u;
		if (v == 0 || v == 0xFFFF) { buf13[5 + i] = 0; }
		else if (v > 0x7E) { buf13[5 + i] = 0; ok = false; }
		else { buf13[5 + i] = (char)v; }
	}
	for (uint i = 0; i < 2; i++)
	{
		ushort* u = (ushort*)&entry[FAT32_LFN_NAME3 + i * 2];
		uint v = (uint)*u;
		if (v == 0 || v == 0xFFFF) { buf13[11 + i] = 0; }
		else if (v > 0x7E) { buf13[11 + i] = 0; ok = false; }
		else { buf13[11 + i] = (char)v; }
	}
	return ok;
}

// Called for each LFN entry (attr==FAT32_DIRENT_ATTR_LFN) encountered
// while scanning a directory, in on-disk order (highest sequence
// number — the logically LAST chunk of the name — first, descending to
// 1 immediately before the short entry, per spec). Updates the
// caller's own accumulation state (lfn_buf/io_expected_seq/
// io_checksum/io_valid) in place; the caller reads it back via
// fat32_lfn_finish() once the following short entry is reached. A
// fresh "last" entry always resets any in-progress accumulation, even
// a broken one — a real reader must never blend two chains.
fn void fat32_lfn_feed(char* entry, char* lfn_buf, int* io_expected_seq, char* io_checksum, bool* io_valid)
{
	char raw_seq = entry[FAT32_LFN_SEQ];
	if (raw_seq == FAT32_DIRENT_DELETED)
	{
		*io_valid = false;
		return;
	}

	bool is_last = ((uint)raw_seq & FAT32_LFN_SEQ_LAST_BIT) != 0;
	int seq = (int)((uint)raw_seq & FAT32_LFN_SEQ_NUM_MASK);

	if (is_last)
	{
		if (seq < 1 || seq > FAT32_LFN_MAX_ENTRIES)
		{
			*io_valid = false;
			return;
		}
		char[13] chars @noinit;
		if (!fat32_lfn_entry_chars(entry, &chars))
		{
			*io_valid = false;
			return;
		}
		for (int i = 0; i < 13; i++) lfn_buf[(seq - 1) * 13 + i] = chars[i];
		*io_checksum = entry[FAT32_LFN_CHECKSUM];
		*io_expected_seq = seq - 1;
		*io_valid = true;
		return;
	}

	if (!*io_valid || seq != *io_expected_seq || entry[FAT32_LFN_CHECKSUM] != *io_checksum)
	{
		*io_valid = false;
		return;
	}
	char[13] chars @noinit;
	if (!fat32_lfn_entry_chars(entry, &chars))
	{
		*io_valid = false;
		return;
	}
	for (int i = 0; i < 13; i++) lfn_buf[(seq - 1) * 13 + i] = chars[i];
	*io_expected_seq = seq - 1;
}

// Called for the real (non-LFN) entry immediately following whatever
// LFN accumulation (if any) preceded it — validates the accumulated
// chain (only if it reached all the way down to seq 1, io_expected_seq
// == 0) against this entry's own short-name checksum, and writes the
// resolved display/matching name into out_name: the reconstructed long
// name if the chain checks out, otherwise the short name converted to
// ordinary "name.ext" form.
fn void fat32_lfn_finish(char* short_entry, char* lfn_buf, int expected_seq, char checksum, bool valid, char* out_name)
{
	if (valid && expected_seq == 0 && checksum == fat32_short_name_checksum(&short_entry[FAT32_DIRENT_NAME]))
	{
		int len = 0;
		while (len < FAT32_LFN_NAME_MAX - 1 && lfn_buf[len] != 0) len++;
		for (int i = 0; i < len; i++) out_name[i] = lfn_buf[i];
		out_name[len] = 0;
		return;
	}
	fat32_short_name_to_display(&short_entry[FAT32_DIRENT_NAME], out_name);
}

// Scans dir_cluster's own directory for an entry whose real name —
// either its reconstructed long name (if a valid LFN chain precedes
// it) or its short-name-derived display form — matches raw_name
// case-insensitively. On a match, fills out_name11 with that entry's
// own raw 11-byte short name — ready for the existing, unchanged
// fat32_find_in_dir/fat32_find_in_root, which every caller of this
// function still calls right afterward exactly as before, just with
// this as the name-resolution step instead of a bare
// fat32_name_to_8_3(). Also fills out_lfn_entry_sector/
// out_lfn_entry_offset with the FIRST LFN entry's own location if one
// preceded the match (0/0 if the match had no LFN chain at all), so
// fat32_delete/fat32_rename can remove the whole chain instead of
// leaving orphaned LFN entries behind — real corruption from any other
// real FAT32 reader's point of view. Returns false if nothing matches
// at all; every caller already falls back to fat32_name_to_8_3's own
// naive conversion in that case, the only sane name to use for e.g.
// "does this file exist yet" before creating one.
fn bool fat32_resolve_name11(uint dir_cluster, char* raw_name, char* out_name11, uint* out_lfn_entry_sector, uint* out_lfn_entry_offset)
{
	uint cluster = dir_cluster;
	char[SECTOR_SIZE] sector_buf @noinit;

	char[FAT32_LFN_NAME_MAX] lfn_buf @noinit;
	int lfn_expected_seq = 0;
	char lfn_checksum = 0;
	bool lfn_valid = false;
	uint lfn_start_sector = 0;
	uint lfn_start_offset = 0;
	bool lfn_have_start = false;

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
				if (entry[0] == FAT32_DIRENT_DELETED)
				{
					lfn_valid = false;
					lfn_have_start = false;
					continue;
				}

				char attr = entry[FAT32_DIRENT_ATTR];
				if (attr == FAT32_DIRENT_ATTR_LFN)
				{
					bool is_last = ((uint)entry[FAT32_LFN_SEQ] & FAT32_LFN_SEQ_LAST_BIT) != 0;
					if (is_last) { lfn_have_start = false; }
					if (!lfn_have_start)
					{
						lfn_start_sector = sector + s;
						lfn_start_offset = e * FAT32_DIRENT_SIZE;
						lfn_have_start = true;
					}
					fat32_lfn_feed(entry, &lfn_buf, &lfn_expected_seq, &lfn_checksum, &lfn_valid);
					continue;
				}
				if ((attr & FAT32_DIRENT_ATTR_VOLUME) != 0)
				{
					lfn_valid = false;
					lfn_have_start = false;
					continue;
				}

				char[FAT32_LFN_NAME_MAX] display @noinit;
				fat32_lfn_finish(entry, &lfn_buf, lfn_expected_seq, lfn_checksum, lfn_valid, &display);
				bool had_lfn = lfn_valid && lfn_expected_seq == 0;
				bool this_have_start = lfn_have_start;
				lfn_valid = false;
				lfn_have_start = false;

				if (fat32_name_eq_ci(raw_name, &display))
				{
					for (uint k = 0; k < 11; k++) out_name11[k] = entry[FAT32_DIRENT_NAME + k];
					if (had_lfn && this_have_start)
					{
						*out_lfn_entry_sector = lfn_start_sector;
						*out_lfn_entry_offset = lfn_start_offset;
					}
					else
					{
						*out_lfn_entry_sector = 0;
						*out_lfn_entry_offset = 0;
					}
					return true;
				}
			}
		}
		cluster = fat32_next_cluster(cluster);
	}
	return false;
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
			uint seg_lfn_sector; uint seg_lfn_offset;
			if (!fat32_resolve_name11(dir_cluster, &seg_buf, &seg11, &seg_lfn_sector, &seg_lfn_offset))
			{
				fat32_name_to_8_3(&seg_buf, &seg11);
			}

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
	uint dummy_lfn_sector; uint dummy_lfn_offset;
	if (!fat32_resolve_name11(dir_cluster, leaf, &name11, &dummy_lfn_sector, &dummy_lfn_offset))
	{
		fat32_name_to_8_3(leaf, &name11);
	}

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

// Same chain-walk as fat32_read_file, but starts copying from `offset`
// bytes into the file instead of from the beginning — skips whole
// clusters via fat32_next_cluster() until reaching the one containing
// `offset`, then whole sectors within it, then a partial-sector byte
// skip for the very first sector actually copied from (every
// subsequent sector copies from its own start normally). A fully
// separate function from fat32_read_file rather than adding an offset
// parameter there, so the existing, heavily-exercised offset-0 read
// path stays completely untouched. Built for exec()'s own chunked
// reads (user/user.c3) — real binaries (70-105KB) are far larger than
// one FS_MSG_MAX (1128 bytes) IPC message, so loading one needs
// repeated calls advancing this offset, not a single fat32_read().
//
// Resumes from fat32_cache_resume_cluster/fat32_cache_resume_offset
// (fat32_read_at's own cache, see its declaration's comment) instead of
// always walking from first_cluster — the skip-phase loop below only
// runs at all for however far past the cached position `offset` still
// reaches, zero times once a file's already been resolved once and
// subsequent chunks land in the same cluster the cache already points
// at. Only ever called from fat32_read_at, so reads/writes that cache's
// global fields directly rather than threading them through as
// parameters — same shape ext2_cache_* uses.
fn uint fat32_read_file_at(uint first_cluster, char* dst, uint len, uint offset)
{
	uint cluster_size = fat32_sectors_per_cluster * SECTOR_SIZE;

	uint cluster;
	uint cluster_start_offset; // the file offset `cluster`'s own first byte sits at
	if (offset >= fat32_cache_resume_offset)
	{
		cluster = fat32_cache_resume_cluster;
		cluster_start_offset = fat32_cache_resume_offset;
	}
	else
	{
		cluster = first_cluster;
		cluster_start_offset = 0;
	}

	while (cluster_start_offset + cluster_size <= offset && cluster != 0 && cluster < FAT32_EOC_MIN)
	{
		cluster = fat32_next_cluster(cluster);
		cluster_start_offset += cluster_size;
	}
	fat32_cache_resume_cluster = cluster;
	fat32_cache_resume_offset = cluster_start_offset;

	uint offset_in_cluster = offset - cluster_start_offset;
	uint sectors_to_skip = offset_in_cluster / SECTOR_SIZE;
	uint skip_in_sector = offset_in_cluster % SECTOR_SIZE; // only ever applies to the first sector actually read

	uint bytes_read = 0;
	char[SECTOR_SIZE] sector_buf @noinit;
	bool at_start = true;

	while (cluster != 0 && cluster < FAT32_EOC_MIN && bytes_read < len)
	{
		uint sector = fat32_cluster_to_sector(cluster);
		uint start_s = at_start ? sectors_to_skip : 0;
		for (uint s = start_s; s < fat32_sectors_per_cluster && bytes_read < len; s++)
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
		// Deliberately checked *before* advancing (unlike a plain
		// unconditional advance at the bottom of the loop, which would
		// still run once more here purely as a structural side effect
		// of the outer while's own re-check): caching a cluster this
		// call never actually needed to reach would overshoot past
		// wherever the *next* call's own offset lands, turning every
		// future call into a cache miss instead of a hit — see this
		// function's own header comment.
		if (bytes_read >= len) break;
		cluster = fat32_next_cluster(cluster);
		cluster_start_offset += cluster_size;
		fat32_cache_resume_cluster = cluster;
		fat32_cache_resume_offset = cluster_start_offset;
	}
	return bytes_read;
}

// Entry point dispatched from fsd.c3's main() for FS_READ_AT — same
// lookup shape as fat32_read above, but returns 0 (not -1) once
// `offset` reaches or passes the file's own size, the "clean EOF"
// signal exec()'s own chunked-read loop watches for to know when to
// stop, distinct from -1's "something is actually wrong" (not found,
// or a directory).
fn int fat32_read_at(char* name, char* dst, uint len, uint offset)
{
	uint first_cluster;
	uint file_size;

	// Cache hit: exec()'s own chunked-read loop (user/user.c3) calls
	// this repeatedly for the same path — see fat32_cache_path's own
	// comment.
	if (fat32_cache_valid && strcmp(name, &fat32_cache_path) == 0)
	{
		first_cluster = fat32_cache_first_cluster;
		file_size = fat32_cache_file_size;
	}
	else
	{
		uint dir_cluster;
		if (!fat32_resolve_dir(name, &dir_cluster)) return -1;
		char* leaf = fat32_leaf_name(name);

		char[11] name11 @noinit;
		uint dummy_lfn_sector; uint dummy_lfn_offset;
		if (!fat32_resolve_name11(dir_cluster, leaf, &name11, &dummy_lfn_sector, &dummy_lfn_offset))
		{
			fat32_name_to_8_3(leaf, &name11);
		}

		uint dummy_sector;
		uint dummy_offset;
		char attr;
		if (!fat32_find_in_dir(dir_cluster, &name11, &first_cluster, &file_size, &dummy_sector, &dummy_offset, &attr))
		{
			return -1;
		}
		if ((attr & FAT32_DIRENT_ATTR_DIRECTORY) != 0) return -1;

		uint fc_i = 0;
		while (name[fc_i] != 0 && fc_i < 99) { fat32_cache_path[fc_i] = name[fc_i]; fc_i++; }
		fat32_cache_path[fc_i] = 0;
		fat32_cache_first_cluster = first_cluster;
		fat32_cache_file_size = file_size;
		// A newly-cached file has no walk history yet — must start
		// fat32_read_file_at's own resume point from this file's own
		// beginning, not wherever the *previous* cached file's cluster
		// walk happened to leave off.
		fat32_cache_resume_offset = 0;
		fat32_cache_resume_cluster = first_cluster;
		fat32_cache_valid = true;
	}

	if (offset >= file_size) return 0;

	uint remaining = file_size - offset;
	uint read_len = len;
	if (read_len > remaining) read_len = remaining;

	return (int)fat32_read_file_at(first_cluster, dst, read_len, offset);
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
			fat32_free_count -= 1;
			fat32_write_free_count(); // best-effort — see its own comment
			return cluster;
		}
	}
	return 0;
}

// Writes fat32_free_count back to the FSInfo sector — called by
// fat32_alloc_cluster/fat32_free_cluster_chain after they change it, and
// once at mount time after fat32_mount() establishes the starting value
// (either trusted from disk or freshly recomputed). Return value is
// deliberately never propagated as its caller's own failure: by the
// time either call site above calls this, the *authoritative* state —
// the FAT table entry itself — has already been successfully written.
// free_count is explicitly a hint (fsck.vfat recomputes and silently
// corrects it, never errors on a stale one), and failing the whole
// alloc/free operation because this secondary write failed would be
// strictly worse — the caller would believe the alloc/free itself never
// happened while the real, authoritative FAT entry already changed,
// exactly the kind of inconsistency this driver works to avoid
// everywhere else. Best-effort here is the correctness-preserving
// choice, not a shortcut.
fn bool fat32_write_free_count()
{
	char[SECTOR_SIZE] fsinfo_buf @noinit;
	if (!fs_read_sector(fat32_fsinfo_sector, &fsinfo_buf)) return false;
	uint* free_count_field = (uint*)&fsinfo_buf[FAT32_FSINFO_FREE_COUNT];
	*free_count_field = fat32_free_count;
	return fs_write_sector(fat32_fsinfo_sector, &fsinfo_buf);
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

// Generalizes fat32_find_free_dirent (above) to find `count` CONSECUTIVE
// free (or deleted) slots — needed for a long name's own LFN entries
// plus its short entry, which must all sit contiguously for any real
// FAT32 reader to recognize the chain (nothing tells it a chain
// continues across a gap). A run is never allowed to span a cluster
// boundary, even though clusters aren't necessarily physically
// adjacent on disk (a real, if rare, correctness hazard a run that did
// span one would hit) — resetting the run at the start of every
// cluster costs a little potential reuse of an oddly-fragmented
// directory's free space, in exchange for never needing to reason
// about non-contiguous physical sectors here at all. Extends the
// directory with one freshly zero-filled cluster if no existing run is
// long enough — the same "extend on demand" shape
// fat32_create_file/fat32_mkdir/fat32_rename each already do inline
// for a single slot, generalized once here instead of a fourth
// near-duplicate. One fresh cluster is always enough: every real
// volume has at least 16 slots per sector, comfortably past
// FAT32_LFN_MAX_ENTRIES+1.
fn bool fat32_find_free_dirent_range(uint dir_cluster, int count, uint* out_entry_sector, uint* out_entry_offset)
{
	uint cluster = dir_cluster;
	uint last_cluster = dir_cluster;

	while (cluster != 0 && cluster < FAT32_EOC_MIN)
	{
		last_cluster = cluster;
		uint sector = fat32_cluster_to_sector(cluster);
		int run_len = 0;
		uint run_sector = 0;
		uint run_offset = 0;
		for (uint s = 0; s < fat32_sectors_per_cluster; s++)
		{
			char[SECTOR_SIZE] sector_buf @noinit;
			if (!fs_read_sector(sector + s, &sector_buf)) return false;

			for (uint e = 0; e < SECTOR_SIZE / FAT32_DIRENT_SIZE; e++)
			{
				char* entry = &sector_buf[e * FAT32_DIRENT_SIZE];
				bool free = entry[0] == FAT32_DIRENT_FREE_REST || entry[0] == FAT32_DIRENT_DELETED;
				if (free)
				{
					if (run_len == 0)
					{
						run_sector = sector + s;
						run_offset = e * FAT32_DIRENT_SIZE;
					}
					run_len++;
					if (run_len >= count)
					{
						*out_entry_sector = run_sector;
						*out_entry_offset = run_offset;
						return true;
					}
				}
				else
				{
					run_len = 0;
				}
			}
		}
		cluster = fat32_next_cluster(cluster);
	}

	uint new_cluster = fat32_alloc_cluster();
	if (new_cluster == 0) return false;
	char[SECTOR_SIZE] zero_buf @noinit;
	for (uint i = 0; i < SECTOR_SIZE; i++) zero_buf[i] = 0;
	for (uint s = 0; s < fat32_sectors_per_cluster; s++)
	{
		if (!fs_write_sector(fat32_cluster_to_sector(new_cluster) + s, &zero_buf)) return false;
	}
	if (!fat32_write_fat_entry(last_cluster, new_cluster)) return false;
	if (!fat32_write_fat_entry(new_cluster, FAT32_EOC_MIN)) return false;
	*out_entry_sector = fat32_cluster_to_sector(new_cluster);
	*out_entry_offset = 0;
	return true;
}

// Prepares a directory entry slot for a brand-new file/directory named
// raw_name inside dir_cluster: if raw_name is already exactly valid
// 8.3 short-name form (checked by round-tripping it through
// fat32_name_to_8_3 and back through fat32_short_name_to_display — an
// exact match means no case-folding/truncation/invalid characters were
// needed), no LFN entries are written at all and this is exactly
// today's existing single-slot behavior, just reached from here.
// Otherwise generates a unique short-name alias using the standard MS
// "numeric tail" scheme (up to 6 base characters + "~1"/"~2"/... on a
// real collision, found by probing fat32_find_in_dir directly + up to
// 3 extension characters), finds enough consecutive free slots for the
// LFN chain plus the short entry (fat32_find_free_dirent_range above),
// writes the LFN entries (highest sequence number — the logically LAST
// chunk of the name — first, descending to 1 immediately before the
// short entry, per spec), and returns the short entry's own (sector,
// offset) for the caller to populate exactly like
// fat32_create_file/fat32_mkdir already do today, unchanged.
fn bool fat32_prepare_new_entry(uint dir_cluster, char* raw_name, char* out_name11, uint* out_entry_sector, uint* out_entry_offset)
{
	char[11] plain_name11 @noinit;
	fat32_name_to_8_3(raw_name, &plain_name11);
	char[16] roundtrip @noinit;
	fat32_short_name_to_display(&plain_name11, &roundtrip);
	if (strcmp(raw_name, &roundtrip) == 0)
	{
		for (int i = 0; i < 11; i++) out_name11[i] = plain_name11[i];
		return fat32_find_free_dirent_range(dir_cluster, 1, out_entry_sector, out_entry_offset);
	}

	// Alias generation: up to 6 base characters + "~N" + up to 3
	// extension characters. Invalid-in-8.3 characters were already
	// dropped by fat32_name_to_8_3 above (plain_name11 reused as the
	// base/extension source) — good enough for this driver's own real
	// use (ASCII names with spaces/long extensions/multiple dots), not
	// a byte-for-byte reproduction of every real Windows edge case.
	bool found_alias = false;
	for (int tail = 1; tail <= 999 && !found_alias; tail++)
	{
		char[4] rev @noinit;
		int rev_len = 0;
		int t = tail;
		while (t > 0) { rev[rev_len] = (char)('0' + (t % 10)); rev_len++; t /= 10; }

		char[11] candidate @noinit;
		for (int i = 0; i < 11; i++) candidate[i] = ' ';
		int base_chars = 6 - rev_len;
		if (base_chars < 1) base_chars = 1;
		int ci = 0;
		for (int i = 0; i < base_chars && plain_name11[i] != ' '; i++) { candidate[ci] = plain_name11[i]; ci++; }
		candidate[ci] = '~'; ci++;
		for (int i = rev_len - 1; i >= 0; i--) { candidate[ci] = rev[i]; ci++; }
		for (int i = 8; i < 11; i++) candidate[i] = plain_name11[i];

		uint dummy_cluster; uint dummy_size; uint dummy_sector; uint dummy_offset; char dummy_attr;
		if (!fat32_find_in_dir(dir_cluster, &candidate, &dummy_cluster, &dummy_size, &dummy_sector, &dummy_offset, &dummy_attr))
		{
			for (int i = 0; i < 11; i++) out_name11[i] = candidate[i];
			found_alias = true;
		}
	}
	if (!found_alias) return false; // exhausted — an implausible number of colliding names

	int name_len = 0;
	while (raw_name[name_len] != 0) name_len++;
	int entries_needed = (name_len + (int)FAT32_LFN_CHARS_PER_ENTRY) / (int)FAT32_LFN_CHARS_PER_ENTRY; // ceil((name_len+1)/13) — +1 for the terminator
	if (entries_needed < 1) entries_needed = 1;
	if (entries_needed > FAT32_LFN_MAX_ENTRIES) return false; // longer than this driver's own bounded cap — see FAT32_LFN_NAME_MAX

	uint entry_sector; uint entry_offset;
	if (!fat32_find_free_dirent_range(dir_cluster, entries_needed + 1, &entry_sector, &entry_offset)) return false;

	char checksum = fat32_short_name_checksum(out_name11);

	for (int seq = entries_needed; seq >= 1; seq--)
	{
		char[SECTOR_SIZE] sector_buf @noinit;
		if (!fs_read_sector(entry_sector, &sector_buf)) return false;
		char* entry = &sector_buf[entry_offset];

		char seq_byte = (char)seq;
		if (seq == entries_needed) seq_byte = (char)((uint)seq_byte | FAT32_LFN_SEQ_LAST_BIT);
		entry[FAT32_LFN_SEQ] = seq_byte;
		entry[FAT32_LFN_ATTR] = FAT32_DIRENT_ATTR_LFN;
		entry[FAT32_LFN_TYPE] = 0;
		entry[FAT32_LFN_CHECKSUM] = checksum;
		ushort* cluster_lo = (ushort*)&entry[FAT32_LFN_CLUSTER_LO];
		*cluster_lo = 0;

		int base = (seq - 1) * (int)FAT32_LFN_CHARS_PER_ENTRY;
		for (uint i = 0; i < 5; i++)
		{
			ushort* u = (ushort*)&entry[FAT32_LFN_NAME1 + i * 2];
			int idx = base + (int)i;
			*u = idx < name_len ? (ushort)(uint)raw_name[idx] : (idx == name_len ? (ushort)0 : (ushort)0xFFFF);
		}
		for (uint i = 0; i < 6; i++)
		{
			ushort* u = (ushort*)&entry[FAT32_LFN_NAME2 + i * 2];
			int idx = base + 5 + (int)i;
			*u = idx < name_len ? (ushort)(uint)raw_name[idx] : (idx == name_len ? (ushort)0 : (ushort)0xFFFF);
		}
		for (uint i = 0; i < 2; i++)
		{
			ushort* u = (ushort*)&entry[FAT32_LFN_NAME3 + i * 2];
			int idx = base + 11 + (int)i;
			*u = idx < name_len ? (ushort)(uint)raw_name[idx] : (idx == name_len ? (ushort)0 : (ushort)0xFFFF);
		}

		if (!fs_write_sector(entry_sector, &sector_buf)) return false;

		// Advance to the next slot (the next LFN entry going toward
		// seq-1, or the short entry once seq reaches 1) — a plain
		// fixed 32-byte stride with sector-boundary wraparound, never a
		// *cluster* boundary: fat32_find_free_dirent_range's own range
		// never crosses one (see its own comment), so raw sector-number
		// arithmetic is safe here.
		entry_offset += FAT32_DIRENT_SIZE;
		if (entry_offset >= SECTOR_SIZE)
		{
			entry_offset = 0;
			entry_sector += 1;
		}
	}

	*out_entry_sector = entry_sector;
	*out_entry_offset = entry_offset;
	return true;
}

// Creates a new, empty (zero-size) directory entry for raw_name inside
// dir_cluster (root or a subdirectory) and allocates its first data
// cluster. fat32_prepare_new_entry (above) does the actual slot-finding
// (generating a short-name alias and writing a real LFN chain first if
// raw_name needs one, extending dir_cluster's own chain with a fresh
// zero-filled cluster if it has no room — a directory cluster's bytes
// are always interpreted as entries, unlike file data past the
// declared size, which is never exposed to a reader, so this really
// does need zero-filling for correctness, not just tidiness) — this
// function just populates the short entry itself, unchanged from
// before. out_name11 is the actual short name written (== raw_name's
// own 8.3 form when no LFN was needed) — the caller (fat32_write) needs
// it for its own follow-up lookup after this returns.
fn bool fat32_create_file(uint dir_cluster, char* raw_name, char* out_name11, uint* out_first_cluster)
{
	uint first_cluster = fat32_alloc_cluster();
	if (first_cluster == 0) return false;

	uint entry_sector;
	uint entry_offset;
	if (!fat32_prepare_new_entry(dir_cluster, raw_name, out_name11, &entry_sector, &entry_offset)) return false;

	// Defense in depth — see fs_is_protected_entry's own comment in
	// fsd.c3. Structurally unreachable in practice: fat32_prepare_new_entry
	// only ever returns a free/deleted slot, and a protected file's real
	// entry is neither, so this would require a bug in that scan to ever
	// fire.
	if (fs_is_protected_entry(entry_sector, entry_offset)) return false;

	char[SECTOR_SIZE] sector_buf @noinit;
	if (!fs_read_sector(entry_sector, &sector_buf)) return false;

	char* entry = &sector_buf[entry_offset];
	for (uint i = 0; i < 11; i++) entry[FAT32_DIRENT_NAME + i] = out_name11[i];
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

// Offset-aware counterpart to fat32_write_file — writes `len` bytes of
// `src` starting `offset` bytes into first_cluster's chain: walks (and
// extends, one cluster at a time) to the cluster holding `offset`, then
// writes forward from there, extending the chain as it goes. Alongside,
// not replacing, fat32_write_file (still used unchanged by the whole-
// file fat32_write) — the same "keep the heavily-exercised offset-0 path
// untouched" split fat32_read_file_at / ext2_write_file_at both made.
// The caller owns the directory entry's size field (fat32_write_at sets
// it to max(old, offset + written)); this touches only cluster data and
// FAT links. Returns bytes actually written — short on a genuine failure
// (out of space, I/O error) partway through.
fn uint fat32_write_file_at(uint first_cluster, char* src, uint len, uint offset)
{
	uint cluster_size = fat32_sectors_per_cluster * SECTOR_SIZE;

	// Walk to the cluster holding `offset`, allocating + linking if the
	// chain is currently shorter — only reachable for an aligned append
	// (fat32_write_at already rejected offset > size, so at most the one
	// cluster right at the current end can be missing).
	uint cluster = first_cluster;
	uint cluster_start = 0;
	while (cluster_start + cluster_size <= offset)
	{
		uint next = fat32_next_cluster(cluster);
		if (next >= FAT32_EOC_MIN)
		{
			next = fat32_alloc_cluster();
			if (next == 0) return 0;
			if (!fat32_write_fat_entry(cluster, next)) return 0;
			if (!fat32_write_fat_entry(next, FAT32_EOC_MIN)) return 0;
		}
		cluster = next;
		cluster_start += cluster_size;
	}

	uint in_cluster = offset - cluster_start;
	uint skip_s = in_cluster / SECTOR_SIZE;
	uint skip_in_s = in_cluster % SECTOR_SIZE; // first written sector only
	uint bytes_written = 0;
	char[SECTOR_SIZE] sector_buf @noinit;
	bool at_start = true;

	while (bytes_written < len)
	{
		uint sector = fat32_cluster_to_sector(cluster);
		uint start_s = at_start ? skip_s : 0;
		for (uint s = start_s; s < fat32_sectors_per_cluster && bytes_written < len; s++)
		{
			uint soff = (at_start && s == skip_s) ? skip_in_s : 0;
			uint chunk = len - bytes_written;
			if (chunk > SECTOR_SIZE - soff) chunk = SECTOR_SIZE - soff;
			// Read-modify-write any partially touched sector, same
			// read-what's-really-there discipline fat32_write_file has.
			if (soff != 0 || chunk < SECTOR_SIZE)
			{
				if (!fs_read_sector(sector + s, &sector_buf)) return bytes_written;
			}
			for (uint i = 0; i < chunk; i++) sector_buf[soff + i] = src[bytes_written + i];
			if (!fs_write_sector(sector + s, &sector_buf)) return bytes_written;
			bytes_written += chunk;
		}
		at_start = false;
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
	fat32_cache_valid = false; // see fat32_cache_path's own comment
	uint dir_cluster;
	if (!fat32_resolve_dir(name, &dir_cluster)) return -1;
	char* leaf = fat32_leaf_name(name);
	if (leaf[0] == 0) return -1; // "" or a trailing slash — no name to write

	char[11] name11 @noinit;
	uint dummy_lfn_sector; uint dummy_lfn_offset;
	bool resolved = fat32_resolve_name11(dir_cluster, leaf, &name11, &dummy_lfn_sector, &dummy_lfn_offset);
	if (!resolved) fat32_name_to_8_3(leaf, &name11);

	uint cluster;
	uint size;
	uint entry_sector;
	uint entry_offset;
	char attr;
	bool exists = resolved && fat32_find_in_dir(dir_cluster, &name11, &cluster, &size, &entry_sector, &entry_offset, &attr);
	// A directory isn't file content — refuse rather than overwrite
	// whatever it points at, same refusal fat32_read gives.
	if (exists && (attr & FAT32_DIRENT_ATTR_DIRECTORY) != 0) return -1;

	if (!exists)
	{
		if (!fat32_create_file(dir_cluster, leaf, &name11, &cluster)) return -1;
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

// Entry point dispatched from fsd.c3 for FS_WRITE_AT — offset-aware:
// overwrite bytes anywhere in the file, or append at the current end.
// Same resolve / create-if-missing / relocate-to-update-size shape as
// fat32_write, plus the no-holes rule (offset > current size rejected,
// offset != 0 on a file that doesn't exist yet rejected). The entry's
// size grows to max(old, offset + written), never shrinks.
fn int fat32_write_at(char* name, char* src, uint len, uint offset)
{
	fat32_cache_valid = false; // see fat32_cache_path's own comment
	uint dir_cluster;
	if (!fat32_resolve_dir(name, &dir_cluster)) return -1;
	char* leaf = fat32_leaf_name(name);
	if (leaf[0] == 0) return -1; // no name to write to (e.g. "" or a trailing slash)

	char[11] name11 @noinit;
	uint dummy_lfn_sector; uint dummy_lfn_offset;
	bool resolved = fat32_resolve_name11(dir_cluster, leaf, &name11, &dummy_lfn_sector, &dummy_lfn_offset);
	if (!resolved) fat32_name_to_8_3(leaf, &name11);

	uint cluster;
	uint size;
	uint entry_sector;
	uint entry_offset;
	char attr;
	bool exists = resolved && fat32_find_in_dir(dir_cluster, &name11, &cluster, &size, &entry_sector, &entry_offset, &attr);
	if (exists && (attr & FAT32_DIRENT_ATTR_DIRECTORY) != 0) return -1;
	if (!exists && offset != 0) return -1; // can't create with a hole
	if (exists && offset > size) return -1; // no holes

	if (!exists)
	{
		if (!fat32_create_file(dir_cluster, leaf, &name11, &cluster)) return -1;
		size = 0;
	}

	uint written = fat32_write_file_at(cluster, src, len, offset);

	uint final_cluster;
	uint final_size;
	char final_attr;
	if (!fat32_find_in_dir(dir_cluster, &name11, &final_cluster, &final_size, &entry_sector, &entry_offset, &final_attr))
	{
		return -1; // should be unreachable — don't claim success if it is
	}
	uint new_size = offset + written;
	if (new_size < size) new_size = size; // never shrink
	if (!fat32_update_entry_size(entry_sector, entry_offset, new_size)) return -1;

	return (int)written;
}

// Entry point dispatched from fsd.c3 for FS_STAT — size + type (0 file,
// 1 dir) of `name`. "" is the root directory. Returns false when
// nothing resolves there. Same resolve/find shape as fat32_read.
fn bool fat32_stat(char* name, uint* out_size, int* out_type)
{
	if (name[0] == 0)
	{
		*out_size = 0;
		*out_type = 1;
		return true;
	}
	uint dir_cluster;
	if (!fat32_resolve_dir(name, &dir_cluster)) return false;
	char* leaf = fat32_leaf_name(name);

	char[11] name11 @noinit;
	uint dummy_lfn_sector; uint dummy_lfn_offset;
	if (!fat32_resolve_name11(dir_cluster, leaf, &name11, &dummy_lfn_sector, &dummy_lfn_offset))
	{
		fat32_name_to_8_3(leaf, &name11);
	}

	uint cluster; uint size; uint es; uint eo; char attr;
	if (!fat32_find_in_dir(dir_cluster, &name11, &cluster, &size, &es, &eo, &attr)) return false;
	bool is_dir = (attr & FAT32_DIRENT_ATTR_DIRECTORY) != 0;
	*out_type = is_dir ? 1 : 0;
	*out_size = is_dir ? 0 : size;
	return true;
}

// Frees every cluster in first_cluster's chain, marking each 0 (free)
// in every FAT copy. Reads each cluster's own next-link before
// clearing its entry — clearing first would lose the rest of the
// chain, same ordering concern fat32_write_file's own chain-extension
// code has in reverse.
fn bool fat32_free_cluster_chain(uint first_cluster)
{
	uint cluster = first_cluster;
	uint freed_count = 0;
	while (cluster != 0 && cluster < FAT32_EOC_MIN)
	{
		uint next = fat32_next_cluster(cluster);
		if (!fat32_write_fat_entry(cluster, 0)) return false;
		freed_count += 1;
		cluster = next;
	}
	// One write for the whole chain, not one per cluster — see
	// fat32_write_free_count's own comment for why its failure isn't
	// propagated here either.
	fat32_free_count += freed_count;
	fat32_write_free_count();
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
	fat32_cache_valid = false; // see fat32_cache_path's own comment
	uint dir_cluster;
	if (!fat32_resolve_dir(name, &dir_cluster)) return -1;
	char* leaf = fat32_leaf_name(name);
	if (leaf[0] == 0) return -1; // "" or a trailing slash — nothing to delete

	char[11] name11 @noinit;
	uint lfn_sector = 0; uint lfn_offset = 0;
	if (!fat32_resolve_name11(dir_cluster, leaf, &name11, &lfn_sector, &lfn_offset))
	{
		fat32_name_to_8_3(leaf, &name11);
	}

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

	// Also delete the whole LFN chain (if any) that preceded the short
	// entry — leaving it behind would look like real corruption to any
	// other real FAT32 reader (orphaned LFN entries pointing at a
	// checksum nothing pruned). Walks by fixed 32-byte stride from the
	// chain's own recorded start up to (not including) entry_sector/
	// entry_offset — safe: fat32_prepare_new_entry only ever writes an
	// LFN chain immediately, contiguously, before its own short entry,
	// within a single cluster (see its own comment), so this can never
	// run past a cluster boundary either.
	if (lfn_sector != 0 || lfn_offset != 0)
	{
		uint del_sector = lfn_sector;
		uint del_offset = lfn_offset;
		while (del_sector != entry_sector || del_offset != entry_offset)
		{
			char[SECTOR_SIZE] del_buf @noinit;
			if (!fs_read_sector(del_sector, &del_buf)) break;
			del_buf[del_offset] = FAT32_DIRENT_DELETED;
			if (!fs_write_sector(del_sector, &del_buf)) break;
			del_offset += FAT32_DIRENT_SIZE;
			if (del_offset >= SECTOR_SIZE) { del_offset = 0; del_sector += 1; }
		}
	}

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
// fat32_dir_is_empty already does, rather than reconstructing names
// into path strings and going back through fat32_find_in_dir/
// fat32_delete for each child (every name it would need is already
// right here in the raw entry — no need to resolve one at all). Needs
// no LFN awareness of its own despite that: a child's LFN entries
// (attr==LFN, cluster field always 0) are skipped exactly like today
// and never individually marked deleted the way each child's own short
// entry is (below) — harmless, since dir_cluster's own chain gets
// freed by the caller in its *entirety* regardless of what any
// individual entry inside it says, the moment this whole recursive
// wipe completes. Leaves dir_cluster's own chain allocated — freeing *that* is the
// caller's job, same as fat32_delete_recursive frees the top-level
// target's own chain once this returns.
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
	fat32_cache_valid = false; // see fat32_cache_path's own comment
	uint dir_cluster;
	if (!fat32_resolve_dir(name, &dir_cluster)) return -1;
	char* leaf = fat32_leaf_name(name);
	if (leaf[0] == 0) return -1; // "" or a trailing slash — nothing to delete

	char[11] name11 @noinit;
	uint lfn_sector = 0; uint lfn_offset = 0;
	if (!fat32_resolve_name11(dir_cluster, leaf, &name11, &lfn_sector, &lfn_offset))
	{
		fat32_name_to_8_3(leaf, &name11);
	}

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

	// Also delete the target's own whole LFN chain, if any — see
	// fat32_delete's own comment for why: unlike the target's own
	// *content* (cluster, wholesale-freed below), this entry lives in
	// dir_cluster (the target's *parent*), which isn't being freed
	// here, so an orphaned chain here would really persist.
	if (lfn_sector != 0 || lfn_offset != 0)
	{
		uint del_sector = lfn_sector;
		uint del_offset = lfn_offset;
		while (del_sector != entry_sector || del_offset != entry_offset)
		{
			char[SECTOR_SIZE] del_buf @noinit;
			if (!fs_read_sector(del_sector, &del_buf)) break;
			del_buf[del_offset] = FAT32_DIRENT_DELETED;
			if (!fs_write_sector(del_sector, &del_buf)) break;
			del_offset += FAT32_DIRENT_SIZE;
			if (del_offset >= SECTOR_SIZE) { del_offset = 0; del_sector += 1; }
		}
	}

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
		uint dummy_lfn_sector; uint dummy_lfn_offset;
		if (!fat32_resolve_name11(parent_cluster, leaf, &name11, &dummy_lfn_sector, &dummy_lfn_offset))
		{
			fat32_name_to_8_3(leaf, &name11);
		}
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
	// LFN accumulation, same shape as fat32_resolve_name11's own scan —
	// see fat32_lfn_feed/fat32_lfn_finish's own comments.
	char[FAT32_LFN_NAME_MAX] lfn_buf @noinit;
	int lfn_expected_seq = 0;
	char lfn_checksum = 0;
	bool lfn_valid = false;
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
				if (entry[0] == FAT32_DIRENT_DELETED) { lfn_valid = false; continue; }

				char attr = entry[FAT32_DIRENT_ATTR];
				if (attr == FAT32_DIRENT_ATTR_LFN)
				{
					fat32_lfn_feed(entry, &lfn_buf, &lfn_expected_seq, &lfn_checksum, &lfn_valid);
					continue;
				}
				if ((attr & FAT32_DIRENT_ATTR_VOLUME) != 0) { lfn_valid = false; continue; }

				char[FAT32_LFN_NAME_MAX] display @noinit;
				fat32_lfn_finish(entry, &lfn_buf, lfn_expected_seq, lfn_checksum, lfn_valid, &display);
				lfn_valid = false;

				bool is_dot    = entry[FAT32_DIRENT_NAME] == '.' && entry[FAT32_DIRENT_NAME + 1] == ' ';
				bool is_dotdot = entry[FAT32_DIRENT_NAME] == '.' && entry[FAT32_DIRENT_NAME + 1] == '.' && entry[FAT32_DIRENT_NAME + 2] == ' ';
				if (is_dot || is_dotdot) continue;

				// Truncated to FS_LIST_NAME_MAX-1 for display — this
				// wire-format record is shared with ext2.c3/envd.c3,
				// which already truncate real names longer than this
				// the same way (see FS_LIST_NAME_MAX's own comment,
				// user.c3) — the real, full name is still reachable via
				// fs_read/fs_write/etc directly, only listing is capped.
				char* rec = &out_buf[(uint)count * FS_LIST_ENTRY_SIZE];
				int ni = 0;
				while (ni < (int)FS_LIST_NAME_MAX - 1 && display[ni] != 0) { rec[ni] = display[ni]; ni++; }
				rec[ni] = 0;
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
	fat32_cache_valid = false; // see fat32_cache_path's own comment
	uint parent_cluster;
	if (!fat32_resolve_dir(path, &parent_cluster)) return -1;
	char* leaf = fat32_leaf_name(path);
	if (leaf[0] == 0) return -1; // "" or a trailing slash — no directory name

	char[11] name11 @noinit;
	uint dummy_lfn_sector; uint dummy_lfn_offset;
	if (fat32_resolve_name11(parent_cluster, leaf, &name11, &dummy_lfn_sector, &dummy_lfn_offset))
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
	if (!fat32_prepare_new_entry(parent_cluster, leaf, &name11, &entry_sector, &entry_offset)) return -1;

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
	fat32_cache_valid = false; // see fat32_cache_path's own comment
	uint old_parent_cluster;
	if (!fat32_resolve_dir(old_path, &old_parent_cluster)) return -1;
	char* old_leaf = fat32_leaf_name(old_path);
	if (old_leaf[0] == 0) return -1; // "" or a trailing slash — nothing to rename
	char[11] old_name11 @noinit;
	uint old_lfn_sector = 0; uint old_lfn_offset = 0;
	if (!fat32_resolve_name11(old_parent_cluster, old_leaf, &old_name11, &old_lfn_sector, &old_lfn_offset))
	{
		fat32_name_to_8_3(old_leaf, &old_name11);
	}

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
	if (new_leaf[0] == 0) return -1; // "" or a trailing slash — no destination name
	char[11] new_name11 @noinit;
	uint dummy_new_lfn_sector; uint dummy_new_lfn_offset;
	bool new_resolved = fat32_resolve_name11(new_parent_cluster, new_leaf, &new_name11, &dummy_new_lfn_sector, &dummy_new_lfn_offset);

	// Moving a directory: refuse if the destination's own parent chain
	// runs through the directory being moved — see
	// fat32_would_create_cycle's own comment. Files can never create a
	// cycle (they have no children to contain anything), so this only
	// applies to attr's directory bit.
	if ((attr & FAT32_DIRENT_ATTR_DIRECTORY) != 0 && fat32_would_create_cycle(new_parent_cluster, cluster))
	{
		return -1;
	}

	if (new_resolved)
	{
		uint existing_cluster;
		uint existing_size;
		uint existing_sector;
		uint existing_offset;
		char existing_attr;
		if (fat32_find_in_dir(new_parent_cluster, &new_name11, &existing_cluster, &existing_size, &existing_sector, &existing_offset, &existing_attr))
		{
			return -1; // destination already exists
		}
	}

	uint new_entry_sector;
	uint new_entry_offset;
	if (!fat32_prepare_new_entry(new_parent_cluster, new_leaf, &new_name11, &new_entry_sector, &new_entry_offset)) return -1;
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

	// Also delete the source's own whole LFN chain, if any — see
	// fat32_delete's own comment for why (same logic, duplicated here
	// rather than factored out: the two callers' surrounding state —
	// what's already been read/written, what's already been decided —
	// differs enough that a shared helper would need as many parameters
	// as it saves lines).
	if (old_lfn_sector != 0 || old_lfn_offset != 0)
	{
		uint del_sector = old_lfn_sector;
		uint del_offset = old_lfn_offset;
		while (del_sector != old_entry_sector || del_offset != old_entry_offset)
		{
			char[SECTOR_SIZE] del_buf @noinit;
			if (!fs_read_sector(del_sector, &del_buf)) break;
			del_buf[del_offset] = FAT32_DIRENT_DELETED;
			if (!fs_write_sector(del_sector, &del_buf)) break;
			del_offset += FAT32_DIRENT_SIZE;
			if (del_offset >= SECTOR_SIZE) { del_offset = 0; del_sector += 1; }
		}
	}

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
	ushort* fsinfo_sector_field = (ushort*)&boot_sector[FAT32_BPB_FSINFO_SECTOR];

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
	fat32_fsinfo_sector       = (uint)*fsinfo_sector_field;

	// Establish fat32_free_count — trusted from the FSInfo sector if its
	// signatures check out and it isn't the explicit "unknown" sentinel,
	// otherwise recomputed once here via the same linear-scan shape
	// fat32_alloc_cluster uses to find one free entry, just counting all
	// of them instead of stopping at the first. Not every real-world
	// FAT32 volume populates FSInfo correctly, so this fallback matters
	// for more than just defensiveness. Either way, persist the result
	// immediately (fat32_write_free_count) so a freshly-recomputed value
	// is on disk from the start, not only ever in memory.
	char[SECTOR_SIZE] fsinfo_buf @noinit;
	bool fsinfo_ok = false;
	if (fs_read_sector(fat32_fsinfo_sector, &fsinfo_buf))
	{
		uint* lead_sig  = (uint*)&fsinfo_buf[FAT32_FSINFO_LEAD_SIG];
		uint* struc_sig = (uint*)&fsinfo_buf[FAT32_FSINFO_STRUC_SIG];
		uint* trail_sig = (uint*)&fsinfo_buf[FAT32_FSINFO_TRAIL_SIG];
		uint* free_count_field = (uint*)&fsinfo_buf[FAT32_FSINFO_FREE_COUNT];
		if (*lead_sig == 0x41615252 && *struc_sig == 0x61417272 && *trail_sig == 0xAA550000 && *free_count_field != 0xFFFFFFFF)
		{
			fat32_free_count = *free_count_field;
			fsinfo_ok = true;
		}
	}
	if (!fsinfo_ok)
	{
		uint count = 0;
		for (uint cluster = 2; cluster < fat32_total_clusters + 2; cluster++)
		{
			if (fat32_next_cluster(cluster) == 0) count += 1;
		}
		fat32_free_count = count;
	}
	fat32_write_free_count();

	print("fsd: FAT32 mounted, partition_start=");
	print_uint(fs_partition_start);
	print(" root_cluster=");
	print_uint(fat32_root_cluster);
	print(" sectors_per_cluster=");
	print_uint(fat32_sectors_per_cluster);
	print("\n");
}
