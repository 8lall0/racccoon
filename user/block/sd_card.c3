module user;

// SD card protocol, shared by every SD host controller sdd can be built
// with — the Duo's Cvitek SDHCI (sdhci.c3) and the Orange Pi's DesignWare
// MSHC (dw_mshc.c3). The card side of bring-up (CMD0 / CMD8 / ACMD41 /
// CMD2 / CMD3 / CMD9 / CMD7 / CMD16) is the SD Physical Layer spec's and
// identical on both; only how a command reaches the card differs. It used
// to be written out twice, and the ACMD41 timing bug (docs/devlog.md
// 2026-10-18) had to be found and fixed twice.
//
// The controller file (one per build, scripts/build_user.sh's SDD_SOC_SRC)
// provides:
//   fn bool sdc_cmd(uint index, uint arg, uint resp)  — issue one command,
//        false on timeout/error; `resp` is one of SDC_RESP_* below
//   fn uint sdc_resp0()      — bits [31:0] of the last short response
//   fn bool sdc_run_clock()  — leave identification speed for the run
//        clock once the card is selected (prints its own detail)

// Response kinds, as the SD spec names them. Each controller maps these
// onto its own flag bits (SDHCI also checks the echoed index; DW-MSHC has
// no such check).
const uint SDC_RESP_NONE = 0; // CMD0
const uint SDC_RESP_R1   = 1; // 48-bit, CRC + index (R1/R6/R7)
const uint SDC_RESP_R2   = 2; // 136-bit, CRC (CID/CSD)
const uint SDC_RESP_R3   = 3; // 48-bit, no CRC/index (OCR, ACMD41)

uint sd_rca;            // relative card address, learned from CMD3
bool sd_high_capacity;  // CCS bit from ACMD41's R3: SDHC/SDXC address by block, SDSC by byte

// Standard enumeration. Prints a marker after every stage: on real
// hardware this sequence has silently stalled more than once during
// bring-up, and the console was the only way to see which command it got
// stuck at. Kept permanently for that reason.
fn bool sdd_enumerate()
{
	// CMD0: GO_IDLE_STATE, no response. A false here means the controller
	// never even completed the command — the clock genuinely isn't
	// toggling, the single most useful thing to know before ACMD41.
	bool cmd0_ok = sdc_cmd(0, 0, SDC_RESP_NONE);
	print("sdd: CMD0 ");
	print(cmd0_ok ? "ok\n" : "TIMED OUT\n");

	// CMD8: SEND_IF_COND — 0x1AA = check pattern 0xAA + 2.7-3.6V range.
	// A v1.x (pre-SD2.0) card won't respond at all; non-fatal, ACMD41
	// below still handles it.
	bool cmd8_ok = sdc_cmd(8, 0x1AA, SDC_RESP_R1);
	print("sdd: CMD8 ");
	print(cmd8_ok ? "responded: " : "no response: ");
	print_hex32(sdc_resp0());
	print("\n");

	// ACMD41 (CMD55 + CMD41): SD_SEND_OP_COND, polled until the card
	// reports ready (bit 31 of the R3 response). HCS (bit 30 of the
	// argument) requests high-capacity support.
	//
	// Bounded by wall-clock time, not a try count: the SD Physical Layer
	// spec gives the card up to 1 s to finish initializing, and Linux's
	// mmc_send_app_op_cond polls every 10 ms for that 1 s. This used to be
	// "200 back-to-back tries", which only lasted long enough by accident:
	// at boot the card is already initialized (BootROM read it), and with
	// `loud` on each progress '.' costs serial time. A respawned sdd with
	// its output silenced (CMD0 just reset an initialized card, which then
	// needs a full init) burned all 200 before the card was ready, panicked,
	// and only the supervisor's second respawn worked — the double
	// "svc: respawned sdd" (docs/devlog.md 2026-10-18). 2 s = the spec's
	// bound with margin; a '.' every 100 ms shows progress meanwhile.
	ulong hz = timebase_hz();
	ulong acmd41_start = rdtime();
	ulong acmd41_next_dot = acmd41_start + hz / 10;
	bool ready = false;
	int tries = 0;
	while (!ready && rdtime() - acmd41_start < hz * 2)
	{
		if (tries > 0)
		{
			ulong poll_start = rdtime();
			while (rdtime() - poll_start < hz / 100) { yield(); }
		}
		tries++;
		if (rdtime() >= acmd41_next_dot) { putchar('.'); acmd41_next_dot += hz / 10; }
		if (!sdc_cmd(55, 0, SDC_RESP_R1)) continue;
		if (!sdc_cmd(41, 0x40FF8000, SDC_RESP_R3)) continue;
		uint ocr = sdc_resp0();
		if ((ocr & 0x80000000) != 0)
		{
			ready = true;
			sd_high_capacity = (ocr & 0x40000000) != 0;
		}
	}
	print("\n");
	print("sdd: ACMD41 ");
	print(ready ? "ready after " : "gave up after ");
	print_hex32((uint)tries);
	print(" tries, ocr=");
	print_hex32(sdc_resp0());
	print("\n");
	if (!ready) return false;

	// CMD2: ALL_SEND_CID, R2 — content unused.
	if (!sdc_cmd(2, 0, SDC_RESP_R2)) return false;
	print("sdd: CMD2 (CID) ok\n");

	// CMD3: SEND_RELATIVE_ADDR, R6 — RCA in bits [31:16].
	if (!sdc_cmd(3, 0, SDC_RESP_R1)) return false;
	sd_rca = sdc_resp0() & 0xFFFF0000;
	print("sdd: CMD3 rca=");
	print_hex32(sd_rca);
	print("\n");

	// CMD9: SEND_CSD, R2 — informational, not decoded.
	sdc_cmd(9, sd_rca, SDC_RESP_R2);

	// CMD7: SELECT_CARD — into transfer state.
	if (!sdc_cmd(7, sd_rca, SDC_RESP_R1)) return false;
	print("sdd: CMD7 (SELECT_CARD) ok\n");

	if (!sdc_run_clock()) return false;

	// CMD16: SET_BLOCKLEN=512 — SDHC/SDXC cards are fixed at 512 by
	// spec, but harmless (and required for SDSC cards) to send anyway.
	sdc_cmd(16, SECTOR_SIZE, SDC_RESP_R1);

	return true;
}
