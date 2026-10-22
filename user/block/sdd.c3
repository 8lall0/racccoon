module user;

import std::nolibc::main_stub;

// sdd: orchestration only — main()'s own IPC request loop and
// sdd_init()'s own bring-up sequencing. Everything register/PIO-level
// (SDHCI registers, pad/power/clock bring-up, SD command issuing,
// block PIO transfer) lives in user/block/sdhci.c3 instead — this is
// the file that reads like "what sdd actually does," split out once
// the combined file grew large enough that the wire-level code and
// the orchestration were hard to tell apart in one file
// (docs/devlog.md), same reasoning/shape as usbd.c3's own dwc2.c3
// split and ethd.c3's own dwmac.c3/ephy.c3 split.
//
// sdd is the real-hardware SD storage driver for the Milk-V Duo,
// mutually exclusive with diskd (user/block/diskd.c3, QEMU's
// virtio-blk driver) — see kernel.c3 (whichever of the board's
// "sd" / "virtio-blk" DEVICES entries exists picks which one spawns).
// Speaks the identical DISKD_READ/DISKD_WRITE wire protocol diskd
// does, so fsd.c3 (its only client) needs zero changes to work
// against either.

// --- Shared with the kernel / fsd — kept in sync by hand, same wire
// protocol as user/block/diskd.c3. Inline verbs carry the data in the
// message ({sector}{data} or {sector}{count}{data}); the _ARENA verbs
// ({sector}{count}{arena_off}) move it through the shared disk arena —
// only on a board whose "sd" device sets `disk_arena` (src/device.c3,
// e.g. the Orange Pi; the Duo keeps the inline verbs). Any other verb
// gets a rejection reply (never a silent drop — a dropped verb would hang
// fsd's p9_call).
const uint DISKD_READ        = 210;
const uint DISKD_WRITE       = 211;
const uint DISKD_READ_MULTI  = 212; // read `count` consecutive sectors, count at byte 4..7
const uint DISKD_READ_ARENA        = 213;
const uint DISKD_WRITE_ARENA       = 214; // `count` sectors (byte 4..7) from the arena
const uint DISKD_READ_MULTI_ARENA  = 215;
const uint DISKD_WRITE_MULTI = 216; // write `count` sectors, count at 4..7, data from byte 8
const uint DISKD_UNSUPPORTED = 209; // reply verb for an unknown request
const uint DISKD_MAX_SECTORS = 15;  // inline cap — must match user/block/diskd.c3 + fsd.c3
const uint DISKD_MSG_MAX     = 8192; // must match user/block/diskd.c3 + fsd.c3 + src/process.c3 MSG_MAX

char* g_arena;      // the shared disk arena (identity-mapped), or null
uint  g_arena_size;

fn void sdd_init()
{
	sdd_pad_power_clock_init();
	print("sdd: pad/power/clock bring-up done\n");

	if (!sdd_enumerate())
	{
		panic("sdd: ", "card enumeration failed");
	}
	print("sdd: card ready\n");

	// SDMA staging buffer (identity-mapped, uncached — the SD device's one
	// DMA region, dev_info(), same pattern as usbd/ethd) + the controller's own SDMA capability
	// bit. Both must be present for sdd_block_rw to take the DMA path;
	// otherwise it stays PIO. See sdhci.c3's SDD_USE_DMA.
	if (SDD_USE_DMA)
	{
		uptr dma_paddr = 0;
		dev_info(&dma_paddr, 1);
		g_sdd_dma_paddr = dma_paddr;
		uint caps = sd_reg_read(SD_CAPABILITIES);
		g_sdd_dma_ok = dma_paddr != 0 && (caps & SD_CAP_SDMA) != 0;
		print(g_sdd_dma_ok ? "sdd: SDMA enabled\n" : "sdd: SDMA unavailable, PIO\n");
	}

	// The fsd<->sdd payload arena, if the board gave this device one.
	uptr arena_paddr = 0;
	uint arena_sz = 0;
	if (disk_arena_info(&arena_paddr, &arena_sz) == 0 && arena_paddr != 0)
	{
		g_arena = (char*)arena_paddr;
		g_arena_size = arena_sz;
	}
}

fn void main()
{
	sdd_init();

	for (;;)
	{
		char[DISKD_MSG_MAX] buf @noinit;
		uint verb = 0;
		uint from_gen = 0;
		int from = ipc_recv_type_gen(&buf, DISKD_MSG_MAX, &verb, &from_gen);
		// Same stale note removed as diskd.c3's own — see its comment:
		// every real sender today is a genuine process pid >= 1.
		if (from == 0) continue;

		bool is_arena = verb == DISKD_READ_ARENA || verb == DISKD_WRITE_ARENA || verb == DISKD_READ_MULTI_ARENA;
		bool known = is_arena || verb == DISKD_READ || verb == DISKD_WRITE
			|| verb == DISKD_READ_MULTI || verb == DISKD_WRITE_MULTI;
		if (!known || (is_arena && g_arena == null))
		{
			// Unknown verb, or an arena verb on a board without one.
			// Reply — never drop — so fsd's p9_call returns and its
			// reply_verb mismatch check triggers its fallback.
			buf[0] = 1;
			ipc_reply(from, DISKD_UNSUPPORTED, &buf, 4, from_gen);
			continue;
		}
		bool is_write = verb == DISKD_WRITE || verb == DISKD_WRITE_ARENA || verb == DISKD_WRITE_MULTI;

		uint* sector_ptr = (uint*)&buf;
		uint sector = *sector_ptr;

		// count: byte 4..7 for every verb but the single inline ones.
		uint count = 1;
		if (verb != DISKD_READ && verb != DISKD_WRITE)
		{
			uint* count_ptr = (uint*)&buf[4];
			count = *count_ptr;
			if (count < 1) count = 1;
		}

		// Where the sector data is: the arena (bounds-checked offset), or
		// the message — at byte 4, or 8 for the inline multi-write.
		char* data = &buf[4];
		char status = 0;
		if (is_arena)
		{
			uint* off_ptr = (uint*)&buf[8];
			if ((ulong)*off_ptr + (ulong)count * SECTOR_SIZE > (ulong)g_arena_size) { status = 1; }
			data = &g_arena[*off_ptr];
		}
		else
		{
			if (count > DISKD_MAX_SECTORS) count = DISKD_MAX_SECTORS;
			if (verb == DISKD_WRITE_MULTI) { data = &buf[8]; }
		}

		if (SDD_VERBOSE)
		{
			print("sdd: rw sector=");
			print_hex32(sector);
			print(" x");
			print_hex32(count);
			print(is_write ? " write\n" : " read\n");
		}

		// One multi-block command where the controller driver has one
		// (dw_mshc.c3), a per-sector loop otherwise (sdhci.c3).
		if (status == 0)
		{
			bool ok;
			if (is_write) { ok = count == 1 ? sdd_block_rw(data, sector, true) : sdd_block_write_multi(data, sector, count); }
			else          { ok = count == 1 ? sdd_block_rw(data, sector, false) : sdd_block_read_multi(data, sector, count); }
			if (!ok) { status = 1; }
		}

		buf[0] = status;
		// Inline reads carry the data back; everything else is status only.
		int reply_len = (!is_write && !is_arena) ? (int)(4 + count * SECTOR_SIZE) : 4;
		ipc_reply(from, verb, &buf, reply_len, from_gen);
	}
}
