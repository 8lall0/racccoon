module user;

import std::nolibc::main_stub;
import std::nolibc::mem;

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
const uint DISKD_READ  = 210; // request: read one sector
const uint DISKD_WRITE = 211; // request: write one sector
const uint DISKD_READ_MULTI = 212; // request: read `count` consecutive sectors

// Message layout: byte 0..3 = sector number (uint). For DISKD_WRITE the
// sector data follows at byte 4. For DISKD_READ_MULTI byte 4..7 = count
// (1..DISKD_MAX_SECTORS); the reply carries byte 0 = status then
// count*512 bytes of data from byte 4. DISKD_READ's reply is byte 0 =
// status, byte 4..515 = the sector. Must fit src/process.c3's MSG_MAX;
// USB-MSC (user/bin/usbrw.c3) speaks the single-sector subset only —
// fsd probes DISKD_READ_MULTI and falls back if the backend rejects it.
const uint DISKD_MAX_SECTORS = 15;
const uint DISKD_MSG_MAX = 8192;

// Arena-mode verbs (docs/ipc-rings.md Phase 1, step 2). Same semantics as
// their inline counterparts above, but the sector payload lives in the
// shared disk arena (SYS_DISK_ARENA_INFO), not the IPC message: the
// virtio data descriptor points straight at `arena_paddr + arena_off`,
// so the device DMAs into the region the primary fsd reads — no copy
// into/out of req.data, no 8 KiB bounce through the kernel. Request is
// [0..3] sector, [4..7] count (1 for the single verbs), [8..11]
// arena_off; reply is byte 0 = status only. Only the primary fsd uses
// these; fsd2 and usbrw.c3 keep the inline verbs (they aren't mapped to
// the arena).
const uint DISKD_READ_ARENA        = 213;
const uint DISKD_WRITE_ARENA       = 214;
const uint DISKD_READ_MULTI_ARENA  = 215;

const uint SECTOR_SIZE      = 512;
const uint VIRTIO_BLK_PADDR = 0x10001000;

const uint VIRTIO_BLK_T_IN  = 0;
const uint VIRTIO_BLK_T_OUT = 1;

struct Virtio_blk_req @packed
{
	uint          type;
	uint          reserved;
	ulong         sector;
	char[15 * 512] data;   // DISKD_MAX_SECTORS — see src/virtio.c3's copy
	char          status;
}

// Thin wrappers around user/virtio.c3's own base-address-parameterized
// helpers, bound to this device's own VIRTIO_BLK_PADDR — every other
// call site in this file keeps calling plain reg_read32(offset) etc.,
// unchanged.
fn uint reg_read32(uint offset) { return virtio_reg_read32(VIRTIO_BLK_PADDR, offset); }
fn ulong reg_read64(uint offset) { return virtio_reg_read64(VIRTIO_BLK_PADDR, offset); }
fn void reg_write32(uint offset, uint v) { virtio_reg_write32(VIRTIO_BLK_PADDR, offset, v); }
fn void reg_fetch_or32(uint offset, uint v) { virtio_reg_fetch_or32(VIRTIO_BLK_PADDR, offset, v); }

Virtio_virtq*   vq;
Virtio_blk_req* req;
uptr            req_paddr;

// The fsd<->diskd shared payload arena (docs/ipc-rings.md P1 step 2) —
// identity-mapped, so arena_paddr doubles as the virtual address. 0 if
// the kernel didn't hand one back (older kernel); the arena verbs then
// just never arrive and the inline path is unaffected.
uptr arena_paddr;
uint arena_size;

fn void diskd_init()
{
	uptr vq_paddr;
	if (diskd_info(&vq_paddr, &req_paddr) < 0)
	{
		panic("diskd: ", "failed to get buffer info");
	}
	vq  = (Virtio_virtq*)vq_paddr;
	req = (Virtio_blk_req*)req_paddr;

	arena_paddr = 0;
	arena_size  = 0;
	disk_arena_info(&arena_paddr, &arena_size); // -1 (leaves both 0) on an older kernel

	if (reg_read32(VIRTIO_REG_MAGIC) != 0x74726976)
	{
		panic("diskd: ", "invalid magic value");
	}
	if (reg_read32(VIRTIO_REG_VERSION) != 1)
	{
		panic("diskd: ", "invalid version");
	}
	if (reg_read32(VIRTIO_REG_DEVICE_ID) != 2)
	{
		panic("diskd: ", "invalid device id");
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

fn void main()
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
		bool is_arena = (verb == DISKD_READ_ARENA || verb == DISKD_WRITE_ARENA || verb == DISKD_READ_MULTI_ARENA);
		bool is_inline = (verb == DISKD_READ || verb == DISKD_WRITE || verb == DISKD_READ_MULTI);
		if (!is_arena && !is_inline) continue;

		bool is_write = (verb == DISKD_WRITE || verb == DISKD_WRITE_ARENA);
		bool is_multi = (verb == DISKD_READ_MULTI || verb == DISKD_READ_MULTI_ARENA);
		uint* sector_ptr = (uint*)&buf;
		uint sector = *sector_ptr;

		// count: byte 4..7 for the multi verbs, else one sector.
		uint count = 1;
		if (is_multi)
		{
			uint* count_ptr = (uint*)&buf[4];
			count = *count_ptr;
			if (count < 1) count = 1;
			if (count > DISKD_MAX_SECTORS) count = DISKD_MAX_SECTORS;
		}
		uint xfer = count * SECTOR_SIZE;

		// Arena mode: byte 8..11 = the offset into the shared arena the
		// device DMAs to/from directly. Bounds-checked here (fsd is
		// trusted, but a stale/corrupt request must not make the device
		// scribble outside the region). data_paddr is where the sector
		// bytes live for the virtio data descriptor.
		uptr data_paddr = (uptr)(uptr)&req.data;
		if (is_arena)
		{
			uint* arena_off_ptr = (uint*)&buf[8];
			uint arena_off = *arena_off_ptr;
			if (arena_paddr == 0 || (ulong)arena_off + (ulong)xfer > (ulong)arena_size)
			{
				buf[0] = 1; // status != 0 -> fsd treats it as a failed op
				ipc_reply(from, verb, &buf, 4, from_gen);
				continue;
			}
			data_paddr = arena_paddr + arena_off;
		}

		req.sector = (ulong)sector;
		req.type   = is_write ? VIRTIO_BLK_T_OUT : VIRTIO_BLK_T_IN;
		if (is_write && !is_arena)
		{
			char* src = &buf[4];
			mem::copy(&req.data, src, SECTOR_SIZE);
		}

		vq.descs[0].addr  = (ulong)req_paddr;
		vq.descs[0].len   = 16; // type + reserved + sector
		vq.descs[0].flags = VIRTQ_DESC_F_NEXT;
		vq.descs[0].next  = 1;

		vq.descs[1].addr  = (ulong)data_paddr;
		vq.descs[1].len   = xfer;
		vq.descs[1].flags = VIRTQ_DESC_F_NEXT | (is_write ? (ushort)0 : VIRTQ_DESC_F_WRITE);
		vq.descs[1].next  = 2;

		vq.descs[2].addr  = (ulong)(uptr)&req.status;
		vq.descs[2].len   = 1;
		vq.descs[2].flags = VIRTQ_DESC_F_WRITE;

		virtq_kick(0);

		// Wait for the virtio-blk completion IRQ. This used to be a tight
		// userspace `for(;;){ ipc_poll_type(...) }` spin — one SYS_IPC_POLL
		// per pass, tens to hundreds of passes per completion, ~330M
		// syscalls over a `go build` (docs/ipc-rings.md Phase 1). It's now
		// one SYS_DRIVER_IRQ_WAIT: the same PLIC-hand-draining poll loop,
		// but the passes happen inside the kernel where the yield()s aren't
		// syscalls. Still not a true blocking wait — see that syscall's
		// comment in src/entry.c3 for why (sscratch nested-trap hazard,
		// global SIE-off storms) and why the in-kernel loop is safe anyway.
		driver_irq_wait();

		// Clear the device's interrupt-status bits so QEMU drops the
		// (legacy virtio-mmio, level-triggered) IRQ line. Nothing else
		// does it — and a permanently-asserted line re-traps on every
		// sret, storming the PLIC and wedging the whole system. This was
		// harmless while the only IRQ delivery was the trap path routing
		// straight to diskd's inbox; it stopped being harmless once
		// SYS_IPC_POLL started draining the PLIC itself (docs/devlog.md).
		uint isr = reg_read32(VIRTIO_REG_INTERRUPT_STATUS);
		if (isr != 0) { reg_write32(VIRTIO_REG_INTERRUPT_ACK, isr); }

		buf[0] = req.status;
		if (!is_write && !is_arena)
		{
			char* dst = &buf[4];
			mem::copy(dst, &req.data, xfer);
		}
		// Reply only as long as the payload needs. Arena mode: status
		// only (4 bytes) — the data already went straight to the shared
		// region. Inline: a single sector's 516 bytes for DISKD_READ,
		// 4 + count*512 for the multi read, 4 for a write ack.
		int reply_len = (is_write || is_arena) ? 4 : (int)(4 + xfer);
		ipc_reply(from, verb, &buf, reply_len, from_gen);
	}
}
