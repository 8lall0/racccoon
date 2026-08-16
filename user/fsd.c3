module user;

// fsd: the file system, moved out of the trusted kernel into its own
// user-mode process (microkernel plan phase 5 — see docs/devlog.md).
// It's a 9P-lite-style client of diskd/sdd (phase 4) for raw sector I/O,
// and a server to everyone else (today just the shell) over the
// FS_READ/FS_WRITE verbs below. SYS_READFILE/SYS_WRITEFILE are gone from
// the kernel entirely now — this is the only way to touch a file.
//
// Reads a real FAT32 filesystem, read-only — not the tar-based format
// this file used to speak. On the Duo, this is the *same* FAT32
// partition (see fs_partition_info()/board::FS_PARTITION_START_SECTOR)
// that already holds this board's own bootable fip.bin — safe to point
// directly at it specifically because fsd never writes: a parsing bug
// can misread data, but can't corrupt anything. v1 scope, deliberately
// limited: root directory only (fsd had no subdirectory concept before
// this either — not a regression), 8.3 short filenames only (long
// filename / LFN directory entries are skipped, not parsed), no caching
// at boot — every FS_READ walks the root directory fresh and follows
// the matched file's cluster chain on demand, since there's no
// reasonable fixed-size cache for "however many files happen to be on
// someone's real SD card." FS_WRITE is rejected outright (see main()).
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

fn uint cluster_to_sector(uint cluster)
{
	return fs_data_start_sector + (cluster - 2) * fs_sectors_per_cluster;
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
// fills *out_cluster/*out_size on a hit.
fn bool fat32_find_in_root(char* name11, uint* out_cluster, uint* out_size)
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

	// `& 0xFF` rather than a straight (uint) cast: char's signedness in
	// this dialect isn't relied on elsewhere in this codebase, and
	// masking gives the correct unsigned byte value either way — a
	// signed char holding the bit pattern for 255 would otherwise
	// sign-extend to 0xFFFFFFFF on a plain widening cast.
	fs_sectors_per_cluster = (uint)sectors_per_cluster & 0xFF;
	fs_fat_start_sector    = (uint)*reserved_sectors;
	fs_data_start_sector   = fs_fat_start_sector + ((uint)num_fats & 0xFF) * (*fat_size_32);
	fs_root_cluster        = *root_cluster;

	print("fsd: FAT32 mounted, partition_start=");
	print_uint(fs_partition_start);
	print(" root_cluster=");
	print_uint(fs_root_cluster);
	print(" sectors_per_cluster=");
	print_uint(fs_sectors_per_cluster);
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

		// Read-only in v1 (see this file's header comment) — reject
		// immediately, same "nothing to do here" shape a missing file
		// already gets below, no lookup needed at all.
		if (verb == FS_WRITE)
		{
			*result_len_field = -1;
			ipc_send(from, verb, &buf, FS_MSG_MAX);
			continue;
		}

		// Pull the filename and requested length out before touching buf
		// again — the reply reuses the same offsets for different things
		// (result length at 0..3, data at 4..), so anything needed from
		// the request has to be captured first.
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

		uint first_cluster;
		uint file_size;
		if (!fat32_find_in_root(&name11, &first_cluster, &file_size))
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
