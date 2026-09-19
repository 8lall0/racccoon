module kernel;

import board;
import panic;

// Board-declared devices — the one thing the kernel needs to know about a
// driver's hardware, stated as data instead of as per-driver code.
//
// Each board (boards/<name>/board.c3) exports `board::DEVICES`, a table of
// Device entries: the MMIO pages a driver needs, the PLIC source that
// signals it, and any DMA regions the kernel must allocate for it. A
// boot service that owns a device (see service_boot in supervisor.c3)
// just names it; device_setup() below is the single routine that turns
// an entry into mappings + an Irq_route + DMA regions in the driver's
// page table. There is no per-driver setup function and no per-driver
// "give me my DMA address" syscall any more — the kernel knows "a device
// is windows + an IRQ + DMA regions", not "this is sdd" or "this is usbd".
// Adding hardware (the JH7110's DW-MSHC needs syscrg/sysreg/pinmux pages
// on top of its own MMIO) is a new table entry in that board's file, not
// a new kernel function.
//
// What is deliberately still NOT data-driven (Stage B of the plan, see
// docs/devlog.md): *which* binary drives *which* device — kernel_main
// still names its boot servers and the device each one uses. Moving that
// to a userspace init means giving it a "map this device for that child"
// capability, which this table is the natural backing store for.

const int DEV_DMA_MAX  = 4;   // DMA regions per device (SYS_DEV_INFO's reply capacity)
const int DEV_MAX      = 8;   // entries in a board's table

struct Dev_dma
{
	uint pages;    // contiguous pages to allocate
	bool cached;   // true: map_page (plain cacheable RAM) — only correct where the
	               //   "device" is a software model with no real cache-coherency
	               //   hazard (QEMU virtio). false: map_device_page, uncached —
	               //   required for a real bus master (see process.c3's history
	               //   on usbd_dma_paddr / the Duo DMA-coherency bug).
}

struct Device
{
	String name;                    // the role a boot service asks for: "sd", "usb", …
	uptr[] mmio;                    // page-aligned physical pages, identity-mapped,
	                                //   uncached + strongly ordered, for the driver
	uint  irq;                      // PLIC source routed to the driver, 0 = none
	bool  irq_level;                // level source (handle_trap masks it, the driver re-arms
	                                //   via SYS_DRIVER_IRQ_ARM) vs edge/latched (left enabled)
	Dev_dma[] dma;                  // DMA regions (<= DEV_DMA_MAX), in the order
	                                //   SYS_DEV_INFO reports them
	bool  disk_arena;               // this device's driver shares the fsd payload arena
	                                //   (process.c3's map_disk_arena) — the one storage-protocol
	                                //   coupling that still rides on the device table
}

// Physical base of each device's DMA regions, filled by device_setup and
// handed to the driver by SYS_DEV_INFO. Flat [device * DEV_DMA_MAX + region]:
// a respawned driver gets fresh regions and simply overwrites its slots.
uptr[DEV_MAX * DEV_DMA_MAX] dev_dma_paddr;

// Index of the board device named `name` in board::DEVICES, or -1 if this
// board doesn't have it. A boot service spawns only on a board that does.
fn int device_find(String name)
{
	for (int i = 0; i < board::DEVICES.len; i++)
	{
		if (board::DEVICES[i].name == name) { return i; }
	}
	return -1;
}

// Does any device on this board hand the fsd payload arena to its driver?
// (fsd's primary instance maps the same arena — setup_fsd_mappings.)
fn bool device_board_has_disk_arena()
{
	for (int i = 0; i < board::DEVICES.len; i++)
	{
		if (board::DEVICES[i].disk_arena) { return true; }
	}
	return false;
}

// How many DMA regions device `dev` declares.
fn int device_dma_count(int dev)
{
	return (int)board::DEVICES[dev].dma.len;
}

// Give `proc` everything board::DEVICES[dev] describes: its MMIO windows,
// freshly allocated DMA regions (identity-mapped so a driver's own pointer
// value *is* the physical address the device needs — it can't learn a
// virtual page's physical backing otherwise), the PLIC route, and the fsd
// arena if the device carries one. Called once per spawn, including every
// supervisor respawn, so a restarted driver gets fully re-established.
fn void device_setup(Process* proc, int dev)
{
	if (dev < 0 || dev >= DEV_MAX || dev >= board::DEVICES.len) { panic::panic("bad board device index"); }
	Device* d = &board::DEVICES[dev];
	if (d.dma.len > DEV_DMA_MAX) { panic::panic("board device declares too many DMA regions"); }

	foreach (page : d.mmio)
	{
		map_device_page(proc.page_table, page, page, PAGE_U | PAGE_R | PAGE_W);
	}

	// alloc_pages(n) (unlike a process image's per-page copy loop)
	// guarantees one physically contiguous run — DMA descriptors and
	// virtqueue rings are addressed from a single physical base.
	for (int r = 0; r < (int)d.dma.len; r++)
	{
		uint pages = d.dma[r].pages;
		uptr paddr = alloc_pages(pages);
		for (uint off = 0; off < pages * PAGE_SIZE; off += PAGE_SIZE)
		{
			if (d.dma[r].cached)
			{
				map_page(proc.page_table, paddr + off, paddr + off, PAGE_U | PAGE_R | PAGE_W);
			}
			else
			{
				map_device_page(proc.page_table, paddr + off, paddr + off, PAGE_U | PAGE_R | PAGE_W);
			}
		}
		dev_dma_paddr[dev * DEV_DMA_MAX + r] = paddr;
	}

	// No-op for irq == 0. A repeat register for the same IRQ (driver
	// respawn) overwrites the route in place.
	irq_route_register(d.irq, proc.pid, d.irq_level);

	if (d.disk_arena)
	{
		map_disk_arena(proc);
		disk_arena_diskd_pid = proc.pid;
	}

	proc.device = dev;
}
