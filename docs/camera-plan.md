# CAM-GC2083 camera bring-up — staged plan

Milk-V's own 16-pin MIPI CSI camera module (GC2083 sensor) for the Duo.
First surveyed 2026-08-28 (see docs/devlog.md), set aside as the "big
item" in favor of the USB keyboard. Resumed 2026-09-12 once the camera
module itself arrived. This file is the plan referenced (but never
actually written to disk) by that first session's devlog entry —
recreated and corrected here.

## Correction vs. the first survey

The 2026-08-28 survey recorded "SENSOR_RSTN = GPIOA2 active-low, MCLK
24MHz off the CAM0 PLL". That was wrong: it came from
`freertos/cvitek/hal/cv181x/config/cv181x_pinlist_swconfig.h`'s
`CAM_RST0__XGPIOA_2` — the **CV181X** pin map (Duo256M/DuoS's chip), not
this board's actual **CV1800B**. CV1800B's own pinlist
(`linux_5.10/drivers/pinctrl/cvitek/cv180x_pinlist_swconfig.h`) has no
`CAM_RST0` pad at all. Re-derived 2026-09-12 straight from Milk-V's own
published schematics instead of another chip's pin map — see
boards/duo/board.c3's own camera comment for the full sourcing
(`DUO_CAM_GC2083.pdf` for the module's FPC pinout,
`duo-schematic-v1.2.pdf` sheet "04 CV1800B PART1" for this board's own
wiring, cross-checked against the pinctrl driver's alt-function table).
Corrected pin map, all landing on the same 4 consecutive QFN68 balls:

| Signal      | QFN68 pin | Pad name      | Function      | funcsel (offset, value) |
|-------------|-----------|---------------|----------------|--------------------------|
| SENSOR_RSTN | 62        | PAD_MIPIRX1N  | XGPIOC[8]      | +0xec, 3 (GPIO)          |
| I2C_SDA     | 63        | PAD_MIPIRX1P  | IIC1_SDA       | +0xf0, 4                 |
| I2C_SCL     | 64        | PAD_MIPIRX0N  | IIC1_SCL       | +0xf4, 4                 |
| SENSOR_CLK  | 65        | PAD_MIPIRX0P  | CAM_MCLK0      | +0xf8, 4                 |

Sensor: I2C address 0x37 (7-bit), 16-bit register address / 8-bit data,
chip-ID 0x2083 at register 0x03f0/0x03f1 (Milk-V's own
`sensor_cfg_GC2083.ini`, `bus_id = 1` = I2C1 @ 0x04010000). Single fixed
mode 1920x1080p30 RAW10, 2-lane MIPI CSI-2, no sub-resolution mode.

## Sourcing split (the actual risk, unchanged from the first survey)

- **Open**: `gc2083_sensor_ctl.c`/`gc2083_cmos.c` (sensor control), and
  the FreeRTOS cv1835 CIF HAL (`cif_drv.c` + register-field headers) —
  base addresses match the CV1800B DTS, covering D-PHY RX + CSI-2
  decode.
- **Closed**: `cv180x_vi.ko`/`cvi_mipi_rx.ko` are prebuilt blobs. The
  `vi` block (`0x0A000000`, the ISP-FE/RAW/DMA-to-DRAM path — the only
  route from the CSI-MAC to DRAM, the CSI wrap has no DMA-address
  register of its own) has no source at all. The cv1835 VIP HAL
  (`isp_drv.c`: `ISP_DUMP_PRERAW`, `ispblk_dma_setaddr`,
  `ispblk_crop_config`) is the closest rosetta stone, but cv1835→cv1800b
  ISP-register parity is unverified.

This is still the go/no-go gate for stages 4-5 below — nothing here
resolves it, only the pin/register map underneath stages 0-3.

## Staged plan

0. ~~Sourcing spike~~ (done, see above) + **i2cd** (`user/i2c/i2cd.c3`,
   DesignWare I2C1 master, poll-only) — **done 2026-09-12**.
1. **DONE 2026-09-13 — sensor power/clock/reset + read chip-ID over
   I2C.** Power rails (AVDD28/DVDD/IOVDD) are fixed regulators tied
   directly to 3V3/1V8/2V8 (schematic sheet 3), not GPIO-controlled — no
   software action needed there. `camtest` (`user/bin/camtest.c3`)
   pulses SENSOR_RSTN low then high via gpiod, then reads the chip-ID
   register via i2cd.

   **Real-hardware-verified 2026-09-12, i2cd itself proven working —
   sensor doesn't ACK yet.** Three real, distinguishable failure modes
   were hit and fixed in turn (see docs/devlog.md for the full blow-by-
   blow): a missing `RST_I2C1` deassert (the actual transfer engine was
   dead — nothing before this project ever touches I2C1's own reset,
   unlike SD/USB/ETH which inherit an already-deasserted state from
   earlier boot stages), then a real bug in `i2c_xfer`'s own abort
   detection (checked `TX_ABRT` exactly once, immediately after writing
   each byte — too early for a NAK to have actually landed on the bus,
   turning a real NAK into a false timeout). With both fixed, `camtest`
   now correctly reports **NAK from address 0x37 — no ACK at all** —
   confirmed the camera module is physically seated, so this is real
   signal.

   **DONE — chip-ID = 0x2083, real hardware, repeatable.** The NAK
   above turned out to be i2cd's own bugs, not the sensor: (a) `IC_TAR`
   was being written while the controller was already enabled, which
   the DesignWare databook (and u-boot's own reference driver) says is
   ignored — every transfer before this was silently addressing
   whatever `IC_TAR` held at reset, never actually 0x37; fixed by
   disabling (properly polled, not just written and assumed), writing
   `IC_TAR`, re-enabling. (b) the first real transaction after that fix
   read back chip-ID as `0x2020` — not a fault: `0x20` is exactly
   0x2083's real high byte, the low-byte read just never advanced.
   The GC2083 datasheet's own "Single Register Reading" diagram shows
   one byte per transaction (write 2-byte address, restart, read 1
   byte) with no auto-increment on reads (only writes get that) —
   `camtest` now issues two separate single-byte reads instead of one
   combined write-2/read-2 transaction. MCLK (CAM_MCLK0 pinmux +
   clk_cam0 gate, reusing FSBL's own already-configured PLL/divider)
   and the `RST_VIPSYS` deassert added while chasing this both turned
   out unnecessary for I2C itself to work — kept anyway since they're
   correct per the real vendor U-Boot board-init table for this exact
   board (`cv1800b_milkv_duo_sd/u-boot/cvi_board_init.c`, which
   independently confirmed every pin choice bit-for-bit) and MCLK is
   still needed for actual sensor streaming later.
2. **DONE 2026-09-13 — full GC2083 mode register script.** `caminit`
   (`user/bin/caminit.c3`, new) writes all 135 registers of the vendor's
   own `gc2083_linear_1080p30_init()` (transcribed byte-for-byte from
   `gc2083_sensor_ctl.c`, diffed programmatically against the source to
   confirm an exact match — not retyped by eye) — 1920x1080p30 RAW10,
   2-lane MIPI. **PASS on real hardware, first attempt**: all 135
   writes succeeded, chip-ID still reads 0x2083 afterward, and the last
   register (0x023e) reads back exactly the value written (0x99),
   confirming writes actually land rather than just "every transfer
   returned OK". Streaming blind — no MIPI receiver involved yet,
   that's Stage 3.
3. **IN PROGRESS 2026-09-13 — CIF / D-PHY RX / CSI-2 RX bring-up.**
   `user/cif/cifd.c3` (new) + `user/bin/cifinit.c3` (new, chains
   camtest/caminit's own reset+chip-ID+mode-init then asks cifd for
   link status). First attempt used the FreeRTOS cv1835 CIF HAL
   (`cif_drv.c`, duo-buildroot-sdk) as a register reference, since its
   base addresses (0x0A0C2000/0x0A0D0000) matched CV1800B's own
   devicetree — wrongly extending that trust to the *internal* register
   layout too. Real hardware caught it: `CSI_GLB_CTL0`/lane-select
   writes at cv1835's own offsets read back unchanged no matter what
   was written, while the "power-down" register (right offset by
   coincidence) worked fine — an inconsistency code review alone
   couldn't resolve.

   Checking the SDK harder (at the user's explicit prompting, after a
   first "this needs hardware measurement" conclusion) turned up
   `milkv-duo/duo-files`' own **CV1800B-CV1801B Preliminary Datasheet**
   — a real 692-page register-level TRM, distinct from the short
   overview PDF fetched earlier, with CV1800B's actual register map
   (section 9.1.6 for the MAC, 9.2.5 for the PHY/CSI blocks). It is
   genuinely different from cv1835's at this block: lane-select lives
   at `+0x304`/`+0x308` (2-bit fields), not cv1835's `+0x028` (3-bit);
   `PD_IBIAS`/`PD_RXLP` are at bits 14/[21:16], not 26/[31:27]. Most
   importantly: **`SENSOR_MAC_MODE` is a 3-bit field where 0 means
   *Disable*, not CSI** — cv1835's own 2-bit encoding defaults to CSI at
   0, and the first attempt's own reasoning ("left at its 0 reset value
   = CSI", copied from the cv1835 driver's comment) was backwards for
   real CV1800B silicon. The whole MAC had been sitting disabled the
   entire first attempt, regardless of how correct anything else was.

   With the register map corrected against the real datasheet
   (`cifd.c3`'s own top comment has the full account) and re-verified
   on real hardware: every diagnostic readback now lands exactly where
   intended (`SENSOR_MAC_MODE=CSI`, `PD_CTRL` fully cleared, 2-lane
   enable set) — a real, confirmed improvement over the garbage/silent
   state before. `CSI_STATUS` (the MAC's own documented error/decode
   register) now reads a **clean** `0x00000000`: no ECC/CRC/word-count
   errors, but also no packet decoded yet either. Removing a
   speculative `gc2083_restart()` register sequence (tried mid-session,
   on the theory the sensor's mode-init table alone doesn't start
   streaming) made no difference either way — a clean negative result,
   since the vendor's own `gc2083_init()` never calls `restart()` either.

   **Not yet locked, and the investigation is exhausted for now.**
   Continued past the above with the same real datasheet: found that
   the earlier "leave lane-select at reset defaults" conclusion was
   itself based on misreading the *link1* (unused, `+0x600`) copy of
   the digital lane-config block — link0's real fields (`+0x304`/
   `+0x308`) are 3-bit, not 2-bit, with generic "identity" reset
   defaults (`d0<-1, d1<-2, ck<-0`) that don't already match this
   board's wiring. Corrected to the original schematic-derived mapping
   (`ck<-3, d0<-2, d1<-4`) at the *right* offsets this time — verified
   via readback, lands exactly as intended. Also split `cifd`'s analog-
   frontend enable (`cif_stream_enable`) out of its own boot-time static
   config into an on-demand step triggered only once the sensor is
   confirmed streaming (the reference driver's own `cif_config`/
   `cif_streaming` split, which this project's first pass had
   collapsed into one boot-time call) — on the theory that the D-PHY's
   internal calibration might need the sensor's clock lane already
   toggling to lock. Verified via the IPC reply itself, not this
   driver's own print output (which silently failed to reach the
   console from this specific call path — the same symptom `i2cd.c3`
   hit once already): the analog front end genuinely does power up
   correctly. Checked the calibration registers the overview table
   lists (`D0_REG_CTRL_CALIB_0/1` etc.) and read their bit-level
   description: manual/diagnostic self-test registers (PRBS9 or a
   fixed pattern, compared against a golden value) with a
   `calib_ignore` bit implying real-time calibration otherwise runs
   automatically in hardware — not a prerequisite this project's own
   register writes are missing.

   Every register found in the real CV1800B datasheet for this path is
   now verified correct via direct readback: MAC mode/enable/polarity,
   lane count, VS-gen mode, D-PHY analog power state, lane-select
   mapping (schematic-confirmed), and the CIF-specific reset lines
   (`RST_CSIPHY0`/`RST_CSIPHY0RST_APB`, confirmed genuinely deasserted
   via a non-degenerate register readback, unlike the clock-enable
   registers which read back `0xffffffff` regardless of the real bit
   state on this SoC). `CSI_STATUS` stays a clean `0x00000000`
   throughout — no errors, but no packet decoded either.

   **Round 2 (2026-09-13, same day, re-opened on explicit instruction
   not to stop at documentation review)**: found and fixed two more
   real, previously-untouched issues, then exhausted every remaining
   register-level and empirical lead without moving `CSI_STATUS` by a
   single bit:
   - Restructured `cifd.c3` so MAC_TOP/MAC_CSI/WRAP config runs
     together with the analog PD_IBIAS/RXLP/deskew enable, on-demand,
     in that exact order — matching the reference driver's real
     `cif_streaming()` (`cif_config()` immediately before
     `cif_stream_enable()`, every time, not config-once-at-boot). The
     first pass had only split out the analog dance.
   - Found and set `WRAP` global `REG_04`'s `reg_mipirx_sel_clk_channel`
     ([21:16], reset 0) — a one-hot **analog** clock-lane select,
     distinct from the per-link *digital* `WRAP_L0_CK_SEL` already set;
     inferred from 6 other clearly-per-physical-lane registers nearby
     (`REG_34-48`'s calibration results, `REG_80`'s AD clock inverse
     bits) and set to match physical lane 3.
   - Exhaustively swept all 8 clock/data0/data1 pn-swap combinations
     (`WRAP_L0_CK_SEL`'s own `reg_csi_lane_{ck,d0,d1}_pnswap` bits) —
     every one came back byte-for-byte identical (`0x00000000`).
   - Re-tried the GC2083's `gc2083_restart()` sequence (`0x03f9=0x42`,
     `0x03f7=0x11`, `0x03fc=0x8e`, `0x003e=0x91`) with the now-fully-
     corrected CIF driver — no change.
   - Verified MIPIMPLL (the PLL generating the D-PHY's own HS
     sampling/byte clock) directly via hardware readback: `CSR=
     0x05488101`, exactly FSBL's own programmed value
     (`fsbl/plat/cv180x/platform.c`'s `sys_pll_od()`/`sys_pll_nd()`,
     unconditional, on the same FSBL binary this project's reflash
     reuses unchanged), G2_STATUS busy bit clear. Confirmed not the
     problem, not just assumed.
   - Cross-checked the MAC_TOP register's full bit layout (9.1.6) and
     `CSI_STATUS`'s own full bit layout (9.2.5) against what the driver
     already does — no discrepancy found; both match exactly.

   **Round 3, same day**: took "use the real Linux driver, not just
   the datasheet" seriously and mined `u-boot-2021.10`'s real display
   driver + `linux_5.10`'s real clock driver for anything the TRM
   doesn't document. Found and fixed 3 more genuine clock/reset gates
   this way: `VIP_SYS` (`0x0A0C8000`, a whole register block absent
   from the TRM entirely, found via `vip_sys.c`'s own
   `vip_isp_clk_reset()`) gates `csi_mac0`'s clock+reset at a third
   tier below the SoC-level gates; `clk-cv180x.c` names two more
   `REG_CLK_EN_2` bits (`clk_csi_mac0_vip` bit 18, its parent
   `clk_axi_vip` bit 4) in the very register already in use, absent
   from the devicetree's own clock list. All three confirmed correctly
   set via hardware readback. **No change to `CSI_STATUS` from any of
   them.** (First VIP_SYS attempt, faithfully replaying the vendor's
   full axi+isp_top+csi_mac0/1 reset-toggle sequence, crashed cifd —
   narrowed to a plain csi_mac0-only set/clear, fixed the crash, still
   no functional change.)

   **Round 4, same day**: found and disassembled the actual compiled
   kernel module (`middleware/v2/cv180x/ko/cvi_mipi_rx.ko` — the real
   V4L2 driver's *source* is confirmed genuinely closed, only a
   Kconfig ships, but the compiled, unstripped `.ko` does). Corrected
   round 3's own framing: `clk_axi_vip` wasn't running slow (6-8MHz) —
   reading the real `clk_ops` mux-index table showed mux=0 is actually
   `clk_mipimpll` (900MHz), so the divider (already 3, i.e. ÷4) was
   already giving ~225MHz. What round 3 actually fixed was that this
   whole clock domain was **fully gated off (0Hz)**, not slow — a
   stronger, cleaner result. GC2083's own real `.mac_clk = RX_MAC_CLK_
   200M` confirms 225MHz is the right ballpark. Found the long-sought
   HS-settle register (`WRAP_LINK0_BASE+0x10`, in the datasheet's own
   undocumented `REG_0C`→`REG_20` gap) via `cif_set_hs_settle`'s
   disassembly — but confirmed, from GC2083's own real attribute struct
   never setting its `dphy.enable` field, that the real driver does
   **not** configure it for this sensor. Ruled out with high confidence
   for an otherwise-undocumented register.

   Thirteen total hardware configurations tested across rounds 2-4 (8
   pn-swap + sensor-restart + 4 clock/gate fixes), all producing the
   exact same `0x00000000`. Every avenue any of 4 independent real
   sources (TRM, FreeRTOS HAL, U-Boot driver, Linux clock driver) plus
   the actual compiled production kernel module's disassembly offers
   has now been checked — this is the genuine limit of static-analysis
   debugging, not a paused-early conclusion. That invariance is itself the diagnostic
   signal: the MAC's packet decoder appears to never see any lane
   activity at all, not a polarity or protocol-config mismatch (either
   of those would be expected to at least flip an ECC/CRC error bit on
   *some* combination). This points at something outside what a
   register-level datasheet can diagnose — most likely a physical-layer
   problem specific to this third-party GC2083 breakout (bad
   solder/FPC contact, or a lane/clock physical-pin mapping that
   doesn't match Milk-V's own official module's `sensor_cfg_GC2083.ini`
   this session derived the wiring from) — genuinely needing a
   multimeter continuity check against the schematic, an oscilloscope/
   logic analyzer on the physical lines, or a known-good module to
   swap in for comparison. Fallback finish line (Stage 3, error-free
   lane sync) if Stage 4's go/no-go gate says no — not reached yet,
   paused here for now on physical-hardware-measurement grounds, not
   as a documentation-search stopping point.
4. `vi` raw dump — one RAW10 frame to a file, host-side debayer. The
   risky stage; gated on actually being able to drive the closed `vi`
   block correctly (see sourcing split above).
5. `camd` service + `capture` tool + double-buffered continuous
   capture.

## Infra this plan needed / needs

- `HAS_CAMERA` board flag + `I2C1_MMIO_BASE`/`I2C_CLOCK_PAGE` — done.
- `i2cd` as its own driver process (one-owner-per-real-device, same
  split as sdd/usbd/ethd/gpiod) — done.
- GPIOC8 added to gpiod's allowlist for SENSOR_RSTN — done.
- Still needed for stage 4+: a large **contiguous, uncached** DMA frame
  buffer (~633 pages for one packed RAW10 1920x1080 frame) — this
  project's usb/eth DMA buffers are all single-page, so the multi-page-
  contiguous-allocation path itself may need work; a cache flush /
  uncached mapping (see [[racccoon_dma_coherency]] on real hardware).
- No QEMU camera model — this whole feature is real-Duo-only from stage
  1 on, which breaks the project's usual verify-on-both-targets cadence
  (see [[racccoon_feature_cadence]]). Every stage's actual verification
  has to happen on the real board.
