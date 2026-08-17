module user;

// ext2 backend for fsd (see user/fsd.c3's own header comment for the
// generic core / backend split). Standard, stable public spec (the
// original ext2 on-disk format, unchanged by ext3/ext4's later journal/
// extent additions) — not reverse-engineered.
//
// v1 scope, deliberately limited — applies to both read and write:
//   - Root directory only (inode 2, a format constant — always the root,
//     regardless of what the superblock says), same as FAT32's own v1
//     scope.
//   - Direct block pointers only (i_block[0..11], 12 of them) — single/
//     double/triple indirect blocks are NOT walked. A file needing more
//     than 12 blocks' worth of data reads back short, same "return
//     however many bytes were actually reachable" discipline
//     fat32_read_file uses for a broken chain, not an error.
//   - Block group 0 only — an inode number beyond group 0's own inode
//     count isn't just slow to resolve, it needs group-index math this
//     driver doesn't implement at all; treated as not-found rather than
//     read from the wrong location (see ext2_read_inode's own check).
//   - No directory-entry file-type filtering: the on-disk file_type byte
//     (only populated if the volume has that optional feature flag) is
//     never consulted, so a directory sharing a requested file's name
//     would be treated as a matching "file" and its own data blocks read
//     as if they were file content. Narrow, known gap — not fixed here.
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
//   - Free-space bookkeeping (bg_free_blocks_count/bg_free_inodes_count
//     in the block group descriptor, the matching s_free_* superblock
//     fields) is NOT maintained — a real e2fsck would flag the mismatch
//     and offer to fix it, but nothing about it corrupts data or blocks
//     a real ext2 driver from reading the volume correctly. Accepted,
//     documented gap, not solved here.
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
const uint EXT2_SUPERBLOCK_SECTOR   = 2;
const uint EXT2_SB_LOG_BLOCK_SIZE   = 24; // u32
const uint EXT2_SB_BLOCKS_PER_GROUP = 32; // u32
const uint EXT2_SB_INODES_PER_GROUP = 40; // u32
const uint EXT2_SB_FIRST_DATA_BLOCK = 20; // u32
const uint EXT2_SB_MAGIC            = 56; // u16, must be 0xEF53
const uint EXT2_SB_REV_LEVEL        = 76; // u32, 0 = original (fixed 128-byte inodes), >=1 = dynamic
const uint EXT2_SB_INODE_SIZE       = 88; // u16, only meaningful if rev_level >= 1

// Block group descriptor (32 bytes), starting in the block immediately
// after the superblock's own block. v1 only ever reads group 0's
// descriptor, the first one in the table.
const uint EXT2_BGD_BLOCK_BITMAP = 0; // u32, block holding this group's block-allocation bitmap
const uint EXT2_BGD_INODE_BITMAP = 4; // u32, block holding this group's inode-allocation bitmap
const uint EXT2_BGD_INODE_TABLE  = 8; // u32, starting block of this group's inode table

// Inode field offsets, relative to the inode's own start.
const uint EXT2_INODE_MODE  = 0;  // u16
const uint EXT2_INODE_SIZE  = 4;  // u32 (low 32 bits — large-file high bits not read, v1)
const uint EXT2_INODE_BLOCK = 40; // u32 x 15 (i_block[0..14]) — v1 only reads [0..11]

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

uint ext2_block_size;
uint ext2_sectors_per_block;
uint ext2_inode_size;
uint ext2_inodes_per_group;
uint ext2_blocks_per_group; // write-path only: ext2_alloc_block()'s scan bound
uint ext2_inode_table_block;
uint ext2_block_bitmap_block; // write-path only
uint ext2_inode_bitmap_block; // write-path only
uint ext2_first_data_block; // write-path only: ext2_alloc_block()'s base for converting a bitmap bit index into a block number

struct Ext2_inode_info
{
	uint mode;
	uint size;
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
	if (inode_num == 0 || inode_num > ext2_inodes_per_group) return false;

	uint index = inode_num - 1;
	uint byte_offset_in_table = index * ext2_inode_size;
	uint block_offset = byte_offset_in_table / ext2_block_size;
	uint offset_in_block = byte_offset_in_table % ext2_block_size;

	char[EXT2_MAX_BLOCK_SIZE] block_buf @noinit;
	if (!ext2_read_block(ext2_inode_table_block + block_offset, &block_buf)) return false;

	char* inode_bytes = &block_buf[offset_in_block];
	ushort* mode_field = (ushort*)&inode_bytes[EXT2_INODE_MODE];
	uint*   size_field = (uint*)&inode_bytes[EXT2_INODE_SIZE];
	out.mode = (uint)*mode_field;
	out.size = *size_field;
	uint* block_ptrs = (uint*)&inode_bytes[EXT2_INODE_BLOCK];
	for (uint i = 0; i < 12; i++) out.block[i] = block_ptrs[i];
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

// Entry point dispatched from fsd.c3's main() for FS_READ. Returns -1
// if not found, else bytes actually read (already clamped to the file's
// real size and to what the direct blocks can reach — see this file's
// header comment).
fn int ext2_read(char* name, char* dst, uint len)
{
	uint inode_num;
	uint entry_sector;
	uint entry_offset;
	if (!ext2_find_in_root(name, &inode_num, &entry_sector, &entry_offset)) return -1;

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
	// after the superblock's own block. v1 only ever reads group 0's
	// descriptor (the first 32 bytes of that block).
	char[EXT2_MAX_BLOCK_SIZE] bgdt_buf @noinit;
	if (!ext2_read_block(ext2_first_data_block + 1, &bgdt_buf))
	{
		fs_panic("failed to read ext2 block group descriptor");
	}
	uint* block_bitmap = (uint*)&bgdt_buf[EXT2_BGD_BLOCK_BITMAP];
	uint* inode_bitmap = (uint*)&bgdt_buf[EXT2_BGD_INODE_BITMAP];
	uint* inode_table   = (uint*)&bgdt_buf[EXT2_BGD_INODE_TABLE];
	ext2_block_bitmap_block = *block_bitmap;
	ext2_inode_bitmap_block = *inode_bitmap;
	ext2_inode_table_block  = *inode_table;

	Ext2_inode_info root;
	if (!ext2_read_inode(EXT2_ROOT_INODE, &root) || (root.mode & EXT2_S_IFDIR) == 0)
	{
		// Root not being a directory means either a corrupt volume or a
		// real limitation of this driver (e.g. the root inode isn't in
		// group 0 on an unusually small inodes-per-group configuration)
		// — panic clearly either way.
		fs_panic("ext2 root inode is not a directory");
	}

	print("fsd: ext2 mounted, block_size=");
	print_uint(ext2_block_size);
	print(" inode_table_block=");
	print_uint(ext2_inode_table_block);
	print("\n");
}

// --- Write path -------------------------------------------------------

// Linear scan of group 0's block bitmap for a clear bit. Marks it set
// immediately, before returning it, closing the window where a second
// allocation later in the same request could pick the same block twice
// (same reasoning as fat32_alloc_cluster's own immediate-mark). Returns
// 0 (never a valid block number — block 0 is always either unused or
// the boot block, never allocatable) on "no free space" or any read/
// write failure along the way.
fn uint ext2_alloc_block()
{
	char[EXT2_MAX_BLOCK_SIZE] bitmap_buf @noinit;
	if (!ext2_read_block(ext2_block_bitmap_block, &bitmap_buf)) return 0;

	for (uint i = 0; i < ext2_blocks_per_group; i++)
	{
		uint byte_i = i / 8;
		uint bit_i = i % 8;
		uint b = (uint)bitmap_buf[byte_i] & 0xFF;
		if ((b & (1 << bit_i)) == 0)
		{
			bitmap_buf[byte_i] = (char)(b | (1 << bit_i));
			if (!ext2_write_block(ext2_block_bitmap_block, &bitmap_buf)) return 0;
			return ext2_first_data_block + i;
		}
	}
	return 0;
}

// Same shape as ext2_alloc_block(), against the inode bitmap. Returns a
// 1-based inode number (0 = none free). Reserved inodes (1-10) are
// already marked used by mke2fs at format time, so a plain first-clear-
// bit scan naturally skips them — no special-cased reserved-inode-
// number logic needed.
fn uint ext2_alloc_inode()
{
	char[EXT2_MAX_BLOCK_SIZE] bitmap_buf @noinit;
	if (!ext2_read_block(ext2_inode_bitmap_block, &bitmap_buf)) return 0;

	for (uint i = 0; i < ext2_inodes_per_group; i++)
	{
		uint byte_i = i / 8;
		uint bit_i = i % 8;
		uint b = (uint)bitmap_buf[byte_i] & 0xFF;
		if ((b & (1 << bit_i)) == 0)
		{
			bitmap_buf[byte_i] = (char)(b | (1 << bit_i));
			if (!ext2_write_block(ext2_inode_bitmap_block, &bitmap_buf)) return 0;
			return i + 1;
		}
	}
	return 0;
}

// Patches mode/size/block[] into inode_num's existing on-disk record —
// read-modify-write, like fat32_write_fat_entry. Leaves every other
// field (timestamps, links_count, etc.) as whatever was already there;
// for a freshly allocated inode, the caller runs ext2_zero_inode() first
// so there's nothing stale left in those fields.
fn bool ext2_write_inode(uint inode_num, Ext2_inode_info* info)
{
	if (inode_num == 0 || inode_num > ext2_inodes_per_group) return false;

	uint index = inode_num - 1;
	uint byte_offset_in_table = index * ext2_inode_size;
	uint block_offset = byte_offset_in_table / ext2_block_size;
	uint offset_in_block = byte_offset_in_table % ext2_block_size;

	char[EXT2_MAX_BLOCK_SIZE] block_buf @noinit;
	if (!ext2_read_block(ext2_inode_table_block + block_offset, &block_buf)) return false;

	char* inode_bytes = &block_buf[offset_in_block];
	ushort* mode_field = (ushort*)&inode_bytes[EXT2_INODE_MODE];
	uint*   size_field = (uint*)&inode_bytes[EXT2_INODE_SIZE];
	*mode_field = (ushort)info.mode;
	*size_field = info.size;
	uint* block_ptrs = (uint*)&inode_bytes[EXT2_INODE_BLOCK];
	for (uint i = 0; i < 12; i++) block_ptrs[i] = info.block[i];

	return ext2_write_block(ext2_inode_table_block + block_offset, &block_buf);
}

// Zeroes a freshly allocated inode's ENTIRE on-disk record (all
// ext2_inode_size bytes, not just the mode/size/block fields
// ext2_write_inode touches) before that function sets specific fields —
// otherwise stale bytes from whatever inode number was last recycled
// (old timestamps, old block pointers past [0..11] this driver never
// reads but a real ext2 tool would) would leak into the "new" file's
// metadata. Parallels fat32_create_file's own "zero the reserved/date
// fields on a reused deleted slot" correctness step.
fn bool ext2_zero_inode(uint inode_num)
{
	uint index = inode_num - 1;
	uint byte_offset_in_table = index * ext2_inode_size;
	uint block_offset = byte_offset_in_table / ext2_block_size;
	uint offset_in_block = byte_offset_in_table % ext2_block_size;

	char[EXT2_MAX_BLOCK_SIZE] block_buf @noinit;
	if (!ext2_read_block(ext2_inode_table_block + block_offset, &block_buf)) return false;
	for (uint i = 0; i < ext2_inode_size; i++) block_buf[offset_in_block + i] = 0;
	return ext2_write_block(ext2_inode_table_block + block_offset, &block_buf);
}

// Creates a new, empty (zero-size) inode for `name` and links it into
// the root directory. Fails outright if the root's own 12 direct blocks
// are already all in use — a real v1 limit (see this file's header
// comment), not silently worked around by splitting an existing entry's
// trailing space.
fn bool ext2_create_file(char* name, uint* out_inode_num)
{
	uint inode_num = ext2_alloc_inode();
	if (inode_num == 0) return false;
	if (!ext2_zero_inode(inode_num)) return false;

	Ext2_inode_info new_inode;
	new_inode.mode = EXT2_S_IFREG | 0x1A4; // 0644 permissions
	new_inode.size = 0;
	for (uint i = 0; i < 12; i++) new_inode.block[i] = 0;
	if (!ext2_write_inode(inode_num, &new_inode)) return false;

	Ext2_inode_info root;
	if (!ext2_read_inode(EXT2_ROOT_INODE, &root)) return false;

	uint slot = 0;
	while (slot < 12 && root.block[slot] != 0) slot++;
	if (slot >= 12) return false; // root directory's 12 direct blocks are full

	uint new_block = ext2_alloc_block();
	if (new_block == 0) return false;

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

	root.block[slot] = new_block;
	root.size += ext2_block_size; // kept correct — real ext2 readers use a directory's own size to know how far to scan its blocks
	if (!ext2_write_inode(EXT2_ROOT_INODE, &root)) return false;

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
fn int ext2_write(char* name, char* src, uint len)
{
	uint inode_num;
	uint entry_sector;
	uint entry_offset;
	bool exists = ext2_find_in_root(name, &inode_num, &entry_sector, &entry_offset);

	if (!exists)
	{
		if (!ext2_create_file(name, &inode_num)) return -1;
		if (!ext2_find_in_root(name, &inode_num, &entry_sector, &entry_offset)) return -1;
	}

	if (fs_is_protected_entry(entry_sector, entry_offset)) return -1;

	Ext2_inode_info inode;
	if (!ext2_read_inode(inode_num, &inode)) return -1;

	uint written = ext2_write_file(&inode, src, len);
	inode.size = written;

	if (!ext2_write_inode(inode_num, &inode)) return -1;

	return (int)written;
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

	fs_set_protected_entry(entry_sector, entry_offset);

	Ext2_inode_info inode;
	if (!ext2_read_inode(inode_num, &inode)) return;
	for (uint b = 0; b < 12; b++)
	{
		if (inode.block[b] == 0) continue;
		if (!fs_reserve_sector_range(inode.block[b] * ext2_sectors_per_block, ext2_sectors_per_block)) return;
	}
}
