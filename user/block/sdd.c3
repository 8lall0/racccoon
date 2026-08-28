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
// protocol as user/block/diskd.c3.
const uint DISKD_READ    = 10;
const uint DISKD_WRITE   = 11;
const uint DISKD_MSG_MAX = 516;

fn void sdd_panic(char* msg)
{
	print("sdd: ");
	print(msg);
	print("\n");
	// See user/block/diskd.c3's diskd_panic comment for why this is
	// exit(), not an empty `for(;;){}` loop — same UB/optimizer hazard
	// applies here.
	exit();
}

fn void sdd_init()
{
	sdd_pad_power_clock_init();
	print("sdd: pad/power/clock bring-up done\n");

	if (!sdd_enumerate())
	{
		sdd_panic("card enumeration failed");
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
		if (verb != DISKD_READ && verb != DISKD_WRITE) continue;

		bool is_write = (verb == DISKD_WRITE);
		uint* sector_ptr = (uint*)&buf;
		uint sector = *sector_ptr;

		if (SDD_VERBOSE)
		{
			print("sdd: rw sector=");
			print_hex32(sector);
			print(is_write ? " write\n" : " read\n");
		}

		char status = 0;
		if (!sdd_block_rw(&buf[4], sector, is_write))
		{
			status = 1;
		}

		buf[0] = status;
		ipc_reply(from, verb, &buf, DISKD_MSG_MAX, from_gen);
	}
}
