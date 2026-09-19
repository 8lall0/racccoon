# Orange Pi RV (StarFive JH7110) port — bring-up plan

Status: **Stage 0 (scaffold) done.** Branch `opi-rv-port`. Nothing has
run on hardware — the board isn't in hand yet. This doc is the staged
plan; it mirrors how the Milk-V Duo port was sequenced (a `board`
module seam first, then one peripheral at a time, each verified before
the next).

> **CORRECTION 2026-09-19 — the "flaky SD probe" below was the wrong device.**
> The microSD slot is **`mmc 1`** (sdio1, `0x16020000`, PLIC IRQ 75), not
> `mmc 0`. `mmc 0` is sdio0 @ `0x16010000`, the AP6256 Wi-Fi's SDIO — not an SD
> card, so U-Boot's `Card did not respond to voltage select! : -110` for it is
> expected noise, not a bug. A vendor-Debian boot log shows the distro boot
> reading `/extlinux/extlinux.conf`, `/uInitrd`, `/Image` and the dtb from
> `MMC1` at ~21 MiB/s. Everything below that blames a "known upstream U-Boot
> dw_mmc voltage-switch bug", the ground-loop/isolator experiments, and the
> USB-mass-storage workaround was chasing that misreading (mainline
> `jh7110-orangepi-rv.dts` had it right all along: `&mmc0` carries the Wi-Fi,
> `&mmc1` has `cd-gpios`). The real fix for booting without USB is just
> `load mmc 1:1 ...`. **It works, unattended (2026-09-19):** the vendor U-Boot
> imports `/vf2_uEnv.txt` from the boot partition and runs its `boot2`
> variable, so `boards/opi-rv/vf2_uEnv.txt` (`boot2=load mmc 1:1 ...
> kernel_opi.bin; go 0x40200000`) starts racccoon before the Linux boot is
> tried; `scripts/flash_opi.sh` installs it. (`boot.scr` is never run by this
> chain — it dies on `"distro_boot_env_test" not defined` — so the old
> `boot.cmd` was removed.) The historical text is left as written for the record. Still true: `bootelf` on the ELF
> crashes in this U-Boot (use the raw `.bin` + `go`), and OpenSBI's legacy
> `console_getchar` bug is separate and unaffected.

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
| Storage | Synopsys DW-MSHC (`snps,dw-mshc` / `starfive,jh7110-mmc`): `mmc0`/sdio0 `0x16010000` = **Wi-Fi** SDIO (IRQ 74); `mmc1`/sdio1 `0x16020000` = **the microSD slot** (IRQ 75, cd-gpio 41) |
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
prompt. No filesystem (an empty `board::DEVICES` table), so this is purely:
BSS clear → trap vector → `plic_init` → FPU enable → timer interrupts →
idle + echod + shell processes → cooperative scheduler → prompt.

- Get the kernel onto the SD card's boot partition next to the vendor image,
  load + run from U-Boot: `load mmc 1:1 0x40200000 kernel_opi.bin ; go
  0x40200000` (**corrected 2026-09-19**: the microSD is `mmc 1` = sdio1
  `0x16020000`; `mmc 0` is the Wi-Fi's SDIO. `bootelf` on the ELF crashes
  this U-Boot, hence the raw `.bin` + `go`).
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
  by design). Empty `DEVICES` table, same as the opi-rv scaffold.
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
  - **Tested 2026-09-13 with the serial isolator** (the same device
    verified working on the Milk-V Duo earlier that session): inserted
    inline between the USB-serial adapter and the board's UART, GND
    included through the isolator rather than direct. Result: **9
    consecutive `mmc dev 0` failures**, identical `-110` signature,
    across 2 independent fresh cold power-cycles plus in-session
    retries — no improvement. This weakens the ground-loop/noise-
    coupling theory (an isolator should have broken that specific
    coupling path if it were the cause) and points back toward this
    being the documented upstream dw_mmc voltage-switch bug itself
    (fixed in U-Boot ≥2025.01), independent of the serial adapter.
    `mmc dev 1` (a different, non-SD device — likely the AP6256 WiFi's
    SDIO) continues to probe fine in the same sessions, confirming the
    controller/bus itself isn't universally broken, just this
    specific card-voltage-switch sequence on `mmc dev 0`.
  - A web search (2026-09-13) found this is a known, currently
    **unresolved upstream U-Boot bug**, reproduced on VisionFive2 (same
    JH7110) with multiple different SD cards, on both v2026.07 and
    v2026.07-rc4 — so a newer U-Boot would *not* have fixed it either;
    good to know before ever reconsidering a firmware reflash. The same
    report names a real workaround: **booting via USB mass storage
    works fine** — sidesteps the SD controller's specific voltage-
    switch bug entirely rather than fixing it.

**USB mass storage boot — unblocked Stage 1, 2026-09-13.** This
board's U-Boot has a working XHCI/USB stack (`usb start` finds storage
devices fine); loaded `kernel_opi.elf`/`kernel_opi.bin` off a USB-
adapter'd SD card (`usb part` showed a GPT `bootfs` partition,
`fatload`-equivalent `load usb 0:1 ...` works) instead of `mmc dev 0`.

- `bootelf 0x40200000` on the ELF **crashed inside U-Boot itself**
  (`Unhandled exception: Load access fault`, fault address inside
  U-Boot's own relocated image, board watchdog-reset itself) — a real
  `bootelf`+ELF compatibility bug in this vendor U-Boot build, first
  time ever attempted on real hardware. Not pursued further; sidestep
  it instead.
- `load usb 0:1 0x40200000 kernel_opi.bin` + `go 0x40200000` (the raw
  binary + direct jump, `build_opi.sh`'s own documented fallback)
  **works** — this is now the real, working load path for this board,
  not `bootelf`. Update any future instructions/scripts accordingly.

**First-ever real hardware boot — hit a real, previously-latent kernel
bug** (`scause=6`, store/AMO address misaligned, `sd ra,0(sp)` — the
very first instruction of `kernel_entry`, right after `csrrw sp,
sscratch, sp`): `sscratch`'s computed value (`(uptr)&next.stack +
STACK_SIZE`, in `process.c3`'s own `switch_context` call site) is
exactly `&next + sizeof(Process)` — the next array element's own start
address in the `procs[]` table, a struct/array boundary with **no
alignment guarantee of its own** (`stack` is a trailing `char[]` field
after a long run of mixed-size fields; nothing enforces its own start
address land on an 8-byte boundary, only that `sizeof(Process)` does).
Whether the resulting address happens to come out aligned is pure luck
of where the linker places `procs[]` in BSS — the opi-rv-qemu build's
different link address (`0x80200000` vs opi-rv's `0x40200000`) shifted
overall layout enough to land aligned there and not on the real board;
same source, same struct layout, no earlier build (including the
QEMU harness that supposedly validated this exact boot path) ever
caught it. Two more call sites computed the same "top of `.stack`"
value the same unguarded way (`process.c3`'s `create_process`,
`entry.c3`'s `rfork`) — fixed all three by masking to a 16-byte
boundary (`& ~(uptr)15`) at each computation; `kernel.c3`'s own
`boot_trap_stack` anchor got the same defensive treatment even though
it hadn't been caught misaligned yet. Regression-checked: QEMU `virt`,
`opi-rv-qemu` (still boots clean to `root / #`), and the Duo build all
still boot/link unchanged.

**Result after the fix: `root / #` on real Orange Pi RV hardware for
the first time ever.** Boots clean through BSS clear → trap handler →
idle/procd/envd/shell creation → SMP hart-1 detection → shell prompt.

**New, separate, real hardware quirk found immediately after**: this
board's specific OpenSBI firmware build prints `sbi_ecall_handler:
Invalid error N for ext=0x2 func=0x0` (N = the ASCII value of the
character just read) for **every legacy `sbi_console_getchar()` call
that returns an actual character** — i.e. once per keystroke, on the
same shared UART our own console output uses. The characters
themselves are read correctly (the logged N values spell out exactly
what was typed), so this isn't a bug in `sbi::__getchar()` — it's
OpenSBI's own firmware being unexpectedly chatty about extension 0x2's
completely normal legacy behavior (returning the char via a0 directly,
not the standard {error,value} pair legacy calls don't use). Typing a
longer string (a full `echo ...` command) over the noisy link appears
to have dropped some later characters before the shell even saw them
(consistent with the M-mode firmware's own blocking UART print for
each spam line stealing enough real time that a small hardware RX FIFO
overruns) — after that, the shell accepted further Enter presses
(each newline was correctly read, per the same spam trail) but never
printed any command output or a fresh prompt. **Not yet root-caused —
picked up next.** Worth checking: does the shell echo input at all on
this platform (no echoed characters were seen distinct from OpenSBI's
own diagnostic lines), and does a short, single-character-at-a-time
input sequence (avoiding whatever dropped characters in the longer
string) behave differently.
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

#### Firmware upgrade attempt (2026-09-14) — set aside, real recovery procedure proven along the way

User's own plan: fix the OpenSBI legacy-`console_getchar` bug (see
above) by upgrading firmware from a running, trusted Linux environment
rather than risky blind `sf write` at the U-Boot prompt. Booted the
standard vendor Debian image via the same USB-mass-storage path
(`sysboot usb 0:1 any 0x44000000 /extlinux/extlinux.conf` once
`extlinux.conf` is confirmed present — no need to rename anything on
this particular card). `apt` has no live upgrade path for
`linux-u-boot-orangepirv-current` (a local-only package, only a frozen
2022 debian-ports snapshot repo configured, no network on the board
anyway). Board's SPI NOR is 3 real MTD partitions confirmed via
`/proc/mtd`: `mtd0`="spl" (256K, DRAM training — never touched),
`mtd1`="uboot" (3M, OpenSBI+U-Boot FIT image — the only one touched),
`mtd2`="data" (1M). Backed up the original working `mtd1` first (raw
`dd`, verified via md5sum, kept on the PC) before touching anything.

**Found mainline U-Boot has real upstream support for
`xunlong,orangepi-rv`** (same `starfive_visionfive2_defconfig` binary
as VisionFive2 — only the devicetree filename differs, and that only
matters for the Linux kernel later, not for U-Boot/OpenSBI itself) and
a real, working recovery path: this board has 3 physical buttons
("uart boot", "flash", "power" — found by asking, not guessing;
"flash" alone does nothing, only **"uart boot" + power** enters JH7110
Mask ROM UART/X-modem recovery, `(C)StarFive` banner then continuous
`C` bytes at 115200). `lrzsz`'s `sx -X` got continuous NAKs from this
receiver for unknown reasons; a from-scratch ~100-line Python
XMODEM-CRC sender worked where it didn't (128-byte blocks, CRC16-CCITT
poly 0x1021, 0x1A padding — not saved to the repo, recreate if ever
needed). The *specific*, documented recovery bootstrap matters: the
newer "devkits" variant produced total silence; the older, exactly
`jh7110-recovery-20221205.bin` (from `github.com/starfive-tech/Tools`
`recovery/`) works and shows the documented menu (`0`=SPL-in-flash,
`2`=uboot-in-flash, `5`=exit).

**Three build/flash attempts, three identical crashes, firmware
upgrade set aside for now:**
1. Unpinned latest-HEAD OpenSBI + latest-HEAD U-Boot →
   `Unhandled exception: Load access fault` inside OpenSBI/U-Boot
   itself, crash-loop, `EPC` reloc-adjusted to `0x4023d882`,
   `TVAL` a mangled/sign-extended-looking address. Hypothesis: OpenSBI
   version skew (docs.u-boot.org pins `OpenSBI v1.7` specifically for
   this defconfig).
2. Rebuilt with OpenSBI **exactly v1.7** as documented, same U-Boot —
   **identical crash, same `EPC`.** Ruled out the version-skew
   hypothesis.
3. Same OpenSBI v1.7, U-Boot rebuilt with `CONFIG_DEFAULT_DEVICE_TREE`
   switched to the real `starfive/jh7110-orangepi-rv` (confirmed
   already present in `CONFIG_OF_LIST`, i.e. the upstream board-support
   patch has landed in current mainline U-Boot) instead of
   VisionFive2's default — **identical crash again, same `EPC`.** Ruled
   out the devicetree-mismatch hypothesis too.

Real remaining hypothesis, not yet tested: **`mtd0` (SPL) was never
touched, in any of the 3 attempts** — every build used the *original
2021-era vendor SPL* to load a *U-Boot-proper built from today's
mainline source*. The SPL→U-Boot-proper handoff (FIT image parsing,
load addresses, board-init expectations) isn't a stable ABI across
years of drift; this vendor SPL and mainline U-Boot-proper may simply
not be able to talk to each other, regardless of which U-Boot-proper
config is used. Fixing that would mean *also* rebuilding and flashing
SPL — a materially higher-risk operation (bad SPL affects DRAM
training itself, and could make even the proven recovery path harder
to use) — **not attempted, set aside deliberately with the user rather
than pursued further this session.**

**Recovered successfully all 3 times** using the procedure above
(restore the backed-up original `mtd1` via the same recovery menu) —
confirmed via the exact original vendor boot banner (`U-Boot SPL
2021.10-orangepi (Oct 24 2024 - 20:33:18 +0800)`, `OpenSBI v1.2`, same
EEPROM info) reappearing each time. **Board is back to its original,
fully working state** as of session end — same OpenSBI getchar bug
still present (never fixed), same SD-probe bug still present (never
attempted), but not bricked. This 3x-proven recovery procedure is
itself the most valuable output of this sub-arc if firmware work is
ever resumed: the physical button combo, the specific recovery binary,
and a working from-scratch XMODEM sender are all now known-good.

Next step if resumed: either build a *matching* SPL from the same
mainline source (and flash `mtd0` too, accepting the higher risk with
the now-proven recovery path as a safety net), or drop the firmware
route entirely in favor of the software workaround already identified
(read UART0's raw 16550 registers directly for input, bypassing the
buggy legacy SBI `console_getchar` call in racccoon's own kernel —
zero firmware risk, works regardless of vendor SPL/U-Boot vintage).

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

DT-sourced facts already in the file (**corrected 2026-09-19 to mmc1 / sdio1,
the microSD; the first draft used mmc0, the Wi-Fi**): base `0x16020000`, PLIC
IRQ 75, `fifo-depth` 32, `fifo-watermark-aligned`, sys_syscon sample-phase
field `<0x13030000 + 0x9c, shift 1, mask 0x3e>`.

Build integration when ready: `scripts/build_opi{,_qemu}.sh` rebuild
`sdd` from `dw_mshc.c3 + sdd.c3` (a 1-line `build_user_program`
override) before the link step; add the `"sd"` entry to
`board::DEVICES` (see below).

Reference sources used (all fetched 2026-09-09):
- U-Boot `include/dwmmc.h`, `drivers/mmc/dw_mmc.c` (generic core).
- Linux `drivers/mmc/host/dw_mmc-starfive.c` (JH7110 phase/tuning).
- Linux mainline `arch/riscv/boot/dts/starfive/jh7110.dtsi` `mmc@…`.

Then: add an `"sd"` entry to `boards/opi-rv/board.c3`'s `DEVICES` table
(`src/device.c3`) — the controller's MMIO page plus the syscrg
clock/reset, sysreg-syscon and pinmux pages, its PLIC source, and one
uncached DMA region for the IDMAC descriptor ring. `kernel_main` then
spawns `sdd` on its own; no kernel code changes.
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
