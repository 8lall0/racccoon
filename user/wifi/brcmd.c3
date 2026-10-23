module user;

import std::nolibc::fmt;

import std::nolibc::main_stub;

// brcmd: the Orange Pi RV's onboard Wi-Fi — an AP6256 module (Broadcom
// BCM43456, FullMAC) on the JH7110's sdio0 controller (0x16010000, the
// "mmc 0" U-Boot fails to probe on every boot). Stages W0-W5 in the
// memory note / devlog; this is W0 + W1 only:
//
//   W0  power: WL_REG_ON is sys GPIO 62 (mainline Linux's dts:
//       mmc-pwrseq-simple, reset-gpios = <&sysgpio 62 GPIO_ACTIVE_LOW>),
//       held low — the chip in reset — until someone drives it high.
//   W1  SDIO enumeration on sdio0 through dw_mshc.c3 (the same DesignWare
//       controller sdd drives on sdio1): CMD0, CMD5 until the card is
//       ready, CMD3, CMD7, then CMD52 reads of its common registers
//       (CCCR) and the manufacturer tuple — Broadcom is vendor 0x02D0.
//
//   W2a SDIO setup: function 1 on, block sizes, 4-bit bus; CMD53 transfers.
//   W2b the chip itself: the ALP clock request, then its id register on
//       the backplane (through function 1's 32 KiB address window).
//
//   W2c the cores, from the chip's enumeration ROM.
//   W2d the firmware: halt the ARM CR4, download /lib/firmware's
//       brcmfmac43456-sdio.bin + .txt (NVRAM) into its RAM, release it,
//       wait for function 2 (data) to come up.
//
// Prints what it finds, then idles as a server. The control channel and
// joining a network (W3/W4) build on this.

const uint WL_REG_ON  = 62;          // sys GPIO, the AP6256 WL_REG_ON line
const uptr SDIO0_BASE   = 0x16010000;

// --- the chip's backplane through function 1 (brcmfmac bcmsdh.c) ------
// F1 registers 0x1000A-C hold bits 15-31 of a 32 KiB window onto the
// backplane; an access goes to (addr & 0x7FFF) | 0x8000 (the 4-byte flag).
const uint SBSDIO_FUNC1_SBADDRLOW = 0x1000A;
const uint SBSDIO_FUNC1_CHIPCLKCSR = 0x1000E;
const uint SBSDIO_FUNC1_SDIOPULLUP = 0x1000F;
const uint SBSDIO_FORCE_ALP       = 0x01;
const uint SBSDIO_ALP_AVAIL_REQ   = 0x08;
const uint SBSDIO_FORCE_HW_CLKREQ_OFF = 0x20;
const uint SBSDIO_ALP_AVAIL       = 0x40;
const uint SBSDIO_HT_AVAIL        = 0x80;
const uint SI_ENUM_BASE           = 0x18000000; // chipcommon: chip id at offset 0

uint g_sbwin = 0xFFFFFFFF;

fn bool bp_window(uint addr)
{
	uint bar = addr & 0xFFFF8000;
	if (bar == g_sbwin) { return true; }
	uint v = bar >> 8;
	for (uint i = 0; i < 3; i++)
	{
		if (!sdio_cmd52(true, 1, SBSDIO_FUNC1_SBADDRLOW + i, v & 0xFF, null)) { return false; }
		v >>= 8;
	}
	g_sbwin = bar;
	return true;
}

fn bool bp_read32(uint addr, uint* out)
{
	if (!bp_window(addr)) { return false; }
	uint w = 0;
	if (!sdio_cmd53(false, 1, (addr & 0x7FFF) | 0x8000, (char*)&w, 4)) { return false; }
	*out = w;
	return true;
}

fn bool bp_write32(uint addr, uint v)
{
	if (!bp_window(addr)) { return false; }
	return sdio_cmd53(true, 1, (addr & 0x7FFF) | 0x8000, (char*)&v, 4);
}

// W2a: function 1 on, block sizes (F1 64, F2 512 — brcmfmac's), 4-bit bus.
fn bool sdio_setup()
{
	if (!sdio_enable_func(1, true, 1000)) { print("brcmd: F1 never became ready\n"); return false; }
	sdio_set_block_size(1, 64);    // brcmfmac's F1 / F2 block sizes
	sdio_set_block_size(2, 512);

	// 1-bit at the 400 kHz identification clock for now. On the board
	// (2026-10-23) CMD53 data only arrives there: switched to 4-bit (CCCR
	// 0x07 = 2 + CTYPE) the data never came even at 400 kHz, and 1-bit at
	// 25 MHz timed out the same way — CMD52 (CMD line only) works at both.
	// Open item, the same family as sdio1's 50 MHz failure (sampling /
	// pads). 400 kHz 1-bit moves the ~480 KB firmware in ~10 s.
	dw_write(DWMCI_TMOUT, (0x40000u << 8) | 0x40); // data timeout well under the poll budget
	print("brcmd: F1 ready, block sizes set, 1-bit bus at 400 kHz\n");
	return true;
}

// W2b: ask for the ALP clock (as brcmfmac's probe_attach does — PLL forced
// off until the chip is attached), then read the chip id.
fn bool chip_identify()
{
	if (!sdio_cmd52(true, 1, SBSDIO_FUNC1_CHIPCLKCSR, SBSDIO_FORCE_HW_CLKREQ_OFF | SBSDIO_ALP_AVAIL_REQ, null))
	{
		print("brcmd: CHIPCLKCSR write failed\n");
		return false;
	}
	uint clk = 0;
	bool alp = false;
	for (int i = 0; i < 100 && !alp; i++)
	{
		if (sdio_cmd52(false, 1, SBSDIO_FUNC1_CHIPCLKCSR, 0, &clk) && (clk & SBSDIO_ALP_AVAIL) != 0) { alp = true; } else { delay_ms(1); }
	}
	print("brcmd: CHIPCLKCSR=0x"); print_hex32(clk); print(alp ? " (ALP clock up)\n" : " (no ALP clock)\n");
	if (!alp) { return false; }
	// brcmfmac's buscoreprep: with ALP available, force it (and keep HW clock
	// requests off), 65 us to settle, and turn off the chip's own extra SDIO
	// pull-ups. Left in the "request" state, backplane reads (CMD53) never
	// returned data on the board.
	sdio_cmd52(true, 1, SBSDIO_FUNC1_CHIPCLKCSR, SBSDIO_FORCE_HW_CLKREQ_OFF | SBSDIO_FORCE_ALP, null);
	ulong t = rdtime();
	while (rdtime() - t < timebase_hz() / 15000 + 1) { }
	sdio_cmd52(true, 1, SBSDIO_FUNC1_SDIOPULLUP, 0, null);
	uint id = 0;
	if (!bp_read32(SI_ENUM_BASE, &id)) { print("brcmd: chip id read failed\n"); return false; }
	print("brcmd: chip id reg=0x"); print_hex32(id);
	print(" chip=0x"); print_hex32(id & 0xFFFF);
	print(" rev="); print_uint((id >> 16) & 0xF);
	print(((id >> 28) & 0xF) == 1 ? " (AXI backplane)\n" : " (SB backplane)\n");
	return true;
}

// --- W2c: the chip's cores, from its EROM (brcmfmac chip.c dmp scan) ----
// The enumeration ROM is a list of ARM PL-368 DMP descriptors: a core is
// two component descriptors (part number + revision/port counts), then
// address descriptors giving its register window (a "slave" region) and
// its wrapper (agent) window. chipcommon's eromptr (offset 0xFC) points at it.
const uint DMP_DESC_TYPE_MSK = 0x0F;
const uint DMP_DESC_VALID = 0x01;
const uint DMP_DESC_COMPONENT = 0x01;
const uint DMP_DESC_MASTER_PORT = 0x03;
const uint DMP_DESC_ADDRESS = 0x05;
const uint DMP_DESC_ADDRSIZE_GT32 = 0x08;
const uint DMP_DESC_EOT = 0x0F;
const uint CORE_CHIPCOMMON = 0x800;
const uint CORE_80211 = 0x812;
const uint CORE_PMU = 0x827;
const uint CORE_SDIO_DEV = 0x829;
const uint CORE_ARM_CR4 = 0x83E;
const uint CORE_GCI = 0x840;

struct Brcm_core { uint id; uint rev; uint base; uint wrap; }
Brcm_core[16] g_cores;
int g_ncores;

fn uint erom_desc(uint* addr, uint* type)
{
	uint v = 0;
	bp_read32(*addr, &v);
	*addr += 4;
	uint t = v & DMP_DESC_TYPE_MSK;
	if ((t & ~DMP_DESC_ADDRSIZE_GT32) == DMP_DESC_ADDRESS) { t = DMP_DESC_ADDRESS; }
	*type = t;
	return v;
}

fn bool erom_regaddr(uint* addr, uint* regbase, uint* wrapbase)
{
	*regbase = 0;
	*wrapbase = 0;
	uint t = 0;
	uint v = erom_desc(addr, &t);
	uint wraptype;
	if (t == DMP_DESC_MASTER_PORT) { wraptype = 3; }           // master wrapper
	else if (t == DMP_DESC_ADDRESS) { *addr -= 4; wraptype = 2; } // slave wrapper
	else { *addr -= 4; return false; }
	for (int guard = 0; guard < 64; guard++)
	{
		do
		{
			v = erom_desc(addr, &t);
			if (t == DMP_DESC_EOT) { *addr -= 4; return false; }
		} while (t != DMP_DESC_ADDRESS && t != DMP_DESC_COMPONENT);
		if (t == DMP_DESC_COMPONENT) { *addr -= 4; return true; }
		if ((v & DMP_DESC_ADDRSIZE_GT32) != 0) { erom_desc(addr, &t); }
		uint sztype = (v >> 4) & 3;
		if (sztype == 3)
		{
			uint szd = erom_desc(addr, &t);
			if ((szd & DMP_DESC_ADDRSIZE_GT32) != 0) { erom_desc(addr, &t); }
		}
		if (sztype != 0 && sztype != 1) { continue; }       // 4K / 8K register regions only
		uint stype = (v >> 6) & 3;
		if (*regbase == 0 && stype == 0) { *regbase = v & 0xFFFFF000; }
		if (*wrapbase == 0 && stype == wraptype) { *wrapbase = v & 0xFFFFF000; }
		if (*regbase != 0 && *wrapbase != 0) { return true; }
	}
	return false;
}

fn char* core_name(uint id)
{
	switch (id)
	{
		case CORE_CHIPCOMMON: return "chipcommon";
		case CORE_80211:      return "802.11";
		case CORE_PMU:        return "PMU";
		case CORE_SDIO_DEV:   return "SDIO device";
		case CORE_ARM_CR4:    return "ARM CR4";
		case CORE_GCI:        return "GCI";
		default:              return "";
	}
}

fn bool erom_scan()
{
	uint addr = 0;
	if (!bp_read32(SI_ENUM_BASE + 0xFC, &addr)) { print("brcmd: eromptr read failed\n"); return false; }
	print("brcmd: EROM at 0x"); print_hex32(addr); print(" — cores:\n");
	g_ncores = 0;
	uint t = 0;
	for (int guard = 0; guard < 512 && t != DMP_DESC_EOT; guard++)
	{
		uint v = erom_desc(&addr, &t);
		if ((v & DMP_DESC_VALID) == 0 || t != DMP_DESC_COMPONENT) { continue; }
		uint id = (v >> 8) & 0xFFF;
		uint v2 = erom_desc(&addr, &t);
		if ((v2 & DMP_DESC_TYPE_MSK) != DMP_DESC_COMPONENT) { print("brcmd: EROM: bad component pair\n"); return false; }
		uint nmw = (v2 >> 14) & 0x1F;
		uint nsw = (v2 >> 19) & 0x1F;
		uint rev = (v2 >> 24) & 0xFF;
		if (nmw + nsw == 0 && id != CORE_PMU && id != CORE_GCI) { continue; }
		uint base; uint wrap;
		if (!erom_regaddr(&addr, &base, &wrap)) { continue; }
		print("brcmd:   core 0x"); print_hex32(id); print(" rev "); print_uint(rev);
		print(" base 0x"); print_hex32(base); print(" wrap 0x"); print_hex32(wrap);
		print(" "); print(core_name(id)); print("\n");
		if (g_ncores < 16)
		{
			g_cores[g_ncores].id = id; g_cores[g_ncores].rev = rev;
			g_cores[g_ncores].base = base; g_cores[g_ncores].wrap = wrap;
			g_ncores++;
		}
	}
	return g_ncores > 0;
}

// --- W2d: the firmware (brcmfmac chip.c + sdio.c, for the ARM CR4) -----

// Core registers, and the AI wrapper's (agent's) control registers.
const uint BCMA_IOCTL = 0x408;
const uint BCMA_IOCTL_CLK = 0x01;
const uint BCMA_IOCTL_FGC = 0x02;
const uint BCMA_RESET_CTL = 0x800;
const uint BCMA_RESET_CTL_RESET = 0x01;
const uint ARMCR4_IOCTL_CPUHALT = 0x20;
const uint D11_IOCTL_PHYCLOCKEN = 0x04;
const uint D11_IOCTL_PHYRESET = 0x08;
const uint ARMCR4_CAP = 0x04;
const uint ARMCR4_BANKIDX = 0x40;
const uint ARMCR4_BANKINFO = 0x44;
const uint SD_REG_INTSTATUS = 0x20;        // SDIO device core (sdpcmd_regs)
const uint SBSDIO_FUNC1_SLEEPCSR = 0x1001F;
const uint SBSDIO_SLEEPCSR_KSO = 0x01;
const uint SBSDIO_HT_AVAIL_REQ = 0x10;
const uint RAMBASE_4345 = 0x198000;        // brcmf_chip_tcm_rambase

fn Brcm_core* core_by_id(uint id)
{
	for (int i = 0; i < g_ncores; i++)
	{
		if (g_cores[i].id == id) { return &g_cores[i]; }
	}
	return null;
}

fn uint wrap_rd(Brcm_core* c, uint off) { uint v = 0; bp_read32(c.wrap + off, &v); return v; }
fn void wrap_wr(Brcm_core* c, uint off, uint v) { bp_write32(c.wrap + off, v); }
fn uint core_rd(Brcm_core* c, uint off) { uint v = 0; bp_read32(c.base + off, &v); return v; }
fn void core_wr(Brcm_core* c, uint off, uint v) { bp_write32(c.base + off, v); }

// brcmf_chip_ai_coredisable
fn void core_disable(Brcm_core* c, uint prereset, uint reset)
{
	if ((wrap_rd(c, BCMA_RESET_CTL) & BCMA_RESET_CTL_RESET) == 0)
	{
		wrap_wr(c, BCMA_IOCTL, prereset | BCMA_IOCTL_FGC | BCMA_IOCTL_CLK);
		wrap_rd(c, BCMA_IOCTL);
		wrap_wr(c, BCMA_RESET_CTL, BCMA_RESET_CTL_RESET);
		delay_ms(1);
		for (int i = 0; i < 300 && wrap_rd(c, BCMA_RESET_CTL) != BCMA_RESET_CTL_RESET; i++) { }
	}
	wrap_wr(c, BCMA_IOCTL, reset | BCMA_IOCTL_FGC | BCMA_IOCTL_CLK);
	wrap_rd(c, BCMA_IOCTL);
}

// brcmf_chip_ai_resetcore (one 802.11 core on this chip)
fn void core_reset(Brcm_core* c, uint prereset, uint reset, uint postreset)
{
	core_disable(c, prereset, reset);
	for (int count = 0; count <= 50 && (wrap_rd(c, BCMA_RESET_CTL) & BCMA_RESET_CTL_RESET) != 0; count++)
	{
		wrap_wr(c, BCMA_RESET_CTL, 0);
		delay_ms(1);
	}
	wrap_wr(c, BCMA_IOCTL, postreset | BCMA_IOCTL_CLK);
	wrap_rd(c, BCMA_IOCTL);
}

// brcmf_chip_tcm_ramsize: the CR4's tightly-coupled RAM, bank by bank.
fn uint cr4_ramsize(Brcm_core* cr4)
{
	uint cap = core_rd(cr4, ARMCR4_CAP);
	uint banks = (cap & 0xF) + ((cap >> 4) & 0xF);
	uint size = 0;
	for (uint i = 0; i < banks; i++)
	{
		core_wr(cr4, ARMCR4_BANKIDX, i);
		uint info = core_rd(cr4, ARMCR4_BANKINFO);
		uint blk = (info & 0x200) != 0 ? 1024 : 8192;
		size += ((info & 0x7F) + 1) * blk;
	}
	return size;
}

// Backplane memory, in byte-mode CMD53s of at most F1's block size (64 —
// a 512-byte one came back OUT_OF_RANGE + a data CRC error on the board),
// each inside one 32 KiB window (brcmf_sdiod_ramrw). `n` is a multiple of 4.
const uint F1_BLOCK = 64;

fn bool ram_rw(bool write, uint addr, char* buf, uint n)
{
	uint done = 0;
	while (done < n)
	{
		uint a = addr + done;
		uint chunk = n - done;
		if (chunk > F1_BLOCK) { chunk = F1_BLOCK; }
		uint room = 0x8000 - (a & 0x7FFF);
		if (chunk > room) { chunk = room; }
		if (!bp_window(a)) { return false; }
		if (!sdio_cmd53(write, 1, (a & 0x7FFF) | 0x8000, &buf[done], chunk)) { return false; }
		done += chunk;
	}
	return true;
}

// A failed backplane transfer: abort function 1 (sdio.c3) and forget the
// window — the next access sets it again.
fn void bp_abort()
{
	sdio_abort(1);
	g_sbwin = 0xFFFFFFFF;
}

// The 4-bit bus and 25 MHz failed before the clock sequence above was
// right — try them again, each checked with a real read, each undone if
// it fails.
fn void try_fast_bus()
{
	uint id = 0;
	sdio_set_bus_width(4);
	g_sbwin = 0xFFFFFFFF;
	if (bp_read32(SI_ENUM_BASE, &id) && (id & 0xFFFF) == 0x4345)
	{
		print("brcmd: 4-bit bus works\n");
	}
	else
	{
		bp_abort();
		sdio_set_bus_width(1);
		print("brcmd: 4-bit still fails — 1-bit\n");
	}
	if (dw_set_clock(DW_CLKDIV_RUN))
	{
		g_sbwin = 0xFFFFFFFF;
		if (bp_read32(SI_ENUM_BASE, &id) && (id & 0xFFFF) == 0x4345)
		{
			print("brcmd: 25 MHz works\n");
			return;
		}
		bp_abort();
	}
	dw_set_clock(DW_CLKDIV_ENUM);
	print("brcmd: 25 MHz fails — staying at 400 kHz\n");
}

// brcmf_fw_nvram_strip, simplified: `key=value` lines, comments and blank
// lines dropped, leading/trailing blanks trimmed, each NUL-terminated;
// padded to roundup(len + 1, 4), then the length token
// (~words << 16 | words). Returns the total length (token included).
fn uint nvram_build(char* text, uint tlen, char* out, uint cap)
{
	uint o = 0;
	uint i = 0;
	while (i < tlen)
	{
		uint s = i;
		while (i < tlen && text[i] != '\n') { i++; }
		uint e = i;
		i++;
		while (s < e && (text[s] == ' ' || text[s] == '\t' || text[s] == '\r')) { s++; }
		if (s >= e || text[s] == '#') { continue; }
		uint eq = s;
		while (eq < e && text[eq] != '=') { eq++; }
		if (eq >= e) { continue; }
		while (e > s && (text[e - 1] == ' ' || text[e - 1] == '\t' || text[e - 1] == '\r')) { e--; }
		if (o + (e - s) + 8 >= cap) { break; }
		for (uint k = s; k < e; k++) { out[o] = text[k]; o++; }
		out[o] = 0;
		o++;
	}
	uint padded = (o + 1 + 3) & ~3u;
	while (o < padded) { out[o] = 0; o++; }
	uint words = padded / 4;
	uint token = (~words << 16) | (words & 0xFFFF);
	out[o] = (char)(token & 0xFF); out[o + 1] = (char)((token >> 8) & 0xFF);
	out[o + 2] = (char)((token >> 16) & 0xFF); out[o + 3] = (char)(token >> 24);
	return o + 4;
}

// A whole file into freshly mapped memory; its size in *out_len.
fn char* load_file(char* path, uint* out_len)
{
	uint size = 0;
	int type = 0;
	if (fs_stat(path, &size, &type) != 0 || size == 0) { return null; }
	char* buf = (char*)map_pages(size + 4096);
	if (buf == null) { return null; }
	uint off = 0;
	while (off < size)
	{
		int want = size - off > 4096 ? 4096 : (int)(size - off);
		int got = fs_read_at(path, &buf[off], want, off);
		if (got <= 0) { return null; }
		off += (uint)got;
	}
	*out_len = size;
	return buf;
}

const char* FW_PATH = "/lib/firmware/brcmfmac43456-sdio.bin";
const char* NVRAM_PATH = "/lib/firmware/brcmfmac43456-sdio.txt";

fn bool firmware_start()
{
	Brcm_core* cr4 = core_by_id(CORE_ARM_CR4);
	Brcm_core* d11 = core_by_id(CORE_80211);
	Brcm_core* sdc = core_by_id(CORE_SDIO_DEV);
	if (cr4 == null || d11 == null || sdc == null) { print("brcmd: missing a core (CR4/802.11/SDIO)\n"); return false; }

	// Keep the SDIO core awake (save/restore-capable chips sleep otherwise).
	uint sl = 0;
	if (sdio_cmd52(false, 1, SBSDIO_FUNC1_SLEEPCSR, 0, &sl) && (sl & SBSDIO_SLEEPCSR_KSO) == 0)
	{
		sdio_cmd52(true, 1, SBSDIO_FUNC1_SLEEPCSR, sl | SBSDIO_SLEEPCSR_KSO, null);
	}

	// Passive: halt the ARM (keep only its HALT bit), disable the 802.11 core.
	uint halt = wrap_rd(cr4, BCMA_IOCTL) & ARMCR4_IOCTL_CPUHALT;
	core_reset(cr4, halt, ARMCR4_IOCTL_CPUHALT, ARMCR4_IOCTL_CPUHALT);
	core_disable(d11, D11_IOCTL_PHYRESET | D11_IOCTL_PHYCLOCKEN, D11_IOCTL_PHYCLOCKEN);
	uint ramsize = cr4_ramsize(cr4);
	print("brcmd: ARM halted; RAM base 0x"); print_hex32(RAMBASE_4345);
	print(" size "); print_uint(ramsize / 1024); print(" KiB\n");
	if (ramsize == 0 || ramsize > 0x200000) { return false; }

	// The fast backplane clock for the download (brcmf_sdio_clkctl CLK_AVAIL).
	sdio_cmd52(true, 1, SBSDIO_FUNC1_CHIPCLKCSR, SBSDIO_HT_AVAIL_REQ, null);
	uint clk = 0;
	bool ht = false;
	for (int i = 0; i < 200 && !ht; i++)
	{
		if (sdio_cmd52(false, 1, SBSDIO_FUNC1_CHIPCLKCSR, 0, &clk) && (clk & SBSDIO_HT_AVAIL) != 0) { ht = true; } else { delay_ms(5); }
	}
	print(ht ? "brcmd: HT clock up\n" : "brcmd: no HT clock — downloading on ALP\n");

	uint fwlen = 0;
	char* fw = load_file(FW_PATH, &fwlen);
	if (fw == null) { print("brcmd: no "); print(FW_PATH); print("\n"); return false; }
	uint nvlen = 0;
	char* nvtext = load_file(NVRAM_PATH, &nvlen);
	if (nvtext == null) { print("brcmd: no "); print(NVRAM_PATH); print("\n"); return false; }
	uint fwpad = (fwlen + 3) & ~3u;
	for (uint k = fwlen; k < fwpad; k++) { fw[k] = 0; }
	uint rstvec = (uint)(fw[0] & 0xFF) | ((uint)(fw[1] & 0xFF) << 8) | ((uint)(fw[2] & 0xFF) << 16) | ((uint)(fw[3] & 0xFF) << 24);

	print("brcmd: downloading "); print_uint(fwlen); print(" bytes of firmware...\n");
	ulong t0 = rdtime();
	if (!ram_rw(true, RAMBASE_4345, fw, fwpad)) { print("brcmd: firmware write failed\n"); return false; }
	char[512] chk;
	if (!ram_rw(false, RAMBASE_4345, &chk[0], 512)) { print("brcmd: read-back failed\n"); return false; }
	for (int k = 0; k < 512; k++)
	{
		if (chk[k] != fw[k]) { print("brcmd: firmware read-back differs\n"); return false; }
	}
	print("brcmd: firmware written + verified in "); print_uint((uint)((rdtime() - t0) * 1000 / timebase_hz())); print(" ms\n");

	char* nv = (char*)map_pages(nvlen + 4096);
	uint nvsize = nvram_build(nvtext, nvlen, nv, nvlen + 4096);
	uint nvaddr = RAMBASE_4345 + ramsize - nvsize;
	if (!ram_rw(true, nvaddr, nv, nvsize)) { print("brcmd: NVRAM write failed\n"); return false; }
	print("brcmd: NVRAM "); print_uint(nvsize); print(" bytes at 0x"); print_hex32(nvaddr); print("\n");

	// Active: clear the SDIO core's interrupts, reset vector to address 0,
	// release the ARM.
	core_wr(sdc, SD_REG_INTSTATUS, 0xFFFFFFFF);
	bp_write32(0, rstvec);
	core_reset(cr4, ARMCR4_IOCTL_CPUHALT, 0, 0);
	print("brcmd: ARM released (reset vector 0x"); print_hex32(rstvec); print(")\n");

	// F2 (the data channel) is enabled by bus_init, after the mailbox write.
	return true;
}

// --- W3a: the control channel (brcmfmac sdio.c framing + bcdc.c) -------
// Every frame on function 2 starts with SDPCM headers: a 4-byte hardware
// header (length, ~length) and an 8-byte software header (sequence,
// channel << 8, data offset << 24; then 0). Control frames (channel 0)
// carry a BCDC command: cmd, len, flags (set bit 1, request id << 16),
// status — then the payload. F2 is a FIFO addressed like the backplane:
// window on chipcommon, offset 0x8000.
const uint SD_REG_HOSTINTMASK = 0x24;
const uint SD_REG_TOSBMAILBOXDATA = 0x48;
const uint I_HMB_FRAME_IND = 1u << 6;
const uint HOSTINTMASK = 0xF0 | (1u << 29); // I_HMB_SW_MASK | I_CHIPACTIVE
const uint SDPCM_PROT_VERSION = 4;
const uint SBSDIO_FORCE_HT = 0x02;
const uint SBSDIO_WATERMARK = 0x10008;
const uint SBSDIO_DEVICE_CTL = 0x10009;
const uint SBSDIO_DEVCTL_F2WM_ENAB = 0x10;
const uint SBSDIO_FUNC1_MESBUSYCTRL = 0x1001D;
const uint SDPCM_HDRLEN = 12;
const uint BCDC_HDRLEN = 16;
const uint BRCMF_C_GET_VAR = 262;
const uint BRCMF_FIRSTREAD = 64;

uint g_txseq;
uint g_reqid = 1;
const uint BRCM_BUF = 4096;
char[BRCM_BUF] g_rxbuf @align(4);
char[BRCM_BUF] g_txbuf @align(4);

fn void put32(char* p, uint v)
{
	p[0] = (char)(v & 0xFF); p[1] = (char)((v >> 8) & 0xFF);
	p[2] = (char)((v >> 16) & 0xFF); p[3] = (char)(v >> 24);
}
fn uint get32(char* p)
{
	return (uint)(p[0] & 0xFF) | ((uint)(p[1] & 0xFF) << 8) | ((uint)(p[2] & 0xFF) << 16) | ((uint)(p[3] & 0xFF) << 24);
}

// brcmfmac's firmware_callback: backplane clock forced on (HT, so F2
// interrupts propagate), protocol version to the device mailbox, F2 on,
// host interrupt mask, and the 43455's F2/MES watermarks.
fn bool bus_init(Brcm_core* sdc)
{
	uint clk = 0;
	sdio_cmd52(false, 1, SBSDIO_FUNC1_CHIPCLKCSR, 0, &clk);
	sdio_cmd52(true, 1, SBSDIO_FUNC1_CHIPCLKCSR, clk | SBSDIO_FORCE_HT, null);
	bool ht = false;
	for (int i = 0; i < 200 && !ht; i++)
	{
		if (sdio_cmd52(false, 1, SBSDIO_FUNC1_CHIPCLKCSR, 0, &clk) && (clk & SBSDIO_HT_AVAIL) != 0) { ht = true; } else { delay_ms(5); }
	}
	print(ht ? "brcmd: HT clock up (firmware running)\n" : "brcmd: still no HT clock\n");
	core_wr(sdc, SD_REG_TOSBMAILBOXDATA, SDPCM_PROT_VERSION << 16);
	if (!sdio_enable_func(2, true, 3000)) { print("brcmd: F2 not ready after the mailbox write\n"); return false; }
	core_wr(sdc, SD_REG_HOSTINTMASK, HOSTINTMASK);
	sdio_cmd52(true, 1, SBSDIO_WATERMARK, 0x60, null);
	uint devctl = 0;
	sdio_cmd52(false, 1, SBSDIO_DEVICE_CTL, 0, &devctl);
	sdio_cmd52(true, 1, SBSDIO_DEVICE_CTL, devctl | SBSDIO_DEVCTL_F2WM_ENAB, null);
	sdio_cmd52(true, 1, SBSDIO_FUNC1_MESBUSYCTRL, 0x50 | 0x80, null);
	return true;
}

// F2 transfers: byte-mode CMD53 up to 512, whole 512-byte blocks in block
// mode (F2's block size is 512, sdio_setup) + a byte-mode tail.
fn bool f2_xfer(bool write, char* buf, uint n)
{
	uint blocks = n / 512;
	if (blocks > 0 && !sdio_cmd53_blocks(write, 2, 0x8000, buf, blocks)) { return false; }
	uint tail = n - blocks * 512;
	if (tail > 0 && !sdio_cmd53(write, 2, 0x8000, &buf[blocks * 512], tail)) { return false; }
	return true;
}

// One frame to F2: SDPCM headers + `body` (already in g_txbuf after the
// headers), length padded to 4 — and past one block, to whole blocks, as
// brcmfmac's tx does (the firmware takes the length from the header).
fn bool f2_send(uint channel, uint body_len)
{
	uint len = SDPCM_HDRLEN + body_len;
	put32(&g_txbuf[0], (len & 0xFFFF) | ((~len & 0xFFFF) << 16));
	put32(&g_txbuf[4], (g_txseq & 0xFF) | ((channel & 0xF) << 8) | (SDPCM_HDRLEN << 24));
	put32(&g_txbuf[8], 0);
	g_txseq = (g_txseq + 1) & 0xFF;
	uint xfer = (len + 3) & ~3u;
	if (xfer > 512) { xfer = (xfer + 511) & ~511u; }
	if (xfer > BRCM_BUF) { return false; }
	for (uint k = len; k < xfer; k++) { g_txbuf[k] = 0; }
	if (!bp_window(SI_ENUM_BASE)) { return false; }
	return f2_xfer(true, &g_txbuf[0], xfer);
}

// One frame from F2 into g_rxbuf: the first 64 bytes, then the rest the
// hardware header asks for. Returns the frame length, 0 when none is
// waiting (an all-zero header), or -1 on a bad header / transfer error.
fn int f2_recv()
{
	if (!bp_window(SI_ENUM_BASE)) { return -1; }
	if (!sdio_cmd53(false, 2, 0x8000, &g_rxbuf[0], BRCMF_FIRSTREAD)) { return -1; }
	uint hw = get32(&g_rxbuf[0]);
	uint len = hw & 0xFFFF;
	uint chk = hw >> 16;
	if (len == 0 && chk == 0) { return 0; }
	if (((len ^ chk) & 0xFFFF) != 0xFFFF || len < SDPCM_HDRLEN || len > BRCM_BUF)
	{
		print("brcmd: bad F2 header 0x"); print_hex32(hw); print("\n");
		return -1;
	}
	if (len > BRCMF_FIRSTREAD)
	{
		uint rest = (len - BRCMF_FIRSTREAD + 3) & ~3u;
		if (!f2_xfer(false, &g_rxbuf[BRCMF_FIRSTREAD], rest)) { return -1; }
	}
	return (int)len;
}

// --- W3b: events (channel 1) -------------------------------------------
// After the SDPCM headers an event frame carries a 4-byte BCDC data
// header (flags, priority, flags2, data offset in words), then an
// Ethernet frame of type 0x886C: brcm_ethhdr (10 bytes) + the big-endian
// brcmf_event_msg_be (48 bytes) + `datalen` bytes of event data.
const uint BRCMF_E_SET_SSID = 0;
const uint BRCMF_E_AUTH = 3;
const uint BRCMF_E_DEAUTH = 5;
const uint BRCMF_E_DEAUTH_IND = 6;
const uint BRCMF_E_ASSOC = 7;
const uint BRCMF_E_DISASSOC = 11;
const uint BRCMF_E_DISASSOC_IND = 12;
const uint BRCMF_E_LINK = 16;
const uint BRCMF_E_IF = 54;
const uint BRCMF_E_PSK_SUP = 46;
const uint BRCMF_E_ESCAN_RESULT = 69;
const uint BRCMF_E_STATUS_PARTIAL = 8;
const uint BRCMF_EVENT_MASK_LEN = 18;
const uint BRCMF_C_UP = 2;
const uint BRCMF_C_SET_INFRA = 20;
const uint BRCMF_C_SET_AUTH = 22;
const uint BRCMF_C_SET_SSID = 26;
const uint BRCMF_C_DISASSOC = 52;
const uint BRCMF_C_SET_WSEC_PMK = 268;
const uint BRCMF_C_SET_VAR = 263;
const uint BCDC_DCMD_ERROR = 0x01;
const uint BCDC_DCMD_SET = 0x02;

fn uint get16(char* p) { return (uint)(p[0] & 0xFF) | ((uint)(p[1] & 0xFF) << 8); }
fn uint get_be16(char* p) { return ((uint)(p[0] & 0xFF) << 8) | (uint)(p[1] & 0xFF); }
fn uint get_be32(char* p) { return (get_be16(p) << 16) | get_be16(&p[2]); }

fn void print_mac(char* m)
{
	for (int k = 0; k < 6; k++)
	{
		print_hex8((uint)(m[k] & 0xFF));
		if (k < 5) { print(":"); }
	}
}

fn void print_int(int v)
{
	if (v < 0) { print("-"); print_uint((uint)(-v)); } else { print_uint((uint)v); }
}

// Scan state: results come as one event per BSS (status PARTIAL), then a
// final one (status 0); the firmware repeats a BSS per probe answered, so
// a BSSID already in the table only refreshes its signal.
const int SCAN_MAX = 48;
struct Brcm_bss
{
	char[6] bssid;
	char[33] ssid;
	uint channel;
	int rssi;
	bool secured;
}
Brcm_bss[SCAN_MAX] g_bss;
int g_nbss;
bool g_scanning;
bool g_scan_done;
uint g_scan_status;

fn void escan_result(char* d, uint dlen, uint status)
{
	if (status != BRCMF_E_STATUS_PARTIAL)
	{
		g_scanning = false;
		g_scan_done = true;
		g_scan_status = status;
		return;
	}
	if (dlen < 12 + 92) { return; }
	if (get16(&d[10]) == 0) { return; }
	char* bi = &d[12];
	char* bssid = &bi[8];
	Brcm_bss* e = null;
	for (int k = 0; k < g_nbss && e == null; k++)
	{
		bool same = true;
		for (int b = 0; b < 6; b++) { if (g_bss[k].bssid[b] != bssid[b]) { same = false; } }
		if (same) { e = &g_bss[k]; }
	}
	int rssi = (int)(short)get16(&bi[78]);
	if (e != null) { if (rssi > e.rssi) { e.rssi = rssi; } return; }
	if (g_nbss >= SCAN_MAX) { return; }
	e = &g_bss[g_nbss];
	g_nbss++;
	for (int b = 0; b < 6; b++) { e.bssid[b] = bssid[b]; }
	uint ssid_len = (uint)(bi[18] & 0xFF);
	if (ssid_len > 32) { ssid_len = 32; }
	for (uint k = 0; k < ssid_len; k++) { e.ssid[k] = bi[19 + k]; }
	e.ssid[ssid_len] = 0;
	// ctl_ch (the control channel); chanspec's low byte is the centre
	// channel on 40/80 MHz BSSes
	e.channel = (uint)(bi[88] & 0xFF);
	if (e.channel == 0) { e.channel = get16(&bi[72]) & 0xFF; }
	e.rssi = rssi;
	e.secured = (get16(&bi[16]) & 0x10) != 0;
}

fn int cat(char* out, int n, char* s)
{
	for (int k = 0; s[k] != 0; k++) { out[n] = s[k]; n++; }
	return n;
}

// The scan list as /bin/wifi prints it: bssid channel signal security ssid.
fn int scan_text(char* out, int cap)
{
	int n = 0;
	char* hx = "0123456789abcdef";
	for (int i = 0; i < g_nbss && n < cap - 80; i++)
	{
		Brcm_bss* b = &g_bss[i];
		for (int k = 0; k < 6; k++)
		{
			out[n] = hx[((uint)b.bssid[k] >> 4) & 0xF]; out[n + 1] = hx[(uint)b.bssid[k] & 0xF]; n += 2;
			if (k < 5) { out[n] = ':'; n++; }
		}
		out[n] = ' '; n++;
		n += fmt::format_uint(b.channel, &out[n]);
		out[n] = ' '; n++;
		if (b.rssi < 0) { out[n] = '-'; n++; n += fmt::format_uint((uint)(-b.rssi), &out[n]); }
		else { n += fmt::format_uint((uint)b.rssi, &out[n]); }
		n = cat(out, n, b.secured ? " wpa2 " : " open ");
		n = cat(out, n, b.ssid[0] != 0 ? &b.ssid[0] : "(hidden)");
		out[n] = '\n'; n++;
	}
	return n;
}

// --- W4: station state (the firmware runs the join and the WPA2 4-way
// handshake itself; we configure it and follow its events) ---------------
const int STA_IDLE = 0;
const int STA_JOINING = 1;    // SET_SSID sent
const int STA_KEYING = 2;     // associated, firmware supplicant handshaking
const int STA_UP = 3;
const uint BRCMF_EVENT_MSG_LINK = 0x01;
const uint BRCMF_E_STATUS_FWSUP_COMPLETED = 6;

int g_sta = STA_IDLE;
char[33] g_sta_ssid;
bool g_sta_wpa;
uint g_sta_reason;
bool g_link;
Brcm_core* g_sdc;

fn void sta_set(int s, char* why)
{
	g_sta = s;
	link_state(s == STA_UP);
	print("brcmd: wifi "); print(why);
	if (s != STA_IDLE) { print(" ("); print(&g_sta_ssid[0]); print(")"); }
	print("\n");
}

fn void sta_event(uint type, uint status, uint reason, uint flags)
{
	print("brcmd: event "); print_uint(type); print(" status "); print_uint(status);
	print(" reason "); print_uint(reason); print(" flags 0x"); print_hex32(flags); print("\n");
	if (type == BRCMF_E_SET_SSID)
	{
		if (g_sta != STA_JOINING) { return; }
		if (status != 0) { g_sta_reason = status; sta_set(STA_IDLE, "join failed"); return; }
		if (g_sta_wpa) { sta_set(STA_KEYING, "associated, handshaking"); }
		else { sta_set(STA_UP, "joined (open)"); }
	}
	else if (type == BRCMF_E_PSK_SUP)
	{
		if (g_sta != STA_KEYING && g_sta != STA_JOINING) { return; }
		if (status == BRCMF_E_STATUS_FWSUP_COMPLETED) { sta_set(STA_UP, "joined (wpa2)"); }
		else
		{
			g_sta_reason = reason;
			print("brcmd: supplicant status "); print_uint(status); print(" reason "); print_uint(reason); print("\n");
		}
	}
	else if (type == BRCMF_E_LINK)
	{
		bool up = (flags & BRCMF_EVENT_MSG_LINK) != 0;
		if (up != g_link) { g_link = up; print(up ? "brcmd: link up\n" : "brcmd: link down\n"); }
		if (!up && g_sta != STA_IDLE) { g_sta_reason = reason; sta_set(STA_IDLE, "link lost"); }
	}
	else if (type == BRCMF_E_DEAUTH || type == BRCMF_E_DEAUTH_IND || type == BRCMF_E_DISASSOC || type == BRCMF_E_DISASSOC_IND)
	{
		if (g_sta == STA_IDLE) { return; }
		g_sta_reason = reason;
		print("brcmd: deauth/disassoc reason "); print_uint(reason); print("\n");
	}
}

// One event frame (g_rxbuf, SDPCM data offset `doff`, frame length `len`).
fn void handle_event(char* f, uint doff, uint len)
{
	if (len < doff + 4) { return; }
	char* b = &f[doff];
	uint dataoff = 4 + (uint)(b[3] & 0xFF) * 4;
	if (len < doff + dataoff + 14 + 10 + 48) { return; }
	char* eth = &b[dataoff];
	if (get_be16(&eth[12]) != 0x886C) { return; }
	char* msg = &eth[14 + 10];
	uint type = get_be32(&msg[4]);
	uint status = get_be32(&msg[8]);
	uint reason = get_be32(&msg[12]);
	uint datalen = get_be32(&msg[20]);
	char* data = &msg[48];
	uint avail = len - (doff + dataoff + 14 + 10 + 48);
	if (datalen > avail) { datalen = avail; }
	if (type == BRCMF_E_ESCAN_RESULT) { escan_result(data, datalen, status); return; }
	sta_event(type, status, reason, get_be16(&msg[2]));
}

// --- W5: frames by channel ------------------------------------------
// SDPCM software header: word 1 = seq | channel << 8 | next length << 16 |
// data offset << 24; word 2 = flow control | the firmware's tx window
// (the highest tx sequence it will take) << 8. Channel 0 control
// replies, 1 events, 2 data, 3 a glom descriptor: the next F2 read is a
// superframe of the subframes whose lengths it lists (u16 each).
const uint SDPCM_CONTROL = 0;
const uint SDPCM_EVENT = 1;
const uint SDPCM_DATA = 2;
const uint SDPCM_GLOM = 3;
const uint BCDC_PROTO_VER = 2;
const uint GLOM_BUF = 16384;

uint g_txmax = 4;
char[GLOM_BUF] g_globuf @align(4);
ulong g_rx_data;
ulong g_tx_data;
ulong g_rx_gloms;
Link g_link_ring;
bool g_link_ok;

// One data frame: BCDC data header (flags, priority, flags2 = interface,
// data offset in words) + an Ethernet frame -> ipd's RX ring.
fn void data_input(char* f, uint doff, uint len)
{
	if (len < doff + 4 || !g_link_ok || g_sta != STA_UP) { return; }
	char* b = &f[doff];
	uint off = doff + 4 + (uint)(b[3] & 0xFF) * 4;
	if (len < off + 14) { return; }
	if (link_put(&g_link_ring, &f[off], len - off)) { g_rx_data++; }
}

// Dispatch one frame `f` (`len` bytes, SDPCM headers first). For a control
// reply to request `id` it's copied to g_rxbuf (if not already there) and
// its data offset returned; otherwise -1.
fn int frame_dispatch(Brcm_core* sdc, char* f, uint len, uint id)
{
	uint sw = get32(&f[4]);
	uint chan = (sw >> 8) & 0xF;
	uint doff = sw >> 24;
	uint win = (get32(&f[8]) >> 8) & 0xFF;
	if (((win - g_txseq) & 0xFF) <= 0x40) { g_txmax = win; }
	if (doff < SDPCM_HDRLEN || doff > len) { return -1; }
	if (chan == SDPCM_EVENT) { handle_event(f, doff, len); return -1; }
	if (chan == SDPCM_DATA) { data_input(f, doff, len); return -1; }
	if (chan == SDPCM_GLOM) { glom_input(sdc, f, doff, len, id); return g_glom_hit; }
	if (chan != SDPCM_CONTROL) { return -1; }
	if ((get32(&f[doff + 8]) >> 16) != id) { return -1; }
	if (f != &g_rxbuf[0]) { for (uint k = 0; k < len; k++) { g_rxbuf[k] = f[k]; } }
	return (int)doff;
}

int g_glom_hit;
int g_glom_len;

// A glom descriptor: read the superframe, dispatch each subframe.
fn void glom_input(Brcm_core* sdc, char* d, uint doff, uint len, uint id)
{
	g_glom_hit = -1;
	uint total = 0;
	for (uint k = doff; k + 1 < len; k += 2) { total += get16(&d[k]); }
	if (total == 0 || total > GLOM_BUF) { print("brcmd: bad glom descriptor\n"); return; }
	uint xfer = (total + 3) & ~3u;
	if (!bp_window(SI_ENUM_BASE) || !f2_xfer(false, &g_globuf[0], xfer)) { print("brcmd: glom read failed\n"); return; }
	g_rx_gloms++;
	uint pos = 0;
	for (uint k = doff; k + 1 < len; k += 2)
	{
		uint sub = get16(&d[k]);
		if (pos + sub > total) { break; }
		char* f = &g_globuf[pos];
		uint flen = get32(&f[0]) & 0xFFFF;
		if (flen >= SDPCM_HDRLEN && flen <= sub)
		{
			int r = frame_dispatch(sdc, f, flen, id);
			if (r >= 0) { g_glom_hit = r; g_glom_len = (int)flen; }
		}
		pos += sub;
	}
}

// Poll F2 once: dispatch what came, return a control reply's BCDC header
// position (>= 0, in g_rxbuf) for request `id`, -1 if nothing for us yet,
// -2 on error. *out_len = the frame length (0 = nothing was queued).
fn int f2_poll(Brcm_core* sdc, uint id, int* out_len)
{
	uint st = core_rd(sdc, SD_REG_INTSTATUS);
	if (st != 0) { core_wr(sdc, SD_REG_INTSTATUS, st); }
	int len = f2_recv();
	*out_len = len;
	if (len < 0) { return -2; }
	if (len == 0) { return -1; }
	uint chan = (get32(&g_rxbuf[4]) >> 8) & 0xF;
	int r = frame_dispatch(sdc, &g_rxbuf[0], (uint)len, id);
	if (r >= 0 && chan == SDPCM_GLOM) { *out_len = g_glom_len; } // the reply came inside a glom
	return r;
}

// ipd's TX ring -> F2 data frames, while the firmware's window allows.
fn void data_output()
{
	if (!g_link_ok) { return; }
	for (int k = 0; k < 16; k++)
	{
		uint room = (g_txmax - g_txseq) & 0xFF;
		if (room == 0 || (room & 0x80) != 0) { return; }
		char* p = &g_txbuf[SDPCM_HDRLEN];
		int n = link_get(&g_link_ring, &p[4]);
		if (n < 0) { return; }
		if (g_sta != STA_UP || n < 14) { continue; }
		p[0] = (char)(BCDC_PROTO_VER << 4); p[1] = 0; p[2] = 0; p[3] = 0;
		if (f2_send(SDPCM_DATA, 4 + (uint)n)) { g_tx_data++; }
	}
}

fn void link_state(bool up)
{
	if (!g_link_ok) { return; }
	g_link_ring.h.link_up = up ? 1 : 0;
	link_kick(&g_link_ring);
}

// A BCDC command: `cmd` with `plen` payload bytes already at the BCDC
// payload position in g_txbuf. Copies up to `outcap` reply bytes into
// `out`. Returns the firmware's status (0 = ok), -1 on no / bad reply.
fn int bcdc_cmd(Brcm_core* sdc, uint cmd, bool set, uint plen, char* out, uint outcap)
{
	char* p = &g_txbuf[SDPCM_HDRLEN];
	uint id = g_reqid & 0xFFFF;
	g_reqid++;
	put32(&p[0], cmd);
	put32(&p[4], plen);
	put32(&p[8], (id << 16) | (set ? BCDC_DCMD_SET : 0));
	put32(&p[12], 0);
	if (!f2_send(0, BCDC_HDRLEN + plen)) { print("brcmd: control frame send failed\n"); return -1; }
	for (int tries = 0; tries < 400; tries++)
	{
		int len = 0;
		int doff = f2_poll(sdc, id, &len);
		if (doff == -2) { print("brcmd: bad frame from F2\n"); return -1; }
		if (doff < 0) { delay_ms(5); continue; }
		char* b = &g_rxbuf[doff];
		uint rflags = get32(&b[8]);
		int status = (int)get32(&b[12]);
		if ((rflags & BCDC_DCMD_ERROR) != 0 && status == 0) { status = -1; }
		uint rlen = (uint)len - (uint)doff - BCDC_HDRLEN;
		uint copy = rlen < outcap ? rlen : outcap;
		for (uint k = 0; k < copy; k++) { out[k] = b[BCDC_HDRLEN + k]; }
		return status;
	}
	print("brcmd: no reply to command "); print_uint(cmd); print("\n");
	return -1;
}

// Payload = name\0 + `dlen` bytes of `data` (set) or zeroes up to `buflen` (get).
fn uint iovar_put(char* name, char* data, uint dlen, uint buflen)
{
	char* p = &g_txbuf[SDPCM_HDRLEN + BCDC_HDRLEN];
	uint n = 0;
	while (name[n] != 0) { p[n] = name[n]; n++; }
	p[n] = 0;
	n++;
	for (uint k = 0; k < dlen; k++) { p[n + k] = data != null ? data[k] : 0; }
	uint total = n + dlen;
	if (total < buflen) { for (uint k = total; k < buflen; k++) { p[k] = 0; } total = buflen; }
	return total;
}

fn int bcdc_get_var(Brcm_core* sdc, char* name, uint buflen, char* out, uint outcap)
{
	uint plen = iovar_put(name, null, 0, buflen);
	return bcdc_cmd(sdc, BRCMF_C_GET_VAR, false, plen, out, outcap);
}

fn int bcdc_set_var(Brcm_core* sdc, char* name, char* data, uint dlen)
{
	uint plen = iovar_put(name, data, dlen, 0);
	char[4] dummy;
	return bcdc_cmd(sdc, BRCMF_C_SET_VAR, true, plen, &dummy[0], 0);
}

fn int bcdc_set_int(Brcm_core* sdc, uint cmd, uint v)
{
	put32(&g_txbuf[SDPCM_HDRLEN + BCDC_HDRLEN], v);
	char[4] dummy;
	return bcdc_cmd(sdc, cmd, true, 4, &dummy[0], 0);
}

// The CLM blob (regulatory: which channels/powers per country) in 1400-byte
// "clmload" chunks: brcmf_dload_data_le {flag, type = CLM, len, crc 0}.
const char* CLM_PATH = "/lib/firmware/brcmfmac43456-sdio.clm_blob";
const uint CLM_CHUNK = 1400;

fn void clm_load(Brcm_core* sdc)
{
	uint size = 0;
	char* clm = load_file(CLM_PATH, &size);
	if (clm == null) { print("brcmd: no "); print(CLM_PATH); print(" — firmware's built-in channels only\n"); return; }
	char[CLM_CHUNK + 12] chunk;
	uint off = 0;
	uint flag = 0x0002; // DL_BEGIN
	while (off < size)
	{
		uint n = size - off > CLM_CHUNK ? CLM_CHUNK : size - off;
		if (off + n == size) { flag |= 0x0004; } // DL_END
		uint f = flag | (1u << 12);  // DLOAD_HANDLER_VER
		chunk[0] = (char)(f & 0xFF); chunk[1] = (char)(f >> 8);
		chunk[2] = 2; chunk[3] = 0;  // DL_TYPE_CLM
		put32(&chunk[4], n);
		put32(&chunk[8], 0);
		for (uint k = 0; k < n; k++) { chunk[12 + k] = clm[off + k]; }
		int st = bcdc_set_var(sdc, "clmload", &chunk[0], 12 + n);
		if (st != 0)
		{
			print("brcmd: clmload at "); print_uint(off); print(" -> status "); print_int(st);
			char[4] s;
			if (bcdc_get_var(sdc, "clmload_status", 4, &s[0], 4) == 0) { print(", clmload_status "); print_uint(get32(&s[0])); }
			print("\n");
			return;
		}
		flag &= ~0x0002u;
		off += n;
	}
	print("brcmd: CLM blob loaded ("); print_uint(size); print(" bytes)\n");
}

fn void event_mask_enable(Brcm_core* sdc)
{
	char[BRCMF_EVENT_MASK_LEN] mask;
	int st = bcdc_get_var(sdc, "event_msgs", BRCMF_EVENT_MASK_LEN, &mask[0], BRCMF_EVENT_MASK_LEN);
	if (st != 0) { print("brcmd: get event_msgs -> "); print_int(st); print("\n"); return; }
	uint[*] want = { BRCMF_E_IF, BRCMF_E_ESCAN_RESULT, BRCMF_E_SET_SSID, BRCMF_E_AUTH, BRCMF_E_ASSOC,
		BRCMF_E_DEAUTH, BRCMF_E_DEAUTH_IND, BRCMF_E_DISASSOC, BRCMF_E_DISASSOC_IND, BRCMF_E_LINK, BRCMF_E_PSK_SUP };
	foreach (e : want) { mask[e / 8] |= (char)(1u << (e % 8)); }
	st = bcdc_set_var(sdc, "event_msgs", &mask[0], BRCMF_EVENT_MASK_LEN);
	if (st != 0) { print("brcmd: set event_msgs -> "); print_int(st); print("\n"); }
}

fn int iovar_set_int(Brcm_core* sdc, char* name, uint v)
{
	char[4] b;
	put32(&b[0], v);
	return bcdc_set_var(sdc, name, &b[0], 4);
}

// escan: brcmf_escan_params_le v1 {version 1, action START, sync_id} +
// brcmf_scan_params_le (64 bytes, all defaults: any BSS type, broadcast
// BSSID, active, -1 times, all channels). Results arrive as events.
fn bool escan_start(Brcm_core* sdc)
{
	char[72] ep;
	for (int k = 0; k < 72; k++) { ep[k] = 0; }
	put32(&ep[0], 1);
	ep[4] = 1; ep[5] = 0;            // WL_ESCAN_ACTION_START
	ep[6] = 0x34; ep[7] = 0x12;      // sync id
	char* sp = &ep[8];
	for (int k = 0; k < 6; k++) { sp[36 + k] = (char)0xFF; }
	sp[42] = 2;                      // DOT11_BSSTYPE_ANY
	sp[43] = 0;                      // active
	put32(&sp[44], 0xFFFFFFFF); put32(&sp[48], 0xFFFFFFFF);
	put32(&sp[52], 0xFFFFFFFF); put32(&sp[56], 0xFFFFFFFF);
	put32(&sp[60], 0);
	g_nbss = 0;
	g_scan_done = false;
	int st = bcdc_set_var(sdc, "escan", &ep[0], 72);
	if (st != 0) { print("brcmd: escan -> status "); print_int(st); print("\n"); return false; }
	g_scanning = true;
	return true;
}

// Drain whatever the firmware has queued on F2 (events; data frames are W5).
fn void f2_drain(Brcm_core* sdc)
{
	for (int k = 0; k < 64; k++)
	{
		int len = 0;
		int r = f2_poll(sdc, 0x10000, &len); // no control request pending
		if (r == -2 || len == 0) { return; }
	}
}

fn uint hexv(char c)
{
	if (c >= '0' && c <= '9') { return (uint)(c - '0'); }
	if (c >= 'a' && c <= 'f') { return (uint)(c - 'a' + 10); }
	if (c >= 'A' && c <= 'F') { return (uint)(c - 'A' + 10); }
	return 0xFF;
}

fn void join_step(char* what, int st)
{
	if (st != 0) { print("brcmd: join: "); print(what); print(" -> status "); print_int(st); print("\n"); }
}

// Join `g_sta_ssid`: open when `pmk` is null, else WPA2-PSK/CCMP with the
// firmware supplicant and the 32-byte PMK (handed over as 64 hex digits,
// brcmf_wsec_pmk_le flags 0 — the wl tool's "PSK as hex" form).
fn bool sta_join(Brcm_core* sdc, char* pmk)
{
	if (g_sta != STA_IDLE) { bcdc_cmd(sdc, BRCMF_C_DISASSOC, true, 0, null, 0); g_sta = STA_IDLE; }
	g_sta_wpa = pmk != null;
	g_sta_reason = 0;
	join_step("infra", bcdc_set_int(sdc, BRCMF_C_SET_INFRA, 1));
	join_step("auth", bcdc_set_int(sdc, BRCMF_C_SET_AUTH, 0));                    // open system
	join_step("wsec", iovar_set_int(sdc, "wsec", g_sta_wpa ? 4 : 0));             // AES_ENABLED
	join_step("wpa_auth", iovar_set_int(sdc, "wpa_auth", g_sta_wpa ? 0x80 : 0));  // WPA2_AUTH_PSK
	join_step("sup_wpa", iovar_set_int(sdc, "sup_wpa", g_sta_wpa ? 1 : 0));
	// The association request's RSN element, as wpa_supplicant hands it to
	// brcmfmac's connect ("wpaie"): version 1, group CCMP, 1 pairwise
	// CCMP, 1 AKM PSK, capabilities 0. Empty for an open network.
	char[22] rsn = { 0x30, 20, 1, 0, 0x00, 0x0F, 0xAC, 4, 1, 0, 0x00, 0x0F, 0xAC, 4, 1, 0, 0x00, 0x0F, 0xAC, 2, 0, 0 };
	join_step("wpaie", bcdc_set_var(sdc, "wpaie", &rsn[0], g_sta_wpa ? 22 : 0));
	if (g_sta_wpa)
	{
		// brcmf_wsec_pmk_le {key_len, flags, key[]}: current brcmfmac hands
		// the PMK over as 32 raw bytes (brcmf_set_pmk); the wl tool's older
		// form is 64 hex digits. 7.45.96 refused the hex one with BADARG.
		int st = -1;
		for (int form = 0; form < 2 && st != 0; form++)
		{
			char* p = &g_txbuf[SDPCM_HDRLEN + BCDC_HDRLEN];
			for (int k = 0; k < 132; k++) { p[k] = 0; }
			if (form == 0)
			{
				p[0] = 32;
				for (int i = 0; i < 32; i++) { p[4 + i] = pmk[i]; }
			}
			else
			{
				p[0] = 64;
				char* hx = "0123456789abcdef";
				for (int i = 0; i < 32; i++) { p[4 + 2 * i] = hx[((uint)pmk[i] >> 4) & 0xF]; p[5 + 2 * i] = hx[(uint)pmk[i] & 0xF]; }
			}
			st = bcdc_cmd(sdc, BRCMF_C_SET_WSEC_PMK, true, 132, null, 0);
			print(form == 0 ? "brcmd: SET_WSEC_PMK (raw 32) -> status " : "brcmd: SET_WSEC_PMK (hex 64) -> status ");
			print_int(st); print("\n");
		}
		if (st != 0) { return false; }
	}
	char* s = &g_txbuf[SDPCM_HDRLEN + BCDC_HDRLEN];
	for (int k = 0; k < 36; k++) { s[k] = 0; }
	uint n = 0;
	while (g_sta_ssid[n] != 0 && n < 32) { s[4 + n] = g_sta_ssid[n]; n++; }
	put32(&s[0], n);
	g_sta = STA_JOINING;
	int st = bcdc_cmd(sdc, BRCMF_C_SET_SSID, true, 36, null, 0);
	if (st != 0) { g_sta = STA_IDLE; print("brcmd: SET_SSID -> status "); print_int(st); print("\n"); return false; }
	print("brcmd: wifi joining "); print(&g_sta_ssid[0]); print(g_sta_wpa ? " (wpa2)\n" : " (open)\n");
	return true;
}

// Boot-time join from /adm/wifi (`wifi save`): line 1 the SSID, line 2
// empty (open) or the PMK as 64 hex digits — the same file usbd reads.
fn void sta_autojoin(Brcm_core* sdc)
{
	char[160] f;
	int n = fs_read("/adm/wifi", &f[0], 159);
	if (n <= 0) { return; }
	int a = 0;
	while (a < n && f[a] != '\n' && f[a] != '\r') { a++; }
	if (a == 0 || a > 32) { return; }
	for (int k = 0; k < a; k++) { g_sta_ssid[k] = f[k]; }
	g_sta_ssid[a] = 0;
	while (a < n && (f[a] == '\n' || f[a] == '\r')) { a++; }
	int b = a;
	while (b < n && f[b] != '\n' && f[b] != '\r') { b++; }
	char[32] pmk;
	if (b - a == 64)
	{
		for (int i = 0; i < 32; i++)
		{
			uint hi = hexv(f[a + 2 * i]);
			uint lo = hexv(f[a + 2 * i + 1]);
			if (hi > 15 || lo > 15) { print("brcmd: /adm/wifi line 2 isn't a 64-hex PMK\n"); return; }
			pmk[i] = (char)(hi * 16 + lo);
		}
		print("brcmd: autojoin (/adm/wifi)\n");
		sta_join(sdc, &pmk[0]);
	}
	else if (b == a) { print("brcmd: autojoin (/adm/wifi)\n"); sta_join(sdc, null); }
	else { print("brcmd: /adm/wifi line 2 isn't a 64-hex PMK — store it with `wifi save SSID PASSPHRASE`\n"); }
}

fn bool control_hello(Brcm_core* sdc)
{
	if (!bus_init(sdc)) { return false; }
	char[512] ans;
	for (int k = 0; k < 512; k++) { ans[k] = 0; }
	int st = bcdc_get_var(sdc, "ver", 256, &ans[0], 511);
	if (st == 0)
	{
		print("brcmd: firmware says: ");
		print(&ans[0]);
		if (ans[0] != 0 && ans[255] == 0) { print("\n"); }
	}
	else if (st > 0) { print("brcmd: get_var ver -> status "); print_uint((uint)st); print("\n"); }
	char[16] mac;
	if (bcdc_get_var(sdc, "cur_etheraddr", 6, &mac[0], 6) == 0)
	{
		print("brcmd: MAC "); print_mac(&mac[0]); print("\n");
		// "ether1", like the Duo's USB Wi-Fi: ipd attaches it and runs DHCP once it's up
		g_link_ok = link_create(&g_link_ring, "ether1", &mac[0], 1500);
		if (g_link_ok) { g_link_ring.h.link_up = 0; } else { print("brcmd: can't create link ether1\n"); }
	}
	print("brcmd: W3a done\n");

	clm_load(sdc);
	event_mask_enable(sdc);
	// country IT (brcmf_fil_country_le: abbrev[4], rev -1, ccode[4])
	char[12] cc;
	for (int k = 0; k < 12; k++) { cc[k] = 0; }
	cc[0] = 'I'; cc[1] = 'T'; put32(&cc[4], 0xFFFFFFFF); cc[8] = 'I'; cc[9] = 'T';
	st = bcdc_set_var(sdc, "country", &cc[0], 12);
	if (st != 0) { print("brcmd: country IT -> status "); print_int(st); print("\n"); }
	st = bcdc_set_int(sdc, BRCMF_C_UP, 1);
	if (st != 0) { print("brcmd: WLC_UP -> status "); print_int(st); print("\n"); return false; }
	for (int k = 0; k < 12; k++) { cc[k] = 0; }
	if (bcdc_get_var(sdc, "country", 12, &cc[0], 12) == 0)
	{
		cc[3] = 0;
		print("brcmd: interface up, country "); print(&cc[0]); print("\n");
	}
	if (escan_start(sdc))
	{
		ulong start = rdtime();
		while (!g_scan_done && rdtime() - start < timebase_hz() * 15) { f2_drain(sdc); delay_ms(5); }
		char[4096] t;
		int n = scan_text(&t[0], 4095);
		t[n] = 0;
		print(&t[0]);
		print("brcmd: scan: "); print_uint((uint)g_nbss); print(" networks\n");
	}
	print("brcmd: W3b done\n");
	return true;
}

// --- IPC from /bin/wifi: the same verbs (and reply shape: [len u16][2]
// [text]) usbd answers for the Duo's USB adapter ---------------------------
const uint WIFI_IPC_SCAN   = 40;
const uint WIFI_IPC_LIST   = 41;
const uint WIFI_IPC_STATUS = 42;
const uint WIFI_IPC_JOIN   = 43;   // req: [ssid, NUL-padded to 33][have_pmk][pmk 32]
const uint WIFI_IPC_LEAVE  = 44;

char[4096] g_reply;
ulong g_rx_kicked;

fn void wifi_ipc(int from, uint verb, uint from_gen, char* req, bool up)
{
	char* r = &g_reply[0];
	int n = 0;
	if (!up) { n = cat(&r[4], n, "wifi: AP6256 not running (see dmesg)\n"); }
	else if (verb == WIFI_IPC_SCAN)
	{
		if (g_scanning) { n = cat(&r[4], n, "scanning\n"); }
		else { n = cat(&r[4], n, escan_start(g_sdc) ? "scanning\n" : "scan refused (see dmesg)\n"); }
	}
	else if (verb == WIFI_IPC_LIST) { n = scan_text(&r[4], 4000); }
	else if (verb == WIFI_IPC_JOIN)
	{
		int k = 0;
		for (; k < 32 && req[k] != 0; k++) { g_sta_ssid[k] = req[k]; }
		g_sta_ssid[k] = 0;
		bool ok = sta_join(g_sdc, req[33] != 0 ? &req[34] : null);
		n = cat(&r[4], n, ok ? "joining\n" : "can't join (see dmesg)\n");
	}
	else if (verb == WIFI_IPC_LEAVE)
	{
		bcdc_cmd(g_sdc, BRCMF_C_DISASSOC, true, 0, null, 0);
		g_sta = STA_IDLE;
		g_link = false;
		link_state(false);
		n = cat(&r[4], n, "left\n");
	}
	else
	{
		char*[4] names = { "idle", "joining", "handshaking", "associated" };
		n = cat(&r[4], n, g_scanning && g_sta == STA_IDLE ? "scanning" : names[g_sta]);
		if (g_sta != STA_IDLE) { n = cat(&r[4], n, " ssid "); n = cat(&r[4], n, &g_sta_ssid[0]); }
		if (g_sta == STA_UP) { n = cat(&r[4], n, g_sta_wpa ? " wpa2" : " open"); }
		n = cat(&r[4], n, " data rx/tx ");
		n += fmt::format_uint((uint)g_rx_data, &r[4 + n]);
		n = cat(&r[4], n, "/");
		n += fmt::format_uint((uint)g_tx_data, &r[4 + n]);
		if (g_rx_gloms != 0) { n = cat(&r[4], n, " gloms "); n += fmt::format_uint((uint)g_rx_gloms, &r[4 + n]); }
		if (g_sta_reason != 0) { n = cat(&r[4], n, " last reason "); n += fmt::format_uint(g_sta_reason, &r[4 + n]); }
		n = cat(&r[4], n, " (AP6256)\n");
	}
	r[0] = (char)(n & 0xFF); r[1] = (char)(n >> 8); r[2] = 0; r[3] = 0;
	ipc_reply(from, verb, r, 4 + n, from_gen);
}

fn bool sdio_enumerate()
{
	uint ocr = 0;
	uint rca = 0;
	if (!sdio_identify(&ocr, &rca))
	{
		print("brcmd: no SDIO card answered (still in reset?)\n");
		return false;
	}
	print("brcmd: SDIO card: ocr=0x"); print_hex32(ocr);
	print(" functions="); print_uint((ocr >> 28) & 7);
	print(" rca="); print_uint(rca); print("\n");
	uint rev = 0;
	sdio_cmd52(false, 0, 0x00, 0, &rev);
	uint vendor = 0;
	uint device = 0;
	if (sdio_read_manfid(&vendor, &device))
	{
		print("brcmd: CCCR rev 0x"); print_hex32(rev);
		print(", MANFID vendor 0x"); print_hex32(vendor); print(" device 0x"); print_hex32(device);
		print(vendor == 0x02D0 ? " (Broadcom)\n" : "\n");
	}
	return true;
}

fn void main()
{
	print("brcmd: AP6256 Wi-Fi — powering on (WL_REG_ON = GPIO 62)\n");
	jh7110_gpio_out(WL_REG_ON, false);
	delay_ms(20);
	jh7110_gpio_out(WL_REG_ON, true);
	delay_ms(250); // the chip's own power-up before SDIO answers

	bool up = false;
	srv_post("brcmd");   // /bin/wifi: ns_mount("/srv/brcmd/", "brcmd")
	jh7110_sdio0_pads();
	g_dw_base = SDIO0_BASE;
	g_dw_timebase_hz = timebase_hz();
	if (!dw_mshc_init_ctrl())
	{
		print("brcmd: sdio0 controller init failed\n");
	}
	else if (sdio_enumerate())
	{
		print("brcmd: W1 done\n");
		if (sdio_setup() && chip_identify())
		{
			print("brcmd: W2a/b done\n");
			if (erom_scan())
			{
				print("brcmd: W2c done\n");
				try_fast_bus();
				if (firmware_start())
				{
					print("brcmd: W2d done\n");
					g_sdc = core_by_id(CORE_SDIO_DEV);
					up = control_hello(g_sdc);
					if (up) { sta_autojoin(g_sdc); }
				}
			}
		}
	}

	// Serve /bin/wifi; between requests, poll the firmware for events
	// (20 Hz — there's no interrupt yet: the OOB line is GPIO21, W5).
	for (;;)
	{
		int ready = await_any(AW_MSG | AW_WAKE, timebase_hz() / 20, null, 0);
		if (ready > 0 && ((uint)ready & AW_MSG) != 0)
		{
			char[516] buf @noinit;
			uint verb = 0;
			uint from_gen = 0;
			int from = ipc_recv_type_gen(&buf, 516, &verb, &from_gen);
			if (from > 0) { wifi_ipc(from, verb, from_gen, &buf[0], up); }
		}
		if (up) { f2_drain(g_sdc); data_output(); f2_drain(g_sdc); }
		if (up && g_link_ok && g_rx_data != g_rx_kicked) { g_rx_kicked = g_rx_data; link_kick(&g_link_ring); }
	}
}
