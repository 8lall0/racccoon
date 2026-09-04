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
// virtio-blk driver) — see board::HAS_SD_BLOCK/HAS_VIRTIO_BLOCK
// (kernel.c3) for how exactly one of the two ever gets spawned.
// Speaks the identical DISKD_READ/DISKD_WRITE wire protocol diskd
// does, so fsd.c3 (its only client) needs zero changes to work
// against either.

// --- Shared with the kernel / fsd — kept in sync by hand, same wire
// protocol as user/block/diskd.c3. sdd implements the *inline* verbs
// (DISKD_READ/WRITE/READ_MULTI); it has no shared payload arena (that's
// setup_diskd_mappings, virtio-only), so fsd never sends it the _ARENA
// verbs — src/process.c3's setup_fsd_mappings only maps the arena on
// board::HAS_VIRTIO_BLOCK. Any other verb gets a rejection reply (never
// a silent drop — a dropped verb would hang fsd's p9_call forever).
const uint DISKD_READ        = 210;
const uint DISKD_WRITE       = 211;
const uint DISKD_READ_MULTI  = 212; // read `count` consecutive sectors, count at byte 4..7
const uint DISKD_UNSUPPORTED = 209; // reply verb for an unknown request
const uint DISKD_MAX_SECTORS = 15;  // must match user/block/diskd.c3 + fsd.c3
const uint DISKD_MSG_MAX     = 8192; // must match user/block/diskd.c3 + fsd.c3 + src/process.c3 MSG_MAX

fn void sdd_init()
{
	sdd_pad_power_clock_init();
	print("sdd: pad/power/clock bring-up done\n");

	if (!sdd_enumerate())
	{
		panic("sdd: ", "card enumeration failed");
	}
	print("sdd: card ready\n");

	// SDMA staging buffer (identity-mapped, uncached — SYS_SDD_INFO,
	// same pattern as usbd/ethd) + the controller's own SDMA capability
	// bit. Both must be present for sdd_block_rw to take the DMA path;
	// otherwise it stays PIO. See sdhci.c3's SDD_USE_DMA.
	if (SDD_USE_DMA)
	{
		uptr dma_paddr = 0;
		syscall(SYS_SDD_INFO, (long)&dma_paddr, 0, 0);
		g_sdd_dma_paddr = dma_paddr;
		uint caps = sd_reg_read(SD_CAPABILITIES);
		g_sdd_dma_ok = dma_paddr != 0 && (caps & SD_CAP_SDMA) != 0;
		print(g_sdd_dma_ok ? "sdd: SDMA enabled\n" : "sdd: SDMA unavailable, PIO\n");
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

		bool is_read  = (verb == DISKD_READ);
		bool is_write = (verb == DISKD_WRITE);
		bool is_multi = (verb == DISKD_READ_MULTI);
		if (!is_read && !is_write && !is_multi)
		{
			// Unknown verb (the _ARENA family, a future extension, junk).
			// Reply — never drop — so fsd's p9_call returns and its
			// reply_verb mismatch check triggers its fallback.
			buf[0] = 1;
			ipc_reply(from, DISKD_UNSUPPORTED, &buf, 4, from_gen);
			continue;
		}

		uint* sector_ptr = (uint*)&buf;
		uint sector = *sector_ptr;

		uint count = 1;
		if (is_multi)
		{
			uint* count_ptr = (uint*)&buf[4];
			count = *count_ptr;
			if (count < 1) count = 1;
			if (count > DISKD_MAX_SECTORS) count = DISKD_MAX_SECTORS;
		}

		if (SDD_VERBOSE)
		{
			print("sdd: rw sector=");
			print_hex32(sector);
			if (is_multi) { print(" x"); print_hex32(count); }
			print(is_write ? " write\n" : " read\n");
		}

		char status = 0;
		if (is_multi)
		{
			// DISKD_READ_MULTI: `count` consecutive sectors into buf[4..],
			// one sdd_block_rw() per sector (no scatter DMA on this IP).
			for (uint i = 0; i < count; i++)
			{
				if (!sdd_block_rw(&buf[4 + i * SECTOR_SIZE], sector + i, false))
				{
					status = 1;
					break;
				}
			}
		}
		else if (!sdd_block_rw(&buf[4], sector, is_write))
		{
			status = 1;
		}

		buf[0] = status;
		int reply_len = is_multi ? (int)(4 + count * SECTOR_SIZE) : (int)(4 + SECTOR_SIZE);
		ipc_reply(from, verb, &buf, reply_len, from_gen);
	}
}
