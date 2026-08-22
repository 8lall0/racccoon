module user;

// Shared legacy virtio-mmio (version 1) transport layer — the generic
// register offsets, virtqueue struct shapes, and raw MMIO primitives
// used by both user/block/diskd.c3 (virtio-blk) and user/net/netd.c3
// (virtio-net), both on QEMU's own virtio-mmio bus. Extracted after
// netd.c3 was written by near-verbatim copying diskd.c3's own pattern
// — real, already-existing duplication, not speculative DRY.
//
// Each driver keeps its own device-specific pieces: diskd.c3's own
// VIRTIO_BLK_PADDR/Virtio_blk_req/VIRTIO_BLK_T_IN/OUT, netd.c3's own
// VIRTIO_NET_PADDR/VIRTIO_NET_F_STATUS/VIRTIO_NET_S_LINK_UP and
// device-config layout — this file only has what's genuinely identical
// between any legacy virtio-mmio device.

const uint VIRTQ_ENTRY_NUM = 16;
const uint PAGE_SIZE       = 4096;

const uint VIRTIO_REG_MAGIC          = 0x00;
const uint VIRTIO_REG_VERSION        = 0x04;
const uint VIRTIO_REG_DEVICE_ID      = 0x08;
const uint VIRTIO_REG_HOST_FEATURES  = 0x10;
const uint VIRTIO_REG_GUEST_FEATURES = 0x20;
const uint VIRTIO_REG_PAGE_SIZE      = 0x28;
const uint VIRTIO_REG_QUEUE_SEL      = 0x30;
const uint VIRTIO_REG_QUEUE_NUM      = 0x38;
const uint VIRTIO_REG_QUEUE_PFN      = 0x40;
const uint VIRTIO_REG_QUEUE_NOTIFY   = 0x50;
const uint VIRTIO_REG_DEVICE_STATUS  = 0x70;
const uint VIRTIO_REG_DEVICE_CONFIG  = 0x100;

const uint VIRTIO_STATUS_ACK       = 1;
const uint VIRTIO_STATUS_DRIVER    = 2;
const uint VIRTIO_STATUS_DRIVER_OK = 4;

const ushort VIRTQ_DESC_F_NEXT  = 1;
const ushort VIRTQ_DESC_F_WRITE = 2;

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

// `used` must sit at a page-aligned offset within the struct: this is
// the legacy virtio MMIO layout QEMU expects (avail ring and used ring
// on separate pages, derived from a single queue PFN).
struct Virtio_virtq @packed
{
	Virtq_desc[VIRTQ_ENTRY_NUM] descs;
	Virtq_avail avail;
	Virtq_used used @align(PAGE_SIZE);
	int queue_index;
	ushort* used_index;
	ushort last_used_index;
}

// Single-instruction, register-bound raw MMIO access: no volatile
// qualifier exists on a plain C3 pointer, so an ordinary `*(uint*)addr`
// load/store here would be fair game for the optimizer to hoist, cache,
// or eliminate — exactly wrong for device registers that change from
// outside the CPU's view. An asm block's contents run as written, not
// subject to that kind of reordering (the same property src/entry.c3's
// read_reg/write_reg macros rely on).
//
// RV64 port: `addr` and every local bound into this block-form asm
// widen to `uptr`/`ulong` — a plain 32-bit `uint` in that binding
// position is rejected by c3c on a 64-bit target, the same restriction
// that forced src/kernel/sbi.c3's params wider (see docs/devlog.md).
// Separately, `lw` is a *signed* word load — on RV32 that didn't matter
// (the register was only ever 32 bits wide anyway), but on RV64 it
// sign-extends into the full 64-bit register. For mmio_read32 that's
// harmless (the (uint) truncation below immediately discards whatever
// landed in the upper 32 bits), but mmio_read64 combines two such loads
// into one *unsigned* 64-bit value via shift+or, where a sign-extended
// upper word would corrupt the result — masked off explicitly there.
// `lwu` (a real zero-extending load) would be the more direct fix, but
// c3c's block-form asm doesn't recognize it ("Unknown instruction for
// the current target") — `lw` + an explicit mask is the workaround.
fn uint mmio_read32(uptr addr)
{
	ulong v;
	asm
	{
		lw v, [addr];
	}
	return (uint)v;
}

fn void mmio_write32(uptr addr, uint v)
{
	ulong vv = (ulong)v;
	asm
	{
		sw vv, [addr];
	}
}

fn ulong mmio_read64(uptr addr)
{
	ulong lo;
	ulong hi;
	asm
	{
		lw lo, [addr];
		lw hi, [addr + 4];
	}
	return ((hi & 0xffffffff) << 32) | (lo & 0xffffffff);
}

fn ushort mmio_read16(uptr addr)
{
	ulong v;
	asm
	{
		lhu v, [addr];
	}
	return (ushort)v;
}

// Base-address-parameterized register helpers — each driver keeps its
// own thin `reg_read32(offset)`-style wrapper around these, bound to
// its own device's PADDR, so call sites elsewhere in each driver stay
// unchanged.
fn uint virtio_reg_read32(uptr base, uint offset) { return mmio_read32(base + offset); }
fn ulong virtio_reg_read64(uptr base, uint offset) { return mmio_read64(base + offset); }
fn ushort virtio_reg_read16(uptr base, uint offset) { return mmio_read16(base + offset); }
fn void virtio_reg_write32(uptr base, uint offset, uint v) { mmio_write32(base + offset, v); }
fn void virtio_reg_fetch_or32(uptr base, uint offset, uint v) { virtio_reg_write32(base, offset, virtio_reg_read32(base, offset) | v); }
