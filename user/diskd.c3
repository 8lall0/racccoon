module user;

// diskd: the virtio-blk driver, moved out of the trusted kernel into its
// own user-mode process (microkernel plan phase 4 — see docs/devlog.md).
// It's the only process with the device's MMIO mapped into its page
// table (see setup_diskd_mappings, src/process.c3); every other client
// — today just the kernel's own fs.c3, via a kernel-internal IPC helper
// — talks to it exclusively over the DISKD_READ/DISKD_WRITE messages
// below.
//
// No mem:: here: the user build compiles with --use-stdlib=no (see
// scripts/build_user.sh), so MMIO reads/writes use small hand-rolled
// asm-block helpers instead of the kernel's mem::load/store(volatile)
// wrappers — same reasoning, different mechanism, matching this
// codebase's established habit of reaching for raw asm wherever ordinary
// loads/stores aren't trustworthy (see src/entry.c3's read_reg/write_reg
// comments).

// --- Shared with the kernel — kept in sync by hand, same convention as
// the SYS_* numbers above (see src/entry.c3, src/process.c3).
const uint DISKD_IRQ_NOTIFY = 0xFFFFFFFF;
const uint DISKD_READ  = 10; // request: read one sector
const uint DISKD_WRITE = 11; // request: write one sector

// Message layout, both directions: byte 0..3 = sector number (uint),
// byte 4..515 = one 512-byte sector's worth of data (the sector written,
// for a WRITE request; the sector read, for a READ reply). Unused for a
// READ request or a WRITE reply. Must match src/process.c3's MSG_MAX and
// whatever the kernel-side client (fs.c3) assumes.
const uint DISKD_MSG_MAX = 516;

const uint SECTOR_SIZE      = 512;
const uint VIRTQ_ENTRY_NUM  = 16;
const uint VIRTIO_BLK_PADDR = 0x10001000;
const uint PAGE_SIZE        = 4096;

const uint VIRTIO_REG_MAGIC         = 0x00;
const uint VIRTIO_REG_VERSION       = 0x04;
const uint VIRTIO_REG_DEVICE_ID     = 0x08;
const uint VIRTIO_REG_PAGE_SIZE     = 0x28;
const uint VIRTIO_REG_QUEUE_SEL     = 0x30;
const uint VIRTIO_REG_QUEUE_NUM     = 0x38;
const uint VIRTIO_REG_QUEUE_PFN     = 0x40;
const uint VIRTIO_REG_QUEUE_NOTIFY  = 0x50;
const uint VIRTIO_REG_DEVICE_STATUS = 0x70;
const uint VIRTIO_REG_DEVICE_CONFIG = 0x100;

const uint VIRTIO_STATUS_ACK       = 1;
const uint VIRTIO_STATUS_DRIVER    = 2;
const uint VIRTIO_STATUS_DRIVER_OK = 4;

const ushort VIRTQ_DESC_F_NEXT  = 1;
const ushort VIRTQ_DESC_F_WRITE = 2;

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

fn uint reg_read32(uint offset) { return mmio_read32((uptr)(VIRTIO_BLK_PADDR + offset)); }
fn ulong reg_read64(uint offset) { return mmio_read64((uptr)(VIRTIO_BLK_PADDR + offset)); }
fn void reg_write32(uint offset, uint v) { mmio_write32((uptr)(VIRTIO_BLK_PADDR + offset), v); }
fn void reg_fetch_or32(uint offset, uint v) { reg_write32(offset, reg_read32(offset) | v); }

Virtio_virtq*   vq;
Virtio_blk_req* req;
uptr            req_paddr;

fn void diskd_panic(char* msg)
{
	print("diskd: ");
	print(msg);
	print("\n");
	// Not `for (;;) {}`: an empty infinite loop with no side effects is
	// UB by C/LLVM's rules and is a real optimizer target, not just a
	// theoretical one — under -O2 this got silently dropped, falling
	// straight through back into diskd_init()'s caller with diskd in a
	// half-initialized state instead of actually halting, which is what
	// caused the repeated "diskd: invalid device id" prints and eventual
	// illegal-instruction crash this was found chasing (see
	// docs/devlog.md). exit() is both correct (this really is fatal —
	// nothing after this point can do anything useful) and immune to
	// the same class of bug, since it's a real syscall with a real
	// side effect the optimizer can't reason away.
	exit();
}

fn void diskd_init()
{
	uptr vq_paddr;
	if (diskd_info(&vq_paddr, &req_paddr) < 0)
	{
		diskd_panic("failed to get buffer info");
	}
	vq  = (Virtio_virtq*)vq_paddr;
	req = (Virtio_blk_req*)req_paddr;

	if (reg_read32(VIRTIO_REG_MAGIC) != 0x74726976)
	{
		diskd_panic("invalid magic value");
	}
	if (reg_read32(VIRTIO_REG_VERSION) != 1)
	{
		diskd_panic("invalid version");
	}
	if (reg_read32(VIRTIO_REG_DEVICE_ID) != 2)
	{
		diskd_panic("invalid device id");
	}

	reg_write32(VIRTIO_REG_DEVICE_STATUS, 0);
	reg_fetch_or32(VIRTIO_REG_DEVICE_STATUS, VIRTIO_STATUS_ACK);
	reg_fetch_or32(VIRTIO_REG_DEVICE_STATUS, VIRTIO_STATUS_DRIVER);
	reg_write32(VIRTIO_REG_PAGE_SIZE, PAGE_SIZE);

	reg_write32(VIRTIO_REG_QUEUE_SEL, 0);
	reg_write32(VIRTIO_REG_QUEUE_NUM, VIRTQ_ENTRY_NUM);
	reg_write32(VIRTIO_REG_QUEUE_PFN, (uint)(vq_paddr / PAGE_SIZE));
	vq.queue_index = 0;
	vq.used_index  = &vq.used.index;

	reg_write32(VIRTIO_REG_DEVICE_STATUS, VIRTIO_STATUS_DRIVER_OK);

	uint sectors = (uint)reg_read64(VIRTIO_REG_DEVICE_CONFIG);
	print("diskd: ");
	print_uint(sectors);
	print(" sectors\n");
}

fn void virtq_kick(int desc_index)
{
	vq.avail.ring[vq.avail.index % VIRTQ_ENTRY_NUM] = (ushort)desc_index;
	vq.avail.index++;
	asm("fence");
	reg_write32(VIRTIO_REG_QUEUE_NOTIFY, (uint)vq.queue_index);
	vq.last_used_index++;
}

fn void main() @export("main")
{
	diskd_init();

	for (;;)
	{
		char[DISKD_MSG_MAX] buf @noinit;
		uint verb = 0;
		uint from_gen = 0;
		int from = ipc_recv_type_gen(&buf, DISKD_MSG_MAX, &verb, &from_gen);
		// Stale note removed: this used to say a legitimate sender could
		// be a synthetic KERNEL_PID (-1) because fs_init()/fs_flush() once
		// talked to diskd directly as kernel code (a pre-microkernel-split
		// fs.c3 that no longer exists — see fsd.c3's own header comment).
		// Every real sender today is fsd/fsd2, always a genuine process
		// pid >= 1, so ipc_reply()'s generation check below is safe to
		// rely on unconditionally.
		if (from == 0) continue;
		if (verb != DISKD_READ && verb != DISKD_WRITE) continue;

		bool is_write = (verb == DISKD_WRITE);
		uint* sector_ptr = (uint*)&buf;
		uint sector = *sector_ptr;

		req.sector = (ulong)sector;
		req.type   = is_write ? VIRTIO_BLK_T_OUT : VIRTIO_BLK_T_IN;
		if (is_write)
		{
			char* src = &buf[4];
			mem::copy(&req.data, src, SECTOR_SIZE);
		}

		vq.descs[0].addr  = (ulong)req_paddr;
		vq.descs[0].len   = 16; // type + reserved + sector
		vq.descs[0].flags = VIRTQ_DESC_F_NEXT;
		vq.descs[0].next  = 1;

		vq.descs[1].addr  = (ulong)(uptr)&req.data;
		vq.descs[1].len   = SECTOR_SIZE;
		vq.descs[1].flags = VIRTQ_DESC_F_NEXT | (is_write ? (ushort)0 : VIRTQ_DESC_F_WRITE);
		vq.descs[1].next  = 2;

		vq.descs[2].addr  = (ulong)(uptr)&req.status;
		vq.descs[2].len   = 1;
		vq.descs[2].flags = VIRTQ_DESC_F_WRITE;

		virtq_kick(0);

		// Poll (never block) for the kernel's synthetic completion notify
		// (see src/entry.c3's handle_trap) instead of wfi or a blocking
		// ipc_recv — see SYS_IPC_POLL's comment in src/entry.c3 for why a
		// blocking wait here is genuinely unsafe (nested-trap frame
		// corruption via sscratch), not just less efficient. Spinning in
		// user-mode code between polls keeps interrupts naturally
		// deliverable the whole time. Safe to reuse this same inbox
		// slot: it was just drained by the recv above, and nothing else
		// can legitimately arrive here as long as callers keep to one
		// outstanding disk request at a time (the same v1 discipline the
		// IPC layer itself already relies on).
		for (;;)
		{
			uint notify_verb = 0;
			int r = ipc_poll_type(&buf, 0, &notify_verb);
			if (r != -1 && notify_verb == DISKD_IRQ_NOTIFY) break;
		}

		buf[0] = req.status;
		if (!is_write)
		{
			char* dst = &buf[4];
			mem::copy(dst, &req.data, SECTOR_SIZE);
		}
		ipc_reply(from, verb, &buf, DISKD_MSG_MAX, from_gen);
	}
}
