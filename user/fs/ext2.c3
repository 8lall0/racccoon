module user;

// ext2 backend for fsd (see user/fsd.c3's own header comment for the
// generic core / backend split). Standard, stable public spec (the
// original ext2 on-disk format, unchanged by ext3/ext4's later journal/
// extent additions) — not reverse-engineered.
//
// v1 scope, deliberately limited — applies to both read and write:
//   - Direct block pointers only (i_block[0..11], 12 of them) — single/
//     double/triple indirect blocks are NOT walked. A file needing more
//     than 12 blocks' worth of data reads back short, same "return
//     however many bytes were actually reachable" discipline
//     fat32_read_file uses for a broken chain, not an error.
//   - Reading, updating, and allocating inodes/blocks all work across
//     any block group, up to EXT2_MAX_GROUPS (see its own comment) —
//     found a real need for this on actual hardware: a real Linux
//     `mkdir` spread a new directory into group 1, which this driver
//     used to refuse entirely.
//   - The on-disk file_type byte in a directory entry (only populated if
//     the volume has that optional feature flag) is never consulted —
//     but a directory sharing a requested file's name is still refused,
//     via the matched inode's own authoritative mode field instead (see
//     ext2_read/ext2_write and ext2_reserve_protected), which works
//     regardless of whether that optional feature flag is even set.
//
// Write support (create, overwrite, grow — see ext2_write()) reuses
// fsd.c3's generic write-protection machinery verbatim (the same
// fs_reserve_sector_range()/fs_set_protected_entry() a protected file's
// data and directory entry get registered through for FAT32 — see
// ext2_reserve_protected()) rather than anything ext2-specific. What's
// genuinely different from FAT32's write path: ext2 allocates space via
// *bitmaps* (one bit per block/inode in a group), not a linked list like
// the FAT table, and needs a separate allocation step for *inodes* (a
// fixed-size, pre-allocated table — FAT32 has no equivalent; creating a
// file there only ever needed a free cluster + a free directory slot).
// v1 write scope, explicit:
//   - Creating a file always appends a fresh directory block containing
//     just that one entry, rather than splitting an existing entry's
//     trailing rec_len (a common real ext2 allocator technique) — a
//     documented inefficiency, parallel to FAT32 write's own "shrinking
//     doesn't free the now-excess clusters" gap. Fails outright (no
//     silent workaround) if the root directory's own 12 direct blocks
//     are already all in use.
//   - No indirect-block writes either, same 12-direct-block limit the
//     read path already has.

// Superblock lives at a *fixed byte offset*, 1024, from the partition
// start regardless of block size — sector 2 for this project's fixed
// 512-byte sectors (byte 1024 = sector 2 * 512). Field offsets below are
// relative to the superblock's own start (i.e. byte 1024 + offset).
const uint EXT2_SUPERBLOCK_SECTOR    = 2;
const uint EXT2_SB_LOG_BLOCK_SIZE    = 24; // u32
const uint EXT2_SB_INODES_COUNT      = 0;  // u32 — total inodes on the volume, used to
                                             // compute how many block groups exist (see
                                             // ext2_group_count's own comment)
const uint EXT2_SB_BLOCKS_PER_GROUP  = 32; // u32
const uint EXT2_SB_INODES_PER_GROUP  = 40; // u32
const uint EXT2_SB_FIRST_DATA_BLOCK  = 20; // u32
const uint EXT2_SB_FREE_BLOCKS_COUNT = 12; // u32 — real hardware consequence found
                                             // this session, not just cosmetic: a
                                             // stale free-count makes a real Linux
                                             // box's own ext2 driver see "errors on
                                             // this volume" at mount time and
                                             // auto-remount read-only
                                             // (errors=remount-ro), blocking any
                                             // further writes from that side until
                                             // e2fsck -y clears it. See
                                             // ext2_dec_free_blocks/inodes below.
const uint EXT2_SB_FREE_INODES_COUNT = 16; // u32, same reasoning
const uint EXT2_SB_MAGIC             = 56; // u16, must be 0xEF53
const uint EXT2_SB_REV_LEVEL         = 76; // u32, 0 = original (fixed 128-byte inodes), >=1 = dynamic
const uint EXT2_SB_INODE_SIZE        = 88; // u16, only meaningful if rev_level >= 1

// Block group descriptor (32 bytes each), starting in the block
// immediately after the superblock's own block — ext2_mount() reads
// every group's own descriptor, not just group 0's (see
// EXT2_MAX_GROUPS's own comment).
const uint EXT2_BGD_BLOCK_BITMAP       = 0;  // u32, block holding this group's block-allocation bitmap
const uint EXT2_BGD_INODE_BITMAP       = 4;  // u32, block holding this group's inode-allocation bitmap
const uint EXT2_BGD_INODE_TABLE        = 8;  // u32, starting block of this group's inode table
const uint EXT2_BGD_FREE_BLOCKS_COUNT  = 12; // u16 — group-0 copy of EXT2_SB_FREE_BLOCKS_COUNT, see its comment
const uint EXT2_BGD_FREE_INODES_COUNT  = 14; // u16 — group-0 copy of EXT2_SB_FREE_INODES_COUNT, see its comment
const uint EXT2_BGD_USED_DIRS_COUNT    = 16; // u16 — how many directories live in this group. No
                                               // superblock-level twin to keep in sync (unlike the
                                               // free-block/inode counts above) — this one's only
                                               // tracked per-group. This driver never creates a
                                               // directory itself (no mkdir), so only ext2_delete's
                                               // own decrement on removal needs this — found via
                                               // e2fsck flagging it after the very first real rmdir
                                               // test, the same "verify with the oracle, don't just
                                               // trust the write" discipline that caught the earlier
                                               // free-count gap this session.

// Inode field offsets, relative to the inode's own start.
const uint EXT2_INODE_MODE        = 0;  // u16
const uint EXT2_INODE_SIZE        = 4;  // u32 (low 32 bits — large-file high bits not read, v1)
const uint EXT2_INODE_LINKS_COUNT = 26; // u16 — real hardware bug found here (see
                                          // ext2_create_file's own comment): a
                                          // newly created inode left this at 0
                                          // (zeroed by ext2_zero_inode, never set
                                          // afterward), which a real ext2 reader
                                          // treats as "not actually a live file"
                                          // even though a directory entry points
                                          // at it — e2fsck flagged it as a
                                          // "deleted inode with zero dtime".
const uint EXT2_INODE_BLOCKS      = 28; // u32 — count of 512-byte sectors this
                                          // inode's data occupies (standard ext2
                                          // unit, NOT ext2_block_size blocks).
                                          // Same real-hardware bug: never updated
                                          // when a file/directory gained a block,
                                          // caught by e2fsck as "i_blocks is 8,
                                          // should be 24" on the root directory.
const uint EXT2_INODE_BLOCK       = 40; // u32 x 15 (i_block[0..14]) — v1 only reads [0..11]

const uint EXT2_S_IFREG = 0x8000; // regular file bit in i_mode
const uint EXT2_S_IFDIR = 0x4000; // directory bit in i_mode

const uint EXT2_ROOT_INODE = 2; // format constant, not read from the superblock

// Directory entry (variable length) field offsets, relative to the
// entry's own start within its containing block.
const uint EXT2_DIRENT_INODE    = 0; // u32, 0 = deleted, skip but still advance by rec_len
const uint EXT2_DIRENT_REC_LEN  = 4; // u16, total record length — how far to the next entry
const uint EXT2_DIRENT_NAME_LEN = 6; // u8
const uint EXT2_DIRENT_NAME     = 8; // name_len bytes, NOT null-terminated

// 4096 covers every block size mke2fs actually produces by default
// (1024/2048/4096) and every block size this project's own test/real
// images are expected to use — see this file's header comment. A larger
// block size fails closed via ext2_mount()'s own check, not a silent
// truncation.
const uint EXT2_MAX_BLOCK_SIZE = 4096;

// Real hardware bug found and fixed this session: this driver used to
// only ever know group 0's inode table, so any inode belonging to a
// different group (real Linux tools spread new files/directories
// across groups) was silently treated as not-found — see
// ext2_read_inode/ext2_write_inode's own comments and docs/devlog.md.
// ext2_alloc_block()/ext2_alloc_inode() now scan every group too, so
// this driver's own writes aren't confined to group 0 as it fills up
// either. 64 groups is generous for this project's real hardware (a
// 1GB partition needs about 8); a volume needing more just can't fully
// interoperate/allocate past group 63 — every group-indexed lookup in
// this file already fails closed (treated as not-found, or "no space
// left") for anything beyond what ext2_group_count/these arrays
// actually cover.
const uint EXT2_MAX_GROUPS = 64;
const uint EXT2_BGD_SIZE   = 32; // bytes per block group descriptor, standard fixed size

uint ext2_block_size;
uint ext2_sectors_per_block;
uint ext2_inode_size;
uint ext2_inodes_per_group;
uint ext2_blocks_per_group; // write-path only: ext2_alloc_block()'s scan bound
uint ext2_first_data_block; // write-path only: ext2_alloc_block()'s base for converting a bitmap bit index into a block number
uint ext2_group_count;
uint[EXT2_MAX_GROUPS] ext2_inode_table_blocks;  // every group's own inode table block, for ext2_read_inode/ext2_write_inode
uint[EXT2_MAX_GROUPS] ext2_block_bitmap_blocks; // every group's own block bitmap, for ext2_alloc_block
uint[EXT2_MAX_GROUPS] ext2_inode_bitmap_blocks; // every group's own inode bitmap, for ext2_alloc_inode

struct Ext2_inode_info
{
	uint mode;
	uint size;
	uint links_count; // see EXT2_INODE_LINKS_COUNT's own comment
	uint blocks;       // see EXT2_INODE_BLOCKS's own comment — 512-byte sectors, not ext2_block_size blocks
	uint[12] block; // direct block pointers only — see this file's header comment
}

fn bool ext2_probe()
{
	char[SECTOR_SIZE] sb_sector @noinit;
	if (!fs_read_sector(EXT2_SUPERBLOCK_SECTOR, &sb_sector)) return false;
	ushort* magic = (ushort*)&sb_sector[EXT2_SB_MAGIC];
	return *magic == 0xEF53;
}

// Reads a full block (however many sectors that spans) into `buf`, which
// must be at least ext2_block_size bytes — callers declare
// char[EXT2_MAX_BLOCK_SIZE] and only look at the first ext2_block_size
// of it, same "comfortably fixed-size buffer" convention as this
// codebase's other char[SECTOR_SIZE]/char[100] locals.
fn bool ext2_read_block(uint block, char* buf)
{
	for (uint s = 0; s < ext2_sectors_per_block; s++)
	{
		if (!fs_read_sector(block * ext2_sectors_per_block + s, &buf[s * SECTOR_SIZE])) return false;
	}
	return true;
}

// Write counterpart to ext2_read_block — every ext2-level write in this
// file (data, bitmaps, inode table entries, directory entries) goes
// through this, which goes through fs_write_sector()'s reserved-sector
// check.
fn bool ext2_write_block(uint block, char* buf)
{
	for (uint s = 0; s < ext2_sectors_per_block; s++)
	{
		if (!fs_write_sector(block * ext2_sectors_per_block + s, &buf[s * SECTOR_SIZE])) return false;
	}
	return true;
}

// Reads inode `inode_num` (1-based) into *out. Fails (returns false,
// not a panic — this is a normal, expected outcome for an out-of-range
// lookup, not a corrupt-volume condition) if it would need a block
// group other than 0 — see this file's header comment on why that's a
// real v1 limit, not a bug.
fn bool ext2_read_inode(uint inode_num, Ext2_inode_info* out)
{
	if (inode_num == 0) return false;

	// Group-aware, not group-0-only: a real ext2 allocator (Linux's own
	// mkdir, found the hard way on real hardware — see EXT2_MAX_GROUPS's
	// own comment) can put an inode in any group. Fails closed (treated
	// as not-found, same as an out-of-range inode_num always has) for a
	// group beyond what ext2_mount() actually cached.
	uint group = (inode_num - 1) / ext2_inodes_per_group;
	if (group >= ext2_group_count) return false;
	uint index_in_group = (inode_num - 1) % ext2_inodes_per_group;

	uint byte_offset_in_table = index_in_group * ext2_inode_size;
	uint block_offset = byte_offset_in_table / ext2_block_size;
	uint offset_in_block = byte_offset_in_table % ext2_block_size;

	char[EXT2_MAX_BLOCK_SIZE] block_buf @noinit;
	if (!ext2_read_block(ext2_inode_table_blocks[group] + block_offset, &block_buf)) return false;

	char* inode_bytes = &block_buf[offset_in_block];
	ushort* mode_field        = (ushort*)&inode_bytes[EXT2_INODE_MODE];
	uint*   size_field        = (uint*)&inode_bytes[EXT2_INODE_SIZE];
	ushort* links_count_field = (ushort*)&inode_bytes[EXT2_INODE_LINKS_COUNT];
	uint*   blocks_field      = (uint*)&inode_bytes[EXT2_INODE_BLOCKS];
	out.mode        = (uint)*mode_field;
	out.size        = *size_field;
	out.links_count = (uint)*links_count_field;
	out.blocks      = *blocks_field;
	uint* block_ptrs = (uint*)&inode_bytes[EXT2_INODE_BLOCK];
	mem::copy(&out.block, block_ptrs, 48); // 12 uint (4 bytes each) direct block pointers
	return true;
}

fn uint ext2_strlen(char* s)
{
	uint n = 0;
	while (s[n] != 0) n++;
	return n;
}

// Walks the root inode's direct blocks looking for a name match (exact,
// case-sensitive — ext2 names have no 8.3-style folding). Returns true
// and fills *out_inode/*out_entry_sector/*out_entry_offset on a hit —
// the latter two (the entry's own location, converted from
// block+in-block-offset to fsd.c3's generic sector+in-sector-offset
// convention — the same shape fat32_find_in_root's own out-params use,
// since fsd.c3's fs_set_protected_entry()/fs_is_protected_entry() are
// sector-granular, not block-granular) are needed by the write path
// (ext2_reserve_protected(), and ext2_write()'s protected-entry check);
// the read path just ignores them.
fn bool ext2_find_in_root(char* name, uint* out_inode, uint* out_entry_sector, uint* out_entry_offset)
{
	Ext2_inode_info root;
	if (!ext2_read_inode(EXT2_ROOT_INODE, &root)) return false;

	uint name_len = ext2_strlen(name);

	for (uint b = 0; b < 12; b++)
	{
		uint block = root.block[b];
		if (block == 0) continue; // sparse — unused direct pointer

		char[EXT2_MAX_BLOCK_SIZE] block_buf @noinit;
		if (!ext2_read_block(block, &block_buf)) return false;

		uint offset = 0;
		while (offset < ext2_block_size)
		{
			char* entry = &block_buf[offset];
			uint*  entry_inode    = (uint*)&entry[EXT2_DIRENT_INODE];
			ushort* rec_len_field = (ushort*)&entry[EXT2_DIRENT_REC_LEN];
			char   name_len_byte  = entry[EXT2_DIRENT_NAME_LEN];

			uint rec_len = (uint)*rec_len_field;
			if (rec_len == 0) break; // malformed — avoid an infinite loop

			uint entry_name_len = (uint)name_len_byte & 0xFF;
			if (*entry_inode != 0 && entry_name_len == name_len)
			{
				bool match = true;
				for (uint k = 0; k < name_len; k++)
				{
					if (entry[EXT2_DIRENT_NAME + k] != name[k]) { match = false; break; }
				}
				if (match)
				{
					*out_inode = *entry_inode;
					*out_entry_sector = block * ext2_sectors_per_block + (offset / SECTOR_SIZE);
					*out_entry_offset = offset % SECTOR_SIZE;
					return true;
				}
			}

			offset += rec_len;
		}
	}
	return false;
}

// --- Subdirectory support (read and write) ------------------------------
//
// ext2_read (below) and ext2_write (further down — create/overwrite/
// grow a file inside a subdirectory, not just the root, generalizing
// ext2_create_file the same way) both walk into a subdirectory using
// the functions below. ext2_find_in_root and its one remaining caller,
// ext2_reserve_protected, stay root-only on purpose: the one file that
// ever needs protecting (fip.bin) is always in the root regardless of
// what this feature does — same boundary as FAT32's own (see
// user/fs/fat32.c3's matching comment). A subdirectory is just an inode
// with EXT2_S_IFDIR set whose own data blocks hold more directory
// entries — the exact same shape as the root directory's own blocks —
// so ext2_find_in_dir is ext2_find_in_root generalized to any starting
// inode, not new logic.

// Same walk as ext2_find_in_root, but over any directory inode's direct
// blocks, not just the root — and reports the matched entry's inode
// mode too, so a caller can tell a subdirectory from a regular file
// before deciding what to do with the inode it points at.
// out_entry_sector/out_entry_offset are the entry's own location, same
// shape as ext2_find_in_root's — needed by the write path (the
// protected-entry check); ext2_resolve_dir's own directory-walking use
// just discards them into local dummies.
fn bool ext2_find_in_dir(uint dir_inode_num, char* name, uint* out_inode, uint* out_entry_sector, uint* out_entry_offset, uint* out_mode)
{
	Ext2_inode_info dir;
	if (!ext2_read_inode(dir_inode_num, &dir)) return false;
	if ((dir.mode & EXT2_S_IFDIR) == 0) return false;

	uint name_len = ext2_strlen(name);

	for (uint b = 0; b < 12; b++)
	{
		uint block = dir.block[b];
		if (block == 0) continue;

		char[EXT2_MAX_BLOCK_SIZE] block_buf @noinit;
		if (!ext2_read_block(block, &block_buf)) return false;

		uint offset = 0;
		while (offset < ext2_block_size)
		{
			char* entry = &block_buf[offset];
			uint*  entry_inode    = (uint*)&entry[EXT2_DIRENT_INODE];
			ushort* rec_len_field = (ushort*)&entry[EXT2_DIRENT_REC_LEN];
			char   name_len_byte  = entry[EXT2_DIRENT_NAME_LEN];

			uint rec_len = (uint)*rec_len_field;
			if (rec_len == 0) break;

			uint entry_name_len = (uint)name_len_byte & 0xFF;
			if (*entry_inode != 0 && entry_name_len == name_len)
			{
				bool match = true;
				for (uint k = 0; k < name_len; k++)
				{
					if (entry[EXT2_DIRENT_NAME + k] != name[k]) { match = false; break; }
				}
				if (match)
				{
					Ext2_inode_info matched;
					if (!ext2_read_inode(*entry_inode, &matched)) return false;
					*out_inode        = *entry_inode;
					*out_entry_sector = block * ext2_sectors_per_block + (offset / SECTOR_SIZE);
					*out_entry_offset = offset % SECTOR_SIZE;
					*out_mode         = matched.mode;
					return true;
				}
			}

			offset += rec_len;
		}
	}
	return false;
}

// Splits `path` on '/' and walks from the root inode through every
// directory component but the last, requiring each to actually be a
// directory (EXT2_S_IFDIR) — a component that matches a regular file
// instead fails the resolve, same as one that doesn't match anything. A
// bare filename with no '/' resolves trivially to the root inode,
// unchanged from every existing single-level caller. Empty segments (a
// leading '/', a doubled '//') are skipped rather than treated as a
// lookup failure.
fn bool ext2_resolve_dir(char* path, uint* out_dir_inode)
{
	uint dir_inode = EXT2_ROOT_INODE;
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
			char[256] seg_buf @noinit;
			uint copy_len = seg_len < 255 ? seg_len : 255;
			for (uint k = 0; k < copy_len; k++) seg_buf[k] = path[seg_start + k];
			seg_buf[copy_len] = 0;

			uint next_inode;
			uint dummy_sector;
			uint dummy_offset;
			uint mode;
			if (!ext2_find_in_dir(dir_inode, &seg_buf, &next_inode, &dummy_sector, &dummy_offset, &mode)) return false;
			if ((mode & EXT2_S_IFDIR) == 0) return false;
			dir_inode = next_inode;
		}

		if (path[i] == 0) break;
		seg_start = i + 1;
		i++;
	}
	*out_dir_inode = dir_inode;
	return true;
}

// The final path component (after the last '/', or the whole string if
// there's none) — a pointer into `path` itself, no copy.
fn char* ext2_leaf_name(char* path)
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

// Entry point dispatched from fsd.c3's main() for FS_READ. Returns -1
// if not found, else bytes actually read (already clamped to the file's
// real size and to what the direct blocks can reach — see this file's
// header comment).
fn int ext2_read(char* name, char* dst, uint len)
{
	uint dir_inode;
	if (!ext2_resolve_dir(name, &dir_inode)) return -1;
	char* leaf = ext2_leaf_name(name);

	uint inode_num;
	uint dummy_sector;
	uint dummy_offset;
	uint mode;
	if (!ext2_find_in_dir(dir_inode, leaf, &inode_num, &dummy_sector, &dummy_offset, &mode)) return -1;
	// A directory isn't file content — refuse rather than hand back
	// whatever bytes its own directory-entry blocks happen to hold.
	if ((mode & EXT2_S_IFDIR) != 0) return -1;

	Ext2_inode_info inode;
	if (!ext2_read_inode(inode_num, &inode)) return -1;

	uint read_len = len;
	if (read_len > inode.size) read_len = inode.size;

	uint bytes_read = 0;
	for (uint b = 0; b < 12 && bytes_read < read_len; b++)
	{
		uint block = inode.block[b];
		char[EXT2_MAX_BLOCK_SIZE] block_buf @noinit;
		if (block == 0)
		{
			// Sparse block — zero-fill this portion rather than
			// stopping, matching the region's logical content (all-
			// zero) per ext2's own sparse-file semantics.
			for (uint i = 0; i < EXT2_MAX_BLOCK_SIZE; i++) block_buf[i] = 0;
		}
		else if (!ext2_read_block(block, &block_buf))
		{
			return (int)bytes_read;
		}

		uint chunk = read_len - bytes_read;
		if (chunk > ext2_block_size) chunk = ext2_block_size;
		for (uint i = 0; i < chunk; i++)
		{
			dst[bytes_read + i] = block_buf[i];
		}
		bytes_read += chunk;
	}
	return (int)bytes_read;
}

fn void ext2_mount()
{
	char[SECTOR_SIZE] sb_sector @noinit;
	if (!fs_read_sector(EXT2_SUPERBLOCK_SECTOR, &sb_sector))
	{
		fs_panic("failed to read ext2 superblock");
	}

	// Magic already confirmed by ext2_probe() (fs_mount() only calls
	// this after that returned true) — not re-checked here.

	uint* log_block_size    = (uint*)&sb_sector[EXT2_SB_LOG_BLOCK_SIZE];
	uint* first_data_block  = (uint*)&sb_sector[EXT2_SB_FIRST_DATA_BLOCK];
	uint* blocks_per_group  = (uint*)&sb_sector[EXT2_SB_BLOCKS_PER_GROUP];
	uint* inodes_per_group  = (uint*)&sb_sector[EXT2_SB_INODES_PER_GROUP];
	uint* rev_level         = (uint*)&sb_sector[EXT2_SB_REV_LEVEL];
	ushort* inode_size_field = (ushort*)&sb_sector[EXT2_SB_INODE_SIZE];

	ext2_block_size = 1024 << *log_block_size;
	if (ext2_block_size > EXT2_MAX_BLOCK_SIZE)
	{
		// Every other part of this driver assumes a block fits in
		// EXT2_MAX_BLOCK_SIZE — panic clearly rather than silently
		// mishandle a larger one (see this file's own header comment).
		fs_panic("ext2 block size too large for this driver");
	}
	ext2_sectors_per_block = ext2_block_size / SECTOR_SIZE;
	ext2_blocks_per_group  = *blocks_per_group;
	ext2_inodes_per_group  = *inodes_per_group;
	ext2_inode_size        = (*rev_level >= 1) ? (uint)*inode_size_field : 128;

	ext2_first_data_block = *first_data_block;

	// Block group descriptor table starts in the block immediately
	// after the superblock's own block, and can itself span more than
	// one block once there are enough groups (descriptors_per_block
	// each). Reads every group's own block/inode bitmap and inode
	// table location — not just group 0's — so ext2_read_inode/
	// ext2_write_inode/ext2_alloc_block/ext2_alloc_inode can all
	// resolve/allocate in any group. See EXT2_MAX_GROUPS's own comment
	// for why: a real Linux `mkdir` on the real Duo card allocated a
	// new directory in group 1, which this driver used to treat as
	// not-found entirely.
	uint* inodes_count_field = (uint*)&sb_sector[EXT2_SB_INODES_COUNT];
	ext2_group_count = (*inodes_count_field + ext2_inodes_per_group - 1) / ext2_inodes_per_group;
	if (ext2_group_count > EXT2_MAX_GROUPS) ext2_group_count = EXT2_MAX_GROUPS;

	uint descriptors_per_block = ext2_block_size / EXT2_BGD_SIZE;
	uint bgdt_blocks_needed = (ext2_group_count + descriptors_per_block - 1) / descriptors_per_block;
	for (uint bb = 0; bb < bgdt_blocks_needed; bb++)
	{
		char[EXT2_MAX_BLOCK_SIZE] bgdt_scan_buf @noinit;
		if (!ext2_read_block(ext2_first_data_block + 1 + bb, &bgdt_scan_buf))
		{
			fs_panic("failed to read ext2 block group descriptor");
		}
		for (uint d = 0; d < descriptors_per_block; d++)
		{
			uint g = bb * descriptors_per_block + d;
			if (g >= ext2_group_count) break;
			uint* group_inode_table  = (uint*)&bgdt_scan_buf[d * EXT2_BGD_SIZE + EXT2_BGD_INODE_TABLE];
			uint* group_block_bitmap = (uint*)&bgdt_scan_buf[d * EXT2_BGD_SIZE + EXT2_BGD_BLOCK_BITMAP];
			uint* group_inode_bitmap = (uint*)&bgdt_scan_buf[d * EXT2_BGD_SIZE + EXT2_BGD_INODE_BITMAP];
			ext2_inode_table_blocks[g]  = *group_inode_table;
			ext2_block_bitmap_blocks[g] = *group_block_bitmap;
			ext2_inode_bitmap_blocks[g] = *group_inode_bitmap;
		}
	}

	Ext2_inode_info root;
	if (!ext2_read_inode(EXT2_ROOT_INODE, &root) || (root.mode & EXT2_S_IFDIR) == 0)
	{
		// Root (inode 2, always in group 0 by format convention) not
		// being a directory means a corrupt volume — panic clearly.
		fs_panic("ext2 root inode is not a directory");
	}

	print("fsd: ext2 mounted, block_size=");
	print_uint(ext2_block_size);
	print(" inode_table_block=");
	print_uint(ext2_inode_table_blocks[0]);
	print("\n");
}

// --- Write path -------------------------------------------------------

// Decrements both copies of the free-block count (superblock's global
// s_free_blocks_count, and `group`'s own bg_free_blocks_count in the
// block group descriptor table — not always group 0 anymore, since
// ext2_alloc_block() below now allocates from any group) by one —
// called once per successful allocation. See EXT2_SB_FREE_BLOCKS_
// COUNT's own comment for why this isn't just a cosmetic e2fsck
// complaint: a real Linux box's ext2 driver checks this at mount time
// and auto-remounts read-only if it's wrong, found the hard way while
// testing on the actual boot card this session. `group`'s own
// descriptor can live in any of the (possibly several) BGDT blocks —
// same `group / descriptors_per_block` / `group % descriptors_per_
// block` math ext2_mount()'s own BGDT scan uses. Two separate sector/
// block writes (superblock lives in a fixed sector, the BGDT in a
// block) — same "each copy independently read-modify-written" shape
// as fat32_write_fat_entry's multiple FAT copies.
fn bool ext2_dec_free_blocks(uint group)
{
	char[SECTOR_SIZE] sb_sector @noinit;
	if (!fs_read_sector(EXT2_SUPERBLOCK_SECTOR, &sb_sector)) return false;
	uint* sb_free = (uint*)&sb_sector[EXT2_SB_FREE_BLOCKS_COUNT];
	*sb_free -= 1;
	if (!fs_write_sector(EXT2_SUPERBLOCK_SECTOR, &sb_sector)) return false;

	uint descriptors_per_block = ext2_block_size / EXT2_BGD_SIZE;
	uint bgdt_block = ext2_first_data_block + 1 + (group / descriptors_per_block);
	uint offset_in_block = (group % descriptors_per_block) * EXT2_BGD_SIZE + EXT2_BGD_FREE_BLOCKS_COUNT;

	char[EXT2_MAX_BLOCK_SIZE] bgdt_buf @noinit;
	if (!ext2_read_block(bgdt_block, &bgdt_buf)) return false;
	ushort* bg_free = (ushort*)&bgdt_buf[offset_in_block];
	*bg_free -= 1;
	return ext2_write_block(bgdt_block, &bgdt_buf);
}

// Same shape as ext2_dec_free_blocks(), for inodes — called once per
// successful ext2_alloc_inode().
fn bool ext2_dec_free_inodes(uint group)
{
	char[SECTOR_SIZE] sb_sector @noinit;
	if (!fs_read_sector(EXT2_SUPERBLOCK_SECTOR, &sb_sector)) return false;
	uint* sb_free = (uint*)&sb_sector[EXT2_SB_FREE_INODES_COUNT];
	*sb_free -= 1;
	if (!fs_write_sector(EXT2_SUPERBLOCK_SECTOR, &sb_sector)) return false;

	uint descriptors_per_block = ext2_block_size / EXT2_BGD_SIZE;
	uint bgdt_block = ext2_first_data_block + 1 + (group / descriptors_per_block);
	uint offset_in_block = (group % descriptors_per_block) * EXT2_BGD_SIZE + EXT2_BGD_FREE_INODES_COUNT;

	char[EXT2_MAX_BLOCK_SIZE] bgdt_buf @noinit;
	if (!ext2_read_block(bgdt_block, &bgdt_buf)) return false;
	ushort* bg_free = (ushort*)&bgdt_buf[offset_in_block];
	*bg_free -= 1;
	return ext2_write_block(bgdt_block, &bgdt_buf);
}

// Same shape as ext2_dec_free_blocks(), incrementing instead — called
// once per successful ext2_free_block().
fn bool ext2_inc_free_blocks(uint group)
{
	char[SECTOR_SIZE] sb_sector @noinit;
	if (!fs_read_sector(EXT2_SUPERBLOCK_SECTOR, &sb_sector)) return false;
	uint* sb_free = (uint*)&sb_sector[EXT2_SB_FREE_BLOCKS_COUNT];
	*sb_free += 1;
	if (!fs_write_sector(EXT2_SUPERBLOCK_SECTOR, &sb_sector)) return false;

	uint descriptors_per_block = ext2_block_size / EXT2_BGD_SIZE;
	uint bgdt_block = ext2_first_data_block + 1 + (group / descriptors_per_block);
	uint offset_in_block = (group % descriptors_per_block) * EXT2_BGD_SIZE + EXT2_BGD_FREE_BLOCKS_COUNT;

	char[EXT2_MAX_BLOCK_SIZE] bgdt_buf @noinit;
	if (!ext2_read_block(bgdt_block, &bgdt_buf)) return false;
	ushort* bg_free = (ushort*)&bgdt_buf[offset_in_block];
	*bg_free += 1;
	return ext2_write_block(bgdt_block, &bgdt_buf);
}

// Same shape as ext2_dec_free_inodes(), incrementing instead — called
// once per successful ext2_free_inode().
fn bool ext2_inc_free_inodes(uint group)
{
	char[SECTOR_SIZE] sb_sector @noinit;
	if (!fs_read_sector(EXT2_SUPERBLOCK_SECTOR, &sb_sector)) return false;
	uint* sb_free = (uint*)&sb_sector[EXT2_SB_FREE_INODES_COUNT];
	*sb_free += 1;
	if (!fs_write_sector(EXT2_SUPERBLOCK_SECTOR, &sb_sector)) return false;

	uint descriptors_per_block = ext2_block_size / EXT2_BGD_SIZE;
	uint bgdt_block = ext2_first_data_block + 1 + (group / descriptors_per_block);
	uint offset_in_block = (group % descriptors_per_block) * EXT2_BGD_SIZE + EXT2_BGD_FREE_INODES_COUNT;

	char[EXT2_MAX_BLOCK_SIZE] bgdt_buf @noinit;
	if (!ext2_read_block(bgdt_block, &bgdt_buf)) return false;
	ushort* bg_free = (ushort*)&bgdt_buf[offset_in_block];
	*bg_free += 1;
	return ext2_write_block(bgdt_block, &bgdt_buf);
}

// Decrements `group`'s own bg_used_dirs_count — no superblock-level
// copy to keep in sync (see EXT2_BGD_USED_DIRS_COUNT's own comment),
// just this one field. Called once per directory ext2_delete removes,
// using the *deleted directory's own* group (where its inode lived),
// not the parent's.
fn bool ext2_dec_used_dirs(uint group)
{
	uint descriptors_per_block = ext2_block_size / EXT2_BGD_SIZE;
	uint bgdt_block = ext2_first_data_block + 1 + (group / descriptors_per_block);
	uint offset_in_block = (group % descriptors_per_block) * EXT2_BGD_SIZE + EXT2_BGD_USED_DIRS_COUNT;

	char[EXT2_MAX_BLOCK_SIZE] bgdt_buf @noinit;
	if (!ext2_read_block(bgdt_block, &bgdt_buf)) return false;
	ushort* bg_dirs = (ushort*)&bgdt_buf[offset_in_block];
	if (*bg_dirs > 0) *bg_dirs -= 1;
	return ext2_write_block(bgdt_block, &bgdt_buf);
}

// Inverse of ext2_dec_used_dirs() — same shape, +1 instead of -1.
// Needed by ext2_mkdir (below): the new directory's own group, not the
// parent's, same convention ext2_dec_used_dirs already uses.
fn bool ext2_inc_used_dirs(uint group)
{
	uint descriptors_per_block = ext2_block_size / EXT2_BGD_SIZE;
	uint bgdt_block = ext2_first_data_block + 1 + (group / descriptors_per_block);
	uint offset_in_block = (group % descriptors_per_block) * EXT2_BGD_SIZE + EXT2_BGD_USED_DIRS_COUNT;

	char[EXT2_MAX_BLOCK_SIZE] bgdt_buf @noinit;
	if (!ext2_read_block(bgdt_block, &bgdt_buf)) return false;
	ushort* bg_dirs = (ushort*)&bgdt_buf[offset_in_block];
	*bg_dirs += 1;
	return ext2_write_block(bgdt_block, &bgdt_buf);
}

// Linear scan of every group's block bitmap, group 0 first, for a
// clear bit — not group-0-only anymore, so this driver's own writes
// aren't confined there as it fills up (see EXT2_MAX_GROUPS's own
// comment). Marks it set immediately, before returning it, closing the
// window where a second allocation later in the same request could
// pick the same block twice (same reasoning as fat32_alloc_cluster's
// own immediate-mark). Returns 0 (never a valid block number — block 0
// is always either unused or the boot block, never allocatable) once
// every group has been scanned with nothing free, or on any read/write
// failure along the way.
fn uint ext2_alloc_block()
{
	for (uint group = 0; group < ext2_group_count; group++)
	{
		char[EXT2_MAX_BLOCK_SIZE] bitmap_buf @noinit;
		if (!ext2_read_block(ext2_block_bitmap_blocks[group], &bitmap_buf)) return 0;

		for (uint i = 0; i < ext2_blocks_per_group; i++)
		{
			uint byte_i = i / 8;
			uint bit_i = i % 8;
			uint b = (uint)bitmap_buf[byte_i] & 0xFF;
			if ((b & (1 << bit_i)) == 0)
			{
				bitmap_buf[byte_i] = (char)(b | (1 << bit_i));
				if (!ext2_write_block(ext2_block_bitmap_blocks[group], &bitmap_buf)) return 0;
				if (!ext2_dec_free_blocks(group)) return 0;
				return ext2_first_data_block + group * ext2_blocks_per_group + i;
			}
		}
	}
	return 0;
}

// Same shape as ext2_alloc_block(), against every group's inode
// bitmap. Returns a 1-based inode number (0 = none free). Reserved
// inodes (1-10, group 0 only) are already marked used by mke2fs at
// format time, so a plain first-clear-bit scan naturally skips them —
// no special-cased reserved-inode-number logic needed.
fn uint ext2_alloc_inode()
{
	for (uint group = 0; group < ext2_group_count; group++)
	{
		char[EXT2_MAX_BLOCK_SIZE] bitmap_buf @noinit;
		if (!ext2_read_block(ext2_inode_bitmap_blocks[group], &bitmap_buf)) return 0;

		for (uint i = 0; i < ext2_inodes_per_group; i++)
		{
			uint byte_i = i / 8;
			uint bit_i = i % 8;
			uint b = (uint)bitmap_buf[byte_i] & 0xFF;
			if ((b & (1 << bit_i)) == 0)
			{
				bitmap_buf[byte_i] = (char)(b | (1 << bit_i));
				if (!ext2_write_block(ext2_inode_bitmap_blocks[group], &bitmap_buf)) return 0;
				if (!ext2_dec_free_inodes(group)) return 0;
				return group * ext2_inodes_per_group + i + 1;
			}
		}
	}
	return 0;
}

// Inverse of ext2_alloc_block() — clears `block`'s bit in its own
// group's block bitmap and bumps both free-count copies back up. The
// absolute-to-(group, bit) math is the exact inverse of ext2_alloc_
// block()'s own `ext2_first_data_block + group * ext2_blocks_per_group
// + i` — see its comment.
fn bool ext2_free_block(uint block)
{
	uint group = (block - ext2_first_data_block) / ext2_blocks_per_group;
	uint bit_index = (block - ext2_first_data_block) % ext2_blocks_per_group;
	if (group >= ext2_group_count) return false;

	char[EXT2_MAX_BLOCK_SIZE] bitmap_buf @noinit;
	if (!ext2_read_block(ext2_block_bitmap_blocks[group], &bitmap_buf)) return false;
	uint byte_i = bit_index / 8;
	uint bit_i = bit_index % 8;
	uint b = (uint)bitmap_buf[byte_i] & 0xFF;
	bitmap_buf[byte_i] = (char)(b & ~(1 << bit_i));
	if (!ext2_write_block(ext2_block_bitmap_blocks[group], &bitmap_buf)) return false;
	return ext2_inc_free_blocks(group);
}

// Inverse of ext2_alloc_inode() — same shape as ext2_free_block(),
// against the inode bitmap.
fn bool ext2_free_inode(uint inode_num)
{
	uint group = (inode_num - 1) / ext2_inodes_per_group;
	uint bit_index = (inode_num - 1) % ext2_inodes_per_group;
	if (group >= ext2_group_count) return false;

	char[EXT2_MAX_BLOCK_SIZE] bitmap_buf @noinit;
	if (!ext2_read_block(ext2_inode_bitmap_blocks[group], &bitmap_buf)) return false;
	uint byte_i = bit_index / 8;
	uint bit_i = bit_index % 8;
	uint b = (uint)bitmap_buf[byte_i] & 0xFF;
	bitmap_buf[byte_i] = (char)(b & ~(1 << bit_i));
	if (!ext2_write_block(ext2_inode_bitmap_blocks[group], &bitmap_buf)) return false;
	return ext2_inc_free_inodes(group);
}

// Patches mode/size/links_count/blocks/block[] into inode_num's
// existing on-disk record — read-modify-write, like
// fat32_write_fat_entry. Leaves every other field (timestamps, etc.)
// as whatever was already there; for a freshly allocated inode, the
// caller runs ext2_zero_inode() first so there's nothing stale left
// in those fields.
fn bool ext2_write_inode(uint inode_num, Ext2_inode_info* info)
{
	if (inode_num == 0) return false;

	// Same group-aware lookup as ext2_read_inode — see its own comment.
	// Updating an *existing* inode's fields (e.g. overwriting a file's
	// content) needs to reach whatever group it's really in — same as
	// ext2_alloc_inode(), which also scans every group now.
	uint group = (inode_num - 1) / ext2_inodes_per_group;
	if (group >= ext2_group_count) return false;
	uint index_in_group = (inode_num - 1) % ext2_inodes_per_group;

	uint byte_offset_in_table = index_in_group * ext2_inode_size;
	uint block_offset = byte_offset_in_table / ext2_block_size;
	uint offset_in_block = byte_offset_in_table % ext2_block_size;

	char[EXT2_MAX_BLOCK_SIZE] block_buf @noinit;
	if (!ext2_read_block(ext2_inode_table_blocks[group] + block_offset, &block_buf)) return false;

	char* inode_bytes = &block_buf[offset_in_block];
	ushort* mode_field        = (ushort*)&inode_bytes[EXT2_INODE_MODE];
	uint*   size_field        = (uint*)&inode_bytes[EXT2_INODE_SIZE];
	ushort* links_count_field = (ushort*)&inode_bytes[EXT2_INODE_LINKS_COUNT];
	uint*   blocks_field      = (uint*)&inode_bytes[EXT2_INODE_BLOCKS];
	*mode_field        = (ushort)info.mode;
	*size_field        = info.size;
	*links_count_field = (ushort)info.links_count;
	*blocks_field      = info.blocks;
	uint* block_ptrs = (uint*)&inode_bytes[EXT2_INODE_BLOCK];
	mem::copy(block_ptrs, &info.block, 48); // 12 uint (4 bytes each) direct block pointers

	return ext2_write_block(ext2_inode_table_blocks[group] + block_offset, &block_buf);
}

// Zeroes a freshly allocated inode's ENTIRE on-disk record (all
// ext2_inode_size bytes, not just the mode/size/block fields
// ext2_write_inode touches) before that function sets specific fields —
// otherwise stale bytes from whatever inode number was last recycled
// (old timestamps, old block pointers past [0..11] this driver never
// reads but a real ext2 tool would) would leak into the "new" file's
// metadata. Parallels fat32_create_file's own "zero the reserved/date
// fields on a reused deleted slot" correctness step.
//
// Group-aware, same as ext2_read_inode/ext2_write_inode: now that
// ext2_alloc_inode() scans every group, the inode it just allocated
// isn't guaranteed to be in group 0 anymore.
fn bool ext2_zero_inode(uint inode_num)
{
	uint group = (inode_num - 1) / ext2_inodes_per_group;
	if (group >= ext2_group_count) return false;
	uint index_in_group = (inode_num - 1) % ext2_inodes_per_group;

	uint byte_offset_in_table = index_in_group * ext2_inode_size;
	uint block_offset = byte_offset_in_table / ext2_block_size;
	uint offset_in_block = byte_offset_in_table % ext2_block_size;

	char[EXT2_MAX_BLOCK_SIZE] block_buf @noinit;
	if (!ext2_read_block(ext2_inode_table_blocks[group] + block_offset, &block_buf)) return false;
	for (uint i = 0; i < ext2_inode_size; i++) block_buf[offset_in_block + i] = 0;
	return ext2_write_block(ext2_inode_table_blocks[group] + block_offset, &block_buf);
}

// Finds a directory-entry slot to write a new entry into, reusing an
// existing, allocated-but-logically-empty block (one whose own single
// entry was deleted) if one exists, only allocating a genuinely new
// block if none is found. Without this, a directory block slot never
// gets reclaimed after delete/rename removes an entry (only the
// entry's own entry_inode field gets cleared — see
// ext2_delete_recursive/ext2_rename's own comments — never the block
// itself), so a directory that sees repeated create/delete activity
// (exactly what /tmp sees) would otherwise permanently exhaust its
// 12-direct-block limit after just a handful of cycles, even though it
// never holds more than a few live entries at once. Found exactly this
// way: a stress test doing repeated mkdir/rename/delete cycles under
// /tmp reliably exhausted its 12 slots after ~3 cycles — which then
// looked exactly like e2fsck-visible corruption (a later create
// silently failing after already having allocated a real, valid child
// inode, orphaning it — see ext2_create_file/ext2_mkdir's own rollback
// for the other half of that fix), not a resource-exhaustion refusal.
//
// Returns false only if the directory is genuinely full (12 slots, all
// holding a live entry) or on a real I/O error. On success, fills
// *out_block with the block to write the new entry into, and
// *out_needs_link with whether `dir` itself still needs updating
// (dir.block[*out_new_slot] = *out_block, plus size/blocks) — false
// when reusing an existing slot (dir already points at this block),
// true when a genuinely new one was allocated.
fn bool ext2_find_or_reuse_dir_slot(Ext2_inode_info* dir, uint* out_block, bool* out_needs_link, uint* out_new_slot)
{
	uint free_slot = 12; // sentinel: no unallocated slot found yet
	for (uint s = 0; s < 12; s++)
	{
		if (dir.block[s] == 0)
		{
			if (free_slot == 12) free_slot = s;
			continue;
		}
		char[EXT2_MAX_BLOCK_SIZE] existing_buf @noinit;
		if (!ext2_read_block(dir.block[s], &existing_buf)) return false;
		uint* existing_inode = (uint*)&existing_buf[EXT2_DIRENT_INODE];
		if (*existing_inode == 0)
		{
			*out_block = dir.block[s];
			*out_needs_link = false;
			return true;
		}
	}

	if (free_slot >= 12) return false; // genuinely full

	uint new_block = ext2_alloc_block();
	if (new_block == 0) return false;
	*out_block = new_block;
	*out_needs_link = true;
	*out_new_slot = free_slot;
	return true;
}

// Creates a new, empty (zero-size) inode for `name` and links it into
// the root directory. Fails outright if the root's own 12 direct blocks
// are already all in use — a real v1 limit (see this file's header
// comment), not silently worked around by splitting an existing entry's
// trailing space.
// dir_inode_num is the containing directory (root or a subdirectory —
// see ext2_write's own comment on write-into-subdirectory support), not
// always EXT2_ROOT_INODE anymore.
fn bool ext2_create_file(uint dir_inode_num, char* name, uint* out_inode_num)
{
	uint inode_num = ext2_alloc_inode();
	if (inode_num == 0) return false;
	if (!ext2_zero_inode(inode_num)) return false;

	Ext2_inode_info new_inode;
	new_inode.mode = EXT2_S_IFREG | 0x1A4; // 0644 permissions
	new_inode.size = 0;
	// Real hardware bug, found and fixed this session (see
	// EXT2_INODE_LINKS_COUNT's own comment): a freshly zeroed inode has
	// links_count 0, which is what dtime-0-but-unreferenced-looking
	// means to a real ext2 reader — this is what actually makes the
	// inode a live, referenced file rather than a mode/size/blocks
	// record that happens to have a directory entry pointing at it.
	new_inode.links_count = 1;
	new_inode.blocks = 0; // freshly created, no data blocks yet
	for (uint i = 0; i < 12; i++) new_inode.block[i] = 0;
	if (!ext2_write_inode(inode_num, &new_inode)) return false;

	Ext2_inode_info dir;
	if (!ext2_read_inode(dir_inode_num, &dir)) return false;

	uint new_block;
	bool needs_link;
	uint new_slot;
	if (!ext2_find_or_reuse_dir_slot(&dir, &new_block, &needs_link, &new_slot))
	{
		// Directory genuinely full (or a real I/O error) — the inode
		// allocated above would otherwise leak, unreferenced by
		// anything, forever. See ext2_find_or_reuse_dir_slot's own
		// comment.
		ext2_free_inode(inode_num);
		return false;
	}

	uint name_len = ext2_strlen(name);
	char[EXT2_MAX_BLOCK_SIZE] block_buf @noinit;
	for (uint i = 0; i < EXT2_MAX_BLOCK_SIZE; i++) block_buf[i] = 0;
	uint*   entry_inode   = (uint*)&block_buf[EXT2_DIRENT_INODE];
	ushort* rec_len_field = (ushort*)&block_buf[EXT2_DIRENT_REC_LEN];
	*entry_inode = inode_num;
	*rec_len_field = (ushort)ext2_block_size; // whole block, one entry
	block_buf[EXT2_DIRENT_NAME_LEN] = (char)name_len;
	block_buf[7] = 0; // file_type — left unset; this driver's own reader never consults it
	for (uint i = 0; i < name_len; i++) block_buf[EXT2_DIRENT_NAME + i] = name[i];

	if (!ext2_write_block(new_block, &block_buf)) return false;

	if (needs_link)
	{
		dir.block[new_slot] = new_block;
		dir.size += ext2_block_size; // kept correct — real ext2 readers use a directory's own size to know how far to scan its blocks
		// Second real-hardware bug fixed alongside links_count above:
		// i_blocks (512-byte sectors, a separate field from i_size —
		// see EXT2_INODE_BLOCKS's own comment) was never bumped when a
		// directory gained a new block, caught by e2fsck as a real
		// inconsistency on the actual boot card.
		dir.blocks += ext2_block_size / SECTOR_SIZE;
		if (!ext2_write_inode(dir_inode_num, &dir)) return false;
	}

	*out_inode_num = inode_num;
	return true;
}

// Writes `len` bytes from `src` into inode.block[0..11], starting from
// the beginning of the file, allocating new blocks as needed (up to the
// 12-direct-block limit — see this file's header comment). Mutates
// `inode.block[]` in place as it allocates; the caller writes the inode
// back afterward, once, with the final size (simpler than threading a
// separate "was this slot newly allocated" signal back out — same
// reasoning fat32_write_file's own header comment gives). Returns the
// number of bytes actually written — short, not an error, if `len`
// needs more than 12 blocks or a write fails partway through.
fn uint ext2_write_file(Ext2_inode_info* inode, char* src, uint len)
{
	uint bytes_written = 0;
	uint b = 0;
	while (bytes_written < len && b < 12)
	{
		uint block = inode.block[b];
		if (block == 0)
		{
			block = ext2_alloc_block();
			if (block == 0) break;
			inode.block[b] = block;
			// Same real-hardware i_blocks bug fixed in ext2_create_file
			// (see EXT2_INODE_BLOCKS's own comment) — only for a
			// genuinely new block, not one already counted from a
			// previous write that's merely being overwritten in place.
			inode.blocks += ext2_block_size / SECTOR_SIZE;
		}

		uint chunk = len - bytes_written;
		if (chunk > ext2_block_size) chunk = ext2_block_size;

		char[EXT2_MAX_BLOCK_SIZE] block_buf @noinit;
		if (chunk < ext2_block_size)
		{
			// Partial-block write: read the real, existing content
			// first so bytes beyond `chunk` in this block (if any) keep
			// their current on-disk value — matches
			// fat32_write_file's own read-what's-really-there
			// discipline.
			if (!ext2_read_block(block, &block_buf)) break;
		}
		for (uint i = 0; i < chunk; i++) block_buf[i] = src[bytes_written + i];
		if (!ext2_write_block(block, &block_buf)) break;

		bytes_written += chunk;
		b++;
	}
	return bytes_written;
}

// Entry point dispatched from fsd.c3's main() for FS_WRITE. Only ever
// called once fsd.c3's own fs_is_protected_name() check has already
// passed, so no protected-name check here — but fs_is_protected_entry()
// IS checked here, as a backstop that doesn't depend on that string
// comparison staying correct (see fs_protected_entry_sector's own
// comment in fsd.c3). One check site covers both the create-then-write
// and plain-overwrite paths, since both end up here before the final
// inode write. fs_write_disabled and the reserved-sector-range check
// are enforced even lower, in fs_write_sector (via diskd_rw), so not
// duplicated here either.
// Write-into-subdirectory: resolves the containing directory the same
// way ext2_read does (ext2_resolve_dir/ext2_leaf_name), then does
// everything else — existence check, create — against that directory's
// inode instead of always the root. ext2_find_in_root/its own root-only
// callers below (ext2_reserve_protected) are untouched: the one file
// that ever needs protecting (fip.bin) is always in the root.
fn int ext2_write(char* name, char* src, uint len)
{
	uint dir_inode;
	if (!ext2_resolve_dir(name, &dir_inode)) return -1;
	char* leaf = ext2_leaf_name(name);

	uint inode_num;
	uint entry_sector;
	uint entry_offset;
	uint mode;
	bool exists = ext2_find_in_dir(dir_inode, leaf, &inode_num, &entry_sector, &entry_offset, &mode);
	// A directory isn't file content — refuse rather than overwrite
	// whatever it points at, same refusal ext2_read gives.
	if (exists && (mode & EXT2_S_IFDIR) != 0) return -1;

	if (!exists)
	{
		if (!ext2_create_file(dir_inode, leaf, &inode_num)) return -1;
		if (!ext2_find_in_dir(dir_inode, leaf, &inode_num, &entry_sector, &entry_offset, &mode)) return -1;
	}

	if (fs_is_protected_entry(entry_sector, entry_offset)) return -1;

	Ext2_inode_info inode;
	if (!ext2_read_inode(inode_num, &inode)) return -1;

	uint written = ext2_write_file(&inode, src, len);
	inode.size = written;

	if (!ext2_write_inode(inode_num, &inode)) return -1;

	return (int)written;
}

// Checks whether a directory's own data blocks contain any real entry
// besides "." and ".." (every subdirectory's own two self/parent
// entries — ext2 names aren't space-padded like FAT32's, so these are
// matched by exact name_len + bytes instead). Fails closed (returns
// false, "not empty") on any read error, rather than risk letting
// ext2_delete free a directory it couldn't actually confirm was empty.
fn bool ext2_dir_is_empty(Ext2_inode_info* dir)
{
	for (uint b = 0; b < 12; b++)
	{
		uint block = dir.block[b];
		if (block == 0) continue;

		char[EXT2_MAX_BLOCK_SIZE] block_buf @noinit;
		if (!ext2_read_block(block, &block_buf)) return false;

		uint offset = 0;
		while (offset < ext2_block_size)
		{
			char* entry = &block_buf[offset];
			uint*  entry_inode    = (uint*)&entry[EXT2_DIRENT_INODE];
			ushort* rec_len_field = (ushort*)&entry[EXT2_DIRENT_REC_LEN];
			char   name_len_byte  = entry[EXT2_DIRENT_NAME_LEN];

			uint rec_len = (uint)*rec_len_field;
			if (rec_len == 0) break;

			uint entry_name_len = (uint)name_len_byte & 0xFF;
			if (*entry_inode != 0)
			{
				bool is_dot    = entry_name_len == 1 && entry[EXT2_DIRENT_NAME] == '.';
				bool is_dotdot = entry_name_len == 2 && entry[EXT2_DIRENT_NAME] == '.' && entry[EXT2_DIRENT_NAME + 1] == '.';
				if (!is_dot && !is_dotdot) return false;
			}

			offset += rec_len;
		}
	}
	return true;
}

// Entry point dispatched from fsd.c3's main() for a non-recursive
// FS_DELETE. Handles both a regular file and an *empty* directory
// (ext2_dir_is_empty, above — a non-empty one is refused, matching
// real rmdir()'s own semantics: no recursive auto-delete here; see
// ext2_delete_recursive below for that).
//
// Order matters, same "fail toward leak, not corruption" reasoning as
// fat32_delete's own comment: clear the directory entry first (makes
// the file unreachable via lookup), then zero the inode's own record
// (drops stale metadata — mirrors ext2_zero_inode's own reasoning for
// a freshly *allocated* inode, in reverse), then free its data blocks,
// and only once nothing references them anymore, free the inode itself
// — never mark something reusable while anything might still reference
// it.
fn int ext2_delete(char* name)
{
	uint dir_inode;
	if (!ext2_resolve_dir(name, &dir_inode)) return -1;
	char* leaf = ext2_leaf_name(name);

	uint inode_num;
	uint entry_sector;
	uint entry_offset;
	uint mode;
	if (!ext2_find_in_dir(dir_inode, leaf, &inode_num, &entry_sector, &entry_offset, &mode)) return -1;
	if (fs_is_protected_entry(entry_sector, entry_offset)) return -1;

	Ext2_inode_info inode;
	if (!ext2_read_inode(inode_num, &inode)) return -1;

	bool is_dir = (mode & EXT2_S_IFDIR) != 0;
	if (is_dir && !ext2_dir_is_empty(&inode)) return -1;

	char[SECTOR_SIZE] sector_buf @noinit;
	if (!fs_read_sector(entry_sector, &sector_buf)) return -1;
	uint* entry_inode_field = (uint*)&sector_buf[entry_offset + EXT2_DIRENT_INODE];
	*entry_inode_field = 0;
	if (!fs_write_sector(entry_sector, &sector_buf)) return -1;

	if (is_dir)
	{
		// The deleted directory's own ".." entry was a link to its
		// parent — undo that reference now that the directory itself
		// is gone, or a real ext2 reader (this session already found
		// one real, practical consequence of a wrong link count — see
		// EXT2_INODE_LINKS_COUNT's own comment) would see the parent's
		// own link count as one too many.
		Ext2_inode_info parent;
		if (!ext2_read_inode(dir_inode, &parent)) return -1;
		if (parent.links_count > 0) parent.links_count -= 1;
		if (!ext2_write_inode(dir_inode, &parent)) return -1;

		// bg_used_dirs_count tracks how many directories live in the
		// *deleted* directory's own group (where inode_num itself
		// lives), not the parent's — same group math ext2_free_inode
		// uses internally. Real, found-the-hard-way bookkeeping: a
		// real e2fsck flags this specifically ("directory count wrong
		// for group N") if it's left stale, the same class of gap as
		// this session's earlier free-count fix.
		if (!ext2_dec_used_dirs((inode_num - 1) / ext2_inodes_per_group)) return -1;
	}

	if (!ext2_zero_inode(inode_num)) return -1;

	for (uint b = 0; b < 12; b++)
	{
		if (inode.block[b] == 0) continue;
		if (!ext2_free_block(inode.block[b])) return -1;
	}
	if (!ext2_free_inode(inode_num)) return -1;

	return 0;
}

// Defense-in-depth bound on ext2_delete_dir_contents' own recursion —
// see fat32_delete_dir_contents' matching constant for the full
// reasoning (not reachable through a well-formed ext2 tree, but
// nothing on-disk actually prevents a corrupted or adversarial image
// from containing a directory cycle anyway).
const int EXT2_MAX_DELETE_DEPTH = 32;

// Empties a directory's own data blocks by deleting everything inside
// it — files freed directly, subdirectories recursed into first —
// walking raw directory entries the same way ext2_dir_is_empty already
// does. Unlike FAT32, ext2 dirents here carry no file-type byte (see
// ext2_find_in_dir's own comment), so telling a file from a
// subdirectory means reading each child's own inode. dir_inode_num is
// *this* directory's own inode number — needed to patch its
// links_count down by one for every subdirectory removed from inside
// it (undoing that child's own ".." link to it — the same accounting
// ext2_delete's non-recursive path already does for the single
// directory it removes, done here once per removed subdirectory
// instead of once total). depth is the same recursion bound
// fat32_delete_dir_contents uses.
fn bool ext2_delete_dir_contents(uint dir_inode_num, int depth)
{
	if (depth >= EXT2_MAX_DELETE_DEPTH) return false;

	Ext2_inode_info dir;
	if (!ext2_read_inode(dir_inode_num, &dir)) return false;

	for (uint b = 0; b < 12; b++)
	{
		uint block = dir.block[b];
		if (block == 0) continue;

		char[EXT2_MAX_BLOCK_SIZE] block_buf @noinit;
		if (!ext2_read_block(block, &block_buf)) return false;

		bool block_modified = false;
		uint offset = 0;
		while (offset < ext2_block_size)
		{
			char* entry = &block_buf[offset];
			uint*   entry_inode   = (uint*)&entry[EXT2_DIRENT_INODE];
			ushort* rec_len_field = (ushort*)&entry[EXT2_DIRENT_REC_LEN];
			char    name_len_byte = entry[EXT2_DIRENT_NAME_LEN];

			uint rec_len = (uint)*rec_len_field;
			if (rec_len == 0) break;

			uint entry_name_len  = (uint)name_len_byte & 0xFF;
			uint child_inode_num = *entry_inode;
			if (child_inode_num != 0)
			{
				bool is_dot    = entry_name_len == 1 && entry[EXT2_DIRENT_NAME] == '.';
				bool is_dotdot = entry_name_len == 2 && entry[EXT2_DIRENT_NAME] == '.' && entry[EXT2_DIRENT_NAME + 1] == '.';
				if (!is_dot && !is_dotdot)
				{
					uint entry_sector = block * ext2_sectors_per_block + (offset / SECTOR_SIZE);
					uint entry_offset = offset % SECTOR_SIZE;
					if (fs_is_protected_entry(entry_sector, entry_offset)) return false;

					Ext2_inode_info child;
					if (!ext2_read_inode(child_inode_num, &child)) return false;
					bool child_is_dir = (child.mode & EXT2_S_IFDIR) != 0;

					if (child_is_dir)
					{
						if (!ext2_delete_dir_contents(child_inode_num, depth + 1)) return false;

						// child.block[] (read above, before recursing)
						// stays accurate: the recursive call only ever
						// rewrites child_inode_num's own links_count and
						// the *contents* of its data blocks, never which
						// blocks are allocated to it — no re-read needed
						// before freeing those blocks below.
						if (dir.links_count > 0) dir.links_count -= 1;
						if (!ext2_dec_used_dirs((child_inode_num - 1) / ext2_inodes_per_group)) return false;
					}

					if (!ext2_zero_inode(child_inode_num)) return false;
					for (uint cb = 0; cb < 12; cb++)
					{
						if (child.block[cb] == 0) continue;
						if (!ext2_free_block(child.block[cb])) return false;
					}
					if (!ext2_free_inode(child_inode_num)) return false;

					*entry_inode = 0;
					block_modified = true;
				}
			}

			offset += rec_len;
		}
		if (block_modified)
		{
			if (!ext2_write_block(block, &block_buf)) return false;
		}
	}

	return ext2_write_inode(dir_inode_num, &dir);
}

// Same as ext2_delete, but a non-empty directory is emptied first
// (ext2_delete_dir_contents, above) instead of refused — the real,
// separate, genuinely destructive operation ext2_delete's own comment
// deliberately deferred. A protected entry anywhere in the subtree
// (checked by ext2_delete_dir_contents for every child, and here for
// the target itself) aborts the whole operation before anything is
// freed — never a partial delete that silently skips just the
// protected part.
fn int ext2_delete_recursive(char* name)
{
	uint dir_inode;
	if (!ext2_resolve_dir(name, &dir_inode)) return -1;
	char* leaf = ext2_leaf_name(name);

	uint inode_num;
	uint entry_sector;
	uint entry_offset;
	uint mode;
	if (!ext2_find_in_dir(dir_inode, leaf, &inode_num, &entry_sector, &entry_offset, &mode)) return -1;
	if (fs_is_protected_entry(entry_sector, entry_offset)) return -1;

	Ext2_inode_info inode;
	if (!ext2_read_inode(inode_num, &inode)) return -1;

	bool is_dir = (mode & EXT2_S_IFDIR) != 0;
	if (is_dir)
	{
		// inode.block[] (read above) stays accurate across this call —
		// see ext2_delete_dir_contents' own matching comment.
		if (!ext2_delete_dir_contents(inode_num, 0)) return -1;
	}

	char[SECTOR_SIZE] sector_buf @noinit;
	if (!fs_read_sector(entry_sector, &sector_buf)) return -1;
	uint* entry_inode_field = (uint*)&sector_buf[entry_offset + EXT2_DIRENT_INODE];
	*entry_inode_field = 0;
	if (!fs_write_sector(entry_sector, &sector_buf)) return -1;

	if (is_dir)
	{
		Ext2_inode_info parent;
		if (!ext2_read_inode(dir_inode, &parent)) return -1;
		if (parent.links_count > 0) parent.links_count -= 1;
		if (!ext2_write_inode(dir_inode, &parent)) return -1;

		if (!ext2_dec_used_dirs((inode_num - 1) / ext2_inodes_per_group)) return -1;
	}

	if (!ext2_zero_inode(inode_num)) return -1;

	for (uint b = 0; b < 12; b++)
	{
		if (inode.block[b] == 0) continue;
		if (!ext2_free_block(inode.block[b])) return -1;
	}
	if (!ext2_free_inode(inode_num)) return -1;

	return 0;
}

// Entry point dispatched from fsd.c3's main() for FS_LIST. Same
// scope/limits as fat32_list's own comment (single reply, no
// pagination, "."/".." skipped). Unlike FAT32, ext2 names aren't
// space-padded or 8.3-truncated — copied verbatim, capped at
// FS_LIST_NAME_MAX (a real ext2 name can be longer; this driver has no
// long-name support to round-trip through on the read side either, so
// this matches the rest of it).
fn bool ext2_list(char* path, char* out_buf, int max_entries, int* out_count)
{
	uint dir_inode;
	if (path[0] == 0)
	{
		dir_inode = EXT2_ROOT_INODE;
	}
	else
	{
		uint parent_inode;
		if (!ext2_resolve_dir(path, &parent_inode)) return false;
		char* leaf = ext2_leaf_name(path);
		uint inode_num;
		uint entry_sector;
		uint entry_offset;
		uint mode;
		if (!ext2_find_in_dir(parent_inode, leaf, &inode_num, &entry_sector, &entry_offset, &mode)) return false;
		if ((mode & EXT2_S_IFDIR) == 0) return false;
		dir_inode = inode_num;
	}

	Ext2_inode_info dir;
	if (!ext2_read_inode(dir_inode, &dir)) return false;

	int count = 0;
	for (uint b = 0; b < 12 && count < max_entries; b++)
	{
		uint block = dir.block[b];
		if (block == 0) continue;

		char[EXT2_MAX_BLOCK_SIZE] block_buf @noinit;
		if (!ext2_read_block(block, &block_buf)) return false;

		uint offset = 0;
		while (offset < ext2_block_size && count < max_entries)
		{
			char* entry = &block_buf[offset];
			uint*   entry_inode   = (uint*)&entry[EXT2_DIRENT_INODE];
			ushort* rec_len_field = (ushort*)&entry[EXT2_DIRENT_REC_LEN];
			char    name_len_byte = entry[EXT2_DIRENT_NAME_LEN];

			uint rec_len = (uint)*rec_len_field;
			if (rec_len == 0) break;

			uint entry_name_len = (uint)name_len_byte & 0xFF;
			if (*entry_inode != 0)
			{
				bool is_dot    = entry_name_len == 1 && entry[EXT2_DIRENT_NAME] == '.';
				bool is_dotdot = entry_name_len == 2 && entry[EXT2_DIRENT_NAME] == '.' && entry[EXT2_DIRENT_NAME + 1] == '.';
				if (!is_dot && !is_dotdot)
				{
					Ext2_inode_info child;
					if (!ext2_read_inode(*entry_inode, &child)) return false;

					char* rec = &out_buf[(uint)count * FS_LIST_ENTRY_SIZE];
					uint copy_len = entry_name_len;
					if (copy_len > FS_LIST_NAME_MAX - 1) copy_len = FS_LIST_NAME_MAX - 1;
					for (uint k = 0; k < copy_len; k++) rec[k] = entry[EXT2_DIRENT_NAME + k];
					rec[copy_len] = 0;
					rec[FS_LIST_NAME_MAX] = ((child.mode & EXT2_S_IFDIR) != 0) ? (char)1 : (char)0;
					count++;
				}
			}

			offset += rec_len;
		}
	}
	*out_count = count;
	return true;
}

// Entry point dispatched from fsd.c3's main() for FS_MKDIR. Creates an
// empty directory at `path` — refuses if anything already exists
// there, or if the parent doesn't. Self-contained rather than sharing
// ext2_create_file's own "allocate a block, add a dirent to the
// parent" logic: close enough in shape, but a directory also needs its
// own data block pre-seeded with real "." and ".." entries and an
// extra links_count bump on the *parent* (its own ".." now references
// it) that ext2_create_file has no reason to do for a regular file —
// same "self-contained rather than force a shared abstraction" choice
// fat32_mkdir makes for the same reason.
//
// mode 0x41ED = EXT2_S_IFDIR | 0755 — the standard real-world value
// for an ordinary directory (same permission convention
// ext2_create_file's own 0644 already follows for regular files).
fn int ext2_mkdir(char* path)
{
	uint parent_inode;
	if (!ext2_resolve_dir(path, &parent_inode)) return -1;
	char* leaf = ext2_leaf_name(path);

	uint existing_inode;
	uint existing_sector;
	uint existing_offset;
	uint existing_mode;
	if (ext2_find_in_dir(parent_inode, leaf, &existing_inode, &existing_sector, &existing_offset, &existing_mode))
	{
		return -1; // already exists
	}

	uint new_inode_num = ext2_alloc_inode();
	if (new_inode_num == 0) return -1;
	if (!ext2_zero_inode(new_inode_num)) return -1;

	uint new_block = ext2_alloc_block();
	if (new_block == 0) { ext2_free_inode(new_inode_num); return -1; }

	char[EXT2_MAX_BLOCK_SIZE] block_buf @noinit;
	for (uint i = 0; i < EXT2_MAX_BLOCK_SIZE; i++) block_buf[i] = 0;

	uint*   dot_inode   = (uint*)&block_buf[EXT2_DIRENT_INODE];
	ushort* dot_rec_len = (ushort*)&block_buf[EXT2_DIRENT_REC_LEN];
	*dot_inode = new_inode_num;
	*dot_rec_len = 12; // 4 (inode) + 2 (rec_len) + 1 (name_len) + 1 (file_type) + 1 (".") rounded to 4
	block_buf[EXT2_DIRENT_NAME_LEN] = (char)1;
	block_buf[EXT2_DIRENT_NAME] = '.';

	uint*   dotdot_inode   = (uint*)&block_buf[12 + EXT2_DIRENT_INODE];
	ushort* dotdot_rec_len = (ushort*)&block_buf[12 + EXT2_DIRENT_REC_LEN];
	*dotdot_inode = parent_inode;
	*dotdot_rec_len = (ushort)(ext2_block_size - 12); // fills the rest of the block, standard ext2 convention
	block_buf[12 + EXT2_DIRENT_NAME_LEN] = (char)2;
	block_buf[12 + EXT2_DIRENT_NAME] = '.';
	block_buf[12 + EXT2_DIRENT_NAME + 1] = '.';

	if (!ext2_write_block(new_block, &block_buf)) return -1;

	Ext2_inode_info new_inode;
	new_inode.mode = EXT2_S_IFDIR | 0x1ED;
	new_inode.size = ext2_block_size;
	// 2, not 1: one for the parent's own directory entry pointing at
	// this inode, one for this directory's own "." entry pointing at
	// itself — same real-hardware-verified reasoning as
	// ext2_create_file's own links_count comment, extended by the one
	// extra self-reference every directory (but no regular file) has.
	new_inode.links_count = 2;
	new_inode.blocks = ext2_block_size / SECTOR_SIZE;
	new_inode.block[0] = new_block;
	for (uint i = 1; i < 12; i++) new_inode.block[i] = 0;
	if (!ext2_write_inode(new_inode_num, &new_inode)) return -1;

	Ext2_inode_info parent;
	if (!ext2_read_inode(parent_inode, &parent)) return -1;

	uint parent_block;
	bool needs_link;
	uint new_slot;
	if (!ext2_find_or_reuse_dir_slot(&parent, &parent_block, &needs_link, &new_slot))
	{
		// Parent genuinely full (or a real I/O error) — the child
		// directory we just fully built (inode + its own "."/".."
		// block) would otherwise leak, unreferenced by anything,
		// forever. See ext2_find_or_reuse_dir_slot's own comment.
		ext2_free_block(new_block);
		ext2_free_inode(new_inode_num);
		return -1;
	}

	uint name_len = ext2_strlen(leaf);
	char[EXT2_MAX_BLOCK_SIZE] parent_block_buf @noinit;
	for (uint i = 0; i < EXT2_MAX_BLOCK_SIZE; i++) parent_block_buf[i] = 0;
	uint*   entry_inode_field   = (uint*)&parent_block_buf[EXT2_DIRENT_INODE];
	ushort* entry_rec_len_field = (ushort*)&parent_block_buf[EXT2_DIRENT_REC_LEN];
	*entry_inode_field = new_inode_num;
	*entry_rec_len_field = (ushort)ext2_block_size; // whole block, one entry
	parent_block_buf[EXT2_DIRENT_NAME_LEN] = (char)name_len;
	for (uint i = 0; i < name_len; i++) parent_block_buf[EXT2_DIRENT_NAME + i] = leaf[i];

	if (!ext2_write_block(parent_block, &parent_block_buf)) return -1;

	if (needs_link)
	{
		parent.block[new_slot] = parent_block;
		parent.size += ext2_block_size;
		parent.blocks += ext2_block_size / SECTOR_SIZE;
	}
	parent.links_count += 1; // the new subdirectory's own ".." now references this one — always needed, regardless of slot reuse
	if (!ext2_write_inode(parent_inode, &parent)) return -1;

	if (!ext2_inc_used_dirs((new_inode_num - 1) / ext2_inodes_per_group)) return -1;

	return 0;
}

// dir_inode_num's own ".." entry — always its block[0], universal ext2
// convention (a directory's "."/".." pair is always one preformatted
// block, packed together — see ext2_mkdir's own dotdot_inode write,
// and ext2_rename's existing moved-directory fixup below, which reads
// this exact same block[0]/offset-12 shape already). No "0 means root"
// translation needed the way fat32_get_parent_cluster has: this
// driver's own ext2_mkdir always writes the real parent_inode value
// directly, and root's own ".." (pre-formatted by mke2fs, never
// written by this driver) already points at EXT2_ROOT_INODE itself.
fn uint ext2_get_parent_inode(uint dir_inode_num)
{
	Ext2_inode_info dir;
	if (!ext2_read_inode(dir_inode_num, &dir)) return EXT2_ROOT_INODE;
	char[EXT2_MAX_BLOCK_SIZE] block_buf @noinit;
	if (!ext2_read_block(dir.block[0], &block_buf)) return EXT2_ROOT_INODE;
	uint* dotdot_inode = (uint*)&block_buf[12 + EXT2_DIRENT_INODE];
	return *dotdot_inode;
}

// Same shape as fat32_would_create_cycle — see its own comment for the
// full reasoning, including why FAT32_MAX_DELETE_DEPTH's ext2 sibling
// (EXT2_MAX_DELETE_DEPTH) is the right bound to reuse here too.
fn bool ext2_would_create_cycle(uint candidate_dir_inode, uint forbidden_inode)
{
	uint inode_num = candidate_dir_inode;
	for (int depth = 0; depth < EXT2_MAX_DELETE_DEPTH; depth++)
	{
		if (inode_num == forbidden_inode) return true;
		if (inode_num == EXT2_ROOT_INODE) return false;
		inode_num = ext2_get_parent_inode(inode_num);
	}
	return true; // depth exhausted without reaching root — refuse rather than risk missing a real cycle
}

// Entry point dispatched from fsd.c3's main() for FS_RENAME. Same
// scope as fat32_rename's own comment (uniform same-parent-or-not
// handling, destination-must-not-exist) — and, unlike when that
// comment was originally written, cycle detection too: see
// ext2_would_create_cycle's own comment. Genuinely cheap on ext2
// specifically: a directory entry is just a name -> inode_num link, so
// moving a file or directory never touches its data at all, only the
// entry that points at it — same "one new dirent, one removed dirent"
// shape as fat32_rename, just without any cluster/size copying since
// ext2's own dirent format doesn't carry either.
fn int ext2_rename(char* old_path, char* new_path)
{
	uint old_parent_inode;
	if (!ext2_resolve_dir(old_path, &old_parent_inode)) return -1;
	char* old_leaf = ext2_leaf_name(old_path);

	uint inode_num;
	uint old_entry_sector;
	uint old_entry_offset;
	uint mode;
	if (!ext2_find_in_dir(old_parent_inode, old_leaf, &inode_num, &old_entry_sector, &old_entry_offset, &mode)) return -1;
	if (fs_is_protected_entry(old_entry_sector, old_entry_offset)) return -1;

	uint new_parent_inode;
	if (!ext2_resolve_dir(new_path, &new_parent_inode)) return -1;
	char* new_leaf = ext2_leaf_name(new_path);

	// Moving a directory: refuse if the destination's own parent chain
	// runs through the directory being moved — see
	// ext2_would_create_cycle's own comment. Files can never create a
	// cycle (they have no children to contain anything), so this only
	// applies to mode's directory bit.
	if ((mode & EXT2_S_IFDIR) != 0 && ext2_would_create_cycle(new_parent_inode, inode_num))
	{
		return -1;
	}

	uint existing_inode;
	uint existing_sector;
	uint existing_offset;
	uint existing_mode;
	if (ext2_find_in_dir(new_parent_inode, new_leaf, &existing_inode, &existing_sector, &existing_offset, &existing_mode))
	{
		return -1; // destination already exists
	}

	Ext2_inode_info new_parent;
	if (!ext2_read_inode(new_parent_inode, &new_parent)) return -1;

	uint new_block;
	bool needs_link;
	uint new_slot;
	if (!ext2_find_or_reuse_dir_slot(&new_parent, &new_block, &needs_link, &new_slot)) return -1; // destination directory genuinely full

	uint name_len = ext2_strlen(new_leaf);
	char[EXT2_MAX_BLOCK_SIZE] block_buf @noinit;
	for (uint i = 0; i < EXT2_MAX_BLOCK_SIZE; i++) block_buf[i] = 0;
	uint*   entry_inode_field   = (uint*)&block_buf[EXT2_DIRENT_INODE];
	ushort* entry_rec_len_field = (ushort*)&block_buf[EXT2_DIRENT_REC_LEN];
	*entry_inode_field = inode_num;
	*entry_rec_len_field = (ushort)ext2_block_size;
	block_buf[EXT2_DIRENT_NAME_LEN] = (char)name_len;
	for (uint i = 0; i < name_len; i++) block_buf[EXT2_DIRENT_NAME + i] = new_leaf[i];
	if (!ext2_write_block(new_block, &block_buf)) return -1;

	if (needs_link)
	{
		new_parent.block[new_slot] = new_block;
		new_parent.size += ext2_block_size;
		new_parent.blocks += ext2_block_size / SECTOR_SIZE;
	}

	bool is_dir = (mode & EXT2_S_IFDIR) != 0;
	bool cross_parent = new_parent_inode != old_parent_inode;

	if (is_dir && cross_parent)
	{
		new_parent.links_count += 1; // moved directory's own ".." now references this parent
	}
	if (needs_link || (is_dir && cross_parent))
	{
		if (!ext2_write_inode(new_parent_inode, &new_parent)) return -1;
	}

	if (is_dir && cross_parent)
	{
		// Fix up the moved directory's own ".." (always its first
		// entry in block[0] — universal ext2 convention, not just this
		// driver's own, so this holds for a directory created by any
		// real tool too) to point at its new parent, then drop the old
		// parent's own link for the one it just lost — inverse of the
		// += above.
		Ext2_inode_info moved;
		if (!ext2_read_inode(inode_num, &moved)) return -1;
		char[EXT2_MAX_BLOCK_SIZE] moved_block_buf @noinit;
		if (!ext2_read_block(moved.block[0], &moved_block_buf)) return -1;
		uint* dotdot_inode = (uint*)&moved_block_buf[12 + EXT2_DIRENT_INODE];
		*dotdot_inode = new_parent_inode;
		if (!ext2_write_block(moved.block[0], &moved_block_buf)) return -1;

		Ext2_inode_info old_parent;
		if (!ext2_read_inode(old_parent_inode, &old_parent)) return -1;
		if (old_parent.links_count > 0) old_parent.links_count -= 1;
		if (!ext2_write_inode(old_parent_inode, &old_parent)) return -1;
	}

	char[SECTOR_SIZE] old_sector_buf @noinit;
	if (!fs_read_sector(old_entry_sector, &old_sector_buf)) return -1;
	uint* old_entry_inode_field = (uint*)&old_sector_buf[old_entry_offset + EXT2_DIRENT_INODE];
	*old_entry_inode_field = 0;
	if (!fs_write_sector(old_entry_sector, &old_sector_buf)) return -1;

	return 0;
}

// Looks up a protected file (plain name, e.g. "fip.bin") and: records
// its directory entry's exact (sector, offset) via
// fs_set_protected_entry() — see that function's own comment in fsd.c3
// for why that's checked separately rather than folded into the range
// allowlist — and reserves every block in its data via
// fs_reserve_sector_range() (safe at that granularity: one block only
// ever belongs to one file's data, unlike the shared root directory). A
// file that isn't found is simply nothing to protect — logged so it's
// visible, not silently skipped. Mirrors fat32_reserve_protected()
// exactly.
//
// A directory sharing the protected name is treated the same as "not
// found" — ext2_find_in_root itself doesn't check type (it's the only
// remaining caller, mount-time only, not the general-purpose lookup
// ext2_read/ext2_write use), so the check happens here instead, right
// after reading the inode this function needed anyway. Reserving a
// directory's own blocks as if they were "the protected file"'s data
// would be a real category error, not just imprecise — this fails
// toward treating a same-named directory as unprotected rather than
// silently reserving the wrong blocks.
fn void ext2_reserve_protected(char* name)
{
	uint inode_num;
	uint entry_sector;
	uint entry_offset;
	if (!ext2_find_in_root(name, &inode_num, &entry_sector, &entry_offset))
	{
		print("fsd: protected file not found, nothing to reserve for it\n");
		return;
	}

	Ext2_inode_info inode;
	if (!ext2_read_inode(inode_num, &inode)) return;
	if ((inode.mode & EXT2_S_IFDIR) != 0)
	{
		print("fsd: protected file not found, nothing to reserve for it\n");
		return;
	}

	fs_set_protected_entry(entry_sector, entry_offset);

	for (uint b = 0; b < 12; b++)
	{
		if (inode.block[b] == 0) continue;
		if (!fs_reserve_sector_range(inode.block[b] * ext2_sectors_per_block, ext2_sectors_per_block)) return;
	}
}
