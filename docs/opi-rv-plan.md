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
  U-Boot: `load mmc 1:1 0x40200000 kernel_opi.elf ; bootelf 0x40200000`.
- Verify against the four open questions above (console, hart/context,
  `rdtime`, and that the vendor U-Boot's `bootelf` really does jump in
  S-mode — it should; U-Boot proper on JH7110 runs S-mode under
  OpenSBI).
- Success = the `1: BSS cleared` … `4: Idle configured` boot prints and
  a `root / #` prompt that echoes input.

Testable at this stage (no fs needed): `echo`, pipes, brace/glob
expansion, `ns`, `ping` (IPC to echod), and — with
`OPI_TEST_SHELL=1` — `maptest` (SYS_MAP), `hungservertest` (supervisor
respawn of a wedged echod), `mutextest`/`threadtest`.

### Stage 2 — timer + traps under load

Confirm the forced-preemption timer tick, `handle_trap`, and a
userspace fault (`faulttest`) all behave — same in-kernel machinery the
Duo needed a real look at even though QEMU was green. Still no fs.

### Stage 3 — storage: the DW-MSHC SD driver

The big one. A new driver (`user/block/dw_mshc.c3`?) for the Synopsys
DesignWare Mobile Storage Host Controller — **not** reusable from the
Duo's `user/block/sdhci.c3` (Cvitek SDHCI, a different register model).

Sources, in order of trustworthiness:
- VisionFive 2 U-Boot: `drivers/mmc/dw_mmc.c` + `drivers/mmc/
  starfive_dwmmc.c` (the SoC glue: CIU/BIU clocks, the syscon phase
  registers, card-detect).
- Linux `drivers/mmc/host/dw_mmc.c` + `dw_mmc-starfive.c`.
- JH7110 devicetree `mmc0`/`mmc1` nodes for the exact reg ranges, the
  clock/reset handles, and `fifo-depth` / `data-addr`.

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
