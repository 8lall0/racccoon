module kernel;

import panic;
import std::io;

const uint SECTOR_SIZE       = 512;
const uint VIRTQ_ENTRY_NUM   = 16;
const uint VIRTIO_DEVICE_BLK = 2;
const uint VIRTIO_BLK_PADDR  = 0x10001000;

const uint VIRTIO_REG_MAGIC         = 0x00;
const uint VIRTIO_REG_VERSION       = 0x04;
const uint VIRTIO_REG_DEVICE_ID     = 0x08;
const uint VIRTIO_REG_PAGE_SIZE     = 0x28;
const uint VIRTIO_REG_QUEUE_SEL     = 0x30;
const uint VIRTIO_REG_QUEUE_NUM_MAX = 0x34;
const uint VIRTIO_REG_QUEUE_NUM     = 0x38;
const uint VIRTIO_REG_QUEUE_PFN     = 0x40;
const uint VIRTIO_REG_QUEUE_READY   = 0x44;
const uint VIRTIO_REG_QUEUE_NOTIFY  = 0x50;
const uint VIRTIO_REG_DEVICE_STATUS = 0x70;
const uint VIRTIO_REG_DEVICE_CONFIG = 0x100;

const uint VIRTIO_STATUS_ACK       = 1;
const uint VIRTIO_STATUS_DRIVER    = 2;
const uint VIRTIO_STATUS_DRIVER_OK = 4;

const ushort VIRTQ_DESC_F_NEXT          = 1;
const ushort VIRTQ_DESC_F_WRITE         = 2;
const ushort VIRTQ_AVAIL_F_NO_INTERRUPT = 1;

const uint VIRTIO_BLK_T_IN  = 0;
const uint VIRTIO_BLK_T_OUT = 1;

struct Virtq_desc @packed
{
	ulong  addr;
	uint   len;
	ushort flags;
	ushort next;
}

struct Virtq_avail @packed
{
	ushort flags;
	ushort index;
	ushort[VIRTQ_ENTRY_NUM] ring;
}

struct Virtq_used_elem @packed
{
	uint id;
	uint len;
}

struct Virtq_used @packed
{
	ushort flags;
	ushort index;
	Virtq_used_elem[VIRTQ_ENTRY_NUM] ring;
}

// `used` must sit at a page-aligned offset within the struct: this is the
// legacy virtio MMIO layout QEMU expects (avail ring and used ring on
// separate pages, derived from a single queue PFN).
struct Virtio_virtq @packed
{
	Virtq_desc[VIRTQ_ENTRY_NUM] descs;
	Virtq_avail avail;
	Virtq_used used @align(PAGE_SIZE);
	int queue_index;
	ushort* used_index;
	ushort last_used_index;
}

struct Virtio_blk_req @packed
{
	uint      type;
	uint      reserved;
	ulong     sector;
	char[512] data;
	char      status;
}

fn uint virtio_reg_read32(uint offset)
{
	uint* ptr = (uint*)(VIRTIO_BLK_PADDR + offset);
	return mem::load(ptr, 4, true);
}

fn ulong virtio_reg_read64(uint offset)
{
	ulong* ptr = (ulong*)(VIRTIO_BLK_PADDR + offset);
	return mem::load(ptr, 8, true);
}

fn void virtio_reg_write32(uint offset, uint value)
{
	uint* ptr = (uint*)(VIRTIO_BLK_PADDR + offset);
	mem::store(ptr, value, 4, true);
}

fn void virtio_reg_fetch_and_or32(uint offset, uint value)
{
	virtio_reg_write32(offset, virtio_reg_read32(offset) | value);
}

Virtio_virtq*   blk_request_vq;
Virtio_blk_req* blk_req;
uint            blk_req_paddr;
ulong           blk_capacity;

fn Virtio_virtq* virtq_init(uint index)
{
	uint pages       = (uint)(mem::aligned_offset((sz)Virtio_virtq::size, PAGE_SIZE) / PAGE_SIZE);
	uint virtq_paddr = alloc_pages(pages);
	Virtio_virtq* vq = (Virtio_virtq*)virtq_paddr;
	vq.queue_index   = (int)index;
	vq.used_index    = &vq.used.index;
	virtio_reg_write32(VIRTIO_REG_QUEUE_SEL, index);
	virtio_reg_write32(VIRTIO_REG_QUEUE_NUM, VIRTQ_ENTRY_NUM);
	virtio_reg_write32(VIRTIO_REG_QUEUE_PFN, virtq_paddr / PAGE_SIZE);
	return vq;
}

fn void virtio_blk_init()
{
	if (virtio_reg_read32(VIRTIO_REG_MAGIC) != 0x74726976)
	{
		panic::panic("virtio: invalid magic value");
	}
	if (virtio_reg_read32(VIRTIO_REG_VERSION) != 1)
	{
		panic::panic("virtio: invalid version");
	}
	if (virtio_reg_read32(VIRTIO_REG_DEVICE_ID) != VIRTIO_DEVICE_BLK)
	{
		panic::panic("virtio: invalid device id");
	}

	virtio_reg_write32(VIRTIO_REG_DEVICE_STATUS, 0);
	virtio_reg_fetch_and_or32(VIRTIO_REG_DEVICE_STATUS, VIRTIO_STATUS_ACK);
	virtio_reg_fetch_and_or32(VIRTIO_REG_DEVICE_STATUS, VIRTIO_STATUS_DRIVER);
	virtio_reg_write32(VIRTIO_REG_PAGE_SIZE, PAGE_SIZE);
	blk_request_vq = virtq_init(0);
	virtio_reg_write32(VIRTIO_REG_DEVICE_STATUS, VIRTIO_STATUS_DRIVER_OK);

	blk_capacity = virtio_reg_read64(VIRTIO_REG_DEVICE_CONFIG) * SECTOR_SIZE;
	io::printfn("virtio-blk: capacity is %d bytes", (uint)blk_capacity);

	uint req_pages = (uint)(mem::aligned_offset((sz)Virtio_blk_req::size, PAGE_SIZE) / PAGE_SIZE);
	blk_req_paddr  = alloc_pages(req_pages);
	blk_req        = (Virtio_blk_req*)blk_req_paddr;
}

fn void virtq_kick(Virtio_virtq* vq, int desc_index)
{
	vq.avail.ring[vq.avail.index % VIRTQ_ENTRY_NUM] = (ushort)desc_index;
	vq.avail.index++;
	asm("fence");
	virtio_reg_write32(VIRTIO_REG_QUEUE_NOTIFY, (uint)vq.queue_index);
	vq.last_used_index++;
}

fn bool virtq_is_busy(Virtio_virtq* vq)
{
	return vq.last_used_index != mem::load(vq.used_index, 2, true);
}

fn void read_write_disk(void* buf, uint sector, bool is_write)
{
	uint capacity_sectors = (uint)(blk_capacity / SECTOR_SIZE);
	if (sector >= capacity_sectors)
	{
		io::printfn("virtio: tried to read/write sector=%d, but capacity is %d", sector, capacity_sectors);
		return;
	}

	blk_req.sector = sector;
	blk_req.type   = is_write ? VIRTIO_BLK_T_OUT : VIRTIO_BLK_T_IN;
	if (is_write)
	{
		mem::copy(&blk_req.data, buf, SECTOR_SIZE);
	}

	Virtio_virtq* vq = blk_request_vq;
	vq.descs[0].addr  = (ulong)blk_req_paddr;
	vq.descs[0].len   = 16; // type + reserved + sector
	vq.descs[0].flags = VIRTQ_DESC_F_NEXT;
	vq.descs[0].next  = 1;

	vq.descs[1].addr  = (ulong)(uint)&blk_req.data;
	vq.descs[1].len   = SECTOR_SIZE;
	vq.descs[1].flags = VIRTQ_DESC_F_NEXT | (is_write ? (ushort)0 : VIRTQ_DESC_F_WRITE);
	vq.descs[1].next  = 2;

	vq.descs[2].addr  = (ulong)(uint)&blk_req.status;
	vq.descs[2].len   = 1;
	vq.descs[2].flags = VIRTQ_DESC_F_WRITE;

	virtq_kick(vq, 0);

	while (virtq_is_busy(vq)) {}

	if (blk_req.status != 0)
	{
		io::printfn("virtio: warn: failed to read/write sector=%d status=%d", sector, (int)blk_req.status);
		return;
	}

	if (!is_write)
	{
		mem::copy(buf, &blk_req.data, SECTOR_SIZE);
	}
}
