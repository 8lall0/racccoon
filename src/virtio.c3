module kernel;

// The kernel no longer talks to the virtio-blk device directly — diskd
// (user/diskd.c3) owns it now (see docs/devlog.md, microkernel phase 4).
// What's left here is just the struct shapes, so a board's Device table
// (boards/qemu/board.c3) can size diskd's / netd's virtqueue and request
// buffers correctly, and the few constants other kernel code still
// references. The
// struct definitions are duplicated in user/diskd.c3 — kernel and user
// are separate c3c compilations with no shared header, same convention
// already used for the syscall numbers in user/user.c3.

const uint SECTOR_SIZE       = 512;
const uint VIRTQ_ENTRY_NUM   = 16;

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

// data holds one sector for DISKD_READ/WRITE, up to DISKD_MAX_SECTORS
// (15) consecutive sectors for DISKD_READ_MULTI — virtio-blk transfers
// them in one queue op (descs[1].len = count * 512). Kept in sync by
// hand with user/block/diskd.c3's copy; the ::size here sizes the DMA
// region alloc (VIRTIO_BLK_REQ_PAGES below — 2 pages).
struct Virtio_blk_req @packed
{
	uint          type;
	uint          reserved;
	ulong         sector;
	char[15 * 512] data;
	char          status;
}

// Pages one virtqueue / one blk request buffer span — what a board's
// Device table asks device_setup to allocate (alloc_pages guarantees the
// physical contiguity the legacy virtio layout needs).
const uint VIRTQ_PAGES          = (uint)((Virtio_virtq::size + PAGE_SIZE - 1) / PAGE_SIZE);
const uint VIRTIO_BLK_REQ_PAGES = (uint)((Virtio_blk_req::size + PAGE_SIZE - 1) / PAGE_SIZE);
