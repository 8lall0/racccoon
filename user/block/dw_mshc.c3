module user;

// dw_mshc: the Synopsys DesignWare Mobile Storage Host Controller
// register/PIO layer for the Orange Pi RV (StarFive JH7110) — the "how"
// layer for user/block/sdd.c3's orchestration, exactly the role
// user/block/sdhci.c3 plays for the Milk-V Duo. The two are mutually
// exclusive: a given `sdd` binary is built from sdd.c3 + *one* of these.
//
// STATUS: DRAFT, NEVER RUN ON HARDWARE. The real board is Stage-1
// blocked (docs/opi-rv-plan.md) and there is no QEMU model of the JH7110
// SD controller, so nothing below is verified. It is written against
// real driver source (see "Sourcing" below) and is meant to be
// reviewable now and brought up once the board is unblocked. the
// board's "sd" DEVICES entry doesn't exist until then; this file is not yet wired into
// any build (see "Build integration").
//
// ---------------------------------------------------------------------
// Sourcing
// ---------------------------------------------------------------------
// Register offsets + bit fields: U-Boot `include/dwmmc.h` +
//   `drivers/mmc/dw_mmc.c` (the generic DesignWare core — same IP used
//   by Rockchip / Allwinner / Exynos / Hi3798, very well trodden).
// JH7110 glue: Linux `drivers/mmc/host/dw_mmc-starfive.c` and the
//   mainline devicetree `arch/riscv/boot/dts/starfive/jh7110.dtsi`
//   `mmc@16020000` (mmc1 / sdio1) node — THE MICROSD SLOT on the Orange Pi RV
//   (mmc0 @ 0x16010000 is the AP6256 Wi-Fi's SDIO; corrected 2026-09-19 from
//   the U-Boot boot log + the board devicetree, this draft originally
//   targeted mmc0):
//     reg          = <0x16020000 0x10000>
//     interrupts   = <75>                       (PLIC source -> the "sd" entry's irq)
//     fifo-depth   = <32>
//     fifo-watermark-aligned;
//     clocks       = SDIO1_AHB ("biu"), SDIO1_SDCARD ("ciu")
//     resets       = SDIO1_AHB ("reset")
//     starfive,sysreg = <&sys_syscon 0x9c 0x1 0x3e>
//                        (sample-phase field: syscon off 0x9c, shift 1,
//                         mask 0x3e)
// The SD Physical Layer command sequence in dw_enumerate() is
// controller-agnostic and copied verb-for-verb from sdhci.c3's
// sdd_enumerate() — only dw_send_cmd() differs from its SDHCI sibling.
//
// ---------------------------------------------------------------------
// What is NOT done yet (the bring-up TODO list)
// ---------------------------------------------------------------------
//  1. IDMAC / DMA. PIO only here (like sdhci.c3's fallback path). DMA on
//     this IP is the internal DMA controller (IDMAC) with a physically-
//     contiguous descriptor list — needs the uncached SYS_DEV_INFO page
//     (see sdd.c3) plus a descriptor ring. Follow-up once PIO reads work.
//  2. Clock/reset controller (JH7110 syscrg @ 0x13020000). The first cut
//     ASSUMES U-Boot already left the SDIO0 biu+ciu clocks ungated and
//     out of reset — it has to, it loads the kernel off this same card
//     (same reasoning sdhci.c3 uses for not re-clocking the Duo's IP the
//     BootROM already set up). dw_mshc_soc_init() is a near-no-op on that
//     assumption; if it's wrong, the syscrg SDIO0 gate/deassert bits are
//     the thing to add, and DW_CIU_HZ below is the parent rate to pin.
//  3. Card-detect (CDETECT @ 0x50) — ignored; the slot is assumed
//     populated, same as sdhci.c3.
//  4. Bus width > 1-bit, high-speed (CMD6), tuning. 1-bit / SD
//     default-speed (~25 MHz) only, same conservative target as sdhci.c3.
//  5. VERID-dependent FIFO offset. StarFive VERID is >= 0x240A so the
//     data port is at 0x200 (DWMCI_DATA), asserted at init — see
//     dw_reg_verid_check().
//
// ---------------------------------------------------------------------
// Build integration (when ready)
// ---------------------------------------------------------------------
// scripts/build_user.sh builds `sdd` from `sdhci.c3 + sdd.c3`. To ship
// this instead on the opi targets, have scripts/build_opi.sh and
// scripts/build_opi_qemu.sh rebuild `sdd` from `dw_mshc.c3 + sdd.c3`
// before the link step (a 1-line build_user_program override), and add an
// "sd" entry to board::DEVICES in boards/opi-rv/board.c3 (MMIO page,
// IRQ 75, DMA region — sdio1 @ 0x16020000 is the SD slot, see docs/opi-rv-plan.md). sdd.c3 itself needs no
// change — it only calls the four names this file also exports
// (dw-prefixed here vs sd-prefixed in sdhci.c3; see the shim aliases at
// the bottom).

const bool DWMSHC_VERBOSE = false; // per-sector trace; on it prints 2 lines/read and floods dmesg's 32K ring

// Failure reporting is rate-limited: a marginal PIO read is retried by fsd,
// so it must not turn every read into console output. First few are printed
// in full, then a summary every DW_STATS_EVERY transfers.
const uint DW_FAIL_PRINT_MAX = 8;
const uint DW_STATS_EVERY    = 512;
uint g_dw_xfers = 0;
uint g_dw_fails = 0;

const uint SECTOR_SIZE = 512; // shared with sdd.c3's wire-protocol layout

// --- DW-MSHC register block (relative to DW_BASE). Verbatim from U-Boot
// include/dwmmc.h. Every register is 32-bit, little-endian MMIO.
const uint DWMCI_CTRL     = 0x000;
const uint DWMCI_PWREN    = 0x004;
const uint DWMCI_CLKDIV   = 0x008;
const uint DWMCI_CLKSRC   = 0x00C;
const uint DWMCI_CLKENA   = 0x010;
const uint DWMCI_TMOUT    = 0x014;
const uint DWMCI_CTYPE    = 0x018;
const uint DWMCI_BLKSIZ   = 0x01C;
const uint DWMCI_BYTCNT   = 0x020;
const uint DWMCI_INTMASK  = 0x024;
const uint DWMCI_CMDARG   = 0x028;
const uint DWMCI_CMD      = 0x02C;
const uint DWMCI_RESP0    = 0x030;
const uint DWMCI_RESP1    = 0x034;
const uint DWMCI_RESP2    = 0x038;
const uint DWMCI_RESP3    = 0x03C;
const uint DWMCI_MINTSTS  = 0x040;
const uint DWMCI_RINTSTS  = 0x044;
const uint DWMCI_STATUS   = 0x048;
const uint DWMCI_FIFOTH   = 0x04C;
const uint DWMCI_CDETECT  = 0x050;
const uint DWMCI_WRTPRT   = 0x054;
const uint DWMCI_TCMCNT   = 0x05C;
const uint DWMCI_TBBCNT   = 0x060;
const uint DWMCI_DEBNCE   = 0x064;
const uint DWMCI_USRID    = 0x068;
const uint DWMCI_VERID    = 0x06C;
const uint DWMCI_HCON     = 0x070;
const uint DWMCI_UHS_REG  = 0x074;
const uint DWMCI_BMOD     = 0x080;
const uint DWMCI_PLDMND   = 0x084;
// Data FIFO. 0x200 for VERID >= 0x240A (StarFive is 0x5342270A); 0x100
// on older cores. dw_reg_verid_check() asserts the assumption at init.
const uint DWMCI_DATA     = 0x200;

// CTRL (0x00)
const uint DWMCI_CTRL_RESET      = 1u << 0;
const uint DWMCI_CTRL_FIFO_RESET = 1u << 1;
const uint DWMCI_CTRL_DMA_RESET  = 1u << 2;
const uint DWMCI_CTRL_INT_ENABLE = 1u << 4;
const uint DWMCI_CTRL_DMA_EN     = 1u << 5;
const uint DWMCI_CTRL_USE_IDMAC  = 1u << 25;
const uint DWMCI_RESET_ALL       = DWMCI_CTRL_RESET | DWMCI_CTRL_FIFO_RESET | DWMCI_CTRL_DMA_RESET;

// CMD (0x2C)
const uint DWMCI_CMD_RESP_EXP     = 1u << 6;  // expect a response
const uint DWMCI_CMD_RESP_LENGTH  = 1u << 7;  // long (136-bit) response
const uint DWMCI_CMD_CHECK_CRC    = 1u << 8;
const uint DWMCI_CMD_DATA_EXP     = 1u << 9;  // data transfer follows
const uint DWMCI_CMD_RW           = 1u << 10; // 1 = write (host -> card)
const uint DWMCI_CMD_SEND_STOP    = 1u << 12; // auto CMD12 after the data block
const uint DWMCI_CMD_PRV_DAT_WAIT = 1u << 13; // wait for the card to be non-busy first
const uint DWMCI_CMD_UPD_CLK      = 1u << 21; // "update clock registers only" — no command issued
const uint DWMCI_CMD_USE_HOLD_REG = 1u << 29;
const uint DWMCI_CMD_START        = 1u << 31; // hand the command to the CIU

// RINTSTS / MINTSTS / INTMASK (write-1-to-clear on RINTSTS)
const uint DWMCI_INT_RE    = 1u << 1;  // response error
const uint DWMCI_INT_CDONE  = 1u << 2;  // command done
const uint DWMCI_INT_DTO    = 1u << 3;  // data transfer over
const uint DWMCI_INT_TXDR   = 1u << 4;  // TX FIFO data request
const uint DWMCI_INT_RXDR   = 1u << 5;  // RX FIFO data request
const uint DWMCI_INT_RCRC   = 1u << 6;  // response CRC error
const uint DWMCI_INT_DCRC   = 1u << 7;  // data CRC error
const uint DWMCI_INT_RTO    = 1u << 8;  // response timeout
const uint DWMCI_INT_DRTO   = 1u << 9;  // data read timeout
const uint DWMCI_INT_HTO    = 1u << 10; // data starvation-by-host timeout
const uint DWMCI_INT_FRUN   = 1u << 11; // FIFO under/overrun
const uint DWMCI_INT_HLE    = 1u << 12; // hardware locked write error (bad clock-update)
const uint DWMCI_INT_SBE    = 1u << 13; // start-bit error
const uint DWMCI_INT_ACD    = 1u << 14; // auto command done
const uint DWMCI_INT_EBE    = 1u << 15; // end-bit error
const uint DWMCI_INT_ALL    = 0xFFFFFFFF;

const uint DWMCI_DATA_ERR   = DWMCI_INT_DCRC | DWMCI_INT_DRTO | DWMCI_INT_SBE | DWMCI_INT_EBE | DWMCI_INT_FRUN | DWMCI_INT_HLE;

// STATUS (0x48)
const uint DWMCI_STATUS_FIFO_EMPTY = 1u << 2;
const uint DWMCI_STATUS_FIFO_FULL  = 1u << 3;
const uint DWMCI_STATUS_BUSY       = 1u << 9;  // data-busy (card holding DAT0 low)
const uint DWMCI_STATUS_FIFO_SHIFT = 17;      // FIFO_COUNT is bits [29:17]
const uint DWMCI_STATUS_FIFO_MASK  = 0x1FFF;

// CLKENA (0x10)
const uint DWMCI_CLKEN_ENABLE  = 1u << 0;
const uint DWMCI_CLKEN_LOW_PWR = 1u << 16;

// CTYPE (0x18)
const uint DWMCI_CTYPE_1BIT = 0;
const uint DWMCI_CTYPE_4BIT = 1u << 0;

// FIFOTH (0x4C): [30:28] MSIZE (DW-DMA burst = 8 -> 2), [27:16] RX watermark,
// [11:0] TX watermark. fifo-depth is 32 (HCON-reported / DT), so a
// half-full mark of 16 (RX) / (depth - rx - 1) style TX per U-Boot's
// dw_mmc.c dwmci_setup_bus(): MSIZE=2, RX_WMARK = fifo_depth/2 - 1,
// TX_WMARK = fifo_depth/2.
const uint DW_FIFO_DEPTH     = 32;
const uint DW_FIFOTH_MSIZE   = 2;
fn uint dw_fifoth_value()
{
	uint rx_wmark = DW_FIFO_DEPTH / 2 - 1;
	uint tx_wmark = DW_FIFO_DEPTH / 2;
	return (DW_FIFOTH_MSIZE << 28) | (rx_wmark << 16) | tx_wmark;
}

// --- Clock plan. The CIU (card unit) clock parent is JH7110's
// SDIO0_SDCARD. Its exact rate is not in the devicetree; VisionFive 2's
// U-Boot leaves it at 50 MHz for SD default-speed, which is the working
// assumption here. dw_mshc CLKDIV divides the parent by (2*n) for n != 0,
// or by 1 for n == 0. So:
//   enum (~400 kHz): n = ceil(50e6 / (2 * 400e3)) = 63  -> ~397 kHz
//   run  (~25 MHz) : n = 1                              -> 25 MHz
// If bring-up shows the parent is not 50 MHz, this is the one number to
// fix (and possibly add a syscrg clk_set_rate in dw_mshc_soc_init).
const uint DW_CIU_HZ       = 50000000;
const uint DW_CLKDIV_ENUM  = 63;
const uint DW_CLKDIV_RUN   = 1;

// --- Real, wall-clock-bounded wait budgets, same approach as sdhci.c3
// (rdtime() from user mode). TIMEBASE differs per board; the sdd binary
// learns it via timebase_hz() rather than hardcoding, unlike sdhci.c3's
// frozen SD_TIMEBASE_HZ (that predates timebase_hz()).
ulong g_dw_timebase_hz = 4000000; // overwritten by dw_mshc_soc_init()

fn ulong dw_us_to_ticks(ulong us) { return us * g_dw_timebase_hz / 1000000; }

const ulong DW_CMD_DONE_US    = 500000;   // command-done poll budget
const ulong DW_CLK_UPDATE_US  = 100000;   // "update clock only" command self-clear
const ulong DW_RESET_US       = 200000;   // CTRL reset self-clear
const ulong DW_DATA_US        = 2000000;  // whole-block data phase (ready + DTO)
const ulong DW_BUSY_US        = 1000000;  // post-write DAT0-busy release

// --- MMIO helpers. board:: is kernel-only; the base is duplicated here
// as a plain const with its devicetree sourcing, same convention as
// sdhci.c3's SD_BASE and diskd.c3's VIRTIO_BLK_PADDR.
const uptr DW_BASE       = 0x16020000; // jh7110.dtsi mmc@16020000 (mmc1 / sdio1 — the microSD slot)
const uptr DW_SYSCON_BASE = 0x13030000; // starfive,jh7110-sys-syscon
const uint DW_SYSCON_PHASE_OFF   = 0x9C;       // starfive,sysreg arg 0 (mmc1; mmc0 would be 0x14)
const uint DW_SYSCON_PHASE_MASK  = 0x3E;       // starfive,sysreg arg 2 (mmc1; mmc0: 0x7C000000)
const uint DW_SYSCON_PHASE_SHIFT = 1;          // starfive,sysreg arg 1 (mmc1; mmc0: 26)

fn uint dw_read(uint off)  { return mmio_read32((uptr)(DW_BASE + off)); }
fn void dw_write(uint off, uint v) { mmio_write32((uptr)(DW_BASE + off), v); }

// print_hex32 / print_uint / rdtime / mmio_* / timebase_hz : user/user.c3

uint dw_rca;              // relative card address from CMD3
bool dw_high_capacity;    // CCS bit from ACMD41's R3
uint dw_response0;
uint dw_response1;
uint dw_response2;
uint dw_response3;
uint dw_last_rintsts;

// "Update clock registers only": the DW-MSHC does not latch CLKDIV /
// CLKSRC / CLKENA on a plain write — you issue a dummy command with
// UPD_CLK|PRV_DAT_WAIT|START and arg 0, and wait for START to self-clear.
// HLE set afterwards means the update was rejected (command FSM busy).
fn bool dw_update_clock()
{
	dw_write(DWMCI_CMDARG, 0);
	dw_write(DWMCI_CMD, DWMCI_CMD_START | DWMCI_CMD_UPD_CLK | DWMCI_CMD_PRV_DAT_WAIT);

	ulong start = rdtime();
	ulong budget = dw_us_to_ticks(DW_CLK_UPDATE_US);
	while ((dw_read(DWMCI_CMD) & DWMCI_CMD_START) != 0)
	{
		if (rdtime() - start > budget) { return false; }
	}
	// HLE latches in RINTSTS; clear it and report.
	uint r = dw_read(DWMCI_RINTSTS);
	if ((r & DWMCI_INT_HLE) != 0)
	{
		dw_write(DWMCI_RINTSTS, DWMCI_INT_HLE);
		return false;
	}
	return true;
}

// Program the card clock to `clkdiv` (see the DW_CLKDIV_* constants).
// Standard DW-MSHC sequence: gate the clock off, update; set divider,
// update; enable (non-low-power), update.
fn bool dw_set_clock(uint clkdiv)
{
	dw_write(DWMCI_CLKENA, 0);
	dw_write(DWMCI_CLKSRC, 0);
	if (!dw_update_clock()) { return false; }

	dw_write(DWMCI_CLKDIV, clkdiv);
	if (!dw_update_clock()) { return false; }

	dw_write(DWMCI_CLKENA, DWMCI_CLKEN_ENABLE); // bit16 low-power OFF: keep the clock always running
	if (!dw_update_clock()) { return false; }
	return true;
}

// SoC-level bring-up. See TODO #2 in the header — the working assumption
// is that U-Boot already ungated the SDIO0 biu/ciu clocks and released
// the reset (it boots the kernel off this controller), so this only
// pins the timebase and parks the sample-phase field at 0 (fine for SD
// default-speed; tuning is only needed for HS200/UHS).
fn void dw_mshc_soc_init()
{
	g_dw_timebase_hz = timebase_hz();

	// Sample phase = 0 in the SYS_SYSCON field. regmap_update_bits
	// equivalent: read-modify-write the masked field.
	uptr phase_reg = DW_SYSCON_BASE + DW_SYSCON_PHASE_OFF;
	uint w = mmio_read32(phase_reg);
	w &= ~DW_SYSCON_PHASE_MASK;
	w |= (0u << DW_SYSCON_PHASE_SHIFT) & DW_SYSCON_PHASE_MASK;
	mmio_write32(phase_reg, w);
}

// One-time controller bring-up: full reset, power, FIFO threshold,
// timeouts, 1-bit bus, enumeration clock. Mirrors U-Boot dw_mmc.c's
// dwmci_init() + dwmci_setup_bus().
fn bool dw_reg_verid_check()
{
	uint verid = dw_read(DWMCI_VERID) & 0xFFFF;
	// >= 0x240A -> data FIFO at 0x200 (the DWMCI_DATA constant above).
	// A mismatch here means the FIFO offset assumption is wrong for this
	// silicon and every PIO transfer below would touch the wrong address.
	if (verid < 0x240A)
	{
		print("dw_mshc: VERID 0x");
		print_hex32(verid);
		print(" < 0x240A — data FIFO is at 0x100, not 0x200; fix DWMCI_DATA\n");
		return false;
	}
	return true;
}

fn bool dw_mshc_init_ctrl()
{
	if (!dw_reg_verid_check()) { return false; }

	// Full reset: controller + FIFO + DMA. Self-clears.
	dw_write(DWMCI_CTRL, DWMCI_RESET_ALL);
	ulong start = rdtime();
	ulong budget = dw_us_to_ticks(DW_RESET_US);
	while ((dw_read(DWMCI_CTRL) & DWMCI_RESET_ALL) != 0)
	{
		if (rdtime() - start > budget)
		{
			print("dw_mshc: CTRL reset stuck\n");
			return false;
		}
	}

	// Clear and mask all interrupts — this driver polls RINTSTS, like
	// sdhci.c3 and U-Boot's own dw_mmc.c. INT_ENABLE in CTRL stays off.
	dw_write(DWMCI_RINTSTS, DWMCI_INT_ALL);
	dw_write(DWMCI_INTMASK, 0);
	dw_write(DWMCI_TMOUT, 0xFFFFFFFF); // max response + data timeout
	dw_write(DWMCI_FIFOTH, dw_fifoth_value());
	dw_write(DWMCI_BMOD, 0); // no IDMAC (PIO)
	dw_write(DWMCI_CTRL, 0); // DMA off, ints off

	dw_write(DWMCI_PWREN, 1); // power the card slot

	dw_write(DWMCI_CTYPE, DWMCI_CTYPE_1BIT);
	dw_write(DWMCI_BLKSIZ, SECTOR_SIZE);

	if (!dw_set_clock(DW_CLKDIV_ENUM))
	{
		print("dw_mshc: enum clock setup failed\n");
		return false;
	}
	return true;
}

// Issue one command and poll RINTSTS for command-done. `resp_flags` is
// the DWMCI_CMD_RESP_* subset the caller wants; `data`/`is_write` mark a
// data-bearing command. Response -> dw_response0..3. Same contract as
// sdhci.c3's sd_send_cmd(): false on timeout/error, caller decides
// fatality.
fn bool dw_send_cmd(uint index, uint arg, uint resp_flags, bool data, bool is_write)
{
	// Wait for the command FSM to be free (STATUS busy = data line held).
	// Not strictly required with PRV_DAT_WAIT below, but keeps a wedged
	// prior transfer from silently swallowing this command.
	ulong bstart = rdtime();
	ulong bbudget = dw_us_to_ticks(DW_BUSY_US);
	while ((dw_read(DWMCI_STATUS) & DWMCI_STATUS_BUSY) != 0)
	{
		if (rdtime() - bstart > bbudget) { break; }
	}

	dw_write(DWMCI_RINTSTS, DWMCI_INT_ALL); // clear stale status

	if (data)
	{
		dw_write(DWMCI_BLKSIZ, SECTOR_SIZE);
		dw_write(DWMCI_BYTCNT, SECTOR_SIZE);
		// FIFO reset between transfers — recommended by the databook so a
		// partially-drained FIFO from a failed prior transfer can't leak in.
		uint c = dw_read(DWMCI_CTRL);
		dw_write(DWMCI_CTRL, c | DWMCI_CTRL_FIFO_RESET);
		ulong fstart = rdtime();
		while ((dw_read(DWMCI_CTRL) & DWMCI_CTRL_FIFO_RESET) != 0)
		{
			if (rdtime() - fstart > dw_us_to_ticks(DW_RESET_US)) { break; }
		}
	}

	dw_write(DWMCI_CMDARG, arg);

	uint cmd = DWMCI_CMD_START | DWMCI_CMD_USE_HOLD_REG | DWMCI_CMD_PRV_DAT_WAIT
	         | (index & 0x3F);
	cmd |= resp_flags;
	if (data)
	{
		cmd |= DWMCI_CMD_DATA_EXP;
		if (is_write) { cmd |= DWMCI_CMD_RW; }
	}
	// CMD0 needs "send initialization sequence" (bit 15) — the 80-clock
	// warm-up. U-Boot sets it for the very first CMD0 only; harmless to
	// set every CMD0.
	if (index == 0) { cmd |= (1u << 15); }

	dw_write(DWMCI_CMD, cmd);

	ulong start = rdtime();
	ulong budget = dw_us_to_ticks(DW_CMD_DONE_US);
	uint r = 0;
	for (;;)
	{
		r = dw_read(DWMCI_RINTSTS);
		if ((r & DWMCI_INT_CDONE) != 0) { break; }
		if ((r & (DWMCI_INT_RTO | DWMCI_INT_RE)) != 0) { break; }
		if (rdtime() - start > budget) { break; }
	}
	dw_last_rintsts = r;

	// Clear the command-status bits we consumed (leave data bits for the
	// data path). RTO/RE/RCRC are errors.
	dw_write(DWMCI_RINTSTS, DWMCI_INT_CDONE | DWMCI_INT_RTO | DWMCI_INT_RE | DWMCI_INT_RCRC);

	if ((r & DWMCI_INT_CDONE) == 0) { return false; }
	if ((r & (DWMCI_INT_RTO | DWMCI_INT_RE)) != 0) { return false; }
	if ((resp_flags & DWMCI_CMD_CHECK_CRC) != 0 && (r & DWMCI_INT_RCRC) != 0) { return false; }

	// Long response: RESP0..3 hold the 128-bit CID/CSD (RESP3 = MSB).
	// Short response: RESP0 only.
	dw_response0 = dw_read(DWMCI_RESP0);
	dw_response1 = dw_read(DWMCI_RESP1);
	dw_response2 = dw_read(DWMCI_RESP2);
	dw_response3 = dw_read(DWMCI_RESP3);
	return true;
}

// Response-flag shorthands mapping the SDHCI-style names used at the call
// sites in dw_enumerate() onto DW-MSHC's CMD bits.
const uint DW_R_NONE  = 0;
const uint DW_R_SHORT = DWMCI_CMD_RESP_EXP;
const uint DW_R_LONG  = DWMCI_CMD_RESP_EXP | DWMCI_CMD_RESP_LENGTH;
const uint DW_R_CRC   = DWMCI_CMD_CHECK_CRC;

// Standard SD Physical Layer enumeration — identical command order to
// sdhci.c3's sdd_enumerate() (CMD0 / CMD8 / ACMD41 / CMD2 / CMD3 / CMD9 /
// CMD7 / CMD16). Per-stage prints kept for the same reason sdhci.c3
// keeps them: on a silent stall there is no other way to see how far it
// got.
fn bool dw_enumerate()
{
	bool cmd0 = dw_send_cmd(0, 0, DW_R_NONE, false, false);
	print("dw_mshc: CMD0 ");
	print(cmd0 ? "ok\n" : "TIMED OUT\n");

	bool cmd8 = dw_send_cmd(8, 0x1AA, DW_R_SHORT | DW_R_CRC, false, false);
	print("dw_mshc: CMD8 ");
	print(cmd8 ? "responded: " : "no response: ");
	print_hex32(dw_response0);
	print("\n");

	bool ready = false;
	int tries;
	for (tries = 0; tries < 200 && !ready; tries++)
	{
		if (tries > 0 && tries % 20 == 0) { putchar('.'); }
		if (!dw_send_cmd(55, 0, DW_R_SHORT | DW_R_CRC, false, false)) { continue; }
		if (!dw_send_cmd(41, 0x40FF8000, DW_R_SHORT, false, false)) { continue; }
		if ((dw_response0 & 0x80000000) != 0)
		{
			ready = true;
			dw_high_capacity = (dw_response0 & 0x40000000) != 0;
		}
	}
	print("\ndw_mshc: ACMD41 ");
	print(ready ? "ready, ocr=" : "gave up, ocr=");
	print_hex32(dw_response0);
	print("\n");
	if (!ready) { return false; }

	if (!dw_send_cmd(2, 0, DW_R_LONG | DW_R_CRC, false, false)) { return false; }
	print("dw_mshc: CMD2 (CID) ok\n");

	if (!dw_send_cmd(3, 0, DW_R_SHORT | DW_R_CRC, false, false)) { return false; }
	dw_rca = dw_response0 & 0xFFFF0000;
	print("dw_mshc: CMD3 rca=");
	print_hex32(dw_rca);
	print("\n");

	dw_send_cmd(9, dw_rca, DW_R_LONG | DW_R_CRC, false, false); // CSD, informational

	if (!dw_send_cmd(7, dw_rca, DW_R_SHORT | DW_R_CRC, false, false)) { return false; }
	print("dw_mshc: CMD7 (SELECT) ok\n");

	if (!dw_set_clock(DW_CLKDIV_RUN))
	{
		print("dw_mshc: run clock setup failed\n");
		return false;
	}
	print("dw_mshc: raised clock to run speed\n");

	dw_send_cmd(16, SECTOR_SIZE, DW_R_SHORT | DW_R_CRC, false, false); // SET_BLOCKLEN

	return true;
}

// How many 32-bit words are currently in the FIFO (STATUS[29:17]).
fn uint dw_fifo_count()
{
	return (dw_read(DWMCI_STATUS) >> DWMCI_STATUS_FIFO_SHIFT) & DWMCI_STATUS_FIFO_MASK;
}

// PIO single-block transfer: CMD17 (read) / CMD24 (write) with DATA_EXP,
// then drain/fill the FIFO through DWMCI_DATA while polling RINTSTS, then
// wait for DTO. `data` is exactly SECTOR_SIZE bytes, positioned by the
// caller. Mirrors U-Boot dw_mmc.c's dwmci_read_data_pio /
// dwmci_write_data_pio.
//
// No DMA, no interrupts (see header TODO #1). The DW-MSHC FIFO is 32
// words deep (fifo-depth), enough that a straightforward count-driven
// drain keeps up with SD default-speed without the shallow-FIFO timing
// hazard sdhci.c3's PIO path fights — but do NOT print() inside the
// drain loop regardless (same discipline as sdhci.c3).
fn bool dw_block_rw_once(char* data, uint sector, bool is_write)
{
	uint* words = (uint*)data;

	uint arg = dw_high_capacity ? sector : (sector * SECTOR_SIZE);
	uint cmd_index = is_write ? 24 : 17;

	if (!dw_send_cmd(cmd_index, arg, DW_R_SHORT | DW_R_CRC, true, is_write))
	{
		print("dw_mshc: CMD");
		print_hex32(cmd_index);
		print(" TIMED OUT rintsts=");
		print_hex32(dw_last_rintsts);
		print("\n");
		return false;
	}

	ulong start = rdtime();
	ulong budget = dw_us_to_ticks(DW_DATA_US);
	uint got = 0; // words transferred
	uint r = 0;

	for (;;)
	{
		r = dw_read(DWMCI_RINTSTS);
		if ((r & DWMCI_DATA_ERR) != 0) { break; }

		if (is_write)
		{
			// Count-driven burst fill: ask the FIFO once how much room is
			// left, then push that many words back to back — no STATUS poll
			// per word (register accesses on this SoC are slow; a poll per
			// word underruns the FIFO against a 25 MHz card).
			uint want = SECTOR_SIZE / 4 - got;
			uint room = DW_FIFO_DEPTH - dw_fifo_count();
			uint n = room < want ? room : want;
			for (uint i = 0; i < n; i++) { dw_write(DWMCI_DATA, words[got + i]); }
			got += n;
		}
		else
		{
			// Count-driven BURST drain. The old loop did ~4 register accesses
			// (RINTSTS read, STATUS read, RXDR clear, ...) per 1-2 words, i.e.
			// slower than the card fills the 32-word FIFO -> FRUN
			// (rintsts bit 11) on ~1 read in 3. Instead wait until at least
			// half a FIFO (16 words) is waiting — or everything that's left —
			// then read that many words with nothing but DATA reads between
			// them, which drains faster than the card refills.
			uint want = SECTOR_SIZE / 4 - got;
			uint avail = dw_fifo_count();
			uint thresh = want < 16 ? want : 16;
			if (avail >= thresh)
			{
				uint n = avail < want ? avail : want;
				for (uint i = 0; i < n; i++) { words[got + i] = dw_read(DWMCI_DATA); }
				got += n;
			}
		}

		if ((r & DWMCI_INT_DTO) != 0 && got == SECTOR_SIZE / 4) { break; }
		if ((r & DWMCI_INT_DTO) != 0 && is_write) { break; }

		if (rdtime() - start > budget) { break; }
	}

	// Consume the data-phase status.
	dw_write(DWMCI_RINTSTS, DWMCI_INT_DTO | DWMCI_INT_RXDR | DWMCI_INT_TXDR | DWMCI_DATA_ERR);

	bool ok = got == SECTOR_SIZE / 4 && (r & DWMCI_INT_DTO) != 0 && (r & DWMCI_DATA_ERR) == 0;

	if (ok && is_write)
	{
		// Wait out DAT0-busy (card programming) before returning, so the
		// next command's PRV_DAT_WAIT doesn't stall on it.
		ulong wstart = rdtime();
		ulong wbudget = dw_us_to_ticks(DW_BUSY_US);
		while ((dw_read(DWMCI_STATUS) & DWMCI_STATUS_BUSY) != 0)
		{
			if (rdtime() - wstart > wbudget) { break; }
		}
	}

	g_dw_xfers++;
	if (!ok)
	{
		g_dw_fails++;
		if (g_dw_fails <= DW_FAIL_PRINT_MAX)
		{
			print("dw_mshc: ");
			print(is_write ? "write" : "read");
			print(" sector ");
			print_hex32(sector);
			print(" FAILED got=");
			print_uint(got);
			print(" rintsts=");
			print_hex32(r);
			print("\n");
		}
	}
	if (g_dw_xfers % DW_STATS_EVERY == 0)
	{
		print("dw_mshc: ");
		print_uint(g_dw_fails);
		print(" failed / ");
		print_uint(g_dw_xfers);
		print(" transfers\n");
	}
	if (ok && DWMSHC_VERBOSE)
	{
		uint us = (uint)((rdtime() - start) * 1000000 / g_dw_timebase_hz);
		print("dw_mshc: ");
		print(is_write ? "wrote" : "read");
		print(" sector ");
		print_hex32(sector);
		print(" in ");
		print_uint(us);
		print("us\n");
	}
	return ok;
}

// A data-phase error (FRUN — FIFO under/overrun — in practice) is transient on
// this controller: on the real board the first second or so after enumeration
// saw ~1 read in 3 fail, then thousands in a row succeeded. Retrying the
// single block is safe (a read is idempotent; a write rewrites the same
// sector), but only after resetting the FIFO and the sticky RINTSTS bits, or
// the leftovers poison the next attempt. Without this, fsd's first probe
// reads failed and it declared "no recognized filesystem" and had to retry
// its whole mount. Failures are still counted/reported by the once() version.
const uint DW_RW_ATTEMPTS = 4;

fn bool dw_block_rw(char* data, uint sector, bool is_write)
{
	for (uint attempt = 0; attempt < DW_RW_ATTEMPTS; attempt++)
	{
		if (dw_block_rw_once(data, sector, is_write)) { return true; }

		// Reset the FIFO (self-clearing) and clear every pending status bit.
		dw_write(DWMCI_CTRL, dw_read(DWMCI_CTRL) | DWMCI_CTRL_FIFO_RESET);
		ulong start = rdtime();
		ulong budget = dw_us_to_ticks(DW_RESET_US);
		while ((dw_read(DWMCI_CTRL) & DWMCI_CTRL_FIFO_RESET) != 0)
		{
			if (rdtime() - start > budget) { break; }
		}
		dw_write(DWMCI_RINTSTS, DWMCI_INT_ALL);

		// Brief settle (~200us) before the next attempt.
		ulong t = rdtime();
		ulong settle = dw_us_to_ticks(200);
		while (rdtime() - t < settle) { }
	}
	return false;
}

// ---------------------------------------------------------------------
// Shim: the names user/block/sdd.c3 calls (sd-prefixed, from sdhci.c3).
// Keeping sdd.c3 board-agnostic — it only needs these four entry points
// and one register read. When this file is the one linked into `sdd`,
// these aliases make it a drop-in for sdhci.c3.
// ---------------------------------------------------------------------
fn void sdd_pad_power_clock_init()
{
	dw_mshc_soc_init();
	if (!dw_mshc_init_ctrl())
	{
		print("dw_mshc: controller init failed\n");
	}
}

fn bool sdd_enumerate() { return dw_enumerate(); }

fn bool sdd_block_rw(char* data, uint sector, bool is_write)
{
	return dw_block_rw(data, sector, is_write);
}

// sdd.c3 reads sd_reg_read(SD_CAPABILITIES) to decide the SDMA path.
// This driver is PIO-only for now, so report "no SDMA capability" —
// sdd_init() then keeps g_sdd_dma_ok false and never takes the DMA path.
const uint SD_CAPABILITIES = DWMCI_HCON;
const uint SD_CAP_SDMA     = 0; // never set -> PIO
fn uint sd_reg_read(uint offset) { return dw_read(offset); }

// The rest of the sdhci.c3 surface sdd.c3 expects at link time. DMA is
// TODO #1, so SDD_USE_DMA is false and the g_sdd_dma_* globals are inert
// stubs (sdd_init() sets them but sdd_block_rw() -> dw_block_rw() never
// reads them). SDD_VERBOSE maps onto this file's own DWMSHC_VERBOSE.
const bool SDD_VERBOSE = DWMSHC_VERBOSE;
const bool SDD_USE_DMA = false;
uptr g_sdd_dma_paddr = 0;
bool g_sdd_dma_ok = false;
