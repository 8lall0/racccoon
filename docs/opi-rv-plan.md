# Orange Pi RV (StarFive JH7110) port — bring-up plan

Status: **Stage 0 (scaffold) done.** Branch `opi-rv-port`. Nothing has
run on hardware — the board isn't in hand yet. This doc is the staged
plan; it mirrors how the Milk-V Duo port was sequenced (a `board`
module seam first, then one peripheral at a time, each verified before
the next).

## The board

Orange Pi RV = **StarFive JH7110** SoC (same as VisionFive 2, Star64,
Milk-V Mars — so mainline Linux + U-Boot and the VisionFive 2 BSP all
apply):

| | |
|---|---|
| Cores | 4× SiFive U74-MC (RV64GC) application harts 1–4, + 1× SiFive S7 "monitor" core = hart 0 |
| DRAM base | `0x40000000` (variants: 1 / 2 / 4 / 8 GiB) |
| Interrupt controller | stock SiFive PLIC @ `0x0c000000`, `riscv,ndev = 136` |
| Timebase | 4 MHz (`timebase-frequency = <4000000>`) |
| Debug UART | UART0 (8250/DW-APB) @ `0x10000000` |
| Firmware | U-Boot SPL → OpenSBI (fw_dynamic, M-mode) → U-Boot proper (S-mode) → distro |
| Storage | Synopsys DW-MSHC (`snps,dw-mshc` / `starfive,jh7110-mmc`), sdio0 `0x16010000`, sdio1 `0x16020000` |
| Ethernet | 2× `starfive,jh7110-dwmac` (Synopsys DWMAC 5.20), gmac0 `0x16030000`, gmac1 `0x16040000`, **external** PHY on the RJ45 |
| USB | Cadence USBSS-DRD (`cdns,usb3`) @ `0x10100000` |
| Pinctrl / GPIO | `starfive,jh7110-sys-pinctrl` @ `0x13040000` |

### What makes it *easier* than the Duo

- SiFive U74 is a plain RV64GC core — **no T-Head MAEE PTE-attribute
  quirk**. `PTE_EXTRA_BITS`/`PTE_DEVICE_BITS` are 0, exactly like QEMU.
  The single hardest part of the Duo bring-up (the PLIC interrupt storm
  from weakly-ordered MMIO) cannot happen here.
- Stock SiFive PLIC at the same address QEMU uses — the register
  formulas in `boards/qemu/board.c3` are reused verbatim.
- Mainline-quality documentation and a huge body of existing driver
  code for every peripheral.

### What makes it *harder*

- **Multi-hart SoC.** Hart 0 is the S7 with only an M-mode PLIC
  context; the U74s are harts 1–4. The S-mode PLIC context of the hart
  racccoon runs on is `2 * hartid`, i.e. **2** if firmware hands off on
  hart 1 (as VisionFive 2 does). `boards/opi-rv/board.c3` sets
  `PLIC_S_CONTEXT = 2` — **the #1 thing to verify on first boot.**
- Every peripheral is a *different controller* from the Duo's: DW-MSHC
  not Cvitek SDHCI, Cadence USB not DWC2, StarFive-wrapped DWMAC with an
  external PHY not a SoC-internal one. Each needs its own driver;
  `user/net/dwmac.c3` is a partial head start for Ethernet only.

## Open questions to resolve on / before first boot

**Update 2026-09-09: #1–#3 retired in emulation** by the QEMU `sifive_u`
harness (see Stage 1 below). #1 also independently confirmed on the real
board — OpenSBI's own banner said `Boot HART ID: 1`. #4 still open.

1. **Boot hart** → `PLIC_S_CONTEXT`. Does the Orange Pi RV's OpenSBI
   hand the S-mode payload to hart 1? (`csrr` mhartid isn't reachable
   from S-mode; check the a0 U-Boot passes, or just try context 2 and
   fall back to 4/6/8.)
2. **`rdtime` in S-mode** — native on the U74, or trap-and-emulate by
   OpenSBI? `arm_timer()` already uses the SBI `set_timer` call (not a
   direct `stimecmp` write — that was a Duo lesson), so only the *read*
   side matters. If `rdtime` faults, the fix is an SBI/`time`-CSR shim
   in the `board` module.
3. **SBI console actually wired to UART0?** If `sbi::__putchar`
   produces nothing but the boot otherwise looks alive, drop in a raw
   16550 driver behind `board::console_putchar/getchar` (UART0 is a
   stock 8250, reg-shift 2, reg-io-width 4).
4. **Smallest RAM variant** we care about → raise `__free_ram_end` in
   `boards/opi-rv/kernel.ld` from the conservative flat 64 MiB.

## Stages

### Stage 0 — scaffold — **DONE**

- `boards/opi-rv/board.c3` — full `board` contract. JH7110 PLIC /
  timebase / console filled in; every peripheral flag `false`; SD / USB
  / GPIO / ETH addresses are `0` stubs (honest "not sourced yet", same
  convention `boards/qemu/board.c3` uses for its absent hardware).
- `boards/opi-rv/kernel.ld` — link at `0x40200000` (DRAM_BASE + 2 MiB),
  flat 64 MiB `free_ram` window.
- `project.json` — `racccoon-opi` target.
- `scripts/build_opi.sh` — builds `build/kernel_opi.elf` (+ `.bin`).
  No firmware packaging; load from the vendor U-Boot.
- Builds clean; QEMU + Duo builds unaffected.

### Stage 1 — first boot to the shell

Goal: `build_opi.sh` output boots over serial to the embedded shell
prompt. No filesystem (`HAS_BLOCK_DEVICE = false`), so this is purely:
BSS clear → trap vector → `plic_init` → FPU enable → timer interrupts →
idle + echod + shell processes → cooperative scheduler → prompt.

- Get the ELF onto an SD card next to the vendor image, load + run from
  U-Boot: `load mmc 0:1 0x40200000 kernel_opi.elf ; bootelf 0x40200000`
  (device 0 = `sdio0@16010000`, confirmed the real SD slot on this
  board — device 1 has no partition, likely the onboard AP6256 WiFi's
  SDIO interface, not a second card slot).
- Verify against the four open questions above (console, hart/context,
  `rdtime`, and that the vendor U-Boot's `bootelf` really does jump in
  S-mode — it should; U-Boot proper on JH7110 runs S-mode under
  OpenSBI).
- Success = the `1: BSS cleared` … `4: Idle configured` boot prints and
  a `root / #` prompt that echoes input.

#### QEMU `sifive_u` verification harness (added 2026-09-09)

Because the real board is SD-probe blocked (below), Stage 1 + Stage 2
were brought up in emulation first. QEMU's `-machine sifive_u` is the
closest proxy: a SiFive core complex with an S-mode-less monitor hart 0
and application harts 1..N — the same split as the JH7110's S7 + U74s,
and the only QEMU machine that exercises what `virt` cannot (boot hart
!= 0, PLIC S-context 2).

- `boards/opi-rv-qemu/` — a deliberate near-duplicate of
  `boards/opi-rv/`, differing only in `TIMEBASE_HZ` (sifive_u DT says
  1 MHz, JH7110 says 4 MHz) and the link address (`kernel.ld`,
  0x80200000 not 0x40200000 — so this ELF is **not** hardware-loadable,
  by design). `HAS_BLOCK_DEVICE = false`, same as the opi-rv scaffold.
- `scripts/build_opi_qemu.sh` (→ `build/kernel_opi_qemu.elf`,
  `OPI_TEST_SHELL=1` for the killtest/faulttest dev shell) +
  `scripts/launch_opi_qemu.sh` (`-machine sifive_u -smp 2`, no U-Boot,
  QEMU's own `-kernel`). Target `racccoon-opi-qemu` in `project.json`.

**Result: boots clean to `root / #`.** OpenSBI reports `Boot HART ID:
1`; the kernel now prints `SMP: boot hart 1 only`. That retires three
of the four open questions above before the board is unblocked:
  1. **Boot hart / PLIC S-context** — verified. `PLIC_S_CONTEXT = 2` is
     correct for a hart-1 boot; timer + external interrupts fire.
  2. **`rdtime` in S-mode** — native on the U54, no OpenSBI trap needed.
  3. **SBI console** — wired (DBCN + legacy path), no raw 16550 needed.
Stage 2 machinery also verified here: `faulttest` (a userspace fault
kills just that process, kernel + shell survive), `maptest`,
`hungservertest` (supervisor kills + respawns a wedged echod).

Three real bugs the harness surfaced that no existing board could
(all boot on hart 0), fixed this session:
  - **`boot_hartid` always read as 0.** `boot()` stashed a0 (the boot
    hart id) into `boot_hartid_raw`, which lives in `.bss` — and
    `kernel_main`'s first act is to zero `.bss`, wiping it right back.
    Invisible on any hart-0 boot; wrong on the JH7110 (boots on hart 1).
    Fix: carry a0 as `kernel_main`'s parameter, write the global after
    the clear (`src/kernel.c3`, `src/smp.c3`).
  - **`smp_start_secondaries()` poked the S7 monitor.** With
    `board::SMP_MAX_HARTS = 1` (both shipping boards) and a boot hart
    != 0, the start loop fell through to `sbi_hart_start(0)` — the
    JH7110's S7, an explicit non-target. Guarded with `max > 1`
    (`src/smp.c3`).
  - **Production shell's boot delays were raw tick counts.**
    `shell_boot_settle(150e6)` and the `shell_login` fs probe
    (`+250e6`) assumed ~25 MHz: 150 s / 250 s on the 1 MHz sifive_u,
    37 s / 62 s on the real 4 MHz JH7110. Switched to
    `timebase_hz() * seconds`, the idiom `shell_test.c3` already uses
    (`user/shell.c3`, `user/shell_common.c3`, `user/shell_test.c3`).

Regression-checked: QEMU `virt` and the Duo build both still boot / link
unchanged. This harness stays useful past Stage 1 — any kernel change
touching the boot path, traps, or the scheduler can be shaken out here
in seconds instead of on the scarce, half-flaky real board.

**Board arrived 2026-09-08. Status: BLOCKED on a flaky SD-card probe,
not yet reached racccoon's own boot output.** Findings, in case this is
picked up in a later session:

- OpenSBI's own banner confirms **Boot HART ID: 1** on this real board,
  matching the plan's assumption — `PLIC_S_CONTEXT = 2` in
  `boards/opi-rv/board.c3` needs no change once SD access is unblocked.
- Rebasing the Stage 0 scaffold onto master surfaced two real gaps the
  branch predated (fixed, commit `09133d6`): `board.c3` was missing
  `SMP_MAX_HARTS` / `EXEC_MAX_IMAGE_SIZE` / `HEAP_MAX_BYTES` /
  `PLIC_*_PHYS_PAGE`, and `kernel.ld`'s `.text.boot` was missing
  `.text.boot.entry` — the ordering fix from the SMP Stage C1 work
  (see [[racccoon_text_boot_ordering]]). Without it this board would
  have silently jumped into `secondary_entry` instead of `boot()` on
  first hardware boot. Caught before ever touching hardware.
- **The actual blocker**: the vendor U-Boot (`2021.10-orangepi`, built
  Oct 2024) hits `Card did not respond to voltage select! : -110` on
  the SD (`mmc dev 0`) roughly half the time, both on its own automatic
  `distro_bootcmd` probe and on a manual retry — this is a documented,
  known JH7110/VisionFive2 vendor U-Boot bug (dw_mmc voltage-switch
  flakiness), reportedly fixed upstream in U-Boot ≥2025.01. Confirmed
  NOT specific to our kernel file or FAT32 writes — a fresh `dd`
  reflash of the untouched vendor image hit the identical failure
  signature on its very first cold boot.
  - Reflashing the board's SPI NOR U-Boot/OpenSBI firmware would likely
    fix this, but was **not done**: no verified, Orange-Pi-RV-specific
    firmware source was found (only generic StarFive VisionFive2
    images from a different vendor board), and a mismatched SPL risks
    a hard brick (JH7110 SPL bakes in per-board DRAM training
    parameters). This also directly contradicts this port's own
    non-goal below ("no SPL/OpenSBI surgery") — reconsider deliberately
    if ever revisited, don't do it as a side effect of chasing this bug.
  - The user separately observed the failure correlates with whether
    the USB-serial adapter's GND pin is connected (connected → fails;
    disconnected → boots, but then there's no console). Consistent
    with a ground-loop / noise-coupling theory (adapter ground
    perturbing the SD controller's sensitive 1.8V switch), but not
    conclusively proven deterministic in a single A/B trial — same
    outlet/strip and a different USB port / GND pin didn't fix it.
    Next thing to try: a different (ideally galvanically isolated)
    USB-serial adapter.
- **Software workaround staged, ready regardless of the adapter fix**:
  `boards/opi-rv/boot.cmd` → `mkimage`'d into `boot.scr`, deployed to
  the SD boot partition root, with `/boot/extlinux/extlinux.conf`
  renamed to `.conf.bak` so U-Boot's `scan_dev_for_boot` macro falls
  through past the vendor's Linux extlinux entry to this script instead
  (`scan_dev_for_extlinux` before `scan_dev_for_scripts` in
  `distro_bootcmd`). This removes the human-reaction-time race of
  manually catching the U-Boot prompt to type `load`/`bootelf` — once
  the SD probe succeeds (whatever fixes that), it loads and jumps into
  `kernel_opi.elf` fully unattended. **Not yet verified end-to-end**
  (never got a clean SD probe after deploying it) — this is the very
  next thing to check once a boot succeeds.
- To revert the SD card to normal vendor Debian boot:
  `sudo mv /boot/extlinux/extlinux.conf.bak /boot/extlinux/extlinux.conf`
  (leaving `boot.scr` in place is harmless — extlinux.conf is tried
  first and wins).

Testable at this stage (no fs needed): `echo`, pipes, brace/glob
expansion, `ns`, `ping` (IPC to echod), and — with
`OPI_TEST_SHELL=1` — `maptest` (SYS_MAP), `hungservertest` (supervisor
respawn of a wedged echod), `mutextest`/`threadtest`.

### Stage 2 — timer + traps under load

Confirm the forced-preemption timer tick, `handle_trap`, and a
userspace fault (`faulttest`) all behave — same in-kernel machinery the
Duo needed a real look at even though QEMU was green. Still no fs.

### Stage 3 — storage: the DW-MSHC SD driver

The big one. A new driver, `user/block/dw_mshc.c3`, for the Synopsys
DesignWare Mobile Storage Host Controller — **not** reusable from the
Duo's `user/block/sdhci.c3` (Cvitek SDHCI, a different register model).

**A first draft exists (2026-09-09), NEVER RUN — no hardware, no QEMU
model of the JH7110 SD block.** It compiles and links cleanly as a
drop-in for `sdhci.c3` (`sdd.c3` + `dw_mshc.c3` → a valid `sdd` binary;
`sdd.c3` needs zero changes — `dw_mshc.c3` re-exports the four names it
calls). What the draft has: the full DW-MSHC register map (verbatim
from U-Boot `include/dwmmc.h`), the "update clock registers only"
sequence, `dw_send_cmd` (CMDARG + CMD/START, poll RINTSTS for CDONE,
RTO/RCRC/RE handling, RESP0–3), the SD spec enumeration (copied
verb-for-verb from `sdd_enumerate()`), and a PIO single-block read/write
via the `DWMCI_DATA` FIFO with RINTSTS/STATUS-count polling. What it
does **not** have, in order of bring-up priority:
  1. IDMAC/DMA — PIO only (like `sdhci.c3`'s fallback).
  2. JH7110 syscrg clock/reset bring-up — `dw_mshc_soc_init()` is a
     near-no-op on the assumption U-Boot already left SDIO0's biu/ciu
     clocks ungated (it loads the kernel off this same card — same
     reasoning `sdhci.c3` uses for the Duo's BootROM). If wrong: the
     syscrg (`0x13020000`) SDIO0 gate/deassert bits, and `DW_CIU_HZ`
     (assumed 50 MHz parent) → `DW_CLKDIV_*`.
  3. Card-detect, >1-bit bus, high-speed/tuning — all skipped, SD
     default-speed 1-bit only.
  4. `DWMCI_DATA` offset is VERID-gated (0x200 for ≥ 0x240A; StarFive is
     0x270A) — `dw_reg_verid_check()` asserts it at init.

DT-sourced facts already in the file: base `0x16010000`, PLIC IRQ 74,
`fifo-depth` 32, `fifo-watermark-aligned`, sys_syscon sample-phase field
`<0x13030000 + 0x14, shift 26, mask 0x7c000000>`.

Build integration when ready: `scripts/build_opi{,_qemu}.sh` rebuild
`sdd` from `dw_mshc.c3 + sdd.c3` (a 1-line `build_user_program`
override) before the link step; flip `board::HAS_BLOCK_DEVICE` +
`HAS_SD_BLOCK`.

Reference sources used (all fetched 2026-09-09):
- U-Boot `include/dwmmc.h`, `drivers/mmc/dw_mmc.c` (generic core).
- Linux `drivers/mmc/host/dw_mmc-starfive.c` (JH7110 phase/tuning).
- Linux mainline `arch/riscv/boot/dts/starfive/jh7110.dtsi` `mmc@…`.

Then: `board::HAS_BLOCK_DEVICE = true` + `HAS_SD_BLOCK = true`, fill
`SD_MMIO_BASE` and any pinmux/clock pages, wire `setup_sdd_mappings`.
Find the ext2 root partition's start sector with `sfdisk`/`lsblk` on the
real card → `FS_PARTITION_START_SECTOR`.

Once SD reads work, the **entire existing test battery becomes
runnable** by populating an SD card the way `scripts/populate_duo_bin.sh`
does for the Duo (a `populate_opi_bin.sh` sibling): the libc stage
tests, `tcctest` + tcc self-host, `wasmtest`, `dirpacktest`,
`bigwritetest`, the killtests, `p9fstest`, etc.

### Stage 4 — Ethernet (StarFive DWMAC + external PHY)

`user/net/dwmac.c3` already targets the DesignWare MAC core for the
Duo — the MAC register layout is shared. New work: the StarFive syscon
glue (PHY interface mode, delay lines, `starfive,jh7110-dwmac` clocks/
resets) and driving a real external PHY chip over MDIO (the Orange Pi RV
has a discrete PHY on the RJ45, unlike the Duo's SoC-internal EPHY —
so `user/net/ephy.c3` does *not* apply; a generic MDIO/clause-22 PHY
bring-up does). Unblocks §6 (real 9P) with a hardware transport.

### Stage 5 — USB (Cadence USBSS-DRD)

New driver for `cdns,usb3`. No overlap with the Duo's DWC2. Lower
priority — do it when HID/MSC on this board is actually wanted.

### Stage 6 — GPIO (`jh7110-sys-pinctrl`)

New driver for the StarFive pinctrl/GPIO block. Small; do it last or
on demand.

## Non-goals for this port

- SMP (racccoon is single-hart by design — the other 3 U74s stay
  parked, same stance as the Duo's second C906).
- The S7 monitor core (hart 0) — never a racccoon target.
- Replacing the vendor firmware chain. racccoon loads as an S-mode
  payload from the stock U-Boot; no SPL/OpenSBI surgery.
