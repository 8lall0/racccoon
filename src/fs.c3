module kernel;

import panic;
import std::io;

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

File[FILES_MAX]  files;
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

// True if `s` starts with `prefix` (prefix may be shorter than s; an empty
// prefix matches everything). Used by namespace resolution (process.c3's
// Mount table) to match a path against a mount's prefix.
fn bool str_starts_with(char* s, char* prefix)
{
	uint i = 0;
	while (prefix[i] != 0)
	{
		if (s[i] != prefix[i]) return false;
		i++;
	}
	return true;
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

fn void fs_init()
{
	for (uint sector = 0; sector < DISK_MAX_SIZE / SECTOR_SIZE; sector++)
	{
		read_write_disk(&disk[sector * SECTOR_SIZE], sector, false);
	}

	uint off = 0;
	for (uint i = 0; i < FILES_MAX; i++)
	{
		Tar_header* header = (Tar_header*)&disk[off];
		if (header.name[0] == 0) break;

		if (!str_eq(&header.magic[0], "ustar"))
		{
			panic::panic("invalid tar header: not ustar");
		}

		int filesz = oct2int(&header.size[0], header.size.len);
		File* file = &files[i];
		file.in_use = true;
		str_copy(&file.name[0], &header.name[0], file.name.len);
		mem::copy(&file.data, (char*)header + Tar_header::size, (sz)filesz);
		file.size = (uint)filesz;
		io::printfn("file: %s, size=%d", (ZString)&file.name, file.size);

		off += (uint)mem::aligned_offset((sz)(Tar_header::size + filesz), SECTOR_SIZE);
	}
}

fn void fs_flush()
{
	mem::set(&disk, 0, DISK_MAX_SIZE);

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

		mem::copy((char*)header + Tar_header::size, &file.data, (sz)file.size);
		off += (uint)mem::aligned_offset((sz)(Tar_header::size + file.size), SECTOR_SIZE);
	}

	for (uint sector = 0; sector < DISK_MAX_SIZE / SECTOR_SIZE; sector++)
	{
		read_write_disk(&disk[sector * SECTOR_SIZE], sector, true);
	}

	io::printfn("wrote %d bytes to disk", DISK_MAX_SIZE);
}

fn File* fs_lookup(char* filename)
{
	for (uint i = 0; i < FILES_MAX; i++)
	{
		if (str_eq(&files[i].name[0], filename)) return &files[i];
	}
	return null;
}
