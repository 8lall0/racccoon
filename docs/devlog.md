# Racccoon devlog

Running log of work sessions with Claude Code. Newest entry on top.

---

## 2026-08-22 (71) — Directory refactor step 5 (last one): `sdd.c3` split into `sdhci.c3`/`sdd.c3`

Final step of the refactor plan started in entry 68. `sdd.c3` (894
lines) mixed the standard SDHCI register/PIO layer (pad/power/clock
bring-up, SD command issuing, block PIO transfer — genuinely spec-
level, not Duo-specific except for the base addresses and the vendor
pad/PHY registers) with the driver's own orchestration (`main()`'s IPC
request loop). Split, same shape as the `usbd.c3`/`ethd.c3` splits
before it:

- `user/block/sdhci.c3`: every `SD_*` SDHCI register/bit constant,
  `mmio_read32`/`write32`, `sd_reg_read`/`write` and friends
  (`top_reg_*`/`pinmux_reg_*`/`clock_reg_*`), `sdd_pad_power_clock_init()`,
  `sd_send_cmd()`, `sdd_raise_clock()`, `sdd_enumerate()`,
  `sdd_block_rw()`. Also `SDD_VERBOSE` and `print_hex32` — moved here
  rather than staying in `sdd.c3`, matching the precedent the `usbd.c3`
  split already set (`USBD_VERBOSE` lives in `dwc2.c3`, not `usbd.c3`).
- `user/block/sdd.c3`: `main()`, `sdd_init()`, `sdd_panic()`, and the
  DISKD_READ/WRITE wire-protocol constants only.

Pure code motion, no logic changes. Real hardware verification: the
full `sdd` boot sequence (`clock_stable=1`, CMD0/CMD8/ACMD41/CMD2/
CMD3/CMD7 all succeeding, `raised clock`, `card ready`) came back
byte-identical to pre-split, and `fsd: ext2 mounted, block_size=4096
inode_table_block=67` already proves real block reads work end to end
through the new `sdhci.c3` (mounting requires reading the superblock/
inode table via `sdd_block_rw`) — `usbd`/`ethd` (same shared kernel
image) unaffected too.

This closes out the user-space directory refactor started in entry
68: `user/` is now `bin/`/`sys/`/`fs/`/`block/`/`net/`/`usb/`, every
driver that had grown large enough to blur "talks to the wire" vs.
"decides what to do next" (`usbd`, `ethd`, `sdd`) has been split
accordingly, and the shared `virtio.c3`/`main_stub.c3` pieces are
factored out where real duplication existed. No further steps planned
from that original plan.

## 2026-08-22 (70) — Directory refactor step 4: `ethd.c3` split into `dwmac.c3`/`ephy.c3`/`ethd.c3`

Continuation of entry 68's refactor plan. `ethd.c3` (673 lines) had
three genuinely distinct layers tangled into one file: generic DW
MAC/MDIO register access, this board's own Cvitek embedded-PHY analog
bring-up, and the orchestration deciding when to call either. Split
into three, same shape as the earlier `usbd.c3` → `dwc2.c3`/`usbd.c3`
split (entry 68):

- `user/net/dwmac.c3`: `ETH_MAC_*`/`ETH_MII_*`/standard IEEE 802.3
  `MII_*` constants, `mmio_read32`/`write32`, `mac_reg_read`/`write`,
  `mdio_read`/`write`/`wait_ready`, `eth_us_to_ticks`. The layer any
  other real DW-MAC board could reuse unchanged.
- `user/net/ephy.c3`: everything Cvitek-embedded-PHY-specific —
  `ETH_PHY_*`/`ETH_CLK_*`/`ETH_LED_*`/`ETH_SD1_*`/`ETH_EFUSE_*`
  constants, `phy_reg_read`/`write`/`clk_reg_*`/`led_pinmux_write`/
  `sd1_selphy_write`/`efuse0_read`/`efuse1_read`, `eth_phy_init()`,
  `eth_phy_led_pinmux()`, and the ~200-line `eth_phy_analog_init()`
  (the faithful `cv182xa_ephy_init()` translation).
- `user/net/ethd.c3`: `main()` and `ethd_init()`'s own sequencing
  only.

One real lesson from this split specifically (didn't come up in the
USB split, since `dwc2.c3` was the only register-level file there):
`dwmac.c3` and `ephy.c3` are both `module user;` — same module, no
import needed for cross-file visibility — which means a raw
`mmio_read32`/`write32` genuinely can't be duplicated in both files
the way `usb_us_to_ticks`-style helpers safely are duplicated across
*different* modules elsewhere in this codebase (e.g. `virtio.c3` vs.
`dwc2.c3` each having their own copy) — same-module duplicate function
*definitions* are a real compile error ("would shadow a previous
declaration"), not just untidy. Fixed by defining `mmio_read32`/
`write32` once in `dwmac.c3` and having `ephy.c3` call them directly,
same as `eth_us_to_ticks` already had to.

Pure code motion, no logic changes — verified byte-identical real-
hardware behavior before and after: full PHY bring-up sequence, MDIO
scan finding the PHY at address 0, BMCR fixup, and live link-up/
link-down sensing, plus `usbd`'s own hub enumeration (same shared
kernel image) unaffected.

Step 5 (`sdd.c3` → `sdhci.c3`/`sdd.c3`) is the last one in the
original refactor plan, still pending.

## 2026-08-22 (69) — Idiomatic argc/argv, following on from `main()` (entry 68)

Direct follow-up to entry 68's `@main_no_args` addition: the c3 spec's
own entry-point section also defines `fn void main(String[] args)` as
the idiomatic args-taking form (`MAIN_TYPE_ARGS` in the compiler's own
`sema_decls.c`), backed by a second forwarding macro, `@main_args`.

Every real stdlib version of that macro heap-allocates its `String[]`
(`mem::alloc_array`/`free`) — no allocator exists in this freestanding
build, so `lib/std/_nolibc/main_stub.c3` (8lall0/c3c fork) gets a
fixed-size static-array version instead (32 entries, matching the
convention the old `argv_storage` mechanism it replaces already used).

One real bug caught before it shipped, not just a mechanical
translation: the compiler's synthetic wrapper declares `argv` as a
genuine `char**` (the standard C-ABI type), but racccoon's own
`SYS_EXEC` doesn't actually hand off a real pointer array — `user.c3`'s
own `exec()` packs argv as a single NUL-separated blob ("foo\0bar\0"),
the only encoding that survives being copied as flat bytes into a
freshly exec'd process's address space. `@main_args` reinterprets the
`char**` as that blob's raw base address and walks it sequentially,
not `argv[i]`-indexes it — verified by first testing the naive
(wrong) `argv[i]` version in isolation, confirming it does NOT match
this project's own wire format on inspection, before it ever touched
a real racccoon file.

Converted every real consumer (`cat`/`ls`/`mv`/`mkdir`/`write`/`rm`/
`echod` — 7 files) from the old `char** argv; int argc = get_argv(&argv);`
pattern to plain `fn void main(String[] args)`. Two of them got
genuinely simpler in the process: `write.c3` and `echod.c3` both used
to hand-scan for a NUL terminator to get a string's length; `args[i].len`
replaces that outright. With every consumer converted, the old
`exec_argc`/`exec_argv_blob`/`argv_storage`/`get_argv()` machinery in
`user.c3` was genuinely dead — removed, and `start()` simplified
(`a0`/`a1` now pass straight through as `main()`'s real parameters,
instead of being stashed into globals first).

Verified end to end, not just "it compiles": a `write`→`cat` round
trip on real content, `ls` before/after `mv`/`rm`, and `argvtest`'s
own IPC-reply check — first scripted against QEMU (a real bug in the
test harness itself surfaced here too: `shell.c3`'s own input loop
only recognizes `\r` as line-end, not `\n` — a `\n`-only test harness
just accumulates characters silently forever instead of ever
dispatching a command), then the identical sequence on real Duo
hardware against ext2 (case-preserving, unlike FAT32 — `f.txt`/`g.txt`
stayed lowercase there, a nice independent confirmation the real
argv content survived intact).

## 2026-08-22 (68) — User-space directory refactor (steps 1-3), and an idiomatic `main()`

Two related pieces of housekeeping, both pure behavior-preserving
changes verified on real Duo hardware, not new features.

### Directory refactor: splitting drivers from orchestration

`user/` had grown to 17 files flat in one directory, and two drivers
in particular — `usbd.c3` (1209 lines) and (a later step) `ethd.c3`
(671 lines) — mixed hardware-register-level code with process-level
orchestration so thoroughly that finding "the part that talks to the
wire" versus "the part that decides what to do next" required reading
the whole file.

Rather than reach for C3's real `interface`+`@dynamic` support (C3
does have it — confirmed in the stdlib's own `logging.c3`/`alloc.c3`
— a struct declares `(InterfaceName)` and marks methods `@dynamic`),
this replicates `fsd.c3`'s own already-proven "generic core / backend
split": plain files in subdirectories, all still `module user;` (no
nested submodules, no import needed for same-module cross-file
visibility — just the directory as a human-navigation aid, matching
`user/fs/fat32.c3`/`ext2.c3`'s own precedent exactly). Introducing
dynamic dispatch would be designing for a hypothetical second USB/
Ethernet backend that doesn't exist yet; the seam is clean to
formalize into a real interface later if one ever does.

New layout: `user/bin/` (cat/ls/mkdir/mv/rm/write), `user/sys/`
(echod/procd/envd), `user/fs/` (fsd joins fat32/ext2), `user/block/`
(diskd/sdd), `user/net/` (netd/ethd), `user/usb/` (usbd). `user.c3`/
`shell.c3`/the new `virtio.c3` stay top-level.

New shared file `user/virtio.c3`: `diskd.c3` and `netd.c3` had already
near-verbatim duplicated the legacy virtio-mmio (version 1) transport
layer — magic/version/status/queue-setup register offsets, the
virtqueue struct shapes, raw MMIO read/write helpers — from `netd.c3`
being written by copying `diskd.c3`'s own pattern earlier this
session. Real, already-existing duplication, not speculative DRY.
Extracted the generic parts (base-address-parameterized
`virtio_reg_read32`/`write32`/etc.); each driver keeps its own
device-specific pieces (`VIRTIO_BLK_PADDR`/`Virtio_blk_req` for
diskd, `VIRTIO_NET_PADDR`/`VIRTIO_NET_F_STATUS` for netd).

`usbd.c3` split into `user/usb/dwc2.c3` (every `USB_*` register/bit
constant, the host-channel transfer engine, the USB/hub-class request
builders — the "how") and a much smaller `user/usb/usbd.c3` (just
`main()` and `usb_enumerate_device()` — the "what"). Pure code
motion, no logic changes.

Verified: QEMU regression clean at every step (all processes created,
`netd: link up`, FAT32 mounted). Since QEMU has no DWC2 equivalent at
all, `usbd` itself is only ever exercised on real hardware — flashed
the Duo and confirmed the exact same enumeration as before the split
(hub `vid=0x05e3 pid=0x0610`, 4 ports, correct per-port status).

Steps 4 (`ethd.c3` → `dwmac.c3`/`ephy.c3`/`ethd.c3`) and 5 (`sdd.c3`
→ `sdhci.c3`/`sdd.c3`) are planned but not yet done.

### An idiomatic `main()`, via a small addition to the c3c fork's stdlib

Every user-mode binary's `main()` was declared `fn void main()
@export("main")`, needed because `scripts/build_user.sh` compiles with
`--no-entry` (required since `--use-stdlib=no` means the compiler's
own standard main-wrapping has no forwarding macro to find). Under
`--no-entry`, the compiler registers whatever function is literally
named `main` without ever auto-exporting it under an unmangled linker
name the way it does in the normal (non-`--no-entry`) path — so every
single program needed the `@export("main")` boilerplate repeated by
hand, purely to satisfy `user.c3`'s own hand-written `_start`
(`call main`).

Traced this down to `sema_analyse_main_function()` in the compiler's
own `sema_decls.c` (8lall0/c3c fork) — genuinely fixable there, but a
compiler-internals patch felt like the wrong tool for what's really a
missing library piece: the real stdlib already solves this exact
problem for hosted builds via `std::core::main_stub`'s `@main_no_args`
macro (`lib/std/core/private/main_stub.c3`) — the compiler looks this
up *by name* when it sees a plain `fn void main()`, and generates a
real, standard, properly-exported `int main(int, char**)` wrapper
around it automatically. Racccoon's `--use-stdlib=no` build just never
had that macro anywhere reachable.

Added `lib/std/_nolibc/main_stub.c3` to the fork (sibling to the
existing `mem.c3`/`atomic.c3`/`fmt.c3`, same `@feat(RACCCOON)` gating)
providing a minimal freestanding `@main_no_args` — just `#m(); return
0;`, no args-forwarding machinery a freestanding target has no use
for. Removed `--no-entry` from `build_user.sh`, added the new file to
every binary's source list, and every `fn void main()` across all 16
racccoon files now just `import std::nolibc::main_stub;` and drops
`@export("main")` entirely — the compiler generates and exports the
real `main` symbol itself, confirmed via `nm` (`T main`, calling into
the mangled `user.main`), exactly like any standard hosted C3 program.

Verified: QEMU regression byte-for-byte identical to the pre-change
baseline. Real Duo hardware: full boot sequence clean across all 7
processes (sdd/fsd/procd/envd/shell/usbd/ethd), `usbd` enumeration
still exactly correct, and `ethd` showed `link up` this round —
possibly the first real external-carrier confirmation since the
`cv182xa_ephy_init()` fix (entry 67); worth an explicit `ip link`
check on the peer side to confirm.

## 2026-08-22 (67) — Ethernet Phase 1: MAC+PHY bring-up, real analog link sensing confirmed live

New feature area, mirroring USB's own Phase 1 scope: bring the MAC and
its PHY up, confirm link status, no packet TX/RX yet. Two targets,
mutually exclusive like diskd/sdd: `user/netd.c3` (QEMU, virtio-net on
the same virtio-mmio bus virtio-blk already uses) and `user/ethd.c3`
(Duo, the real on-chip Ethernet MAC — a genuinely standard, widely-
documented Synopsys DesignWare/"stmmac" core wrapped by the vendor's
own `cvitek,ethernet` devicetree compatible string, confirmed via the
real devicetree's own `snps,*`/`clock-names="stmmaceth"` properties,
not proprietary despite the vendor string).

### netd (QEMU) — worked first try

Legacy virtio-mmio (version 1), same register layout `diskd.c3`
already established. Real feature negotiation this time (unlike
diskd's own simplified skip-it-entirely approach): reads
`HostFeatures`, negotiates `VIRTIO_NET_F_STATUS` specifically, since
the device-config `status` field is only meaningful once that bit is
actually accepted. Configures both RX and TX virtqueues (virtio-net's
own spec requires both before `DRIVER_OK`, even though Phase 1 doesn't
push anything through them yet). First real hardware round: correct
MAC (`52:54:00:12:34:56`, QEMU's own well-known default), feature
negotiated, link up — no debugging needed at all.

### ethd (Duo) — a long chase, resolved

The MAC itself (register offsets/DMA descriptor format from U-Boot's
own `drivers/net/designware.c/.h`) needed no debugging — Phase 1 never
touches its DMA engine at all (MDIO is plain register access through
`miiaddr`/`miidata`, independent of the datapath). The embedded PHY
was the real chase: U-Boot's own `board_init()` calls
`cv180x_ephy_id_init()` unconditionally on real ASIC hardware
(previously read during USB Phase 1 research and dismissed as
irrelevant then), and this driver initially replicated exactly that —
clock enables (`REG_CLK_EN_0` bits 25/26, same clock-controller page
USB already maps), the exact register sequence, byte-for-byte.

Result: PLL genuinely locked, `BMCR` read back completely healthy
(auto-negotiation enabled, no power-down, no isolate), MDIO fully
functional, MAC address/RX/TX configured — and **zero link ever
detected by three independent peer devices** (two separate ports on
the user's own machine, plus a router) across many real-hardware
rounds. Ruled out, in order: cable (swapped), port (swapped), Linux-
side config (`enp2s0` already administratively up — `NO-CARRIER` is a
passive hardware report, nothing to "activate"), `BMCR` power-down/
isolate (already clear), PLL lock (read back directly, genuinely
locked). Every register-level fact available from `cv180x_ephy_id_init()`
checked out healthy; the symptom pattern (working digital control
plane, zero real analog output) pointed toward something the partial
sequence never covered at all.

**Root cause**: `cv180x_ephy_id_init()` was only ever a *subset* of
this exact PHY's real bring-up. U-Boot ships a genuinely separate,
dedicated PHY driver, `drivers/net/phy/cvitek.c`
(`cv182xa_ephy_init()`, called from the real PHY framework's own
`.config` callback) — found only by finally reading a file that had
shown up in an initial directory listing early in this session's own
Ethernet research but was never actually opened. Its own source
comments mark the parts overlapping `cv180x_ephy_id_init()` as
`/* do this in board.c */` and skip them — confirming the two were
always meant to run together, board.c first. Everything else in that
file had never been touched by this driver at all: efuse-based analog
trim (TX bias current, echo cancellation, TX/RX termination), MLT-3
line-coding phase tables (the actual 100BASE-TX signal encoding),
**link-pulse waveform shape** (the literal analog signal a peer PHY
recognizes as "something is connected" — the leading hypothesis for
the whole symptom), TP_IDLE and 10BaseT tables, LPF/HPF filter
coefficients (CV180X/"phobos" branch specifically — the source also
has a separate CV181X branch this board doesn't need), and two
registers never written before at all: a genuine "start auto-
negotiation" trigger (`0x03009800=0x090e`, distinct from board.c's own
`0x0906`) and a force-full-duplex bit. Replicated faithfully as
`eth_phy_analog_init()` — including a real redundant re-run of the
ANA_PD/ANA_EN release the source itself repeats, not "cleaned up" away
even though it looks unnecessary on paper, since matching the proven
flow exactly mattered more here than tidiness.

**Result**: genuine, live, physically-responsive link sensing —
confirmed by unplugging the cable mid-run and watching `ethd` print
`link down`, then `link up` again on replugging. Not a stuck false
positive; real analog activity. **Still open**: no peer device has yet
confirmed carrier from the Duo's side (the user's own laptop still
shows `NO-CARRIER` on both cable and port swaps) — a router test,
which may be more tolerant of whatever's still not fully spec-
compliant about the generated signal, is planned but not yet run.
Genuine, meaningful progress either way: from "completely inert,
unclear why" to "sourced from the real, complete vendor PHY driver,
demonstrably responding to real physical state" — worth committing
even with the peer-link question still open, rather than sitting on
uncommitted work indefinitely.

### Verification

QEMU: `netd` correct end to end, shell/diskd/fsd unaffected. Duo:
`ethd`'s own diagnostics all confirm healthy state (PLL locked, BMCR
clean, clocks enabled with readback verification, MAC address set),
live link-up/link-down transitions confirmed via physical unplug/
replug. `usbd` (Phase 1+2) continues working unaffected alongside it —
confirmed hub port detection still correct in the same boot.

**Files changed:** `src/entry.c3` (`SYS_NETD_INFO`), `src/process.c3`
(`ethd_pid`/`netd_pid`/`netd_rxq_paddr`/`netd_txq_paddr`,
`setup_ethd_mappings`, `setup_netd_mappings`), `src/kernel.c3` (spawn
logic), `boards/duo/board.c3` / `boards/qemu/board.c3` (`ETH_*`/
`VIRTIO_NET_*` constants), `user/user.c3` (`netd_info()`),
`user/ethd.c3` (new), `user/netd.c3` (new), `scripts/launch64*.sh`
(virtio-net device), `scripts/build_user.sh`/`build.sh`/`build_duo.sh`.

Also, separately: quieted `usbd`'s own logging (`USBD_VERBOSE`, off by
default) — the periodic raw `HPRT0` dumps and per-transfer `SETUP`
byte prints were necessary while actively debugging DWC2 bring-up and
enumeration, not useful day to day, and were making Ethernet's own
console output hard to read during this session's testing.

---

## 2026-08-22 (66) — USB Phase 2 confirmed working: real device detected on a real hub port

Entry 65's own Phase 2 code got its first real hardware test this
morning — it did not work on the first try, or the second, or the
third, but four real bugs found and fixed in sequence got it all the
way to a genuine, physical confirmation: `hub port 2: connected`, a
real USB device correctly identified on the exact downstream port of
the Duo IO board's own hub it was actually plugged into. Full chain
now verified real: DWC2 host-mode bring-up (entry 64) -> control
transfers over host channel 0 -> device enumeration -> hub
configuration -> per-port power-on -> per-port connect status,
end to end, no simulation, no assumption left unverified.

### The four bugs, in the order they were found

**1. Cache-incoherent DMA buffer** (the big one). `usbd`'s own DMA
buffer (entry 65's `setup_usbd_mappings`) used `map_page()` — the same
call `diskd`'s virtqueue uses — which marks the mapping cacheable
(`board::PTE_EXTRA_BITS`, `SHARE|CACHE|BUF`). Correct for ordinary RAM
the CPU alone touches; wrong for a buffer a *separate bus master* (the
DWC2 core's own DMA engine) also reads directly, since a CPU write can
sit in a cache line indefinitely without ever reaching real RAM.
`diskd`'s own precedent turned out to be a false one: it only ever
runs against QEMU's software-emulated virtio-mmio, which just reads
the guest's memory buffer directly — no real incoherency exists to hit
there at all. `usbd` is the first driver in this project's history
doing genuine DMA against real hardware, and it hit this immediately:
every control transfer's SETUP stage reported success, but the
following DATA stage STALLed, byte-identical (`HCINT=0x0000000a`),
completely unaffected by every other real, well-reasoned fix tried
first (bootstrap MPS0 switched to the USB-2.0-spec-mandated 64 for
high-speed devices, an explicit `HCSPLT=0` write, a 2ms inter-stage
settle delay) — the signature of the actually-transmitted bytes
silently differing from what this driver's own debug prints, reading
the original stack buffer rather than the DMA buffer, had been
trusted as confirming correct. Fixed by switching to
`map_device_page()` (uncached) for this one allocation — everything
else about the DMA-buffer pattern (identity-mapped, physical address
handed back via `SYS_USBD_INFO`) stayed exactly as entry 65 built it.

**2. Missing `SET_CONFIGURATION`**. Device and hub-class descriptor
reads both succeeded even in the unconfigured "Address" state (USB 2.0
spec allows `GetHubDescriptor` there), but `GetPortStatus` doesn't —
STALLed identically on all 4 ports until a `SET_CONFIGURATION(1)`
request was added between the hub descriptor fetch and the per-port
status loop. Hardcoded to configuration 1 (this driver never fetches
the configuration descriptor at all — basic hubs essentially always
have exactly one).

**3. Missing per-port `PORT_POWER`**. With enumeration otherwise fully
working, every port reported "empty" despite a real device being
plugged in before boot — an unpowered port does no connect detection
at all, regardless of what's attached, until the host explicitly
issues `SetPortFeature(PORT_POWER)` for it (a real, spec-mandated step
for hubs with per-port power switching, which this Genesys Logic
GL850/852-family hub — real vendor ID `0x05e3`, confirmed via its own
correctly-decoded device descriptor — implements). Fixed by powering
every port before querying status, then waiting the hub's own
specified `bPwrOn2PwrGood` settle time (hub descriptor byte 5, 2ms
units, floored at 20ms) before trusting any port status read.

**4. (Non-bug, confirmed along the way)** `HPRT0.PRTSPD` read 0
(high-speed) once a real reset actually ran against a real device —
this hub genuinely negotiates HS. Tried switching the bootstrap MPS0
from the traditional "always 8, full/low-speed only" trick to the
USB-2.0-spec-mandated fixed 64 for high-speed devices; didn't change
the outcome on its own (bug #1 was still blocking everything at that
point) but is spec-correct and stayed in.

### Verification

Real Duo hardware, IO board attached, a real USB device plugged into
one of the hub's 4 downstream ports before power-on: full enumeration
trace clean end to end — `bMaxPacketSize0=64`, `SET_ADDRESS`,
`vid=0x05e3 pid=0x0610` (correct, real Genesys Logic hub IDs),
`SET_CONFIGURATION`, hub descriptor (`4 ports`), all 4 `PORT_POWER`
requests, and finally `hub port 2: connected` — the exact port the
device was actually plugged into, the other three correctly reporting
empty. QEMU unaffected (`HAS_USB=false`, this code never runs there).

**Files changed this entry:** `src/process.c3` (`map_device_page()`
for the DMA buffer instead of `map_page()`), `user/usbd.c3`
(`usb_set_configuration()`, `usb_set_port_feature()`, the per-port
power-on step, the high-speed bootstrap-MPS0 fix, and the diagnostic
prints — SETUP byte dump, per-stage failure labels, raw `HCINT` on
error — that made finding all of the above possible).

Not yet committed, alongside entry 65's own work — both land together
once the user reviews the full diff.

---

## 2026-08-22 (65) — USB Phase 2: device enumeration over host channel 0 (implemented, NOT yet hardware-verified)

Written and built (QEMU + Duo, both clean) autonomously overnight,
after entry 64's own Phase 1 confirmed real hot-plug detection but
also confirmed the user's physical test rig (the Duo's official
USB&Ethernet IO board) has an onboard hub, meaning `HPRT0` can only
ever see that hub's own connection — never a downstream device — until
this driver can actually enumerate the hub itself and poll its
individual ports. **This entry's own code has not been run against
real hardware at all** — every other USB entry this session needed a
human to physically power-cycle the Duo and paste back the console log
each round, and that loop wasn't available while writing this. Treat
everything below as a well-reasoned first attempt, not a verified
result — the honest, first real test is whatever happens the next time
someone boots this and a connect event reaches `usb_enumerate_device()`.

### Design

Control transfers over DWC2 host channel 0 only (no split
transactions — every device this driver enumerates directly, the
IO board's own hub included, is full-speed and directly on the root
port from the DWC2 core's own point of view). Sourced from U-Boot's
own `chunk_msg()`/`_submit_control_msg()`/`wait_for_chhltd()`
(`duo-buildroot-sdk`'s `u-boot-2021.10/drivers/usb/host/dwc2.c`) —
register offsets for `struct dwc2_hc_regs` (channel 0 base `0x500`,
`HCCHAR`/`HCSPLT`/`HCINT`/`HCINTMSK`/`HCTSIZ`/`HCDMA`), not guessed.

**DMA buffer**: the DWC2 core (already configured for `DMAENABLE` in
Phase 1's `GAHBCFG` write) needs a real physical address for transfer
data — `usbd`, like any user-mode process, has no way to learn its own
virtual pages' physical backing. Solved with the exact same pattern
`diskd`'s virtqueue already established: `setup_usbd_mappings`
(`process.c3`) allocates one page via `alloc_pages(1)`, identity-maps
it into `usbd`'s own page table, and hands the physical address back
via a new syscall (`SYS_USBD_INFO`, 28 — same shape as
`SYS_DISKD_INFO`).

**Transfer engine** (`user/usbd.c3`): `hc_transfer_once()` programs
`HCTSIZ`/`HCDMA`/`HCCHAR`, sets `CHEN`, and polls `HCINT` for
`CHHLTD` (yield()-paced, 2s timeout) — returns 0 (`XFERCOMP`), 1
(`NAK`/`FRMOVRUN` — completely normal, caller retries), or -1 (real
error). `usb_control_transfer()` builds the standard 3-stage SETUP ->
DATA -> STATUS sequence on top of it, with a 3-second wall-clock NAK-retry
budget per stage (this driver's own established `rdtime()`-based
budget idiom, not a raw iteration count). Control endpoints always
restart their data toggle at DATA1 after a SETUP stage regardless of
any previous transfer's own final state, so no per-endpoint toggle
tracking was needed — a real simplification bulk/interrupt transfers
won't get to keep.

**Enumeration flow** (`usb_enumerate_device()`, called from `main()`'s
own polling loop the moment a real connect event fires — not at init
time, matching entry 64's own lesson about false-positive latches from
an unconditional reset against noise): 50ms bus-reset pulse + a full
1-second settle (matching U-Boot's `dwc2_init_common()` own comment
about "problematic USB keys" exactly, rather than trimming an untested
value) -> `GET_DESCRIPTOR(8)` at the default address to learn
`bMaxPacketSize0` -> `SET_ADDRESS(1)` -> `GET_DESCRIPTOR(18)` at the
new address for the full device descriptor -> if `bDeviceClass ==
0x09` (hub, the expected case here), `GET_DESCRIPTOR` for the
class-specific hub descriptor, then `GET_PORT_STATUS` on every
downstream port, printing connected/empty per port.

**Verification**: QEMU (`HAS_USB=false`, this code never runs there,
confirms only that the kernel-side additions — `SYS_USBD_INFO`,
`usbd_dma_paddr`, the new `setup_usbd_mappings` allocation — don't
disturb anything else) and Duo both build clean. No real-hardware run
yet at all — this is the pending work for whenever the user is back at
the physical board.

**Files changed:** `src/entry.c3` (`SYS_USBD_INFO`), `src/process.c3`
(`usbd_dma_paddr`, DMA page allocation in `setup_usbd_mappings`),
`user/user.c3` (`usbd_info()`), `user/usbd.c3` (the transfer engine
and enumeration flow).

Not committed — same standing rule as always, and doubly so here:
this is real, untested protocol-level code, not just a register tweak.

---

## 2026-08-22 (64) — USB Phase 1: DWC2 host-mode bring-up, real on the Duo

Goal: bring the Duo's actual USB host controller (Synopsys DesignWare
USB2 OTG, "DWC2", at `0x04340000`) into host mode and get
`HPRT0.PRTCONNSTS` to genuinely react to a device plugging in — Phase 1
of the USB mass-storage roadmap (entry 63's `SYS_NS_MOUNT_WAIT` was
Phase 0). Real-hardware-only; QEMU's `virt` machine has no DWC2
equivalent, so there's no dev-loop here — every iteration is a full
build+flash+power-cycle round trip on the real Duo. This ended up being
by far the longest single bring-up in this project's history —
somewhere north of twenty real-hardware round trips — and the final
root causes were genuinely subtle enough that no amount of *reading*
the register reference tables would have found them; it took finding
and diffing against the actual vendor kernel driver.

### The other bug this surfaced: `usbd` breaks the boot-time shell

Before any USB register work mattered at all, the shell stopped
appearing at boot the moment `usbd` was spawned — a real scheduler bug,
not a USB bug. `kernel_main` runs as `idle_proc` itself and creates
every boot-time server sequentially without ever yielding; the shell
has always been created lazily, inside `idle_proc`'s own final
`for(;;)` loop, only once nothing else is `PROC_RUNNABLE`. Every prior
boot-time server eventually reaches a genuine `SYS_IPC_RECV`-driven
`PROC_BLOCKED` state, and each one's own blocking call hands control to
the next-created server in the chain — a "cascading yield()" that,
once the last server blocks, falls back to `idle_proc`, which then
notices nothing is runnable and creates the shell. `usbd` is the first
process in this project's history that never genuinely blocks — it
only polls hardware and calls `yield()`, staying `PROC_RUNNABLE`
forever — which permanently breaks the cascade once it's scheduled,
since `idle_proc` (where shell-creation lives) can never be reached
again via the round-robin scan. Fixed by moving shell creation to be
explicit in `kernel.c3`, right after `envd` and before `usbd`'s own
spawn, instead of relying on the lazy fallback. Also added `SYS_YIELD`
(syscall 27, a plain unconditional `yield()`) for `usbd`'s own
busy-wait loops — not the actual fix, but a real correctness
improvement kept anyway.

### Register facts confirmed, in the order that mattered

Every fix below is sourced from real files in the local
`duo-buildroot-sdk` checkout, not guessed — but the session's own
research process is worth recording, because several plausible-looking
leads turned out to be dead ends, and the two fixes that actually
mattered were found only by escalating from "read the datasheet" to
"read U-Boot" to "read the real vendor Linux driver and its own
shipped rootfs scripts."

**Baseline bring-up** (all correct, none of this was the bug): PHY
reference clocks `clk_125m_usb`/`clk_33k_usb`/`clk_12m_usb`
(`REG_CLK_EN_1` bits 30/31, `REG_CLK_EN_2` bit 0 — sourced from the
Linux clock driver, since the datasheet's own table lists those bits
as "Reserved"); `RST_USB` toggle (`REG_TOP_SOFT_RST` bit 11);
`PAD_USB_VBUS_DET` pinmux (`PINMUX_BASE+0xac`, function 0); the ECO
`RX_FLUSH` errata bit (`REG_TOP_USB_ECO` @ `TOP_BASE+0xB4`, bit 7,
found in U-Boot's `board_usb_init()`); `GAHBCFG` programming
(`HBURSTLEN_INCR4` + `DMAENABLE`, matching the devicetree's own
`g-use-dma;` property — never written by this driver before this
session); `PCGCCTL` cleared to 0 ("Restart the Phy Clock," U-Boot's own
`dwc_otg_core_host_init()`'s first step, never touched before either).

**Dead ends, explicitly ruled out** (so a future session doesn't
re-chase them): `GOTGCTL.CONIDSTS` — spent a full round flipping the
TOP-block `usb_phy_ctrl_reg`'s ID-value bit in both directions to try
to make this DWC2-core status bit read "host"; it never budged either
way, and it turned out the real vendor driver never reads it at all —
host mode there comes entirely from `GUSBCFG.FORCEHOSTMODE`. The
devicetree's second `reg` range (`0x03006000`, "USB 2.0 PHY") —
confirmed via the actual vendor Linux `dwc2/platform.c` glue
(`cviusb_dev.phy_regs`) that this block is real and genuinely mapped,
but only ever touched by BC1.2 charger-detection code, which is
explicitly gated to device mode (`if (!id_override) return -EPERM;`)
— irrelevant to host mode. An external hub-reset GPIO mechanism
(`GPIO_HUBPORT_EN`/`ROLESEL`/`HUBRST`, found in `/etc/uhubon.sh`) —
real, but only wired up in that script's `case` statement for *other*
Cvitek chip variants (cv1821/cv1826/cv1835/cv1838); the plain
`cv180x`/Duo version of that same script defines the functions but
never calls them, confirming the Duo itself has no such external
switch to worry about.

**The actual TOP-block fix**: the exact register value to write for
host mode was always available straight from
`/mnt/system/usb-host.sh` (the vendor rootfs's own one-liner,
`echo host > /proc/cviusb/otg_role`) and its real kernel-side handler,
`dwc2_set_hw_id()` (`linux_5.10/drivers/usb/dwc2/platform.c`) — which
writes `(read & ~0xC0) | 0x40` to `usb_phy_ctrl_reg`: clear bits 6-7,
set bit 6 only. This driver's own earlier value (`0x43`, also setting
`EXTERNAL_VBUSVALID`/`DRIVE_VBUS`, bits 0-1) was this project's own
inference from the datasheet's field table, never confirmed by any
real driver, and wrong — replaced with the vendor's exact byte value.

**The actual core-reset fix**: this driver's own `GSNPSID` reads back
as exactly `0x4f54420a` — which is bit-for-bit
`DWC2_CORE_REV_4_20a`, the real Linux driver's own named constant for
this exact silicon revision (`linux_5.10/drivers/usb/dwc2/core.h`).
For cores at or above that revision, the real `dwc2_core_reset()`
does something this driver never did: after seeing
`GRSTCTL_CSFTRST_DONE` set, it performs an explicit **write-back** —
read `GRSTCTL`, clear `CSFTRST`, set `CSFTRST_DONE`, write it back —
before polling `AHBIDLE` (which Linux also polls *after* the reset
completes, not before, the reverse of this driver's original
ordering). Rewrote `usb_core_reset()` to match this exactly. This was
the fix that took `HPRT0` from permanently frozen at `0x00000000`
(regardless of any other register written, TOP-block or DWC2-core) to
genuinely live and responsive.

**Two more real-hardware-only findings, after `HPRT0` came alive**:
the `GOTGCTL` VBUS-valid override (`VbvalidOvEn`/`VbvalidOvVal`,
another of this driver's own datasheet-only inferences, never in the
vendor driver) turned out to force the port into a permanent false
"connected" latch — removed. So did an unconditional port-reset pulse
performed immediately after port-power, before any real settle time —
Phase 1's own stated scope (connect/disconnect polling only, no
enumeration) never actually needed a reset here at all; replaced with
a plain 100ms settle delay and a W1C-bit clear before the polling loop
starts.

### The final, real confirmation

With the above, a genuinely clean two-state result across separate
boots: SD-card-only boot (no USB IO board attached) shows
`HPRT0=0x00001000`, `prtconnsts=0`, `prtlnsts=0` (SE0 — correctly
disconnected); boot with the Duo's official USB&Ethernet IO board
attached shows `prtconnsts=1`, `prtlnsts=1` (idle full-speed J-state),
consistent and unchanging across multiple boots. That "unchanging"
property was itself briefly alarming — plugging/unplugging a USB drive
into the IO board's own downstream ports never changed anything — until
realizing the IO board's "4x USB" spec implies an onboard hub, and
`HPRT0` can only ever see the single device on the Duo's own root
port: the hub itself, not whatever's plugged into its downstream side.
Seeing the hub connect is a completely valid, real connect-detection
event (a hub is a real, standard-compliant USB device) — the
two-boot-state comparison above is that confirmation, since a live
attach/detach test wasn't physically possible (the IO board's header
also carries the serial console's own UART3 TX/RX, pins 6/7).

Detecting an actual downstream *device* behind that hub — as opposed
to the hub's own connection — needs real hub-class enumeration
(`SET_CONFIGURATION` on the hub, then `GET_PORT_STATUS` class requests
per downstream port), which is out of scope for Phase 1's bare
`HPRT0`-polling design. That's real, necessary Phase 2+ work, not a
bug in what's here.

**Verification**: QEMU regression clean (`HAS_USB=false` there,
`usbd` correctly never spawns, shell/diskd/fsd/fsd2/procd/envd all
create normally). Real Duo hardware: `usbd`'s own diagnostic prints
confirm `GSNPSID`/`GHWCFG2` sane, `GINTSTS.CURMODE`/`GOTGCTL.CONIDSTS`
both correctly report host mode, `HPRT0` genuinely tracks real
connect/disconnect state across the two-boot-state comparison above.
`hotplugtest`/`lsproc` both still clean alongside `usbd`'s own polling
loop (confirms the shell-creation-reorder fix holds).

**Files changed:** `src/entry.c3` (`SYS_YIELD`), `src/process.c3`
(`setup_usbd_mappings`, `usbd_pid`), `src/kernel.c3` (explicit shell
creation before `usbd`'s spawn), `boards/duo/board.c3` /
`boards/qemu/board.c3` (`USB_*` constants), `user/user.c3` (`yield()`
wrapper), `user/usbd.c3` (new — the driver itself), `scripts/
build_user.sh`, `scripts/build.sh`, `scripts/build_duo.sh`.

Not yet committed — working tree has all of the above, pending review.

---

## 2026-08-21 (63) — Hot-plug plumbing (`SYS_NS_MOUNT_WAIT`), and a real kernel interrupt-safety bug found along the way

USB support (goal: mass storage with real hot-plug) needs a way for a
driver spawned *after* boot to announce itself and have some other
process wait until it's actually ready to bind — something this kernel
had no mechanism for at all. `fsd.c3`'s own binding to its disk driver
is a hardcoded, boot-time-only constant (`DISKD_PID = 3`); `SYS_NS_MOUNT`
binds a namespace prefix to whatever's *currently* posted, with no
retry; `mounttest` (the one existing proof `srv_post`/`ns_mount` work
post-boot) deliberately only ever mounts something *already* posted
well before the command runs, avoiding exactly this race. There's also
no user-mode `yield()`/`sleep()` syscall, so a client-side retry loop
has no safe way to wait.

**`SYS_NS_MOUNT_WAIT`** (`src/entry.c3`, syscall 26): same
`(prefix, srv_name)` as `SYS_NS_MOUNT`, plus a `max_attempts` retry
count. Blocks — same `PROC_RUNNABLE`-throughout polling shape as
`SYS_JOIN` (never `PROC_BLOCKED`: nothing would ever clear that for
this condition) — retrying a new shared `ns_mount_try()` helper
(`src/process.c3`, extracted from `SYS_NS_MOUNT`'s own previously-inline
lookup+bind logic, zero behavior change for its existing caller) until
it succeeds or the attempts run out. `user/user.c3` gets the
`ns_mount_wait()` wrapper; `user/shell.c3` gets `hotplugtest`, which
spawns a "late driver" child that posts itself only after a real,
unpredictable delay, and races a real `ns_mount_wait()` call against it
— proving the wait genuinely blocks and retries, not just checks once,
plus a second call against a name nothing ever posts, proving it gives
up rather than hanging forever.

**A real, previously-undiscovered kernel bug, found building this**:
`hotplugtest` reproducibly corrupted the parent's own execution —
not a crash, the parent appeared to silently re-execute its own code
from an earlier point. Root-caused, by elimination across five isolated
variants, to a fresh `rfork()` child getting its first scheduling turn
while the parent is still open inside a *different* blocking syscall.
`sstatus`'s `SPIE` bit (what every `sret` restores the live `SIE`/
interrupt-enable bit from) is a single, unbanked hardware register;
`switch_context()` (the cooperative stack-swap `yield()` uses) never
touches it, only a genuine trap-entry/`sret` pair does. `fork_entry()`
(`src/process.c3`) — a brand-new child's synthetic "first ever" resume
path, entirely separate from the shared `kernel_entry` trap-exit tail —
never touched `sstatus` at all: its `sret` fired using whatever the
*most recent real trap entry anywhere in the system* happened to leave
in that shared register, which, with the parent mid-syscall, was still
the parent's own "interrupts were on" snapshot from *before* it entered
that syscall — globally re-enabling interrupts while the parent's own
wait still assumed they were off, letting a timer interrupt land
mid-syscall (exactly what this kernel's whole preemption-safety design,
`enable_timer_interrupts()`'s own comment, says should be impossible).
Latent until now because nothing before combined "spawn a new process"
with "immediately enter a *different* blocking syscall."

**Fix**: a new `blocking_depth` counter (`src/process.c3`) plus
`Process.in_blocking_wait`, incremented/decremented around all six
blocking syscalls' own poll loops (`SYS_JOIN`, `SYS_GETCHAR`,
`SYS_IPC_RECV`/`_GEN`, `SYS_FUTEX_WAIT`, `SYS_NS_MOUNT_WAIT`).
`fork_entry()` consults it live, at the exact moment its own `sret` is
about to fire, forcing `SPIE` off whenever it's nonzero — checked live,
not baked in at `SYS_RFORK` time (seriously considered and rejected:
`blocking_depth` can change *after* `rfork()` returns but *before* the
child's first real turn, exactly hotplugtest's own scenario). `SYS_KILL`
decrements the counter if it kills a target that was genuinely mid a
counted wait, closing a real leak risk (a killed process's own
increment would otherwise never come back down).

**A wrong first attempt, corrected before shipping**: the first version
also forced `SPIE` off at `handle_trap()`'s own end (the *shared*
trap-exit tail every ordinary syscall returns through), reasoning that
*any* process's eventual natural `sret` could equally use a stale
`sstatus` snapshot if another process was still blocked elsewhere.
Wrong in practice: `blocking_depth` is *effectively always* nonzero
during normal operation — every idle server (`echod`/`fsd`/`procd`/
`envd`) sits *permanently* blocked in `SYS_IPC_RECV` waiting for its
next client, which is its normal steady state, not a transient window.
Gating the shared tail on it disabled real timer-interrupt preemption
for the *entire system*, forever, from early in boot onward — found
directly when `hotplugtest` itself started reproducibly hanging with
that version in place (a syscall-free spinning child, once nothing
could ever forcibly preempt it, simply never gave the CPU back).
Reverted that part: the shared tail's own `sret` already correctly
restores `SIE` from *that specific process's own* `sstatus` snapshot,
captured at *that same trap's* own entry — already safe by the
existing, proven invariant. Forcing `SPIE` off is only ever needed for
a *synthetic* `sret` with no real corresponding trap-entry of its own,
which only happens in `fork_entry()`.

**Also fixed in `hotplugtest` itself**: the "late driver" child
originally spun in a bare `for(;;){}` after posting — a design bug in
its own right, independent of the kernel fix: a real driver would
eventually make *some* syscall (an actual I/O wait), never spin
forever with zero syscalls at all. Once the kernel correctly stopped
letting a mid-syscall parent get preempted by an unrelated process's
stale interrupt state, a truly syscall-free child had no way to ever
give the CPU back. Changed to block on a real `ipc_recv()` for a
message nobody sends — a realistic idle-wait, and one that yields
through the same safe, `blocking_depth`-covered mechanism every other
blocking wait already uses.

**Verification**: `hotplugtest: ok` repeatedly (12+ consecutive
invocations across fresh boots, no failures) on all three QEMU images.
Full regression clean: `mounttest` (confirms `ns_mount_try`'s extraction
is a no-op), `rforktest`, `threadtest`/`threadjointest`, `killtest`,
`permtest`, `srvtest`, `racetest`/`mutextest` (`SYS_FUTEX_WAIT`/`WAKE`),
`ping`/`p9test` (`SYS_IPC_RECV`), `p9fstest`/`p9fswritetest`/
`p9mkdirtest`/`fspermtest`, `runtest2`/`argvtest2`/`pathtest2`/
`bigreadtest`/`elftest2`, full shell suite. Explicitly re-verified the
leak-safety path (a throwaway diagnostic command, not committed): killed
a process genuinely mid-`SYS_JOIN`, confirmed `blocking_depth`
decremented correctly rather than leaking. Three-boot stress batch,
`e2fsck -n -f` clean on both `disk_dual.img` halves.

**Real Milk-V Duo hardware confirmation**: `hotplugtest: ok`,
`killtest`/`permtest`/`p9fswritetest` all still `ok`, `lsproc` clean
(`2/` through `7/`, no leaked children). `mounttest: FAILED` on real
hardware is expected and unrelated — real hardware has never spawned a
second `fsd` (entry 53), so `mounttest`'s own `/mnt/fs2/` cycle has
never been reachable there; not a regression from this entry.

**Files changed:** `src/entry.c3`, `src/process.c3`, `user/user.c3`,
`user/shell.c3`.

---

## 2026-08-21 (62) — mkdir via real 9P: `P9_CREATE` gains a `DMDIR` perm bit

Closes entry 59's other explicit deferral: `P9_CREATE` only ever made
regular files. Real 9P's own `Tcreate` takes a `perm` argument with a
`DMDIR` bit that tells the server to create a directory instead —
closed that gap the same way rather than inventing a separate verb.

**`ext2_mkdir_resolved()`** (`user/fs/ext2.c3`), extracted from
`ext2_mkdir()`'s own tail — same pattern as `ext2_read_inode_at`
(entry 56) and `ext2_delete_resolved` (entry 59): everything past path
resolution (the "already exists" check, inode/block allocation,
`.`/`..` entries, linking into the parent) operates purely on a
directory inode and a name, never touching a path string. `ext2_mkdir`
itself keeps its path-resolution prefix and delegates — zero behavior
change for its existing caller (`/bin/mkdir`).

**`fsd.c3`'s `P9_CREATE` dispatch**: wire format gains a `perm` field
(`fid(4) + perm(4) + name(32)`, was `fid(4) + name(32)` — `name` shifts
from byte 4 to byte 8). `perm & P9_DMDIR` (new constant, `0x80000000`
— the real Plan9 value) selects `ext2_mkdir_resolved()` instead of
`ext2_create_file()`; the fid transform sets `is_dir`/`opened` from
`want_dir` instead of hardcoding them — a directory fid comes back
*not* opened (`P9_OPEN` already rejects directories, and only
`P9_WALK`/`P9_REMOVE` ever touch a directory fid, neither checks
`opened`), matching `P9_ATTACH`'s own root-fid convention.

**`P9_REMOVE` needed zero changes** — the actual payoff of entry 59's
own extraction being generic rather than filename-tied:
`ext2_delete_resolved()` already branches on `mode & EXT2_S_IFDIR`
(non-empty-directory refusal, parent `links_count` fixup,
`ext2_dec_used_dirs()`), regardless of whether the directory came from
a path or a fid.

**A real test-design bug found and fixed while writing `p9mkdirtest`,
not a dispatch bug**: the test's first draft tried to remove a
non-empty directory (expecting `-1`), then remove the file inside it,
then retry removing the directory *using the same fid*. That retry
kept failing. Root cause, found via targeted debug prints (temporarily
added to `ext2_delete_resolved` and the `P9_REMOVE` dispatch, removed
once diagnosed): entry 59's own `P9_REMOVE` design deliberately
consumes the fid on *any* genuine attempt, success or failure — matching
real `Tremove`'s own contract exactly, already relied on by
`p9fswritetest`'s own dangling-fid check. The first (failed, "not
empty") removal attempt had already consumed the fid; the second call
found an unused fid and never reached the dispatch at all. Fixed in
the test, not the driver: the final successful removal walks a *fresh*
fid to the same directory (`p9_walk` again from the still-live root
fid) rather than reusing the one already spent on the earlier
rejection.

**Verification**: `p9mkdirtest: ok` on both images — real directory
create, an independent walk into it (proving a genuine directory
entry, not just local fid state), a nested file created/written/read
inside it, the non-empty-directory rejection, and eventual successful
removal once empty. Full regression clean (`p9fstest`,
`p9fswritetest`, `fspermtest`, `/bin/mkdir`/`/bin/rm` — confirms
`ext2_mkdir_resolved`'s extraction is a no-op for its path-based
caller — `mounttest`, `runtest2`/`argvtest2`/`bigreadtest`). Three-boot
stress batch, `e2fsck -n -f` clean on `disk_ext2.img` and both
`disk_dual.img` halves — no errors or warnings, despite directory
linking/bookkeeping being more structurally sensitive than a plain
file write.

**Real Milk-V Duo hardware confirmation**: `p9mkdirtest: ok`,
`p9fswritetest: ok`, `p9fstest: ok`, `lsproc` clean (`2/` through
`7/`).

**Files changed:** `user/fs/ext2.c3`, `user/fsd.c3`, `user/user.c3`,
`user/shell.c3`.

---

## 2026-08-21 (61) — Genuine offset-aware `Twrite`

Follow-up to entry 59, closing its own explicitly-deferred restriction:
`P9_WRITE` only ever accepted offset 0, because `ext2_write_file()`
(the helper it reused) has no offset parameter at all — it always
replaces a file's content starting from block 0. Real `pwrite()`-style
writes needed a genuinely new primitive, not just relaxing a check.

**New**: `ext2_write_file_at(inode, src, len, offset)` in
`user/fs/ext2.c3`, alongside — not replacing — `ext2_write_file`
(still used unchanged by path-based `ext2_write()`, unrelated "replace
the whole file" semantics). Same per-block allocation loop shape,
generalized with a starting block index and in-block byte offset.

**No holes, by design.** Every read path in this driver
(`ext2_read_at`/`ext2_read_inode_at`) treats `inode.block[i] == 0` as
"past the end of the file", not "a sparse hole" — letting a write
leave a gap of unallocated blocks before new data, while `inode.size`
claims they're valid content, would silently corrupt every future read
of that file. So `offset > inode.size` is rejected outright (`-1`),
same as `offset` already being at/past this driver's own
12-direct-block cap. That still covers what actually matters:
overwriting existing bytes anywhere in the file, and appending exactly
at the current end to grow it.

One correctness improvement made possible by building this fresh
rather than generalizing the old function in place: a partial write
into a block this call just freshly allocated now zero-fills the
buffer first, rather than reading whatever stale content happens to
already be on disk at that block number (`ext2_write_file`'s own
existing behavior in that same situation, left untouched — a
pre-existing quirk, not part of this fix, and not worth the regression
risk of touching a well-exercised path-based write to fix it there
too).

`fsd.c3`'s `P9_WRITE` dispatch dropped the `offset == 0` check, calls
the new function, and grows `inode.size` only if the write actually
extended past the old end — never shrinks it.

`p9fswritetest` extended (not replaced): a mid-file overwrite at byte
6, an append exactly at the current end (26 → 32 bytes), and the old
"any nonzero offset fails" check replaced with a real hole-rejection
check (offset far past the new 32-byte end). Verifying the append case
needed byte-range comparison instead of `strcmp`: the file's content
has a stray trailing-null byte baked in mid-buffer, an artifact of
entry 59's own write call passing a C string literal's length
including its trailing null (harmless there — strcmp naturally stopped
at the same point either side — but it would make a plain strcmp
report a false match for the newly appended tail too).

**Verification**: `p9fswritetest: ok` on both images with all three
new checks passing. Full regression clean (`p9fstest`, `fspermtest`,
`/bin/rm` and existing delete tests, `mounttest`, `runtest2`/
`argvtest2`/`bigreadtest`) — confirms `ext2_write_file`/`ext2_write()`'s
own path-based behavior is completely unaffected, a new function, not
a modified one. Three-boot stress batch, `e2fsck -n -f` clean on
`disk_ext2.img` and both `disk_dual.img` halves — no errors or
warnings, despite the new partial-block-write-at-arbitrary-offset and
append-time-allocation logic being genuinely new on-disk write paths.

**Real Milk-V Duo hardware confirmation**: `p9fswritetest: ok`,
`p9fstest: ok`, `lsproc` clean (`2/` through `7/`) — mid-file
overwrite, append-growth, and hole-rejection all confirmed working for
real, not just on QEMU.

**Files changed:** `user/fs/ext2.c3`, `user/fsd.c3`, `user/user.c3`,
`user/shell.c3`.

---

## 2026-08-21 (60) — Fix `fspermtest`'s real-hardware gap: retarget to root

Closes entry 58's own documented gap. `fspermtest` always targeted
`/mnt/fs2/`, for a real historical reason: the old topology could have
FAT32 and ext2 mounted simultaneously, and an unprefixed path
resolving through the `""` catch-all might land on whichever `fsd` was
created first — FAT32 has no uid concept, so a bare path could
silently bypass ext2's own checks entirely. Entry 53's Plan9-style
reorganization already removed that ambiguity structurally (`""` is
ext2-exclusive on real hardware, and the first partition on every
QEMU image that has one), but `fspermtest` itself was never updated to
take advantage of it — so entry 58 found the opposite problem instead:
real hardware, since entry 53, never spawns a second `fsd` at all,
meaning every `/mnt/fs2/`-prefixed call in this test failed at
`ns_resolve()` *before ever reaching ext2's own permission checks*. The
"correctly denied" results this produced on real hardware were a false
positive from an unreachable namespace, not genuine confirmation of
anything.

**Fix**: every path in `fspermtest` (`user/shell.c3`) switched from
`/mnt/fs2/`-prefixed to bare (root-mount). Same reasoning
`p9fstest`/`p9fswritetest` already rely on — `""` unambiguously means
ext2 wherever this project's real 9P work targets it now. No `ext2.c3`
or `fsd.c3` changes needed — this was a test-targeting gap, not an
enforcement gap; the permission checks themselves (`ext2_write_allowed`
and friends) were already correct, just unreachable from where the
test poked at them.

**Verification**: `fspermtest: ok` on QEMU's dual-mount image (now
against partition 1, the root mount, instead of partition 2) and,
notably, on the single-partition ext2-only image too — the topology
closest to real hardware's own single-`fsd` layout, which this test
literally could not exercise meaningfully before. Full regression
(`runtest2`, `argvtest2`, `mounttest`, `bigreadtest` — all still
`/mnt/fs2/`-targeted, untouched, still `ok`) confirms the retarget
didn't disturb anything relying on the second mount. Three-boot stress
batch, `e2fsck -n -f` clean on both partitions.

**Real Milk-V Duo hardware confirmation**: `fspermtest: ok`, every
individual check line showing genuine allow/deny behavior (not a
namespace-resolution short-circuit) — the first real confirmation that
ext2's own permission enforcement, including entry 58's own rename fix,
actually works on real hardware. `lsproc` clean (`2/` through `7/`).

**Files changed:** `user/shell.c3`.

---

## 2026-08-21 (59) — Real 9P writes against fsd: Tcreate, Tremove, Twrite (offset-0 only)

Follow-up to entry 56 (real 9P read-only against `fsd`). Three new
verbs, same wire discipline as `P9_ATTACH`/`P9_WALK`/`P9_OPEN`/
`P9_READ`/`P9_CLUNK`: `P9_CREATE`, `P9_WRITE`, `P9_REMOVE` (verbs 8-10,
`user/user.c3`), with matching `p9_create`/`p9_write`/`p9_remove`
client wrappers and `fsd.c3` dispatch, ext2 only.

`P9_WRITE` is deliberately narrow: `ext2_write_file()` (the existing
helper both this and the path-based `ext2_write()` use) has no offset
parameter at all — it always replaces a file's entire content from the
start. Rather than build genuine offset-aware partial writes (real
future work), `P9_WRITE` just exposes that same existing capability
through a fid: **offset must be exactly 0**, anything else is rejected
outright rather than silently writing the wrong bytes.

`P9_CREATE` reuses `ext2_create_file()` directly (already takes a
directory inode, not a path) and transforms the fid in place — real
9P's own actual `Tcreate` semantics: no separate `newfid`, and the fid
comes back already open, matching `Tcreate`'s own "no `Topen` needed
after" contract. Files only — a `DMDIR`-style bit for directory
creation stays out of scope.

`P9_REMOVE` needed one real design decision entry 56 never had to
face: fids resolve to a stable inode number (deliberately, so they
survive a rename elsewhere) rather than a path. Removing a file while
*another* fid still holds the same inode open would let that fid keep
reading/writing freed-and-possibly-reallocated blocks — real
corruption, not just a stale error. Fixed with an explicit scan of
`fs9_fids[]` before any removal proceeds: if any other slot is `used`
with the same `inode_num`, the request is rejected outright and the
fid stays open (no on-disk removal was even attempted, so unlike a
genuine attempt this doesn't consume it — confirmed with
`p9fswritetest` itself, which retries the same `p9_remove` call again
after clunking the blocking fid and expects it to then succeed). A
*genuinely attempted* removal, by contrast, consumes the fid
regardless of whether `ext2_delete_resolved()` itself succeeds —
matching real 9P's own `Tremove` contract exactly.

`Fs9_fid_entry` gained `parent_inode`/`entry_sector`/`entry_offset`/
`has_entry` — `P9_WALK` already computed a new entry's directory
position via `ext2_find_in_dir()` but discarded it; now captured so
`P9_REMOVE` never needs to re-walk a path at removal time. `has_entry`
is false only for a bare root fid (`P9_ATTACH` never sets it) — root
has no entry of its own to remove.

`ext2_delete()`'s own tail (everything past path resolution) is
extracted into `ext2_delete_resolved(dir_inode, inode_num,
entry_sector, entry_offset, mode, requester_uid)`, mirroring entry 56's
own `ext2_read_at` → `ext2_read_inode_at` split exactly. `ext2_delete()`
itself keeps its path-resolution prefix and delegates — zero behavior
change for its existing caller (`/bin/rm`).

New `p9fswritetest` (`user/shell.c3`): create-then-immediately-write-
then-read, the offset-0-only rejection, and the dangling-fid safety
check with two real, independently-attached fids on the same inode
(walk fails before create, create-and-write-and-read round-trips,
non-zero-offset write rejected, a second fid opens the file, remove is
rejected while that fid is open, remove succeeds once it's clunked).

**Verification**: `p9fswritetest: ok` on both the ext2-only and
dual-mount images. Full regression clean: `p9fstest`, `/bin/rm` (path-
based delete unaffected by the `ext2_delete_resolved` extraction),
`fspermtest`, `mounttest`, `pathtest`/`pathtest2`, `permtest`,
`elftest`/`elftest2`, `sandboxtest`, `p9realtest`, `p9test`, `nstest`,
`pstest`, `bigreadtest`, `runtest2`, `argvtest`/`argvtest2`. Three
consecutive boots against the same persistent `disk_dual.img` (running
`p9fswritetest`/`p9fstest`/`fspermtest` each time) all `ok` — confirms
create+write+remove leaves the filesystem in a stable, re-testable
state, not accumulating drift. `e2fsck -n -f` clean on `disk_ext2.img`
and both halves of `disk_dual.img` after the stress run, no errors or
warnings.

**Real Milk-V Duo hardware confirmation**: `p9fswritetest: ok`,
`p9fstest: ok`, `lsproc` clean (`2/` through `7/`, no leaked
processes). Unlike entry 58's own `fspermtest` gap, both new test
commands target the root mount (`ns_resolve("")`) exclusively — real
hardware's only mount post-entry-53 — so this is the first write-path
9P work in this series confirmed genuinely working on real hardware,
not just QEMU's dual-mount image.

**Files changed:** `user/fs/ext2.c3`, `user/fsd.c3`, `user/user.c3`,
`user/shell.c3`.

---

## 2026-08-21 (58) — Fix `ext2_rename`'s missing ownership check

Surfaced during entry 56's own research: every other mutating ext2 verb
(`ext2_write`'s overwrite case, `ext2_delete`, `ext2_delete_recursive`)
gates on `requester_uid` via `ext2_write_allowed()` — `ext2_rename`
never looked up `requester_uid` at all. Any non-root process could
rename (including moving into a different directory) any file
regardless of ownership.

Same treatment `ext2_delete`'s own comment already establishes for
exactly this situation: real Unix gates rename by the *directory's*
write permission, not the target's own — this driver doesn't model
directory permissions at all, so the target's (source file's) own
write bit is the stand-in, checked before any of rename's own
destination-side work (cycle check, existing-destination check,
directory-slot allocation, actual writes). `fsd.c3`'s `FS_RENAME`
dispatch gained the same `proc_info()` uid lookup `FS_WRITE`/
`FS_DELETE`/`FS_MKDIR` already have. FAT32 untouched — no uid concept
there at all, same scoping every other permission feature in this
project already has.

`fspermtest` extended with two rename sub-checks (root-owned file,
non-root rename attempt correctly denied; the attacker's own file,
rename succeeds) — the existing parent-side readback check already
doubles as an implicit denial confirmation (a wrongly-succeeded rename
would make the original path unreadable, which the existing check
already catches).

**Verification**: `fspermtest: ok` with both new sub-checks, on the
dual-mount image (single-mount `fspermtest` failure is the same
pre-existing, expected "/mnt/fs2/ inactive there" limitation this test
has always had). `/bin/mv` (root) unaffected. Three-boot stress batch,
`e2fsck -n -f` clean.

**A real, structural gap found while trying to confirm this on real
hardware, not fixed here**: `fspermtest` targets `/mnt/fs2/`
unconditionally — but since entry 53, real Duo hardware no longer spawns
a second `fsd` at all, so `/mnt/fs2/` doesn't resolve to anything there.
`fs_rename("/mnt/fs2/...")` (and every other `fspermtest` call) now
fails at `ns_resolve()`, *before it ever reaches `fsd`/`ext2.c3` at
all* — the "correctly denied" results this produces on real hardware
are a false positive from the namespace not resolving, not genuine
confirmation of any permission check. This means **ext2's own
permission enforcement — including this entry's own new rename check —
has not actually been exercised on real hardware since entry 53
shipped**, only on QEMU's dual-mount image. Confirmed with the user:
left as a known gap for now rather than retargeting `fspermtest` to
root (real hardware's only, writable mount) in this entry — a real
follow-up worth doing, not a silent limitation.

**Files changed:** `user/fs/ext2.c3`, `user/fsd.c3`, `user/shell.c3`.

---

## 2026-08-21 (57) — Quiet sdd's per-sector debug output

`sdd.c3` (the real Duo SD driver) printed two full lines per sector
I/O unconditionally — `"sdd: rw sector=..."` before every command,
`"sdd: CMDxx ok resp0=... ready after ..."` after every successful
transfer. Real, useful bringup-era diagnostics (found real bugs this
way), but with a real ext2 read path routinely touching dozens of
sectors per `exec()`/9P read, it had become pure noise now that the
driver's own timing has been extensively verified this session.

New `SDD_VERBOSE` const, off by default, gates both blocks. Confirmed
safe to toggle without risk: both prints already sit outside the
timing-sensitive window this file's own comments warn about (the
FIFO-shallow bug that window's discipline exists to prevent) — one runs
before the command is even sent, the other after the transfer has
already fully completed.

**Real Milk-V Duo hardware confirmation**: ran the next full real-
hardware test round with `SDD_VERBOSE` off — the serial output is
completely clean of `sdd:` lines, a direct, visible before/after
contrast against every prior real-hardware round this session.

**Files changed:** `user/sdd.c3`.

---

## 2026-08-21 (56) — Real 9P (read-only) against fsd — the real file server, ext2 only

Follow-up to entries 54/55 (real 9P against `echod`'s toy sandbox) —
lands the same protocol against `fsd`, the real file server backed by
ext2, scoped to read-only (`Twalk`/`Topen`/`Tread`/`Tclunk`) and ext2
only. `Twrite`/`Tcreate`/`Tremove`/`Trename` raise real semantic
questions (what does an open fid mean across a rename/delete of its own
target — a scenario that can't occur in today's stateless-per-call
`FS_*` model, so there's no existing behavior to preserve, only a new
one to design) deliberately left for a later entry. FAT32 excluded —
it's boot-partition-only now (entry 53), not part of this project's own
real deployment topology.

**The actual payoff of building the protocol generically against
`echod` first**: no new verb constants, no new client wrapper functions
needed at all. `P9_ATTACH`/`P9_WALK`/`P9_OPEN`/`P9_READ`/`P9_CLUNK`
(`user/user.c3`) and their client wrappers already exist and already
work against *any* pid — real 9P's own "same protocol, any server"
property, for real. `fsd.c3` just needed its own dispatch for these
already-defined verbs, addressed to `fsd`'s own pid instead of
`echod`'s.

`fsd.c3` gains an 8-slot FID table (`Fs9_fid_entry`: `used`/`opened`/
`is_dir`/`inode_num`) — an ext2 inode number is a genuinely stable
identity, unlike a path string (survives a rename elsewhere, unlike
`ext2_cache_path`). `P9_WALK` calls the *existing* `ext2_find_in_dir`,
which already takes an arbitrary directory inode, not just root — so
this is hierarchical for free, no separate "add subdirectories" phase
needed the way `echod`'s own from-scratch synthetic tree required.
Every one of the five verbs returns `-1` when `fs_type != FS_TYPE_EXT2`
(FAT32, or an unmounted second instance) — same graceful-degrade shape
every existing `FS_*` verb already has.

`ext2_read_at`'s own tail (offset/EOF handling, the indirect-block
resolution loop) is extracted into a new `ext2_read_inode_at(inode_num,
...)`, taking an inode number directly — `ext2_read_at` itself (path-
based, still used unchanged by `exec()`'s own chunked read loop and
everything downstream) keeps its own cache/resolve logic and just
delegates once it has `inode_num`; `fsd.c3`'s new `P9_READ` dispatch
calls the same shared helper directly, skipping path resolution
entirely since it already has `fid.inode_num` from the walk. Pure
extraction, zero behavior change for existing callers — confirmed by
the full regression suite passing unchanged.

New shell command `p9fstest` walks real, on-disk data — a root-level
file, then a real subdirectory, then a file inside it (genuine two-level
descent against the actual filesystem, not a synthetic tree) — and a
negative walk against a nonexistent name.

Surfaced, unrelated, not fixed here: `ext2_rename` never looks up
`requester_uid` at all, unlike every other mutating verb (write/delete/
mkdir) — a real, pre-existing permission gap, flagged to the user,
left alone for this entry.

**Verification**: `p9fstest: ok` on the ext2-only and dual-mount
(ext2 root) images; correctly `FAILED` on the FAT32-only image (every
verb returns `-1`, confirms the gate works, nothing crashes). Full
regression — `exec()`-dependent tests, every `/bin/` utility, the
entire existing shell suite, `mounttest`, `p9realtest` — all
unaffected, confirming the `ext2_read_at` extraction is a genuine
no-op. Three-boot stress batch, `e2fsck -n -f` clean.

**Real Milk-V Duo hardware confirmation**: `p9fstest: ok` against the
real, single, ext2-exclusive `fsd` (entry 53's own topology), full
regression (`runtest`/`elftest`) unaffected, `lsproc` clean.

**Files changed:** `user/fs/ext2.c3`, `user/fsd.c3`, `user/shell.c3`.

---

## 2026-08-21 (55) — Real subdirectories in echod's 9P sandbox

Follow-up to the previous entry: `echod`'s own synthetic 9P tree was
flat — only the root had children, enforced directly in `P9_WALK`'s
own dispatch (`fid must be root`), and `P9_OPEN` rejected opening
`P9_NODE_ROOT` specifically. Real 9P's own `Twalk` is inherently
hierarchical — a client walks one path element at a time, composing
calls to descend arbitrarily deep — a flat tree never exercised that.

`P9_node` (`user/echod.c3`) gains `parent`/`is_dir`; the tree grows
from 3 nodes to 5 — `hello`/`motd` unchanged under root, plus a new
`docs` subdirectory containing its own `readme` file, reachable only by
walking `root → docs → readme`. `P9_WALK`'s own dispatch generalizes
from "fid must be root" to "fid must point at a directory," and the
child search from "any node under root" to "any node whose own parent
matches fid's current node" — the exact same code path that already
found `hello`/`motd` under root now also finds `readme` under `docs`,
parameterized instead of hardcoded. `P9_OPEN` generalizes the same way
(reject any directory, not just root specifically).

`p9realtest` (`user/shell.c3`) extended, not a new command — two more
`p9_walk()` calls composed in sequence (`root → docs`, then `docs →
readme`), confirming opening `docs` directly fails (it's a directory)
and the final read reaches genuinely nested content.

**Verification**: `p9realtest: ok` on all three QEMU images with the
new two-level walk included, full regression of `ping`/`runtest`/
`argvtest`/`p9test` unchanged, three-boot stress batch clean.

**Real Milk-V Duo hardware confirmation**: `p9realtest: ok` (including
the new two-level walk), full regression of `ping`/`runtest`/
`argvtest`/`p9test` unchanged, `lsproc` clean.

**Files changed:** `user/echod.c3`, `user/shell.c3`.

---

## 2026-08-21 (54) — Real 9P semantics (FID/Twalk/Topen/Tread/Tclunk), against echod's own sandbox

Today's "9P-lite" (`P9_TWALK`/`P9_TREAD`, introduced 2026-08-15) was
never real 9P — confirmed by research this round: `echod`, the only
server that speaks these verbs, has no backing store at all.
`P9_TWALK` never walks anything (echod just echoes the raw path bytes
straight back); `P9_TREAD` returns a hardcoded canned string, ignoring
offset entirely. No FID exists anywhere in the codebase (every
operation re-sends a full path or uses a bare pid, no persistent open
handle). The real file server (`fsd`, backed by FAT32/ext2) was built
later on an entirely separate, non-9P verb set (`FS_READ`/`FS_WRITE`/
etc.) that never got folded back into 9P. The original 2026-08-15 entry
explicitly deferred "real path resolution" to a later phase — this
entry is that phase, 2026-08-15's own unfinished "next up."

**Lands in `echod`'s own sandbox, not a migration of `fsd`**, confirmed
with the user — a small, in-memory, read-only synthetic tree (`hello`/
`motd`, distinct known content), genuinely exercising real FID/walk/
open/read/clunk semantics, without the much larger risk of migrating
the real file server. Uses racccoon's own existing IPC framing
(`msg_type` carries the verb, structured C3 fields at fixed byte
offsets in `msg_data` — same convention `FS_*` verbs already use), not
real 9P's own byte-level wire encoding (size/type/tag header) — nothing
outside this kernel could ever speak real 9P over an actual byte
stream, so reinventing that framing here would be pure ceremony with no
interoperability benefit.

**New verbs, not a change to `P9_TWALK`/`P9_TREAD`'s own behavior**:
`P9_ATTACH`/`P9_WALK`/`P9_OPEN`/`P9_READ`/`P9_CLUNK` (`user/user.c3`)
sit alongside the existing two, completely untouched — `runtest`/
`argvtest` specifically use `P9_TREAD` to verify `exec()`'s own
argv-passing plumbing, an unrelated use case that would have broken had
`P9_TREAD` suddenly required a walked-and-opened FID.

`echod`'s own new state (`user/echod.c3`): a 3-node flat tree (root +
`hello` + `motd`) and an 8-slot FID table, both populated/reset the way
every other struct in this codebase is — explicit field assignment, not
a struct-array literal (confirmed by grep: no precedent for that syntax
anywhere in this project). `P9_WALK` does a real name lookup against the
tree; `P9_OPEN` marks a FID ready; `P9_READ` does a genuine
offset-based slice into the matched node's own content (proven with a
real mid-string read, not just "always from position 0" — the exact
thing the old `P9_TREAD` could never do); `P9_CLUNK` frees the slot.

New shell command `p9realtest` (not `p9test2` — this session's own `2`
suffix already means "targets the non-default mount," an unrelated
concept) exercises the whole set: two simultaneously-open FIDs, a real
negative walk (`"nope"`, must fail), and two independent offset reads
against two different nodes.

**Verification**: `p9realtest: ok` on all three QEMU images. Full
regression of every existing 9P-lite user (`ping`/`runtest`/
`argvtest`/`p9test`) unchanged. Three-boot stress batch clean (no
filesystem state involved at all — echod's own tree/FID table are
purely in-memory, reset fresh every boot).

**Real Milk-V Duo hardware confirmation**: `p9realtest: ok`, full
regression of `ping`/`runtest`/`argvtest`/`p9test` unchanged, `lsproc`
clean.

**Files changed:** `user/user.c3`, `user/echod.c3`, `user/shell.c3`.

---

## 2026-08-21 (53) — ext2 becomes root everywhere; FAT32 becomes boot-only; real `/mnt` binding

Plan9-style filesystem reorganization. Root is ext2 now, both on real
Milk-V Duo hardware and in QEMU's own dual-mount test topology —
previously FAT32 was "root" purely because it happened to be whichever
fsd got created first (`create_process()`'s own `""` catch-all binding
to `fsd_pid`), the exact bug-prone pattern this whole session kept
working around (`/2/`-prefix requirements, real-hardware bare paths
defaulting to the wrong filesystem, etc.). FAT32 becomes boot-partition-
only everywhere: on real hardware `DUOBOOT` stays physically on the SD
card (the SoC's own boot ROM reads `fip.bin` from it via its own
independent FAT32 walk, already fully decoupled from racccoon's kernel
— confirmed via `scripts/flash_duo.sh`'s own header comment) but
`fsd` never mounts it anymore; on QEMU it has no structural role to
mirror at all (QEMU loads the kernel ELF directly via `-kernel`, no
boot-ROM-reads-a-partition step exists there), so `disk.img`
(FAT32-only) stays purely as ongoing regression coverage for the
backend itself, never anyone's root or dual-mount partner.

**Real Duo hardware**: `boards/duo/board.c3` now points
`FS_PARTITION_START_SECTOR` at `EXT2TEST` (was `DUOBOOT`), and
`HAS_SECOND_FS_PARTITION` is `false` — only one `fsd` process exists.
Since filesystem type is auto-probed by content (`ext2_probe()` first),
not partition position, that one `fsd` correctly mounts ext2 with zero
`fsd.c3`/`ext2.c3` changes. This retires the single biggest source of
real-hardware pain this session kept hitting: with only one fsd, every
bare path now reaches ext2 directly, no more "which fsd was created
first" ambiguity to work around.

**`/mnt/fs2/`, not `/2/`**: matches Plan9's own convention — `/mnt` is
just an ordinary directory (root's own `bin/` now has a real, sibling
`mnt/` directory too, initially empty) that other services get mounted
onto, nothing structurally special about it, same as this project's own
`/srv`/`/proc`/`/env` are already name-keyed IPC-backed namespace
prefixes mirroring Plan9 already. `create_process()`'s default namespace
still statically binds this at boot (slot 2, renamed from `"/2/"`) —
deliberately not raced against `fsd2`'s own boot-time mount via a real
`ns_mount()` call instead: there's no `yield()`/`sleep()` syscall in
this kernel to wait on safely, and trading a small, already-safe
hardcoded default for a real chance of an intermittent missing mount
isn't a good trade for a cosmetic rename. (This isn't actually in
tension with "real Plan9-style" — even a real Plan9 `init` establishes
its own starting namespace directly, not via a race against its own
children.)

**Proving `srv_post()`/`ns_mount()`/`ns_unmount()` work for real, not
just as boot-time plumbing**: these syscalls already existed (this
session's own earlier work) but were never genuinely exercised
end-to-end. `fsd.c3` now calls `srv_post("fs2")` right after mounting,
*only* when it's the second instance — `fsd.c3` is user-space and can't
see `board::` (kernel-only module) to know that about itself, so this
required extending the existing `SYS_FS_PARTITION_INFO`/
`fs_partition_info()` mechanism with a second optional out-pointer
(same convention `SYS_NS_RESOLVE`/`SYS_RFORK` already use), fed by a new
`Process.is_secondary_fs` field `kernel.c3` sets unambiguously at each
of its own two `setup_fsd_mappings()` call sites — it already knows
which is which, since its own code is what conditionally creates the
second instance at all. New shell command `mounttest`: reads through
the default mount, `ns_unmount("/mnt/fs2/")`, confirms the read now
fails, `ns_mount("/mnt/fs2/", "fs2")` re-adds it by name through the
exact syscalls any user process could call itself, confirms the read
works again. Entirely post-boot, manually triggered — no race with
`fsd2`'s own startup, since by the time anything types a shell command
it's had many scheduler rounds to finish.

**QEMU's `disk_dual.img`** is rebuilt as two ext2 partitions instead of
FAT32+ext2 — partition 1 (root) gets the same fixture set
`disk_ext2.img`'s own root already has plus the new `mnt/` directory;
partition 2 (bound at `/mnt/fs2/`) reuses the existing ext2-half
construction essentially unchanged (it was already ext2, only partition
1 was what changed). Every remaining `"/2/"` reference in
`user/shell.c3` becomes `"/mnt/fs2/"` — command *names* stay unchanged
(`runtest2`, `argvtest2`, `pathtest2`, `elftest2`, `fspermtest`,
`bigreadtest` — the `2` still means "targets the non-default mount,"
regardless of that mount's prefix string). Found two stale comments
citing the old real-hardware "DUOBOOT/FAT32 wins by creation order"
bug (now structurally impossible there) and one referencing
already-removed `readfile2`/`newfile2` commands from an earlier entry
— fixed in place; historical devlog entries themselves are not
retroactively edited (same discipline already established).

**Verification**: on the new dual-ext2 image, `runtest`/`argvtest`/
`pathtest`/`elftest` (root, now ext2 instead of FAT32) and
`runtest2`/`argvtest2`/`pathtest2`/`elftest2`/`fspermtest`/`bigreadtest`
(now via `/mnt/fs2/`) all `ok`, new `mounttest: ok`, full regression of
every process/IPC-mechanism builtin and the `/bin/` utilities against
both mounts (confirming `cat`/`ls`/`write`/`rm`/`mkdir`/`mv` work
against ext2-as-root now, lowercase filenames preserved as expected,
unlike FAT32's uppercase 8.3 names). Single-mount images unaffected —
confirms the conditional `srv_post()` correctly never fires when there's
no real second mount (`fs_type` stays `FS_TYPE_NONE`). Three-boot stress
batch, `e2fsck -n -f` clean on every ext2 image, `fsck.vfat -n` clean on
the untouched FAT32-only image.

**Real Milk-V Duo hardware confirmation**: `cat hello.txt` (bare, no
prefix) now correctly reaches ext2 directly — the long-standing "bare
path hits whichever fsd was created first" issue is structurally gone
on this board, not just avoided. `lsproc` shows `2/`-`7/` only (one
fewer than QEMU's `2/`-`8/`, exactly the expected shift from no longer
spawning a second `fsd`) — clean, no leaked slots. `ls mnt` correctly
shows nothing (a genuinely empty directory).

**Files changed:** `boards/duo/board.c3`, `src/process.c3`,
`src/kernel.c3`, `src/entry.c3`, `user/user.c3`, `user/fsd.c3`,
`user/shell.c3`, `scripts/build.sh`, `scripts/launch64_dual.sh`.

---

## 2026-08-21 (52) — Shell backspace/line-editing support

Follow-up to the previous entry: now that the shell takes real typed
paths and arguments instead of fixed test commands, a typo had no way
to be corrected — `main()`'s own input loop (`user/shell.c3`) echoed
and appended every byte literally, including whatever a Backspace
keypress produced.

**Fix**: both `0x7F` (DEL) and `0x08` (BS) are treated as backspace —
different terminal emulators/serial console tools send different
bytes for the same key, no way to know which in advance, so both are
handled rather than guessing one. Checked as the very first thing in
the loop, before the existing echo/full-buffer logic — which means a
user can now also backspace their way back from a genuinely full
127-character line instead of it being unconditionally abandoned the
moment the old `i == 127` check fired; a side effect of the ordering,
not extra logic. The raw backspace byte is never echoed as-is — `"\b
\b"` (cursor back, blank the character, cursor back again) is the
actual on-screen erasure; a real terminal renders this as the
character disappearing.

**Verification**: no shell command can assert on terminal echo
behavior, so this was verified by real typed interaction through the
paced-input QEMU harness with literal `0x7F` bytes embedded in the
input stream — typo-then-correct (`x`, backspace, `cat hello.txt` →
correctly executes as `cat hello.txt`, confirmed by its real output
appearing, not a mangled command), backspace on an empty line (safely
a no-op), and filling the line to its 127-character limit then
backspacing all the way back to empty before typing a real command
(proves recovery from a full line, not just a partially-full one) —
each case's *actually-executed* command was correct in every scenario
(confirmed by its real output), the only artifact being that raw
`\b`/space bytes render as literal characters when a captured byte log
is viewed as plain text outside a real terminal emulator, not a bug in
the logic itself. Full regression (existing builtins and the previous
entry's own `/bin/` utilities) unaffected, three-boot stress batch
clean.

**Real Milk-V Duo hardware confirmation**: typed a typo, backspaced,
retyped correctly, in a real terminal against the real board —
characters visibly erased on screen as expected (the one thing QEMU's
raw-byte-log verification couldn't directly confirm), and the corrected
command executed correctly (reached `cat`'s own real "not found" path
for a file that was never seeded onto the real `DUOBOOT` — expected,
not a bug). `lsproc` clean afterward.

**Files changed:** `user/shell.c3`.

---

## 2026-08-21 (51) — Real argv-parsing shell + fs-operation tests become `/bin/` utilities

Every one of the shell's 54 commands (`user/shell.c3`) was dispatched by
comparing the *entire* input line against a fixed string — no
tokenization, so no command could take real user-supplied arguments;
`readfile` always read the same hardcoded path, `mkdirtest` always
created the same hardcoded directory. Every filesystem primitive these
commands exercised (`fs_read`/`fs_write`/`fs_delete`/
`fs_delete_recursive`/`fs_mkdir`/`fs_rename`/`fs_list`) was already a
real, tested, path-taking function — the hardcoding was purely in the
shell's own dispatch layer.

**Tokenization**: the command-line-reading preamble now splits on
spaces in place (mutating the line buffer itself, same "no separate
storage" approach `exec()`'s own NUL-separated argv blob already uses)
into up to 8 tokens. Every *kept* builtin's own `strcmp(cmd, "...")`
dispatch line is completely unchanged — `cmd` still means "the command
name," just sourced from the first token instead of the whole line.

**Twenty-three commands removed**, replaced by six real `/bin/`
utilities (`user/cat.c3`, `ls.c3`, `write.c3`, `rm.c3`, `mkdir.c3`,
`mv.c3` — same minimal skeleton every exec() target already uses,
`get_argv()` for arguments, thin wrappers around already-tested
primitives, no new syscalls or primitives needed anywhere):
`readfile`/`readfile2`/`readsubfile`/`readsubfile2` → `cat <path>`;
`ls`/`lssub` → `ls [path]`; `writefile`/`newfile`/`newfile2`/
`newsubfile`/`newsubfile2` → `write <path> <text>` (`fs_write` already
creates-or-overwrites transparently, so one utility covers both old
scenarios); `deletetest`/`deletetest2`/`rmdirtest`/`rmdirtest2`/
`rmdirnonempty`/`rmdirnonempty2`/`rmrtest` → `rm <path>` / `rm -r
<path>`; `mkdirtest` → `mkdir <path>`; `renametest`/`movetest` → `mv
<old> <new>` (`fs_rename` already handles same-dir rename and
cross-dir move identically); `deleteprotected`/`protectedwrite` → no
longer separate commands — `rm fip.bin`/`write fip.bin ...` against the
new generic utilities exercise the identical scenario.

Deliberately scoped out (confirmed with the user before starting): the
~30 remaining commands are process/IPC mechanics (`permtest`,
`fspermtest`, `rforktest`, `threadtest`, `mutextest`, `racetest`,
`killtest`, `srvtest`, `nstest`, `p9test`, `sandboxtest`, ...) or
meta-tests of exec() itself (`runtest`/`argvtest`/`pathtest`/`elftest`
and their `2` variants) — converting a test *of* exec() into something
exec() has to load would be architecturally awkward for no real
benefit, and these aren't "commands with arguments" the way a
filesystem operation is. They stay exactly as they were.

**Shell's new fallback**: anything not a builtin gets `rfork()`+`exec()`
against a bare `"/bin/<cmd>"` (not `$PATH`-resolved — matches how
`bin/echod` is referenced everywhere else in this file, keeps this
orthogonal to `pathtest`'s own separately-tested `exec_path` feature),
passing the remaining tokens through as the new process's own argv. The
shell `join()`s (already used elsewhere in this file, e.g.
`fspermtest`) before printing its next prompt — ordinary blocking-shell
behavior.

**Found and fixed a real, previously-flagged-but-not-fixed gap while
verifying this**: the dual-mount QEMU image's FAT32 half has *never*
had a `bin/` directory at all (entries 45 and 49 both flagged this —
every un-suffixed exec()-family test correctly `FAILED` there — without
fixing it, since nothing forced the issue until now). Since the
shell's own fallback always execs a bare `/bin/<cmd>` for the *command
name itself* regardless of what its arguments target, the new utilities
were completely unreachable on that image even when invoked as `cat
/2/hello.txt` — the argument correctly targets ext2, but `cat` itself
could never be found. Fixed by seeding `bin/echod`, `bin/echod.elf`,
and the six new utilities onto the dual image's FAT32 half too — as a
side effect, `runtest`/`argvtest`/`pathtest`/`elftest` (previously
always `FAILED` there) now pass on that image for the first time.

**Verification**: no self-checking "ok"/"FAILED" test commands exist
for these six anymore — by design, they're real utilities now, not
tests. Verified the way an actual user would: scripted interactive
command sequences through the paced-input QEMU harness — each
utility's happy path (`mkdir`→`write`→`cat`→`ls`→`mv`→`cat`→`rm`→`rm
-r`), cross-directory `mv`, protected-file refusal (`rm fip.bin`/`write
fip.bin x`), error paths (missing arguments, nonexistent files) —
across all three QEMU images including `/2/`-prefixed invocations on
the dual image, plus the full ~30-command kept-builtin regression suite
(unaffected by the tokenization change). Three-boot stress batch,
`fsck.vfat -n`/`e2fsck -n -f` clean on every image (including no
free-cluster-count regression from entry 50's own fix).

**Real Milk-V Duo hardware confirmation**: seeded all six new utilities
onto real `DUOBOOT` and `EXT2TEST` (confirmed via `debugfs` directly
against the device, same discipline established earlier this session).
Full scripted sequence against both — `mkdir`/`write`/`cat`/`ls`/`mv`/
`rm`/`rm -r` on `DUOBOOT`, `cat`/`mkdir`/`write`/`rm -r` via `/2/` on
`EXT2TEST` — every output matched exactly, `lsproc` clean afterward.

**Files changed:** `user/shell.c3`, `user/cat.c3`, `user/ls.c3`,
`user/write.c3`, `user/rm.c3`, `user/mkdir.c3`, `user/mv.c3`,
`scripts/build_user.sh`, `scripts/build.sh`.

---

## 2026-08-21 (50) — FAT32 free-cluster-count bookkeeping (FSInfo sector)

`fsck.vfat -n` flagged "Free cluster summary wrong... Auto-correcting"
after essentially every write/delete test all session, on every FAT32
image. Root cause: `user/fs/fat32.c3` never touched the FAT32 FSInfo
sector at all — `fat32_mount()` never even parsed `BPB_FSInfo` (the BPB
field naming that sector), and neither `fat32_alloc_cluster()` nor
`fat32_free_cluster_chain()` updated it. Purely cosmetic — FSInfo's own
`free_count` is a *hint*, not authoritative data, which is exactly why
`fsck.vfat` silently recomputes and corrects it rather than erroring —
but this project has treated a clean fsck as a real correctness bar all
along (same class of gap already fixed for ext2's own
`bg_used_dirs_count`/`links_count`).

**Fix**: a new `fat32_free_count` global, established at mount time
(trusted from FSInfo if its three signatures check out and it isn't the
explicit `0xFFFFFFFF` "unknown" sentinel, otherwise recomputed once via
the same linear-scan shape `fat32_alloc_cluster` already uses to find
one free entry — not every real-world FAT32 volume populates FSInfo
correctly, so this fallback matters for more than defensiveness), kept
in sync by `fat32_alloc_cluster`/`fat32_free_cluster_chain` and written
back via a new `fat32_write_free_count()` helper.

Deliberately **not** the same failure-propagation discipline
`bg_used_dirs_count` (ext2's own equivalent) uses: by the time either
call site writes the count back, the *authoritative* state — the FAT
table entry itself — has already changed successfully. Failing the
whole alloc/free because this secondary, hint-only write failed would
be strictly worse than a stale hint: the caller would believe the
operation itself never happened while the real FAT entry already did,
exactly the inconsistency this driver otherwise works to avoid. Written
back best-effort instead.

**Verification**: no functional/shell-visible behavior change — this is
pure on-disk bookkeeping, so the actual test is `fsck.vfat -n` itself.
Full regression suite unaffected on `disk.img` and the dual image's own
FAT32 half; after a batch of writes/deletes/mkdir/rename/move, `fsck.vfat
-n` reports the free-cluster count *matching* what it independently
computes on both — no more "Free cluster summary wrong." Three-boot
stress batch (`runtest`/`elftest`/`newfile`/`deletetest`, the same
repeatable set every earlier stress batch this session used — a
`mkdirtest`/`renametest`/`movetest`/`rmdirtest` sequence isn't
idempotent when repeated back-to-back on an already-mutated persistent
image across separate boots, unrelated to this fix, confirmed by the
single earlier run succeeding cleanly) stayed clean throughout. The
mount-time "recompute via full scan" fallback path has no exercising
fixture (every QEMU image here is built via `mkfs.vfat`, which does
populate FSInfo correctly) — verified by code review, stated plainly as
an accepted gap rather than silently skipped.

**Real Milk-V Duo hardware confirmation**: `newfile`/`deletetest`/
`lsproc` all behave identically on the board (no functional change
expected or found). Pulled the SD card back to the host afterward —
`sudo fsck.vfat -n /dev/sdc1` reports no "Free cluster summary wrong"
at all (two unrelated, pre-existing notes: a harmless boot-sector-vs-
backup byte difference, and the dirty bit — set because this project's
own workflow always power-cycles without a clean unmount, not something
this entry touches).

**Files changed:** `user/fs/fat32.c3`.

---

## 2026-08-21 (49) — FAT32 chunked-read caching (exec() over FAT32)

Entry 46 fixed this exact bug class for `ext2_read_at`, flagging
FAT32's own `fat32_read_at`/`fat32_read_file_at` (`user/fs/fat32.c3`) as
having the same problem — arguably worse. On every `exec()` chunk call,
`fat32_read_at` redid the directory walk from root (same cost class
ext2 had), and `fat32_read_file_at` *also* re-walked the FAT cluster
chain from `first_cluster` every single call — `offset / cluster_size`
clusters walked from scratch each time. Unlike ext2's old bug (roughly
constant per-chunk overhead), this one grows *with* offset: chunk K
walks ~K times further than chunk 1, so total cost across one file read
was quadratic in chunk count. On real Duo hardware `DUOBOOT` (FAT32) is
the *default* mount, so every `exec()` there paid this.

**Fix**: a `fat32_cache_*` single-slot cache, same path/identity shape
entry 46 already established for ext2 (`fat32_cache_path`/
`fat32_cache_first_cluster`/`fat32_cache_file_size`), plus a second
piece FAT32 specifically needs — `fat32_cache_resume_offset`/
`fat32_cache_resume_cluster`, a live cluster-walk cursor, since FAT32
has no O(1) "index → block" math the way ext2's `i_block[]` gives for
free; reaching cluster N always means following N links from a known
start. `fat32_read_file_at` resumes from the cached cluster instead of
`first_cluster` when `offset` is at or past it, falling back to a full
walk otherwise (a backward seek, never a pattern `exec()` produces, but
kept correct regardless).

Found a real bug in-flight while implementing this, before it ever
reached a test: the natural-looking version — advance the cache in
lockstep with the existing loop's own unconditional `cluster =
fat32_next_cluster(cluster)` — silently defeats itself. That line runs
one cluster *past* wherever a call actually needed to stop, as a pure
structural side effect of the original loop shape (harmless there,
since `cluster` was just a discarded local); caching that same
one-cluster-ahead value would mean every call's own cache write
overshoots past where the *next* call's own offset lands, turning
every subsequent call into a cache miss — defeating the entire
optimization for the common case (many small chunks inside one larger
cluster). Fixed by checking `bytes_read >= len` *before* advancing/
caching, not after. Caught by tracing through the design during
planning, not by a failing test.

**Invalidation**: same 5-site unconditional pattern entries 46/47
already established for ext2 — `fat32_write`/`fat32_delete`/
`fat32_delete_recursive`/`fat32_mkdir`/`fat32_rename` each invalidate
as their first statement.

Also updated this file's own header comment, which flatly claimed "no
caching" — now scoped to say what's actually true: no *general*
whole-filesystem cache, but this one narrow exec()-loop exception.

**Verification**: `runtest`/`argvtest`/`pathtest`/`elftest` (the
un-suffixed variants, hitting FAT32 by default) all `ok` on QEMU's
`disk.img`; a FAT32 mutation immediately followed by `runtest`/`elftest`
in the same boot confirms no stale cache. Full regression suite on all
three QEMU images — the dual-mount image's own FAT32-default tests
correctly `FAILED (exec load failed)` there, the same pre-existing
fixture gap entry 45 already documented (that image's FAT32 half was
never seeded with `bin/echod`), not a regression. Three-boot stress
batch, `fsck.vfat -n` clean (same pre-existing free-cluster-count
cosmetic warning this project has always had, untouched by this entry),
`e2fsck -n -f` clean on the unaffected ext2 images.

**Real Milk-V Duo hardware confirmation**: `runtest`/`argvtest`/
`pathtest`/`elftest` all `ok` against real `DUOBOOT` — each completed
immediately, without the long multi-second burst of repeated sector
reads entry 46 had to explain away for ext2 before its own fix; visible
confirmation this fixes the same real slowness for FAT32, which is the
*default* mount on this board. `lsproc` clean afterward.

**Files changed:** `user/fs/fat32.c3`.

---

## 2026-08-21 (48) — ext2: double- and triple-indirect block support (read-only)

Extends `ext2_resolve_block` (`user/fs/ext2.c3`) past its previous
direct-blocks-plus-single-indirect reach (`i_block[0..11]` +
`i_block[12]`, capped at `12 + block_size/4` blocks — 268KB at QEMU's
1024-byte blocks) to walk all three levels the ext2 spec actually
defines: `i_block[13]` (double-indirect) and `i_block[14]`
(triple-indirect). Read-only, matching this file's own existing v1
write scope (`ext2_write` stays direct-blocks-only, unaffected) —
confirmed before writing any code that `ext2_write_inode` already
preserves `i_block[12..14]` untouched across any existing write path
(it patches specific fields into a block read fresh from disk each
time, never reconstructing the record from scratch), so this needed no
write-side changes at all to stay correct.

**Design**: `Ext2_inode_info` gains `double_indirect_block`/
`triple_indirect_block`. The old two-param cache (`char*`+`bool*`,
good for exactly one indirect block) is replaced by a new
`Ext2_block_cache` struct with independently-tracked slots for the
leaf level (shared by single/double/triple — whichever leaf a given
read is currently walking), the double/triple "top" pointer blocks
(loaded once, constant for a file), and triple-indirect's own middle
level. Identity-tracked by physical block number (`0xFFFFFFFF` sentinel
for "not loaded yet," matching this project's own established
fail-closed-sentinel convention) rather than a bare loaded bool,
because — unlike the old single-indirect case — a read walking
double/triple indirect crosses into genuinely different leaf/mid
blocks as it advances, and `0` is itself a legitimate cached value (a
sparse hole's all-zero leaf), so a bool alone couldn't tell "nothing
loaded" from "loaded, and it's the hole." A shared `ext2_resolve_leaf`
helper does the actual "load or reuse, zero-fill on a hole" work for
every level. Stack cost checked, not assumed: 4 buffers × 4096 bytes =
16KB, comfortably inside `fsd`'s own 64KB process stack alongside the
caller's existing 4KB block buffer.

In practice this driver's own 32-bit `i_size` (no `i_size_high`) already
caps any representable file at 4GB, well below what triple-indirect
alone can address — the new ceiling is a completeness property of the
implementation, not something any real file on this project could ever
approach.

**Test coverage**: no existing fixture was big enough to exercise this
(`echod` is ~70KB, well within the old single-indirect reach). Added
`bigfile.bin` — a 300000-byte, deterministically-generated
(`byte[i] = i % 256`) fixture seeded into both ext2 QEMU images
(`scripts/build.sh`, via a small `python3` one-liner rather than a
committed binary), genuinely past single-indirect reach at 1024-byte
blocks. New `bigreadtest` (`user/shell.c3`) reads it via `fs_read_at` in
1024-byte chunks (same shape `exec()`'s own loop uses) into a new
global buffer (300KB — too big for a stack local, same reasoning
`run_exec_buf` already established), then verifies *every byte*
against the known pattern rather than just checking the read
"succeeded" — a wrong block resolution would still return real,
on-disk bytes, just the wrong ones, so only a full content check
actually proves correctness. Targets `/2/bigfile.bin` unconditionally
(same reasoning `fspermtest`'s own header comment already established
for why an unprefixed path can't be trusted).

Triple-indirect's own arithmetic has no dedicated fixture — a file that
size isn't practical to generate or store for this project. Verified by
code review and by sharing the exact same `ext2_resolve_leaf`/cache
machinery double-indirect's own fixture exercises, rather than an
end-to-end test — a real, accepted verification gap, stated plainly
rather than silently assumed away.

**Verification**: `bigreadtest: ok` on the dual-mount QEMU image (where
`/2/` genuinely reaches ext2); correctly `FAILED` on the single-mount
ext2 image (mount 2 is inactive there, same pre-existing precedent
`fspermtest` already established, not a regression). Full regression
suite on all three QEMU images unaffected by the signature change
(`ext2_resolve_block`'s callers both updated), three-boot stress batch,
`e2fsck -n -f` clean on both ext2 images.

`bigreadtest` also gained better failure diagnostics along the way
(reports whether the read itself failed vs. returned the wrong byte
count vs. a specific mismatched offset, instead of a bare "FAILED") —
needed for real: the first real-hardware run failed, and it turned out
to be the exact same class of issue found twice already this session
(entries 45/46's own `seed_ext2test_bin.sh` story) — `bigfile.bin`
wasn't actually on the device, this time because the SD card's mount
had simply dropped between seeding and testing, not a mountpoint-naming
issue. The better diagnostics didn't end up needed to *find* that (a
`findmnt`/`debugfs` check from the host caught it directly), but stay in
the test now that they exist.

**Real Milk-V Duo hardware confirmation**: `bigreadtest: ok` against
real `EXT2TEST` (4096-byte blocks — genuinely different `N` than either
QEMU image, confirming the arithmetic generalizes for real, not just on
paper), `lsproc` clean afterward. At this block size the 300KB fixture
actually stays within single-indirect reach (`12 + 1024 = 1036` blocks
≈ 4.2MB) — this run exercises the refactored single-indirect path
(now going through the shared `ext2_resolve_leaf` helper) for real, not
double-indirect specifically; double-indirect itself was confirmed on
QEMU's 1024-byte-block images, where the same 300KB fixture genuinely
exceeds single-indirect's much smaller reach there.

**Files changed:** `user/fs/ext2.c3`, `user/shell.c3`, `scripts/build.sh`.

---

## 2026-08-21 (47) — ext2 recursive-delete ownership enforcement

Closes a gap the real ext2 permissions feature (entry 43) deliberately
left open: `ext2_write`/`ext2_delete` both gate overwriting/deleting an
*existing* file on `requester_uid` vs. the target's own `i_uid`/`IWUSR`/
`IWOTH` bits, but `ext2_delete_recursive` (and its own helper
`ext2_delete_dir_contents`) took no `requester_uid` at all — a non-root,
non-owner process could `rm -r` an entire subtree it didn't own,
including files it individually couldn't touch via plain `deletetest`.

**Fix**: both now take `requester_uid`. `ext2_delete_recursive` checks it
against the top-level target the same way `ext2_delete` already does;
`ext2_delete_dir_contents` checks it against *every child it walks*,
right after that child's own inode read and before anything destructive
happens to it — same placement discipline the existing protected-entry
check right above it already uses. Same caveat that existing check
already has, not a new one introduced here: entries encountered earlier
in the same directory, or already recursed into, may already be gone by
the time a denied entry is hit deeper in the tree.

The root/owner/other check itself was about to be duplicated a 3rd and
4th time on top of the two copies already in `ext2_write`/`ext2_delete`
— factored into one shared `ext2_write_allowed(inode, requester_uid)`
helper, with those two existing call sites refactored to use it too (no
behavior change there, same bits, same semantics).

`user/fsd.c3`'s `FS_DELETE` dispatch now looks up `requester_uid` once
and passes it to either `ext2_delete`/`ext2_delete_recursive`, instead of
only the non-recursive branch doing the lookup.

**Test coverage**: `fspermtest` (`user/shell.c3`) extended with two more
sub-checks in the same setuid(42) child — real two-entry trees via
`fs_mkdir`+`fs_write` (a bare empty dir wouldn't exercise the child walk
at all): recursive-deleting a root-owned tree as non-owner (must fail),
then creating, writing into, and recursive-deleting its *own* tree (must
all succeed) — same "denied on someone else's, works on your own" shape
the existing non-recursive sub-checks already establish. Root's own
cleanup at the end uses `fs_delete_recursive` too, confirming
`requester_uid == 0` still works unchanged through the new checks.

**Verification**: full regression suite on all three QEMU images —
`rmrtest` (existing plain recursive-delete test, run as root) unaffected
on the single-mount images; it fails on the dual-mount image, but that's
a pre-existing fixture gap (`nestdir` was never seeded onto that image's
ext2 half, same class of gap entry 45 already flagged for that image's
FAT32 half), not a regression. Three-boot stress batch, `e2fsck -n -f`
clean on both ext2 images.

**Real Milk-V Duo hardware confirmation**: `fspermtest: ok` against real
`EXT2TEST`, including both new recursive-delete sub-checks, `lsproc`
clean afterward.

**Files changed:** `user/fs/ext2.c3`, `user/fsd.c3`, `user/shell.c3`.

---

## 2026-08-21 (46) — exec() ext2 chunked-read caching

Follow-up to the previous entry's own flagged issue: `exec()`
(`user/user.c3`) loops calling `fs_read_at()` in ~1124-byte chunks
(`FS_MSG_MAX-4`), and `ext2_read_at` (`user/fs/ext2.c3`) was redoing a
completely fresh path walk from the filesystem root — `ext2_resolve_dir`
+ `ext2_find_in_dir` — on *every single chunk*, even though every call in
one `exec()`'s loop targets the exact same path. Loading the 71648-byte
`echod` on real hardware took ~64 chunk calls, each repeating the full
walk instead of reusing the previous one, ~1900 total sector reads for
one binary load — the "is this actually stuck?" scare from the previous
entry.

**Fix**: a single-slot cache in `ext2.c3` — `ext2_cache_valid`/
`ext2_cache_path`/`ext2_cache_inode_num` — remembers the last path
`ext2_read_at` resolved. A hit skips straight to `ext2_read_inode`
(still re-read fresh from disk every call — cheap, one block read, and
correctness-safe even if something else mutated the file between two
chunk calls of the same `exec()` loop, rather than assuming nothing else
writes during exec()). One slot, not a table: one `exec()` read loop only
ever re-reads one path. Every ext2 mutation (`ext2_write`/`ext2_delete`/
`ext2_delete_recursive`/`ext2_mkdir`/`ext2_rename`) invalidates the cache
unconditionally as its first statement, rather than checking whether it
actually touched the cached path — simpler, and `ext2_delete_recursive`
in particular never reconstructs path strings for what it removes, so
there's nothing to compare against there anyway. Cost of the
unconditional approach is only ever a hit-rate one (an unrelated
mutation mid-`exec()`-loop costs one extra resolve on the next chunk,
then it's a hit again), never a correctness one.

`ext2_read` (the non-chunked, single-call read path) is untouched —
never called in a loop, so there's no repeated-resolve cost to remove,
and leaving it out of the cache avoids a plain `fs_read()` from one
process evicting another process's mid-`exec()` cache slot for no
benefit.

**FAT32 has the identical bug, arguably worse** (`fat32_read_file_at`
re-walks the cluster chain from the start every chunk call too — an
O(offset/cluster_size) walk that gets *more* expensive each successive
chunk, unlike ext2's flat O(depth)). Flagged, not fixed here — the right
shape is different (resume from a remembered cluster+offset, not an
inode number) and deserves its own entry.

**Verification**: full regression suite on all three QEMU images
(single-mount ext2, single-mount FAT32, dual-mount) — every existing
test still passes, including `fspermtest` run *between* two `runtest2`/
`elftest2` calls on the dual-mount image specifically to prove
invalidation works (fspermtest's own writes/deletes invalidate the
cache mid-suite; the following `runtest2`/`elftest2` still correctly
re-resolve `/2/bin/echod` from scratch and pass). Three-boot stress
batch, `e2fsck -n -f` clean on both the single-mount and dual-mount
ext2 images, `fsck.vfat -n` clean on the dual image's FAT32 half (same
pre-existing free-cluster-count cosmetic warning this project has always
had there, untouched by this entry).

**Real Milk-V Duo hardware confirmation**, against the real `EXT2TEST`
partition — `runtest2`/`argvtest2`/`pathtest2`/`elftest2` all `ok`,
`lsproc` clean afterward. Noticeably but not dramatically faster than
the previous entry's "is this actually stuck?" run — expected, not a
red flag: `ext2_read_inode` still re-reads fresh from disk on every
single chunk by deliberate design (the correctness tradeoff described
above), so this cache only removes the directory-walk portion of each
chunk's cost, roughly halving the block reads per chunk rather than
eliminating almost all of them. The walk itself (the part that scaled
with path depth and was the actual source of the near-1900-sector-read
total) is gone.

**Files changed:** `user/fs/ext2.c3`.

---

## 2026-08-21 (45) — `runtest2`/`argvtest2`/`pathtest2`/`elftest2`: proper mount-2 re-verification

Follow-up to the previous entry's own discovery: `runtest`/`argvtest`/
`pathtest`/`elftest` all use bare, unprefixed paths (`"bin/echod"`,
etc.), exactly the same class of bug `fspermtest` just had — so every
earlier "confirmed against real `EXT2TEST`" claim for this test family,
and the single-indirect-block feature's own hardware confirmation two
entries back, almost certainly exercised `DUOBOOT`/FAT32 instead
whenever both are mounted, which is always true on real hardware.
Closes that out properly instead of leaving it flagged.

**New `/2/`-prefixed variants**, not edits to the originals:
`runtest2`/`argvtest2`/`pathtest2`/`elftest2` (`shell.c3`) are
near-identical copies of `runtest`/`argvtest`/`pathtest`/`elftest`,
differing only in the path(s) they target — `"/2/bin/echod"` instead of
`"bin/echod"`, `/env/PATH` set to `"/2/nonexistent/:/2/bin/"` instead of
`"nonexistent/:bin/"` for `pathtest2`. The originals stay exactly as
they were, still useful for testing whichever filesystem is the
*default* mount (which is genuinely FAT32 on real hardware, genuinely
ext2 on QEMU's own single-mount ext2 image) — this isn't a case where
the old versions were simply wrong and got replaced, they test a real,
different thing (mount 1) than the new ones (mount 2, unambiguously).

**`scripts/build.sh`'s dual-mount image** (`disk_dual.img`, backing
`scripts/launch64_dual.sh` — the one QEMU config that actually matches
real hardware's own topology, both filesystems mounted at once) never
seeded `bin/echod`/`bin/echod.elf` onto either half at all; the new "2"
variants needed them reachable at `/2/bin/echod`/`/2/bin/echod.elf`
specifically. Added to the ext2 half's own scratch-image seeding step,
alongside its existing `hello.txt`/`subdir`/`emptydir` fixtures.

**Verification**: all four new tests on QEMU's dual-mount image, full
regression suite there too (mount-1 tests correctly report
`FAILED (exec load failed)` on this image — its own FAT32 half was
never seeded with `bin/echod`, a pre-existing gap unrelated to this
entry, not a regression), the single-mount images' own original tests
reconfirmed unaffected, a three-boot stress batch, `fsck.vfat -n`/
`e2fsck -n -f` clean on the dual image's own two halves.

**Real Milk-V Duo hardware confirmation**, against the real `EXT2TEST`
partition — `runtest2: ok`, `argvtest2: ok`, `pathtest2: ok`,
`elftest2: ok`, `lsproc` clean afterward (no leaked slots). Two real
things surfaced getting there, neither a bug in this entry's own code,
both worth recording:

- **The seeding round-trip itself silently missed the real device
  once.** The scratch script that copies `bin/echod`/`bin/echod.elf`
  onto `EXT2TEST` addressed it by a guessed mountpoint path
  (`/run/media/$USER/EXT2TEST`) — `udisksctl mount` doesn't always
  reuse that exact path; a stale mount/label already claiming it makes
  udisks pick `EXT2TEST1` instead. `mkdir -p`/`cp` against the stale,
  now-wrong path silently succeeded (created a directory on the *host's
  own root filesystem*, not the device), and `ls -la` "confirmed" files
  that were never on the SD card at all. First re-verification attempt
  failed with the exact same `FAILED (exec load failed)` shape this
  whole entry exists to properly test, for a completely mundane reason.
  Fixed by resolving the mountpoint from the device (`findmnt -n -o
  TARGET /dev/sdc2`) instead of a guessed label path, refusing to
  proceed if it isn't actually mounted, and verifying the write
  independently afterward via `debugfs -R "ls -l /bin"` straight
  against the block device — bypasses the mount entirely, so it can't
  be fooled the same way twice.
- **Reading a real multi-chunk file over `/2/` on real hardware is
  legitimately slow, easy to mistake for a hang.** `ext2_read_at`
  (entry 41) does a completely uncached walk from root on *every*
  `fs_read_at()` call — re-resolving `/2/bin/echod`'s directory chain
  and both inodes from scratch each time — and each call only carries
  ~1124 bytes (`FS_MSG_MAX-4`). Loading `echod` (71648 bytes) took
  ~64 chunk calls, each doing ~5 block reads instead of 1, ~1900 sector
  reads total just for one binary — visibly the same handful of
  physical block addresses cycling on the serial console, easy to
  mistake for an infinite loop. It wasn't one — `runtest2: ok` arrived
  after waiting it out. Never surfaced before because every prior
  real-hardware exec test used files well under one chunk. Not fixed
  here (out of scope for a re-verification entry), but worth a real
  entry later: caching the resolved dir/leaf inode across one exec()'s
  own read loop instead of re-walking the path on every chunk would
  turn this from O(chunks × depth) block reads into O(chunks + depth).

**Files changed:** `user/shell.c3`, `scripts/build.sh`.

---

## 2026-08-21 (44) — `fspermtest` confirmed on real hardware — after finding it was never really testing ext2 at all

Follow-up to the previous entry, but a real bug-hunt, not a clean
confirmation. First hardware run: `fspermtest: FAILED` — both denial
checks ("overwrite root-owned file as non-owner", "delete...")
**wrongly succeeded**. Added debug prints inside `ext2_write`/
`ext2_delete`'s own enforcement branch and in `fsd.c3`'s
`proc_info()` lookup; rebuilt, reflashed, reran — and *none of the new
prints appeared at all*, even though the code they're inside of must
have run for the write/delete to return success in the first place.
That was the actual clue: the ext2 branch was never being reached.

Root cause, confirmed by reading `src/process.c3`'s own default
namespace setup and `SYS_NS_RESOLVE`'s longest-prefix match
(`src/entry.c3`): the unprefixed catch-all mount (`""`) binds to
whichever `fsd` was created *first* — `DUOBOOT`/FAT32 on this board,
not `EXT2TEST`/ext2 — any time both are mounted, which is always true
on real hardware (confirmed from this exact board's own boot log:
`fsd: FAT32 mounted...` then later `fsd: ext2 mounted...`). `fspermtest`'s
own `fs_write("owner_only.txt", ...)` (no `/2/` prefix) was resolving
straight to FAT32 the whole time — which has no uid concept to enforce
by design, so every write/delete just succeeded unconditionally. Not a
bug in the enforcement logic itself (which the debug prints, once
`/2/`-prefixed, showed working exactly as designed) — the test was
just never reaching the code being tested. QEMU's own single-mount
ext2 test image (`scripts/launch64_ext2.sh`) made the bare-path version
look correct purely by accident: ext2 happens to be the *only*, and
therefore default, mount there, so the same bare path that silently
hit FAT32 on real hardware correctly hit ext2 on that specific QEMU
image. Fixed by prefixing every path in `fspermtest` with `/2/` — the
same convention `readfile2`/`newfile2`/etc. already established for
exactly this reason — and re-verifying against QEMU's own dual-mount
image (`scripts/launch64_dual.sh`), which matches real hardware's own
topology, not the single-mount one.

**A real, unresolved implication this surfaces**: `runtest`/`argvtest`/
`pathtest`/`elftest` (and the previous entry's own "confirmed... against
real `EXT2TEST`" claim) all use bare, unprefixed paths too
(`"bin/echod"`, etc.) — meaning those real-hardware confirmations were
almost certainly *also* silently hitting `DUOBOOT`/FAT32 instead of
`EXT2TEST`, the same way `fspermtest` just was. FAT32 has no
12-direct-block limit at all, so those runs passing proves nothing
about whether the single-indirect-block work (two entries back) was
ever actually exercised on real ext2 hardware. Flagged directly to the
user rather than silently corrected — deciding whether/how to
re-verify those four tests and that claim against real `EXT2TEST`
(most likely via new `/2/`-prefixed `...2` variants, matching this same
fix) is a separate decision, not made unilaterally here.

**Verification**: `fspermtest` on QEMU's dual-mount image, repeated
across a three-boot stress batch, `lsproc` clean, `e2fsck -n -f` clean
on the ext2 half; the single-mount ext2 image's own full regression
suite reconfirmed unaffected; real Duo hardware, against the actual
`EXT2TEST` partition this time, confirmed via the same debug prints
that proved the original failure — removed once the fix was confirmed
end to end.

**Files changed:** `user/shell.c3`.

---

## 2026-08-20 (43) — Real ext2 file permissions (`i_uid` + owner/other write bits)

Closes the other gap the process-ownership permission-model entry
explicitly deferred: ext2 has real on-disk `i_uid`/permission bits
`Ext2_inode_info` never read — `mode`'s *type* bits (`EXT2_S_IFREG`/
`EXT2_S_IFDIR`) were always parsed, but its *permission* bits weren't,
and `i_uid` wasn't read at all. `ext2_create_file` already writes a
sensible default (`EXT2_S_IFREG | 0x1A4`, 0644) into every new file's
own `mode` — the permission bits were already being written correctly,
just never enforced coming back.

**Scope, matching this session's own established discipline**: gate
*overwriting an existing file* and *deleting a file* (non-recursive) by
ownership — root or the file's own owner (subject to `EXT2_S_IWUSR`),
or anyone else if `EXT2_S_IWOTH` allows it. No group concept
(racccoon's own process-uid model has none), no directory-permission
modeling (creating a file isn't gated by its directory's own
permissions, unlike real Unix), no recursive-delete enforcement (would
need checking every file it touches) — all explicit, not silently
dropped. Creating a new file (or an empty directory) stays
unrestricted, but gets stamped with its creator's real uid, so
*subsequent* writes to it are correctly gated.

**The same backdoor shape `procd` already had**: `fsd.c3` (always
root) is what actually calls `ext2_write`/`ext2_delete`/`ext2_mkdir` on
a caller's behalf — enforcing against `fsd`'s own uid would enforce
nothing. Closed the same way the `/proc/ctl` "kill" backdoor was:
`fsd.c3` already captures `from` (the real requester, via
`ipc_recv_type_gen`); before dispatching to the ext2 backend
specifically, it looks up the requester's uid via `proc_info(from, null, null, &requester_uid)`
(the 4-out-param version the permission-model entry added) and passes
it through. A failed lookup (the requester's own process already gone,
a real if rare race) fails closed to a sentinel (`0xFFFFFFFF`) that
never matches a real uid and is never root. FAT32's own write/delete
paths are untouched — its on-disk format has no uid concept at all to
enforce against.

**Found during implementation, not anticipated in planning**:
`ext2_delete` (non-recursive) already handled both a regular file *and*
an empty directory — meaning `ext2_mkdir`'s own newly-created
directories needed the same creator-uid stamp `ext2_create_file` gets,
or a directory's own creator could never `rmdir` it again once this
landed. Threaded through the same way.

**Test**: new shell command `fspermtest` — the shell (root) creates a
file directly, `rfork()`s a child that drops to uid 42 and must fail at
both overwriting and deleting it, then must fully succeed at creating,
overwriting, and deleting a file of its own (proving owner access
works and that creation really stamps the right uid, not just that
denial works). No IPC handshake needed this time: `fs_write()`/
`fs_delete()` are already synchronous, and `join()` (real Plan-9-style
— blocks until the joined process is actually gone) is exactly the
"wait for the child to be genuinely done" this needs, simpler than
`permtest`'s own IPC-based signal.

**Verification**: full regression suite unaffected (every existing
process is uid 0 by inheritance, so every existing ext2 write/delete
test keeps hitting the root-bypass path unchanged) plus `fspermtest`,
run repeatedly with `lsproc` showing no leaked slots, a three-boot
stress batch, `e2fsck -n -f` clean.

**Files changed:** `user/fs/ext2.c3`, `user/fsd.c3`, `user/shell.c3`.

---

## 2026-08-20 (42) — ext2 single-indirect blocks confirmed on real Milk-V Duo hardware, against real `EXT2TEST`

Follow-up to the previous entry: `runtest`/`argvtest`/`pathtest`/
`elftest` all pass against the real `EXT2TEST` partition on the real
C906 core, `lsproc` clean afterward — the first time any of these four
tests has run against real ext2 hardware at all (earlier real-hardware
sessions this session only ever exercised them against `DUOBOOT`/FAT32,
`EXT2TEST` staying untested for this family since seeding its `bin/`
fixtures needs root). Seeded via a one-off `sudo` script copying
`build/user/echod.bin`/`echod.elf` onto `EXT2TEST/bin/`, the same
fixtures `scripts/build.sh` already seeds onto the QEMU ext2 image.

**Files changed:** none (hardware verification only).

---

## 2026-08-20 (41) — ext2: single-indirect block support (read-only)

`ext2.c3`'s own header comment has always been explicit: "Direct block
pointers only (i_block[0..11])... single/double/triple indirect blocks
are NOT walked." That gap had, by this point in the session, blocked
four different tests — `runtest`/`argvtest`/`pathtest`/`elftest` — from
working on the ext2 test image, each failing cleanly rather than
crashing (a real, correct fix from earlier this session), but a real,
recurring limitation rather than a one-off. Closed for reads.

With this project's own `ext2_block_size=1024` (confirmed from its own
boot logs), 12 direct blocks cover 12KB; one single-indirect block adds
`1024/4=256` more block pointers — 268 blocks total, 268KB, comfortably
past racccoon's own ~70KB binaries (`echod.bin`/`echod.elf`).
Single-indirect alone is enough; double/triple stay out of scope, same
as before.

**One resolver, shared by both read paths**: `Ext2_inode_info` gained
an `indirect_block` field (`i_block[12]`, the 13th on-disk pointer
`ext2_read_inode` used to stop copying before), and a new
`ext2_resolve_block(inode, b, indirect_cache, indirect_loaded)` —
direct for `b < 12` unchanged, lazily reads the indirect block (once
per read, cached across the loop) and indexes into it for
`12 <= b < 12 + ext2_block_size/4`. Both `ext2_read` and
`ext2_read_at`'s own block loops now call this instead of indexing
`inode.block[b]` directly, with their upper bound raised from `12` to
`12 + ext2_block_size/4` to match. A `0` result within that range stays
unambiguous — a genuine ext2 sparse hole, zero-filled exactly like a
direct block always has been, including when `indirect_block` itself
is unset (every pointer within it reads as 0, same as an
entirely-unallocated indirect block would). Beyond that range, the
loop simply stops — the same "short read, not an error" discipline the
old 12-block limit already had, just at a higher boundary.

**Read-only, matching what's actually motivated**: nothing in the
current test suite writes a file bigger than 12 blocks, so
`ext2_write`/`ext2_write_inode` keep their own existing 12-direct-block
limit unchanged — explicitly scoped out, not silently dropped, noted
in the file's own header comment.

**Verification**: `runtest`/`argvtest`/`pathtest`/`elftest` all flip
from `FAILED (exec load failed)` to passing on ext2 — the direct,
motivating proof. Full regression suite (ext2-backed reads included)
unaffected — direct-block behavior is unchanged. All four newly-passing
tests run repeatedly across a three-boot stress batch, `lsproc` clean
throughout, `e2fsck -n -f` clean.

**Files changed:** `user/fs/ext2.c3`.

---

## 2026-08-20 (40) — ELF loading confirmed on real Milk-V Duo hardware

Follow-up to the previous entry: `elftest: ok` on the real C906 core
(`DUOBOOT`/FAT32) alongside `runtest` re-confirmed, `lsproc` clean
afterward. The multi-segment, per-segment-permission-union staging and
the real `e_entry` redirect both hold outside QEMU's emulation.

**Files changed:** none (hardware verification only).

---

## 2026-08-20 (39) — ELF loading for `SYS_EXEC`

Closes the last item flagged in the original exec() plan: "no ELF
loading... a real ELF loader is a substantially bigger, separate
project." `SYS_EXEC` can now load real ELF64/RISC-V executables, not
just racccoon's own flat-binary format.

**Confirmed via `llvm-readelf` before writing any code** that this
would be a genuinely non-trivial loader, not a hand-wave: racccoon's
own toolchain output (`build/user/echod.elf`, before `objcopy` strips
it to the flat binary the rest of this session's `exec()` work used)
has 3 `PT_LOAD` segments with 3 different permission combinations
(`.text` R-E, `.rodata` R, `.data`+`.bss` RW), and the last segment's
`memsz` (0x10150) far exceeds its `filesz` (0x30) — a real `.bss` gap
that must be zero-filled, not read from the file. Segments 0 and 1 are
even adjacent enough to share one physical page
(`0x1001000-0x1001fff`) with *different* permissions each — a real
case a hand-crafted test fixture would have had to specifically
manufacture, and this one didn't need to.

**Detection**: `SYS_EXEC` (`src/entry.c3`) sniffs the magic bytes
(`\x7FELF`) at the top of its case; `exec()`'s own user-mode wrapper
(`user.c3`) is completely unchanged — it already just reads bytes and
hands them over, no format opinion of its own. Both the ELF and
flat-binary paths converge on the same shared tail this session
already built (argv staging, old-image teardown, TLB flush,
`saved_sepc` redirect). Kept inlined in the switch like every other
case here, not factored into a helper — a documented, proven
constraint of this codebase (an unexplained c3c compiler bug: "a call
out to a moderately complex function from inside this switch has
reproducibly broken boot before"), so this makes the case long but
consistent with the existing pattern rather than a deviation from it.

**Validation before trusting anything**: `ELFCLASS64`, little-endian,
`ET_EXEC` only (rejects `ET_DYN`/PIE — would need real relocation
processing, out of scope), `EM_RISCV`, segment count bounded, program
headers bounds-checked against the real buffer size before a single
byte of any header is trusted. Per `PT_LOAD` segment: `filesz <= memsz`,
`vaddr`/`memsz` bounded without risking overflow, source range checked
against the actual file size — any failure aborts before any
staging/teardown, same "fail toward not losing what's already there"
discipline the image/argv staging already established.

**Staging, one real wrinkle**: a page-table entry can't grant
partial-page permissions, but `echod.elf`'s own segments 0/1 genuinely
share a page with different flags — confirmed above, not hypothetical.
Fixed by unioning every touching segment's own permission flags into
that page rather than letting the last one silently win, tracked in a
new parallel `exec_seg_perm[]` array alongside the existing
`exec_staged[]`. `alloc_pages()` already zero-fills every page it hands
back (confirmed in `src/allocation.c3`) — the `.bss` gap and any
inter-segment page padding come out correctly zeroed for free.
`exec_page_count` became "highest touched page index + 1" rather than
a plain size-derived count, so a genuine gap between segments stays
unmapped, not silently zero-filled — the mapping loop now skips any
untouched slot.

**Entry point**: `e_entry`, not an assumed `USER_BASE` — validated to
land on a page a real segment actually staged, then used for the
redirect. For racccoon's own binaries this happens to equal `USER_BASE`
anyway (confirmed via `llvm-readelf -h`), but a real loader shouldn't
assume that.

**Test**: `elftest` (`shell.c3`) — same `rfork`+sync+`exec`+"ready"
handshake `runtest` already established, execs `bin/echod.elf` (the
real ELF, seeded by `scripts/build.sh` alongside the existing flat
`bin/echod`) instead of the flat binary, same "hi echod" echo check.
One naming wrinkle found immediately: the fixture was first seeded as
`bin/echod_elf`, which doesn't fit FAT32's 8.3 short-name format —
mtools generated an `ECHOD_~1` alias this driver's simple 8.3
converter (`fat32_name_to_8_3`, a plain 8-character truncation, no LFN
support) can't reproduce, so the lookup failed before `SYS_EXEC` ever
ran. Renamed to `bin/echod.elf` (5+3 characters, fits 8.3 exactly, no
alias needed).

**Verification**: full regression suite (through `permtest`)
unaffected — the flat-binary path is untouched code, only reached when
the magic-byte check fails — plus `elftest` on both filesystems
(`FAILED (exec load failed)` on ext2, the same pre-existing
12-direct-block limit `runtest`/`argvtest`/`pathtest` already hit
there), run repeatedly with `lsproc` showing no leaked slots, a
three-boot stress batch, `fsck.vfat -n`/`e2fsck -n -f` clean.

**Files changed:** `src/entry.c3`, `scripts/build.sh`, `user/shell.c3`.

---

## 2026-08-20 (38) — `permtest` confirmed on real Milk-V Duo hardware

Follow-up to the previous entry: every `permtest` sub-check (`setuid()`
drop, then the four denied attempts: direct `kill()`, re-`setuid(0)`,
`srv_post()` hijack, and the `/proc/ctl` path) passes on the real C906
core, alongside `killtest` re-confirmed (root killing root through the
now-permission-checked procd path), `lsproc` clean afterward.

**Files changed:** none (hardware verification only).

---

## 2026-08-20 (37) — A real permission model: process ownership (`uid`)

Closes a gap flagged in this kernel's own code, not just a plan
document: `SYS_KILL` and `SYS_SRV_POST` (`src/entry.c3`) both carried
comments explicitly saying "no permission check... this kernel has no
user/permission concept at all, so restricting *which* caller can act
on *which* target would be security theater, not a real boundary."
This closes that gap for exactly the two places it was flagged.

**`Process.uid`** (`src/process.c3`): every boot-time server
(`create_process()`) is explicitly root (uid 0), the same "explicit,
not relied-on zero-init" reasoning already used for `parent_pid`.
`SYS_RFORK` copies it into the child unchanged, same as
`parent_pid`/`parent_generation`; `SYS_EXEC` doesn't touch it at all —
same pid, same namespace, same uid, matching everything else that
already survives `exec()` unchanged.

**`setuid()`** (new `SYS_SETUID`) is the *only* privilege primitive
added, deliberately minimal: sets the caller's own uid, and only while
still root — once dropped, permanent, no way back up. No login, no
credentials, just the standard `fork()` + child-calls-`setuid()`
idiom. Without it every process would stay root forever by
inheritance and the new checks below would never actually deny
anything.

**`SYS_KILL`** now requires root or the same uid as the target.
**`SYS_SRV_POST`** now requires root or the same uid as the *current,
live* holder of a name — but only when reclaiming one; a first-time
claim (free slot) stays unrestricted, nothing to protect yet, and a
name whose old holder is actually dead is still the "server restart"
case, also unrestricted.

**The backdoor this would otherwise leave wide open**: found while
tracing `killtest`'s own existing test — it kills through
`user/procd.c3`'s `/proc/<pid>/ctl` `FS_WRITE` handler, which calls the
raw `kill()` syscall *as procd itself*, and procd is a boot-time
server, always root. Gating only the raw syscall would leave
`/proc/<pid>/ctl` as a complete, ungated root-kill-as-a-service
backdoor around the entire model: any process, any uid, writes "kill"
and it always succeeds, since the kernel only ever sees procd's own
uid, never the real requester's. Fixed in `procd.c3` itself, not the
kernel — matching this codebase's existing split between mechanical
kernel syscalls and policy living in user-mode servers (e.g. `fsd.c3`'s
own `FS_READ_AT` wire-format handling). `proc_info()` gained a 4th
out-param, `uid_out` (switching its wrapper from the plain 3-arg
`syscall()` to `syscall4`, same shape `fs_read_at` already uses for its
own 4th argument — safe to widen this one directly rather than adding
a new syscall number the way `SYS_IPC_RECV_GEN` did, since `proc_info()`
has exactly one real caller-set, updated in this same change, not an
ABI with independent consumers). procd's "kill" handler now looks up
both the real requester's uid (`from`, already captured by
`ipc_recv_type_gen`) and the target's before ever calling `kill()`, and
refuses the write otherwise.

**Test**: new shell command `permtest` — three processes: the shell
(root), a "victim" child (inherits root, posts itself as `"victim"`,
then spins forever, same shape `killtest`'s own spin-child already
uses), and an "attacker" child that drops to uid 42 then tries, and
must fail at, every angle: `kill()` directly, `setuid(0)` again
(re-escalation), `srv_post("victim")` (hijacking its name), and the
`/proc/<pid>/ctl` "kill" path — the one that would silently succeed
without the procd-side fix above. The parent confirms the victim
genuinely survived every attempt (`proc_info()`, not just trusting the
attacker's own error codes) before killing it itself, root's own
legitimate path.

**Explicitly out of scope, and why**: `SYS_IPC_SEND`/`SYS_IPC_REPLY` —
servers must stay reachable by any caller, gating message delivery
would break this kernel's whole "everything is a server anyone can
talk to" model, not fix a real gap. `SYS_NS_MOUNT`/`SYS_NS_UNMOUNT` —
already correctly self-scoped (only ever touches the caller's own
namespace). Real filesystem permission bits — ext2 actually has
on-disk `i_uid`/`i_gid` that this driver has always deliberately never
read (confirmed via direct survey of `Ext2_inode_info`); wiring real
per-file ownership through fsd's wire protocol is a separate, much
larger project. Any login/user-database concept — this kernel has
none, `uid` stays an opaque identity, not a name, matching Plan 9's
own minimal approach.

**Verification**: full regression suite (`killtest` included — still
root killing root through the now-checked procd path) plus `permtest`,
both filesystems, `permtest` run repeatedly with `lsproc` showing no
leaked slots; a three-boot stress batch; `fsck.vfat -n`/`e2fsck -n -f`
clean.

**Files changed:** `src/process.c3`, `src/entry.c3`, `user/user.c3`,
`user/procd.c3`, `user/envd.c3`, `user/shell.c3`.

---

## 2026-08-20 (36) — `exec_path()`/`pathtest` confirmed on real Milk-V Duo hardware

Follow-up to the previous entry: `pathtest: ok` on the real C906 core
(`DUOBOOT`/FAT32), alongside `runtest`/`argvtest` re-confirmed in the
same boot, `lsproc` clean afterward. The deliberately-wrong-first-
prefix search (`"nonexistent/:bin/"`) genuinely exercises multi-prefix
resolution on real hardware, not just QEMU's own timing.

**Files changed:** none (hardware verification only).

---

## 2026-08-20 (35) — `$PATH`-style `/bin` lookup for `exec()`

Closes the last item the exec() plan flagged explicitly out of scope:
`runtest`/`argvtest` both hardcode `"bin/echod"` — there was no way to
name a program by its bare filename and have it resolved against a
real search list.

**`exec_path()`** (`user.c3`) is a separate function, not a mode of
`exec()` itself — matching Unix's own split between `execve()` (exact
path) and `execvp()` (`$PATH`-searched); `exec()` keeps its current,
unambiguous "run exactly this file" meaning. It tries a colon-separated
search list of directory prefixes in order, building each full
candidate path and calling the existing `exec()` with it — since
`exec()` only ever returns on failure, the loop naturally moves to the
next prefix.

**The search list is `/env/PATH`**, not a new mechanism: real Plan 9
doesn't have `$PATH` at all (it uses namespace binds/union directories,
which this kernel's filesystem backends don't support), but `$PATH`-
style search is what was actually asked for, and this session already
built exactly the right per-process configuration mechanism for it
(`/env`, `user/envd.c3` — including lazy inheritance across `rfork()`).
Reusing it beats inventing a second one. No `/env/PATH` set falls back
to a single hardcoded default, `"bin/"` — matching every existing test
fixture's own path exactly, so callers that never touch `/env/PATH` see
identical behavior for free. (One small wrinkle: `envd.c3`'s own
`ENV_VALUE_MAX` isn't actually reachable from `user.c3` — each server
is its own separate `c3c` compilation, scripts/build_user.sh builds
each from its own source list, and `user.c3` is the only file they all
share. `exec_path()` has to carry its own matching constant,
`PATH_VAR_MAX`, rather than importing the real one.)

**Test**: new shell command `pathtest` sets `/env/PATH` to
`"nonexistent/:bin/"` — a deliberately wrong first prefix — before
`rfork()`, so the child inherits it, then calls
`exec_path("echod", ...)`. Success is only possible if `exec_path()`
genuinely tried the first prefix, failed, and moved to the second, not
just that the correct-by-default fallback still works.

**Verification**: full regression suite plus `pathtest`/`runtest`/
`argvtest`, `pathtest` run repeatedly with `lsproc` showing no leaked
slots; a three-boot stress batch; `fsck.vfat -n`/`e2fsck -n -f` clean;
`pathtest` fails the same clean way on ext2 that `runtest`/`argvtest`
already do there (the driver's pre-existing 12-direct-block limit, not
a new gap).

**Files changed:** `user/user.c3`, `user/shell.c3`.

---

## 2026-08-20 (34) — `argv` confirmed on real Milk-V Duo hardware

Follow-up to the previous entry: `argvtest: ok` and `runtest: ok` on
the real C906 core (`DUOBOOT`/FAT32), `lsproc` clean afterward (only
the six always-on servers plus the shell, no leaked slots from either
test's own child). The register-repurposing (`a0`/`a1` as `argc`/argv
base instead of a syscall return value), the `just_execd` check's
`>= 0` adjustment, and `user_entry()`'s explicit zeroing all hold
outside QEMU's emulation, not just on it.

**Files changed:** none (hardware verification only).

---

## 2026-08-20 (33) — `argv` at exec() time

Closes a gap the exec() plan flagged explicitly out of scope: a
freshly-exec'd process previously had no way to learn what it was
supposed to do beyond `/env` — no `argc`/`argv` at all.

**Wire format**: `exec()`'s caller already owns a buffer the image gets
read into (`user.c3`) — argv strings get packed right after the image
content, in that same buffer, NUL-separated (`"foo\0bar\0"` for
`argc=2`). Real pointers wouldn't survive being copied into a brand new
address space, so a flat, self-describing blob is the only thing that
can cross that boundary. `exec()` gained two parameters (`char** argv`,
`int argc`); the one existing caller (`runtest`, `shell.c3`) now passes
`null, 0`, unchanged behavior.

**`SYS_EXEC`** (`src/entry.c3`) stages the argv blob as a second,
smaller pass of the same page-staging loop already used for the image
(new `EXEC_MAX_ARGV_SIZE`, 4096 bytes — plenty for real CLI args), maps
it right after the image's own last page (`ARGV_BASE`), and hands the
new process `argc`/`ARGV_BASE` via `a0`/`a1` — repurposing the same
registers a normal syscall would use for its return value, safe here
because control never returns to the caller on success (the
`saved_sepc` redirect from last session's own fix means that
return-value-reading code never executes). This needed one adjustment
to that same fix: `handle_trap()`'s `just_execd` check used to test
`f.a0 == 0` to detect a successful `SYS_EXEC`; now that `f.a0` carries
`argc` (which can legitimately be nonzero), the check became
`(long)f.a0 >= 0` — a real failure still sets `-1`, so the distinction
still holds.

**Getting it into a real `main()`**: existing binaries' `main()`
signatures stay untouched — most don't care about argv, and this
codebase has no default-parameter syntax to make an extra param free.
`start()` (`user.c3`, naked asm, already confirmed to leave `a0`/`a1`
untouched from `sret` through to `call main`) stashes both into two new
globals before calling `main()`. A new, opt-in `get_argv()` lazily
parses that blob into a small static pointer array on demand — only a
caller that actually wants its own argv reaches for it.

**Boot-time processes needed a real fix, not just an omission**:
`user_entry()` (`src/process.c3` — the trampoline `create_process()`
uses for a never-yet-run process) never touched `a0`/`a1` before its own
`sret`, leaving whatever the kernel's own boot-time code last put there
in the physical registers. Every `create_process()`'d server would have
read that leftover garbage as if it were a real argv blob pointer.
Fixed by explicitly zeroing both there, so every boot-time process
(echod, diskd, fsd, procd, envd, shell) gets a deterministic `argc=0`.

**Test**: `echod.c3` now calls `get_argv()` at startup; if `argc > 0`,
`argv[0]` replaces its hardcoded `P9_TREAD` canned reply (its raw-echo
behavior, what `runtest` checks, is unchanged either way). New shell
command `argvtest` — same `rfork`+sync+`exec`+"ready" handshake
`runtest` already established, reused rather than duplicated in spirit
(each is its own small copy, this codebase's own established pattern
for inline `rfork()` test children) — execs `bin/echod` with one real
argument, then confirms it actually arrived via a `P9_TREAD` round trip
matching that argument, not just that `exec()` returned success.
`p9test` (the existing command exercising `P9_TREAD` against boot-time
echod, pid 2, argc=0) still gets the original hardcoded reply,
confirming `user_entry()`'s zeroing holds.

**Verification**: full regression suite plus `argvtest`/`runtest`, both
run repeatedly in the same boot with `lsproc` showing no leaked slots
afterward; a three-boot stress batch; `fsck.vfat -n`/`e2fsck -n -f`
clean on both test images; `argvtest` on ext2 fails the same clean way
`runtest` already does there (the driver's own 12-direct-block limit,
`echod.bin` exceeds it — a pre-existing, documented limitation, not new
here).

**Files changed:** `user/user.c3`, `src/entry.c3`, `src/process.c3`,
`user/echod.c3`, `user/shell.c3`.

---

## 2026-08-20 (32) — `exec()`/`runtest` confirmed on real Milk-V Duo hardware

Follow-up to the previous entry: built `kernel_duo.elf`, packaged
`fip_duo.bin`, seeded `bin/echod` onto the real `DUOBOOT` FAT32
partition (same file `build/user/echod.bin` QEMU's own test images use),
flashed via the existing `scripts/flash_duo.sh` convention (`fip.bin` as
a literal file on `DUOBOOT`, not a raw `dd`). `runtest` on real hardware:
`runtest: ok` — the `saved_sepc`-clobber fix, the TLB flush, and the
IPC-race fix from the previous entry all hold on the real C906 core, not
just QEMU's emulation. Didn't seed `EXT2TEST` this round — writing there
needs root (the partition's owned by `root` on this machine) and the
outcome is already known from QEMU: `echod.bin` exceeds ext2's own
12-direct-block limit, so it would just fail the same documented way.

**Files changed:** none (hardware verification only).

---

## 2026-08-20 (31) — `/bin`: a real `exec()` syscall, and three real bugs found chasing it

The first real `/bin` support: a Plan-9/Unix-style `exec()` that replaces
the *calling* process's own image in place — same pid, same page table,
same namespace (so `/env`'s own vars survive it unchanged, matching real
`exec()` semantics) — composing with `rfork()` exactly the way Unix
`fork()`+`exec()` do. Getting the feature itself in place was the easy
part; getting it to actually *work* took three separate, genuinely
different bugs, each hiding the next one.

**The feature, in shape:**
- **`FS_READ_AT`** (`user.c3`, wire verb 26): a new, distinct verb rather
  than widening `FS_READ` — same reasoning as `SYS_IPC_RECV_GEN` over a
  widened `SYS_IPC_RECV` earlier this session. Real binaries are
  70-105KB; `FS_READ`'s one-message-per-call shape (`FS_MSG_MAX`=1128
  bytes) can't load one at all. `fat32_read_at`/`fat32_read_file_at` and
  `ext2_read_at` (`user/fs/*.c3`) add offset-aware reads alongside the
  existing offset-0 versions, left untouched; `fsd.c3` dispatches the
  new verb the same shape as the old one, plus the offset field.
- **`SYS_EXEC`** (`src/entry.c3`, syscall 24): takes an already-fully-read
  image + size (the read happens user-side, in `user.c3`'s own `exec()`,
  before this syscall ever runs — a failed read never risks the calling
  process's *existing* image). Stages every new page first (a failed
  allocation leaves the old image untouched), only then frees the old
  image's `PAGE_U` leaves and maps the new ones, then redirects
  execution by setting `saved_sepc = USER_BASE`.
- **`exec()`** (`user.c3`): loops `fs_read_at()` until EOF or the
  caller's buffer is exhausted, then calls `SYS_EXEC`. Buffer is
  caller-owned (a large static buffer in `user.c3` itself would bloat
  every binary that links it, whether or not it ever calls `exec()`).
- **`runtest`** (`shell.c3`): `rfork(RFPROC)`s a child that execs
  `bin/echod` — a real, already-built binary (`build/user/echod.bin`,
  known behavior, already exercised at boot as pid 2), seeded onto both
  test images by `scripts/build.sh` from the already-built binary rather
  than writing a new one just for this.

**Bug 1 — `saved_sepc` clobbered right after being set.** First real
symptom: `runtest` panicked with an illegal-instruction trap inside what
should have been the new image, at an offset that was legitimately
zero-filled `.bss` in the real file on disk — meaning execution was
landing somewhere it should never reach via normal control flow. Ruled
out data corruption directly: a checksum of the full chunked read,
mirroring `exec()`'s own read loop exactly, matched the real file
byte-for-byte. The actual cause was one layer up, in `handle_trap()`
(`src/entry.c3`): every syscall unconditionally sets
`current_proc.saved_sepc = user_pc + 4` *after* the syscall's own switch
case returns, to resume right past the `ecall` that made it — correct
for every syscall except this one, where the whole point is to resume
somewhere else entirely. `SYS_EXEC`'s own case was setting
`saved_sepc = USER_BASE` correctly; this line ran right after and
silently overwrote it back to the old image's own address, so execution
kept resuming inside the *old* code (in this case the old image's own
`.bss`, past the point that old code ever legitimately jumped to)
instead of the new one. Fixed by capturing the syscall number before
`handle_syscall()` runs and skipping the `+4` specifically when it was a
successful `SYS_EXEC` — a one-line, syscall-specific exception is the
whole fix, but it took a full checksum-verification pass to rule out
*where it wasn't* before finding it.

**Bug 2 — a real IPC race, exposed for the first time by this feature.**
Once `exec()` correctly replaced the image, `runtest`'s own
synchronization hung. Root cause: `SYS_IPC_RECV`'s single inbox slot per
process has no per-sender filtering (`src/entry.c3`) — delivery happens
the instant the slot is free, regardless of which conversation the
receiver thinks it's in. Every earlier test's child does exactly one
IPC conversation before reaching a stable state (`srvtest`'s child posts
and goes straight into its serve loop); `runtest`'s child is the first
to have a *second* conversation of its own (the `FS_READ_AT` round trips
to `fsd`, inside `exec()`) still in flight while an outside process
might message it. The test's own initial "ping immediately after
rfork" could land mid-round-trip and get misread as `fsd`'s reply,
corrupting `exec()`'s own read loop.

Two-part fix. `p9_call()` (`user.c3`, the client-side request/reply
helper every 9P-lite caller funnels through) now checks the reply's
actual sender against `dest_pid`; a message from anyone else gets
bounced back to *its own* sender as a new reserved verb, `P9_STRAY`,
rather than being misread as the real reply — this protects every
existing `p9_call` user, not just this one. A retry-with-backoff version
of `runtest` built on top of that bounce was tried and rejected: `fsd`'s
own round trip through `diskd` for a deep offset (this driver's
offset-skip walks clusters/blocks one at a time — see `FS_READ_AT`'s own
comment) can run longer than any fixed backoff, so the retries just kept
re-winning the race against `fsd`'s real reply, forever. Fixed properly
instead by removing the race altogether: `exec()` gained an optional
`notify_pid` parameter — right after its last `fs_read_at()` and before
the point of no return, it sends that pid one message. `runtest`'s
parent does a `srvtest`-style initial sync (proving the child is alive
before sending anything else), then blocks on exactly that one
notification before ever messaging the child again — by the time it
arrives, the child is guaranteed to never talk to `fsd` again, so no
race is possible. (The child also has to report an *unsuccessful*
`exec()` this same way — found by testing the ext2 case below: a failed
load never sends "ready" on its own, and the parent was blocking on it
forever.)

**Bug 3 — ext2's own real scope limit, now actually reachable.**
`runtest` against the ext2 test image (`scripts/launch64_ext2.sh`)
didn't hang — it panicked with a store page fault, `sepc` right at the
top of the new image's own `user.syscall` stub. `ext2_read_at`
(`user/fs/ext2.c3`) only ever reads this driver's 12 direct blocks (no
indirect-block chain — the same limit `ext2_read()` has always had); for
an offset past block 11 it returned `0` (clean EOF) instead of an error,
since nothing had ever asked it to read that far before — every existing
fixture is well under 12KB. `echod.bin` (70KB) is the first file this
driver was ever asked to read past that point. `exec()`'s own read loop
trusts `0` completely and stops there, so it installed a genuinely
truncated image — the copy itself wasn't corrupted, but `__stack_top`
(a link-time constant baked into the binary regardless of how much of
it actually got loaded) pointed past the pages `SYS_EXEC` had mapped.
Fixed by having `ext2_read_at` return `-1` when the offset is genuinely
within the file but past what this driver can reach, so `exec()` fails
cleanly instead of installing a truncated image. `runtest` now correctly
reports `FAILED (exec load failed)` on ext2 rather than crashing the
kernel — a real, standing limitation of this driver (no indirect-block
support), not something worth building out for this feature alone.

**Verification:** full regression suite plus `runtest`, both filesystems
— clean on FAT32 (`runtest: ok`, `lsproc` shows no leaked slots even run
repeatedly in the same boot), clean *failure* on ext2 for the reason
above. Three-boot stress batch. `fsck.vfat -n`/`e2fsck -n -f` both clean
(FAT32's lone "free cluster summary" mismatch is the pre-existing,
already-documented FSInfo-caching quirk this driver has always had, not
new).

**Files changed:** `user/user.c3`, `user/fsd.c3`, `user/fs/fat32.c3`,
`user/fs/ext2.c3`, `src/entry.c3`, `src/process.c3` (`flush_tlb()` —
`SYS_EXEC` remaps this process's own live virtual addresses without a
`satp` write, so `switch_context`'s own TLB flush never fires for it;
needed regardless of the three bugs above, since a stale mapping would
otherwise let the CPU keep serving the *old* image's translations),
`scripts/build.sh`, `user/shell.c3`.

---

## 2026-08-20 (30) — EXT2TEST fixtures restored, closing out the flashing-incident recovery

Follow-up to the previous entry: the full repartition there left
`EXT2TEST` freshly formatted but empty — the standard fixture set
(`hello.txt`, `subdir/nested.txt`, `emptydir/`, `nestdir/inner.txt`,
`nestdir/innerdir/inner2.txt`) needed restoring before the `"/2/"`-
targeting regression commands (`readfile2`/`readsubfile2`/`newfile2`/
`newsubfile2`/`deletetest2`/`rmdirtest2`) had anything real to exercise.
Restored via `debugfs -w` directly on the block device — the exact
same technique, and the exact same source files (`disk-ext2/hello.txt`,
`disk-ext2/subdir/nested.txt`), `scripts/build.sh` already uses to seed
`build/disk_ext2.img` for QEMU.

**Confirmed on real hardware afterward**: `fsd`'s own idempotent `/tmp`
auto-create had already fired on first mount against the freshly-seeded
filesystem (a `tmp/` directory present with an epoch timestamp, seen in
the post-seed directory listing, before any test explicitly touched
it) — real, independent confirmation that mount-time write logic runs
correctly against a genuinely fresh filesystem, not just the QEMU test
images this codebase has run it against so far. Then the full `"/2/"`
suite itself: all six commands correct, content byte-matching what was
seeded (`"Hello from ext2!"`, `"Hello from an ext2 subdirectory!"`),
dynamic write/read/delete/rmdir all clean.

This closes out the recovery from the previous entry's flashing
mistake — `EXT2TEST` is back to full parity with what a from-scratch
`scripts/build.sh` run produces for QEMU, confirmed by direct
real-hardware exercise rather than assumed from the seed step alone.

---

## 2026-08-20 (29) — Real Duo hardware: everything since /srv confirmed, and a real flashing lesson

Every feature from this session — `/srv`/`/tmp`/`/proc` (read + write),
`SYS_KILL`, the reply-side stale-pid IPC fix, rename-cycle detection,
real `SYS_SRV_POST`/`SYS_NS_MOUNT` dynamic namespace binding, `/env`
(including lazy inheritance), and the `std::nolibc` stdlib port — run
on the real Milk-V Duo now, not just QEMU. `envtest`/`srvtest`/
`killtest`/`mkdirtest`/`renametest`/`movetest`/`cycletest`/`racetest`/
`mutextest` all match QEMU exactly, including edge cases (`killtest`'s
re-kill-of-a-dead-pid and bogus-ctl-command checks). `mutextest`
specifically is the first real-hardware run of `std::nolibc::atomic`'s
actual RV64 `lr.w`/`sc.w`/`amoadd.w` instructions, not just QEMU's own
emulation of them — real hardware confirmed the same 16/16 result.

**A real flashing mistake, corrected**: got this board's own flashing
convention wrong on the first attempt — assumed a generic "raw `dd` to
disk offset 0" convention without checking this project's own
documented history first. The actual, already-established convention
(confirmed back in the `2026-08-17 (6)` entry, from this exact board's
own real-hardware bring-up) is different: BootROM reads `fip.bin` as a
literal *file* inside the `DUOBOOT` FAT32 partition's own filesystem,
not a raw region before it. `DUOBOOT` itself starts at sector 2048
(`board::FS_PARTITION_START_SECTOR`), not sector 0 — a raw
`dd if=fip.bin of=/dev/sdX bs=1M` starting at offset 0 overwrites the
MBR/partition table instead, which is exactly what happened
(`lsblk` afterward showed zero partitions where `DUOBOOT`/`EXT2TEST`
used to be). Recovered with a full repartition (`sfdisk` recreating
both partitions at their exact original sectors/sizes, `mkfs.vfat`/
`mke2fs`, then copying `fip.bin` onto `DUOBOOT` the correct way) — full
data loss on the card's test fixtures, but the board itself was never
at risk (the corrupted region was purely the SD card's own partition
table, nothing written to the chip's own boot ROM/flash).

**New `scripts/flash_duo.sh`**: the correct, safe, repeatable flash
step (mount `DUOBOOT`, copy `fip.bin` onto it as a file, unmount) —
doesn't touch partitioning or existing filesystem content, safe to run
after every rebuild. Doesn't attempt to fix a missing partition table;
that needs the same manual `sfdisk`/`mkfs.vfat`/`mke2fs` recovery this
entry describes, and it's destructive enough (wipes whatever's
currently on the card) that it isn't worth automating into a script
that runs unattended.

**Files changed:** `scripts/flash_duo.sh` (new).

---

## 2026-08-20 (28) — std::racccoon -> std::nolibc, gated by a real opt-in feature

Two refinements to the previous entry's `std::racccoon::*` module,
both in the c3c fork (`~/Workspace/c3c`, still uncommitted there —
deliberately, same as before), prompted by wanting something less
project-branded and more genuinely reusable.

**Location**: tried moving `mem.c3`/`atomic.c3`/`fmt.c3` to live inside
the *real* canonical files (`lib/std/core/mem.c3`, `lib/std/atomic.c3`)
as additional `@feat`-gated blocks, matching how `core/mem.c3` already
keeps its `FREESTANDING_WASM`/`NO_LIBC` variants in one file. Tested
directly and it doesn't work: those real files have *unconditional*
top-level imports (`std::core::mem::allocators`, `std::os::posix`,
`std::math`, `std::io`) that fail immediately when the file is passed
as a standalone source argument under `--use-stdlib=no`, regardless of
any `@feat` gate further down — confirmed by literally trying it, not
assumed. This is exactly *why* the real stdlib's own freestanding
pieces (`_nolibc/nolibc.c3`, `_nolibc/math_nolibc/`) are separate,
self-contained files rather than gated blocks in the main ones — same
constraint, same answer. So: renamed the *module path* instead —
`std::racccoon::{mem,atomic,fmt}` -> `std::nolibc::{mem,atomic,fmt}`,
staying physically in `lib/std/_nolibc/` (not nested under a
project-branded subdirectory anymore).

**Gating**: switched from the ambient `@feat(NO_LIBC)` (automatically
active for *any* freestanding build, not just racccoon's) to an
explicit `@feat(RACCCOON)`, activated only via a new `-D RACCCOON` flag
in `scripts/build_user.sh`'s own `c3c compile-only` call. Verified both
directions directly: compiles and produces the expected
`std.nolibc.mem.o`/`std.nolibc.fmt.o` (atomic's generics inline into
the caller, as before) with `-D RACCCOON` present; every symbol from
all three modules is completely unreachable (`'mem::copy' could not be
found`) without it. This means the module can sit in the fork's shared
stdlib tree without silently activating for some *other* freestanding
project built against the same fork that never opted in — dormant by
default, not by convention.

**Verified**: full regression suite clean on both filesystems
(`mutextest` again exercising the real hardware atomics through the
renamed/re-gated module), a 10-boot stress batch clean, `e2fsck -n -f`/
`fsck.vfat -n` clean after.

**Files changed:** `scripts/build_user.sh` (`-D RACCCOON`,
`RACCCOON_STD_DIR` default path updated), `user/user.c3`/`procd.c3`/
`shell.c3`/`envd.c3`/`fsd.c3`/`diskd.c3`/`fs/ext2.c3` (imports and
qualified call sites updated to `std::nolibc::*`). Outside this repo:
`~/Workspace/c3c`'s `lib/std/_nolibc/{mem,atomic,fmt}.c3` renamed from
`std::racccoon::*` and re-gated (still uncommitted there).

---

## 2026-08-20 (27) — Moving the stdlib adaptation into std::racccoon, in a real c3c fork

Took the previous entry's `user/mem.c3`/`user/atomic.c3`/`user/fmt.c3`
one step further: instead of vendoring copies per-project, they now
live as `std::racccoon::mem`/`std::racccoon::atomic`/`std::racccoon::fmt`
in a real c3c stdlib tree — the user's own fork
(github.com/8lall0/c3c) — reachable via a plain `import` like any other
stdlib module, no more per-binary file-list copying.

**The fork was stale first**: `origin/master` had zero commits of its
own (a plain mirror that fell behind, not a real divergent fork) —
turned out to be a clean ancestor of upstream's own `v0.8.3` tag, so
fast-forwarding it was risk-free and landed on the *exact* commit
racccoon's system-installed `c3c` already builds with (confirmed by
git hash, not just version string). Rebuilt natively (`cmake`+`ninja`,
already available — no need for the fork's own Docker-based
`build.sh`) after fixing a stale `CMakeCache` (wrong compiler paths)
and an LLVM version conflict (auto-detected LLVM 20 instead of the
system's actual 22.1.8, explicit `-DLLVM_DIR` fixed it) — confirmed
byte-identical version/hash/LLVM-version parity with the system binary
before touching anything else.

**New module, `lib/std/_nolibc/racccoon/`**: same content as the three
vendored files, moved under `std::racccoon::*` names (couldn't reuse
`std::atomic::types`/`std::core::mem` — those names are already taken
by the real modules in the same tree), gated `@feat(NO_LIBC)` matching
`std::nolibc`/`std::core::mem`'s own convention — confirmed empirically
(not assumed) that `NO_LIBC` is exactly the feature racccoon's user-mode
binaries already activate under their existing `--link-libc=no` flag.

**A real trap avoided**: the first instinct was "enable `--use-stdlib`
for user-mode binaries" — testing that directly showed it pulls in far
more of the real stdlib than expected (`std::io`, `libc.os`,
`std::math`, a dozen other modules), none of which this freestanding
link step can handle. The actual fix needed no flag change at all:
passing the new files as explicit source arguments — exactly how
`user/user.c3` has always been included — works under the *existing*
`--use-stdlib=no`, producing only the object files actually needed.
Verified the compiled output directly: real RV64 atomic instructions
(`lr.w.aqrl`/`sc.w.rl`/`amoadd.w.aqrl`), correctly exported
`memcpy`/`memset`/`memcmp` symbols.

**Wired in**: `scripts/build_user.sh` gained a `RACCCOON_STD_DIR`
variable (overridable, defaulting to the fork's checkout path — a real,
disclosed machine-specific dependency, not portable elsewhere without
setting it) pointing at the new module; every `build_user_program` call
now sources `atomic.c3`/`mem.c3`/`fmt.c3` from there instead of `user/`.
`user/atomic.c3`/`mem.c3`/`fmt.c3` deleted. Every consuming file needed
an explicit `import std::racccoon::...` (unlike `std::core::mem`,
`std::racccoon` isn't implicitly visible) and its call sites qualified
(`fmt::format_uint`, not bare `format_uint` — `mem::copy`/`mem::set`
were already qualified).

**Verified**: full regression suite clean on both filesystems
(`mutextest` specifically exercises the real hardware atomics through
the new module), a 10-boot stress batch clean, `e2fsck -n -f`/
`fsck.vfat -n` clean after.

**Scope note**: the c3c fork itself is left with these new files
uncommitted, deliberately — that's the user's own repository and their
call when to commit there, not something to do automatically alongside
a racccoon commit.

**Files changed:** `scripts/build_user.sh` (`RACCCOON_STD_DIR`, source
lists updated), `user/atomic.c3`/`mem.c3`/`fmt.c3` (deleted),
`user/user.c3`/`procd.c3`/`shell.c3`/`envd.c3`/`fsd.c3`/`diskd.c3`/
`fs/ext2.c3` (imports added, call sites qualified). Outside this repo:
`~/Workspace/c3c` fast-forwarded to `v0.8.3`, new
`lib/std/_nolibc/racccoon/{mem,atomic,fmt}.c3` (uncommitted there).

---

## 2026-08-20 (26) — Revisiting the c3 stdlib adaptation: mem::copy/set, and consolidating format_uint

Returned to an early-session goal (adapting the real c3 stdlib into
this project) that had only gotten as far as `user/atomic.c3`
(`std::atomic::types`, for the futex/`Mutex` work). User-mode binaries
build with `--use-stdlib=no` (`scripts/build_user.sh`) — the real
stdlib isn't reachable from them at all, so "adapting" means the same
thing `atomic.c3` already established: port a small, self-contained
piece under the real module name, so it's a drop-in as far as any code
using it is concerned.

### `user/mem.c3`: `mem::copy`/`mem::set`, ported not reinvented

The real stdlib already has exactly the right piece to copy from:
`std::core::mem`'s own `@feat(NO_LIBC)` block
(`/usr/lib/c3c/lib/std/core/mem.c3`) — plain C-style `__memcpy`/
`__memset`/`__memcmp`, no allocator, no OS dependency, already written
for exactly this situation. Copied over near-verbatim (only real change:
`CInt` isn't reachable under `--use-stdlib=no` either, swapped for
plain `int`), plus `copy()`/`set()` as ordinary functions rather than
the real stdlib's macro-based `mem::copy()`/`mem::set()` (those lower
through `$$memcpy`/`$$memset` compiler builtins tied to stdlib
machinery this build doesn't have reachable) — giving user-mode code
the exact same `mem::copy(dst, src, len)` call shape the kernel side
already uses everywhere via the real module.

Replaced seven scattered hand-rolled fixed-length byte-copy loops with
it: two near-identical 100-byte path-buffer copies (`procd.c3`,
`envd.c3`), one in `fsd.c3`, two `SECTOR_SIZE` sector-data copies
(`diskd.c3`), one 64-byte env-var-value copy (`envd.c3`'s own
inheritance code, entry (25) above), and two 48-byte (12×`uint`)
inode-block-pointer copies (`ext2.c3`'s `ext2_read_inode`/
`write_inode`) — left every loop that does more than a pure fixed-
length copy (null-terminator early exit, case transformation) alone,
those aren't the same operation.

### String/format helpers: a real mismatch, handled honestly

Went looking for the same treatment for `strcmp`/`str_copy`-shaped
helpers and integer formatting — found it doesn't fit. The real
stdlib's string utilities (`std::core::string`) are built entirely
around `String`/`ZString` value types (length-tracked, allocator-
aware), and this codebase is plain-`char*` C-strings throughout;
porting `String.compare_to`/`starts_with` would mean dragging in
supporting infrastructure just to reach `strcmp`-shaped functionality
— a worse trade than what's already there. Same story for integer
formatting: the real stdlib's number-to-string logic lives inside
`std::io`'s `Formatter`, an allocator/stream-based subsystem, not a
small standalone function. Reported this rather than forcing a bad-fit
port.

**What *was* real**: `print_uint()` (`user.c3`), `procd_format_uint()`
(`procd.c3`), and `killtest_format_pid()` (`shell.c3`) were three
near-identical copies of the same decimal-digit-extraction loop, each
hand-copied because every binary is a separate build unit with nothing
shared. Consolidated into one `format_uint()` (new `user/fmt.c3`,
explicitly *not* claimed as a stdlib port — this is racccoon's own
logic, just finally written once). Net effect across the affected
files: 94 lines removed, 22 added.

**Verified**: full regression suite clean on both filesystems
(including `readsubfile`/`newsubfile` specifically exercising the
`ext2_read_inode`/`write_inode` block-pointer copy, content confirmed
byte-identical to the old loop), a 10-boot stress batch clean,
`e2fsck -n -f`/`fsck.vfat -n` clean after.

**Files changed:** `user/mem.c3` (new), `user/fmt.c3` (new),
`scripts/build_user.sh` (both added to every binary), `user/procd.c3`/
`envd.c3`/`fsd.c3`/`diskd.c3`/`fs/ext2.c3`/`user.c3`/`shell.c3`
(hand-rolled loops replaced).

---

## 2026-08-20 (25) — /env inheritance across rfork, lazily

The one gap `/env` shipped with, closed the same session: a forked
child used to start with a completely empty environment. Real
inheritance would need the kernel to notify `envd` when a fork happens
— no precedent anywhere in this codebase for the kernel initiating an
IPC send to a server from inside another process's syscall handling,
and genuinely a much bigger, riskier mechanism than the actual problem
needs. Didn't need it: `envd` inherits **lazily**, the first time it
ever sees a request from a given `(pid, generation)`, by asking who
that process's parent is and copying that parent's *current* vars once.

**One small kernel addition**: `Process.parent_pid`/`parent_generation`
(`src/process.c3`) — 0 means no parent, the state every
`create_process()`'d process starts in (explicitly zeroed there on
every call, same "a reused slot must never leak a previous occupant's
data" discipline this session restored for ext2's directory slots and
`Mount`/`Srv_entry`'s generation checks, applied here before it could
bite). `SYS_RFORK`'s existing child-population block sets both, right
alongside where it already sets `child.pid`/`child.generation`. New
read-only `SYS_PARENT_INFO` syscall (next free number, 23) exposes it —
same no-permission-check shape as `SYS_PROC_INFO`.

**`envd.c3`: a real reserved-name convention**. `".inherited"` — a
leading `.`, mirroring Unix dotfiles — records "already handled this
process instance" so `env_maybe_inherit()` never re-runs, without a
second parallel tracking table. `FS_READ`/`FS_WRITE`/`FS_DELETE` now
all refuse any `.`-prefixed name outright, and `FS_LIST` filters it out
of what it shows the caller — a real mechanism now exists for future
internal markers, not just this one. Inheritance itself is a one-time
snapshot at first `/env` touch, not a live link, matching real Plan 9's
own copy-on-fork semantics: neither side's later writes propagate to
the other.

**Extended `envtest` in place** rather than adding a new command: the
child now reads `"GREETING"` *first*, before overwriting it, and checks
it already reads back the parent's pre-fork value — proving inheritance
actually ran — then proceeds exactly as before (overwrite with its own
value, parent's own copy unaffected afterward).

**Verified**: full regression suite (`envtest`'s extended check
included) clean on both filesystems, run repeatedly back-to-back
confirming no leaked process/env slots, a 10-boot stress batch clean,
`e2fsck -n -f`/`fsck.vfat -n` clean after.

**Files changed:** `src/process.c3` (`Process.parent_pid`/
`parent_generation`, `create_process()`'s explicit reset), `src/entry.c3`
(`SYS_RFORK`'s child-population, new `SYS_PARENT_INFO`), `user/user.c3`
(`parent_info()`), `user/envd.c3` (`.`-prefix reserved-name guard,
`env_maybe_inherit()`), `user/shell.c3` (`envtest` extended).

---

## 2026-08-20 (24) — /env: per-process environment variables, zero new syscalls

The last item on the original `/srv`/`/tmp`/`/proc` plan's explicitly-
out-of-scope list: "genuinely separate, much larger subsystems... with
no existing racccoon mechanism to build on." With `/proc`'s read-only
core, `/proc/<pid>/ctl` (the first `FS_WRITE` reuse), and real dynamic
namespace binding all landed since then, `/env` turned out to need
**no new syscalls at all** — a complete read/write/list/delete
filesystem-shaped feature built entirely out of verbs
(`FS_READ`/`FS_WRITE`/`FS_LIST`/`FS_DELETE`) this codebase already had,
on a synthetic server exactly like `procd`.

### Per-process privacy via the sender's own verified pid

Real Plan 9's `/env` is a private per-process kernel device (`#e`) —
racccoon has no per-process device concept and doesn't need one here:
every request `envd` (new file, `user/envd.c3`) receives already
carries the sender's kernel-verified `(pid, generation)` via
`ipc_recv_type_gen()` (`SYS_IPC_RECV_GEN`, two entries back),
unforgeable by the requester. Keying `env_table` by `(pid, generation,
name)` and only ever matching a request's own `(from, from_gen)` gives
genuine per-process isolation for free — no new kernel mechanism, just
the same generation-safety discipline `Mount.server_generation`/
`Srv_entry.generation` already established elsewhere. A pid reused by
an unrelated process simply never matches its predecessor's leftover
vars again; they become permanently inert clutter under a stale
generation, exactly the same shape `Mount`/`Srv_entry` already treat a
stale binding.

**Slot reclamation, learned from the ext2 investigation rather than
repeated**: a bounded table that only ever reclaims on exact-name-match
(fine for `srv_table`'s handful of long-lived named services) would
leak real capacity here, since env vars churn per-process. `FS_WRITE`
needing a fresh slot on a full table scans for one whose owner is no
longer live (`proc_info()` — already used by `procd.c3` — returning
`-1`, or a live generation that no longer matches) before ever
reporting "full" — the same "don't silently degrade after N
operations" bar the ext2 directory-slot-reuse fix set, applied here
before it could bite instead of after.

### Wiring

Same shape as `procd`'s own integration: `envd_pid` global
(`src/process.c3`), a 5th static default-namespace slot (`"/env/"`),
spawned unconditionally right after `procd` in `kernel.c3` (no storage-
hardware dependency, same reasoning). `NS_MOUNTS_MAX` stayed at 8 — 5
static entries now, still 3 spare for `SYS_NS_MOUNT`.

### `envtest`'s isolation proof

Round-tripping a var (write/read/list/delete) is the easy half; the
part that actually matters is proving two processes' vars under the
*same name* don't collide. `rfork(RFPROC)`s a child that sets its own
`"GREETING"` to a different value than the parent's; the parent's own
var, re-read afterward, must come back exactly what the parent itself
wrote. Used the same direct-message-to-the-child's-own-known-pid
handshake `srvtest` had to learn the hard way two entries back (not a
busy-retry — the timer only fires once per real second) to synchronize
before checking.

**Verified**: full regression suite (`envtest` included) clean on both
filesystems, `envtest` run repeatedly back-to-back confirming
idempotent overwrite-in-place and no leaked process/env slots
(`lsproc` after), a 10-boot stress batch (`envtest` twice per boot plus
the rest of the suite) clean on both filesystems, `e2fsck -n -f`/
`fsck.vfat -n` clean after.

### Explicitly out of scope

**No inheritance across `rfork`** — a forked child starts with a
completely empty env, unlike real Plan 9 where children typically
inherit their parent's. Would need `envd` to observe fork events,
which nothing currently notifies it of — a real, separate mechanism
change, not attempted here. The most Plan-9-surprising limitation of
this slice. Also no env groups/`bind`-able sub-namespaces (a single
flat namespace per process, same "not the full `ctl`/`mem`/`fd`/`ns`
set" scoping `/proc` already accepted) and no cross-process env
access by design (that's what makes it private, not another
`srv_table`).

**Files changed:** `user/envd.c3` (new), `src/process.c3` (`envd_pid`,
5th namespace slot), `src/kernel.c3` (spawn `envd`), `scripts/
build_user.sh`/`build.sh`/`build_duo.sh` (`envd` added to the build),
`user/shell.c3` (`envtest`).

---

## 2026-08-20 (23) — Real srv-post + mount: dynamic namespace binding

The last piece explicitly deferred when `/srv`/`/tmp`/`/proc` were built:
the namespace has always been populated exactly once, identically for
every process, at `create_process()` time — no way for a server to
register itself at runtime, no way for a client to bind it afterward.
`SYS_NS_UNMOUNT` already existed (remove one of the *caller's own*
mounts by exact prefix), but there was never an add-a-new-binding
counterpart.

### The two-step

A new, small **kernel-global** registry (`src/process.c3`) — deliberately
separate from `Mount`/namespace, which is per-process and path-keyed:
posted servers are discoverable *by name*, globally.

```c3
struct Srv_entry { char[SRV_NAME_MAX] name; int pid; uint generation; }
Srv_entry[SRV_MAX] srv_table;
```

**`SYS_SRV_POST`** (next free syscall number, 21) posts `current_proc`
under a short name — always self, no pid argument, matching Plan 9's
"you post your own connection" semantics. Idempotent by name, same
"already exists is fine" shape as `fat32_mkdir`'s own `/tmp` auto-create:
posting the same name again just rebinds the entry in place.

**`SYS_NS_MOUNT`** (22) looks the name up, validates it's still live
(the exact same `proc_by_pid` + generation-match check `SYS_NS_RESOLVE`
already does for existing mounts — a stale/dead post is treated as "not
found," never silently handed back), and adds `prefix -> (pid,
generation)` into the *calling* process's own namespace. Idempotent by
exact prefix, same convention `SYS_NS_UNMOUNT` already uses.
`NS_MOUNTS_MAX` grew 5->8: the 4 static mounts left only 1 spare slot,
not enough real headroom for dynamically-added ones.

### A real bug in the first version of the test, not the feature

`srvtest` (new shell command) `rfork(RFPROC)`s a child that posts itself
as `"echo2"` and serves like echod. The first version had the parent
busy-retry `ns_mount()` up to 100000 times, betting on real preemption
(the same reasoning `killtest`'s spin-child relies on) to eventually let
the child run and post. It silently never worked: `srv_mounted` stayed
`-1` every time, `ns_resolve` fell through to the `""` catch-all (fsd),
the parent's `ipc_send`/`ipc_recv` round-trip against the *wrong* pid
left it permanently blocked — and because a permanently-blocked parent
plus its still-serving-nothing child left zero runnable non-idle
processes, `kernel_main`'s own respawn loop silently spun up a *fresh*
shell, which is what kept accepting the next typed command with no
visible hang or crash at all.

Root cause, found by adding checkpoint prints: the timer interrupt only
fires once per full real *second* (`arm_timer(board::TIMEBASE_HZ)`,
`src/entry.c3`) — a tight loop of nothing but fast, non-blocking
`ns_mount()` syscalls can easily finish well under that, so the child
never got a single scheduling opportunity. `killtest`'s own spin-child
gets away with a bare loop only because the *parent* side there makes
several real blocking `fs_read`/`fs_write` calls to fsd in between,
which is what actually drives scheduling — not the timer, and not
`killtest`'s spin loop itself.

**Fixed** by replacing the retry loop with a direct message to the
child's own already-known pid (`srv_r`, straight from `rfork`'s return
value — no namespace involved) before ever touching `ns_mount`.
`SYS_IPC_SEND`'s blocking rendezvous wait calls the kernel's internal
`yield()` on every failed check — the same mechanism every other
blocking-IPC test in this suite already relies on for real scheduling.
Since `srv_post()` is the child's very first statement, by the time it
reaches its own `ipc_recv_type_gen()` to consume this sync message, the
post has already happened — `ns_mount` then succeeds on the very first
try, no retry needed at all.

**Verified**: full regression suite (`srvtest` included) clean on both
filesystems, `srvtest` run repeatedly back-to-back with `lsproc`
confirming no leaked process slots (the `kill()` cleanup at the end
genuinely works), a 10-boot stress batch (`srvtest` twice per boot plus
the rest of the self-cleaning suite) clean, `e2fsck -n -f`/`fsck.vfat -n`
clean after.

**Files changed:** `src/process.c3` (`Srv_entry`/`srv_table`,
`NS_MOUNTS_MAX` 5->8), `src/entry.c3` (`SYS_SRV_POST`, `SYS_NS_MOUNT`),
`user/user.c3` (`srv_post()`, `ns_mount()`), `user/shell.c3` (`srvtest`).

---

## 2026-08-20 (22) — Rename-cycle detection, both backends

The last confirmed, still-open gap on the list from the last few
entries: `fat32_rename`/`ext2_rename` (introduced when directory
listing/mkdir/rename landed) never detected "moving a directory into
its own subtree" — a real cycle in the directory tree. Nothing
refused it outright; only a recursion-depth cap in delete kept a
resulting cycle from causing an unbounded walk, not from being created
in the first place.

**Design, same shape on both backends**: a directory's own `".."`
entry, read directly rather than through the normal named-lookup path
— `fat32_name_to_8_3("..")`/ext2's own leaf-name handling would mangle
or mis-walk a literal `".."` (see `fat32_get_parent_cluster`'s own
comment for the FAT32-specific reason: the leading dot is treated as
the start of a file extension). Both drivers already write `".."` at a
fixed, known location when creating a directory (FAT32: the second
32-byte entry of the first cluster's first sector; ext2: `block[0]`,
offset 12 — both already read/written by rename's own existing
same-parent-vs-different-parent fixup), so the new
`fat32_get_parent_cluster()`/`ext2_get_parent_inode()` helpers just
read that fixed offset directly. A new `fat32_would_create_cycle()`/
`ext2_would_create_cycle()` walks from the destination's parent
directory up through `".."` entries — a plain bounded iteration, not
recursion — until it either reaches the root (safe) or finds the
directory being moved among its own ancestors, including itself
(a cycle: refuse). Bounded by the same `FAT32_MAX_DELETE_DEPTH`/
`EXT2_MAX_DELETE_DEPTH` constants delete's own recursion cap already
uses — reused rather than duplicated, since both express the same
"how deep a directory tree this driver is willing to trust" bound.
Only checked when the source is actually a directory — a file being
renamed/moved can never create a cycle, having no children to contain
anything.

**New shell command, `cycletest`**: builds a real 2-level nested
directory (`tmp/cyc_a/cyc_b`), then tries two ways to break it —
renaming `tmp/cyc_a` directly into itself (depth-0: the new parent
*is* the directory being moved) and into its own grandchild
`tmp/cyc_a/cyc_b` (depth-1). Both must be refused, and — the part that
actually proves the tree wasn't left half-mutated by a refused
rename, not just that `fs_rename` returned -1 — a write and read-back
against `tmp/cyc_a/cyc_b/marker.txt` afterward must still work. A
real, non-cyclic move (`tmp/cyc_a/cyc_b` out to a sibling) proves the
fix didn't just start refusing every directory rename outright.

**Verified**: full regression suite (`cycletest`/`mkdirtest`/
`renametest`/`movetest`/`deletetest`/`newfile`/`racetest`, plus a
manual pass including `rmrtest`/`writefile`/`readfile`) clean on both
filesystems, `e2fsck -n -f`/`fsck.vfat -n` clean after (FAT32's own
free-cluster-summary field stays a pre-existing, unrelated cosmetic
mismatch — confirmed by checking the driver never writes that field at
all, on either side of this change, not something this fix touched).
A 10-boot stress batch of the self-cleaning subset of the suite (not
`rmrtest`, which consumes a one-shot build-time fixture and isn't
meant to repeat across boots on the same image — a test-harness fact
rediscovered this entry, not a regression) clean on both filesystems.

**Files changed:** `user/fs/fat32.c3` (`fat32_get_parent_cluster`,
`fat32_would_create_cycle`, the check in `fat32_rename`), `user/fs/
ext2.c3` (`ext2_get_parent_inode`, `ext2_would_create_cycle`, the
check in `ext2_rename`), `user/shell.c3` (`cycletest`).

---

## 2026-08-20 (21) — Closing the reply-side stale-pid window: SYS_IPC_REPLY/SYS_IPC_RECV_GEN

`Mount.server_generation`/`SYS_JOIN` (2026-08-18 (3), and now `SYS_KILL`
too) all close the same shape of hazard on the *sending* side — a pid
number getting silently reused by an unrelated process between "I
learned this pid" and "I acted on it." One instance of that shape was
still open: a server (fsd/procd/diskd/sdd/echod) receives a request via
`SYS_IPC_RECV`, learns `msg_from`, and later replies via plain
`ipc_send(msg_from, ...)` — but `SYS_IPC_SEND`'s rendezvous completes
for the *client* the moment the server's `SYS_IPC_RECV` consumes the
message, before the server has computed or sent any reply. If the
client somehow exited (or got killed — `SYS_KILL` from the entry above
made this newly reachable, not just theoretical) in the narrow window
before its own follow-up `ipc_recv`, a server's later reply could
silently misdeliver to whatever unrelated process now occupies that
reused pid.

**Design**: two new syscalls, kept fully separate from
`SYS_IPC_SEND`/`SYS_IPC_RECV` rather than widening either — the same
"new syscall number, not a repurposed one" choice `SYS_KILL` made over
extending `SYS_EXIT`. `SYS_IPC_SEND` captures the sender's own
`Process.generation` into a new `Process.msg_from_generation` field
(`src/process.c3`) alongside the existing `msg_from`, unconditionally,
every send — free, no new call convention needed on the sending side.
`SYS_IPC_RECV_GEN` is `SYS_IPC_RECV` plus that captured generation
handed back through a new optional out-pointer; `SYS_IPC_REPLY` is
`SYS_IPC_SEND` plus an optional `expected_generation` (wildcard 0,
`SYS_KILL`'s own convention) checked against the target before
delivery. A server that wants to reply safely calls
`ipc_recv_type_gen()` instead of `ipc_recv_type()`, then
`ipc_reply(dest, ..., from_gen)` instead of `ipc_send()` — the captured
generation travels the shortest possible path, receive to reply,
closing the window down to just those two syscalls.

**Why not just widen `SYS_IPC_RECV`/`SYS_IPC_SEND` in place**: every
existing `SYS_IPC_RECV` caller only ever sets `a0`-`a2` (`user.c3`'s
plain 3-arg `syscall()` wrapper) — reading `a4` as a live out-pointer
on that *same* syscall number would mean writing through whatever
garbage register value was left over from unrelated prior code, for
every caller not yet updated to know about it. A distinct syscall
number sidesteps this entirely: the only wrapper that ever emits
`SYS_IPC_RECV_GEN` is the new one, which always sets `a4` correctly by
construction. `SYS_IPC_REPLY` needed a genuinely new argument slot
anyway (`expected_generation`, a 5th real argument) — `syscall4`'s
existing `a0`-`a2`+`a4` layout was already full (`dest_pid`/`type`/
`data`/`len`), so this is also where `syscall5` (`user.c3`, `a0`-`a2`+
`a4`+`a5`) was added.

**Migrated every server** (`fsd`/`procd`/`diskd`/`sdd`/`echod`) to
`ipc_recv_type_gen()`/`ipc_reply()` — mechanical, same shape in each:
one new `from_gen` local, `ipc_recv_type` -> `ipc_recv_type_gen`,
every `ipc_send(from, ...)` reply -> `ipc_reply(from, ..., from_gen)`.
Found two more stale comments along the way (`diskd.c3`/`sdd.c3`, both
claiming a legitimate sender could be a synthetic `KERNEL_PID` (-1)
"via `fs.c3`'s kernel-internal client" — `fs.c3` doesn't exist anymore,
removed when the filesystem moved into user-mode `fsd` — see `fsd.c3`'s
own header comment) — fixed in passing, same as the ext2 comment two
entries back.

**Known, accepted limitation, same as `SYS_KILL`'s own**: this closes
the specific *reply-misdelivery* shape, not every possible IPC-related
consequence of a pid dying mid-conversation — a process genuinely
blocked mid-rendezvous waiting on a target that then dies is still
left blocked forever either way.

**Verified**: full regression suite (`ping`/`p9test`/`nstest`/`pstest`/
`sandboxtest`/`killtest`/`rforktest`/`threadjointest`/`racetest`/
`mutextest`/`writefile`/`readfile`/`newfile`/`deletetest`/`mkdirtest`/
`renametest`/`movetest`) clean on both filesystems, a 10-boot stress
batch of the same suite all clean.

**Files changed:** `src/process.c3` (`Process.msg_from_generation`),
`src/entry.c3` (`SYS_IPC_RECV_GEN`, `SYS_IPC_REPLY`), `user/user.c3`
(`syscall5`, `ipc_recv_type_gen()`, `ipc_reply()`), `user/fsd.c3`,
`user/procd.c3`, `user/diskd.c3`, `user/sdd.c3`, `user/echod.c3`
(migrated to the generation-checked reply path).

---

## 2026-08-20 (20) — /proc/<pid>/ctl: the first write path /proc has, and a real SYS_KILL

Checking what to build next turned up three already-closed gaps before
finding real work: the `SYS_IPC_SEND` "KNOWN GAP" and the `racetest`
`a=1 b=0` race were both already fixed in the 2026-08-18 (3) entry
below (closing the stale-namespace-pid gap turned out to also explain
`racetest` was `PROCS_MAX` exhaustion, not IPC, all along); and ext2
multi-group support (flagged as a genuine gap in the 2026-08-19 (4)
entry) turned out to already be fully implemented and verified in
entries (5)/(6) the very next day — every allocation/read/write path
is group-aware. Only a stale comment survived
(`ext2_write_inode` claiming "new allocations stay group-0-only,"
contradicted by `ext2_zero_inode`'s own correct comment three lines
below) — fixed in passing.

### /proc/<pid>/ctl

The real remaining gap: procd (`user/procd.c3`) was read-only, so a
future kill-via-ctl was explicitly deferred at the time `/proc` was
built (entry (19) below). Closed now, reusing the same design insight
as `FS_READ`/`FS_LIST`: `FS_WRITE` (verb 21) is just as generic as the
other two — `user.c3`'s existing `fs_write()` reaches procd with zero
client-side changes, the same way `fs_read()`/`fs_list()` already did.

**New `SYS_KILL` syscall** (`src/entry.c3`, next free number 18):
kills an arbitrary target pid, no permission check (same reasoning as
`SYS_PROC_INFO` — this kernel has no user/permission concept at all).
Takes an optional `expected_generation` (0 = wildcard), mirroring
`SYS_JOIN`'s own `join_generation` — closes the same stale-pid race
`Mount.server_generation`/`SYS_JOIN` already close elsewhere. Inlined
in the switch, same page-table-teardown-if-not-shared logic as
`SYS_EXIT`, just targeting an arbitrary `Process*` instead of
`current_proc` (and, unlike `SYS_EXIT`, returning normally to the
caller rather than yielding away permanently). Rejects killing
yourself — `SYS_EXIT` already exists for that, and tearing down your
own running page table from inside this code path is a different,
unsafe shape. **Known, accepted limitation, documented in the case
itself**: any other process blocked mid-rendezvous waiting
specifically on the killed target (`SYS_IPC_SEND`'s own `msg_acked`
wait) is left blocked forever — nothing forcibly unblocks a waiter
when its counterpart is killed out from under it.

**procd's ctl handler** (`user/procd.c3`): `"<pid>"` now lists two
files (`status`, `ctl`) instead of one. Writing to `"<pid>/ctl"` only
recognizes one command, `"kill"` — fetches the target's live
generation via `proc_info()` immediately before calling the new
`kill()` wrapper (`user.c3`) with it, keeping the check-then-act
window as narrow as possible. Any other command, or a path whose
suffix isn't exactly `"/ctl"`, is rejected cleanly (-1), not silently
accepted.

**New shell command, `killtest`**: `rfork(RFPROC)`s a throwaway child
that spins forever (real preemptive scheduling means this doesn't
starve anything else), confirms it's alive via `/proc/<pid>/status`,
kills it via `fs_write("/proc/<pid>/ctl", "kill", 4)`, confirms the
pid is now gone. Also checks two edge cases: re-killing an
already-dead pid fails cleanly, and a bogus ctl command against echod
(pid 2) is rejected without harming it.

**Verified**: full regression suite (`ping`/`p9test`/`nstest`/
`pstest`/`lsproc`/`rforktest`/`threadjointest`/`racetest`) unaffected
on both filesystems, an 8-boot stress batch of `killtest` plus the
suite all clean, and — the real proof the page-table teardown works,
not just the state flip — `lsproc`'s own listing and `rforktest`'s
next child both confirm the killed pid's slot is genuinely reusable
afterward (`rforktest` lands its own child at the exact pid `killtest`
just freed).

**Files changed:** `src/entry.c3` (`SYS_KILL`), `user/user.c3`
(`kill()`), `user/procd.c3` (`FS_WRITE` handling, `ctl` file in
listings, `procd_skip_pid`), `user/shell.c3` (`killtest`),
`user/fs/ext2.c3` (stale comment fix, unrelated).

---

## 2026-08-20 (19) — A Plan-9-style structure: /srv, /tmp, /proc

Verifying this work is what actually turned up the previous entry's
ext2 bug: moving `mkdirtest`/`renametest`/`movetest` under the new
`/tmp` and running them repeatedly is exactly the kind of sustained
create/delete churn against one directory that had never been
exercised before.

### /srv, /tmp, /proc

**`/srv/echo/` replaces bare `"/"` for echod** (`process.c3`'s default
namespace, slot 0). The old `"/" -> echod` mount was confirmed, from
the phase-3 devlog entry, to be a pure artifact — it existed only
because `ping`/`p9test` already hardcoded pid 2 before the namespace
system existed, not from any "echod owns the root" design. `/srv` is
the real Plan 9 convention for where server processes get *named*.
Pure data + call-site change (`ping`, `p9test`, `nstest` in
`shell.c3`) — confirmed via `p9_call_path()` that a mount's prefix is
only ever used to resolve the pid, never sent over the wire. The `""`
catch-all needed no change: once nothing claims bare `/`, it
transparently catches absolute paths too.

**`/tmp`, self-created by fsd** (`fs_mount()`, both backends) rather
than baked into a disk image — `fat32_mkdir("tmp")`/`ext2_mkdir("tmp")`
right after mount, idempotent (already-exists is silently fine).
Works identically on the real Duo with zero SD card changes. Existing
dynamic test fixtures (`newfile`, `deletetest`, `mkdirtest`,
`renametest`, `movetest`) moved under `tmp/` instead of littering root.

**`/proc`, a synthetic process-info server** (`user/procd.c3`, new
process, spawned unconditionally on every board after
diskd/sdd/fsd/fsd2 so it never disturbs their existing hardcoded pid
conventions). The actual interesting design point: it speaks the
*same* `FS_READ`/`FS_LIST` wire verbs fsd already does, just
synthesizing content from a new `SYS_PROC_INFO` syscall
(`src/entry.c3`, read-only, no permission check) instead of reading
disk sectors — `user.c3`'s `fs_read()`/`fs_list()` needed zero changes
to work against it. `ls /proc` lists live pids by scanning
1..PROCD_SCAN_MAX (a generous local bound, not the kernel-only
`PROCS_MAX`) calling `proc_info()` for each; `/proc/<pid>/status`
formats a short text reply. `NS_MOUNTS_MAX` grew 4->5 for the new
`"/proc/"` mount.

**Real bug found via `lsproc` failing**: `fs_list("/proc", ...)` (no
trailing slash) doesn't contain the full `"/proc/"` mount prefix, so
it silently fell through to the `""` catch-all (fsd) instead of
reaching procd, and failed there since `/proc` isn't a real fsd
directory — both servers just return -1, so the wrong-server routing
was invisible until traced. Fixed by using `"/proc/"` in the client
call, matching `"/2/"`'s own established trailing-slash convention.

**Verified**: full regression suite on both filesystems (including
`ping`/`p9test`/`nstest`/`pstest`/`lsproc`), a 10-boot multi-boot
stress batch (2 full mkdir/rename/move cycles under `/tmp` plus the
rest of the suite each boot — see the previous entry for why that
specific combination matters), all clean.

**Files changed:** `user/procd.c3` (new), `src/entry.c3`
(`SYS_PROC_INFO`), `src/process.c3` (namespace slot 0 rename, new
`/proc/` slot, `NS_MOUNTS_MAX` 4->5, `procd_pid`), `src/kernel.c3`
(spawn procd), `user/user.c3` (`SYS_PROC_INFO`/`proc_info()`),
`user/fsd.c3` (`/tmp` auto-create), `user/shell.c3`
(`ping`/`p9test`/`nstest` namespace updates, fixtures moved under
`tmp/`, `pstest`/`lsproc`),
`scripts/build_user.sh`/`scripts/build.sh`/`scripts/build_duo.sh`
(procd added to the build).

---

## 2026-08-20 (18) — A real ext2 bug found chasing what looked like a preemption race

Running `mkdirtest`/`renametest`/`movetest` repeatedly in one boot
(real create/delete churn against the same directory) turned up ext2
corruption: orphaned, unlinked inodes, confirmed via `debugfs`. It
looked exactly like a real preemption race at first — reproduced only
when a test ran long enough to span actual timer ticks, cleared up
when debug `print()`s were added (which seemed to "fix" it by slowing
things down), and FAT32 stayed 100% clean under identical stress. All
three observations turned out to have the same, non-preemption
explanation.

**Actual root cause, found by instrumenting `diskd_rw` and
`ext2_delete_recursive`'s own return sites directly**: `diskd_rw`
never failed a single time across the entire investigation — ruling
out an I/O race outright. The real failure was
`ext2_delete_recursive`'s own `ext2_find_in_dir` call returning "not
found" — because the entry genuinely never existed. `ext2_mkdir`/
`ext2_create_file`/`ext2_rename` never reused a parent directory's own
freed block slot after a delete — clearing a directory entry only
zeroes that one dirent's `entry_inode` field, never reclaims the
*block* it lives in from the parent's `block[]` array. With only 12
direct-block slots and ~5 slots consumed per mkdir+rename+move cycle,
the test directory's own slot list is permanently exhausted after ~2-3
cycles — every later create silently fails (a clean "directory full"
refusal), and the failure never recovers because nothing ever frees a
slot.

This explains every earlier observation without preemption at all:
"more real time" just meant "more completed cycles" (more slots
consumed, hits the wall sooner); debug prints "fixing" it just meant
fewer cycles fit in the same wall-clock test duration; FAT32's own
`fat32_find_free_dirent` already scans for *either* a free *or*
`FAT32_DIRENT_DELETED` slot, so it never has this limit at all.
Confirmed directly: `ext2_create_file`/`ext2_mkdir` allocate the
child's own inode (and, for mkdir, its own "."/".." block) *before*
checking whether the parent has a free slot — so a slot-exhaustion
failure orphaned an already-fully-built child. Matches the two
corrupted-inode shapes found via `debugfs` exactly: a leaked
zero-size regular file (mode/links_count set, no blocks — exactly
what `ext2_create_file` leaves when its parent-slot check fails right
after writing the child's own empty inode) and an orphaned directory
with real content (mode/links_count/blocks all intact, matching
`ext2_mkdir` failing at the same point after fully building the
child's own directory block).

**Fix**: new `ext2_find_or_reuse_dir_slot()` helper (`ext2.c3`) —
scans a parent's existing blocks for one whose single entry was
deleted (`entry_inode == 0`) before allocating a new one, only
returning "genuinely full" once no free *or* reusable slot exists.
Used by `ext2_create_file`, `ext2_mkdir`, `ext2_rename`. Combined
with rollback (`ext2_free_inode`/`ext2_free_block` on the child) when
the parent genuinely has no room, so even a real "directory full"
never leaks — matches the `fs_write`/`fs_delete_recursive` invariant
this driver already keeps everywhere else (fail cleanly, never
partially).

**Verified**: the exact 20- and 40-cycle stress sequences that
reliably corrupted before (failing by cycle ~3 every time) now pass
100% clean — 60/60 and 120/120 test results, `e2fsck -n -f` clean at
both sizes. Full regression suite on both filesystems, all clean.

**Files changed:** `user/fs/ext2.c3` (`ext2_find_or_reuse_dir_slot`
and its three callers: `ext2_create_file`, `ext2_mkdir`,
`ext2_rename`).

---

## 2026-08-19 (17) — Directory listing, mkdir, and rename/move

Three features, all made meaningfully cheaper by infrastructure this
session already built for recursive delete (raw-entry directory
walking, the cluster/inode-zero-vs-root ".." convention, the
allocate-block-and-link-a-dirent shape `ext2_mkdir` and `ext2_rename`
both reuse). No real c3 stdlib code to adapt here the way `std::atomic`
was for the futex work — `std::io::path`'s own `ls`/`mkdir` are thin
OS-native wrappers (`os::native_*`), not portable algorithms, and there
is no `rename` in the stdlib above `libc::rename`'s raw extern
binding — so these are built idiomatically for this environment, only
borrowing the stdlib's API *shape* (an `ls` that lists, an `mkdir`
that refuses if the parent doesn't exist) as naming inspiration.

**`fat32_list`/`ext2_list`** (`FS_LIST`, new verb 23): single-reply, no
pagination (same v1-scope limit as everything else in this protocol) —
up to 31 fixed 36-byte records (32-byte name + 1-byte type + padding)
fit in one `FS_MSG_MAX` reply. FAT32's own version converts each raw
8.3 on-disk name back into a normal "NAME.EXT" display string — the
one place this driver ever hands a name back to a caller instead of
just matching against one.

**`fat32_mkdir`/`ext2_mkdir`** (`FS_MKDIR`, verb 24): creates an empty
directory, refusing if anything already exists there. Self-contained
rather than sharing `fat32_create_file`/`ext2_create_file`'s own
entry-linking logic — close in shape, but a directory needs its own
"."/".." seeded (ext2's own inode also needs `links_count = 2`, not 1,
and the *parent's* `links_count` needs its own +1 for the new
subdirectory's ".." — real extra work a plain file never needs), and
forcing that into the existing functions via a flag felt like the
wrong trade against just duplicating the shape once more, the same
choice `fat32_delete_recursive`/`ext2_delete_recursive` already made
for the same reason. ".." on FAT32 points at cluster 0 when the parent
is root — the real on-disk convention every reader expects, not
something invented here.

**`fat32_rename`/`ext2_rename`** (`FS_RENAME`, verb 25, the one verb
with two paths on the wire — old at byte 0..99, new at 100..199):
handles same-directory rename and cross-directory move uniformly by
always adding a fresh entry at the destination (reusing the source's
existing cluster/size/attr on FAT32, or just the same inode number on
ext2 — genuinely cheap there, a dirent is only ever a name -> inode
link, so a move never touches file data or the inode at all) and then
removing the source entry, new-before-old so a failure partway through
leans toward "briefly visible under both names," never "lost
entirely." Moving a directory across parents fixes up its own ".."
(both backends) and adjusts both parents' `links_count` (ext2 only).
Refuses if the destination already exists (no silent overwrite, unlike
POSIX `rename(2)`) and refuses a cross-filesystem move outright (no
copy-then-delete fallback to silently turn an atomic-looking rename
into a non-atomic one). Does not detect "moving a directory into its
own subtree" (a real cycle) — a known, documented gap, not silently
worked around; the existing recursion-depth cap on
`fat32_delete_dir_contents`/`ext2_delete_dir_contents` is the backstop
that keeps a resulting cycle from ever causing an unbounded walk, just
not from being created.

**Real bug found while testing, not by inspection**: `renametest`'s
first fixture names, `rentest_a.txt`/`rentest_b.txt` (9 characters
before the extension), silently collided under FAT32's 8.3 short-name
truncation — both truncate to the identical `RENTEST_.TXT`, so the
"destination already exists" check correctly refused every single
run. Same root cause as `nestdir`/`nesteddir` two entries ago
(`fat32_name_to_8_3`'s naive 8-character cutoff, no numeric-tail
scheme), made again here before this test's own failure caught it —
isolated via temporary checkpoint prints inside `fat32_rename` itself
(dispatched from a real `print()` call in the fsd process, not a
kernel debug path) rather than guessing. Fixed by shortening to
`ren_a.txt`/`ren_b.txt`/`mv_a`/`mv_b` (all ≤8 characters, matching
`emptydir`/`subdir`/`nestdir`'s own already-established discipline).

**Verified**: full regression suite on both `disk.img` (FAT32) and
`disk_ext2.img` (ext2) — `ls`/`lssub`, `mkdirtest`, `renametest`,
`movetest` alongside every existing command. `fsck.vfat -n`/
`e2fsck -n -f` clean on both after each new test. Unlike `rmrtest`
(previous-previous entry), `mkdirtest`/`renametest`/`movetest` all
create and clean up their own fixtures — confirmed safe to run
repeatedly against the same image, including a 10-boot stress batch
(`mkdirtest`/`renametest`/`movetest`/`ls`/`lssub`/`mutextest`/
`racetest` in sequence each boot) with zero failures. One false
alarm along the way — 8 of an initial 10 stress-batch boots came up
"kernel.elf: No such file or directory" — traced to a race in the
test harness itself (a second, separately-launched `build.sh`
deleting `build/kernel.elf` mid-loop, not a kernel bug); a clean rerun
without the concurrent rebuild passed 10/10.

**Files changed:** `user/fs/fat32.c3` (`fat32_list`, `fat32_mkdir`,
`fat32_rename`), `user/fs/ext2.c3` (`ext2_list`, `ext2_mkdir`,
`ext2_rename`, `ext2_inc_used_dirs`), `user/fsd.c3` (dispatches for
all three new verbs), `user/user.c3` (`FS_LIST`/`FS_MKDIR`/
`FS_RENAME`, `fs_list`/`fs_mkdir`/`fs_rename`), `user/shell.c3`
(`ls`, `lssub`, `mkdirtest`, `renametest`, `movetest`).

---

## 2026-08-19 (16) — Recursive delete

The other half of this session's work (see the previous entry for the
synchronization primitive) — independent of it, just landed in the
same session.

`fat32_delete_recursive`/`ext2_delete_recursive` (`user/fs/*.c3`): the
non-empty-directory case `fat32_delete`/`ext2_delete` always refused,
now actually handled instead of deferred, reusing the existing
`FS_DELETE` wire verb rather than a new one — byte 100 (already sent,
previously unused/ignored by `FS_DELETE`) is now a `recursive` flag,
so plain `fs_delete()` stays byte-for-byte non-recursive and only
`fs_delete_recursive()` opts in. Both backends walk raw directory
entries directly (cluster/sector/offset, same as their own
`*_dir_is_empty`) rather than reconstructing names into path strings
and going back through the normal lookup path for each child — FAT32
has no long-filename support to round-trip through, and ext2's dirents
don't carry a file-type byte at all (its own `ext2_find_in_dir` already
reads each child's inode to get `mode`, same thing this does). Both
cap recursion depth at 32 — not reachable through any well-formed tree
on either filesystem, but nothing on-disk actually prevents a corrupted
or adversarial image from containing a cycle, and a real one would
otherwise recurse forever and blow this process's own stack instead of
failing cleanly.

A protected entry anywhere in the subtree aborts the whole operation
before anything is freed (checked for every child during the walk, and
for the target itself) — never a partial delete that silently skips
just the protected part.

**Test fixture found the hard way**: `scripts/build.sh` seeds a new
`nestdir/` (a file plus a nested `innerdir/` with its own file) on both
the FAT32 and ext2 test images. First attempt named it `nesteddir` —
worked on ext2, silently failed to even be *found* on FAT32. Root
cause: `fat32_name_to_8_3()` does a naive 8-character truncation with
no numeric-tail scheme, while `mtools`' `mmd` generates a real
Windows-style short name (`NESTED~1`) for anything over 8 characters —
confirmed directly via a hex dump of the image. Not a bug introduced
here, a pre-existing limitation of a driver with no long-filename
support at all; the fix for this specific fixture was simply picking a
name (`nestdir`, matching `emptydir`/`subdir`'s own already-short
names) that never needs truncating in the first place.

**Also found while verifying**: `rmrtest` genuinely deletes
`nestdir` — running it more than once against the *same*, un-rebuilt
`disk.img` (e.g. in a multi-boot stress loop over one image file, the
way this session's own stress scripts drive QEMU) fails from the
second boot on, correctly — the fixture is really gone, same as any
real filesystem delete would behave. Not a bug; just means this
specific test isn't safe to include in a same-image repeat-boot stress
loop the way `racetest`/`mutextest` (neither of which touch persistent
state) are.

**Verified**: full regression suite on both `disk.img` (FAT32) and
`disk_ext2.img` (ext2), `rmrtest` (delete refused non-recursively,
succeeds recursively, second call correctly fails "not found") on
both, confirmed repeatable across several fresh rebuilds of each
image, `fsck.vfat -n`/`e2fsck -n -f` afterward as the established
correctness oracle for each backend — ext2 fully clean; FAT32's own
"free cluster summary" mismatch confirmed pre-existing (reproduces
identically from a plain `newfile` on a completely fresh image,
unrelated to this session's changes — this driver has never maintained
the FSInfo sector's cached free-count).

**Files changed:** `user/fs/fat32.c3` (`fat32_delete_recursive`),
`user/fs/ext2.c3` (`ext2_delete_recursive`), `user/fsd.c3` (dispatches
on the new recursive flag), `user/user.c3` (`fs_delete_recursive`, the
wire-format comment), `user/shell.c3` (`rmrtest`), `scripts/build.sh`
(`nestdir/` test fixture on both test images).

---

## 2026-08-19 (15) — A real synchronization primitive: futex + Mutex

Explicitly enabled by real preemption existing now (previous-previous
entry): user code can genuinely race on shared memory for the first
time, so it needs a real way to protect it.

**Adapted, not reinvented, from the real c3 stdlib's `std::atomic`** —
`user/atomic.c3` is a trimmed, self-contained port of
`/usr/lib/c3c/lib/std/atomic.c3`'s `Atomic<Type>` (`load`/`store`/
`compare_exchange`/`add`), same module names, same API shape, same
`AtomicOrdering` enum copied verbatim so `.ordinal` still matches what
the `$$atomic_*` compiler builtins expect. Necessarily a port rather
than a straight `import`: user-mode binaries build with
`--use-stdlib=no` (`scripts/build_user.sh`), so the real module — and
what it itself depends on (`std::core::mem`'s atomic support,
`std::core::types`, `std::math`) — isn't reachable at all. Confirmed by
direct `llvm-objdump` inspection that this still lowers to real RV64
`A`-extension instructions (`lr.w.aqrl`/`sc.w.rl` for compare_exchange,
`amoadd.w.aqrl` for add), not a libcall this freestanding build has
nothing to link against.

**Kernel side**: two new syscalls, `SYS_FUTEX_WAIT`/`SYS_FUTEX_WAKE`
(15/16, `src/entry.c3`). WAIT checks `*addr == expected` and, if still
true, sets `PROC_BLOCKED` and yields; the check-then-block sequence is
atomic with respect to any concurrent WAKE for free, because kernel-mode
code is never preempted (see the previous entry) — no wake can land in
the gap between the read and the block. WAKE scans for blocked waiters
matching both the address *and* `page_table` — page_table equality is
the same "genuinely shares memory" test `SYS_EXIT`'s own table-teardown
skip already uses (RFMEM siblings share the literal pointer, never a
copy), so two unrelated processes' coincidentally-equal user-space
addresses can't cross-wake each other. `Process` gained `futex_addr`
to track this — 0 unless genuinely blocked inside `SYS_FUTEX_WAIT`,
cleared the instant `SYS_FUTEX_WAKE` wakes it.

**User side** (`user/user.c3`): `Mutex` — `lock()` is a single
uncontended `compare_exchange` (0→1), falling back to `futex_wait` only
when actually contended; `unlock()` stores 0 and `futex_wake`s. Also
added `print_uint()` (decimal, no leading zeros) since mutextest's own
counter needed more than the two-digit `'0'+n/10` unrolling every
existing test command uses — and de-duplicated three near-identical
private copies of exactly this helper already sitting in `diskd.c3`/
`fsd.c3`/`sdd.c3`, now all calling the one in `user.c3` instead.

**mutextest, and a real methodology finding while building it**: two
threads increment a shared counter through `Mutex`. First attempt used
a tight loop for a fixed iteration count — and passed identically
whether or not the lock/unlock calls were even present, which is wrong:
confirmed by deliberately checking, the two threads simply never
overlapped in time at all (nothing forces an interleave without a
blocking syscall or a lucky preemption landing in a 1-2 instruction
window out of thousands). Fixed using the standard "read, sleep,
write" technique for reliably demonstrating this class of race: each
iteration reads the counter into a local, spins for a real, fixed
slice of wall-clock time (`rdtime()`-based, not a raw instruction
count — holds for comparable real time on both boards despite their
10MHz/25MHz difference), *then* writes back. Confirmed the test is now
meaningful in both directions: with the lock removed, the count came
up short (12-13 of an expected 16) every time; with it restored, 16/16
every time, repeated 5 times in a row plus 30 more calls across a
10-boot stress batch (alongside `racetest`/`rforktest`/`sandboxtest`/
`threadjointest`, none of which touch persistent state, so safe to
repeat across the same boot loop unlike the next entry's `rmrtest`).

**Files changed:** `user/atomic.c3` (new), `user/user.c3` (futex
syscalls, `Mutex`, `print_uint`), `src/entry.c3` (`SYS_FUTEX_WAIT`/
`SYS_FUTEX_WAKE`), `src/process.c3` (`Process.futex_addr`),
`user/diskd.c3`/`user/fsd.c3`/`user/sdd.c3` (local `print_uint` copies
removed in favor of `user.c3`'s), `user/shell.c3` (`mutextest`),
`scripts/build_user.sh` (`atomic.c3` added to every binary's sources).

## 2026-08-19 (14) — Real preemptive scheduling

Built directly on the `sepc`-per-process fix (previous entry): the
timer interrupt now actually forces a reschedule instead of only
firing and returning to whatever was running.

**The change**: in `handle_trap`'s `SCAUSE_SUPERVISOR_TIMER` case, after
rearming, call `yield()` — but only when `current_proc.pid > 0`.

**Why the `pid > 0` guard, specifically**: `enable_timer_interrupts()`
runs early in `kernel_main`, so the timer is live for the rest of boot
— including `kernel_main`'s own sequence of `create_process()` calls
for echod/diskd/sdd/fsd/fsd2, all of which run as `current_proc ==
idle_proc` (pid 0) and are not reentrant (interleaving two
`create_process()`/`alloc_pages()` calls has no protection against
corrupting shared allocator/process-table state). Excluding pid 0
sidesteps that hazard entirely, and costs nothing: idle's own post-boot
loop already calls `yield()` every iteration on its own, so forcing
another one on top adds no benefit.

**Why real processes (pid > 0) need no equivalent guard**: established
directly by this session's own interrupt-latency finding (previous
entry, and the comment above `enable_timer_interrupts()`) — a timer
interrupt can only ever land during genuine, uninterrupted user-mode
execution, never inside a trap's own kernel-mode handling (`sstatus.SIE`
stays hardware-cleared for a trap's entire duration, regardless of how
many `yield()`-driven `switch_context()` calls happen inside it while
waiting on a blocking syscall). So `SYS_IPC_SEND`'s multi-step
bookkeeping, mid-page-table-edit code, and every other piece of kernel
state this codebase has never needed to guard against concurrent
access — none of it is ever what gets preempted. What's actually being
interrupted is always plain, isolated user-mode execution, which
`yield()` was already safe to call from at any point.

**Verified deliberately harder than a single boot**: full QEMU
regression suite once (`hello`/`readfile`/`writefile`/`newfile`/
`deletetest`/`rmdirtest`/`protectedwrite`/`ping`/`nstest`/`rforktest`/
`sandboxtest`/`threadjointest`/`racetest` x4 — all correct), then 30
additional full boots under randomized real preemption timing (each
running `racetest` x5, `rforktest`, `sandboxtest`, `threadjointest`,
`writefile`+`readfile`), checked for `unexpected trap`/`PANIC`, hangs,
and specifically race corruption (`racetest` reporting anything other
than `a=1 b=1`) — 30/30 clean. Real Duo hardware: clean boot through
disk/fs mount, then `racetest` x4, `rforktest`, `sandboxtest` all
correct, matching QEMU exactly.

**Files changed:** `src/entry.c3` (`handle_trap`'s
`SCAUSE_SUPERVISOR_TIMER` case gains the `yield()` call; the comment
block above `enable_timer_interrupts()` rewritten to describe the now-
real preemption instead of the deliberately-deferred slice from the
previous session).

## 2026-08-19 (13) — Real preemption's first prerequisite: sepc needed to become per-process state

First real design step toward actual preemptive scheduling (the
deliberately-deferred half of the timer-interrupt work). Found by
reading the existing trap-return path closely rather than assuming it
would just work: a genuine, foundational correctness bug that
preemption would trigger on its very first tick, not a rare race.

**The invariant that made the old code correct without a per-process
`sepc`**: `sepc` is a single, non-banked hardware CSR. `write_sepc()`
(or, for interrupts, hardware's own already-correct value) was always
set *immediately before* an uninterrupted `sret` — no `yield()` ever
happened in between, for any existing code path. `Process`/
`switch_context()` never needed a `sepc` field because nothing ever
relied on the hardware register surviving across a context switch —
every blocking-syscall loop (`SYS_GETCHAR`, `SYS_IPC_RECV`, `SYS_JOIN`)
only writes `sepc` *after* its own loop finishes, right before
returning.

**Why preemption breaks it**: calling `yield()` from inside the timer
interrupt means some *other* process's own `write_sepc()`+`sret`
sequence can run before the preempted process resumes — overwriting
`sepc` in between. By the time the preempted process is rescheduled,
`sepc` holds someone else's return address, not its own.

**Fix**: `Process` gained `saved_sepc`. `handle_trap` now captures it
once at entry (correct as-is for interrupts, overwritten with the
post-ecall address for ecalls, unaffected by any `yield()`s that
happen via `switch_context`'s own stack-swap, which — confirmed by
reading it — always resumes a process's own call chain exactly where
it left off) and writes the real `sepc` CSR exactly once, always, right
before `handle_trap` returns — restoring the same "write immediately
before an uninterrupted `sret`" invariant, just sourced from
per-process state instead of assuming the shared register survived
untouched. `fork_entry()` (the `rfork` child's own first resume) needed
no change — it's a separate, fully self-contained naked-asm sequence
(its own `csrw sepc` immediately followed by `sret`, no C3 call, no
`yield()` possible in between) that was never subject to this hazard.
`sstatus`/`SPIE` didn't need the same treatment: every process always
runs with interrupts enabled, so that saved value is the same constant
regardless of which process's trap entry most recently wrote it.

**Verified as rigorously as the concern warranted**: full regression
suite (both QEMU images), `racetest` specifically run 4 times in a row
(the test most likely to expose exactly this class of bug, since it
genuinely interleaves two threads via real concurrent `yield()`s) —
`a=1 b=1` every time. `threadjointest` (properly `join()`-synchronized)
also correct. No context switch happens from the timer interrupt yet —
this is groundwork, not preemption itself.

**Files changed:** `src/process.c3` (`Process.saved_sepc`),
`src/entry.c3` (`handle_trap` captures/restores it instead of writing
`sepc` directly mid-function).

---

## 2026-08-19 (12) — Real timer interrupts, actually working on real hardware now

Fixes the previous entry's real-hardware regression: switched
`arm_timer()` (`entry.c3`) from a direct `stimecmp` CSR write to the
SBI legacy `set_timer` ecall (new `sbi::__set_timer()`, same shape as
the existing `__putchar`/`__getchar` bindings) — M-mode firmware
programs the actual timer comparator on the kernel's behalf, needing
no `menvcfg.STCE` permission for direct S-mode CSR access at all.
`enable_timer_interrupts()` re-enabled in `src/kernel.c3`.

**Verified properly this time**, same discipline as the failed
attempt: temporary debug print, confirmed on QEMU first (fired
correctly, ~1s intervals with the shell kept busy), *then* a real
hardware round trip — and this time, real confirmation: `DBG timer
tick (SBI)` appeared twice in the real console log, correctly
interleaved with ongoing, unrelated `sdd` sector-read traffic, boot
completing normally all the way to the shell prompt both times (with
the debug print, and again on the final clean rebuild). No hang, no
regression. Full QEMU regression suite (both images) unaffected,
`racetest` still `a=1 b=1`.

The narrow-scope boundary from two entries ago stands unchanged: this
still only proves the interrupt mechanism itself (fires, rearms,
returns cleanly) — no context switch happens on a tick yet. Actual
preemption remains real, separate, higher-risk work, and the earlier
interrupt-latency finding (blocking syscalls hold `sstatus.SIE`
globally disabled for their own duration) is unaffected by this
arming-mechanism change — same characteristic either way.

**Files changed:** `src/kernel/sbi.c3` (`__set_timer`), `src/entry.c3`
(`arm_timer` uses it instead of direct CSR access), `src/kernel.c3`
(`enable_timer_interrupts()` re-enabled).

---

## 2026-08-19 (11) — Real hardware correction: stimecmp hangs the real Duo, QEMU only proved half the story

The previous entry's QEMU verification wasn't wrong, but it wasn't the
whole story either — flashing `enable_timer_interrupts()` to the real
board hung it silently, right at boot, before even reaching "2: Trap
handler set". Immediately disabled the call (commit right after) to
get the board back to a known-working boot, then investigated properly
rather than just leaving it off.

**Isolated with two narrow, single-variable real-hardware tests**
(temporary debug prints, each confirmed working on QEMU first before
spending a real-hardware round trip): `read_reg("time")` alone —
boots cleanly all the way to the shell prompt, no issue. Adding
`write_csr("stimecmp", ...)` right after — boot stops *exactly* at the
print immediately before that write, every time. Confirmed
definitively: reading `time` works fine on the real T-Head C906 core;
writing `stimecmp` is what hangs it, silently, with no trap or panic
message reaching this kernel's own handler at all — meaning the trap
either isn't being delivered to S-mode the way QEMU's OpenSBI delivers
it, or something worse is happening at the M-mode/firmware level.
Most likely explanation, not yet confirmed: `menvcfg.STCE` (the
M-mode-only bit that permits S-mode `stimecmp` access at all) isn't
set by the real Duo's own FSBL/OpenSBI build, unlike QEMU's — but this
wasn't chased further once the real, actionable fix path was clear.

**Path forward, not yet implemented**: switch to the SBI legacy timer
extension (`sbi_set_timer()`, an ecall trapping straight to M-mode
firmware — no S-mode CSR access, no menvcfg.STCE dependency at all)
instead of direct `stimecmp` CSR access. Both platforms' own boot
banners already confirm the SBI "time" extension is present
(`Standard SBI Extensions: ...,time,...`), and this project already
has real precedent for SBI ecall bindings (`sbi::__putchar`/
`sbi::__getchar` in `boards/*/board.c3`). `enable_timer_interrupts()`
stays disabled (commented out in `src/kernel.c3`, real hardware
confirmed back to a normal boot) until that switch is made.

**Files changed:** `src/kernel.c3` (updated comment with the confirmed
root cause and the real fix direction).

---

## 2026-08-19 (10) — Real timer interrupts: the mechanism itself, and a real interrupt-latency finding

Deliberately narrow first slice of preemptive-scheduling support,
scoped down from the full feature on purpose: this kernel has been
fully cooperative until now (every context switch happens at a
caller-chosen `yield()`), so kernel state has never needed to guard
against concurrent access — SYS_IPC_SEND's own multi-step bookkeeping,
page-table edits, none of it. Forcing a `yield()` from inside a timer
interrupt (real preemption) means that state could now get touched
mid-update by whatever gets switched to, a whole new class of bug this
codebase has never had to defend against. This session proves the
*mechanism* — the interrupt fires, gets correctly re-armed, and
returns cleanly to whatever was running — without yet taking that
step.

**Design**: `board::TIMEBASE_HZ` (real, confirmed values — 25MHz Duo,
10MHz QEMU, same sourcing as the earlier real-timer-primitive work)
added to both boards, the proper seam for a kernel-reachable
board-specific fact (unlike `user/sdd.c3`'s own duplicate, needed only
because `board` is kernel-only). `entry.c3` gained `arm_timer()`
(writes `time + delta` to `stimecmp`, the sstc extension's own CSR —
confirmed present in this hart's boot banner) and
`enable_timer_interrupts()` (arms *before* enabling `sie.STIE`, not
after — `stimecmp`'s reset value is implementation-defined and could
easily be 0, which would make the interrupt already-pending the
instant the source goes live). `handle_trap` gained a
`SCAUSE_SUPERVISOR_TIMER` case: re-arms immediately (the only thing
that actually clears the pending interrupt — leaving the elapsed value
in place would refire it the instant interrupts are next enabled, a
storm not a tick) and bumps an inert `timer_tick_count` counter. No
context switch — that's the explicitly-deferred half.

**A real finding, not a bug in this mechanism**: verified via a
temporary debug print, the first armed tick (~1s out) didn't actually
fire until several seconds later — once, coinciding almost exactly
with whenever the next keystroke arrived at the idle shell, not on
schedule. Traced to `SYS_GETCHAR`'s own handler: a `for(;;) { ...;
yield(); }` loop running *entirely inside its own still-open trap*,
never reaching `sret` until a character shows up — and the exact same
shape is used by `SYS_IPC_RECV`'s blocking wait and `SYS_JOIN`'s poll
loop. Hardware auto-clears `sstatus.SIE` on trap entry and only
restores it on `sret`; since `switch_context()` is a plain software
stack swap (not a trap return) and `sstatus.SIE` is one shared,
un-banked hardware bit, every process `yield()` switches to *while*
one of these loops is still open inherits that same globally-disabled
state — not just the blocked process itself. Confirmed directly: shell
left idle, the timer only fired once a keystroke finally arrived;
shell kept continuously busy (repeated commands, never idly parked in
`SYS_GETCHAR`), the same timer fired reliably every ~1s as armed
(measured intervals: ~10.3M, 10.26M, 10.26M, 10.33M ticks against a
10M-tick target). Documented directly in `enable_timer_interrupts()`'s
own comment — genuinely relevant to whoever builds real preemption
later: a timer-interrupt-based preemptive scheduler built on this same
mechanism would *not* actually preempt a process stuck in any of these
blocking syscalls, for the identical reason the timer itself was
delayed.

**Verified**: full regression suite (both QEMU images) unaffected,
`racetest` still `a=1 b=1`, 30 rapid commands with the timer firing
repeatedly throughout showed no instability.

**Files changed:** `boards/duo/board.c3`/`boards/qemu/board.c3`
(`TIMEBASE_HZ`), `src/entry.c3` (`SCAUSE_SUPERVISOR_TIMER`, `SIE_STIE`,
`arm_timer`, `timer_tick_count`, `enable_timer_interrupts`,
`handle_trap`'s new case), `src/kernel.c3` (calls
`enable_timer_interrupts()` at boot).

---

## 2026-08-19 (9) — Directory deletion (rmdir), both backends

The natural follow-up to file delete, whose own comments explicitly
deferred this: `fat32_delete()`/`ext2_delete()` now also handle an
*empty* directory, reusing the same `FS_DELETE` verb rather than
adding a new one — no wire protocol change needed. Matches real
`rmdir()` semantics deliberately: refuses a non-empty directory,
no recursive auto-delete (that's real, separate, genuinely dangerous
work not attempted here).

**FAT32**: new `fat32_dir_is_empty()` walks a directory's cluster
chain checking for anything besides `.`/`..`. Those two don't 8.3-
convert correctly through the existing `fat32_name_to_8_3()` (it treats
a leading dot as "start of the extension", producing an all-spaces
name for either) — matched directly against their real, fixed byte
patterns instead of going through that path. Once confirmed empty, an
empty directory deletes exactly like a file (mark the entry
`FAT32_DIRENT_DELETED`, free its cluster chain) — FAT32 has no
link-count concept, so nothing else to unwind.

**ext2**: same shape (`ext2_dir_is_empty()`, matching by exact
`name_len` since ext2 entries aren't space-padded) plus real,
ext2-specific bookkeeping FAT32 doesn't have: the deleted directory's
own `..` entry was a link to its parent, so the parent's `links_count`
needs decrementing (the same field this session's earlier corruption
fix taught was genuinely load-bearing, not cosmetic). **Found a second
real bookkeeping gap the same way**: the very first rmdir test against
`e2fsck` flagged "directory count wrong for group N" — `bg_used_dirs_
count`, a per-group directory counter with no superblock-level twin,
never touched before because this driver has no `mkdir` of its own to
have ever incremented it. New `ext2_dec_used_dirs()` fixes it, using
the *deleted directory's own* group (not the parent's).

**A real test-construction problem, solved properly**: this driver has
no `mkdir`, so testing the positive case (successfully removing an
empty directory) needed a genuinely empty directory to exist first —
added `emptydir/` to all three QEMU test images (`scripts/build.sh`,
`mmd`/`debugfs mkdir`, no files inside). New `rmdirtest`/`rmdirtest2`
delete it and confirm it's really gone by deleting it again (which
should now fail) — the same "before, action, after" shape `deletetest`
uses, just via a second delete instead of a read, since a directory
isn't readable as file content. New `rmdirnonempty`/`rmdirnonempty2`
confirm the existing, genuinely non-empty `subdir/` fixture is
correctly refused.

**Verified as rigorously as every other write-path change this
session**: `e2fsck -n -f` caught the `bg_used_dirs_count` gap on the
very first real test (not just trusted the code), came back completely
clean once fixed. FAT32's own deletion cross-checked with `mdir`
independently — `emptydir/` genuinely gone, `subdir/` genuinely still
there after the correctly-refused non-empty attempt. Full regression
suite (both QEMU images) unaffected, `racetest` still `a=1 b=1`.

**Files changed:** `user/fs/fat32.c3` (`fat32_dir_is_empty`,
`fat32_delete` branches on directory vs file), `user/fs/ext2.c3`
(`EXT2_BGD_USED_DIRS_COUNT`, `ext2_dec_used_dirs`, `ext2_dir_is_empty`,
`ext2_delete` handles directories: empty-check, parent link-count,
used-dirs count), `user/shell.c3` (`rmdirtest`/`rmdirtest2`/
`rmdirnonempty`/`rmdirnonempty2`), `scripts/build.sh` (`emptydir/`
fixture in all three test images).

---

## 2026-08-19 (8) — File delete/unlink, both backends

fsd had no way to remove a file at all — the FS_READ/FS_WRITE wire
protocol had no verb for it, and the shell had no equivalent command.
Real, contained feature, built on top of everything else this session
already put in place (subdirectory resolution, the protected-entry
check, correct free-count bookkeeping).

**Wire protocol**: `user/user.c3` gained `FS_DELETE` (verb 22) and
`fs_delete(filename)` — filename-only request, reply reuses byte 0..3
for a plain 0/-1 result (no length concept for a delete). `fsd.c3`'s
dispatch gained a third branch alongside FS_READ/FS_WRITE, with the
same protected-name fast-gate FS_WRITE already has before either
backend even runs.

**FAT32**: `fat32_delete()` resolves the containing directory (reusing
`fat32_resolve_dir`, so subdirectory files delete correctly too),
refuses a directory or the protected entry, then — order matters —
marks the directory entry `FAT32_DIRENT_DELETED` *before* freeing its
cluster chain (`fat32_free_cluster_chain()`, new). Marking first means
a failure partway through just leaks space (safe); freeing first and
then failing to mark the entry deleted would leave a still-visible
file pointing at clusters that could already be reused elsewhere — a
real corruption risk, not just a leak.

**ext2**: `ext2_delete()` same shape, same ordering principle taken
further given ext2 has more state to unwind: clear the directory
entry, zero the inode's own record (`ext2_zero_inode`, reused),
free each of its data blocks (new `ext2_free_block()`, the inverse of
`ext2_alloc_block()` — same group-aware bitmap math in reverse), then
free the inode itself (new `ext2_free_inode()`) — never marking
something reusable while anything upstream of it might still
reference it. New `ext2_inc_free_blocks()`/`ext2_inc_free_inodes()`
mirror this session's earlier `ext2_dec_free_*` functions, keeping
both free-count copies correct on the way back up too — the same
bookkeeping that turned out to matter for real (auto-remount-read-only)
consequences earlier this session.

**Verified rigorously**: new `deletetest`/`deletetest2` shell commands
(create, confirm present, delete, confirm genuinely gone) on both
mounts, `deleteprotected` confirms `fip.bin` is still refused. `e2fsck
-n -f` on the ext2 image after a delete: completely clean, no errors
of any kind — the free-count/bitmap bookkeeping unwound correctly, not
just the visible file. FAT32's deletion cross-checked with `mdir`
(mtools, not `fsd`'s own read-back) — the file is genuinely gone from
the directory listing. Full regression suite (both QEMU images)
unaffected, `racetest` still `a=1 b=1`.

**Files changed:** `user/user.c3` (`FS_DELETE`, `fs_delete()`),
`user/fsd.c3` (dispatch), `user/fs/fat32.c3` (`fat32_free_cluster_
chain`, `fat32_delete`), `user/fs/ext2.c3` (`ext2_inc_free_blocks`/
`ext2_inc_free_inodes`, `ext2_free_block`/`ext2_free_inode`,
`ext2_delete`), `user/shell.c3` (`deletetest`/`deletetest2`/
`deleteprotected`).

---

## 2026-08-19 (7) — Closing the last documented gap: directory-vs-file confusion in the protected-file lookup

`ext2.c3`'s own header comment still listed "no directory-entry
file-type filtering" as a known gap — checking turned out it was
already closed for the parts that actually matter: `ext2_read`/
`ext2_write` route through `ext2_find_in_dir` (added earlier this
session for subdirectory support), which already reads the matched
entry's real inode and refuses to treat a directory as file content,
using the inode's own authoritative `mode` field rather than the
optional, sometimes-absent on-disk `file_type` byte the old comment
worried about — actually more robust than what was originally asked
for.

The one place this genuinely wasn't checked: `ext2_reserve_protected()`
(mount-time lookup of `fip.bin`), whose only remaining caller of the
now-narrowly-scoped `ext2_find_in_root` never looked at type at all. A
directory happening to share the protected name would have had its
own cluster chain reserved as if it were "the protected file"'s data —
a category error, though a safe-direction one (over-protective, never
under-protective or data-exposing). Fixed the same way in both
backends for consistency: `ext2_reserve_protected` now checks the
inode it already reads anyway; `fat32_find_in_root` (FAT32's own
now-single-purpose equivalent, same "only `fat32_reserve_protected`
still calls it" situation) gained an `out_attr` param so
`fat32_reserve_protected` can check `FAT32_DIRENT_ATTR_DIRECTORY`
directly from the dirent, no extra read needed there. Both fail the
same way a genuinely-missing file already did: print, don't reserve.

Verified via full regression suite (both single- and dual-mount QEMU
images), `protectedwrite`/`racetest` unaffected. The real, hardware-
relevant case (a real `fip.bin`, not a same-named directory) is
unchanged — this only adds a new, narrow refusal path that was never
exercised before.

**Files changed:** `user/fs/ext2.c3` (`ext2_reserve_protected` checks
`inode.mode & EXT2_S_IFDIR`, header comment updated), `user/fs/fat32.c3`
(`fat32_find_in_root` gained `out_attr`, `fat32_reserve_protected`
checks it).

---

## 2026-08-19 (6) — ext2 multi-group allocation: this driver's own writes aren't confined to group 0 anymore

Closes the last piece of the "block group 0 only" limitation — the
entry below deliberately stopped at reads/updates, leaving
`ext2_alloc_block()`/`ext2_alloc_inode()` group-0-only since that's
the higher-risk half (this session already found two real corruption
bugs in the allocator's own neighborhood). Extended carefully, on top
of the mount-time per-group bitmap locations the previous entry
already added.

**Design**: `ext2_mount()`'s block-group-descriptor read now also
caches every group's own block/inode bitmap block (not just the inode
table, which the read-side fix already needed) into two more
`[EXT2_MAX_GROUPS]` arrays. `ext2_alloc_block()`/`ext2_alloc_inode()`
now loop over every group in turn — group 0 first, so existing
single-group volumes see zero behavior change — computing the real
absolute block/inode number from `(group, index-within-group)`.
`ext2_dec_free_blocks()`/`ext2_dec_free_inodes()` gained a `group`
parameter and now locate that specific group's own descriptor within
the (possibly multi-block) BGDT instead of always assuming block 0's
own 32-byte entry — the exact bug class this session's earlier
free-count fix would have reintroduced if left group-0-only.
`ext2_zero_inode()` also needed the same group-aware lookup, since it
runs on whatever `ext2_alloc_inode()` just handed it, no longer
guaranteed to be group 0. The old flat, group-0-only globals (`ext2_
inode_table_block` etc.) were removed entirely rather than left
dangling once nothing referenced them anymore.

**Verified as rigorously as the read-side fix, maybe more so given the
stakes**: baseline regression suite (including `e2fsck -n -f` on a
fresh, untouched image) confirmed no behavior change for the normal,
single-group case. Then actually forced the allocator's hand: built a
small-group scratch image (`mke2fs -g 512`, 128 inodes/group), filled
group 0's inodes completely via `debugfs` (confirmed via `stat` that
the *next* file would land at inode 129, group 1), then had the
*kernel's own* `newfile2` create a genuinely new file through the
exhausted volume — landed at inode 130 (group 1), confirmed via
`debugfs stat`, not just trusted. `e2fsck -n -f` on the result: fully
clean, no errors of any kind, including group 1's own free-count
bookkeeping. Re-ran the same stressed image with `readfile2`/
`racetest` afterward — nothing else broke.

**Files changed:** `user/fs/ext2.c3` (`ext2_block_bitmap_blocks[]`/
`ext2_inode_bitmap_blocks[]`, `ext2_mount()`'s BGDT scan extended,
`ext2_dec_free_blocks`/`ext2_dec_free_inodes` gained a `group`
parameter, `ext2_alloc_block`/`ext2_alloc_inode`/`ext2_zero_inode`
made group-aware, dead flat group-0 globals removed, header comments
updated).

---

## 2026-08-19 (5) — ext2 multi-group reads: closing the gap the real hardware exposed twice now

The "block group 0 only" limitation bit twice in one session (see the
entry below): a real Linux `mkdir` on the actual boot card put a new
directory in group 1, which this driver refused entirely. Scoped
carefully rather than a full rewrite: extending *reading and updating*
an existing inode to work across any group is a bounded, low-risk
index-math change; extending *allocation* (new inodes/blocks) to scan
and update other groups' bitmaps and free-counts is real, separate,
higher-risk work — this session already found two real corruption bugs
in the allocator's neighborhood, so it stayed untouched.

**Design**: `ext2_mount()` now computes `ext2_group_count` (from the
superblock's total inode count) and reads the *entire* block group
descriptor table — not just group 0's own 32-byte entry — into a new
`ext2_inode_table_blocks[]` array (looping over however many BGDT
blocks that actually takes, not assuming one block is always enough).
`ext2_read_inode`/`ext2_write_inode` now compute `group = (inode_num -
1) / ext2_inodes_per_group` and index into that array instead of
always using the flat, group-0-only `ext2_inode_table_block` global —
which `ext2_alloc_inode()`/`ext2_zero_inode()` still use unchanged,
since new inodes are still only ever allocated in group 0.

**Verified properly, not just trusted**: debugfs alone doesn't
naturally scatter files across groups on a small test image (its own
allocator stays in group 0 for anything this project's test fixtures
need), so confirming this needed *actually* forcing a multi-group
scenario — built a scratch ext2 image with `mke2fs -g 512` (small
groups on purpose), filled group 0's inodes with 130 dummy files via
`debugfs`, then created `subdir` — landed at inode 143, genuinely in
group 1 (`(143-1)/128 = 1`). `readsubfile2` against it initially
worked (confirming the read side), but `newsubfile2` initially failed
— traced with temporary debug prints to `ext2_alloc_inode()` itself
returning "no free inode", which turned out to be a test-setup
artifact (the 130 dummy files had exhausted group 0's own inode pool,
not a bug) — freed some of them back up and the write succeeded
cleanly. `e2fsck -n -f` on the result: completely clean, no errors of
any kind. Full regression suite (both QEMU images) unaffected,
`racetest` still `a=1 b=1`.

**Files changed:** `user/fs/ext2.c3` (`EXT2_SB_INODES_COUNT`,
`EXT2_MAX_GROUPS`/`EXT2_BGD_SIZE`, `ext2_group_count`/
`ext2_inode_table_blocks[]`, `ext2_mount()`'s BGDT-table read,
`ext2_read_inode`/`ext2_write_inode` made group-aware, header comment
updated).

---

## 2026-08-19 (4) — ext2 subdirectory support on real hardware: a real trigger for the documented "block group 0 only" limit

Testing write-into-subdirectory support on the real card's `EXT2TEST`
partition hit a wall: `sudo mkdir subdir` there, then `newsubfile2`/
`readsubfile2` both failed with "not found" — even reading the
already-seeded `nested.txt`. Not a new bug: `ext2.c3`'s own header
comment has always scoped this driver to "block group 0 only," and
`sudo debugfs -R "stat subdir" /dev/sdc2` showed exactly why it fired —
the real kernel's `mkdir` allocated `subdir` as inode **16385**, but
`sudo debugfs -R "show_super_stats -h"` showed this filesystem has only
**8192 inodes per group**, putting that inode in group 1.
`ext2_read_inode()` correctly refused it (`inode_num > ext2_inodes_per_
group`) exactly as documented.

Confirmed this was specifically about *how* the directory was created,
not a filesystem-wide problem: real Linux `mkdir` uses a modern
allocator that deliberately spreads new directories across groups for
locality, which QEMU's own test fixtures (seeded via `debugfs`'s
simpler first-fit allocator) never exercised — every previous
real-hardware write went through either this driver's own group-0-only
`ext2_alloc_inode()` or `debugfs`, neither of which had ever landed
outside group 0 before.

**Resolution, not a fix**: removed the kernel-created `subdir` (`sudo
rm`/`rmdir` the contents first — debugfs has no clean recursive
directory removal) and recreated it via `debugfs -w -R "mkdir subdir"`
instead, landing at inode 14 this time — comfortably in group 0.
`readsubfile2`/`newsubfile2` both then worked correctly on real
hardware, confirming write-into-subdirectory support end to end on the
ext2 backend. Multi-group support (real group-index math, reading
additional block group descriptors) remains a genuine, understood gap
— not attempted here, noted as real future work if this driver ever
needs to interoperate with directories real Linux tools create instead
of ones it creates itself.

---

## 2026-08-19 (3) — ext2 free-count bookkeeping: not just cosmetic after all

`user/fs/ext2.c3`'s own header comment had accepted, since the original
write-support work, that `s_free_blocks_count`/`s_free_inodes_count`
(and their group-0 `bg_free_*` copies) going stale after a write was a
harmless, e2fsck-only cosmetic gap. Trying to `mkdir` a test directory
on the real card's `EXT2TEST` partition (to test write-into-
subdirectory on real hardware) showed that's wrong: Linux's own ext2
driver checks this at *mount* time and, seeing the volume "has errors"
(the exact same mismatch `e2fsck` flags), auto-remounts it read-only
(`errors=remount-ro`) — a real, practical consequence blocking any
further write access from the Linux side after a single kernel-driven
write, not just a dry-run complaint.

**Fix**: `ext2_alloc_block()`/`ext2_alloc_inode()` now each call a new
`ext2_dec_free_blocks()`/`ext2_dec_free_inodes()` right after
successfully marking their own bitmap bit — decrements both the
superblock's copy (fixed sector 2, alongside every other superblock
field this driver already reads) and group 0's own copy in the block
group descriptor (same block `ext2_mount()` already reads at
`ext2_first_data_block + 1`). No corresponding increment path exists
because there's no delete/unlink in this driver at all (v1 scope) —
allocation is the only direction free counts ever need to move.

**Verified**: `e2fsck -n -f` on a fresh `disk_ext2.img` after
`writefile`+`newfile` (2 new allocations) came back completely clean —
no errors of *any* kind, not even the previously-accepted mismatch.
Repeated with `newsubfile`/`newsubfile2`/`newfile2` together on
`disk_dual.img`'s ext2 half (4 allocations across two directories):
same, fully clean result. Full regression suite unaffected, `racetest`
still `a=1 b=1`.

**Files changed:** `user/fs/ext2.c3` (`EXT2_SB_FREE_BLOCKS_COUNT`/
`EXT2_SB_FREE_INODES_COUNT`/`EXT2_BGD_FREE_BLOCKS_COUNT`/
`EXT2_BGD_FREE_INODES_COUNT` offsets, `ext2_dec_free_blocks`/
`ext2_dec_free_inodes`, wired into `ext2_alloc_block`/
`ext2_alloc_inode`; removed the now-inaccurate "accepted gap" comment).

---

## 2026-08-19 (2) — Write-into-subdirectory support for both fsd backends

The deliberately-deferred half of subdirectory support (see the
read-only entry below) — create/overwrite/grow a file inside a
subdirectory, not just the root. Higher-stakes than the read side (a
write bug can corrupt real data, per every other write-path entry in
this log), so built and verified carefully, right after fixing a real
write-path corruption bug in the same files.

**Design, same shape in both backends, mirroring the read-only
generalization**: every write-path function that was hardcoded to the
root now takes the containing directory (cluster/inode) as a
parameter, resolved once via the existing `fat32_resolve_dir`/
`ext2_resolve_dir` — no new directory-walking logic, reusing exactly
what the read path already proved.

- `user/fs/fat32.c3`: `fat32_find_in_dir` gained entry_sector/
  entry_offset out-params (needed for the protected-entry check and
  size updates, which the read-only version never needed);
  `fat32_find_free_dirent`/`fat32_create_file` both gained a
  `dir_cluster` parameter; `fat32_write` resolves the directory first,
  then does everything else the same way it always did, just against
  that cluster instead of always the root.
- `user/fs/ext2.c3`: same shape — `ext2_find_in_dir` gained entry_
  sector/entry_offset, `ext2_create_file` gained a `dir_inode_num`
  parameter (its body's `root` local simply renamed `dir`, no logic
  change), `ext2_write` resolves the directory first. Reuses the exact
  same, already-fixed inode-creation code from this session's earlier
  corruption fix (`links_count = 1`, `i_blocks` maintained) — nothing
  new to get wrong there.

`fat32_find_in_root`/`ext2_find_in_root` and their own root-only
caller (`*_reserve_protected`, looking up `fip.bin`) are completely
untouched — that file only ever lives in the root regardless of what
this feature does.

**Verified rigorously**: new `newsubfile`/`newsubfile2` shell commands
(create-then-readback inside `subdir/`, mirroring `newfile`/`newfile2`'s
own pattern) on both single- and dual-mount QEMU images. For ext2
specifically, ran the same `e2fsck -n -f` oracle this session's
corruption fix introduced on the resulting image — only the
pre-existing, already-accepted free-count cosmetic mismatch showed up,
confirming the subdirectory write path doesn't reintroduce that bug
(expected, since it reuses the already-fixed code, but confirmed
rather than assumed). For FAT32, independently confirmed via `mdir`
(mtools, not `fsd`'s own read-back) that the new directory entry is
real and correct. Also confirmed: overwriting an already-created
subdirectory file reuses its entry correctly (doesn't duplicate or
corrupt), and a write into a nonexistent directory fails cleanly (the
identical `resolve_dir` the read path already relies on, not new logic
to break). Full regression suite otherwise unaffected, `racetest`
still `a=1 b=1`.

**Confirmed on real Duo hardware** too (FAT32 side — `subdir/nested.txt`
seeded onto the real `DUOBOOT` partition for this; the ext2 side's own
subdirectory support stays QEMU-only for now, same call made for the
read-only entry below, reasonable here too since its write logic is
identical to `newfile2`'s already hardware-confirmed-fixed path):
`readsubfile` correctly read `nested.txt`, and `newsubfile` correctly
wrote and read back a new file inside `subdir/` — a real `CMD00000018`
(write) visible in the console trace, not just a successful-looking
readback.

**Files changed:** `user/fs/fat32.c3` (`fat32_find_in_dir`'s new
out-params, `fat32_find_free_dirent`/`fat32_create_file`'s
`dir_cluster` parameter, `fat32_write` updated), `user/fs/ext2.c3`
(same shape: `ext2_find_in_dir`'s new out-params, `ext2_create_file`'s
`dir_inode_num` parameter, `ext2_write` updated), `user/shell.c3`
(`newsubfile`/`newsubfile2`).

---

## 2026-08-19 — Real ext2 write-path corruption, found by looking at the card from Linux's own side

Flashing the previous session's fip.bin surfaced something none of this
project's own ext2 write-path testing had ever caught: `ls -la` on the
real card's `EXT2TEST` partition showed `newtest.txt`/`newtest2.txt`
(created earlier via `fsd`'s `newfile`/`newfile2` commands) as
`???????????`, unreadable, "structure needs cleaning" — even though
`fsd`'s own read-back had reported them correct at the time. First
time this session's testing looked at a real-hardware write from
Linux's own side rather than trusting `fsd`'s self-consistency check.

`sudo e2fsck -n -f /dev/sdc2` (read-only, no repairs — run by hand in a
real terminal, `sudo` needs an interactive password this session can't
supply) found two real, distinct bugs in `user/fs/ext2.c3`'s write
path, both pre-existing from last week's "ext2 write support" work, not
introduced by anything since:

1. **`i_links_count` never set.** `ext2_create_file()` calls
   `ext2_zero_inode()` (zeroes the whole raw inode record) then
   `ext2_write_inode()`, which only ever wrote `mode`/`size`/`block[]`
   — `i_links_count` stayed 0 forever. A real ext2 reader treats
   link-count 0 + dtime 0 as "not actually a live file", regardless of
   a directory entry pointing at it with real content — exactly
   `e2fsck`'s "deleted inode has dtime zero" / "directory element
   references deleted/unused inode" findings. Not a bitmap-allocation
   bug (initially suspected, then ruled out by reading `ext2_alloc_
   inode()`'s code directly — it does set its bitmap bit correctly).
2. **`i_blocks` never maintained.** Separate from `i_size` (which
   *was* kept correct, per the file's own existing header comment) —
   `Ext2_inode_info` didn't even model this field, so it stayed at
   whatever `mke2fs` initially wrote regardless of how many blocks a
   file or directory actually gained afterward. Caught as "i_blocks is
   8, should be 24" on the root directory (grew by 2 blocks from the
   two `newfile`/`newfile2` real-hardware tests, count never updated).

**Fix**: `Ext2_inode_info` gained `links_count`/`blocks` fields;
`ext2_read_inode`/`ext2_write_inode` now round-trip both (offsets 26/28
in the standard inode layout, alongside the already-read `mode`/`size`).
`ext2_create_file()` sets `links_count = 1` on every newly created
inode and bumps `root.blocks` when appending a directory block;
`ext2_write_file()` bumps the file's own `.blocks` when allocating a
genuinely new block (not a partial rewrite of an existing one). The
free-block/inode *count* fields (`s_free_blocks_count` etc.) remain
deliberately unmaintained — that's the file's own pre-existing,
documented scope decision, not part of this bug, and `e2fsck` still
correctly (harmlessly) flags that mismatch alone after the fix.

**Verified rigorously**, differently from every previous ext2 session:
QEMU's `disk_ext2.img`/`disk_dual.img` are plain files, so `e2fsck -n
-f` could run directly on them (and on a `dd`-extracted copy of
`disk_dual.img`'s ext2 half) with no root needed — a real correctness
oracle this project's ext2 work never had before. Before the fix:
`writefile`+`newfile` on a fresh `disk_ext2.img` reproduced the exact
same "deleted inode" / "i_blocks wrong" errors seen on the real card.
After the fix: those are gone entirely, only the pre-existing
free-count cosmetic mismatch remains, on both `disk_ext2.img` and
`disk_dual.img`. Full regression suite (both single- and dual-mount
images) otherwise unaffected, `racetest` still `a=1 b=1`. Reflashed
`build/fip_duo.bin` with the fix and confirmed on real hardware
(`newfile2` created and read back correctly through fsd2's own ext2
write path). The two already-corrupted legacy files on the real card
predated this fix; cleaned up separately via `sudo e2fsck -y -f
/dev/sdc2` (run by hand), confirmed clean afterward.

**Files changed:** `user/fs/ext2.c3` (`EXT2_INODE_LINKS_COUNT`/
`EXT2_INODE_BLOCKS` offsets, `Ext2_inode_info.links_count`/`.blocks`,
`ext2_read_inode`/`ext2_write_inode` round-trip both,
`ext2_create_file`/`ext2_write_file` maintain them correctly).

---

## 2026-08-18 (4) — Read-only subdirectory support for both fsd backends

Third of three requested follow-ups from the multi-mount work. Both
FAT32 and ext2 were deliberately root-directory-only in v1 (each
backend's own header comment). Scoped this pass to reads only — write
support (create/overwrite/grow *inside* a subdirectory, as opposed to
the existing root-only write path) is real, separate work with real
data-corruption stakes on a live boot partition, and wasn't attempted
unsupervised.

**Design, same shape in both backends**: a subdirectory is just an
ordinary directory entry/inode whose own data holds more directory
entries — the same layout the root directory already uses — so the new
code is the existing root-walking function generalized to take any
starting point, not new logic. `fat32_find_in_root`/`ext2_find_in_root`
and every write-path caller of either are completely untouched.

- `user/fs/fat32.c3`: `fat32_find_in_dir(dir_cluster, ...)` (generalizes
  `fat32_find_in_root`, also reports the matched entry's attribute byte
  so a caller can tell a subdirectory from a file via the newly-added
  `FAT32_DIRENT_ATTR_DIRECTORY` bit), `fat32_resolve_dir()` (splits a
  path on `/`, walks each directory component, requiring
  `ATTR_DIRECTORY` at each step), `fat32_leaf_name()`. `fat32_read`
  resolves the containing directory first, then looks up the leaf there
  instead of always in the root, and refuses to "read" a directory as
  file content.
- `user/fs/ext2.c3`: `ext2_find_in_dir(dir_inode_num, ...)` (same
  generalization, reports the matched entry's inode mode —
  `EXT2_S_IFDIR` already existed as a format constant, unused until
  now), `ext2_resolve_dir()`, `ext2_leaf_name()`. `ext2_read` updated
  the same way.

Both resolve functions support arbitrary nesting depth (not just one
level) for free — the path-splitting loop doesn't care how many `/`s it
crosses — and skip empty segments (a leading `/`, a doubled `//`)
rather than failing on them.

**Verified on QEMU**, both single- and dual-mount images: new
`disk/subdir/nested.txt` and `disk-ext2/subdir/nested.txt` test fixtures
(`scripts/build.sh`, seeded via `mmd`/`mcopy` for FAT32 and `debugfs`'s
own `mkdir` for ext2), new `readsubfile`/`readsubfile2` shell commands.
Both backends correctly resolve into their subdirectory and return the
right, distinct content through both mounts simultaneously; full
existing regression suite (including `racetest`, now consistently
`a=1 b=1` after this session's `PROCS_MAX` fix above) unaffected.

**Files changed:** `user/fs/fat32.c3` (`FAT32_DIRENT_ATTR_DIRECTORY`,
`fat32_find_in_dir`/`fat32_resolve_dir`/`fat32_leaf_name`, `fat32_read`
updated), `user/fs/ext2.c3` (`ext2_find_in_dir`/`ext2_resolve_dir`/
`ext2_leaf_name`, `ext2_read` updated), `user/shell.c3`
(`readsubfile`/`readsubfile2`), `scripts/build.sh` (subdirectory test
fixtures in all three QEMU test images), new `disk/subdir/nested.txt` /
`disk-ext2/subdir/nested.txt`.

---

## 2026-08-18 (3) — Closing the stale-namespace-pid gap, and the real racetest culprit: PROCS_MAX, not IPC

Two follow-ups from the multi-mount entry below, both requested
explicitly rather than found by accident this time.

**1. The documented `SYS_IPC_SEND` "KNOWN GAP"**: a namespace entry
(`Mount.server_pid`) was a plain pid snapshot taken once at the
resolving process's own creation time, never refreshed — if the
original target exited and its slot got reused, the entry could
silently start resolving to an unrelated process. Fixed the way the
gap comment itself suggested: `Mount` gained a `server_generation`
field, populated via a new `mount_generation()` helper (`proc_by_pid`
+ `.generation`, 0 if the target doesn't currently exist) at the exact
three call sites `create_process()` already populates `server_pid` at.
`SYS_NS_RESOLVE` (`src/entry.c3`) now requires a live match on *both*
pid and generation before handing a mount's `server_pid` back — the
same "this exact instance, not a reused slot" distinction `SYS_JOIN`
already relies on for its own purpose. Fixed one layer up from where
the old comment sat (`SYS_IPC_SEND`'s `proc_by_pid` check): a caller
can now never *obtain* a hijacked pid through namespace resolution in
the first place, so `SYS_IPC_SEND` itself needs no new logic — its
existing `proc_by_pid` null-check still does its original, narrower
job (guarding against a genuinely dead/never-existed pid). The exact
original trigger (fsd2 panicking and freeing its slot) no longer
exists to re-run live, since that path was already made non-fatal in
the multi-mount work — verified instead by full QEMU regression
(single- and dual-mount images), confirming no behavior change in any
working case, and by code-level comparison against `SYS_JOIN`'s
already-proven pattern.

**2. `racetest`'s `a=0 b=0`**, chased for real this time instead of
being logged as a known-orthogonal issue. Static tracing of the
send/recv rendezvous mechanism through several interleavings turned up
nothing — the mechanism is genuinely serialized, no clobbering possible
by construction. Added temporary debug prints (raw reply bytes, sender
pid, `threadcreate()`'s own return values) rather than keep
speculating. The very first data point broke the case open:
`threadcreate()` was returning `-1` for *both* racing threads — never
even creating them, let alone corrupting a reply. Root cause:
`process.c3`'s `PROCS_MAX` was 8, and by the time `racetest` runs in
the full regression sequence, all 8 slots are already spoken for (idle,
echod, diskd-or-sdd, fsd, fsd2, shell, rforktest's child, sandboxtest's
child) — zero left for racetest's own two `threadcreate()` calls.
`join()` on a pid that was never actually created returns immediately
(`proc_by_pid` correctly says "gone"), so `race_ok_a`/`race_ok_b` are
read back at their reset value of 0 before the (nonexistent) threads
ever run. This also fully explains the *original* `a=1 b=0` baseline,
long before any of this week's changes: even at 7 permanent+child
processes, only one spare slot existed — thread A got it, thread B's
`threadcreate()` failed the same way. Never an IPC bug at any point.

Fixed by raising `PROCS_MAX` to 16 (real headroom over the 6 permanent
boot processes plus concurrent test children/threads; costs an extra
512KB of static kernel memory, negligible against the 64MB DRAM budget
on both QEMU and the Duo — confirmed via each board's own `kernel.ld`
that the free-RAM pool either has fixed generous headroom already
(QEMU) or self-sizes against whatever's left (Duo), not a fixed window
that could overflow). Also hardened `racetest` itself
(`user/shell.c3`) to check `threadcreate()`'s return value and report
"threadcreate failed (no free process slot) — inconclusive" distinctly,
so a future `PROCS_MAX`-exhaustion regression can never again be
mistaken for IPC/rendezvous corruption. Verified: `racetest: a=1 b=1`,
reproducible across repeated runs on both the single- and dual-mount
QEMU images, full regression suite otherwise unaffected.

**Files changed:** `src/process.c3` (`Mount.server_generation`,
`mount_generation()`, `PROCS_MAX` 8→16), `src/entry.c3`
(`SYS_NS_RESOLVE`'s generation check, `SYS_IPC_SEND`'s comment
updated), `user/shell.c3` (`racetest`'s `threadcreate()` failure
check and updated comment).

---

## 2026-08-18 (2) — Two simultaneous fsd mounts, and a real self-deadlock bug found along the way

Until now, switching filesystems on the Duo meant editing
`board::FS_PARTITION_START_SECTOR`, rebuilding, and reflashing — done
twice already this week for the ext2 work. This adds a second, parallel
`fsd` instance (`fsd2`) so both the FAT32 and ext2 partitions already on
the card are mounted at once, at boot, permanently.

**Design**: `src/kernel.c3` spawns `fsd2` right after `fsd`, gated on a
new `board::HAS_SECOND_FS_PARTITION` (plus `FS_PARTITION_2_START_SECTOR`)
— false on the Duo's original config and on QEMU's default `disk.img`,
so this is additive, not a behavior change for anything not opted in.
`src/process.c3`'s `Process.namespace` gets a second, fixed entry:
`"/2/" -> fsd2_pid`, populated at `create_process()` time exactly like
the existing `"" -> fsd_pid` entry. `SYS_FS_PARTITION_INFO` now reads a
new per-process `Process.fs_partition_start` field (set via
`setup_fsd_mappings()`) instead of `board::FS_PARTITION_START_SECTOR`
directly, so `fsd`/`fsd2` — two copies of the exact same binary — each
learn their own partition's start sector at boot despite being
identical code. `SYS_NS_RESOLVE` gained a second out-parameter (matched
prefix length), so `fs_read`/`fs_write` (`user/user.c3`) can strip
`"/2/"` before building the wire-format request — `fsd.c3`/`fs/fat32.c3`
/`fs/ext2.c3` needed zero changes, they already only ever see bare
filenames.

**Real bug found**: `readfile2` (a new shell command targeting `/2/`)
produced no output at all on QEMU's default single-partition `disk.img`
— not even the coded fallback message. Root cause: `fsd2` finds no
filesystem on that image and, at the time, called `fs_panic()` (fatal,
`exit()`s) on "no recognized filesystem found". `SYS_EXIT` frees the
process's slot; the very next process created (the shell) reuses that
same freed pid via `create_process()`'s first-free-slot scan; the
shell's own `"/2/"` namespace entry — populated from the stale
`fsd2_pid` global — now points at the shell's *own* pid. `ipc_send` to
yourself deadlocks (parked waiting for a receive you can't issue until
the send call itself returns). Fixed narrowly: `fsd.c3`'s `fs_mount()`
no longer panics on "no recognized filesystem" — it prints and returns,
leaving `fs_type = FS_TYPE_NONE`, which `main()`'s existing dispatch
already handles cleanly (a `-1` reply for every verb, the same shape as
the already-proven "ext2 rejects writes" path). This is a narrow fix for
one trigger, not the underlying hazard class: any namespace entry is a
plain pid snapshot taken once at the *resolving* process's own creation
time, never refreshed, so a *target* that later exits and whose slot
gets reused by something else would silently misroute too — `proc_by_pid`
correctly rejects a fully-dead, unreused pid, but has no way to detect
"same pid, different instance". `SYS_JOIN`'s existing `Process.generation`
field is the right building block for a real fix (documented as a
"KNOWN GAP, not fixed here" comment at `SYS_IPC_SEND` in `src/entry.c3`);
not implemented this session.

**A red herring, chased down properly rather than waved off**: after
the deadlock fix, the QEMU regression suite started showing
`racetest: a=0 b=0` instead of the historical `a=1 b=0`. Compared
directly against the pre-multi-mount build (git stash, rebuild, same
exact command sequence) — that build reproduced `a=1 b=0` every time,
confirming the shift was real, not noise. But reading `race_thread_a`/
`race_thread_b`/`echod.c3` shows each racing thread is a full `RFPROC`
child with its own distinct pid and echod's reply path is fully
serialized by IPC's own rendezvous — there's no code path where one
thread's reply lands in the other's mailbox by design. Since the
baseline was *already* `a=1 b=0` (not `a=1 b=1`) before any of today's
changes, this is a pre-existing, narrow race in the IPC/threading path
that predates this session; the extra `fsd2` process just shifts
pids/scheduling enough to flip which manifestation shows (one-loses to
both-lose). Logged here as a known separate issue, not fixed — it's
orthogonal to this feature and every other test passes correctly.

**Verified on QEMU**: a new `build/disk_dual.img` (FAT32 at sector 0 —
matching the same fixed `FS_PARTITION_START_SECTOR` the default
`disk.img` uses, an earlier attempt at sector 2048 just meant the first
`fsd` found nothing — and ext2 at sector 18432, `scripts/build.sh`) via
new `scripts/launch64_dual.sh`: both `fsd: FAT32 mounted...` and
`fsd: ext2 mounted...` appear at boot, `readfile`/`readfile2` return
correct, distinct content in the same boot, and the full regression
suite passes otherwise unchanged.

**Verified on real Duo hardware**, both partitions already on the card
from earlier sessions, no board.c3 edits needed: `readfile` (mount 1,
FAT32) returned `Hello from disk!`; `readfile2` (mount 2, ext2) returned
`Hello from shell!` — surprising at first (not the `Hello from ext2!`
recorded in the ext2-verification entry above), until traced to the
`ext2 write support` entry's own real-hardware `writefile` test, which
overwrote that exact file and was never reverted (only the temporary
`FS_PARTITION_START_SECTOR` swap was). Confirmed this was real,
correctly-routed ext2 data and not a routing bug by checking the
console's own `sdd: rw sector=...` lines: mount 2's reads land at
absolute sector ≈2,103,884, well inside the ext2 partition (starting at
2,099,200) and nowhere near mount 1's much lower sector range — two
distinct mounts, two distinct real files, same boot. Added a `newfile2`
shell command (mirrors `newfile`, routed through `/2/`) for an
unambiguous write-path check independent of that stale-data question:
creates a new file on the ext2 mount and reads it back —
`Created by newfile2 test`, correct, with I/O sectors again confirmed
inside the ext2 partition range.

**Files changed:** `src/process.c3` (`fsd2_pid`, `Process.fs_partition_start`,
`setup_fsd_mappings()`, second namespace entry), `src/entry.c3`
(`SYS_FS_PARTITION_INFO` reads the per-process field, `SYS_NS_RESOLVE`'s
prefix-length out-param, the IPC hazard comment), `src/kernel.c3`
(conditional `fsd2` spawn), `boards/duo/board.c3` /
`boards/qemu/board.c3` (`HAS_SECOND_FS_PARTITION`,
`FS_PARTITION_2_START_SECTOR`), `user/user.c3` (`ns_resolve()`'s new
out-param, prefix-stripping in `fs_read`/`fs_write`), `user/shell.c3`
(`readfile2`, `newfile2`), `user/fsd.c3` (non-fatal `fs_mount()` on no
filesystem found), `scripts/build.sh`/new `scripts/launch64_dual.sh`
(`disk_dual.img`).

---

## 2026-08-18 — A real timer primitive, replacing sdd.c3's guessed busy-wait counts

`user/sdd.c3` had a standing, self-documented gap: no `rdtime` access
from user mode (`scounteren.TM` never enabled), so every wait loop —
command-complete, data-ready, transfer-complete, the one-time clock/
reset waits — was a raw iteration count (`SD_WAIT_MAX`/
`SD_SETUP_WAIT_MAX`) with no real correspondence to wall-clock time.

**Real values confirmed, not guessed**, same discipline as this
project's SDHCI register maps: Duo's real `timebase-frequency` (25MHz)
read directly from the real devicetree in `duo-buildroot-sdk`; QEMU
`virt`'s (10MHz) extracted directly from the actual
`qemu-system-riscv64` binary via `-machine virt,dumpdtb=...` + `dtc`,
not assumed from general RISC-V/QEMU folklore. Real per-wait timeout
budgets (100ms command-inhibit, 1000ms command-complete, 20ms clock-
stable, 1000ms each for data-ready/transfer-complete) sourced from the
real U-Boot generic SDHCI driver, the same file already read once
earlier this session for the SDHCI_TRNS_READ bug.

**Kernel**: `enable_user_timer_access()` (`src/entry.c3`) sets
`scounteren.TM`, called once at boot next to the existing
`enable_external_interrupts()`. **User-mode**: `rdtime()`
(`user/user.c3`) — direct CSR read via the opaque-string `asm()` form
bridged through a memory temp, not the structured `asm {}` block (which
doesn't recognize `rdtime`/`csrr` at all) and not raw a0 (a real hazard
already found once in this exact codebase, in `entry.c3`'s own
`read_reg` macro — the compiler can silently clobber a value it still
thinks is live in a0). Every one of `sdd.c3`'s five wait loops converted
to `rdtime()`-bounded real time; `SD_WAIT_MAX`/`SD_SETUP_WAIT_MAX`
removed entirely.

Verified on QEMU (full regression suite — `sdd.c3` isn't even spawned
there, confirms the kernel-side change doesn't regress anything else)
and real Duo hardware: every wait now reports genuine, sensible
microsecond figures (`ready after 251us`, not a meaningless iteration
count) with `readfile`/`newfile`/`writefile` all still correct.

Also noticed, while reading the real-hardware output, that
`fip.bin`'s write-protected cluster count had jumped from ~19 to 150 —
initially concerning, but the real, benign explanation: the FAT32
partition was resized much smaller during yesterday's ext2 work, and
`mkfs.vfat` auto-selects cluster size by volume size (4KB clusters on
the new 1GiB partition vs. the original 32KB on the 58GB card) — same
file, proportionally more (smaller) clusters. Confirmed via
`610816 ÷ 150 ≈ 4072 bytes`, essentially exactly 4096, and independently
by `readfile`/`newfile` both still returning correct real content — not
a regression from this session's own changes.

**Explicitly out of scope**: `sstc`/`stimecmp` timer *interrupts* (real
preemptive sleep/scheduling) — `sdd.c3`'s actual problem was an
inaccurate busy-wait bound, not a need to yield the CPU while waiting; a
plain elapsed-ticks read solves that completely. Timer interrupts are a
separate, larger feature (touches the scheduler, not just one driver).

**Files changed:** `src/entry.c3` (`enable_user_timer_access()`),
`src/kernel.c3` (call it), `user/user.c3` (`rdtime()`), `user/sdd.c3`
(`SD_TIMEBASE_HZ`, real per-wait timeout constants, every wait loop
converted, `print_uint()` added, `SD_WAIT_MAX`/`SD_SETUP_WAIT_MAX`
removed).

---

## 2026-08-17 (7) — ext2 write support

**Continuing from this same day's ext2-verification entry.** Brought
`user/fs/ext2.c3` up to the same level FAT32 has: create, overwrite,
grow. Reused `fsd.c3`'s generic write-protection machinery verbatim —
`fs_reserve_sector_range()`, `fs_set_protected_entry()`/
`fs_is_protected_entry()`, enforcement in `fs_write_sector()` — nothing
new needed there, which was the actual point of building the
abstraction earlier today.

What's structurally different from FAT32's write path, and where all
the new code went: ext2 allocates space via **bitmaps** (one bit per
block/inode in a group — `ext2_alloc_block()`/`ext2_alloc_inode()`), not
a linked list like the FAT table, and needs a genuinely separate
allocation step for **inodes** (a fixed-size, pre-allocated table —
FAT32 has no equivalent; creating a file there only ever needed a free
cluster + a free directory slot). Directory entries are variable-length
records, but v1 sidesteps splitting an existing entry's trailing
`rec_len` (a real ext2 allocator technique) — creating a file always
appends a fresh directory block containing just that one entry, a
documented inefficiency parallel to FAT32 write's own "shrinking doesn't
free the now-excess clusters" gap. Free-space bookkeeping
(`bg_free_blocks_count`/`s_free_blocks_count` and their inode
counterparts) is deliberately not maintained — a real `e2fsck` would
flag the mismatch and offer to fix it, but nothing about it corrupts
data or blocks a real ext2 driver from reading the volume; accepted,
documented gap. Directory `i_size` *is* kept correct when a directory
gains a block, since real ext2 readers use it to know how far to scan —
unlike the free-count fields, getting this wrong could make a real
Linux box's `ls` misbehave.

**Worked correctly on the very first real-hardware attempt** — no bugs
found this time, unlike `newfile`'s first real-hardware run during
FAT32 write support (the shared-root-directory-cluster reservation bug)
or the SD read-data-loss bug earlier today. Verified in order, on both
QEMU (`scripts/launch64_ext2.sh`) and real hardware (the same temporary
`FS_PARTITION_START_SECTOR`-swap procedure used for read verification,
reverted afterward): `writefile` (overwrite), `readfile` (confirms it),
`newfile` (genuinely new inode + directory entry, confirmed via its own
readback), `protectedwrite` (correctly rejected — exercises the generic
filename check same as FAT32's does). Full existing FAT32 regression
suite re-run on QEMU too, unaffected.

**Files changed:** `user/fs/ext2.c3` (bitmap allocation, inode read-
modify-write, directory-entry creation, `ext2_write()`,
`ext2_reserve_protected()`), `user/fsd.c3` (`fs_mount()`'s
`FS_TYPE_EXT2` branch gains write-protection setup via a new shared
`fs_reserve_protection_summary()` helper; `main()`'s `FS_WRITE` dispatch
gains an `ext2_write()` branch). No shell/wire-protocol changes needed —
`writefile`/`newfile`/`protectedwrite` already worked against whichever
backend was mounted.

---

## 2026-08-17 (6) — ext2 verified on real Duo hardware

**Continuing from this same day's filesystem-abstraction entry.**
`user/fs/ext2.c3` had only ever run on QEMU; this confirmed it on the
real board. The catch: the Duo's only SD card is also what boots it —
BootROM reads `fip.bin` directly off the FAT32 `DUOBOOT` partition (the
whole session's own flashing workflow already proved this: mount FAT32,
copy a file literally named `fip.bin` onto it, unmount, boot), so a
card without that file findable on a FAT32 partition can't boot this
board at all. Swapping in a second, dedicated SD card was ruled out for
exactly that reason — the board only has one slot.

**Repartitioned the boot card** instead: shrunk the FAT32 partition (a
full reformat, not a resize — `fatresize` isn't installed, and shrinking
only the MBR table entry without also shrinking the FAT32 filesystem's
own internal structures would leave it believing it's larger than its
new boundary, a real corruption risk; only 736K was actually in use, so
reformat-and-restore was both simpler and safer) to 1GiB at its
original start sector (2048, unchanged — so
`board::FS_PARTITION_START_SECTOR` needed no permanent code change), and
added a second 1GiB ext2 partition right after it. The user ran the
actual `sfdisk`/`mkfs.vfat`/`mke2fs` commands (root-only, and this
session's sandbox has no root at all — confirmed, `sudo` needs a
password); everything else — restoring `fip.bin`/`hello.txt` onto the
reformatted boot partition, seeding the ext2 partition via `debugfs -w`
directly on the block device (the mounted ext2 filesystem itself is
root-owned by default, unlike FAT's no-real-ownership model, so a
regular mount + copy hit a permission error; writing straight to the
device — the same approach already used for the QEMU test image —
sidesteps that) — needed no elevated privileges.

Temporarily pointed `board::FS_PARTITION_START_SECTOR` at the new ext2
partition's start sector, rebuilt, reflashed `fip.bin` (still onto the
FAT32 partition — that's what BootROM reads regardless of which
partition `fsd` itself mounts), and confirmed on the real console:
`fsd: ext2 mounted, block_size=4096 inode_table_block=67` (4096, not the
1024 QEMU's smaller test image used — a genuinely different block size,
still within `EXT2_MAX_BLOCK_SIZE`), and `readfile` returned the real,
correct `Hello from ext2!` content. Reverted the constant back to
`2048`, rebuilt, reflashed, and confirmed the board returned to its
normal FAT32-mounted state — the same `Hello from disk!` content as
always. The ext2 test partition is left in place on the card afterward,
inert and harmless.

**Files changed:** none permanently — `boards/duo/board.c3`'s
`FS_PARTITION_START_SECTOR` edit was temporary and reverted to its
committed value before this entry was written.

---

## 2026-08-17 (5) — fsd: filesystem backend abstraction, plus a real ext2 read-only backend

**Continuing from this same day's FAT32 write-support entry.** The ask:
real ext2 support, with "a good file structure, interface and
abstraction" prepared first — `fsd` only ever spoke one on-disk format,
and `user/fsd.c3` mixed the IPC/wire protocol, the filesystem-agnostic
sector-I/O + write-protection machinery, and FAT32-specific structure
parsing all in one file. Adding ext2 the way FAT32 was added would have
either duplicated the generic parts or tangled two unrelated formats
together.

**Split into three files**, all still `module user;` (matching every
other user-mode file — `c3c compile-only` already takes an explicit
source-file list per binary, so this needed no new build machinery,
just adding files to `scripts/build_user.sh`'s existing `fsd` line):
`user/fsd.c3` (generic core — IPC loop, sector I/O, write protection,
mount-time backend dispatch), `user/fs/fat32.c3` (the existing FAT32
logic, moved and renamed to a consistent interface —
`fat32_probe`/`fat32_mount`/`fat32_read`/`fat32_write`/
`fat32_reserve_protected` — otherwise unchanged), `user/fs/ext2.c3`
(new). No function-pointer/vtable dispatch — checked this codebase for
precedent first (structs here are plain data: `Process`/`Mount` in
`src/process.c3`, `@packed` wire layouts like `Virtio_blk_req`) and
found none, so `fsd.c3` just holds an `fs_type` global and dispatches
through a couple of `if`s.

**Write protection generalized** from FAT32-specific clusters to plain
absolute sector ranges (`fs_reserve_sector_range()`/
`fs_sector_is_reserved()`, replacing the old cluster-number allowlist) —
each backend now computes its own protected file's ranges in whatever
unit is natural to it and hands `fsd.c3` sector numbers; `fsd.c3` itself
never needs to know what a "cluster" or "block" is. The exact-entry
protected-slot check was already sector+offset based, so it moved over
unchanged, just via a new `fs_set_protected_entry()` setter instead of
backends touching `fsd.c3`'s globals directly.

**ext2 backend, read-only, root directory only** (matching FAT32's own
first pass): superblock at the fixed byte offset 1024 (magic `0xEF53`),
block group 0's descriptor for the inode table location, direct block
pointers only (`i_block[0..11]` — no indirect blocks in this pass), and
variable-length directory-entry records (unlike FAT32's fixed 32-byte
entries, ext2 names aren't padded/fixed-width, so no 8.3-style
conversion is needed at all — matching by exact length + bytes instead).
Probed first in `fs_mount()`'s dispatch, ahead of FAT32: its magic is a
specific 16-bit value at a fixed offset, a much more unambiguous
signal than FAT32's `0xAA55` (shared with plain MBRs and every other
x86-bootable format).

**Verified on QEMU**: the full existing regression suite
(`readfile`/`writefile`/`newfile`/`protectedwrite`/`hello`/`ping`/
`p9test`/`nstest`/`rforktest`/`sandboxtest`/`racetest`) against the
refactored FAT32 path — byte-for-byte identical output to before the
split. A new, additional test image (`build/disk_ext2.img`, built via
`mke2fs`/seeded via `debugfs -w` — no root needed, same spirit as how
`mtools` seeded the FAT32 image) and `scripts/launch64_ext2.sh` (a
near-duplicate of `launch64.sh` pointing at the ext2 image instead)
confirm `ext2_probe()` picks the right backend and `readfile` returns
the real, correct content of a file seeded directly into the ext2 image.
Also confirmed the Duo cross-build (`build_duo.sh`/`build_duo_fip.sh`)
compiles cleanly against the new multi-file layout — **not yet flashed
or verified on real hardware**, since that needs someone physically
power-cycling the board and reading back the console.

**Files changed:** `user/fsd.c3` (rewritten as the generic core),
`user/fs/fat32.c3` (new — moved from the old `fsd.c3`),
`user/fs/ext2.c3` (new), `scripts/build_user.sh` (new source files for
the `fsd` binary), `scripts/build.sh` (additional `disk_ext2.img` build
step), `scripts/launch64_ext2.sh` (new), `disk-ext2/hello.txt` (new
ext2 test-image seed file).

---

## 2026-08-17 (4) — fsd: full FAT32 write support, structurally blocked from ever touching fip.bin

**Continuing from this same day's read-only FAT32 entry.** The ask:
real write support (create new files, grow existing ones — not just
overwrite-in-place), with a guarantee stronger than "don't write to
fip.bin by name" — a bug in the new allocator/directory code shouldn't
be able to reach the file that boots this board either.

**Design**: `fs_init()` looks up `fip.bin`'s real directory entry and
walks its entire cluster chain once at mount time, recording every data
cluster it occupies in a small reserved-cluster allowlist. `diskd_rw()`
— the one function every write in `fsd.c3` funnels through, whether it's
file data, a FAT-table update, or a directory entry — refuses any write
landing on a reserved cluster; `fs_write_disabled` starts `true` and
fails the whole write path closed if the reservation ever can't be built
completely (list overflow, a read failure mid-chain-walk), rather than
risk protecting only part of the file. A separate, fast filename check
(`fs_is_protected_name`) rejects `fip.bin` by name before any lookup at
all — belt-and-suspenders, not the only line of defense.

**Real bug found on the very first real-hardware write attempt**: `newfile`
(a new shell command added specifically to exercise directory-entry
creation, since `writefile` only ever overwrote the pre-existing
`hello.txt`) failed silently — no error, no console output, nothing.
Root cause: the first version reserved fip.bin's directory-entry
*cluster*, not just its exact 32-byte entry — but in FAT32 the root
directory is itself just an ordinary cluster chain, shared by *every*
file's entry. Reserving "the cluster containing fip.bin's entry"
reserved the whole shared root-directory cluster, silently blocking any
new file's directory entry from ever being written there too — a subtle
but real design bug caught immediately by testing on the real card, not
by review. Fixed by tracking the protected entry's exact
`(sector, offset)` separately from the coarser cluster-level allowlist
(safe at that granularity precisely because file *data* clusters, unlike
the directory, are never shared between files), checked explicitly by
the two functions that ever write directory-entry bytes.

**`sdd.c3`**: implemented the write half of `sdd_block_rw` (CMD24,
symmetric to the already-working CMD17 read path) — same "no `print()`
calls between the ready-check and the buffer loop" fix that resolved the
read-side data-loss bug earlier today, applied here on the same
reasoning before it could bite on the write side too.

**Verified on real hardware, in order**: boot-time reservation confirms
fip.bin's real cluster count gets found and reserved; `newfile` creates
a genuinely new file and reads its exact content back; `writefile` still
round-trips against `hello.txt`; `protectedwrite` (new shell command)
deliberately attempts `fs_write("fip.bin", ...)` and gets rejected; a
full power-cycle afterward boots cleanly end to end — the strongest
proof available that `fip.bin` survived every step of this session's
testing completely intact.

**Files changed:** `user/fsd.c3` (reserved-cluster tracking and
enforcement, cluster allocation, FAT-entry writes mirrored across both
copies, directory-entry creation/update, `fs_do_write()`), `user/sdd.c3`
(`sdd_block_rw`'s write path), `user/shell.c3` (`newfile`,
`protectedwrite` test commands).

---

## 2026-08-17 (3) — fsd: real, read-only FAT32 support, and a shallow-FIFO PIO timing bug

**Continuing from this same day's earlier entries.** After a short
hardening pass (a sector-bounds check in `sdd_block_rw`, a negative-
length clamp on `fsd`'s untrusted request length), the bigger decision:
replace `fsd`'s original tar-based backend — always a placeholder, capped
at `FILES_MAX=2`, full-disk rewrite on every write — with a real FAT32
reader. Read-only first: on the Duo, `fsd` now points directly at the
*same* `DUOBOOT` partition that boots the board (`board::
FS_PARTITION_START_SECTOR = 2048`, `0` on QEMU's whole-disk test image),
which is only safe because a read-only driver can misparse data but can't
corrupt it. `user/fsd.c3` was rewritten around real BPB/directory-entry/
FAT-chain parsing (root directory only, 8.3 names only, no boot-time
caching — see the file's own header comment for the full v1 scope). A new
syscall, `SYS_FS_PARTITION_INFO`, mirrors the existing `SYS_DISKD_INFO`
pattern so `fsd` — one board-agnostic binary — can learn the board-only
`board::FS_PARTITION_START_SECTOR` constant at runtime. `sdd_block_rw`
lost its old `DATA_SECTOR_OFFSET`/bounds-check pair (sized for the old
fsd's small reserved region, and actively wrong once fsd started
addressing real absolute sectors) in favor of unconditionally rejecting
writes — there's no longer a well-defined "safe to write" region at this
layer. QEMU's disk image moved from a hand-rolled tar to a real
`mkfs.vfat`-built FAT32 image (`scripts/build.sh`, `mtools`/`dosfstools`,
no root needed).

Confirmed correct on QEMU immediately: byte-for-byte match against a real
`mkfs.vfat` image, `readfile` returns real file content, `writefile`
cleanly no-ops. Real hardware was a different story: `fsd: bad FAT32 boot
sector signature`, even though the SD read itself reported clean success.
First fix attempt (a wait-budget increase, on a "maybe it just needs more
polling time" theory) was flagged directly — right call, since the next
real-hardware run showed the *identical* failure, proving the guess
wrong. Real diagnosis after that: stage-by-stage prints in
`sdd_block_rw` caught the actual, first concrete bug — `sd_send_cmd`
defined `SD_TRNS_READ` (Transfer Mode's read/write direction bit) but
never set it, so every data command left the controller configured for a
*write*-direction transfer regardless of which command was issued; CMD17
(read) was getting a card response but no data. Fixed by inferring
direction from the command index. That took the SD-protocol layer from
timing out to completing cleanly — but the *data itself* still wasn't a
valid boot sector.

What followed was a careful, non-guessing elimination hunt (canary bytes
pre-filled before every read to rule out a no-op copy loop; a raw read of
absolute sector 0 to separate "PIO path untrustworthy" from "wrong
sector"; a same-sector re-read to check determinism; a full 512-byte hex
dump diffed byte-for-byte against the known-good QEMU reference). That
diff nailed it precisely: every real-hardware PIO read was losing exactly
its first 16 bytes and padding the last 16 with zero — confirmed via two
independent landmarks landing exactly 16 bytes off (the `hidden_sectors`
BPB field reading back as the real partition's own LBA start, and the
`0xAA55` signature appearing 16 bytes early). A background research pass
into the real vendor driver source (`duo-buildroot-sdk`) ruled out the
PHY RX delay-line registers (`CVI_SDHCI_PHY_TX_RX_DLY` etc. — byte-
identical to the real driver's own fixed values for this speed mode) and
pointed at `sd_send_cmd`'s blanket `SD_INT_STATUS` clear, which for a
data command could wipe the data-ready bits before the data phase ever
saw them. Narrowing that clear cut the loss from 16 bytes to 8 — real
progress, but a further experiment (removing the clear entirely, one
combined write vs. two, different orderings) kept producing a *byte-for-
byte identical* 8-byte loss no matter what was tried, which ruled out
register-write sequencing as the actual variable.

What was constant across every still-broken version: several
`print()`/`print_hex32()` calls — slow, one-character-at-a-time UART
writes — sitting between CMD17 completing and the first
`sd_reg_read(SD_BUFFER)`. The card's DAT lines start pushing data almost
immediately after command acceptance, and this SDHCI clone's PIO FIFO is
shallow enough that those prints cost real, already-arrived words before
the host ever looked — deterministically, since the same code path costs
the same wall-clock time every run. Moving every diagnostic print to
*after* the full 128-word read loop fixed it outright: real hardware now
reports genuine wait counts (thousands of iterations, not the "0 iters"
that had actually meant "already too late") and the boot sector parses
correctly — `partition_start=2048 root_cluster=2 sectors_per_cluster=64`.
`readfile` against the real, externally-placed `hello.txt` on the
physical `DUOBOOT` partition returns its exact real content end to end.

**Files changed:** `user/fsd.c3` (full FAT32 rewrite, replacing the tar
backend), `user/sdd.c3` (`SD_TRNS_READ` fix, `sd_send_cmd`'s `INT_STATUS`
clear narrowed and made data-command-aware, `sdd_block_rw`'s data-ready
wait moved to `INT_STATUS`'s own ready bit, all per-request diagnostics
deferred until after the buffer is fully drained), `user/user.c3`
(`fs_partition_info()`), `src/entry.c3` (`SYS_FS_PARTITION_INFO`),
`boards/duo/board.c3` / `boards/qemu/board.c3`
(`FS_PARTITION_START_SECTOR`), `scripts/build.sh` /
`scripts/launch64.sh` (FAT32 test image via `mkfs.vfat`/`mtools`,
replacing the old tar disk image).

---

## 2026-08-17 (2) — sdd: real operating-speed clock, confirmed on hardware

**Continuing straight from this same day's earlier entry** (sdd cleanup
+ the PLIC interrupt-storm investigation/revert). Last remaining
follow-up: `sdd` had been running the whole time — enumeration and
actual block I/O alike — on whatever slow clock BootROM happened to
leave active, since raising it was previously disabled after an earlier
version broke a working clock via a full-word register clobber (see the
PLIC-storm entry above and the original bring-up entries for that
history).

Re-added `sdd_raise_clock()`, called once after `CMD7`/`SELECT_CARD`,
targeting ~23.4MHz (375MHz source / (2×8)) — SD default-speed's own
25MHz ceiling, appropriate since this driver never sends `CMD6` to
negotiate high-speed mode. Every step is read-modify-write this time,
never a full-word write to `SD_CLOCK_SWRESET`: disable the card clock
(clear only that bit), change the divisor (RMW, preserving the
timeout-control/reset bytes), wait for internal-clock-stable, re-enable
the card clock. Confirmed via readback on real hardware:
`clock_reg=0x000e0807` — divider field `8` (exactly the target),
`INT_STABLE=1`, `CARD_EN=1` — and `writefile`/`readfile` both still
round-trip correctly at the new speed.

**Files changed:** `user/sdd.c3` (`sdd_raise_clock()`, called from
`sdd_enumerate()` after `CMD7`).

---

## 2026-08-17 — sdd cleanup, and a real PLIC hardware quirk found chasing interrupt-driven SD I/O

**Continuing from this same week's SD-storage entries.** Two follow-ups
requested after the first working `writefile`/`readfile` round trip:
trim `sdd.c3`'s bring-up-era diagnostics now that the driver works, and
convert its block I/O from busy-polling to interrupt-driven completion
(PLIC `IRQ_SDHCI`), matching `diskd`'s existing pattern. The first
landed cleanly. The second uncovered a genuine, undocumented hardware
quirk in this board's PLIC and had to be reverted.

**Trim:** removed one-off bring-up diagnostics that had done their job
(`0xDEADBEEF` MMIO write test, clock-gate/PLL/power-control readback
dumps, `HOST_CONTROL2` dump, a dead disabled `sdd_raise_clock`
function), condensed the enumeration stage markers to single lines,
kept `clock_stable` and the per-command markers — still genuinely
useful if this ever needs revisiting on a different card.

**Interrupt-driven I/O attempt:** added `board::IRQ_SDHCI` routing
through `entry.c3`'s `handle_trap` (mirroring `diskd`'s existing
`IRQ_VIRTIO_BLK` handling exactly) and enabled it in the Duo's own
`plic_init()` (a second priority + a second enable-word, since IRQ 36
falls outside `IRQ_VIRTIO_BLK`'s first 32). `sdd_block_rw`'s two
polling waits (buffer-ready, transfer-complete) became a shared
`sdd_wait_for_irq()` blocking on `SYS_IPC_POLL`, same shape as
`diskd`'s own interrupt wait. QEMU regression stayed fully clean
throughout (`IRQ_SDHCI=0` there, a dead sentinel like `IRQ_VIRTIO_BLK`
was on the Duo before this).

**Real hardware result: a total, permanent external-interrupt storm.**
The moment `sdd` turned on its own `SIGNAL_ENABLE`, the CPU started
taking `SCAUSE_SUPERVISOR_EXTERNAL` traps continuously, forever — but
PLIC `claim()` at context 1 returned 0 (nothing pending) on every
single sample, every time, across the whole investigation. Chased
through several well-reasoned but ultimately wrong theories before
finding the real cause:

- Ruled out **PLIC context number / register-offset formulas** —
  independently confirmed correct via three sources: the real
  devicetree's `interrupts-extended` property, OpenSBI's own parsed
  `s_cntx_id` (the actual M-mode firmware running on this board), and
  Linux's `irq-sifive-plic.c`. `PLIC_S_CONTEXT=1` was right all along;
  this PLIC has exactly two contexts for hart0 (context 0 = M-mode,
  explicitly marked invalid via the DT's `0xffffffff` sentinel; context
  1 = S-mode, the real one) — no hidden alternate context, no
  cvitek-specific offset override anywhere in the SDK.
- Ruled out **the IRQ number itself** — found and read the official
  CV1800B/CV1801B preliminary datasheet
  (github.com/milkv-duo/duo-files), which confirms IRQ 36 = "SD0
  interrupt" in the real interrupt-source table. Not a typo, not an
  off-by-one.
- Ruled out **stale/uncleared `SD_INT_STATUS` bits** two different
  ways — first by explicitly clearing the whole status register before
  ever enabling `SIGNAL_ENABLE`, then by widening every status-clear
  write from "just the bits this call consumed" to the entire register
  (reasoning: `SD_INT_ERROR` is a summary bit over eleven separate
  detail bits at bits 16-25 that the narrower mask never touched, a
  real and independently-worth-fixing bug — just not *this* bug).
  Neither changed the storm's signature at all.
- Ruled out **PLIC completion sequencing** — tried unconditionally
  completing `IRQ_SDHCI` at the PLIC level even on a spurious (0)
  claim, on the theory this silicon might need it. No change.
- **Found via direct isolation, not another guess:** every test so far
  had changed the PLIC's own enable-bit for source 36 and the SDHCI
  device's own interrupt-enable registers *together*, every time — so
  every failure was equally consistent with either being the cause.
  Split them apart: left the device's `SIGNAL_ENABLE`/`INT_ENABLE`
  writes untouched, but commented out only the PLIC enable-bit write
  for source 36. Result: enumeration completed perfectly end-to-end
  (`CMD0` through `CMD7`, "card ready"), zero storm, zero spurious
  traps. Conclusive: setting this one specific PLIC enable bit alone —
  independent of whether the device it's associated with ever actually
  asserts anything — reliably wedges this exact PLIC into a permanent
  storm. A real, undocumented silicon/PLIC erratum for this source (or
  possibly this whole context), not anything in this driver's own
  logic, and not something any of the three independently-checked
  software sources (DT, OpenSBI, Linux driver) predicted or would
  likely have caught, since none of them exercise every one of this
  chip's 101 interrupt sources in practice.

**Reverted:** `sdd_block_rw` back to busy-polling (`SD_PRESENT_STATE`
for buffer-ready, `SD_INT_STATUS` for transfer-complete) — the exact
design already proven working end-to-end on real hardware before this
attempt. `sdd_wait_for_irq()` removed. The Duo's `plic_init()` keeps
the IRQ_SDHCI enable-bit write in place but commented out, with the
full reasoning, so a future attempt doesn't have to rediscover this
from scratch. `entry.c3`'s `IRQ_SDHCI` trap-handler routing and the new
`board::PLIC_PENDING_BASE`/`PLIC_PENDING_PAGE` infrastructure (added
for this investigation's own diagnostics) are left in place, unused but
ready, in case this gets revisited with real hardware debug tooling
(logic analyzer on the physical IRQ line, or vendor engineering
support) rather than source-reading alone.

**Files changed:** `user/sdd.c3` (trim, revert to polling, wider
status-clear kept as a real independent fix), `boards/duo/board.c3` /
`boards/qemu/board.c3` (`PLIC_PENDING_BASE`/`PAGE`, IRQ_SDHCI enable
commented out), `src/entry.c3` (`IRQ_SDHCI` routing added and kept,
temporary diagnostic prints added and removed), `src/process.c3`
(`PLIC_PENDING_PAGE` mapping).

---

## 2026-08-16 (7) — Real SD-card storage for the Duo: Stage 4, full working round trip

**Continuing straight from this same day's "(6)" entry.** Stages 1-3
(kernel plumbing, `sdd`'s driver skeleton, build wiring) were done and
QEMU-verified; this entry is Stage 4 — real hardware bring-up — which
took roughly a dozen flash/power-cycle round trips and turned up four
real driver bugs, one serious pre-existing kernel bug, and one real
safety hazard, before ending in a genuine, confirmed `writefile`/
`readfile` round trip through `fsd` -> `sdd` -> physical SD card on real
Milk-V Duo hardware.

**The chase, in order:**

1. **Wrong pad drive-strength values.** `sdd_pad_power_clock_init` had
   CLK/CMD/DAT0-3 all at value 2 and PWR_EN at 1 — backwards versus
   `duo-buildroot-sdk/u-boot-2021.10/board/cvitek/cv180x/sdhci_reg.h`'s
   actual `REG_SDIO0_*_PAD_VALUE` constants (only CLK and PWR_EN should
   be 2; everything else is 1). Read from memory instead of the real
   header the first time; fixed by actually reading it.
2. **Clock-divisor field overflow.** The initial ~400kHz enumeration
   clock computed `256 << 8` for the divider field, which needs 9 bits
   and silently overflowed into the adjacent timeout-control byte.
3. **Missing vendor PHY TX/RX delay-line reset.** `cv180x_base.dtsi`'s
   `sd:` node sets `reset_tx_rx_phy`, which `cvi_sdhci_probe()` acts on
   with three extra register writes (`CVI_SDHCI_VENDOR_OFFSET`,
   `CVI_SDHCI_PHY_TX_RX_DLY`, `CVI_SDHCI_PHY_CONFIG`) this driver
   entirely omitted the first time through — ported from general SDHCI
   spec knowledge only, never having actually read the vendor driver.
4. **Self-inflicted clock clobbering.** A real, hard-won piece of
   evidence: raw register readback showed the clock-control field
   already had `INT_STABLE=1` *before* this driver's own software-reset
   attempt — meaning BootROM (which has to read this exact card to load
   FSBL at all, on this SD-boot board) had already left the SDHCI IP
   correctly clocked and running. `SDHCI_SOFTWARE_RESET.RST_ALL` then
   got stuck permanently asserted (confirmed: still asserted after a
   20-million-iteration busy-wait, ruling out "just need a bigger
   timeout" first), and this driver's *subsequent* full-word write to
   set the clock divisor was silently force-clearing that stuck reset
   bit as a side effect — without the hardware's own reset FSM having
   actually finished, plausibly the reason the clock could never
   re-stabilize afterward. Fix: stopped asking for a reset this exact IP
   apparently can't cleanly complete, and stopped clobbering a clock
   config that was already demonstrably working — `sdd_init` now skips
   `SDHCI_SOFTWARE_RESET` and its own clock-divisor reconfiguration
   entirely, just uses BootROM's pre-existing clock. Confirmed via
   readback: `clock_stable` went from 0 to 1 the moment this stopped.

5. **The real root cause, once the clock was confirmed stable and
   commands *still* silently did nothing:** every register this driver
   could inspect looked correct — writes to the SDHCI MMIO block
   genuinely landed and persisted (confirmed with an unambiguous
   `0xDEADBEEF` write/read-back test, and later with a real command word
   reading back exactly as written) — yet `PRESENT_STATE` never moved a
   single bit and `INT_STATUS` never showed one flicker of activity, no
   matter what command was issued. Ruled out, in order: the clock-gate
   register (`REG_CLK_EN_0`, already reading `0xFFFFFFFF` before any
   write of ours — not the blocker), the dedicated SD0 reset line
   (`RST_SD0`, confirmed unused by any boot stage, DT never wires it
   up), `SD_SIGNAL_ENABLE` (added, no effect), UHS/preset-value state
   (misread `HOST_CONTROL2`'s bit layout at first and had to correct
   course — real bits: `PRESET_VAL_ENABLE`=0, `VDD_180`=0, `UHS_MODE_SEL`
   =SDR12; no exotic state active at all), and `SDHCI_POWER_CONTROL`
   (already `0x0F`/bus-power-on, confirmed by readback — this driver had
   already gotten it right, just never verified). **Actual cause:**
   `map_page()` (`src/page.c3`) applies `board::PTE_EXTRA_BITS`
   (T-Head's SHARE|CACHE|BUF memory-attribute encoding — see this same
   day's earlier entries on the Sv39 bring-up) to *every* mapping it
   creates, unconditionally — including genuine device MMIO, not just
   RAM. A cached write to a hardware register can sit in the CPU's own
   cache line and never actually reach the device at all (until that
   line happens to get evicted), and a cached read just as easily
   returns a stale value instead of live device state — exactly
   explaining "writes read back correctly (cache hit) while the actual
   hardware shows zero sign of ever having received them." This is a
   real, pre-existing bug that predates this session — it affected the
   PLIC mapping too, from the very first Duo board-abstraction work —
   just never surfaced before, because nothing had done tight MMIO
   polling against real hardware on this board until `sdd`. **Fix:**
   added `map_device_page()` (`src/page.c3`) alongside `map_page()` —
   identical intermediate-table walk (still needs `PTE_EXTRA_BITS` at
   that level, a genuine table-walker requirement, unrelated to the
   leaf's own memory type), but the leaf entry omits `PTE_EXTRA_BITS`
   entirely, landing at Strong-Order/non-cacheable (`docs/devlog.md`
   already noted in passing, during the original Sv39 hang chase, that
   an all-zero SO/C/B/SH/SEC field reads as exactly that). Switched
   every genuine device-MMIO `map_page()` call site to
   `map_device_page()`: PLIC (`process.c3`, and `entry.c3`'s rfork
   child-table setup), `diskd`'s `VIRTIO_BLK_PADDR` mapping, and all
   four of `sdd`'s new MMIO mappings. Left RAM-backed mappings (kernel
   identity map, user image pages, `diskd`'s DMA vq/req buffers) on
   `map_page()`, unchanged. Full QEMU regression re-verified unchanged
   (`board::PTE_EXTRA_BITS=0` there regardless, so this cache-attribute
   distinction is structurally a no-op on that board — real proof this
   was a Duo-only latent bug, not something QEMU's regression suite
   could ever have caught).

   Once this landed: full enumeration succeeded on the very next boot —
   `CMD0` -> `CMD8` (echoed the check pattern correctly) -> `ACMD41`
   ready after 154 tries, `ocr` showing a high-capacity card -> `CMD2`/
   `CMD3` (RCA assigned) -> `CMD7` SELECT_CARD -> "sdd: card ready".

6. **A real safety hazard, caught before it did any damage.**
   `writefile`/`readfile` both printed nothing on first try — not a bug
   in the new addressing, but two separate things. First,
   `fsd.c3`'s `FS_WRITE` handler only ever *updated* a file already
   present in its in-memory table (built once at boot by tar-parsing the
   disk) — no create path existed at all, so a write to a name never
   seen at boot silently no-op'd. Harmless on QEMU (its `disk.tar`
   always pre-seeds `hello.txt`) but meant nothing could ever be written
   to a genuinely blank disk — exactly what a real SD card is on first
   use. Second, and more serious: `fsd`/`sdd` address the SD card as raw
   sectors starting at absolute LBA 0 — the *same* region as this card's
   actual MBR/partition table (confirmed via `lsblk`/`sfdisk`: the
   `DUOBOOT` FAT partition holding this board's own bootable `fip.bin`
   starts at sector 2048, meaning sector 0 is the live MBR). Had
   `writefile` succeeded before this was caught, `fs_flush()` would have
   overwritten the partition table BootROM needs to find that partition
   at all — data would likely survive physically, but the board would
   probably stop booting until the MBR got manually reconstructed.
   `fsd`'s own write-requires-existing-file limitation had been
   accidentally protecting against this the whole time. Fixed both,
   with the user's explicit sign-off before touching addressing at all
   given the real-hardware stakes: added `DATA_SECTOR_OFFSET=64`
   (`user/sdd.c3`), shifting every logical sector fsd addresses into the
   unused ~1MB gap between the MBR and the first partition, comfortably
   clear of both; and added a real create-on-write path to `fsd.c3`
   (first unused slot in `files[]`, `FS_READ` still correctly fails for
   a name that was never written). Full QEMU regression re-verified
   unchanged (its own disk always has `hello.txt` pre-seeded, so the new
   create path never actually triggers there).

**Result: genuine `writefile`/`readfile` round trip on real Milk-V Duo
hardware**, first time this whole project — `fsd: wrote 2560 bytes to
disk` followed by `readfile` correctly printing back `Hello from
shell!`, matching QEMU's own output exactly. Storage is no longer a
QEMU-only feature.

**Left as diagnostic instrumentation, on purpose, not cleaned up yet:**
`sdd.c3` still prints a fair amount of one-time bring-up state
(`clk_en_0`, the `0xDEADBEEF` write-test, `pll_reg`/`bypass_reg`,
`power_control`, `clock_stable`, `host_control2`) and per-stage
enumeration markers. Genuinely useful if this needs revisiting on a
different physical card (drive-strength/timing margins are real
per-card variables), consistent with this project's established
practice of keeping this class of diagnostic (see `entry.c3`'s
`current_pid` trap-print, kept since the original Sv39 chase) rather
than stripping it the moment things work. A later pass could trim the
noisiest of it once this has proven itself across more than one card
and boot.

**Files changed:** `user/sdd.c3` (all of the above: PHY reset writes,
clock-clobber removal, `DATA_SECTOR_OFFSET`, drive-strength/divisor
fixes, diagnostics), `src/page.c3` (`map_device_page()`, refactored
`walk_to_leaf_table()` shared by both), `src/process.c3` and
`src/entry.c3` (PLIC/`diskd`/`sdd` MMIO mappings switched to
`map_device_page()`), `user/fsd.c3` (create-on-write path).

---

## 2026-08-16 (6) — Real SD-card storage for the Duo: sdd, Stages 1-3 done

**Continuing straight from this same day's "(5)" entry.** With boot fully
proven on real hardware, storage (the one explicitly-deferred gap —
`writefile`/`readfile` correctly refused on the Duo since it has no
virtio-mmio) was next. Plan file:
`~/.claude/plans/wise-wobbling-music.md`.

**Design:** a new, separate userland driver, `user/sdd.c3` — the Duo's
SD controller (`cvitek,cv180x-sd`, MMIO `0x04310000`, PLIC IRQ 36) is a
standard SDHCI-compliant controller (sourced from
`duo-buildroot-sdk/u-boot-2021.10/drivers/mmc/cvitek/sdhci-cv180x.c` and
`arch/riscv/dts/cv180x_base.dtsi`'s `sd:` node — real register values,
not reverse-engineered), structurally unrelated to `diskd.c3`'s
virtio-mmio protocol. PIO, not DMA — SDHCI's buffer-data-port register
lets `sdd` read/write one 32-bit word at a time straight into its own
process image, so unlike `diskd` it needs no kernel-allocated physically
contiguous buffer and no `SYS_DISKD_INFO`-style syscall at all. No PLIC
interrupt handling in v1 either — busy-polling `PRESENT_STATE`/
`INT_STATUS` directly, since SDHCI commands complete in microseconds to
low milliseconds and this sidesteps the sscratch-across-blocking-syscall
hazard `diskd`'s own interrupt wait had to solve.

**`board::HAS_SD_BLOCK`/`HAS_VIRTIO_BLOCK`** (both boards define both,
mutually exclusive today) tell `kernel.c3`'s spawn gate which driver
process + kernel-side mapping helper to use for the block device
`HAS_BLOCK_DEVICE` promises exists. Duo: `HAS_BLOCK_DEVICE` flipped from
`false` to `true`, `HAS_SD_BLOCK=true`. QEMU: unchanged behavior,
`HAS_VIRTIO_BLOCK=true`. Either driver lands in the same third boot
slot (pid 3, right after idle/echod), so `fsd.c3`'s hardcoded
`DISKD_PID=3` needed zero changes — confirmed by reading `fsd.c3` in
full first: it only ever speaks the sector-number/512-byte wire protocol
to whatever answers at that pid, no virtio awareness anywhere in it.

**Kernel-side plumbing** (`src/process.c3`): `setup_sdd_mappings`
mirrors `setup_diskd_mappings` but simpler — no virtqueue/request-buffer
`alloc_pages()` call, since PIO needs none. Maps `board::SD_MMIO_BASE`
(the SDHCI block itself) plus three more separate pages the one-time
pad/power/clock bring-up sequence needs: `SD_TOP_PAGE` (`0x03000000`,
holds `REG_TOP_SD_PWRSW_CTRL`), `SD_PINMUX_PAGE` (`0x03001000`, pad
function-select + drive-strength registers), `SD_CLOCK_PAGE`
(`0x03002000`, the SD PLL divider + clock-bypass-select register) — all
sourced from the same vendor headers as the SDHCI base address itself,
not guessed.

**`user/sdd.c3` itself:** `sdd_init` — pad mux, drive strength, power
switch, PLL clock setup, SDHCI software reset, initial ~400kHz
enumeration clock (spec-required: talk to a freshly powered card slowly
before its real speed is negotiated). Then the standard SD Physical
Layer command sequence (CMD0/CMD8/ACMD41/CMD2/CMD3/CMD9/CMD7, raise
clock to ~25MHz, CMD16) — identical for any SDHCI controller, not
chip-specific. Block read/write: CMD17/CMD24, poll the present-state
ready bit, 128×32-bit words through the buffer port, poll transfer-
complete. Main loop is `diskd.c3`'s shape verbatim (`ipc_recv_type` ->
dispatch -> `ipc_send`), so `fsd` genuinely can't tell the two apart.

**Verified this session:** both `bash scripts/build.sh` (QEMU) and
`bash scripts/build_duo.sh` + `bash scripts/build_duo_fip.sh` (Duo, using
the existing `$DUO_SDK` checkout at
`~/Workspace/duo-buildroot-sdk-build/duo-buildroot-sdk`) build clean —
`sdd.c3` compiles under the same `--use-stdlib=no` user-mode constraints
`diskd.c3`/`fsd.c3` already do. Full QEMU regression
(hello/ping/p9test/nstest/writefile/readfile/rforktest/sandboxtest/
racetest) re-run and confirmed byte-for-byte unchanged from the "(5)"
entry's baseline — `sdd` never spawns there (`HAS_SD_BLOCK=false`), so
this is a real regression check, not just "it still compiles." (Along
the way, discovered the test harness itself — piping `\n`-terminated
commands into QEMU's stdin — was silently no-op'ing every command: the
shell's read loop only ever breaks on `\r`, not `\n`, so bare-`\n` input
just accumulates into one never-terminated line forever. Not a kernel
bug; fixed by feeding `\r`-terminated lines instead.)

**Not yet done — genuinely needs the user's hands (Stage 4):** real
hardware bring-up. Register offsets and the command sequence are a
careful, direct port of sourced values, but none of it has touched real
silicon yet; expect iteration, same as the original Sv39 bring-up.
Verification ladder, cheapest signal first: `sdd_init` completes and
prints without hanging -> `CMD0`/`CMD8` get a response at all ->
enumeration reaches `CMD7`/`SELECT_CARD` -> `writefile`/`readfile`
round-trip correctly through `fsd`, matching QEMU's existing behavior.

**Files changed:** `boards/duo/board.c3` (`SD_MMIO_BASE`, `IRQ_SDHCI`,
`SD_TOP_PAGE`/`SD_PINMUX_PAGE`/`SD_CLOCK_PAGE`, `HAS_BLOCK_DEVICE` ->
`true`, `HAS_SD_BLOCK`/`HAS_VIRTIO_BLOCK`), `boards/qemu/board.c3`
(mirror `HAS_SD_BLOCK`/`HAS_VIRTIO_BLOCK` + dummy SD constants, needed
since `process.c3` references them unconditionally regardless of board),
`src/process.c3` (`sdd_pid`, `setup_sdd_mappings`), `src/kernel.c3`
(spawn gate now picks `sdd` vs `diskd` by board flag), `user/sdd.c3`
(new), `scripts/build_user.sh`/`build.sh`/`build_duo.sh` (build + link
`sdd` alongside the other user binaries on both targets).

---

## 2026-08-16 (5) — Milk-V Duo: full interactive shell, real hardware

**Continuing straight from this same day's "(4)" entry.** Sv39 paging
worked for the first time (the Accessed/Dirty bit fix), but boot still
died with a clean, caught page fault inside `map_page()` right after
"Idle process started" — a second, different bug, `current_pid=0`
(idle).

**Root cause, found by re-deriving the faulting address by hand from
disassembly rather than trusting an earlier, unrelated diagnostic dump's
numbers:** `map_page()`'s own pointer-recovery arithmetic —
`(table2[vpn2] >> 10) * PAGE_SIZE` to get `table1`'s address, same
pattern for `table0` — never masked the result down to Sv39's real
44-bit PPN field. Once `board::PTE_EXTRA_BITS` (bits 60-62, added this
same day's "(3)"/"(4)" entries) started getting set on *every* level,
not just leaves, those extra bits survive the `>>10`/`<<12` round trip
(bit 62 shifts out past bit 63 and is lost, but 60/61 land at 62/63) and
corrupt every intermediate table pointer computed from a parent entry.
QEMU never has this problem (`PTE_EXTRA_BITS=0` there), so full
regression passing there the whole time never caught it. Added
`PPN_MASK = (1UL<<44)-1` and applied it everywhere a table pointer gets
recovered from a stored entry — `page.c3`'s own two sites, plus two more
in `entry.c3` that turned out to duplicate the identical unmasked
pattern: the process-exit page-table free loop, and the `SYS_RFORK`
copy-on-write table-copy loop (`grep`ped the whole tree afterward for
any other `>> 10` occurrences to confirm no fourth copy existed).

**Result: full interactive shell on real Milk-V Duo hardware**, first
time this whole project. `hello`, `ping`, `p9test`, `nstest`,
`rforktest`, `sandboxtest`, `racetest` all pass with output matching
QEMU exactly, module one cosmetic-only exception: `nstest`'s catch-all
resolve prints `pid /` instead of a number, because `server_pid=0`
(`fsd` doesn't exist on this board — `HAS_BLOCK_DEVICE` is false, no
storage driver) is a value QEMU's regression run has literally never
exercised (QEMU always has a real, nonzero `fsd` pid), so whatever
quirk existing print-formatting code has for pid 0 has just never been
seen before. `writefile`/`readfile` still correctly refuse (no block
device on this board at all — an intentional, already-documented scope
cut, not a bug).

**Kept from this session's debugging, on purpose:** `current_pid` in
`entry.c3`'s fatal-trap print (`src/entry.c3`) — genuinely useful,
essentially free, and it's exactly what pinpointed the second bug's
context. Everything else debug-only (the lettered `switch_context`
markers, the CPU-ID SBI query, the nested page-table-walk diagnostic
that itself triggered a cascading fault) stayed reverted from the "(4)"
entry.

**Files changed:** `src/page.c3` (`PPN_MASK`, applied at its own two
pointer-recovery sites), `src/entry.c3` (same mask, two more sites —
exit free loop, rfork COW copy).

---

## 2026-08-16 (4) — First real Sv39 activation on hardware: the Accessed/Dirty bit hang

**Context:** continuing straight from this same day's "(3)" entry —
`build/fip_duo.bin` existed and flashed, but the very first hardware
boot hung completely silently right after "Idle process started",
with no panic, no trap message, nothing. This entry is the full chase:
seven wrong turns and the one real fix, run entirely over a live serial
console with the user physically swapping the SD card between the
reader and the board for every single test.

**First real signal:** page.c3's `map_page()` was panicking
(`"unaligned vaddr"`) on the very first hardware boot — `create_process`
and the rfork COW-copy path both looped `map_page()` from
`__kernel_base` to `__free_ram_end`, and on Duo `__kernel_base` sits 32
bytes past the fiptool `LOADER_2ND` header (`RUNADDR + 32`), not
page-aligned the way QEMU's identical symbol is. Fixed by introducing a
separate `__kernel_map_base` symbol (page-aligned, equal to
`__kernel_base` on QEMU, equal to `RUNADDR` on Duo) — see
`src/kernel.ld`, `boards/duo/kernel.ld`, and the two call sites in
`process.c3`/`entry.c3`. This got the boot past that panic and to "Idle
process started" — then straight into a silent hang with **zero**
further output, not even from the kernel's own direct-SBI console
prints that had worked perfectly up to that exact point.

**Bisection tool: raw SBI-ecall debug markers inside `@naked` asm,
since this predates any working syscall path.** Instrumented
`switch_context` (`process.c3`) with lettered checkpoints (A–E) around
every instruction — stack save, `sfence.vma`, `csrw satp`, `sfence.vma`,
`csrw sscratch`, register restore, `ret` — each one a raw
`li a0,'X'; li a6,0; li a7,1; ecall` sequence (legacy SBI console
putchar), carefully avoiding clobbering registers still needed later in
the function. Also added one to the very top of `user_entry` (before
`sret`). Each round trip: edit → `bash scripts/build.sh` (QEMU
regression) → `bash scripts/build_duo.sh` →
`bash scripts/build_duo_fip.sh` → user flashes `build/fip_duo.bin`,
power-cycles, pastes back the serial log. This bisection was decisive:
**A and B printed every single time; C never did, in any test this
whole session.** C sits right after `csrw satp`. Later, stripping
`switch_context` down to `csrw satp` followed by a bare `nop` before C
still didn't print — the very *next* instruction fetch after enabling
Sv39, regardless of what it is, never completes.

**Seven hypotheses, six wrong:**
1. **PTE attribute bits on leaf entries only** (T-Head C906's MAEE —
   memory-attribute extended encoding, enabled via the M-mode-only
   `mxstatus` CSR that FSBL sets to `0xc0638000` before OpenSBI even
   runs — repurposes Sv39's normally-reserved PTE bits 63:59 as
   SO/C/B/SH/SEC memory-type fields; leaving them zero reads as
   Strong-Order/non-cacheable). Added `board::PTE_EXTRA_BITS`
   (SHARE|CACHE|BUF, bits 60-62, matching this exact SDK's own Linux
   fork's `pgtable-bits.h`/`PAGE_KERNEL`) to leaf PTEs. **No change.**
2. **Same bits on intermediate table-pointer entries too** (leaf-only
   made no observable difference, meaning if this were the mechanism
   the walk would have to be failing before ever reaching the leaf).
   **No change.**
3. **`fence.i`** after the `satp` write, on the theory that real
   hardware can have stale instruction-cache content across a
   translation-mode change that QEMU's emulation never models.
   **No change** — confirmed via disassembly that even a bare `nop`
   immediately after `csrw satp` never executes, regardless of what
   follows it.
4. **Clearing `mxstatus` entirely** from OpenSBI's own M-mode
   `generic_early_init` (`opensbi/platform/generic/platform.c`, patched
   directly in the external SDK checkout) — undoing whatever FSBL
   configured, rather than guessing the right bits to accommodate it.
   Confirmed via disassembly that `csrw mxstatus,a5` (a5=0) really was
   the first thing `generic_early_init` did. **No change.**
5. **The official prebuilt firmware.** The user recalled testing a
   *pre-built* Milk-V release successfully with real Linux in the past
   — not anything built from this SDK checkout. Downloaded
   `milkv-duo-sd-v1.1.4.img.zip` (a URL the user supplied), extracted
   `fip.bin` from its boot partition, and pulled `BL2`/`MONITOR` back
   out of it with fiptool.py's own `read_fip()` (confirming, along the
   way, that this checkout's Kconfig-fixed build already produces
   byte-identical `MONITOR_RUNADDR`/`BLCP_2ND_RUNADDR`/`RUNADDR` values
   to the official release). Repackaged racccoon's kernel as
   `LOADER_2ND` against the *official* BL2+MONITOR. **No change** —
   ruled out a build regression in this checkout as the cause entirely.
6. **Explicit D-cache flush of the page table** before pointing `satp`
   at it, via T-Head's custom `dcache.cipa` instruction (`.long
   0x02b5000b`, the same one `u-boot-2021.10/arch/riscv/cpu/generic/
   cache.c` uses) — on the theory that the MMU table walker reads
   physical memory via a path that doesn't snoop the D-cache, and that
   FSBL's own `flush_dcache_range()` call for the *loaded kernel image*
   (`bl2_opt.c`'s `load_loader_2nd`) doesn't cover page tables built at
   runtime. Verified the raw instruction encoding decoded correctly
   (`rs1=a0`) before ruling it out. **No change.**
7. **A full U-Boot-mediated boot**, instead of racccoon replacing
   U-Boot as `LOADER_2ND` — on the theory that U-Boot's own hardware
   bring-up (DRAM/MMC/Ethernet init, all visible in its own boot log)
   established some prerequisite state Linux implicitly relies on that
   FSBL's minimal init skips. This needed real infrastructure since
   this exact U-Boot build has almost no shell commands compiled in
   (`CONFIG_CMD_GO`, `_BOOTI`, `_ELF`, `_SOURCE`, `_LOADB` all
   `# ... is not set` — only `mmc`/`part`/`fat`/`fs generic`): `go`
   doesn't exist, `bootm` needs `CONFIG_LEGACY_IMAGE_FORMAT` (also
   unset, FIT-only) so a legacy `mkimage -T kernel` uImage was rejected
   outright, and `bootm` itself hard-requires an FDT subimage even
   though the kernel never reads it (blank placeholder DTS compiled
   with `dtc` and added to the FIT) — and the first working FIT attempt
   still needed a non-overlapping staging load address, since loading
   the container at the same address as its own embedded kernel payload
   trips U-Boot's "new format image overwritten" self-protection.
   Ended up with a real, reusable path: `build/racccoon.its`/
   `mkimage -f` → `.itb` → `fatload mmc 0:1 0x80500000 racccoon.itb` →
   `bootm 0x80500000`. Booted clean, full U-Boot init included.
   **Still the exact same hang.** This eliminated *every* environmental/
   firmware-state theory outright — the bug had to be in racccoon's own
   Sv39-enable code, independent of how or by what it gets loaded.

**The real fix: Accessed and Dirty bits.** Diffing the leaf PTE
construction against this exact SDK's own Linux fork's
`arch/riscv/include/asm/pgtable.h` one more time, bit by bit rather than
by shape, turned up `_PAGE_KERNEL`/`PAGE_KERNEL_EXEC` always including
`_PAGE_ACCESSED | _PAGE_DIRTY` (bits 6/7) — which racccoon's `map_page()`
had never set, on any board, ever. Per the RISC-V privileged spec, a
core without hardware auto-setting of the A/D bits (no Svade-equivalent)
is required to fault on any access through a PTE with A=0. This T-Head
C906 apparently doesn't just fault cleanly on that condition the way the
spec's normal page-fault path would suggest — it hard-locks the hart on
the very first instruction fetch through the newly-enabled mapping, no
trap, nothing recoverable. Added `PAGE_A`/`PAGE_D` (page.c3) to every
leaf PTE `map_page()` creates. Tested first against a throwaway 1GB
superpage identity map (bypassing the real ~15,000-entry process page
table entirely, to isolate content/complexity from the actual
mechanism) — **A, B, C, D, E, and the `user_entry` marker all printed,
`sret` into U-mode succeeded, and it cleanly page-faulted at the
deliberately-unmapped `USER_BASE` with a proper trap message.** Sv39
paging works on this hardware, for the first time this whole
investigation.

**Cleaned up for production**: stripped every debug marker/ecall out of
`switch_context`/`user_entry`/`yield`, removed the CPU-ID SBI query
(`sbi_get_mvendorid`/`marchid`/`mimpid` — turned up `mvendorid=0x1`,
`marchid=0x5b7` i.e. `THEAD_VENDOR_ID`, `mimpid=0`; interesting that
this exact SDK's own Linux fork checks `mvendorid` for its T-Head DMA
cache-workaround gate, which would never fire on this exact chip
variant), reverted the `mxstatus`-clear OpenSBI patch (confirmed
unnecessary), and moved `PAGE_A|PAGE_D` into the real `map_page()` leaf
construction. Re-verified: full QEMU regression suite
(hello/ping/p9test/nstest/writefile/readfile/rforktest/sandboxtest/
racetest, all correct) still passes unchanged, and the *original*
direct FSBL→racccoon boot path (no U-Boot detour, our own
`scripts/build_duo_fip.sh`, our own from-source-built OpenSBI/FSBL) —
the actual production target — was rebuilt clean.

**A second, real bug surfaced immediately after:** once Sv39 actually
works, boot now gets past "Idle process started" into a *clean, caught*
page fault (`scause=0xd`, Load Page Fault) inside `map_page()` itself,
`current_pid=0` (idle). A quick nested diagnostic (walking idle's own
page table for the fault address from inside the trap handler) itself
triggered a second fault and a confusing cascading-panic loop — reverted
that back out rather than chase a re-entrant-fault situation blind.
Working theory, not yet confirmed: `create_process()`'s kernel-range
identity-map loop has never been exercised while a page table is
*already active* — every prior board/timing combination happened to
finish creating the shell process while `kernel_main` (which *is* the
idle process's own execution) was still running bare-metal, before its
first `yield()`. Duo's smaller pre-existing process count (`echod` only,
no `diskd`/`fsd` — `HAS_BLOCK_DEVICE` is false) apparently changes when
`shell_running` first goes false relative to `kernel_main`'s own
yield/resume cycle, so this is plausibly the *first ever* time
`create_process()` has run under an already-active satp, on any board,
this entire project. Not yet root-caused.

**Files changed:** `src/kernel.ld`, `boards/duo/kernel.ld` (the
`__kernel_map_base` alignment fix), `src/page.c3` (`PAGE_A`/`PAGE_D`/
`PAGE_G` consts, the actual fix), `boards/duo/board.c3`/
`boards/qemu/board.c3` (`PTE_EXTRA_BITS`), `src/process.c3` (clean
`switch_context`/`user_entry`/`yield`, no debug residue), `src/kernel.c3`
(no debug residue), `src/entry.c3` (`current_pid` added to the fatal-trap
print, kept — genuinely useful, low-risk). Externally, in the
`duo-buildroot-sdk` checkout (not part of this repo): the Kconfig fix
from the "(3)" entry remains; the `mxstatus`-clear OpenSBI patch was
added and then reverted this session.

---

## 2026-08-16 (3) — A real, flashable `fip.bin` — plus two vendor-toolchain bugs that had to die first

**Goal, continuing straight from this same day's "(2)" entry:** actually
build the SDK components racccoon's own `fip.bin` needs (OpenSBI, FSBL)
and package `build/kernel_duo.elf` into a real image. Ended up spending
most of this session on two unrelated toolchain bugs blocking that,
neither of which had anything to do with racccoon's own code.

**Bug 1 — the vendor SDK's top-level Kconfig has drifted ahead of its
own bundled kconfig-frontend.** `u-boot-2021.10/Kconfig`'s `CC_IS_GCC`/
`CC_IS_CLANG` use `def_bool $(success, ...)` — confirmed two separate,
real problems, not host-toolchain skew (reproduced identically against
both the system's own gcc 16.2.1 *and* the vendor's own documented
`milkvtech/milkv-duo` Docker image, gcc 11.4.0/Ubuntu 22.04):
1. `success` wasn't in `scripts/kconfig/preprocess.c`'s function table
   at all (only `shell`, `error-if`, `info`, etc.) — added it (runs the
   command via `popen`, returns "y"/"n" from its exit status, mirroring
   `do_shell`'s plumbing).
2. Even patched in, `$(success, ...)` never actually got invoked when
   used as a `def_bool`'s value — confirmed by instrumenting
   `do_success()` with a debug `fprintf` that never fired. `default
   $(shell, ...)` (used a few lines down for `GCC_VERSION`) *does* get
   invoked. This is a real, narrower gap in this old kconfig-frontend:
   `default`'s value gets macro-expanded, `def_bool`'s doesn't. Not
   worth patching the flex/bison grammar for a vendor build script three
   layers removed from racccoon's own code — instead hardcoded
   `CC_IS_GCC`/`CC_IS_CLANG`/`GCC_VERSION`/`CLANG_VERSION` to the known-
   correct values for racccoon's toolchain (GCC only, cross-compiler is
   `host-tools`' `riscv64-unknown-linux-musl-gcc-10.2.0`).

**Bug 2 — the actual blocker, and much bigger: `host-tools`' entire
cross-toolchain was 0 bytes.** After the Kconfig fix, u-boot's build got
much further, then failed with `cc1: unknown register name: gp` (no
`CROSS_COMPILE`) in manual repros, and separately with silent, no-output,
exit-0 "successes" from `riscv64-unknown-linux-musl-gcc` in the real
recipe — no compiler error, no output file, nothing. `file` on the
binary said `empty`. Checked: **every single binary** in `host-tools/gcc/`
was 0 bytes (17508 of 31578 tracked files) — `git status` inside that
checkout showed tens of thousands of files as locally modified/deleted
relative to its own index. Root cause: that `host-tools` clone was made
in the *previous* (pre-reboot) session directly into `/tmp`, which is
RAM-backed `tmpfs` — this session found it still there post-reboot but
sitting in a tmpfs that was already 6.1GB/7.7GB full (see this same
day's "(2)" entry, which moved the whole checkout to real disk for that
reason). The checkout must have hit ENOSPC or gotten OOM-killed mid-
write, silently leaving thousands of truncated 0-byte files while git's
own object database (already fully received over the network before
checkout started) stayed intact. Fixed with `git checkout HEAD -- .`
inside `host-tools` (re-materializes the working tree from the already-
valid object database — no re-clone needed); confirmed via `file` that
`riscv64-unknown-linux-musl-gcc` is now a real 16MB ELF binary.

**Once both were fixed, the real vendor build (OpenSBI + FSBL + U-Boot,
via `milkvtech/milkv-duo` Docker, `source build/envsetup_milkv.sh
milkv-duo-sd && build_fsbl`) succeeded outright** and produced a real,
complete vendor `fip.bin` (317952 bytes, U-Boot as `LOADER_2ND`) — a
good validation image to flash first and confirm the physical setup
(SD card, UART adapter, board) works at all, independent of any
racccoon code. Its packaged header **independently confirmed two
numbers from this same day's earlier "(2)" entry**, straight from the
real build rather than static reading: `LOADER_2ND`'s `RUNADDR` really
is `0x80200000`, and `BLCP_2ND_RUNADDR` (the top-of-DRAM boundary
reserved for the second C906 core) really is `0x83f40000` — exactly
matching `boards/duo/kernel.ld`'s `__dram_end` computation.

**Packaged racccoon's own image.** `opensbi/build/platform/generic/
firmware/fw_dynamic.bin` (OpenSBI, dynamic mode) and `fsbl/build/
cv1800b_milkv_duo_sd/bl2.bin` (FSBL) from that same build are reusable
as-is — they're generic, not U-Boot-specific. Wrote
`scripts/make_loader2nd.py` (prepends fiptool's 32-byte `LOADER_2ND`
header — `JUMP0`/`MAGIC="BL33"`/`CKSUM`/`SIZE`/`RUNADDR=0x80200000`/
`RESERVED1`/`RESERVED2` — to a raw kernel binary; `CKSUM`/`SIZE` get
recomputed by `fiptool.py` itself, only `MAGIC`/`RUNADDR` need to be
right going in) and `scripts/build_duo_fip.sh` (extracts
`build/kernel_duo.elf`'s raw binary via `llvm-objcopy`, runs the header
script, then invokes `fiptool.py genfip` directly with racccoon's
kernel as `--LOADER_2ND`, the real `--MONITOR`/`--BL2` from the SDK
build, `--BLCP`/`--BLCP_2ND` pointed at FSBL's own `test/empty.bin`
skip-file since racccoon doesn't use the fast-image or second-core
slots, and `--BLCP_2ND_RUNADDR=0` so FSBL's own `if
(!blcp_2nd_runaddr) skip` cleanly no-ops the second core). Ran it end to
end: `build/fip_duo.bin`, 528384 bytes, `RUNADDR=0x80200000` confirmed
in the packaged header. Uncompressed (`--compress` omitted, i.e. plain
`None`) deliberately, for the first hardware attempt — one less moving
part (FSBL's LZMA/LZ4 decompress path) to debug blind without a way to
see real UART output myself if something goes wrong.

**End state:** `DUO_SDK=<path> bash scripts/build_duo_fip.sh` (after
`bash scripts/build_duo.sh`) reproducibly builds a real
`build/fip_duo.bin` from current `master`... er, `riscv64` HEAD.
Not yet tested on real silicon — that's the next step, and needs the
user (flashing an SD card, watching the UART). `boards/duo/kernel.ld`'s
`__loader2nd_runaddr` comment and the plan file should get one more
pass to point at this entry instead of "still needs confirming."

**Files changed this session:** `boards/duo/kernel.ld` (RUNADDR fix,
carried over from the "(2)" entry), `scripts/make_loader2nd.py` (new),
`scripts/build_duo_fip.sh` (new). The Kconfig/preprocess.c/host-tools
fixes all live in the external `duo-buildroot-sdk`/`host-tools`
checkouts, not in this repo.

---

## 2026-08-16 (2) — Real `RUNADDR`, and the actual fiptool/FSBL packaging chain

**Context:** picked back up after a PC reboot. The previous session's
plan (Stage 0.1) assumed the next step was booting the *stock* Milk-V
image first, to validate the physical setup before touching racccoon.
The user corrected that: the actual prior effort was going straight for
packaging **racccoon's own kernel** as the board's payload — a
`duo-buildroot-sdk` checkout already existed at
`/tmp/duo-fsbl-only/duo-buildroot-sdk` (plus a prebuilt toolchain at
`/tmp/duo-fsbl-only/host-tools`) from that attempt, survived the reboot
since `/tmp` wasn't wiped. No fip.bin had been produced yet and no
Docker container was running — nothing was lost, just not yet acted on.

**Resolved the previously-unconfirmed `RUNADDR`.** The prior session's
devlog entry assumed the real board-config header was "generated during
the SDK's own build, not committed." That was wrong — traced it to
`duo-buildroot-sdk/build/boards/cv180x/cv1800b_milkv_duo_sd/memmap.py`,
a real committed Python constants file the SDK's own build reads
(not RTL-generated), with `CONFIG_SYS_TEXT_BASE = DRAM_BASE + 2*SIZE_1M`
— this is where the vendor's own U-Boot runs as the `LOADER_2ND`/"BL33"
payload, i.e. exactly the slot racccoon's kernel replaces. `0x80200000`
(`DRAM_BASE + 2MiB`) is a real, sourced value, not a guess: OpenSBI's
own `MONITOR` slot is only 512KB (ends at `0x80080000`), leaving ~1.5MB
of headroom, and FSBL's own bounds check (`IN_RANGE(runaddr, DRAM_BASE,
DRAM_SIZE)` in `bl2_opt.c`) only requires landing inside the 64MB DRAM
window at all.

**Traced the full packaging chain through the real build scripts**
(`duo-buildroot-sdk/build/scripts/fip_v2.mk`,
`fsbl/make_helpers/fip.mk`, `fsbl/plat/cv180x/fiptool.py`), not just the
FSBL C source read last session:
- OpenSBI is built in **dynamic** firmware mode (`fw_dynamic.bin`),
  *not* `fw_payload.bin` — it does not statically embed the next stage.
  It's loaded into FIP as the `MONITOR` slot.
- `LOADER_2ND` (u-boot-raw.bin, in the vendor build) is a **separate**
  FIP slot, given to `fiptool.py genfip` via `--LOADER_2ND=<path>`.
  Confirmed by reading `add_loader_2nd()`: it requires the input file's
  bytes at offset 0 to already carry the `ldr_2nd_hdr` — `JUMP0`(4) +
  `MAGIC`(4, must literally be `b"BL33"` going in) + `CKSUM`(4) +
  `SIZE`(4) + `RUNADDR`(8) + `RESERVED1`(4) + `RESERVED2`(4) = 32
  bytes, matching `boards/duo/kernel.ld`'s existing 32-byte reservation
  exactly. `CKSUM`/`SIZE` are recomputed by `fiptool.py`'s
  `_update_ldr_2nd_hdr()` — only `MAGIC` and `RUNADDR` need to be
  correct going in. There is deliberately no `--LOADER_2ND_RUNADDR` CLI
  flag; the tool reads `RUNADDR` out of the header we provide, exactly
  as `load_loader_2nd()` in `bl2_opt.c` does at boot
  (`loader_2nd_entry = loader_2nd_header->runaddr + sizeof(header)`).
- No `--BLCP`/`--BLCP_2ND` needed (that's the second C906 core's
  firmware slot, out of scope per the plan).

**Fixed a real bug this surfaced, not just documentation:**
`boards/duo/kernel.ld`'s `__free_ram` reserved a flat `64MB` after the
stack — copied from `src/kernel.ld`'s QEMU version, where it's safe
because QEMU virt is handed far more RAM than it needs. CV1800B only
has 64MB of DDR *total* (`0x80000000`-`0x84000000`), and the kernel
already loads 2MB+ into that window before `__free_ram` even starts —
the flat-64MB copy would have overrun the real DRAM window by
whatever the load offset + image + stack consumed. Fixed to size
`__free_ram_end` against a real `__dram_end` (`DRAM_BASE + 64MB -
768KB`, the last term reserving the same top-of-DRAM region the
vendor's own firmware treats as the second core's, matching
`memmap.py`'s `FREERTOS_SIZE` — racccoon never touches that core, but
there's no reason to depend on RAM that isn't confirmed free).
Verified via `llvm-nm`/`llvm-readelf` post-rebuild:
`__kernel_base = 0x80200020` (= `RUNADDR + 32`, matching the header-skip
math), `__free_ram` spans `0x802fc000`-`0x83f40000`, safely inside the
real window.

**Updated `boards/duo/kernel.ld`**: `__loader2nd_runaddr` is now
`0x80200000` (previously an explicitly-flagged placeholder,
`0x80400000`), with the sourcing above in-line as a comment.
`bash scripts/build_duo.sh` builds clean after the change.

**Not done yet — the actual build:** haven't run `opensbi`/`fsbl-build`
against the real SDK checkout, haven't written the header-prepending
step for `kernel_duo.elf`'s raw binary, haven't run `fiptool.py genfip`
for real, no `fip.bin` exists. That's the next concrete step, pending
the user's go-ahead given it's a real (if scoped-down: just
opensbi+fsbl+u-boot, not the full Buildroot rootfs/Linux kernel) SDK
build.

**Files changed this session:** `boards/duo/kernel.ld`.

---

## 2026-08-16 — Milk-V Duo bring-up, part 1: a `board` abstraction layer

**Goal:** the user has the actual Milk-V Duo board, an SD card, and a
USB-UART adapter in hand now and wants to move past QEMU. Planned this
as its own effort (`~/.claude/plans/giggly-prancing-iverson.md`,
separate from the RV64/Sv39 port's own plan) — real hardware is a
fundamentally different kind of work: I can build/boot/iterate on QEMU
myself in a loop, but I have no way to flash an SD card or watch a
physical UART, so every hardware-touching step needs the user
physically present. This entry covers the software-only first stage,
done autonomously; flashing and first boot are next, and need the user.

**Research, before writing any code:** pulled the real CV1800B/CV1801B
datasheet and cross-referenced two independent bring-up reports rather
than guessing addresses. Confirmed: DDR at `0x80000000` (same base as
QEMU, good), UART0 at `0x04140000` (16550-compatible), PLIC at
`0x70000000` (confirmed from an actual upstream Linux devicetree patch
for `cv1800b.dtsi`, not inferred from a sibling chip), boot chain is
BootROM → FSBL → OpenSBI (S-mode handoff, same shape as QEMU). One
finding corrected an earlier assumption from a secondary source: a
third-party Zephyr bring-up report used fiptool's `BLCP_2ND` payload
slot, but reading the actual FSBL C source
(`fsbl/plat/cv180x/bl2/bl2_opt.c` in `duo-buildroot-sdk`) showed
`load_blcp_2nd()` calls `reset_c906l()` directly — that slot is
explicitly the *second* C906 core's firmware, not what racccoon wants.
The correct slot is `LOADER_2ND` (ATF's standard "BL33" stage — what
OpenSBI jumps to on the *main* core after its own init), which needs a
small synthesizable 32-byte header prepended to the raw kernel binary,
and whose real jump entry is `RUNADDR + 32` (past the header), not
`RUNADDR` itself — traced directly through `load_loader_2nd()`'s
`loader_2nd_entry = loader_2nd_header->runaddr + sizeof(header)`. The
exact safe `RUNADDR` value is still unconfirmed — the real board-config
header (`cvi_board_memmap.h`) is generated during the SDK's own build,
not committed to the repo, so this needs the user's actual build output
to nail down, not more static reading.

**Asked for the design before building it.** Drafted a plan that just
edited `plic.c3`'s constants in place for the Duo — the user rejected
it: "auto mode, but make it with the right abstraction so porting to
other platforms will be easier." Redesigned Stage 1 around a `board`
module contract (data *and* behavior — `plic_init`/`plic_claim`/
`plic_complete`/`console_putchar`/`console_getchar`, not just address
constants, since it's genuinely unconfirmed whether `thead,c900-plic`'s
register layout matches QEMU virt's SiFive-style PLIC closely enough
for a base-address swap alone to be correct) with one implementation
per platform, so a third board later means one new file, not another
pass through `plic.c3`/`process.c3`/`kernel.c3`.

**Implementation:** `boards/qemu/board.c3` and `boards/duo/board.c3` —
new top-level `boards/` directory (not under `src/`) specifically to
use `c3c`'s per-target additive `sources` property cleanly
(`c3c --list-project-properties` confirmed this exists:
`sources`/`sources-override` are real per-target overrides, not just a
global list) rather than needing glob-exclusion syntax. `project.json`
now defines two targets, `racccoon` (existing, QEMU) and `racccoon-duo`
(new), each pulling in only its own board directory on top of the
shared `src/**`. `src/plic.c3` is gone — its logic split into both
`board.c3` files; call sites in `entry.c3`/`process.c3`/`kernel.c3` now
go through `board::` instead of bare `plic_*`/`sbi::__*` calls.
`kernel.c3`'s diskd/fsd spawn is gated on `board::HAS_BLOCK_DEVICE`
(false on Duo — no virtio-mmio equivalent, no storage driver yet;
`fsd_pid` staying 0 already made every later namespace's `"" -> fsd`
mount resolve to nothing, so this fails cleanly, not silently).
`boards/duo/kernel.ld` reserves the 32-byte `LOADER_2ND` header space
ahead of `.text.boot`, with `RUNADDR` written as an explicit,
impossible-to-miss placeholder (`0x80400000`, clearly commented
UNCONFIRMED) pending Stage 0.1's real build output.

**Verification, not just "it compiles":** the QEMU board file is a
straight refactor of already-working code, so rebuilding the `racccoon`
target and rerunning the full manual regression (`hello`, `ping`,
`p9test`, `nstest`, `writefile`/`readfile`, `rforktest`, `sandboxtest`,
`racetest`) doubled as the regression check for the abstraction itself
— identical output to before the refactor, confirming the refactor
didn't silently change QEMU behavior while adding the new platform.
`bash scripts/build_duo.sh` (new) also builds `racccoon-duo` clean;
`llvm-readelf`/`llvm-nm` on the result confirm `__kernel_base`/`boot()`
land exactly at `0x80400020` (`RUNADDR + 32`, matching the header-offset
math above) — can't boot-test this one myself, but the address math
checks out.

**End state:** both targets build clean; QEMU path fully regression-
tested and unchanged. Duo path is real code, not a stub, but genuinely
untested past "the linker is happy" — first real test is Stage 2, once
Stage 0.1 (confirm the physical setup with a stock vendor image) and
0.2 (the real `fiptool`/`RUNADDR` values from an actual SDK build) are
done, which need the user's hands.

**Next up:** Stage 0.1 (user, hardware) — boot the stock `milkv-duo`
image, confirm serial works. Stage 0.2 (mine, once 0.1's SDK checkout
exists) — resolve the real `LOADER_2ND` `RUNADDR` and the exact
`fiptool.py` packaging command. Then Stage 2: first real boot.

**Files changed this session:** `project.json`, `boards/qemu/board.c3`
(new), `boards/duo/board.c3` (new), `boards/duo/kernel.ld` (new),
`scripts/build.sh`, `scripts/build_duo.sh` (new), `src/plic.c3`
(removed), `src/entry.c3`, `src/process.c3`, `src/kernel.c3`.

## 2026-08-15 (12) — RV64/Sv39 port: paging, trap frame, and a real 2GB
code-model wall

**Goal:** the user confirmed via community research that the target
hardware (Milk-V Duo, CV1800B) is RV64-only — no RV32 hardware mode.
Racccoon was RV32/Sv32 throughout. Planned and executed the full port
to RV64/Sv39, scoped to booting and passing the complete existing
regression suite under `qemu-system-riscv64 -machine virt` (real
hardware bring-up is a separate, later effort — different boot chain,
needs the physical board). Done autonomously on the `riscv64` branch
while the user was away; see `~/.claude/plans/giggly-prancing-iverson.md`
for the staged plan this followed.

**Sv32 → Sv39 is a structural change, not a width bump.** Sv32 is
2-level (10/10/12-bit split, 4-byte PTEs); Sv39 is 3-level (9/9/9/12,
8-byte PTEs). The PTE flag bits (V/R/W/X/U, bits 0-4) are identical
between the two — only the PPN field width and per-table entry count
differ — which meant `page.c3`'s `map_page()` could gain a third level
without changing its actual encoding formula. `satp`'s MODE field is a
real encoding change though: Sv32 used a single bit at position 31;
Sv39 needs `8ul << 60` in a 64-bit register.

**Every hand-written asm block needed the same mechanical rewrite:**
`sw`/`lw` → `sd`/`ld`, every `4 * N` stack offset → `8 * N`. Hit in
`switch_context`/`fork_entry`/`user_entry` (`process.c3`), the main trap
vector `kernel_entry` and `Trap_frame`'s 31 fields (`entry.c3`),
`threadcreate` (`user/user.c3`), and `rforkmemtest`'s inline ecall block
(`user/shell.c3`). A second, easy-to-miss RV64-specific bug living in
the same code: `SCAUSE_INTERRUPT_BIT` was `0x80000000` (bit 31, correct
for RV32) — on RV64 the interrupt/exception bit is bit 63 of a 64-bit
register. Wrong would have meant every interrupt silently misclassified
as an exception (or vice versa) — fixed to `1ul << 63` before ever
booting, not found by trial and error.

**c3c's own type checker did most of the "which `uint`s are secretly
addresses" audit for free.** Building against `--target elf-riscv64`
turns every `(uint)pointer` or `(pointer)uint` cast that used to be
silently lossless on RV32 into a hard compile error ("uint is smaller
than a pointer, use (uint)(iptr) if you want this lossy cast"). Worked
through `allocation.c3`, `page.c3`, `process.c3`, `plic.c3`, `kernel.c3`,
`entry.c3`, and every `user/*.c3` file this way — fix what the compiler
flags, rebuild, repeat — rather than trying to manually grep for every
address-shaped `uint` ahead of time.

**A second, less obvious category of RV64 break: block-form inline asm
register binding requires native register width.** `sbi_call`'s params
were `int`; on RV64 that's rejected outright ("'int' is not supported in
this position, convert it to a valid type, like 'long'") because a
32-bit local can't bind into a 64-bit register position in c3c's
`asm { mv $a0, arg0; }` block form. Same restriction hit `user.c3`'s
`syscall`/`syscall4` (widened to `long` throughout — which conveniently
also fixed every pointer-argument truncation in the same pass, since a
`long` argument is exactly pointer-width) and `diskd.c3`'s MMIO helpers
(widened to `uptr`/`ulong`). `diskd_info`'s out-pointers also had a real
latent corruption bug once this pattern is understood: the kernel writes
a full 8-byte `uptr` into them now, but `user.c3`/`diskd.c3` were still
declaring the receiving locals as 4-byte `uint` — an 8-byte kernel-side
store into a 4-byte user-side stack slot. Fixed by widening the
out-pointers to `uptr*` on both sides.

**`lwu` doesn't exist in c3c's block-form asm instruction set** ("Unknown
instruction for the current target") — `diskd.c3`'s `mmio_read64` needed
a zero-extending 32-bit load (combining two register halves into one
unsigned 64-bit value), but `lw` sign-extends on RV64. Worked around by
keeping `lw` and masking each half with `& 0xffffffff` before combining
— `mmio_read32` didn't need this at all, since its `(uint)` truncation
back down to 32 bits discards the sign-extended upper bits regardless of
how they got there.

**No riscv64 soft-float builtins anywhere on this machine, and no root
to install a cross toolchain that ships them.** `bash scripts/build.sh`
first failed at link time with ~20 undefined symbols (`__adddf3`,
`__floatsidf`, `__gtdf2`, ...) — LLVM lowers every float/double operation
to a compiler-rt runtime call on `rvimac` (no F/D extension), and
`std::io`'s generic printf formatter has a float-formatting path compiled
in unconditionally, reachable in principle from `vprintf`'s runtime
format-specifier dispatch even though this kernel's own `io::printfn`
calls (all `%s`/`%d`/`%x`) never actually take it. `--gc-sections`
couldn't drop it either — the reachability is real (a runtime dispatch,
not dead code), just never *taken*. Wrote
`src/kernel/softfloat_stubs.c3`: ~20 tiny functions, each exporting one
missing symbol name and panicking with that name if ever actually
called. If a future change starts passing a float to `io::printfn`, this
turns a silent miscompute into a loud, immediate, self-identifying
panic instead.

**The big one: c3c has no `--mcmodel` flag, and RV64's default code
model can't address this kernel's own load address.** Once the
undefined-symbol errors were gone, linking failed differently —
`R_RISCV_HI20 out of range: 524811 is not in [-524288, 524287]` — from
`compiler_rt.o`'s internal constant pools at first, then (once
`--gc-sections` was tried) from this kernel's *own* code too, including
trivial functions just referencing a string literal. Root cause, worked
out from first principles since c3c has no flag to ask about this
directly: RISC-V's default "medlow" code model materializes every
absolute address via a 2-instruction `lui`+`addi` sequence that only
works for addresses fitting a **signed 32-bit range** — i.e. below 2GiB.
This kernel boots at `0x80200000` (OpenSBI's fixed RV64 payload address,
confirmed via QEMU's own boot log: `Domain0 Next Address: 0x80200000`)
— just past that line. Under RV32 the exact same address was fine,
because RV32 has no signedness ambiguity to begin with (the whole
address space *is* 32 bits). Every real RV64 kernel (Linux, OpenSBI
itself) sidesteps this with `-mcmodel=medany` (PC-relative `auipc`-based
addressing, valid across the full 64-bit space) — but c3c doesn't expose
that flag, and `--reloc=pic` (the one adjacent flag it does have) turned
out to change TLS codegen to a model needing a runtime `__tls_get_addr`
call this freestanding kernel has no dynamic linker to provide.

The actual fix uses `--emit-llvm` as an escape hatch: let c3c emit its
own LLVM IR (still architecture-generic, no code-model baked in — verified
by grepping for `Code Model` module flags, which weren't there), then
recompile every `.ll` file directly with `llc -code-model=medium
-relocation-model=static` (LLVM's name for RV64 "medany") before handing
the resulting `.o` files to `ld.lld` for the real link. Confirmed via
`llvm-readobj -r` that this actually changes the emitted relocation type
from `R_RISCV_HI20` (absolute) to `R_RISCV_PCREL_HI20` (auipc-based).
`scripts/build.sh` now runs this two-stage pipeline instead of a single
`c3c build`.

**One genuinely new bug this surfaced, not a porting mechanical fix:**
even after the code-model fix, `kernel.c3`'s `(uint)&_binary_X_bin_size`
idiom (the classic objcopy trick — the symbol's "address" *is* the
byte count, never actually dereferenced) still overflowed the same
`R_RISCV_PCREL_HI20` range check, because it's fundamentally
incompatible with *any* PC-relative addressing scheme: the "address" is
a small integer with no real relationship to the code referencing it,
so the computed PC-relative delta is nonsense (real kernel PC minus a
tiny fake value ≈ the full 2GB delta, landing right at the edge of what
a signed 32-bit delta can hold). Fixed properly rather than worked
around: objcopy also emits a real `_binary_X_bin_end` symbol (an actual
address, right after `_binary_X_bin_start`'s real data) — switched to
computing the size as `(uptr)&_binary_X_bin_end - (uptr)&_binary_X_bin_start`,
two genuine nearby addresses, no fake symbol involved.

**A real, pre-existing bug this port happened to expose:**
`user/diskd.c3`'s `diskd_panic` ended in a bare `for (;;) {}` — an empty
infinite loop with no side effects, which is UB under C/LLVM's rules and
a real optimizer target, not just theoretical. Under `-O2` this
apparently got eliminated on RV64, falling straight through back into
`diskd_init()`'s caller with diskd half-initialized instead of actually
halting — the visible symptom was "diskd: invalid device id" printed
dozens of times (from a supposedly-single-shot panic) followed by an
illegal-instruction crash. This bug likely existed on RV32 too but was
never exercised there, since RV32 QEMU's virtio-blk device apparently
never failed diskd's init checks. Fixed by replacing the loop with
`exit()` — genuinely fatal, and immune to the same class of elimination
since it's a real syscall.

**Full manual regression, all green, first try after the fixes above:**
`hello`, `ping`, `p9test`, `nstest`, `writefile`/`readfile` (through
fsd/diskd/virtio-blk), `rforktest`, `rforkmemtest`, `sandboxtest`,
`threadtest`/`threadjointest` (with real generation-counter joins),
`racetest` (concurrent IPC rendezvous) — every one produced identical
output to the RV32 baseline. `scripts/stress_test.sh` (adapted to
`qemu-system-riscv64`, 15 runs/scenario) confirmed the interrupt-driven
disk I/O path — the most timing-sensitive part of this kernel, and the
one most likely to hide a subtle Sv39/PLIC regression — is still solid.

**End state:** `bash scripts/build.sh` builds clean end-to-end (two-stage
`c3c`+`llc` pipeline). `build/kernel.elf` boots under
`qemu-system-riscv64 -machine virt -bios default` (`scripts/launch64.sh`)
through the complete existing feature set with no regressions. RV32
support is not preserved — `project.json`/`build.sh`/`build_user.sh` now
target `elf-riscv64` exclusively, matching the target hardware.

**Explicitly out of scope, not started:** real Milk-V Duo hardware
bring-up — different boot chain (FSBL, not a direct `-kernel` load),
needs the physical board, and the CV1800B's PLIC reportedly has only 8
priority levels at addresses that need confirming against real chip
documentation rather than assumed from QEMU's virt board.

**Files changed this session:** `project.json`, `scripts/build.sh`,
`scripts/build_user.sh`, `scripts/launch64.sh` (new),
`scripts/stress_test.sh`, `src/kernel.c3`, `src/kernel/sbi.c3`,
`src/kernel/softfloat_stubs.c3` (new), `src/allocation.c3`, `src/page.c3`,
`src/process.c3`, `src/plic.c3`, `src/entry.c3`, `user/user.c3`,
`user/diskd.c3`, `user/shell.c3`.

## 2026-08-15 (11) — IPC hardened into a true rendezvous, and proof the
old race was real

**Goal:** IPC's single-slot inbox always carried a documented but
*unenforced* assumption — "sender never blocks, safe only if callers
keep to one outstanding request at a time." That was true by accident
for most of this project's history (nothing sent concurrently). It
stopped being accidental the moment `rfork`/`threadcreate` made genuine
concurrent senders possible — two threads sharing memory can now
legitimately both want to message the same server at once. Hardened
`SYS_IPC_SEND`/`RECV`/`POLL` (`src/entry.c3`) into a real two-sided
rendezvous, the standard fix for exactly this class of problem.

**Highest blast radius of anything changed this session** — every
existing feature goes through this code path (echod, diskd, fsd, ping,
p9test, sandboxing) — so this got the most scrutiny of any change so
far, including something the earlier entries didn't do: proving the bug
being fixed was real, not just plausible.

**The mechanism, no new low-level plumbing needed:** `Process` gained
one field, `msg_acked` (`src/process.c3`). `SYS_IPC_SEND` now does two
things the old version didn't — waits (busy-poll, like `SYS_GETCHAR`)
for the target's inbox to actually be empty before depositing anything,
so a second sender can never silently overwrite a message the receiver
hasn't consumed yet; and, after depositing, blocks (`PROC_BLOCKED`,
genuinely woken this time) until the receiver has actually consumed
*this* specific message. `SYS_IPC_RECV`/`POLL` both now explicitly wake
the specific sender (via `msg_from`) on consume, mirroring exactly how
`SYS_IPC_SEND` already woke a blocked receiver — the missing symmetric
half. Deliberately *not* a queue: still one slot, just genuinely safe to
treat as one now that the protocol guarantees at most one message is
ever in flight to a given target.

**Proved the fix actually fixes something, not just "seems safer."**
Built `racetest` (`user/shell.c3`): two `threadcreate`'d threads — true
shared-memory concurrency, not just interleaved processes — both message
echod at once with distinct, checkable payloads (`"AAAA"` / `"BBBB"`),
each verifying its *own* reply matches what it sent. Before trusting the
fix, temporarily reverted just the two new wait loops in `SYS_IPC_SEND`
and reran `racetest` 20 times: **20/20 failures** — every single run
hung indefinitely (a thread's message got silently overwritten by the
other's before echod ever saw it, so it waited forever for a reply that
would never arrive — not a wrong value, a permanent hang, exactly matching
what the design analysis predicted). Restored the fix, reran the exact
same test: 20/20 clean. This is the first entry in this project's history
to run a change's own regression test *against the deliberately-broken
prior version* to confirm the test has real discriminating power, rather
than trusting that a passing test means what it's supposed to mean.

**A documented, accepted new tradeoff:** true synchronous rendezvous
trades "silent data race" for "deadlock if two processes ever try to
send to each other simultaneously without either being ready to
receive." Every existing client/server pair in this codebase follows a
strict request-then-reply discipline (nobody sends to something that
will never `recv`, nothing does bidirectional simultaneous sending) so
this doesn't bite today — worth naming as a real, not hypothetical,
constraint on future protocol design rather than pretending the tradeoff
doesn't exist.

**Verified:** 20/20 `racetest` runs with the fix (after confirming
20/20 *failures* without it), full regression across every feature built
this session and prior phases in one boot, and `scripts/stress_test.sh
15` on both existing scenarios (which exercise diskd/fsd's own IPC under
the new rendezvous too) — all clean.

**Files changed:** `src/process.c3`, `src/entry.c3`, `user/shell.c3`.

---

## 2026-08-15 (10) — Generation counters: closing `join`'s pid-reuse race

**Goal:** close the race the previous entry's `join` deliberately
documented rather than fixed — pids are slot-indexed
(`pid = slot index + 1`) and get reused the moment a slot frees up, so a
`join(pid)` outstanding when that exact pid gets recycled to an
unrelated process would wait for the wrong thing. Not a crash risk (the
original target is genuinely, fully gone the moment it exits — `join`
could never falsely report success), just a real liveness gap: waiting
for the wrong process to disappear instead of the right one.

**The standard fix for recycled small integer IDs:** a generation
counter per slot, bumped every time the slot is reused, that never
resets. `Process.generation` (`src/process.c3`), incremented alongside
`pid` in both `create_process` and `SYS_RFORK`'s child-creation path.
`rfork()` and `threadcreate()` both gained an optional `generation_out`
out-pointer (same "null means don't care" convention as
`SYS_IPC_RECV`'s `type_out`) so a caller that intends to `join()` later
can capture it; `join(pid, generation)` now breaks its poll loop on
*either* condition — slot empty, or the slot's current generation no
longer matches what the caller captured, meaning it's since been reused
by something else entirely. Two states now correctly read as "my target
is gone": actually empty, or reused (in which case the wrong occupant
being alive doesn't matter — the check never looks at *who's* there now,
just whether it's still the same instance).

**The ripple, and the one place it required real care:**
`threadcreate` (`user/user.c3`) is hand-written `@naked` asm — adding a
4th parameter meant it now arrives in `a3`, the exact register the
function was about to overwrite with the `SYS_RFORK` syscall number a
few instructions later. Threaded through `s4` alongside the existing
`s1`-`s3` (`func`/`arg`/`stack_top`), saved and restored around the
`ecall` in the parent path same as the others. Disassembled the rebuilt
`shell.elf` before trusting it — `s4`'s save/restore and the `mv a1, s4`
right before the `ecall` matched the design exactly, same discipline as
the original `threadcreate` build.

One easy-to-miss spot: `rforkmemtest`'s existing inline-asm `ecall`
(hand-written to avoid the shared-stack hazard two entries back) didn't
set `a1` at all before this change — meaning it would have carried
whatever garbage was already sitting in that register into the kernel's
new `SYS_RFORK` handler, which now unconditionally reads `f.a1` as a
pointer to maybe-write through. Caught by inspection while updating call
sites, not by a crash — fixed by explicitly loading `0` (null) into it,
same as every other call site that doesn't intend to join.

**Verified:** 25/25 stress runs of `threadjointest` (3 joins per boot,
75 total, exercising the new generation check on every single one), full
regression across every feature built this session, and
`scripts/stress_test.sh 15` on both existing scenarios — all clean.

**Files changed:** `src/process.c3`, `src/entry.c3`, `user/user.c3`,
`user/shell.c3`.

---

## 2026-08-15 (9) — `join`

**Goal:** replace the awkward "call `ping` a few times and hope the
background process has run by now" pattern this session's own testing
kept reaching for with an actual, correct wait — `join(pid)`, completing
the standard `fork`/`thread`/**`join`** vocabulary on top of `rfork` and
`threadcreate`.

**Much lower-risk than the last two entries, deliberately.** No new
kernel state, no new asm, no new resume mechanism — `SYS_JOIN`
(`src/entry.c3`) is a plain polling loop: check `proc_by_pid(pid) ==
null`, `yield()`, recheck. Exactly the shape `SYS_GETCHAR`'s own retry
loop already has, reusing `proc_by_pid` exactly as it already stands.

**One real bug caught before it shipped, this time by re-reading the
code rather than by stress testing** — a nice change of pace. The first
draft set `current_proc.state = PROC_BLOCKED` before yielding, mirroring
`SYS_IPC_RECV`'s pattern. But `PROC_BLOCKED` only ever gets cleared by
something *else* explicitly flipping it back — `SYS_IPC_SEND` does that
for a receiver. Nothing does that for a joiner: `SYS_EXIT` only ever
touches its *own* process's state, never anyone waiting on it. Setting
`PROC_BLOCKED` here would have made the joiner permanently
unschedulable the instant it was set, even after the joined process
actually exited — `yield()`'s scan only ever matches
`PROC_RUNNABLE`. Fixed by staying `PROC_RUNNABLE` throughout and just
re-yielding, matching `SYS_GETCHAR`'s proven "busy-poll via cooperative
yielding" shape instead of the IPC inbox's "block until explicitly
woken" shape — the right template depends on whether anything is going
to do the waking, and here nothing was.

**A documented, accepted simplification, not a fix:** pids are slot-
indexed and do get reused once a process exits and something new is
created in that slot. If a joined pid gets recycled to an unrelated
process before `join` notices, it can't tell the difference — the same
wart Unix had before zombie/reap semantics. Not a real risk for how this
codebase actually uses `join` today (always joining something the same
caller just created, nothing else racing to create processes
independently), but worth a comment rather than silently assuming it
away.

**`threadjointest`** (`user/shell.c3`): `threadcreate` a thread, `join`
it, read `thread_result` immediately after — no more separate
`threadtest`/`threadresult`-with-a-`ping`-in-between dance. The read
right after `join()` returns is guaranteed current, not a guess.

**Verified:** 20/20 stress runs, 3 `threadjointest` calls per boot (60
total joins), full regression across every feature built this session,
and `scripts/stress_test.sh 15` on both existing scenarios — all clean.
The self-join rejection (`join_pid == current_proc.pid`) is a one-line
guard verified by reading, not by a dedicated runtime test — there's no
`getpid()` in this codebase to let a shell command name its own pid to
try it against, and adding one solely to exercise a guard clause this
simple wasn't worth it.

**Files changed:** `src/entry.c3`, `user/user.c3`, `user/shell.c3`.

---

## 2026-08-15 (8) — `threadcreate`, and a real crash `rforkmemtest` was
hiding

**Goal:** make `RFMEM` (previous `rfork` entry) actually safe to use,
not just demonstrable — `threadcreate(fn, arg, stack_top)`, a userland
trampoline built on top of `rfork(RFPROC|RFMEM)`, matching how real
Plan 9 code gets thread-like behavior (`libthread`'s own `threadcreate`,
built the same way, for the same reason). Full design and the "why not
just have the kernel swap the child's stack" analysis in the plan file.

**Why a kernel-side fix doesn't work:** `rfork()`/`syscall()`
(`user/user.c3`) are ordinary non-leaf functions — at typical
optimization levels, their own prologues spill their own return
addresses onto the stack before making the next call, and their
epilogues reload those relative to `sp` *as it was at their own entry*.
Silently handing the child a different `sp` in its trap frame breaks
that outright: the child would be "returning through" frames whose
saved state lives on a stack it no longer has. Real thread primitives
(Linux `clone`, pthreads) sidestep this by never letting the child
return through the creating call's frame at all — it starts fresh, at a
new function, on a new stack. `threadcreate` does the same, by hand:

```c3
// user/user.c3 — @naked, string-form asm, no block-form binding
addi sp, sp, -16
sw s1, 0(sp); sw s2, 4(sp); sw s3, 8(sp); sw ra, 12(sp)
mv s1, a0; mv s2, a1; mv s3, a2       # fn, arg, stack_top
li a0, 3; li a3, 11                   # RFPROC|RFMEM, SYS_RFORK
ecall
bnez a0, 1f
mv sp, s3; mv a0, s2; jalr s1; j .    # child: switch stack, call fn(arg)
1: lw s1,0(sp); lw s2,4(sp); lw s3,8(sp); lw ra,12(sp); addi sp,sp,16; ret
```

The property that actually closes the hazard (not just narrows it, like
last entry's `rforkmemtest` fix did): from the `ecall` through the
branch and the stack switch, nothing touches memory at all — `a0` (the
branch test) and `s1`-`s3` (`fn`/`arg`/`stack_top`) are registers, and
the kernel's own trap-frame save/restore (`fork_entry`, unchanged since
the last entry) already guarantees those survive. By the time the child
would otherwise need to read anything through `sp`, `sp` already points
at its own private buffer, for the rest of its life, not just the resume
instant. This is also the first hand-written asm in this codebase with a
conditional branch and local labels — every prior naked function
(`switch_context`, `user_entry`, `fork_entry`, `kernel_entry`) is
straight-line. Disassembled `shell.elf` before trusting it at runtime;
every instruction matched the intended design exactly, labels included.

**A real crash, found while stress-testing something else.** While
retesting the previous entry's `rforkmemtest` under slightly different
timing (`rforktest` → `ping` → `rforkmemtest` → `ping`, instead of the
original sequence), the kernel paged-faulted:
`unexpected trap scause=c, stval=2, sepc=2` — an instruction fetch at
address `0x2`, a jump into garbage. Root cause: the *previous* fix for
`rforkmemtest` only protected the child's initial resume instant (by
inlining the `ecall` and branch into `main()`'s own frame). It did
nothing for what the child does *afterward* — and that version's child
still called `print()`, `putchar()`, and `exit()`, every one of them a
real function call spilling its own return address onto the *same,
still-shared* stack the parent kept using. Earlier testing happened to
never disturb that memory in time; this run's extra `ping` (which
genuinely blocks on IPC, forcing more scheduling activity) did. This
wasn't a new bug so much as the previous fix being necessary but not
sufficient — RFMEM's hazard covers the child's *entire* lifetime on the
shared stack, not just the moment it wakes up. Fixed by extending the
exact same "touch nothing but registers" discipline to the whole child
path: it now does a single global assignment (no call, no stack) and
exits via a second raw inline `ecall`, never calling `rfork()`,
`syscall()`, `print()`, `putchar()`, or `exit()` at all. A new
`rforkmemresult` command (mirroring `threadresult`) checks the result
from a safe, later point instead of the child printing anything itself.

**A minor, related lesson about testing this kind of thing with piped
input:** an early attempt to verify `threadresult` right after several
`hello` commands was flaky (~65% pass) for a boring reason — piped input
arrives fast enough that `getchar()`'s retry loop rarely actually blocks,
so `yield()` rarely runs during ordinary command processing, and the
background thread doesn't get a turn. Checking after `exit()` instead
was *worse* (0%): `exit()` respawns the shell as a completely fresh
process with its own independent memory, so it was reading a different
process's un-shared `thread_result`. What actually works reliably:
checking after a command that *genuinely* blocks on IPC (`ping`, which
waits for echod's reply) — a real, guaranteed yield, from the same
process that holds the shared memory. None of this reflects on
`threadcreate`'s or `rfork`'s own correctness — every one of these
attempts showed the mechanism itself working every single time; only the
*test's* ability to observe it reliably was in question.

**Verified:** `threadtest`/`threadresult` — 20/20 clean (using the
`ping`-based check). The exact `rforkmemtest` sequence that crashed —
25/25 clean after the fix. Full regression across every feature built
this session, `scripts/stress_test.sh 15` on both existing scenarios —
all clean.

**Files changed:** `user/user.c3`, `user/shell.c3`.

---

## 2026-08-15 (7) — Namespace unmount + a real sandboxed-child demo

**Goal:** give the namespace mechanism (phase 3) and `rfork` (previous
entry) an actual payoff together — a process that can restrict its own
view of the world after forking, proving the whole point of building
per-process namespaces as real per-`Process` state instead of a shared
global three sessions ago.

**What was added:** `SYS_NS_UNMOUNT` (`src/entry.c3`) — removes one of
the *caller's own* namespace mounts by exact prefix match (`str_eq`,
brought back from the deleted `src/fs.c3` alongside `str_starts_with`,
which already made that trip when this file was removed). Deliberately
a different match rule from `SYS_NS_RESOLVE`'s longest-prefix logic:
unmounting targets one specific entry by its own key, not "whichever
mount a path would currently resolve to." `user/user.c3` gets a trivial
`ns_unmount(prefix)` wrapper. `user/shell.c3`'s new `sandboxtest`:
`rfork(RFPROC)` a child (plain copy — deliberately *not* `RFMEM`, so
none of the previous entry's shared-stack hazard applies here at all),
the child immediately calls `ns_unmount("")` to drop its own fsd mount,
then demonstrates both sides: `fs_read("hello.txt")` now fails
(`ns_resolve` finds nothing, since the `""` catch-all is gone from *this
process's own copy* of the namespace), while `ipc_send`/`ipc_recv` to
echod still works fine — the raw IPC primitive was never namespace-gated
to begin with, so this also incidentally demonstrates that a "sandbox"
built purely on namespace restriction only restricts what the namespace
actually gates.

Because the child's namespace is a fresh **copy**, not a reference, made
at fork time (`SYS_RFORK`'s existing per-`Mount` copy loop, unchanged),
unmounting in the child has zero effect on the parent or any sibling —
verified explicitly (`readfile` still works in the parent after
`sandboxtest` runs).

**Verified:** 15/15 stress runs (`sandboxtest`, checking for both the
denial and the still-working ping, no crashes), full regression across
every feature built so far in one boot, and `scripts/stress_test.sh 15`
on both existing scenarios — all clean.

**Files changed:** `src/entry.c3`, `src/process.c3`, `user/user.c3`,
`user/shell.c3`.

---

## 2026-08-15 (6) — `rfork`: one process-creation primitive, no
process/thread split

**Goal:** with the microkernel roadmap complete, close the gap the
architecture guide's own "What's next" flagged — every process gets an
identical default namespace today because nothing yet creates a process
with a *different* one. Build something in the spirit of Plan 9's
`rfork(2)`: a single syscall, controlled by flags, that produces either
an independent child (`fork`) or one sharing the caller's address space
(a "thread") — the same call, a flag apart, so there's never a separate
thread-creation API to maintain alongside process creation. Scoped to
exactly two flags — `RFPROC` (required) and `RFMEM` (share memory
instead of copying it) — since racccoon has no fd table, note groups, or
env groups for the rest of Plan 9's real flag set to attach to. Full
design in the (still-present) plan file at
`.claude/plans/giggly-prancing-iverson.md`.

**Why this was harder than anything since the trap-frame work itself:**
every process before this was created by `create_process()`, which
always starts a *fresh* image at a fixed entry point. `rfork`'s child has
to resume *mid-syscall*, at the exact point the parent called it, with
different register state (`a0 = 0`) but otherwise identical context —
something this kernel had never done. Solved by copying the parent's own
31-word `Trap_frame` (live on its kernel stack inside `handle_syscall`)
into a 32-word block (31 GPRs + a separately-saved `sepc`, since `sepc`
is a single CPU CSR with nothing else to inherit it from) on the child's
own fresh kernel stack, and giving it a new naked entry point,
`fork_entry()` (`src/process.c3`) — deliberately a *separate* function
from `kernel_entry`'s own restore tail, not a refactor to share it, to
keep zero risk to the one function this project's history says never to
touch casually.

**Memory: full copy for `RFPROC` alone, literal page-table-pointer
aliasing for `RFMEM`.** The copy path reuses `SYS_EXIT`'s own page-table
walk shape (walk table1 → table0 → leaf) verbatim, copying instead of
freeing. The share path is one line — `child.page_table =
current_proc.page_table` — true sharing, not a second mapping of the
same pages. That reintroduced a real hazard `SYS_EXIT`'s teardown wasn't
built for: two `Process` structs can now point at the *same* table, and
the first one to exit must not free memory the other is still running
on. Fixed with a linear `PROCS_MAX`-sized scan before the free loop
(any other live process sharing this exact pointer? skip freeing
entirely) — no new field, since `page_table` pointers are never aliased
any other way.

**A real bug, found the same way the last two were — stress testing, not
inspection.** `rforktest` (plain `RFPROC`) worked first try, reliably.
`rforkmemtest` (`RFPROC|RFMEM`) silently never printed anything from the
child — no crash, no hang of the whole system (the shell kept responding
to other commands), just... nothing from that one process, forever.
Diagnostic prints (temporarily, in `yield()` and `handle_syscall`)
showed the scheduler *repeatedly* selecting and switching to the child —
but the child never made a single syscall of its own, meaning it never
even reached its first `print()` call. Root cause, worked out by hand-
tracing the exact stack addresses involved: `RFMEM` shares the *live
user stack* too, not just the address space in the abstract. The child's
saved resume point sits mid-call, inside `rfork()`'s and `syscall()`'s
own stack frames — and at typical optimization levels those wrapper
functions' own return addresses get spilled onto that same, now-shared
stack. The parent's very next function call (its own `print()`,
happening before the child is ever scheduled, since scheduling is
cooperative) overwrites exactly that memory. When the child finally
resumes, unwinding back out through those frames jumps into whatever the
parent left behind instead. This is not a bug in `rfork` — `rforktest`
proves the core mechanism (register/PC save-restore, memory sharing at
the page-table level) is correct — it's `RFMEM`'s documented behavior
matching real Plan 9 exactly: raw `rfork(RFMEM)` was never meant to be
used bare, only under a threading library that gives the child its own
stack before doing anything else. Fixed `rforkmemtest` itself, not
`rfork`, by inlining its ecall directly in `main()`'s own frame instead
of going through the `rfork()`/`syscall()` wrappers — no function-call
boundary for the child to unwind back through, so nothing spills to the
at-risk stack region in the first place. This sidesteps the hazard for
*this one command*; it doesn't make general `RFMEM` use safe, and isn't
meant to — that's exactly the seam a future stack-aware wrapper would
fill.

**Verified:** `rforktest` and `rforkmemtest` both reliable — 20/20 clean
on a from-scratch build, plus 15 more immediately prior, plus full
regression (`hello`/`ping`/`p9test`/`nstest`/`writefile`/`readfile`/
`exit`+respawn/`rforktest`/`rforkmemtest`, one boot) and
`scripts/stress_test.sh 15` on both existing scenarios — 65+ consecutive
clean runs across all of this session's testing before calling it done,
given this phase's own history of a plausible-looking first attempt
turning out to hide a real bug.

**Next up:** nothing currently planned — the microkernel roadmap and this
follow-up are both done. A stack-aware wrapper around `RFMEM` (give the
child a fresh stack before it runs anything) would be the natural next
increment if `RFMEM` needs to be genuinely usable rather than just
demonstrated; a private, restricted namespace for a sandboxed child (the
namespace-copy machinery this phase added is already in place for it)
is the other obvious direction.

**Files changed:** `src/entry.c3`, `src/process.c3`, `user/user.c3`,
`user/shell.c3`.

---

## 2026-08-15 (5) — Microkernel roadmap phase 5: fsd, the last kernel
filesystem code moved out

**Goal:** move `src/fs.c3`'s tar parsing out of the trusted kernel into
its own user-mode process, `fsd` — the final phase of the microkernel
plan. `SYS_READFILE`/`SYS_WRITEFILE` are gone from the kernel now; file
access only happens over IPC.

**Much simpler than phase 4, for a specific reason.** diskd needed the
kernel to become an IPC *client* (the `KERNEL_PID`/`kernel_reply_waiter`
machinery from the last entry), because `fs_init()`/`fs_flush()` still
ran as kernel code at the time. fsd doesn't have that problem — it's a
genuine process, so it just uses ordinary blocking `ipc_send`/`ipc_recv`
(`p9_call`) like any other client, both to serve requests and to talk to
diskd itself. That let all of the `KERNEL_PID` machinery from phase 4 be
deleted outright — it existed only to bridge a transitional state, and
this phase closed the gap it was bridging. Also worth noting: fsd never
hits the sscratch/nested-trap hazard `SYS_IPC_POLL` was built for either
— that was specific to diskd waiting on a *hardware interrupt* while
parked mid-trap; ordinary process-to-process IPC (which is all fsd ever
does) wakes the receiver via an explicit state flip in `SYS_IPC_SEND`,
not an asynchronous event, so an ordinary blocking wait is fine.

**Protocol:** `FS_READ`/`FS_WRITE`, a small message layout (100-byte
filename, 4-byte length, up to 1024 bytes of data — matching the file
size the old direct-copy `SYS_WRITEFILE` syscall always allowed, so
moving this out of the kernel didn't quietly shrink the max file size).
`MSG_MAX` bumped from 516 (sized for diskd's one sector) to 1128 to fit
it — trivial cost, ~5KB more kernel BSS across 8 process slots.

**Namespace wrinkle:** the existing default mount is `"/" -> echod`, but
every file access in this codebase has always used a bare filename with
no leading slash (`"hello.txt"`), which never matches a `"/"` prefix.
Rather than force filenames into a path scheme they've never used, added
a *second* default mount with an **empty-string prefix** — `""` — which
`str_starts_with` already treats as matching anything, and whose zero
length always loses a longest-prefix-match tie against `"/"`. That makes
it a genuine catch-all: `"/some/path"` still resolves to echod (p9test
unaffected), while any bare filename falls through to fsd. No changes
needed to `SYS_NS_RESOLVE` itself — this reused the longest-prefix-match
logic phase 3 already built, just with a new kind of mount entry.

**Two bugs, both caught before calling it done, not after:**

1. `user/fsd.c3` declared `FS_READ`/`FS_WRITE`/`FS_MSG_MAX` itself, not
   realizing `user/user.c3` (which every user program compiles together
   with — see `scripts/build_user.sh`) already declared them for the
   client side. Duplicate-declaration compile error, caught immediately.
2. A real one: first boot of fsd panicked with `unexpected trap
   scause=2` (illegal instruction) at a `sepc` that disassembled to a
   bare `unimp` sitting where a function call should have been —
   `scripts/build_user.sh` never passed `--safe=no` to `c3c
   compile-only` for user builds (only the kernel build had it), so
   fsd's array-indexing-heavy code was compiled with bounds/overflow
   checks whose failure path calls a panic handler that doesn't exist in
   this freestanding environment — the trap fires correctly, there's
   just nothing on the other end to catch it. shell/echod/diskd happened
   to never trip a check, so this had been latent since phase 1. Fixed
   by adding `--safe=no` to `build_user_program`, matching the kernel's
   own flags — the right fix regardless of whatever fsd bug (if any) had
   actually tripped a check, since a freestanding kernel target has
   nowhere for a safety-check panic to go either way.

**Verified:** `hello`, `ping`, `p9test`, `nstest` (updated — see below),
`writefile`, `readfile`, `exit`+respawn, one clean boot. `readfile`/
`writefile` now round-trip entirely through fsd → diskd over IPC, zero
kernel involvement. `scripts/stress_test.sh 20` clean on both scenarios
— its own success markers needed updating too, since they grepped for
kernel-side `io::printfn` output (`"file: hello.txt"`, `"wrote %d bytes
to disk"`) that no longer exists now that fs.c3 is gone; added matching
prints to fsd.c3 (`"fsd: file: ..."`, `"fsd: wrote N bytes to disk"`)
and updated the script rather than declare 40 non-hangs "failures."
`nstest`'s "nope has no mount" assertion also needed updating — it now
*does* resolve, to fsd, which is the whole point of the catch-all; it
asserts the new pid instead.

**Roadmap status:** all five phases of the original microkernel plan are
now done. The kernel's own trusted surface is down to: process/scheduling,
paging, traps/syscalls, IPC, namespace resolution, and PLIC interrupt
routing — no device drivers, no filesystem, no knowledge of what a "file"
or a "disk" even is. Both diskd and fsd are ordinary user-mode processes
reachable only through the same primitives any future server would use.

**Files changed:** `src/process.c3`, `src/entry.c3`, `src/kernel.c3`,
`src/fs.c3` (deleted), `user/fsd.c3` (new), `user/user.c3`, `user/shell.c3`,
`scripts/build_user.sh`, `scripts/build.sh`, `scripts/stress_test.sh`.

---

## 2026-08-15 (4) — Microkernel roadmap phase 4: diskd, the virtio-blk
driver moved to user mode

**Goal:** move `src/virtio.c3`'s driver logic out of the trusted kernel
into a new user-mode process, `diskd` — phase 4 of the microkernel plan.
The kernel keeps owning `fs.c3`'s tar parsing for now (that's phase 5);
this phase is specifically about who talks to the hardware.

**The hard part, and how it got solved:** a paged U-mode process only
sees virtual addresses, but the virtio device's queue/descriptor fields
are physical, and the legacy virtio layout needs the virtqueue to be one
physically contiguous run — something diskd's own per-page image mapping
can't guarantee (each page comes from a separate `alloc_pages(1)` call).
Solved by having the kernel allocate diskd's virtqueue and request buffer
at process-creation time (`setup_diskd_mappings`, `src/process.c3`,
guaranteed contiguous via a single `alloc_pages(n)` call) and
**identity-map** them into diskd's own page table (vaddr == paddr) — so
diskd's own pointer dereferences and the physical addresses it hands the
device are the same number, no translation needed. diskd learns that
number via a new syscall, `SYS_DISKD_INFO`, called once at its own
startup — it has no other way to find out (can't call `alloc_pages()`
itself, and can't derive it from anything it's told at compile time).
Device MMIO (`VIRTIO_BLK_PADDR`) is now mapped into diskd's page table
only — every other process's `create_process` mapping loop stopped
mapping it (it used to be universal). PLIC MMIO stays mapped everywhere,
unchanged: `handle_trap`'s `plic_claim()`/`plic_complete()` are S-mode
code reached from inside a trap regardless of which process's page table
happens to be active, not something any one process owns.

**Interrupt routing changed too.** The old kernel-resident driver just
let *whichever process happened to be `wfi`-waiting* wake up naturally
when the interrupt fired. With the driver in its own process, that's not
good enough — `handle_trap`'s interrupt branch now recognizes
`IRQ_VIRTIO_BLK` specifically and delivers a synthetic message
(`DISKD_IRQ_NOTIFY`) straight to diskd's inbox, waking it if blocked,
regardless of who was actually running when the IRQ landed.

**A genuinely new problem: the kernel itself needed to be an IPC
client.** `fs_init()`/`fs_flush()` still run as kernel code (either
during `kernel_main`'s own boot-time call, or inside a
`SYS_READFILE`/`SYS_WRITEFILE` syscall), and now need to *send a request
to diskd and block for the reply* — but IPC's addressing is pid-based,
and the kernel isn't a process. `current_proc` at boot time is
`idle_proc`, whose pid is deliberately 0 (unaddressable) — using it
directly as the reply target would have made every boot-time disk read
silently undeliverable. Added a reserved sentinel, `KERNEL_PID = -1`,
recognized specially by `SYS_IPC_SEND`'s handler: a message addressed to
it lands in kernel-owned globals (`kernel_msg_data` etc.) instead of a
`Process`'s inbox, and a new `kernel_reply_waiter` pointer tracks which
process (if any) is parked waiting for it, so delivery can flip that
process back to `PROC_RUNNABLE` — mirroring what `SYS_IPC_SEND` already
does for an ordinary `Process` target, just for a target that isn't one.
`fs.c3`'s new `diskd_read_write()` uses this to talk to diskd regardless
of whether it's running as idle_proc (boot) or a real process (a syscall)
— and routing disk-driver replies through a separate channel, rather
than whatever process's own inbox happens to be current, also avoids any
chance of colliding with that process's own unrelated IPC traffic.

**A real bug, caught by the project's own stress-testing habit, not by
inspection.** diskd's first version blocked on `ipc_recv()` for the
completion notify, the same way it already blocked waiting for a client
request. Manual boots mostly worked; 20 automated boot-only runs (no
shell input, just `fs_init()`'s own reads) showed 8/20 hanging right
after diskd kicked the virtqueue. Root cause: `sstatus.SIE` has no
per-process save/restore in this kernel (`kernel_entry` only saves GPRs),
and whether interrupts are actually enabled while a process sits blocked
in `SYS_IPC_RECV` depends entirely on leftover state from whatever trap
last ran — not on anything the blocked process controls. That was
harmless before now: `SYS_GETCHAR`'s own retry loop just re-polls the SBI
console each time it wakes, it was never actually waiting *on* an
interrupt. diskd's completion-wait was the first blocking `ipc_recv` in
this codebase that genuinely needed one to fire to make progress.

The obvious fix — call `enable_interrupts()` right before yielding in
`SYS_IPC_RECV`'s loop — made things *worse*: 8/20 runs now paged-faulted
instead of hanging. Root cause of that: `switch_context` unconditionally
resets `sscratch` to a fixed "top of this process's own stack" value on
*every* switch, which is only correct when a process is about to take a
*fresh* trap. When resuming a process that's paused *mid*-trap (exactly
diskd's situation, blocked inside its own `SYS_IPC_RECV` call), that
reset clobbers the correctly-advanced value `kernel_entry`'s own prologue
had set for that in-progress frame. Enabling interrupts there risks a
nested trap building its own frame at that fixed (wrong) address,
overlapping and corrupting the still-live outer one — the same *family*
of bug as the reentrant-trap corruption from the previous session's
lost-wakeup fix, reached by a different path this time (resumption-time
`sscratch` reset, not "re-enabled with a completion still pending").

Properly fixing `sscratch` handling for resumed-mid-trap processes felt
like too large and risky a change to make as a side effect of this
phase. Instead: gave diskd a genuinely **non-blocking** poll syscall,
`SYS_IPC_POLL` — checks once, never sets `PROC_BLOCKED`, never yields.
diskd's completion-wait is now a user-mode spin calling it repeatedly.
Since diskd is never parked mid-trap between polls, `sstatus.SIE`'s
natural value (on, established once by `user_entry`) is safe to leave
alone the whole time, and the interrupt can fire and get routed normally
in the gaps. 20/20 clean boots after the fix, plus 15/15 on both of
`scripts/stress_test.sh`'s existing scenarios (35 consecutive clean runs
total) — considerably more scrutiny than the single clean boot this
project's regression bar technically requires, given how this session's
first two "fixes" each looked right until stress-tested.

**Verified:** `hello`, `ping`, `p9test`, `nstest`, `writefile`,
`readfile`, `exit`+respawn — one clean boot cycle, `readfile`/`writefile`
now flowing through diskd over IPC instead of a direct in-kernel driver
call, no behavior change visible to the shell. `scripts/stress_test.sh
15` clean on both scenarios; 20 additional bare boot-only runs clean.

**Next up:** phase 5 — move `fs.c3`'s tar parsing into its own user-mode
process (`fsd`), a 9P-lite client of diskd and server to everyone else,
eventually letting `SYS_READFILE`/`SYS_WRITEFILE` be deleted from the
kernel once the shell goes through namespace resolution + IPC for file
access too, the same way `p9test` already does for the echod-served
verbs.

**Files changed:** `src/process.c3`, `src/entry.c3`, `src/fs.c3`,
`src/virtio.c3` (gutted to just the struct shapes/consts diskd's mapping
setup still needs), `src/kernel.c3`, `user/diskd.c3` (new), `user/user.c3`,
`scripts/build_user.sh`, `scripts/build.sh`.

---

## 2026-08-15 (3) — Microkernel roadmap phase 3: per-process namespace

**Goal:** implement the per-process namespace/mount table sketched in the
microkernel plan's phase 3 — the second of Rob Pike's two Plan 9 ideas
(the first, the 9P-lite message protocol, landed in phase 2). Turns the
hardcoded `pid 2` littered through `shell.c3`'s IPC test commands into a
real kernel-resolved lookup.

**What was added:**
- `src/process.c3`: a `Mount { char[32] prefix; int server_pid; }` struct
  and a `Mount[NS_MOUNTS_MAX]` (`NS_MOUNTS_MAX = 4`) `namespace` field
  added directly to `Process` — a real per-process kernel structure, not
  a global table, so a later sandboxed process can get a restricted view
  without a redesign (the whole reason this was built this way from the
  start rather than as a shared table indexed by pid). `create_process`
  populates one default binding for every new process: `"/" -> pid 2`
  (echod — always pid 2, deterministically, per the existing convention).
  There's no `fork()`/namespace inheritance yet to make private
  namespaces differ from each other, so today every process's namespace
  is identical; the table itself being per-process is what matters for
  later.
- `src/fs.c3`: `str_starts_with(char* s, char* prefix)`, a small addition
  next to the existing `str_copy`/`str_eq` helpers.
- `src/entry.c3`: `SYS_NS_RESOLVE = 8` — walks the *caller's own*
  namespace (never another process's) for the longest-prefix match
  against a given path, returns the bound server pid or `-1`. Kept
  inline in `handle_syscall`'s switch per the standing, proven convention
  in this file (see the `SYS_EXIT`/`SYS_READFILE` comments) rather than
  risking the unexplained factor-into-a-function reboot bug again.
- `user/user.c3`: `ns_resolve(path)` (thin syscall wrapper) and
  `p9_call_path(path, verb, ...)` — the namespace-aware counterpart to
  the existing `p9_call(pid, verb, ...)`, resolving the path through the
  caller's namespace before sending.
- `user/shell.c3`: `p9test` now calls `p9_call_path("/some/path", ...)`
  and `p9_call_path("/", ...)` instead of hardcoding `p9_call(2, ...)` —
  no more magic pid in the protocol-layer test. Added `nstest`, a direct
  smoke test of `ns_resolve` itself (`/anything` resolves to pid 2;
  `nope`, which doesn't start with `/`, correctly resolves to nothing).
  `ping` was deliberately left using the raw hardcoded pid — it's the
  raw-IPC-primitive test, one layer below where namespace resolution
  belongs, and mixing concerns there would muddy what each command
  actually proves.

**Verified:** one clean boot cycle running `hello`, `ping`, `p9test`,
`nstest`, `writefile`, `readfile`, `exit` (respawn) back to back — no
regressions, `p9test`'s replies unchanged now that they arrive via
namespace resolution instead of a hardcoded pid. Also reran
`scripts/stress_test.sh 10` (both scenarios) to confirm this didn't
disturb the interrupt-driven disk path from the previous entry — 20/20
passed.

**Next up:** phases 4/5 of the microkernel plan — `diskd` (move
`virtio.c3` to a user-mode process, route the PLIC interrupt as an IPC
wake-up to it specifically instead of "whoever's `wfi`-waiting", and stop
mapping virtio/PLIC MMIO into every process) and `fsd` (move `fs.c3`'s
tar parsing to a user-mode 9P-lite server, client of `diskd`, eventually
letting `SYS_READFILE`/`SYS_WRITEFILE` be deleted from the kernel
entirely once the shell goes through namespace resolution + IPC for file
access too). Both are real, separately-scoped efforts — not started yet.

**Files changed:** `src/process.c3`, `src/fs.c3`, `src/entry.c3`,
`user/user.c3`, `user/shell.c3`.

---

## 2026-08-15 (2) — The flaky disk hang, root-caused and fixed (with a
detour through a worse bug I introduced fixing it)

**Goal:** chase down the ~1-in-7 clean hang in `fs_init()`'s
interrupt-driven disk reads, flagged but not investigated in the previous
session's devlog entry.

**Root cause, confirmed empirically, not guessed:** a classic lost-wakeup
race between checking `virtq_is_busy()` and executing `wfi` in
`read_write_disk()`. If the completion interrupt lands in that gap, the
PLIC claim/complete happens as part of an ordinary trap right there, and
the `wfi` that follows immediately after then waits forever for an
interrupt that already fired and was already consumed — nothing will
ever wake it, since the disk request it was waiting for is already done.
Confirmed by adding diagnostic prints before the busy-check (which delay
it enough that the device usually finishes first, skipping the risky
window entirely) and watching the hang disappear across 15 runs —
exactly the signature of a real race, not a fixed bug. The standard fix:
disable interrupts before the check, keep them disabled across the whole
check-and-wfi loop (`wfi` still wakes on a pending-but-globally-masked
interrupt — that's the actual point of the pattern), only re-enable once
the condition is genuinely met.

**That fix introduced a second, worse bug — full page-table corruption on
every `writefile`.** Re-enabling interrupts with the completion still
pending (never claimed, since it stayed masked through the whole wait)
made the CPU take it immediately as a **nested** trap — while the
*original* trap (`kernel_entry -> handle_trap -> handle_syscall -> ... ->
read_write_disk`) was still fully on the stack, not yet returned. Every
trap, nested or not, uses the exact same fixed `sscratch` anchor to build
its frame — there's no reentrancy accounting in `kernel_entry` at all —
so the nested trap's own prologue silently overwrote the *still in-flight
outer* trap's saved context in place, including its saved `sp`. 100%
reproducible: any `writefile` corrupted the calling process's `sp` to
point somewhere inside the kernel's own `procs[]` array, and the very
next thing that process touched its stack for page-faulted trying to
write into kernel memory from user mode. Traced precisely by computing
the byte offset of the faulting address into `procs[]` and confirming it
landed inside the writing process's own kernel-stack region, near the top
— exactly where a trap frame would sit.

**Real fix**: claim and complete the pending PLIC interrupt *ourselves*,
inside `read_write_disk`, immediately after the wait loop exits but
*before* re-enabling — so nothing is ever left pending at the moment
interrupts flip back on, and the nested-trap scenario can't happen at
all. Small, surgical, and directly closes the mechanism rather than
working around a symptom.

**Verified thoroughly**, three separate scenarios, all previously
reproducible failures: the original bare-mode hang (15/15 clean),
`writefile` immediately followed by returning to the shell prompt — the
scenario that was 100% reproducible with the interrupt-disable fix alone
(15/15 clean), and the full interactive regression — `hello`, `ping`,
`p9test`, `readfile`, `writefile`, `exit`+respawn, `hello`, `exit` (10/10
clean).

**A methodological note for future sessions**: this is a good example of
why "it got more reliable when I added debug prints" is a *diagnostic
signal*, not a fix — the reflex has to be "why did delay change the
outcome," not "great, ship it." It would have been easy to declare victory
after the first clean 30-run bare-mode test and never notice the
reentrancy bug the same change had introduced, since it only manifests on
a completely different code path (`writefile`'s per-syscall multi-sector
loop) that a narrower test wouldn't have touched.

**Files changed this session:** `src/entry.c3`, `src/virtio.c3`.

---

## 2026-08-15 — Microkernel route, step 2: a 9P-lite verb set

**Goal:** phase 2 of the roadmap in
`/home/blallo/.claude/plans/giggly-prancing-iverson.md` — a small,
fixed message-oriented protocol layered on top of last session's raw
IPC primitive, per the Plan 9-inspired direction (message protocol +
per-process namespace) agreed with the user. As planned, this needed no
new kernel *mechanism* — just one small completion to the primitive, plus
a shared convention.

**The one primitive gap**: `SYS_IPC_RECV` only ever returned who sent a
message, not what kind (`msg_type`) — fine for phase 1's raw echo test,
not enough for a real client to tell a normal reply from an error without
guessing from byte content. Fixed by repurposing `ipc_recv`'s previously-
always-zero 3rd syscall argument as an optional `uint*` out-pointer for
the type (`src/entry.c3`'s `SYS_IPC_RECV` case writes through it when
non-null). `user/user.c3` gained `ipc_recv_type(buf, len, &type)`, with
the original `ipc_recv(buf, len)` becoming a thin wrapper passing `null`
— existing callers (echod's raw echo, shell's `ping`) unchanged.

**The protocol itself** (`user/user.c3`, shared by every user program
since it's compiled into each one): two verbs to start, `P9_TWALK` and
`P9_TREAD` (numeric constants carried in the already-opaque `msg_type`
field — the kernel still never interprets it, exactly as planned), plus
`p9_call(dest_pid, verb, data, len, reply_buf, reply_len, reply_verb)`
combining send+recv into the one call shape every 9P-lite client
actually wants, matching 9P's own synchronous request/reply model.

**`echod` learned the two verbs** without losing its original job:
`P9_TWALK` gets acked back verbatim (no real namespace to resolve
against yet — that's the next phase), `P9_TREAD` gets a canned reply
string, and anything else (including plain untyped messages) falls
through to the original raw echo, so `ping` needed no changes at all.
`user/shell.c3` gained a `p9test` command exercising both verbs via
`p9_call` and checking `reply_verb` matches what was asked, not just
that *some* reply came back.

**Verified**: `p9test` prints `walk ack: some/path` and
`read: hello from 9p-lite`, both correctly typed. Full regression
(`hello`, `ping`, `p9test`, `readfile`, `writefile`, `exit` + respawn,
`hello`, `exit`) passed clean, single boot cycle, across 6 of 7 runs.

**One thing noticed, not caused by this session, not chased down**: about
1 in 7 runs of the exact same input hangs cleanly (no crash, no
corruption, no reboot loop — just stops progressing) partway through
`fs_init()`'s interrupt-driven disk reads, always before the tar
listing prints. Reproduced identically in last session's testing before
any of today's changes existed, so it predates phase 2 — most likely a
rare lost-wakeup race in the PLIC/`wfi` interrupt path from two sessions
ago (an interrupt firing and being claimed before the waiting process's
`wfi` actually executes, so the wake it needed never arrives). Worth a
dedicated investigation at some point; not urgent since it's rare, always
fails clean, and every success is fully correct.

**Next up:** phase 3, the per-process namespace/mount table — the piece
that turns `p9_call(2, P9_TWALK, "some/path", ...)`'s hardcoded pid `2`
into an actual path resolution, and phase 4/5 (`diskd`, `fsd`) after
that. See the plan file for the full roadmap.

**Files changed this session:** `src/entry.c3`, `user/user.c3`,
`user/echod.c3`, `user/shell.c3`.

---

## 2026-08-14 (12) — Microkernel route, step 1: IPC primitive, plus a
published architecture guide

**Goal:** two things, in order. First, a standalone illustrated reference
guide to the kernel's current architecture (published as an Artifact,
separate from this devlog — a "how it works" document rather than a
"how it got here" one). Second, the first concrete slice of the
microkernel direction discussed with the user: kernel-level message
passing between processes, deliberately designed around Plan 9's two
ideas (a message-oriented protocol and a per-process namespace) rather
than a generic capability-token scheme — full reasoning and the phased
roadmap are in `/home/blallo/.claude/plans/giggly-prancing-iverson.md`
(approved plan file). This session is phase 1 of that roadmap only:
prove two processes can actually exchange a message. No 9P-lite verbs,
no namespace, no driver/FS migration yet — those are future sessions.

**Architecture guide**: published as a Claude Artifact (favicon 🦝,
titled "Racccoon Internals"), covering boot, the address space, the
bitmap page allocator, Sv32 virtual memory, processes/scheduling, traps
and syscalls (including the `sscratch`/trap-frame mechanism and the real
bug that hit it), interrupts, the disk driver, the file system, and
userland — five hand-drawn inline-SVG diagrams showing actual mechanisms
(the Sv32 page-table walk, the syscall round-trip's register save/restore,
etc.), not decorative boxes. Visual identity deliberately grounded in the
project's own name — a raccoon's fur-grey/mask-black/amber-eye palette —
rather than a generic tech-doc look.

**IPC primitive** (`src/process.c3`, `src/entry.c3`, `user/user.c3`,
new `user/echod.c3`):
- New `PROC_BLOCKED` process state. `yield()`'s scheduling scan already
  only matches `PROC_RUNNABLE`, so a blocked process is automatically
  skipped — no scheduler change needed beyond the state itself and its
  transitions.
- Each `Process` gained a single-slot inbox
  (`has_message`/`msg_from`/`msg_type`/`msg_data[64]`) — no queue, no
  allocator. This makes send/receive a synchronous rendezvous with one
  known v1 gap: the *receiver* blocks until a message arrives, but the
  *sender* doesn't block if the target's inbox is already full — it just
  overwrites it. Safe as long as callers keep to one outstanding
  request at a time, which is all this phase's traffic does; noted in
  the plan as a deliberate simplification, not an oversight.
- Two new syscalls, `SYS_IPC_SEND`/`SYS_IPC_RECV` (6/7), handled inline in
  `handle_syscall`'s switch — same established, load-bearing convention
  as `SYS_EXIT`/`SYS_READFILE`/`SYS_WRITEFILE`: factoring this out into a
  separate function has reproducibly broken boot in this c3c version
  before, for reasons never root-caused, so new cases stay inline too.
  `SYS_IPC_SEND` needed a 4th argument (`dest_pid`, `type`, `data_ptr`,
  `len`) beyond the existing 3-arg syscall ABI — solved with a new
  `syscall4` in `user/user.c3` that also sets `a4` (already captured by
  `Trap_frame`, just unused until now), rather than changing the
  existing 3-arg `syscall()` every other syscall already relies on.
  `SYS_IPC_RECV` re-checks `has_message` in a loop after waking, same
  wait-then-recheck shape already used by `SYS_GETCHAR` and
  `virtq_is_busy`'s `wfi` loop.
- `proc_by_pid()` (`process.c3`): pid → `Process*`, trivial given
  `create_process` already assigns `pid = slot_index + 1`.

**Second user process, for real verification**: `scripts/build_user.sh`
was hardcoded to one program; refactored into a `build_user_program()`
function so `scripts/build.sh` now builds and embeds two independent
binaries (`shell.bin.o`, `echod.bin.o`) — both linked at the same
`USER_BASE`, which is fine since each only ever exists in its own
process's own page table. `user/echod.c3` is a minimal IPC test server:
receive, echo the same bytes back to the sender. `kernel_main` spawns it
once, right after idle (not through the shell's respawn loop — it isn't
meant to come back after exiting), which makes it deterministically
process slot 1 / pid 2 every boot. `user/shell.c3` gained a `ping`
command hardcoding that pid — a placeholder until there's a real
name → pid lookup (the namespace phase, not this one).

**Verified**: `ping` from the shell prints `echod (pid 2) replied: hello
echod` — a real message round-tripping through two independently
scheduled user processes. Full regression (`hello`, `ping`, `readfile`,
`writefile`, `exit` + respawn, `hello`, `exit` again) passed clean across
four separate runs, single boot cycle every time (one run hit an
unrelated one-off hang before any input was even processed — did not
reproduce across three immediate retries with the identical binary and
input, treated as QEMU/host timing flakiness rather than a kernel bug).

**Next up:** phase 2 of the roadmap (9P-lite verb set: a small fixed
op-code + path/data message shape layered on top of this raw IPC
primitive) and phase 3 (the per-process namespace/mount table) — see the
plan file for the full roadmap through moving the disk driver (`diskd`)
and file system (`fsd`) out of the trusted kernel.

**Files changed this session:** `src/process.c3`, `src/entry.c3`,
`user/user.c3`, `user/echod.c3` (new), `user/shell.c3`,
`scripts/build_user.sh`, `scripts/build.sh`, `src/kernel.c3`.

---

## 2026-08-14 (11) — Interrupt-driven disk I/O (PLIC), and a real
architectural bug this time, not a compiler mystery

**Goal:** replace `virtq_is_busy`'s tight busy-wait spin in
`read_write_disk` with real interrupt-driven waiting — ch.17's "do not
busy-wait for disk I/O" suggestion, left as an exercise by the tutorial
(no reference implementation to port from).

**What was added:**
- `src/plic.c3` (new): QEMU virt's PLIC (SiFive-style, same layout
  xv6-riscv targets). `plic_init()` sets priority>0 and enables IRQ 1
  (virtio-blk on `virtio-mmio-bus.0`, slot 0) for the S-mode context
  (context 1 for hart 0 — context 2*hart=M-mode, 2*hart+1=S-mode is
  QEMU virt's fixed wiring), threshold 0. `plic_claim()`/`plic_complete()`
  for acknowledging IRQs. Also exports page-aligned bases of the three
  distinct pages its registers span (priority/enable/claim aren't
  page-aligned individually, and aren't contiguous with each other).
- `src/entry.c3`: `handle_trap` now checks `scause`'s MSB to distinguish
  interrupts from exceptions before doing anything else; a supervisor
  external interrupt (cause code 9) claims and completes via the PLIC and
  falls through — no `sepc` adjustment needed for interrupts (unlike
  `ecall`, hardware already points `sepc` at the correct resume address).
  Added a general `write_csr(reg, value)` macro (generalizing
  `write_sepc`'s proven memory-bridged pattern to any CSR name) and
  `enable_external_interrupts()` (sets `sie.SEIE` and `sstatus.SIE`).
- `src/virtio.c3`: `read_write_disk`'s `while (virtq_is_busy(vq)) {}` is
  now `while (virtq_is_busy(vq)) { asm { wfi; } }` — the interrupt's only
  job is to wake the CPU; the real completion check (the used ring index)
  still happens in the loop condition itself, same as before.
- `src/process.c3`: mapped the PLIC's three pages into every process's
  page table (`PAGE_R|PAGE_W`, no `PAGE_U`) — proactively, learning from
  the ch.16 session where the equivalent virtio-blk mapping was missing
  and only surfaced once a syscall (not just `kernel_main`'s bare-mode
  bring-up) actually exercised the driver.

**A real, understood bug this time — not another unexplained c3c quirk.**
`sscratch` needs to point at a valid place to build a trap frame at all
times once interrupts are enabled, including during `kernel_main`'s own
bare-mode phase (before any process exists) — this matters concretely
because `fs_init()`'s initial disk reads happen in exactly that window,
and are now interrupt-driven too. First attempt anchored `sscratch` at
`&__stack_top` — reasoning (wrongly) that this parallels how a real
process's `sscratch` points at its own dedicated kernel stack. Result:
`fs_init`'s own local variable (`sector`, the sector-read loop counter)
got corrupted mid-loop to a garbage pointer-looking value, and shortly
after, execution jumped into a data page as if it were code (`scause=2`,
illegal instruction, at a `__free_ram`-range address).

Root cause, found by reading the disassembly rather than guessing:
`__stack_top` is not a spare/unused address — it's the literal top of the
**live boot stack kernel_main is actively executing on**. By the time an
interrupt fires deep inside `fs_init → read_write_disk → wfi`,
kernel_main's real stack pointer has already moved well below
`__stack_top` (several call frames deep). But `kernel_entry` unconditionally
resets `sp` to the fixed `sscratch` value on every trap and builds a new
124-byte frame downward from there — plus `handle_trap`'s own call depth
(`plic_claim`, `plic_complete`, any debug prints) growing further down
still. That collides with kernel_main's *own, currently-active* stack
frames occupying that exact same region, silently overwriting their
locals. A real process doesn't have this problem: its `sscratch` points
at a 64KB stack *nothing else is using concurrently*. `kernel_main`'s
bare-mode phase had no such isolated region — `__stack_top` looked like
one but wasn't.

**Fix**: a dedicated `char[4096] boot_trap_stack` global in `entry.c3`,
used only as the bare-mode `sscratch` anchor — a genuinely separate
memory region kernel_main's own execution never touches, so trap handling
during this window can never collide with it regardless of call depth on
either side.

**Verified thoroughly**: with the fix, all 5 of `fs_init`'s sector reads
completed via real interrupts (confirmed via trace: `scause` code 9,
`plic_claim` correctly returning IRQ 1, each time) with no corruption,
followed by a full regression — `hello`, `readfile`, `writefile`,
`readfile` (showing the write persisted), `exit`, respawn, `hello`,
`exit` again — single clean boot, no crashes. This exercises the
interrupt-driven path from both contexts that matter: `fs_init`'s
bare-mode reads (using `boot_trap_stack`) and a `writefile` syscall's
`fs_flush → read_write_disk` (using a real process's own `sscratch`,
which was already correct).

**Files changed this session:** `src/plic.c3` (new), `src/entry.c3`,
`src/kernel.c3`, `src/process.c3`, `src/virtio.c3`.

---

## 2026-08-14 (10) — Root cause found: the "mystery compiler bug" was a
misaligned trap vector, not a compiler bug

**Goal:** the previous session's respawn fix worked but leaned on two
unexplained, bisection-only "workarounds" (capture `create_process`'s
return value; keep the idle loop bounded under ~1000 iterations instead
of truly infinite). User correctly pushed back that this looked like
papering over the symptom rather than a real fix, and asked for a proper
disassembly-level investigation instead of more black-box bisection.

**Method:** built two kernels differing *only* in the idle loop's bound
(`1000`, known-working vs `10000`, known-broken), and diffed everything:
`c3c`'s LLVM IR output (`build/llvm/elf-riscv32/kernel.ll`) for
`kernel_main`, then the final RISC-V disassembly (`llvm-objdump -d`).

**Finding #1 — the IR is innocent.** The two `kernel_main` LLVM IR bodies
are byte-for-byte identical except for the literal constant in the loop
exit comparison (`icmp eq i32 %add14, 1000` vs `..., 10000`). So this was
never a c3c *frontend* bug — whatever's wrong happens later, in codegen or
linking.

**Finding #2 — the actual bug.** `10000` doesn't fit RISC-V's 12-bit
immediate the way `1000` does, so loading it takes one extra 2-byte
compressed instruction. That shifts every following symbol's address by
2 bytes — including `kernel_entry`, the trap handler, declared
`@align(4)`. In the broken build, `kernel_entry` landed at `0x8020585e`
(low 2 bits `10`) instead of a real 4-byte boundary. `@align(4)` was
**not being honored** once an unrelated earlier code-size change pushed
it off-boundary.

This matters enormously because `stvec`'s low 2 bits *are* the trap mode
field per the RISC-V privileged spec (0=Direct, 1=Vectored, 2/3=Reserved).
`write_reg("stvec", "kernel_entry")` writes kernel_entry's raw address
straight into `stvec` with no masking. A misaligned address there doesn't
just fail to trap — it puts the CPU into **Reserved trap mode**, which is
undefined behavior. That is almost certainly the real mechanism behind
*every* "silent reboot, no panic, no trap message ever printed" incident
this project has hit — ch.16's `fs_handle_syscall`, this session's
`free_process_pages`, the discarded-return-value trigger, and the
infinite-loop trigger. Four incidents, four different-looking triggers,
one root cause: any sufficiently large code-size shift before
`kernel_entry` in link order had roughly even odds of landing it off a
4-byte boundary, and every "fix" that happened to work was really just
an incidental code-size change that happened to re-align it.

**Real fix** (not a workaround): gave `kernel_entry` its own linker
section (`@section(".text.trap")` in `src/entry.c3`) and added an
explicit `.text.trap : ALIGN(4) { KEEP(*(.text.trap)); }` rule to
`src/kernel.ld`, ahead of the generic `.text` wildcard rule — matching
how `.text.boot` was already special-cased. This makes alignment the
*linker's* job, which — unlike the function attribute — is trustworthy
here: SECTIONS block alignment directives are a core, well-tested linker
feature, not something riding on `@align` propagating correctly through
arbitrary intervening codegen changes.

**Verified thoroughly**: rebuilt with the fix and the previously-broken
`iter < 10000` bound still in place — `kernel_entry` landed at
`0x8020000c` (aligned), boot succeeded clean. Then went further and
reverted *both* prior workarounds simultaneously — genuine `for(;;)`
infinite loop, `create_process(...)` called as a bare discarded-return
statement — and it still worked perfectly: three full `hello`/`exit`
respawn cycles, plus a combined run exercising `hello`/`readfile`/
`writefile`/`readfile`/`exit`/respawn/`hello`/`exit` together. Both
workarounds are now proven unnecessary and have been removed from
`src/kernel.c3` — the code reads naturally again, no defensive comments
about compiler quirks needed.

**Not chased further, but worth knowing**: this doesn't rule out that
`@align` might also fail to be honored for *other* future functions if a
similar code-size shift lands them off a required boundary — the
fix here is specific to `kernel_entry`. If another alignment-sensitive
function is ever added (unlikely in this design, but worth remembering),
the same linker-enforced-section pattern is the trustworthy way to pin it,
not the bare attribute.

**Files changed this session:** `src/entry.c3`, `src/kernel.c3`,
`src/kernel.ld`.

---

## 2026-08-14 (9) — Shell respawn, and the deepest dive yet into the
mystery compiler bug

**Goal:** make `SYS_EXIT` actually useful — before this, exiting the
shell left the kernel idling forever with nothing to run. Idea: when
idle notices nothing else is runnable, respawn a fresh shell from the
same embedded image.

**End state (`src/kernel.c3`, `kernel_main`)**: `idle_entry()` as a
separate function is gone — its loop merged directly into `kernel_main`,
which now runs a bounded `for (int iter = 0; iter < 1000; iter++)` loop
that scans `procs[]` for any runnable non-idle process, calls
`create_process(shell)` (capturing the return value into `Process* shell`,
even though it's unused) if none is found, then `yield()`s. Verified with
three full `hello` → `exit` → respawn cycles in one session — clean single
boot, no crashes, no reboot loop.

**This took a lot longer than it should have — a genuinely deep dive into
the recurring mystery c3c 0.8.2 bug from the last two sessions, this time
with two distinct, fully-bisected triggers found:**

1. **Discarding `create_process`'s return value breaks boot as soon as
   the call site is reachable more than once in a run** — even if the
   second call never actually executes at runtime. Confirmed by testing
   two flat, sequential, unlooped `create_process(...)` statements (no
   assignment): broke boot on the *first* call already (its own "5a:"
   print didn't even fire, despite that exact call working in isolation
   for the entire rest of this project). Assigning the result to a local
   variable — `Process* s1 = create_process(...)`, `Process* s2 =
   create_process(...)` — with nothing else changed, fixed it completely.
   This is a different trigger shape from the ch.16 (`fs_handle_syscall`)
   and earlier this session (`free_process_pages`) incidents — those were
   about factoring logic into a *separate function*; this one is about a
   discarded return value from an *already-proven* function called twice.
2. **A second, independent trigger, found after fixing #1**: with the
   return value captured, a loop calling `create_process` still broke
   boot — but only when the loop was *provably infinite*. `for(;;)` and
   `while(true)` around the exact same body both failed identically. The
   identical body in a *bounded* loop (`for (int k = 0; k < N; k++)`)
   worked — and only up to a point: bisected the bound itself, since "any
   finite N is safe" turned out to also be false. `N=1000` works, `N=10000`
   silently breaks it again (reboot loop, no panic, same signature as
   every prior incident). Landed on `N=1000` — a comfortable margin under
   the failure threshold, and functionally unlimited anyway since this
   loop only actually iterates when nothing else is runnable (essentially
   once at boot, once per `exit`).

Neither trigger has a real diagnosis. Both were isolated by strict
bisection (one code change at a time, rebuild, boot-test, repeat) rather
than reasoning about what the compiler "should" be doing — reasoning
about the *expected* behavior stopped being useful several incidents ago.
At this point there have been four separate reproducible instances of
"code that looks correct and matches working patterns elsewhere in this
codebase silently corrupts boot before the new code path is ever
exercised at runtime," each with a different specific shape (new function
+ `Trap_frame*` in ch.16, new function + `Process*` earlier this session,
discarded return value here, provably-infinite loop here). If this
happens a fifth time, it's probably worth trying a c3c version bump (if
one's available) before bisecting again — this smells increasingly like
a real, still-unfixed backend bug rather than anything about this
specific code.

**Files changed this session:** `src/kernel.c3`.

---

## 2026-08-14 (8) — SYS_EXIT: process teardown, and the same mystery
compiler bug strikes a third time

**Goal:** give `free_pages` (from the bitmap allocator work) an actual
caller — process exit. `user/user.c3`'s `exit()` was still `for(;;);`; a
process that "exited" just hung forever, leaking its page table and image
pages permanently.

**What landed:**
- `src/entry.c3`: `SYS_EXIT = 3` (filling the gap deliberately left in the
  syscall numbering — this is the tutorial's own number for it, we just
  hadn't implemented it yet). `handle_syscall`'s new case walks the
  exiting process's own page table: for every valid top-level entry, walk
  its 2nd-level table; free every leaf page that has `PAGE_U` set (the
  process's private image pages — deliberately *not* the shared
  kernel-identity or virtio-MMIO mappings, which were never marked
  `PAGE_U` for exactly this reason), then free the 2nd-level table page
  itself, then finally the top-level table. Resets the `Process` struct to
  `PROC_UNUSED`/`pid=0` so `create_process`'s free-slot scan can reuse it.
  Calls `yield()` last — since the process is now `PROC_UNUSED`, `yield`'s
  scan can never match it as `next`, so `switch_context` always actually
  switches away, and its `ret` never returns back up through this call
  chain (permanently abandoning it, harmlessly — a future `create_process`
  reusing this slot reinitializes the stack from scratch anyway).
- `user/user.c3`: `exit()` now calls `syscall(SYS_EXIT, 0, 0, 0)` for
  real, with a trailing `for(;;);` kept only as an unreachable fallback so
  the function still satisfies its `@noreturn` contract.

**The mystery c3c bug from the ch.16 cleanup session struck again, a third
time, with a new shape.** First attempt factored the page-table-walk into
`free_process_pages(Process* proc)` in `process.c3` (natural home, next to
`create_process`) and called it from `entry.c3`'s `handle_syscall`. That
alone broke boot — reboot-looping from the very first syscall
(`SYS_PUTCHAR`), before `SYS_EXIT`/this function could ever run at
runtime. Bisected carefully this time (confirmed via `git status`/rebuild
cycles, isolating one line at a time): `yield();` alone in the `SYS_EXIT`
case — fine. `free_process_pages(current_proc);` alone, no `yield()` —
broken. So the call itself is what triggers it, not some interaction with
`yield()`. This rules out my ch.16 theory that the earlier
`fs_handle_syscall` incident was specifically about `Trap_frame*` crossing
a file boundary — this new function takes `Process*`, a type that's
already passed across files successfully elsewhere in this codebase, and
it broke anyway. The common thread across both incidents seems to be:
**calling a moderately-complex, newly-added function from inside
`handle_syscall`'s `switch` statement**, independent of file or parameter
type. Still no real diagnosis — not going to keep sinking time into a
c3c 0.8.2 codegen mystery with no repro simpler than "the whole kernel."
Fixed the same way as `fs_handle_syscall`: inlined the entire walk
directly into the `SYS_EXIT` case in `entry.c3` instead of factoring it
out. Confirmed via bisection that this specific case (inline, in this
exact file) is what's safe — not a general rule to necessarily distrust,
but a specific, reproducible landmine to remember if `handle_syscall`
needs new cases again.

**Verified working**: boots clean (single cycle) with the inlined
version. Ran `hello` then `exit` — shell process terminates without any
crash or reboot loop, kernel stays up with idle spinning silently for the
rest of a 6-second run (no delayed fault). Didn't re-verify the specific
freed-address reuse this time (that mechanism — `free_pages` itself — was
already proven correct in the allocator session with a dedicated
alloc/free/alloc-again sanity check); this session's testing focus was
specifically "does calling it from the real exit path crash or corrupt
anything," which it doesn't.

**Next up (not started):** no re-spawn mechanism exists yet — once the
one shell process exits, the system just idles forever with nothing left
to run. If that's ever wanted, `kernel_main`'s current one-shot
`create_process` call would need to become something idle can trigger
again (or a `fork`/multi-shell design), which is a bigger design question
than this session's scope.

**Files changed this session:** `src/entry.c3`, `user/user.c3`.
(`src/allocation.c3` diff shown in `git status` is carried over from the
allocator session, already logged above.)

---

## 2026-08-14 (7) — Bitmap page allocator with real freeing

**Goal:** replace the bump allocator (`alloc_pages` in `src/allocation.c3`)
with one that supports `free_pages`, as the first step toward eventually
tearing down exited processes and reclaiming their memory. User designed
and wrote a first draft themselves after a theory discussion (free-list vs
bitmap vs buddy allocator design tradeoffs, why the current bump allocator
can't support freeing at all); asked me to review it, then to fix it.

**Issues found in the draft:**
- Bitmap sized off `STACK_SIZE` (per-process kernel stack size,
  unrelated) instead of the actual RAM pool size — only covered 512 pages
  (2MB) against a real 64MB pool.
- The bit-set operation (`bitmap[cnt/8] & (1 << (cnt%8))`) computed a
  value and discarded it — no assignment, so it was a complete no-op.
  Needed `|=` to actually set the bit.
- Index math (`cnt/8`, `cnt%8`) assumed 8 bits per array slot, but the
  array was `uint[]` (32 bits/word) — inconsistent bit-width assumption.
- `cnt += 8` advanced by a flat constant regardless of `n` (pages
  actually requested).
- Most fundamentally: the bitmap was being updated *alongside* the old
  bump-pointer scheme, not *driving* allocation — `paddr`/the OOM check
  still came entirely from `next_paddr`. Freeing a page wouldn't have
  done anything observable, since nothing ever scanned backward for
  reusable space.

**Rewrite** (`src/allocation.c3`): `TOTAL_PAGES = RAM_SIZE / PAGE_SIZE`
bits packed into `uint[TOTAL_PAGES / 32]` (`RAM_SIZE` a new const,
commented as needing to match `kernel.ld`'s `64 * 1024 * 1024`
reservation — same "duplicated with no shared header" situation as
`USER_BASE`/the syscall numbers from earlier sessions).
`bit_is_set`/`set_bit`/`clear_bit` do the shift-and-mask. `alloc_pages(n)`
does a single-pass scan tracking a candidate run's start/length, marks the
run's bits used once it reaches length `n`, and computes the returned
address from *where the run was found* rather than a monotonic cursor.
Added `free_pages(paddr, n)`, which just clears the corresponding bits.

**Verified with a targeted sanity check** (temporarily added to the very
top of `kernel_main`, before anything else touches the allocator, then
removed once confirmed): `alloc_pages(1)` then `alloc_pages(2)` gave two
adjacent addresses; freeing both and re-allocating in the same order gave
back the *exact same addresses* (`p3==p1`, `p4==p2`) — confirming freed
pages are actually found and reused by the scan, not just skipped over.
Full boot + shell regression (`hello`/`readfile`/`writefile`/`readfile`/
`exit`) still passes clean on top of the new allocator, including the
multi-page allocations the virtio driver needs (so the run-scanning logic
is exercised for `n>1`, not just single pages).

**Next up (not started, and explicitly the user's to do solo, not mine):**
`free_pages` still has no caller anywhere in the kernel — process exit
doesn't exist yet (`user/user.c3`'s `exit()` is still `for(;;);`). The
natural next step discussed: a `SYS_EXIT` syscall that walks the exiting
process's own page table (freeing each mapped leaf page, each on-demand
L2 table page `map_page` allocated, then the top-level table itself —
*not* the identity-mapped kernel range, which is shared across all
processes) and resets its `Process` struct to `PROC_UNUSED`.

**Files changed this session:** `src/allocation.c3`.

---

## 2026-08-14 (6) — Structure cleanup pass, and a genuine unexplained c3c bug

**Goal:** address structural issues flagged after finishing the tutorial
(ch.1–16 all implemented): inconsistent module placement under
`src/kernel/`, `entry.c3` having grown into a grab-bag, duplicated
constants between the kernel and user builds with no shared source of
truth, and one piece of dead code.

**What landed:**
- **Module convention, made explicit**: `src/*.c3` = `module kernel` (the
  core's tightly-coupled internal implementation — page tables, processes,
  allocation, trap entry, the virtio driver, the file system all mutate
  shared kernel-wide state with no clean boundary between them). `src/kernel/*.c3`
  = standalone modules with a narrow, self-contained API (`sbi`, `panic`).
  Moved `fs.c3` and `virtio.c3` from `src/kernel/` to `src/` to match —
  they're `module kernel`, so they belonged with `page.c3`/`process.c3`,
  not alongside `sbi.c3`/`panic.c3`.
- Deleted `print_hex` from `kernel.c3` — dead code, never called since
  before this session started. Dropped the now-unused `import libc;` that
  went with it.
- Added cross-reference comments at every place a constant is duplicated
  with no shared header to enforce it: `USER_BASE` (hardcoded in three
  places — `kernel.c3`'s const, the literal in `process.c3`'s
  `user_entry()` asm, and `user/user.ld`'s base address) and the `SYS_*`
  syscall numbers (defined once in `src/entry.c3`, once in `user/user.c3`
  — kernel and user are separate `c3c` compilations with no shared header
  between them, unlike the tutorial's C `common.h`).

**What did NOT land, and why — a genuinely unexplained compiler bug:**
Tried moving the `SYS_READFILE`/`SYS_WRITEFILE` handling body out of
`entry.c3`'s `handle_syscall` into a new `fs_handle_syscall(Trap_frame* f)`
function next to `fs_lookup`/`fs_flush` in `fs.c3` — a pure code-motion
refactor, no logic changes. This alone (confirmed via `git stash` bisection
against the known-good committed state, testing one change at a time)
broke boot: the kernel would reboot-loop from the very first syscall
(`SYS_PUTCHAR`, printing the shell's `"> "` prompt) — a code path that
**does not call `fs_handle_syscall` at all**. Tried adding `@noinline` to
rule out an inliner bug; same failure. Reverting *only* this one
extraction (keeping every other change, including the `fs.c3`/`virtio.c3`
relocation) fixed it immediately. Root cause not identified — best guess
is a c3c 0.8.2 codegen bug specific to a function taking `Trap_frame*`
(the `@packed` trap-frame struct) called across a file boundary within the
same module, but that's speculation, not a confirmed diagnosis. Left the
`SYS_READFILE`/`SYS_WRITEFILE` body inline in `entry.c3`'s `handle_syscall`
(proven correct), with a comment explaining why it's not where it looks
like it should live. Worth retrying against a newer c3c release if one
becomes available.

**Verified working**: full regression run through `hello`, `readfile`,
`writefile`, `readfile` (showing the write persisted), `exit` — single
clean boot cycle, no regressions from any of the landed changes.

**Files changed this session:** `src/entry.c3`, `src/kernel.c3`,
`src/process.c3` (comment only), `user/user.c3` (comment only),
`user/user.ld` (comment only), `src/fs.c3` (renamed from
`src/kernel/fs.c3`), `src/virtio.c3` (renamed from `src/kernel/virtio.c3`).

---

## 2026-08-14 (5) — Tar-based file system (tutorial ch.16)

**Goal:** the real file system on top of ch.15's virtio-blk driver — files
stored as a tar archive on disk, loaded into memory at boot, exposed to
user processes via `readfile`/`writefile` syscalls.

**What was added:**
- `src/kernel/fs.c3` (new): `Tar_header` (ustar layout, 512 bytes),
  `File` (in-memory: `in_use`, `name[100]`, `data[1024]`, `size`),
  `oct2int`, `fs_init` (reads the whole disk into a `disk[]` buffer, walks
  tar headers into the `files[]` array), `fs_flush` (rebuilds the tar
  image from `files[]`, including the ustar checksum, writes it back),
  `fs_lookup`. `str_copy`/`str_eq` are small freestanding helpers (no
  `strcpy`/`strcmp` in the kernel's custom libc).
- `src/entry.c3`: `handle_syscall` gained `SYS_READFILE`/`SYS_WRITEFILE`
  (4/5), dereferencing the user-supplied filename/buffer pointers directly
  and calling `fs_lookup`/`fs_flush`.
- `src/process.c3`: `user_entry` now also sets `SSTATUS_SUM` (bit 18) in
  `sstatus` alongside `SSTATUS_SPIE` — required for S-mode to access
  `PAGE_U` pages at all; without it, the kernel dereferencing a user
  pointer (the readfile/writefile filename and buffer) page-faults
  immediately.
- `user/user.c3`, `user/shell.c3`: `readfile`/`writefile` wrappers and
  `readfile`/`writefile` shell commands, per the tutorial.
- `disk/hello.txt` (new) + `scripts/build.sh`: builds `build/disk.tar`
  from `disk/*.txt` via `tar cf ... --format=ustar`, matching the
  tutorial's approach; `scripts/launch.sh` now attaches that instead of
  the raw `resources/disk.txt` from the ch.15 session (that file is now
  unused/superseded, left in place but nothing references it).

**C3 syntax notes (not bugs):** `SomeStruct::size` for `sizeof`, not
`.sizeof` (that parses as a member lookup and fails). No `offsetof` needed
— `(uint)&file.data` already gives the same address a real typed pointer
would.

**Two real bugs found:**

1. **virtio MMIO region wasn't mapped into process page tables.**
   `create_process`'s identity-mapping loop only covers `[__kernel_base,
   __free_ram_end)`; the virtio-blk MMIO registers at `0x10001000` are
   outside that range entirely. Invisible in the ch.15 session because
   `virtio_blk_init()`/`read_write_disk()` only ran from `kernel_main`
   before any process existed (bare/physical addressing, no page table
   involved). The first `writefile` (which triggers `fs_flush` ->
   `read_write_disk` from *inside* a syscall, i.e. under the shell
   process's page table) immediately store-page-faulted writing to the
   queue-notify register. Fixed by adding
   `map_page(page_table, VIRTIO_BLK_PADDR, VIRTIO_BLK_PADDR, PAGE_R | PAGE_W)`
   to `create_process`, same pattern as the identity-mapping loop.

2. **Tutorial's own length-clamping logic is wrong, and C3's safe mode
   caught it where C would have silently corrupted a stack byte.** The
   reference C clamps the requested `len` against the *file's* internal
   1024-byte buffer (`if (len > sizeof(file->data)) len = file->size;`),
   not against the caller's own buffer or the actual file size. Ported
   faithfully at first, it let a `readfile("hello.txt", buf, 128)` call
   return `len=128` unchanged (128 < 1024, so the clamp never triggers)
   even though the file only has 17 bytes — then `buf[128] = 0` in the
   128-byte-buffer shell code is a genuine out-of-bounds write. In C this
   is silent UB that usually goes unnoticed; C3's default safe mode
   (the user build has no `--safe=no`, unlike the kernel build) correctly
   trapped it as an illegal instruction (`unimp`). Fixed by clamping
   *reads* against `file.size` (never return more than the file actually
   has) and *writes* against `file.data.len` (never write more than the
   file's storage can hold) — separately, instead of reusing one
   ambiguous check for both directions. Also added a `len >= 0` guard in
   the shell before indexing `buf[len]`, since a `-1` (file-not-found)
   return would otherwise hit the same class of out-of-bounds trap.

**One more stack-overflow, same class as the ch.14 session's:** after
fixing both bugs above, `readfile` worked once, but a second `readfile`
after a `writefile` reported "file not found" — `files[0].in_use` had
gone back to `false` and its `name` was empty, i.e. the `files[]` array
itself was getting corrupted mid-session. The file-system call chain
(`handle_syscall` -> `fs_lookup`/`fs_flush` -> `read_write_disk` ->
`virtq_kick`/`virtq_is_busy`, plus `fs_flush`'s tar-rebuild and checksum
loops) is considerably deeper and heavier than the ch.14 syscalls
(`getchar`/`putchar`) that `STACK_SIZE = 8192` was sized for, and it
overflowed into the neighboring `Process` structs in `procs[]`. Confirmed
by bumping `STACK_SIZE` to 65536 and watching the corruption disappear.
Kept the larger size permanently (512KB total across `PROCS_MAX=8`
processes is negligible against the 64MB RAM pool). While in there, also
replaced two magic numbers (`2048`, `8191`) that were silently assuming
the old `STACK_SIZE=8192` value with proper `STACK_SIZE`-derived
expressions, since those would have quietly broken again on the next
resize.

**Verified working** end-to-end in QEMU: `readfile` prints the disk's
original `hello.txt` content ("Hello from disk!"), `writefile` reports
"wrote 2560 bytes to disk", and a following `readfile` shows the new
content ("Hello from shell!") — confirming both the tar parse-on-boot and
the write-back-to-disk paths work, and that the change actually persists
in the backing tar file across the write.

**Next up (not started):** ch.17 (outro/wrap-up — the tutorial's last
chapter, mostly a victory lap rather than new functionality). After that,
the user's earlier question about a microkernel-style refactor (moving
the disk driver/file system out of kernel space into a user-mode server
via IPC) becomes the natural next thing to actually scope out.

**Files changed this session:** `src/kernel/fs.c3` (new), `src/entry.c3`,
`src/process.c3`, `src/kernel.c3`, `user/user.c3`, `user/shell.c3`,
`scripts/build.sh`, `scripts/launch.sh`, `disk/hello.txt` (new).

---

## 2026-08-14 (4) — virtio-blk disk driver (tutorial ch.15)

**Goal:** implement the virtio-blk MMIO driver so the kernel can read/write
raw 512-byte sectors from a virtual disk, per tutorial ch.15 — the
foundation ch.16's real file system will sit on.

**What was added:**
- `src/kernel/virtio.c3` (new): the full driver, ported fairly directly
  from the tutorial's C — MMIO register constants, `Virtq_desc` /
  `Virtq_avail` / `Virtq_used` / `Virtio_virtq` / `Virtio_blk_req` structs,
  `virtio_reg_read32/64` / `virtio_reg_write32` / `_fetch_and_or32`,
  `virtq_init`, `virtio_blk_init`, `virtq_kick`, `virtq_is_busy`, and
  `read_write_disk(buf, sector, is_write)`.
- `src/kernel.c3`: `kernel_main` now calls `virtio_blk_init()` right after
  the trap vector is set up, reads sector 0 and prints it, then writes a
  test string back — same bring-up smoke test the tutorial uses in this
  chapter (this block is throwaway, meant to be replaced once ch.16's
  actual file system lands).
- `resources/disk.txt` (new): the backing disk image — plain text file
  QEMU treats as a raw block device. `scripts/launch.sh` now attaches it
  via `-drive ... -device virtio-blk-device,...`.

**C3-specific translation notes (not bugs, just syntax differences from
the tutorial's C that took a try to find):**
- `sizeof(SomeStruct)` in C3 is `SomeStructName::size`, not `.sizeof` —
  `.sizeof` errors as "no method found" since C3 parses it as a member
  lookup. `@sizeof(value)` (with `@`) is the separate form for an actual
  *value* expression, not a type name.
- `offsetof(struct, field)` isn't needed at all in C3 the way the tutorial
  uses it in C — `(uint)&blk_req.data` already gives the same address
  C's `blk_req_paddr + offsetof(virtio_blk_req, data)` computes, since
  `blk_req` is a real typed pointer at that physical address. Simpler than
  the C original.
- A page-aligned struct *member* (`used __attribute__((aligned(PAGE_SIZE)))`
  in the tutorial's C, required by the legacy virtio MMIO layout) is just
  `used @align(PAGE_SIZE)` in C3 — same effect, existing precedent for
  this attribute already in the c3c stdlib (e.g. `sha256.c3`).
- The block-form `asm { fence; }` (used successfully elsewhere this
  project for bare no-operand instructions like `wfi`) rejected `fence`
  specifically ("Unknown instruction for the current target"). Used the
  basic string form `asm("fence")` instead — no cross-statement register
  bridging involved here, so none of the hazards from the ch.14 session's
  `read_reg`/`write_reg` bugs apply.
- Volatile MMIO reads/writes and the `virtq_is_busy` poll use
  `mem::load(ptr, align, true)` / `mem::store(ptr, value, align, true)` —
  the c3 stdlib's own volatile-load/store macros — rather than a bare
  pointer dereference, to make sure the optimizer can't hoist/cache reads
  of memory the device writes asynchronously.

**Verified working** end-to-end in QEMU with the disk attached: boot log
shows `virtio-blk: capacity is 512 bytes` and `first sector: Hello from
disk!` (matching `resources/disk.txt`'s content exactly), then the
in-kernel write-back test was confirmed by inspecting the backing file
after a run — it now contained `hello from kernel!!!` null-padded to 32
bytes, proving both the read and write paths work. Reset `disk.txt` back
to its original content afterward. Rest of boot (process creation, shell
prompt) unaffected — no regressions.

**Next up (not started):** ch.16, the actual file system built on top of
this block driver (replacing the throwaway read/write test in
`kernel_main`), then ch.17 (outro / wrap-up). After that, the user asked
about eventually exploring a microkernel-style refactor (moving drivers/FS
out of kernel space into user-mode servers via IPC) as a deliberate
follow-up once the tutorial's monolithic design is complete.

**Files changed this session:** `src/kernel/virtio.c3` (new),
`src/kernel.c3`, `scripts/launch.sh`, `resources/disk.txt` (new).

---

## 2026-08-14 (3) — Real shell: command parsing, `hello`/`exit`

**Goal:** replace the raw echo-loop shell from the previous session with
the tutorial's actual ch.14 shell — a prompt, a command-line reader, and
`hello`/`exit` command handling — now that `getchar`/`putchar` syscalls are
proven working.

**What was added:**
- `user/user.c3`: two small freestanding helpers, since there's no libc on
  the user side (`--use-stdlib=no --link-libc=no`): `print(char*)` (loops
  `putchar` until NUL) and `strcmp(char*, char*)`. Kept intentionally
  minimal — no varargs `printf`, just what the shell needs.
- `user/shell.c3`: rewritten to the tutorial's loop — prints `> `, reads a
  line into a 128-byte buffer via `getchar()` (echoing each char, handling
  `\r` as end-of-line and a too-long line by restarting the prompt), then
  dispatches on `strcmp`: `hello` prints a greeting, `exit` calls
  `exit()`, anything else prints `unknown command: <line>`.

**One build snag:** `char[128] cmdline;` in `shell.c3` failed to link with
`undefined symbol: memset` — C3 zero-initializes local arrays by default,
and the user build has no libc/memset available (freestanding, matching
`user.c3`'s existing no-stdlib setup). Since the buffer is always
null-terminated by hand before use, zero-init isn't needed — fixed with
`char[128] cmdline @noinit;` to opt out of the implicit zeroing.

**Verified working** end-to-end via QEMU with `-serial stdio -monitor
none` and a piped command script (`xx\rhello\rfoo\rexit\r`): prompt shows,
unknown commands are echoed back correctly, `hello` prints the greeting,
`exit` terminates the shell process cleanly. No crashes, no regressions
from the syscall-path fixes earlier this session.

**Next up (not started):** ch.15 (virtio-blk disk I/O) and ch.16 (file
system) — the shell has no persistent storage or files yet.

**Files changed this session:** `user/user.c3`, `user/shell.c3`.

---

## 2026-08-14 (2) — Wiring up syscalls (tutorial ch.14), and three real compiler/codegen traps

**Goal:** implement `putchar`/`getchar` syscalls end-to-end (user
`syscall()` → `ecall` → kernel trap → SBI console), per tutorial ch.14, on
top of the now-booting `user_mode` branch from the previous session.

**What was added (straightforward part):**
- `user/user.c3`: `syscall(sysno, arg0, arg1, arg2)` using C3's block-form
  inline asm (`asm { mv $a0, arg0; ... ecall; mv result, $a0; }`) — this
  form binds C3 locals to physical registers and auto-infers clobbers,
  unlike the basic `asm("string")` form. `putchar`/`getchar` now call it for
  real instead of being stubs.
- `src/kernel/sbi.c3`: added `__getchar()` (legacy SBI eid=2), matching the
  existing `__putchar()` (eid=1) pattern.
- `src/entry.c3`: `handle_trap` now branches on `scause == SCAUSE_ECALL`
  (8) to a new `handle_syscall()`, dispatching `f.a3` (syscall number) to
  `SYS_PUTCHAR`/`SYS_GETCHAR`; `SYS_GETCHAR` polls `sbi::__getchar()` in a
  loop, calling `yield()` between polls since it's non-blocking.
- `user/shell.c3`: now a real getchar/putchar echo loop instead of an empty
  `for(;;)`, to exercise the path.

**Three real bugs found chasing this — all in the pre-existing low-level
asm helpers, none in the syscall logic itself:**

1. **`stvec` was never reliably set.** `write_reg`/the inline stvec setup
   in `kernel_main` used *two separate* `asm("...")` calls (`la t0,
   SYMBOL` then `csrw REG, t0`), trusting the compiler to keep `t0` live
   across them. Nothing enforces that — the optimizer is free to schedule
   other code between two independent `asm()` statements since each is an
   opaque, unrelated unit to it. This was silently broken (stvec pointing
   at garbage) the entire time; it was invisible because *no prior test
   had ever triggered a real trap* (the previous session's shell was a
   silent `for(;;)`; ch.14 is the first thing to actually execute `ecall`).
   When a trap finally fired with a broken vector, execution went
   somewhere undefined and eventually wandered back into `kernel_main`,
   reproducing the exact "reboot loop → out of memory" signature from the
   `.eh_frame` bug in the previous session, for a completely different
   reason. **Fix:** merged into one `asm(@sprintf(multi-line, ...))` call
   so the whole sequence is one opaque-but-atomic unit (`write_reg` in
   `src/entry.c3`).

2. **`read_reg` corrupted live caller state.** Same shape of bug: it read
   a CSR into `a0` via string asm, then a *separate* block-asm statement
   copied `a0` into the macro's return variable. `handle_trap(Trap_frame*
   f)` receives `f` in `a0` (standard calling convention) and, since the
   compiler can't see into the string-asm's clobbers, had no reason to
   move `f` out of `a0` before calling `read_reg()` three times in a row
   (for scause/stval/sepc) — each call silently overwrote `f` with the
   CSR value. By the third call, `f` == the value of `sepc` (a user-space
   address), so `handle_syscall(f)` dereferenced garbage and page-faulted.
   This is the same class of bug as #1, just hitting a live *variable*
   instead of a dead register — and again latent since nothing had
   previously called `read_reg` from a function with a live pointer
   parameter still needed afterward. **Fix:** rewrote `read_reg` to bridge
   through a dedicated global (`read_reg_tmp`) inside one atomic
   `asm(@sprintf(...))` call, same shape as the `write_sepc` helper added
   for advancing `sepc` past the `ecall`.

3. **Debug `io::printfn` calls deep in the trap-handling call chain caused
   real stack corruption.** While chasing bug #2, added multi-argument
   debug prints inside `yield()` and `handle_syscall()` (5+ struct-field
   args in one `printfn`). This didn't just add noise — at that call
   depth (`kernel_entry`'s raw 124-byte trap frame → `handle_trap` →
   `handle_syscall` → `yield()`, all sharing one process's 8KB kernel
   stack, `char[STACK_SIZE] stack` being the last field of `Process`), the
   extra stack pressure from formatting-heavy `printfn` calls blew past
   the 8KB budget and corrupted `Process` struct fields *before* `.stack`
   in memory (`pid`/`state`/`sp`/`page_table` — confirmed by dumping them
   and watching `idle_proc.state`/`procs[1].pid` read back as zero
   mid-session). Confirmed by testing at `-O0`: the corruption got *worse*
   with less optimization (bigger, unoptimized frames), which pointed
   straight at stack depth rather than a logic bug. **Fix:** none needed
   in the shipped code — just stripped the debug prints back out once the
   real bugs (#1, #2) were fixed. Lesson for next time: keep any debug
   instrumentation inside the trap-handling path (`kernel_entry` →
   `handle_trap` → `handle_syscall` → …) to single-argument prints, or
   move heavier tracing into codepaths outside a process's 8KB kernel
   stack budget.

**Testing gotcha (not a kernel bug):** `qemu-system-riscv32 ... -serial
mon:stdio` silently swallows/multiplexes piped or file-redirected stdin
differently than a real TTY — `getchar()` never saw any input through it.
Switching to `-serial stdio -monitor none` (dedicated, non-multiplexed
serial on stdio, no monitor) made piped/redirected input work exactly as
expected. Use this form for any non-interactive testing.

**End state:** `bash scripts/build.sh` builds clean. Booting with real
piped/redirected input (`-serial stdio -monitor none`) shows the shell
echoing typed characters back correctly via the real `getchar`/`putchar`
syscalls (a `hello world` test echoed as `ello world` — the leading char
lost to a boot-timing race in how QEMU delivers a pre-staged input file
before the guest UART is ready, not a kernel bug). No reboot loop, no
panic, over multiple runs.

**Next up (not started):** the shell is still just a raw echo loop.
Tutorial ch.14's actual shell (command line parsing, `hello`/`exit`
commands) needs `strcmp`/some `printf` on the user side, which the tiny
custom `user/user.c3` library doesn't have yet. After that: ch.15
(virtio-blk disk I/O) and ch.16 (file system).

**Files changed this session:** `user/user.c3`, `user/shell.c3`,
`src/kernel/sbi.c3`, `src/entry.c3`.

---

## 2026-08-14 — Getting `user_mode` branch building and booting again

**Starting state:** branch `user_mode` had uncommitted WIP for tutorial ch.12
("Application") and ch.13 ("User Mode") — a `user/` userland app, a
`scripts/build_user.sh` to embed it into the kernel image, and partial
changes to `src/process.c3` / `src/kernel.c3` to load and run it. The kernel
did not compile.

**Fixes applied, in order hit:**

1. `src/process.c3:97` — `*(--sp) = user_entry` used a function name as a
   value instead of a function pointer. Fixed to `(uint)&user_entry`.
2. `create_process` had the ch.13 signature (`image`, `image_size`) but the
   ch.12-era body — it never mapped the image into the process's address
   space. Added the page-by-page `mem::copy` + `map_page(..., PAGE_U|R|W|X)`
   loop at `USER_BASE`, per the tutorial.
3. `kernel::user_entry()` was a stub that called `panic::panic(...)`.
   Implemented it as the naked-asm trampoline that sets `sepc = USER_BASE`,
   `sstatus = SSTATUS_SPIE`, and executes `sret` to drop into U-mode. Note:
   C3's compile-time `asm(@sprintf(...))` only supports `%s` substitution,
   not `%d`, so the immediates are hardcoded in the asm text rather than
   interpolated from the `USER_BASE`/`SSTATUS_SPIE` constants.
4. `kernel_main` still called `create_process` with the old 1-arg signature
   and spun up kernel-side `proc_a`/`proc_b` demo processes instead of the
   embedded shell binary. Removed the demo code (`proc_a`, `proc_b`,
   `proc_a_entry`, `proc_b_entry`, `delay`); wired `create_process(null, 0)`
   for idle and `create_process(&_binary_shell_bin_start, (uint)&_binary_shell_bin_size)`
   for the shell process.
5. `scripts/build_user.sh` ran `llvm-objcopy -Ibinary` on the path
   `build/user/shell.bin`. objcopy derives the embedded symbol names from
   the *input path*, so this produced `_binary_build_user_shell_bin_start`
   instead of the expected `_binary_shell_bin_start`. Fixed by `cd`-ing into
   `build/user` before running objcopy so the symbol name is derived from
   just `shell.bin`.
6. First attempt at declaring the `_binary_shell_bin_*` symbols in
   `src/kernel.c3` copied the existing `char[] X @export("X")` pattern used
   for linker-script symbols like `__kernel_base`. That pattern actually
   *defines* a zero-size symbol in the C3 object file — fine when nothing
   else defines it (as with `__kernel_base`, which only exists as a linker
   script assignment), but it collided with the real data definition in
   `shell.bin.o`, causing a duplicate-symbol link error. Fixed by declaring
   them as `extern char[] X @cname("X")` instead (same pattern already used
   for `__stack_top` in `user/user.c3`).
7. **The subtle one.** After all of the above, the kernel booted but then
   appeared to "reboot" itself in a loop (`1: BSS cleared` through
   `Idle process started` repeating) until it panicked with "Out of memory".
   No trap/exception was ever logged by `handle_trap`, which ruled out a
   page fault. Root cause: `user/user.ld` didn't discard `.eh_frame`, so LLD
   placed that unwind-info section *before* `.text` at the `USER_BASE` load
   address. `start()` ended up at file offset `0x6c` inside `shell.bin`
   instead of offset `0`, but `user_entry`'s hardcoded `sepc = USER_BASE`
   jumps straight to offset `0`. The CPU executed `.eh_frame` bytes as
   garbage instructions — apparently without ever faulting — and eventually
   wandered back into kernel code space, re-entering `kernel_main` in a
   loop, which is what exhausted the 64MB free-RAM pool. Fixed by adding
   `/DISCARD/ { *(.eh_frame .eh_frame.*) }` to `user.ld`.

**End state:** `bash scripts/build.sh` builds cleanly. Booting
`build/kernel.elf` in QEMU (`qemu-system-riscv32 -machine virt -bios default
-nographic -serial mon:stdio -no-reboot -kernel build/kernel.elf`) runs the
full boot sequence exactly once, creates the idle and shell processes, drops
into U-mode at `USER_BASE`, and the shell process spins silently in its
`for(;;)` loop (its `putchar` is still a stub, so no output yet — that's
ch.14, syscalls). No crash, no reboot loop, confirmed stable over a 5s run.

**Next up (not started):** wire up a real syscall path (`putchar`/`getchar`
at minimum) so the shell can actually talk to the console — tutorial ch.14.

**Files changed this session:** `src/process.c3`, `src/kernel.c3`,
`scripts/build_user.sh`, `user/user.ld`.
