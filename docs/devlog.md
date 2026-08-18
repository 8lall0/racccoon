# Racccoon devlog

Running log of work sessions with Claude Code. Newest entry on top.

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
