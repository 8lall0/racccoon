module user;

// SDIO on top of dw_mshc.c3: the I/O-card side of the SD protocol, for any
// SDIO device behind a DesignWare MSHC (the Orange Pi's AP6256 Wi-Fi on
// sdio0, user/wifi/brcmd.c3). Separate from sd_card.c3 (SD *memory*
// cards: CMD8/ACMD41/CMD17-25) and free of any one card's knowledge — a
// card driver links this, dw_mshc.c3, and does its own protocol on top.
// A library, not a server: every register access is a CMD52/CMD53, and an
// IPC round trip under each would dominate the cost (2026-10-23 design
// note — revisit if a board ever has two SDIO devices on one bus).
//
// Commands (SDIO spec 3.0):
//   CMD5  IO_SEND_OP_COND  R4 (no CRC): OCR, function count, ready bit
//   CMD52 IO_RW_DIRECT     R5: one byte of a function's register space
//   CMD53 IO_RW_EXTENDED   R5 + data: up to a block of bytes (byte mode)
// Common registers (CCCR, function 0): 0x02 I/O enable, 0x03 I/O ready,
// 0x06 I/O abort, 0x07 bus interface, 0x09-0x0B common CIS pointer; each
// function's FBR at 0x100 * n (block size at +0x10/+0x11).

fn void delay_ms(ulong ms)
{
	ulong until = rdtime() + timebase_hz() * ms / 1000;
	while (rdtime() < until) { }
}

// CMD52: arg [31] write, [30:28] function, [27] read-after-write, [25:9]
// address, [7:0] data. R5 response: [7:0] the data, [15:8] status flags.
fn bool sdio_cmd52(bool write, uint func, uint addr, uint data, uint* out)
{
	uint arg = (write ? 1u << 31 : 0) | ((func & 7) << 28) | ((addr & 0x1FFFF) << 9) | (data & 0xFF);
	if (!dw_send_cmd(52, arg, DW_R_SHORT | DW_R_CRC, false, false)) { return false; }
	if (out != null) { *out = dw_response0 & 0xFF; }
	return true;
}

// CMD53, byte mode, incrementing address: `n` bytes (a multiple of 4, at
// most the function's block size — more came back OUT_OF_RANGE) of
// function `func` at `addr`, through the data FIFO by PIO.
fn bool sdio_cmd53(bool write, uint func, uint addr, char* buf, uint n)
{
	uint arg = (write ? 1u << 31 : 0) | ((func & 7) << 28) | (1u << 26) | ((addr & 0x1FFFF) << 9) | (n & 0x1FF);
	return sdio_cmd53_xfer(write, arg, buf, n);
}

// CMD53, block mode (arg bit 27), incrementing address: `nblocks` blocks
// of 512 bytes — the function's block size must be 512 (the controller's
// BLKSIZ is min(bytes, 512), dw_send_cmd).
fn bool sdio_cmd53_blocks(bool write, uint func, uint addr, char* buf, uint nblocks)
{
	uint arg = (write ? 1u << 31 : 0) | ((func & 7) << 28) | (1u << 27) | (1u << 26) | ((addr & 0x1FFFF) << 9) | (nblocks & 0x1FF);
	return sdio_cmd53_xfer(write, arg, buf, nblocks * 512);
}

fn bool sdio_cmd53_xfer(bool write, uint arg, char* buf, uint n)
{
	if (!dw_send_cmd(53, arg, DW_R_SHORT | DW_R_CRC, true, write, n))
	{
		print("sdio: CMD53 command failed rintsts=0x"); print_hex32(dw_last_rintsts); print("\n");
		return false;
	}
	uint* words = (uint*)buf;
	uint total = n / 4;
	uint got = 0;
	uint r = 0;
	ulong start = rdtime();
	for (;;)
	{
		r = dw_read(DWMCI_RINTSTS);
		if ((r & DWMCI_DATA_ERR) != 0) { break; }
		if (got < total)
		{
			if (write)
			{
				uint room = DW_FIFO_DEPTH - dw_fifo_count();
				while (room > 0 && got < total) { dw_write(DWMCI_DATA, words[got]); got++; room--; }
			}
			else
			{
				uint avail = dw_fifo_count();
				while (avail > 0 && got < total) { words[got] = dw_read(DWMCI_DATA); got++; avail--; }
			}
		}
		if ((r & DWMCI_INT_DTO) != 0 && got == total) { break; }
		if (rdtime() - start > dw_us_to_ticks(DW_DATA_US)) { break; }
	}
	dw_write(DWMCI_RINTSTS, DWMCI_INT_DTO | DWMCI_INT_RXDR | DWMCI_INT_TXDR | DWMCI_DATA_ERR);
	bool ok = got == total && (r & DWMCI_INT_DTO) != 0 && (r & DWMCI_DATA_ERR) == 0;
	if (!ok)
	{
		print("sdio: CMD53 arg=0x"); print_hex32(arg); print(" R5 flags 0x"); print_hex32((dw_response0 >> 8) & 0xFF);
		print(", data words "); print_uint(got); print("/"); print_uint(total);
		print(" rintsts=0x"); print_hex32(r); print("\n");
		sdio_fifo_reset();
	}
	return ok;
}

fn void sdio_fifo_reset()
{
	dw_write(DWMCI_CTRL, dw_read(DWMCI_CTRL) | DWMCI_CTRL_FIFO_RESET);
	ulong fs = rdtime();
	while ((dw_read(DWMCI_CTRL) & DWMCI_CTRL_FIFO_RESET) != 0 && rdtime() - fs < dw_us_to_ticks(DW_RESET_US)) { }
	dw_write(DWMCI_RINTSTS, DWMCI_INT_ALL);
}

// A CMD53 that failed mid-transfer leaves the card in its transfer state:
// IO_ABORT (CCCR 0x06) for that function puts it back.
fn void sdio_abort(uint func)
{
	sdio_cmd52(true, 0, 0x06, func & 7, null);
	sdio_fifo_reset();
}

// Identification: CMD0, CMD5 until ready (3.2-3.4 V window), CMD3 for the
// relative address, CMD7 to select. Returns false if nothing answers CMD5
// (no card, or one still held in reset).
fn bool sdio_identify(uint* ocr_out, uint* rca_out)
{
	dw_send_cmd(0, 0, DW_R_NONE, false, false); // GO_IDLE (with the 80-clock init)
	delay_ms(2);
	if (!dw_send_cmd(5, 0, DW_R_SHORT, false, false)) { return false; }
	uint ocr = dw_response0;
	bool ready = false;
	for (int i = 0; i < 100 && !ready; i++)
	{
		if (dw_send_cmd(5, ocr & 0x00FF8000, DW_R_SHORT, false, false) && (dw_response0 & (1u << 31)) != 0) { ready = true; }
		else { delay_ms(10); }
	}
	if (!ready) { return false; }
	if (!dw_send_cmd(3, 0, DW_R_SHORT | DW_R_CRC, false, false)) { return false; }
	uint rca = dw_response0 & 0xFFFF0000;
	if (!dw_send_cmd(7, rca, DW_R_SHORT | DW_R_CRC, false, false)) { return false; }
	*ocr_out = ocr;
	*rca_out = rca >> 16;
	return true;
}

// The common CIS (pointer at CCCR 0x09..0x0B), searched for CISTPL_MANFID
// (0x20): vendor (2 bytes) + device (2 bytes), little-endian.
fn bool sdio_read_manfid(uint* vendor, uint* device)
{
	uint b0 = 0; uint b1 = 0; uint b2 = 0;
	if (!sdio_cmd52(false, 0, 0x09, 0, &b0) || !sdio_cmd52(false, 0, 0x0A, 0, &b1) || !sdio_cmd52(false, 0, 0x0B, 0, &b2)) { return false; }
	uint p = b0 | (b1 << 8) | (b2 << 16);
	for (int guard = 0; guard < 64; guard++)
	{
		uint code = 0; uint link = 0;
		if (!sdio_cmd52(false, 0, p, 0, &code) || code == 0xFF) { return false; }
		if (!sdio_cmd52(false, 0, p + 1, 0, &link)) { return false; }
		if (code == 0x20 && link >= 4)
		{
			uint v0; uint v1; uint d0; uint d1;
			sdio_cmd52(false, 0, p + 2, 0, &v0); sdio_cmd52(false, 0, p + 3, 0, &v1);
			sdio_cmd52(false, 0, p + 4, 0, &d0); sdio_cmd52(false, 0, p + 5, 0, &d1);
			*vendor = v0 | (v1 << 8);
			*device = d0 | (d1 << 8);
			return true;
		}
		p += 2 + link;
	}
	return false;
}

// Turn function `func` on (or off) in CCCR 0x02 and, when on, wait up to
// `timeout_ms` for its bit in 0x03 (I/O ready).
fn bool sdio_enable_func(uint func, bool on, int timeout_ms)
{
	uint en = 0;
	if (!sdio_cmd52(false, 0, 0x02, 0, &en)) { return false; }
	uint bit = 1u << func;
	if (!sdio_cmd52(true, 0, 0x02, on ? (en | bit) : (en & ~bit), null)) { return false; }
	if (!on) { return true; }
	for (int i = 0; i < timeout_ms / 10 + 1; i++)
	{
		uint rdy = 0;
		if (sdio_cmd52(false, 0, 0x03, 0, &rdy) && (rdy & bit) != 0) { return true; }
		delay_ms(10);
	}
	return false;
}

// Function `func`'s block size (its FBR at 0x100 * func, +0x10 low byte, +0x11 high).
fn bool sdio_set_block_size(uint func, uint size)
{
	uint fbr = 0x100 * func;
	return sdio_cmd52(true, 0, fbr + 0x10, size & 0xFF, null) && sdio_cmd52(true, 0, fbr + 0x11, (size >> 8) & 0xFF, null);
}

// Card and controller to a `bits`-wide bus (1 or 4): CCCR 0x07 bits 1:0
// (0 = 1-bit, 2 = 4-bit), then the controller's CTYPE.
fn bool sdio_set_bus_width(uint bits)
{
	uint bus = 0;
	if (!sdio_cmd52(false, 0, 0x07, 0, &bus)) { return false; }
	if (!sdio_cmd52(true, 0, 0x07, (bus & ~3u) | (bits == 4 ? 2u : 0u), null)) { return false; }
	dw_write(DWMCI_CTYPE, bits == 4 ? DWMCI_CTYPE_4BIT : DWMCI_CTYPE_1BIT);
	return true;
}
