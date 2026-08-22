module user;

// sdhci: the SDHCI register/PIO layer for the Milk-V Duo's real SD
// storage — the "how" layer for user/block/sdd.c3's own orchestration
// (main()/the IPC request loop). Split out from what used to be one
// combined sdd.c3 once it grew large enough that "the part that talks
// to the wire" and "the part that decides what to do next" were hard
// to tell apart in one file (docs/devlog.md) — same reasoning, same
// shape as usbd.c3's own dwc2.c3 split and ethd.c3's own dwmac.c3/
// ephy.c3 split.
//
// Structural note carried over from the original file: PIO, not DMA.
// The SDHCI Buffer Data Port register is read/written one 32-bit word
// at a time directly into ordinary memory inside this process's own
// image — no virtqueue, no kernel-allocated physically-contiguous
// buffer, no SYS_DISKD_INFO-style syscall to learn a physical address
// (see setup_sdd_mappings, process.c3). Also no PLIC/interrupt
// involvement at all: SDHCI commands complete in microseconds to low
// milliseconds, so busy-polling PRESENT_STATE/INT_STATUS directly is
// simpler — see sdd_block_rw's own header comment for the real,
// isolated hardware quirk that ruled out an interrupt-driven version.
//
// Register offsets/bit layouts below are the standard SDHCI Host
// Controller Simplified Specification — the same layout Linux's
// include/linux/mmc/sdhci.h and U-Boot's include/sdhci.h both implement
// verbatim, not vendor-specific. The pad/power/clock bring-up sequence
// in sdd_pad_power_clock_init, and the base addresses it targets, ARE
// vendor-specific — sourced from duo-buildroot-sdk's own
// board/cvitek/cv180x/*.h and drivers/mmc/cvitek/sdhci-cv180x.c (see
// boards/duo/board.c3's SD_* constants).

// Gates the two per-sector-I/O print() blocks below (sdd_block_rw's
// own success path) and sdd.c3's own main loop's matching print —
// real, useful bringup-era diagnostics (found real bugs this way, see
// docs/devlog.md), but two full lines per sector adds up fast against
// a real ext2 read path that can touch dozens of sectors per exec()/9P
// read, and the driver's own timing has been extensively verified
// since. Off by default; flip to true for the same level of detail if
// a real hardware bug ever needs it again — both prints sit outside
// the timing-sensitive window this file's own comments warn about (one
// runs before the command is even sent, the other after the transfer
// has already completed), so toggling this can't reintroduce the
// FIFO-timing bug that window's own discipline exists to prevent.
const bool SDD_VERBOSE = false;

const uint SECTOR_SIZE = 512; // shared with sdd.c3's own wire-protocol message layout (DISKD_MSG_MAX)

// --- SDHCI register block (relative to board::SD_MMIO_BASE). Each
// constant here is one 32-bit-aligned register; sub-word fields (8/16-bit
// per the spec) are accessed via shift/mask on the enclosing 32-bit word
// instead of narrower loads/stores — same reasoning user/block/diskd.c3's
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

// Real, wall-clock-bounded wait budgets — this driver used to have no
// timer/delay primitive at all (no rdtime access from user mode —
// scounteren.TM was never enabled — see docs/devlog.md), so every wait
// here used to be a raw iteration-count busy loop with genuinely unknown
// correspondence to real time (SD_WAIT_MAX/SD_SETUP_WAIT_MAX, both blunt
// instruments chosen by trial, not real timeouts). Now that
// user/user.c3's rdtime() exists, every wait below is bounded in real
// microseconds instead. SD_TIMEBASE_HZ is the Duo's real timebase-
// frequency, confirmed directly from the real devicetree shipped in
// duo-buildroot-sdk (build/boards/default/dts/cv180x_riscv/
// cv180x_base_riscv.dtsi: `timebase-frequency = 25000000`), not assumed.
const uint SD_TIMEBASE_HZ = 25000000;

fn ulong sd_us_to_ticks(ulong us)
{
	return us * SD_TIMEBASE_HZ / 1000000;
}

// Real timeout values below, not invented: sourced from the real U-Boot
// generic SDHCI driver (duo-buildroot-sdk/u-boot-2021.10/drivers/mmc/
// sdhci.c), the same file already read once this session for the
// SDHCI_TRNS_READ direction-bit bug and the RST_ALL-stuck elimination
// trail.
//   - SD_CMD_INHIBIT_US: sdhci_send_command()'s own CMD/DATA-inhibit
//     wait, SDHCI_CMD_DEFAULT_TIMEOUT = 100ms.
//   - SD_CMD_COMPLETE_US: the same function's post-command wait for
//     SDHCI_INT_RESPONSE, SDHCI_READ_STATUS_TIMEOUT = 1000ms.
//   - SD_CLOCK_STABLE_US: sdhci_set_clock()'s internal-clock-stable
//     wait, literally "wait max 20 ms" in the real source.
//   - SD_DATA_READY_US/SD_XFER_DONE_US: sdhci_transfer_data()'s own
//     combined ready+transfer+DATA_END loop budgets 10 real seconds
//     (timeout=1000000, udelay(10)) for a *whole*, potentially multi-
//     block transfer; this driver only ever moves one block per call
//     and splits ready-wait from completion-wait into two separate
//     steps, so each gets a smaller, still-generous 1000ms slice of
//     that same real envelope rather than the full 10s each.
const ulong SD_CMD_INHIBIT_US   = 100000;
const ulong SD_CMD_COMPLETE_US  = 1000000;
const ulong SD_CLOCK_STABLE_US  = 20000;
const ulong SD_DATA_READY_US    = 1000000;
const ulong SD_XFER_DONE_US     = 1000000;

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
// convention user/block/diskd.c3 already follows for VIRTIO_BLK_PADDR —
// see this file's own header comment and boards/duo/board.c3 for where
// these come from.
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
// (see boards/duo/board.c3's comment).
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
	ulong inhibit_start = rdtime();
	ulong inhibit_budget = sd_us_to_ticks(SD_CMD_INHIBIT_US);
	uint inhibit_mask = data ? (SD_PRESENT_CMD_INHIBIT | SD_PRESENT_DATA_INHIBIT) : SD_PRESENT_CMD_INHIBIT;
	while ((sd_reg_read(SD_PRESENT_STATE) & inhibit_mask) != 0 && rdtime() - inhibit_start < inhibit_budget)
	{
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
	// Data Transfer Direction Select (SD_TRNS_READ) was defined as a
	// constant but never actually set anywhere — real, concrete bug,
	// not a timing issue: every data-bearing command left this bit 0
	// ("host-to-card"/write direction) regardless of which command was
	// actually issued, so a CMD17 (read) left the controller configured
	// for a write-direction transfer. PRESENT_STATE confirmed this
	// directly on real hardware: SPACE_AVAILABLE (write-ready) came up
	// set, DATA_AVAILABLE (what a real read needs) never did — sdd_
	// block_rw's own wait for DATA_AVAILABLE then timed out forever,
	// looking exactly like a device that never responds, for a read
	// that had actually already succeeded at the command level (CMD17
	// got a valid R1 response, card state = "tran"). Inferred from the
	// command index rather than a new parameter: CMD17/CMD24 are the
	// only two data-bearing commands this driver ever issues.
	uint xfer = 0;
	if (data)
	{
		xfer = SD_TRNS_BLK_CNT_EN;
		if (index == 17) xfer |= SD_TRNS_READ;
	}
	uint cmd_word = ((index & 0x3F) << 24) | ((flags & 0xFF) << 16) | xfer;
	sd_reg_write(SD_XFERMODE_CMD, cmd_word);

	ulong complete_start = rdtime();
	ulong complete_budget = sd_us_to_ticks(SD_CMD_COMPLETE_US);
	uint status = 0;
	while (rdtime() - complete_start < complete_budget)
	{
		status = sd_reg_read(SD_INT_STATUS);
		if ((status & (SD_INT_RESPONSE | SD_INT_ERROR)) != 0) break;
	}
	sd_last_int_status = status;
	// On error, clear the WHOLE status word, not just SD_INT_RESPONSE|
	// SD_INT_ERROR: SD_INT_ERROR (bit 15) is a *summary* bit over eleven
	// separate detail bits (TIMEOUT/CRC/END_BIT/INDEX/DATA_TIMEOUT/
	// DATA_CRC/DATA_END_BIT/BUS_POWER/ACMD12ERR/ADMA_ERROR, bits 16-25 —
	// see the real header), and clearing only the summary bit while a
	// detail bit underneath it stays set does nothing lasting. The
	// transfer is being abandoned on this path anyway (return false
	// below), so a full clear is safe here.
	//
	// On success for a data-bearing command, don't write SD_INT_STATUS at
	// all here — defer entirely to the caller (sdd_block_rw), which does
	// one single combined clear (RESPONSE|DATA_AVAIL together) right
	// before draining the buffer. This started as "clear only
	// SD_INT_RESPONSE, not the whole word" (on the theory that a blanket
	// clear was wiping data-ready bits before the data-phase ever saw
	// them), which cut a measured, byte-exact 16-byte PIO data loss down
	// to 8 bytes — real progress, but not zero. That a *narrower* write
	// to this register, still made while CMD17's data phase was actively
	// in flight, still cost exactly one more 8-byte granule points at the
	// write itself (to this register, mid-transfer, regardless of which
	// bits it sets) being what perturbs this SDHCI clone's FIFO — not
	// which bits happen to be set in the value. Not writing here at all
	// for a data command is the only way left to test that directly. On
	// success for a non-data command, SD_INT_RESPONSE alone is still
	// correct and safe to clear immediately (nothing else in flight).
	// On error, still clear everything (see this block's own comment
	// above) — the transfer is being abandoned either way.
	if ((status & SD_INT_ERROR) != 0)
	{
		sd_reg_write(SD_INT_STATUS, SD_INT_ALL_MASK);
	}
	else if (!data)
	{
		sd_reg_write(SD_INT_STATUS, SD_INT_RESPONSE);
	}

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

	ulong stable_start = rdtime();
	ulong stable_budget = sd_us_to_ticks(SD_CLOCK_STABLE_US);
	while ((sd_reg_read(SD_CLOCK_SWRESET) & SD_CLOCK_INT_STABLE) == 0 && rdtime() - stable_start < stable_budget)
	{
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
	// and each try costs up to two commands' worth of SD_CMD_INHIBIT_US/
	// SD_CMD_COMPLETE_US-bounded busy-waits, so even 2000 tries of a
	// genuinely non-responding card
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

	// CMD9: SEND_CSD, R2 — mostly informational for a first cut; not
	// decoded further here.
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
	// Write support: fsd's own reserved-cluster allowlist (see
	// user/fs/fsd.c3's header comment) is the thing that decides WHICH
	// sectors are safe to write — this layer just moves bytes for
	// whatever sector it's asked to touch, symmetric to the read path
	// below in every respect. A prior version of this function kept a
	// small offset-relative bounds check (DATA_SECTOR_OFFSET) sized for
	// the old tar-based fsd's own small, isolated data region; removed
	// once fsd started addressing real, absolute sectors on the actual
	// DUOBOOT partition, and unconditionally rejected all writes for a
	// while after that since there was no longer a well-defined "safe to
	// write" region at THIS layer. There still isn't — the safety now
	// lives entirely in fsd, which is the layer that actually understands
	// FAT32 structure well enough to know what's safe.
	sd_reg_write(SD_BLKSIZE_BLKCNT, (1 << 16) | SECTOR_SIZE);

	// SDHC/SDXC: block addressing, argument = block number directly.
	// SDSC: byte addressing, argument = sector * 512.
	uint arg = sd_high_capacity ? sector : (sector * SECTOR_SIZE);

	uint resp = SD_CMD_RESP_SHORT | SD_CMD_CRC_CHECK | SD_CMD_INDEX_CHECK;
	uint cmd_index = is_write ? 24 : 17; // WRITE_BLOCK / READ_SINGLE_BLOCK
	bool cmd_ok = sd_send_cmd(cmd_index, arg, resp, true);
	if (!cmd_ok)
	{
		// Aborting anyway — nothing left to race against, safe to print
		// here (see this function's own header comment on why every
		// print() between the command completing and the buffer-drain
		// loop was removed from the success path).
		print("sdd: CMD");
		print_hex32(cmd_index);
		print(" TIMED OUT resp0=");
		print_hex32(sd_response0);
		print("\n");
		return false;
	}

	// A real, wall-clock-bounded wait now (see SD_DATA_READY_US's own
	// comment) — deliberately different from sd_send_cmd's own command-
	// level wait, which stays tight since it's paid repeatedly during
	// ACMD41's retry loop (a slow bound there makes a genuinely non-
	// responding card look hung — see that function's own comment). This
	// wait is paid once per block request, not per retry, so a generous
	// bound here is cheap regardless of whether it turns out to matter.
	//
	// Waits on INT_STATUS's own ready bit — SD_INT_DATA_AVAIL for a read,
	// SD_INT_SPACE_AVAIL for a write — not PRESENT_STATE's equivalent
	// bits, matching the real vendor driver's sdhci_transfer_data()
	// (u-boot's generic drivers/mmc/sdhci.c, read directly during this
	// session's read-side diagnosis; the same pattern applies
	// symmetrically here). rdtime() itself is a handful of instructions
	// (csrr + a memory bridge, no UART involved) — nowhere near the
	// print()-call overhead that was the actual root cause of the real
	// data-loss bug documented below, so calling it here doesn't
	// reintroduce that hazard.
	uint ready_bit = is_write ? SD_INT_SPACE_AVAIL : SD_INT_DATA_AVAIL;
	ulong ready_start = rdtime();
	ulong ready_budget = sd_us_to_ticks(SD_DATA_READY_US);
	uint int_status = 0;
	while (rdtime() - ready_start < ready_budget)
	{
		int_status = sd_reg_read(SD_INT_STATUS);
		if ((int_status & (ready_bit | SD_INT_ERROR)) != 0) break;
	}
	bool ready_ok = (int_status & ready_bit) != 0;
	if (!ready_ok)
	{
		print("sdd: ");
		print(is_write ? "space" : "data");
		print("-ready TIMED OUT, int_status=");
		print_hex32(int_status);
		print("\n");
		return false;
	}

	// No print() calls, and no SD_INT_STATUS write, between here and the
	// buffer loop below — deliberately, in both directions. This is the
	// actual fix for a real, measured bug on the read side (see
	// docs/devlog.md's FAT32 entry for the full elimination trail: the
	// card's DAT lines start pushing/pulling data almost immediately
	// after the command is accepted, and this SDHCI clone's PIO FIFO is
	// shallow enough that any delay here — a print() is many slow, one-
	// character-at-a-time UART writes — costs real data). Applied here
	// symmetrically for writes on the same reasoning, not yet separately
	// proven broken without it — there's no reason to believe this
	// controller's write-side FIFO is less shallow than its read-side one.
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

	ulong done_start = rdtime();
	ulong done_budget = sd_us_to_ticks(SD_XFER_DONE_US);
	uint status = 0;
	while (rdtime() - done_start < done_budget)
	{
		status = sd_reg_read(SD_INT_STATUS);
		if ((status & (SD_INT_DATA_END | SD_INT_ERROR)) != 0) break;
	}
	// All the command/ready diagnostics deferred from earlier in this
	// function (see this function's own header comment) — safe to print
	// now, the whole block is already fully transferred. Elapsed
	// microseconds, not raw iteration counts — genuinely meaningful now
	// that rdtime() exists, unlike the old "N iters" figures. Gated by
	// SDD_VERBOSE (see its own comment) — this whole block exists only
	// to feed the print below, safe to skip entirely when quiet.
	if (SDD_VERBOSE)
	{
		uint ready_us = (uint)((rdtime() - ready_start) * 1000000 / SD_TIMEBASE_HZ);
		uint done_us = (uint)((rdtime() - done_start) * 1000000 / SD_TIMEBASE_HZ);
		print("sdd: CMD");
		print_hex32(cmd_index);
		print(" ok resp0=");
		print_hex32(sd_response0);
		print(" ready after ");
		print_uint(ready_us);
		print("us, int_status=");
		print_hex32(int_status);
		print(" transfer-complete status=");
		print_hex32(status);
		print(" after ");
		print_uint(done_us);
		print("us\n");
	}
	sd_reg_write(SD_INT_STATUS, SD_INT_ALL_MASK);

	return (status & SD_INT_DATA_END) != 0;
}
