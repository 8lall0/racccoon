module user;

// sdd: the real-hardware SD storage driver for the Milk-V Duo, mutually
// exclusive with diskd (user/diskd.c3, QEMU's virtio-blk driver) — see
// board::HAS_SD_BLOCK/HAS_VIRTIO_BLOCK (kernel.c3) for how exactly one of
// the two ever gets spawned. Speaks the identical DISKD_READ/DISKD_WRITE
// wire protocol diskd does, so fsd.c3 (its only client) needs zero
// changes to work against either.
//
// Structural difference from diskd: PIO, not DMA. The SDHCI Buffer Data
// Port register is read/written one 32-bit word at a time directly into
// ordinary memory inside this process's own image — no virtqueue, no
// kernel-allocated physically-contiguous buffer, no SYS_DISKD_INFO-style
// syscall to learn a physical address (see setup_sdd_mappings, process.c3).
// Also no PLIC/interrupt involvement at all in this first version: SDHCI
// commands complete in microseconds to low milliseconds, so busy-polling
// PRESENT_STATE/INT_STATUS directly is simpler and sidesteps the
// sscratch-across-blocking-syscall hazard diskd's own interrupt wait had
// to solve (see user/diskd.c3's main loop comment) — nothing here ever
// blocks on an IRQ, so that hazard doesn't apply.
//
// Register offsets/bit layouts below are the standard SDHCI Host
// Controller Simplified Specification — the same layout Linux's
// include/linux/mmc/sdhci.h and U-Boot's include/sdhci.h both implement
// verbatim, not vendor-specific. The pad/power/clock bring-up sequence in
// sdd_init, and the base addresses it targets, ARE vendor-specific —
// sourced from duo-buildroot-sdk's own board/cvitek/cv180x/*.h and
// drivers/mmc/cvitek/sdhci-cv180x.c (see boards/duo/board.c3's SD_*
// constants and the plan file this was built from). Expect real-hardware
// iteration here (see docs/devlog.md) — this is a direct, careful port of
// sourced values, not something exercised against real silicon yet.

// --- Shared with the kernel / fsd — kept in sync by hand, same wire
// protocol as user/diskd.c3.
const uint DISKD_READ    = 10;
const uint DISKD_WRITE   = 11;
const uint DISKD_MSG_MAX = 516;
const uint SECTOR_SIZE   = 512;

// See sdd_block_rw's own comment — every logical sector fsd addresses
// gets shifted by this many sectors before touching the card, to stay
// entirely inside the unused gap between the MBR (sector 0) and the
// DUOBOOT FAT boot partition (starts at sector 2048 on the card this was
// bring-up-tested on).
const uint DATA_SECTOR_OFFSET = 64;

// --- SDHCI register block (relative to board::SD_MMIO_BASE). Each
// constant here is one 32-bit-aligned register; sub-word fields (8/16-bit
// per the spec) are accessed via shift/mask on the enclosing 32-bit word
// instead of narrower loads/stores — same reasoning user/diskd.c3's
// mmio_read32 comment gives for why this codebase avoids relying on
// anything but `lw`/`sw` in asm blocks.
const uint SD_BLKSIZE_BLKCNT   = 0x04; // [15:0]=block size, [31:16]=block count
const uint SD_ARGUMENT         = 0x08;
const uint SD_XFERMODE_CMD     = 0x0C; // [15:0]=transfer mode, [31:16]=command
const uint SD_RESPONSE0        = 0x10;
const uint SD_RESPONSE1        = 0x14;
const uint SD_RESPONSE2        = 0x18;
const uint SD_RESPONSE3        = 0x1C;
const uint SD_BUFFER           = 0x20;
const uint SD_PRESENT_STATE    = 0x24;
const uint SD_HOSTCTRL_PWRCTRL = 0x28; // byte0=host ctrl, byte1=power ctrl
const uint SD_CLOCK_SWRESET    = 0x2C; // [15:0]=clock ctrl, byte3=software reset
const uint SD_INT_STATUS       = 0x30;
const uint SD_INT_ENABLE       = 0x34;
const uint SD_SIGNAL_ENABLE    = 0x38;
const uint SD_ACMD12ERR_HOSTCTRL2 = 0x3C; // [15:0]=ACMD12 err status, [31:16]=Host Control 2

const uint SD_PRESENT_CMD_INHIBIT    = 0x00000001;
const uint SD_PRESENT_DATA_INHIBIT   = 0x00000002;
const uint SD_PRESENT_SPACE_AVAIL    = 0x00000400; // buffer write-ready
const uint SD_PRESENT_DATA_AVAIL     = 0x00000800; // buffer read-ready

const uint SD_INT_RESPONSE    = 0x00000001; // command complete
const uint SD_INT_DATA_END    = 0x00000002; // transfer complete
const uint SD_INT_SPACE_AVAIL = 0x00000010; // buffer write-ready — NOT
                                             // the same bit position as
                                             // SD_PRESENT_SPACE_AVAIL
                                             // above: same name, two
                                             // different registers
                                             // (PRESENT_STATE vs
                                             // INT_STATUS), confirmed
                                             // against the real header,
                                             // not assumed from the name.
const uint SD_INT_DATA_AVAIL  = 0x00000020; // buffer read-ready
const uint SD_INT_ERROR       = 0x00008000;
const uint SD_INT_ALL_MASK    = 0xFFFFFFFF; // write-1-to-clear, every bit

// Shared busy-wait bound for the per-command polling loops in sd_send_cmd
// (used inside the ACMD41 retry loop, so multiplied by both the retry
// count and two commands per retry — has to stay small enough that a
// genuinely non-responding card fails within a few seconds, not minutes).
const int SD_WAIT_MAX = 50000;

// Separate, much larger bound for the two ONE-TIME setup waits in
// sdd_pad_power_clock_init (software reset self-clear, internal clock
// stable) — each runs exactly once, so a generous bound here is cheap.
// This codebase has no timer/delay primitive at all (no rdtime access
// from user mode — scounteren.TM is never enabled — see the kernel-side
// TODO this raised), so every wait here is a raw iteration-count busy
// loop with genuinely unknown correspondence to wall-clock time. U-Boot's
// own generic sdhci_reset() (drivers/mmc/sdhci.c) waits up to 100ms of
// *real time* via udelay(1000) x100 for the exact same self-clearing
// reset bit — SD_WAIT_MAX (50000 raw loop iterations, no delay) may well
// be nowhere near 100ms of real time on this core, which would make a
// reset that's genuinely still completing look identical to one that
// never will. This is a blunt instrument to test that theory directly,
// not a considered choice — 400x SD_WAIT_MAX, only paid once each.
const int SD_SETUP_WAIT_MAX = SD_WAIT_MAX * 400;

const uint SD_CLOCK_INT_EN     = 0x0001;
const uint SD_CLOCK_INT_STABLE = 0x0002;
const uint SD_CLOCK_CARD_EN    = 0x0004;
const uint SD_SWRESET_ALL      = 0x01000000; // byte 3 of SD_CLOCK_SWRESET

const uint SD_POWER_330_ON = 0x0F00; // byte 1 of SD_HOSTCTRL_PWRCTRL:
                                      // POWER_330 (0x0E) | POWER_ON (0x01),
                                      // shifted to byte-1 position.

// Command register (upper 16 bits of SD_XFERMODE_CMD): index in bits
// [13:8] (so << 8 within the 16-bit half, i.e. << 24 within the word),
// response-type/data-present flags in the low byte of that half.
const uint SD_CMD_RESP_NONE       = 0x00;
const uint SD_CMD_RESP_LONG       = 0x01; // 136-bit (R2)
const uint SD_CMD_RESP_SHORT      = 0x02; // 48-bit (R1/R3/R6/R7)
const uint SD_CMD_RESP_SHORT_BUSY = 0x03; // 48-bit with busy (R1b)
const uint SD_CMD_CRC_CHECK       = 0x08;
const uint SD_CMD_INDEX_CHECK     = 0x10;
const uint SD_CMD_DATA_PRESENT    = 0x20;

// Transfer mode (lower 16 bits of SD_XFERMODE_CMD).
const uint SD_TRNS_BLK_CNT_EN = 0x0002;
const uint SD_TRNS_READ       = 0x0010; // 1 = card-to-host (read)

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

fn uint sd_reg_read(uint offset) { return mmio_read32((uptr)(SD_BASE + offset)); }
fn void sd_reg_write(uint offset, uint v) { mmio_write32((uptr)(SD_BASE + offset), v); }

fn uint top_reg_read(uint offset) { return mmio_read32((uptr)(TOP_BASE + offset)); }
fn void top_reg_write(uint offset, uint v) { mmio_write32((uptr)(TOP_BASE + offset), v); }

fn uint pinmux_reg_read(uint offset) { return mmio_read32((uptr)(PINMUX_BASE + offset)); }
fn void pinmux_reg_write(uint offset, uint v) { mmio_write32((uptr)(PINMUX_BASE + offset), v); }

fn uint clock_reg_read(uint offset) { return mmio_read32((uptr)(CLOCK_BASE + offset)); }
fn void clock_reg_write(uint offset, uint v) { mmio_write32((uptr)(CLOCK_BASE + offset), v); }

// Page bases — board::SD_MMIO_BASE/SD_TOP_PAGE/SD_PINMUX_PAGE/SD_CLOCK_PAGE
// aren't reachable from user-mode code (board is a kernel-only module),
// so the real values are duplicated here as plain constants, same
// convention user/diskd.c3 already follows for VIRTIO_BLK_PADDR — see
// this file's own header comment and boards/duo/board.c3 for where these
// come from.
const uint SD_BASE     = 0x04310000;
const uint TOP_BASE     = 0x03000000;
const uint PINMUX_BASE  = 0x03001000;
const uint CLOCK_BASE   = 0x03002000;

// TOP_BASE-relative.
const uint REG_TOP_SD_PWRSW_CTRL = 0x1F4;
const uint SD_PWRSW_ON_3V3 = 0x9;

// SD_BASE-relative, vendor-specific PHY registers — see
// sdd_pad_power_clock_init's PHY reset comment for why these are written.
const uint CVI_SDHCI_VENDOR_OFFSET = 0x200;
const uint CVI_SDHCI_PHY_TX_RX_DLY = 0x240;
const uint CVI_SDHCI_PHY_CONFIG    = 0x24C;

// PINMUX_BASE-relative: pad function-select (write 0 = route to SDIO0,
// not GPIO) and pad drive-strength/config (clrsetbits, mask 0xC at
// shift 2 — REG_SDIO0_PAD_CLR_MASK).
const uint PAD_SDIO0_CLK_REG     = 0x000;
const uint PAD_SDIO0_CMD_REG     = 0x004;
const uint PAD_SDIO0_D0_REG      = 0x008;
const uint PAD_SDIO0_D1_REG      = 0x00C;
const uint PAD_SDIO0_D2_REG      = 0x010;
const uint PAD_SDIO0_D3_REG      = 0x014;
const uint PAD_SDIO0_CD_REG      = 0x018;
const uint PAD_SDIO0_PWR_EN_REG  = 0x01C;

const uint REG_SDIO0_CLK_PAD_REG    = 0xA00;
const uint REG_SDIO0_CMD_PAD_REG    = 0xA04;
const uint REG_SDIO0_DAT0_PAD_REG   = 0xA08;
const uint REG_SDIO0_DAT1_PAD_REG   = 0xA0C;
const uint REG_SDIO0_DAT2_PAD_REG   = 0xA10;
const uint REG_SDIO0_DAT3_PAD_REG   = 0xA14;
const uint REG_SDIO0_CD_PAD_REG     = 0x900;
const uint REG_SDIO0_PWR_EN_PAD_REG = 0x904;

const uint SDIO0_PAD_CLR_MASK = 0xC;

// CLOCK_BASE-relative — pll_reg/CLOCK_BYPASS_SELECT_REGISTER's own
// offset, and pll_index, sourced directly from the `sd:` devicetree node
// (see boards/duo/board.c3's comment and the plan file's "Real register
// values" section).
const uint SD_PLL_REG              = 0x70;
const uint SD_PLL_DIV_VALUE        = 0x40009; // MMC_MAX_CLOCK_DIV_VALUE
const uint CLOCK_BYPASS_SELECT_REG = 0x30;
const uint SD_PLL_INDEX_BIT        = 1 << 6;  // pll_index = 6

// Clock GATE register — separate from both of the above. The PLL divider
// (SD_PLL_REG) and bypass-select bit only choose/retune the SD0 clock's
// *source*; this register (CLOCK_BASE + 0x0, i.e. 0x03002000, matching
// linux_5.10/drivers/clk/cvitek/clk-cv180x.c's REG_CLK_EN_0) is what
// actually lets that clock (and the bus that makes the SDHCI register
// block at SD_BASE reachable at all) run in the first place. Every write
// to SD_PLL_REG/CLOCK_BYPASS_SELECT_REG read back correctly on real
// hardware even while this stayed ungated, because those two live on an
// always-on CRU bus — but SDHCI_SOFTWARE_RESET never self-cleared and
// the internal clock never went stable, because the IP itself and the
// bus path to it were both still gated off. In Linux's own boot path
// this gate opens implicitly and automatically: the cv180x-clk driver
// marks both clk_sd0 (bit 19) and clk_axi4_sd0 (bit 18) CLK_IS_CRITICAL,
// so the Linux clock-framework core force-enables them the moment that
// driver probes, with no SD-specific code involved at all — not FSBL,
// not U-Boot (neither touches 0x03002000; U-Boot's own cvi_sdhci driver
// only ever writes the same two registers this file already had). A
// boot chain that skips Linux's clk subsystem entirely — FSBL -> OpenSBI
// -> this kernel directly, same as every board this project targets —
// never gets that implicit enable, so it has to happen here instead.
const uint REG_CLK_EN_0    = 0x000;
const uint CLK_EN_AXI4_SD0 = 1 << 18;
const uint CLK_EN_SD0      = 1 << 19;
const uint CLK_EN_100K_SD0 = 1 << 20;

fn void mmio_clrset8_in32(uint base_reg, uint byte_shift, uint mask, uint val)
{
	uint w = sd_reg_read(base_reg);
	w &= ~(mask << byte_shift);
	w |= (val << byte_shift);
	sd_reg_write(base_reg, w);
}

fn void pinmux_clrset8_in32(uint base_reg, uint byte_shift, uint mask, uint val)
{
	uint w = pinmux_reg_read(base_reg);
	w &= ~(mask << byte_shift);
	w |= (val << byte_shift);
	pinmux_reg_write(base_reg, w);
}

// One-time board bring-up: pad muxing, power switch, clock PLL, SDHCI
// software reset + internal clock, initial low-speed (~400kHz)
// enumeration clock. Standard SD spec requires talking to a freshly
// powered card slowly before its real operating speed is negotiated —
// not chip-specific.
fn void sdd_pad_power_clock_init()
{
	// Open the clock gate first — see REG_CLK_EN_0's own comment for why
	// this has to happen here at all. Nothing else in this function (or
	// anywhere in this driver) can work without it: the SDHCI register
	// block isn't even reliably reachable on its bus until clk_axi4_sd0
	// is open, let alone able to run a functional clock without clk_sd0.
	uint clk_en = clock_reg_read(REG_CLK_EN_0);
	clock_reg_write(REG_CLK_EN_0, clk_en | CLK_EN_AXI4_SD0 | CLK_EN_SD0 | CLK_EN_100K_SD0);

	// Function-select: route the physical pins to SDIO0, not GPIO.
	pinmux_reg_write(PAD_SDIO0_CLK_REG, 0);
	pinmux_reg_write(PAD_SDIO0_CMD_REG, 0);
	pinmux_reg_write(PAD_SDIO0_D0_REG, 0);
	pinmux_reg_write(PAD_SDIO0_D1_REG, 0);
	pinmux_reg_write(PAD_SDIO0_D2_REG, 0);
	pinmux_reg_write(PAD_SDIO0_D3_REG, 0);
	pinmux_reg_write(PAD_SDIO0_CD_REG, 0);
	pinmux_reg_write(PAD_SDIO0_PWR_EN_REG, 0);

	// Drive-strength/config, at bit-shift 2 within each pad's own register
	// (mask 0xC) — values taken directly from
	// duo-buildroot-sdk/u-boot-2021.10/board/cvitek/cv180x/sdhci_reg.h's
	// REG_SDIO0_*_PAD_VALUE constants (read from the real source this
	// session, not guessed): 2 for CLK and PWR_EN, 1 for everything else
	// (CMD/DAT0-3/CD). An earlier version of this had CLK/CMD/DAT all at
	// 2 and PWR_EN at 1 — backwards on every line except CLK, found once
	// enumeration hung on real hardware and this got checked against the
	// actual header instead of re-derived from memory.
	pinmux_clrset8_in32(REG_SDIO0_CLK_PAD_REG, 2, SDIO0_PAD_CLR_MASK, 2);
	pinmux_clrset8_in32(REG_SDIO0_CMD_PAD_REG, 2, SDIO0_PAD_CLR_MASK, 1);
	pinmux_clrset8_in32(REG_SDIO0_DAT0_PAD_REG, 2, SDIO0_PAD_CLR_MASK, 1);
	pinmux_clrset8_in32(REG_SDIO0_DAT1_PAD_REG, 2, SDIO0_PAD_CLR_MASK, 1);
	pinmux_clrset8_in32(REG_SDIO0_DAT2_PAD_REG, 2, SDIO0_PAD_CLR_MASK, 1);
	pinmux_clrset8_in32(REG_SDIO0_DAT3_PAD_REG, 2, SDIO0_PAD_CLR_MASK, 1);
	pinmux_clrset8_in32(REG_SDIO0_CD_PAD_REG, 2, SDIO0_PAD_CLR_MASK, 1);
	pinmux_clrset8_in32(REG_SDIO0_PWR_EN_PAD_REG, 2, SDIO0_PAD_CLR_MASK, 2);

	// Power switch: 3.3V, card present.
	top_reg_write(REG_TOP_SD_PWRSW_CTRL, SD_PWRSW_ON_3V3);

	// Clock PLL: set the divider value, then switch the SD clock source
	// from crystal bypass to the PLL (clear pll_index's bit).
	clock_reg_write(SD_PLL_REG, SD_PLL_DIV_VALUE);
	uint bypass = clock_reg_read(CLOCK_BYPASS_SELECT_REG);
	clock_reg_write(CLOCK_BYPASS_SELECT_REG, bypass & ~SD_PLL_INDEX_BIT);

	// Deliberately never issuing SDHCI_SOFTWARE_RESET, and never
	// reconfiguring the clock divisor: this IP comes out of BootROM
	// already correctly clocked and stable (BootROM has to read this
	// exact card to load FSBL at all, on this SD-boot board), and
	// RST_ALL was confirmed, via real hardware bring-up, to get stuck
	// permanently asserted — never self-clearing even across a
	// 20-million-iteration wait. A full-word write to reconfigure the
	// divisor afterward was force-clearing that stuck bit as a side
	// effect, without the hardware's own reset FSM ever having actually
	// finished, which is why the clock could never re-stabilize once
	// this drove that path — see docs/devlog.md's 2026-08-16 "(7)" entry
	// for the full elimination trail. Simplest fix: don't ask this IP
	// for a reset it can't cleanly complete, and don't touch a clock
	// configuration that's already demonstrably working.
	bool clk_stable = (sd_reg_read(SD_CLOCK_SWRESET) & SD_CLOCK_INT_STABLE) != 0;

	// Internal + bus power on.
	mmio_clrset8_in32(SD_HOSTCTRL_PWRCTRL, 8, 0xFF, 0x0F);

	// Clear any already-latched INT_STATUS bits *before* enabling
	// SIGNAL_ENABLE below — found necessary on real hardware: this
	// driver never issues SDHCI_SOFTWARE_RESET (see this function's own
	// comment on why), so nothing has ever cleared INT_STATUS since
	// chip power-on. The instant SIGNAL_ENABLE goes from 0 to
	// all-enabled, any bit already sitting latched there makes the
	// device's interrupt line assert immediately — and since
	// board::IRQ_SDHCI is now routed through the PLIC (see
	// entry.c3/board.c3), the kernel's own IRQ handler claims and
	// completes it at the PLIC level but has no reason to touch this
	// device's own INT_STATUS register (that's this driver's job, not
	// the kernel's generic IRQ-routing code's). Without this clear, the
	// line never actually de-asserts, so the PLIC just re-fires the same
	// interrupt again immediately — a tight storm that starves every
	// process, including this one, of ever running another instruction.
	// Confirmed on real hardware: execution stopped dead right after
	// this function's own final print, exactly where SIGNAL_ENABLE gets
	// turned on.
	sd_reg_write(SD_INT_STATUS, SD_INT_ALL_MASK);
	sd_reg_write(SD_INT_ENABLE, SD_INT_ALL_MASK);
	sd_reg_write(SD_SIGNAL_ENABLE, SD_INT_ALL_MASK);

	// PHY TX/RX delay-line reset — vendor-specific registers, sourced
	// from duo-buildroot-sdk/u-boot-2021.10/drivers/mmc/cvitek/
	// sdhci-cv180x.c's cvi_sdhci_probe(), gated there by the devicetree's
	// `reset_tx_rx_phy` flag on this exact SD node (cv180x_base.dtsi) —
	// not optional boilerplate, this SoC's SD node specifically asks for
	// it. Completely missing from an earlier version of this file (never
	// read the real driver source the first time through, just general
	// SDHCI spec knowledge) — plausibly the actual reason enumeration
	// never got a single command response on real hardware, found by
	// reading the driver after that silent hang.
	sd_reg_write(CVI_SDHCI_VENDOR_OFFSET, 2);
	sd_reg_write(CVI_SDHCI_PHY_TX_RX_DLY, 0x01000100);
	sd_reg_write(CVI_SDHCI_PHY_CONFIG, 1);

	// The one cheap diagnostic worth keeping unconditionally, before any
	// card command: distinguishes "clock never came up" from "clock's
	// fine, something later is wrong" if this ever needs revisiting on a
	// different card.
	print("sdd: clock_stable=");
	print(clk_stable ? "1\n" : "0\n");
}

uint sd_rca; // relative card address, learned from CMD3
bool sd_high_capacity; // CCS bit from ACMD41's R3 response

// Issues one SD command and busy-polls for completion. `resp_flags` is
// one of the SD_CMD_RESP_* constants (ORed with SD_CMD_CRC_CHECK /
// SD_CMD_INDEX_CHECK by the caller where the command warrants it — see
// each call site). `data` marks a data-present command (CMD17/CMD24
// only, here). Response ends up in sd_response0..3. Returns false on a
// timeout or a reported error, true otherwise — the caller decides how
// fatal that is (enumeration commands abort the whole init; a single
// failed block I/O just fails that one request back to fsd).
uint sd_response0;
uint sd_response1;
uint sd_response2;
uint sd_response3;

// Last raw SD_INT_STATUS value observed by sd_send_cmd — not meant as a
// general API, just exposed for the rare caller (like sdd_block_rw) that
// needs to know which bit actually completed, not just success/failure.
uint sd_last_int_status;

fn bool sd_send_cmd(uint index, uint arg, uint resp_flags, bool data)
{
	int inhibit_wait = 0;
	uint inhibit_mask = data ? (SD_PRESENT_CMD_INHIBIT | SD_PRESENT_DATA_INHIBIT) : SD_PRESENT_CMD_INHIBIT;
	while ((sd_reg_read(SD_PRESENT_STATE) & inhibit_mask) != 0 && inhibit_wait < SD_WAIT_MAX)
	{
		inhibit_wait++;
	}

	sd_reg_write(SD_ARGUMENT, arg);

	// Single combined 32-bit write covering both Transfer Mode (low 16
	// bits) and Command (high 16 bits). A prior version of this tried
	// splitting this into two separate writes on the theory that some
	// SDHCI implementations only latch command-issue on a write that
	// specifically touches the Command half — reverted: untested guess,
	// and for CMD0 specifically (index 0, minimal flags) it was
	// indistinguishable from writing nothing (both "separate" writes
	// worked out to 0x00000000), which is a worse test case than a
	// plain single write, not a better one. Going back to the simpler,
	// far more common convention.
	uint flags = resp_flags;
	if (data) flags |= SD_CMD_DATA_PRESENT;
	uint xfer = data ? (SD_TRNS_BLK_CNT_EN) : 0;
	uint cmd_word = ((index & 0x3F) << 24) | ((flags & 0xFF) << 16) | xfer;
	sd_reg_write(SD_XFERMODE_CMD, cmd_word);

	int complete_wait = 0;
	uint status = 0;
	while (complete_wait < SD_WAIT_MAX)
	{
		status = sd_reg_read(SD_INT_STATUS);
		if ((status & (SD_INT_RESPONSE | SD_INT_ERROR)) != 0) break;
		complete_wait++;
	}
	sd_last_int_status = status;
	// Clear the WHOLE status word, not just SD_INT_RESPONSE|SD_INT_ERROR.
	// SD_INT_ERROR (bit 15) is a *summary* bit over eleven separate
	// detail bits (TIMEOUT/CRC/END_BIT/INDEX/DATA_TIMEOUT/DATA_CRC/
	// DATA_END_BIT/BUS_POWER/ACMD12ERR/ADMA_ERROR, bits 16-25 — see the
	// real header), and clearing only the summary bit while a detail bit
	// underneath it stays set does nothing lasting — the summary just
	// re-asserts. Correct practice regardless, even though it turned out
	// NOT to be the cause of the real interrupt storm chased during this
	// board's PLIC bring-up — that was a genuine PLIC-level hardware
	// quirk, isolated and unrelated to this device-side clearing at all
	// (see docs/devlog.md's 2026-08-17 entry and sdd_block_rw's own
	// header comment).
	sd_reg_write(SD_INT_STATUS, SD_INT_ALL_MASK);

	if ((status & SD_INT_RESPONSE) == 0) return false;

	sd_response0 = sd_reg_read(SD_RESPONSE0);
	sd_response1 = sd_reg_read(SD_RESPONSE1);
	sd_response2 = sd_reg_read(SD_RESPONSE2);
	sd_response3 = sd_reg_read(SD_RESPONSE3);
	return true;
}

const char[16] HEX_DIGITS = "0123456789abcdef";

fn void print_hex32(uint v)
{
	for (int shift = 28; shift >= 0; shift -= 4)
	{
		putchar(HEX_DIGITS[(v >> shift) & 0xF]);
	}
}

// Raises SDCLK from whatever slow clock BootROM left running (see
// sdd_pad_power_clock_init's own comment — deliberately never
// reconfigured before this point, since a prior version of this exact
// function broke a working clock by full-word-clobbering this same
// register) up to a real operating speed, once the card is selected.
// 375000000 / (2*8) ≈ 23.4MHz — SD default-speed's own ceiling is
// 25MHz, and this driver never sends CMD6 to negotiate high-speed mode,
// so this is the right target: no faster mode has actually been agreed
// with the card.
//
// Every step here is read-modify-write, never a full-word write to
// SD_CLOCK_SWRESET — that exact mistake (clobbering byte 2/3 as a side
// effect of writing just the low 16 bits) was root-caused as what broke
// a working clock earlier in this board's bring-up (see docs/devlog.md).
// Standard SDHCI re-clock sequence: disable the card clock, change the
// divisor, wait for internal-clock-stable, re-enable the card clock —
// never touches SDHCI_SOFTWARE_RESET (still confirmed stuck/unusable on
// this exact IP, same reasoning as sdd_pad_power_clock_init).
fn void sdd_raise_clock()
{
	uint w = sd_reg_read(SD_CLOCK_SWRESET);
	sd_reg_write(SD_CLOCK_SWRESET, w & ~SD_CLOCK_CARD_EN);

	uint div_25m = 8;
	w = sd_reg_read(SD_CLOCK_SWRESET);
	w = (w & 0xFFFF0000) | ((div_25m & 0xFF) << 8) | SD_CLOCK_INT_EN;
	sd_reg_write(SD_CLOCK_SWRESET, w);

	int wait = 0;
	while ((sd_reg_read(SD_CLOCK_SWRESET) & SD_CLOCK_INT_STABLE) == 0 && wait < SD_SETUP_WAIT_MAX)
	{
		wait++;
	}

	w = sd_reg_read(SD_CLOCK_SWRESET);
	sd_reg_write(SD_CLOCK_SWRESET, w | SD_CLOCK_CARD_EN);
}

// Standard SD Physical Layer enumeration sequence — same command
// sequence for any SDHCI controller (see this file's header comment).
// Prints a marker after every stage: this exact function silently
// stalled on real hardware the first time through (three real bugs in
// sdd_pad_power_clock_init — see its own comments), and there was no way
// to tell from the console alone which of CMD0/CMD8/ACMD41/CMD2/CMD3/
// CMD9/CMD7 it had gotten stuck at without disassembling and reasoning
// about it blind. Kept permanently, not stripped once this works — see
// entry.c3's current_pid trap-print for the same reasoning elsewhere in
// this codebase.
fn bool sdd_enumerate()
{
	// CMD0: GO_IDLE_STATE, no response — success here just means the
	// command register accepted the write and CMD_INHIBIT cleared
	// afterward (SD_CMD_RESP_NONE means sd_send_cmd's own SD_INT_RESPONSE
	// check can never be satisfied by a real response, only by the
	// command-complete interrupt SDHCI still raises for a no-response
	// command). A false here means CMD_INHIBIT never cleared at all
	// going in, or the command-complete interrupt itself never fired —
	// i.e. the clock genuinely isn't toggling — the single most useful
	// bit to know before spending any more time on ACMD41 below.
	bool cmd0_ok = sd_send_cmd(0, 0, SD_CMD_RESP_NONE, false);
	print("sdd: CMD0 ");
	print(cmd0_ok ? "ok\n" : "TIMED OUT\n");

	// CMD8: SEND_IF_COND — 0x1AA = check pattern 0xAA + 2.7-3.6V range.
	// A v1.x (pre-SD2.0) card won't respond at all; treated as
	// non-fatal (some cards, still handled by ACMD41 below), only a
	// v2.0+-card assumption gets recorded.
	bool cmd8_ok = sd_send_cmd(8, 0x1AA, SD_CMD_RESP_SHORT | SD_CMD_CRC_CHECK | SD_CMD_INDEX_CHECK, false);
	print("sdd: CMD8 ");
	print(cmd8_ok ? "responded: " : "no response: ");
	print_hex32(sd_response0);
	print("\n");

	// ACMD41 (CMD55 + CMD41): SD_SEND_OP_COND, busy-polled until the card
	// reports ready (bit 31 of the R3 response). HCS (bit 30 of the
	// argument) requests high-capacity support. 200 tries, not the
	// original 2000 (itself already cut down from 100000) — SD Physical
	// Layer spec's own recommended ACMD41 polling timeout is ~1 second,
	// and each try costs up to two commands' worth of SD_WAIT_MAX-bounded
	// busy-waits, so even 2000 tries of a genuinely non-responding card
	// took long enough on real hardware to be indistinguishable from a
	// hang from the console alone (confirmed: sat with no new output for
	// a long time on the first real attempt). A '.' printed every 20
	// tries means the console shows visible progress the whole time
	// instead of only at the very end.
	bool ready = false;
	int tries;
	for (tries = 0; tries < 200 && !ready; tries++)
	{
		if (tries > 0 && tries % 20 == 0) putchar('.');
		if (!sd_send_cmd(55, 0, SD_CMD_RESP_SHORT | SD_CMD_CRC_CHECK | SD_CMD_INDEX_CHECK, false)) continue;
		if (!sd_send_cmd(41, 0x40FF8000, SD_CMD_RESP_SHORT, false)) continue;
		if ((sd_response0 & 0x80000000) != 0)
		{
			ready = true;
			sd_high_capacity = (sd_response0 & 0x40000000) != 0;
		}
	}
	print("\n");
	print("sdd: ACMD41 ");
	print(ready ? "ready after " : "gave up after ");
	print_hex32((uint)tries);
	print(" tries, ocr=");
	print_hex32(sd_response0);
	print("\n");
	if (!ready) return false;

	// CMD2: ALL_SEND_CID, R2 (long) response — content unused in v1.
	if (!sd_send_cmd(2, 0, SD_CMD_RESP_LONG | SD_CMD_CRC_CHECK, false)) return false;
	print("sdd: CMD2 (CID) ok\n");

	// CMD3: SEND_RELATIVE_ADDR, R6 — RCA in bits [31:16] of the response.
	if (!sd_send_cmd(3, 0, SD_CMD_RESP_SHORT | SD_CMD_CRC_CHECK | SD_CMD_INDEX_CHECK, false)) return false;
	sd_rca = sd_response0 & 0xFFFF0000;
	print("sdd: CMD3 rca=");
	print_hex32(sd_rca);
	print("\n");

	// CMD9: SEND_CSD, R2 — mostly informational for a first cut (see the
	// plan file); not decoded further here.
	sd_send_cmd(9, sd_rca, SD_CMD_RESP_LONG | SD_CMD_CRC_CHECK, false);

	// CMD7: SELECT_CARD.
	if (!sd_send_cmd(7, sd_rca, SD_CMD_RESP_SHORT | SD_CMD_CRC_CHECK | SD_CMD_INDEX_CHECK, false)) return false;
	print("sdd: CMD7 (SELECT_CARD) ok\n");

	sdd_raise_clock();
	print("sdd: raised clock, clock_reg=");
	print_hex32(sd_reg_read(SD_CLOCK_SWRESET));
	print("\n");

	// CMD16: SET_BLOCKLEN=512 — SDHC/SDXC cards are fixed at 512 by
	// spec, but harmless (and required for SDSC cards) to send anyway.
	sd_send_cmd(16, SECTOR_SIZE, SD_CMD_RESP_SHORT | SD_CMD_CRC_CHECK | SD_CMD_INDEX_CHECK, false);

	return true;
}

fn void sdd_panic(char* msg)
{
	print("sdd: ");
	print(msg);
	print("\n");
	// See user/diskd.c3's diskd_panic comment for why this is exit(), not
	// an empty `for(;;){}` loop — same UB/optimizer hazard applies here.
	exit();
}

// PIO block transfer: CMD17 (read) or CMD24 (write), then 128 32-bit
// words through the buffer-data-port register once the present-state
// ready bit is set, then wait for transfer-complete. `data` is exactly
// SECTOR_SIZE bytes, already positioned by the caller.
//
// Busy-polling, not interrupt-driven — a real attempt at interrupt-
// driven completion (PLIC IRQ_SDHCI) was made and thoroughly isolated on
// real hardware: enabling this PLIC's enable-bit for source 36 alone
// (independent of anything the SDHCI device itself does — confirmed by
// disabling only that one bit and leaving every device-side
// interrupt-enable register untouched, which fixed it) reliably wedges
// the CPU into a permanent external-interrupt storm — claim() and the
// raw hardware pending bitmap both report nothing pending on every
// single sample, yet the trap never stops. That's a genuine, real
// hardware quirk in this exact PLIC for this exact source, not
// something in this driver's own logic: two independent, correctly-
// targeted device-level fixes (widening the status-register clear,
// unconditionally completing at the PLIC level) left the storm's exact
// signature completely unchanged, and the isolation test proved neither
// of those was ever the actual cause. See docs/devlog.md's 2026-08-17
// entry for the full elimination trail. board::IRQ_SDHCI's PLIC
// enable-bit write is commented out in boards/duo/board.c3's plic_init()
// to match — leave it that way unless this gets revisited with real
// hardware debug tooling (logic analyzer on the IRQ line, or vendor
// engineering support), not just source-reading.
fn bool sdd_block_rw(char* data, uint sector, bool is_write)
{
	sd_reg_write(SD_BLKSIZE_BLKCNT, (1 << 16) | SECTOR_SIZE);

	// DATA_SECTOR_OFFSET: fsd's `sector` argument (user/fsd.c3) is a
	// logical index starting at 0 — but sector 0 on THIS physical card
	// is the MBR/partition table, and everything from sector 2048 on is
	// the DUOBOOT FAT partition holding this board's own bootable
	// fip.bin (confirmed via `sfdisk`/`lsblk` against the actual card
	// this was bring-up-tested on). Writing fsd's tar-formatted file
	// data at raw sector 0 would destroy the partition table BootROM
	// needs to find that partition at all — the disk stays physically
	// intact but the board would very likely stop booting until the MBR
	// got manually reconstructed. Offsetting into the unused gap between
	// the MBR and the first partition (sectors 1-2047, ~1MB, comfortably
	// more than fsd's ~2560-byte DISK_MAX_SIZE) keeps racccoon's own
	// data entirely out of both the MBR and the boot partition — see
	// docs/devlog.md for the full reasoning. 64 is arbitrary within that
	// safe range, just comfortably clear of sector 0 on either side.
	uint absolute_sector = sector + DATA_SECTOR_OFFSET;

	// SDHC/SDXC: block addressing, argument = block number directly.
	// SDSC: byte addressing, argument = sector * 512.
	uint arg = sd_high_capacity ? absolute_sector : (absolute_sector * SECTOR_SIZE);

	uint resp = SD_CMD_RESP_SHORT | SD_CMD_CRC_CHECK | SD_CMD_INDEX_CHECK;
	uint index = is_write ? 24 : 17;
	if (!sd_send_cmd(index, arg, resp, true)) return false;

	uint ready_bit = is_write ? SD_PRESENT_SPACE_AVAIL : SD_PRESENT_DATA_AVAIL;
	int ready_wait = 0;
	while ((sd_reg_read(SD_PRESENT_STATE) & ready_bit) == 0 && ready_wait < SD_WAIT_MAX)
	{
		ready_wait++;
	}
	if ((sd_reg_read(SD_PRESENT_STATE) & ready_bit) == 0) return false;

	uint* words = (uint*)data;
	for (uint i = 0; i < SECTOR_SIZE / 4; i++)
	{
		if (is_write)
		{
			sd_reg_write(SD_BUFFER, words[i]);
		}
		else
		{
			words[i] = sd_reg_read(SD_BUFFER);
		}
	}

	int done_wait = 0;
	uint status = 0;
	while (done_wait < SD_WAIT_MAX)
	{
		status = sd_reg_read(SD_INT_STATUS);
		if ((status & (SD_INT_DATA_END | SD_INT_ERROR)) != 0) break;
		done_wait++;
	}
	sd_reg_write(SD_INT_STATUS, SD_INT_ALL_MASK);

	return (status & SD_INT_DATA_END) != 0;
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
}

fn void main() @export("main")
{
	sdd_init();

	for (;;)
	{
		char[DISKD_MSG_MAX] buf @noinit;
		uint verb = 0;
		int from = ipc_recv_type(&buf, DISKD_MSG_MAX, &verb);
		// Same as diskd: a legitimate sender can be KERNEL_PID (-1) via
		// fs.c3's kernel-internal client, not just a real process pid.
		if (from == 0) continue;
		if (verb != DISKD_READ && verb != DISKD_WRITE) continue;

		bool is_write = (verb == DISKD_WRITE);
		uint* sector_ptr = (uint*)&buf;
		uint sector = *sector_ptr;

		char status = 0;
		if (!sdd_block_rw(&buf[4], sector, is_write))
		{
			status = 1;
		}

		buf[0] = status;
		ipc_send(from, verb, &buf, DISKD_MSG_MAX);
	}
}
