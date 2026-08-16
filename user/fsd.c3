module user;

// fsd: the tar-based file system, moved out of the trusted kernel into
// its own user-mode process (microkernel plan phase 5 — see
// docs/devlog.md). It's a 9P-lite-style client of diskd (phase 4) for
// raw sector I/O, and a server to everyone else (today just the shell)
// over the FS_READ/FS_WRITE verbs below. SYS_READFILE/SYS_WRITEFILE are
// gone from the kernel entirely now — this is the only way to touch a
// file.
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

// diskd is always pid 3: created third in a fixed boot-time order (idle,
// echod, diskd, fsd — see kernel.c3), same hardcoded-by-convention
// approach as echod's pid 2 in shell.c3's "ping". fsd is a fixed,
// internal-only client of a fixed, internal-only service; fsd's *own*
// clients (the shell) go through namespace resolution instead, so they
// never need to know fsd's pid at all — see user.c3's fs_read/fs_write.
const int DISKD_PID = 3;

const uint FILES_MAX = 2;

struct Tar_header @packed
{
	char[100] name;
	char[8]   mode;
	char[8]   uid;
	char[8]   gid;
	char[12]  size;
	char[12]  mtime;
	char[8]   checksum;
	char      type;
	char[100] linkname;
	char[6]   magic;
	char[2]   version;
	char[32]  uname;
	char[32]  gname;
	char[8]   devmajor;
	char[8]   devminor;
	char[155] prefix;
	char[12]  padding;
}

struct File
{
	bool      in_use;
	char[100] name;
	char[1024] data;
	uint      size;
}

const uint DISK_MAX_SIZE = (File::size * FILES_MAX + SECTOR_SIZE - 1) & ~(SECTOR_SIZE - 1);

File[FILES_MAX]     files;
char[DISK_MAX_SIZE] disk;

fn void str_copy(char* dst, char* src, uint max)
{
	uint i = 0;
	while (src[i] != 0 && i < max - 1)
	{
		dst[i] = src[i];
		i++;
	}
	dst[i] = 0;
}

fn bool str_eq(char* a, char* b)
{
	uint i = 0;
	while (a[i] != 0 && b[i] != 0)
	{
		if (a[i] != b[i]) return false;
		i++;
	}
	return a[i] == b[i];
}

fn int oct2int(char* oct, int len)
{
	int dec = 0;
	for (int i = 0; i < len; i++)
	{
		if (oct[i] < '0' || oct[i] > '7') break;
		dec = dec * 8 + (oct[i] - '0');
	}
	return dec;
}

fn uint align_sector(uint n)
{
	return (n + SECTOR_SIZE - 1) & ~(SECTOR_SIZE - 1);
}

// Same request/reply shape as diskd's own protocol (see user/diskd.c3):
// byte 0 = status, bytes 4.. = the sector's data (write request / read
// reply only). Talking to diskd is ordinary blocking IPC here — see this
// file's header comment for why that's safe, unlike diskd's own
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

fn void fs_init()
{
	for (uint sector = 0; sector < DISK_MAX_SIZE / SECTOR_SIZE; sector++)
	{
		diskd_rw(&disk[sector * SECTOR_SIZE], sector, false);
	}

	uint off = 0;
	for (uint i = 0; i < FILES_MAX; i++)
	{
		Tar_header* header = (Tar_header*)&disk[off];
		if (header.name[0] == 0) break;
		if (!str_eq(&header.magic[0], "ustar")) break;

		int filesz = oct2int(&header.size[0], header.size.len);
		File* file = &files[i];
		file.in_use = true;
		str_copy(&file.name[0], &header.name[0], file.name.len);

		char* src = (char*)header + Tar_header::size;
		for (int j = 0; j < filesz; j++)
		{
			file.data[j] = src[j];
		}
		file.size = (uint)filesz;

		off += align_sector((uint)Tar_header::size + (uint)filesz);
	}

	print("fsd: file: ");
	print(&files[0].name[0]);
	print("\n");
}

fn void fs_flush()
{
	for (uint i = 0; i < DISK_MAX_SIZE; i++)
	{
		disk[i] = 0;
	}

	uint off = 0;
	for (uint file_i = 0; file_i < FILES_MAX; file_i++)
	{
		File* file = &files[file_i];
		if (!file.in_use) continue;

		Tar_header* header = (Tar_header*)&disk[off];
		str_copy(&header.name[0], &file.name[0], header.name.len);
		str_copy(&header.mode[0], "000644", header.mode.len);
		str_copy(&header.magic[0], "ustar", header.magic.len);
		str_copy(&header.version[0], "00", header.version.len);
		header.type = '0';

		int filesz = (int)file.size;
		for (int i = (int)header.size.len; i > 0; i--)
		{
			header.size[i - 1] = (char)((filesz % 8) + '0');
			filesz /= 8;
		}

		int checksum = ' ' * (int)header.checksum.len;
		for (uint i = 0; i < Tar_header::size; i++)
		{
			checksum += (int)(char)disk[off + i];
		}
		for (int i = 5; i >= 0; i--)
		{
			header.checksum[i] = (char)((checksum % 8) + '0');
			checksum /= 8;
		}

		char* dst = (char*)header + Tar_header::size;
		for (uint i = 0; i < file.size; i++)
		{
			dst[i] = file.data[i];
		}
		off += align_sector((uint)Tar_header::size + file.size);
	}

	for (uint sector = 0; sector < DISK_MAX_SIZE / SECTOR_SIZE; sector++)
	{
		diskd_rw(&disk[sector * SECTOR_SIZE], sector, true);
	}

	print("fsd: wrote ");
	print_uint(DISK_MAX_SIZE);
	print(" bytes to disk\n");
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

fn File* fs_lookup(char* filename)
{
	for (uint i = 0; i < FILES_MAX; i++)
	{
		if (str_eq(&files[i].name[0], filename)) return &files[i];
	}
	return null;
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

		File* file = fs_lookup(&filename);
		int* result_len_field = (int*)&buf;

		// FS_WRITE creates a new file in the first unused slot if none
		// with this name exists yet — FS_READ still fails for a missing
		// file (nothing to read). Previously there was no create path at
		// all, so a write to a name fsd hadn't already tar-parsed off
		// disk at boot silently failed; harmless on QEMU (its disk.tar
		// always pre-seeds hello.txt) but meant writefile could never
		// actually do anything on a genuinely blank disk — a real SD
		// card on first use, for instance (see docs/devlog.md).
		if (!file && verb == FS_WRITE)
		{
			for (uint i = 0; i < FILES_MAX; i++)
			{
				if (!files[i].in_use)
				{
					file = &files[i];
					file.in_use = true;
					str_copy(&file.name[0], &filename[0], file.name.len);
					break;
				}
			}
		}

		if (!file)
		{
			*result_len_field = -1;
			ipc_send(from, verb, &buf, FS_MSG_MAX);
			continue;
		}

		if (verb == FS_WRITE)
		{
			int write_len = req_len;
			if (write_len > (int)file.data.len)
			{
				write_len = (int)file.data.len;
			}
			for (int i = 0; i < write_len; i++)
			{
				file.data[i] = buf[104 + i];
			}
			file.size = (uint)write_len;
			fs_flush();
			*result_len_field = write_len;
		}
		else
		{
			int read_len = req_len;
			if (read_len > (int)file.size)
			{
				read_len = (int)file.size;
			}
			for (int i = 0; i < read_len; i++)
			{
				buf[4 + i] = file.data[i];
			}
			*result_len_field = read_len;
		}

		ipc_send(from, verb, &buf, FS_MSG_MAX);
	}
}
