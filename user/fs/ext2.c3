module user;

// ext2 backend for fsd (see user/fsd.c3's own header comment for the
// generic core / backend split). Standard, stable public spec (the
// original ext2 on-disk format, unchanged by ext3/ext4's later journal/
// extent additions) — not reverse-engineered.
//
// v1 scope, deliberately limited, read-only:
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
//   - No write support at all: fsd.c3's main() never calls into this
//     file for FS_WRITE; an ext2-mounted volume rejects every write
//     unconditionally, no backend call.

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
const uint EXT2_BGD_INODE_TABLE = 8; // u32, starting block of this group's inode table

// Inode field offsets, relative to the inode's own start.
const uint EXT2_INODE_MODE  = 0;  // u16
const uint EXT2_INODE_SIZE  = 4;  // u32 (low 32 bits — large-file high bits not read, v1)
const uint EXT2_INODE_BLOCK = 40; // u32 x 15 (i_block[0..14]) — v1 only reads [0..11]

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
uint ext2_inode_table_block;

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
// and fills *out_inode on a hit.
fn bool ext2_find_in_root(char* name, uint* out_inode)
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
	if (!ext2_find_in_root(name, &inode_num)) return -1;

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

	uint* log_block_size   = (uint*)&sb_sector[EXT2_SB_LOG_BLOCK_SIZE];
	uint* first_data_block = (uint*)&sb_sector[EXT2_SB_FIRST_DATA_BLOCK];
	uint* inodes_per_group = (uint*)&sb_sector[EXT2_SB_INODES_PER_GROUP];
	uint* rev_level        = (uint*)&sb_sector[EXT2_SB_REV_LEVEL];
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
	ext2_inodes_per_group  = *inodes_per_group;
	ext2_inode_size        = (*rev_level >= 1) ? (uint)*inode_size_field : 128;

	uint first_data_block_val = *first_data_block;

	// Block group descriptor table starts in the block immediately
	// after the superblock's own block. v1 only ever reads group 0's
	// descriptor (the first 32 bytes of that block).
	char[EXT2_MAX_BLOCK_SIZE] bgdt_buf @noinit;
	if (!ext2_read_block(first_data_block_val + 1, &bgdt_buf))
	{
		fs_panic("failed to read ext2 block group descriptor");
	}
	uint* inode_table = (uint*)&bgdt_buf[EXT2_BGD_INODE_TABLE];
	ext2_inode_table_block = *inode_table;

	Ext2_inode_info root;
	if (!ext2_read_inode(EXT2_ROOT_INODE, &root) || (root.mode & 0x4000) == 0)
	{
		// 0x4000 = S_IFDIR — root not being a directory means either a
		// corrupt volume or a real limitation of this driver (e.g. the
		// root inode isn't in group 0 on an unusually small
		// inodes-per-group configuration) — panic clearly either way.
		fs_panic("ext2 root inode is not a directory");
	}

	print("fsd: ext2 mounted, block_size=");
	print_uint(ext2_block_size);
	print(" inode_table_block=");
	print_uint(ext2_inode_table_block);
	print("\n");
}
