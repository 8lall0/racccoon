# USB: interrupt-driven transfer completion — staged plan

Status: **planning only, no code.** Written 2026-08-28. Autonomous
session ("go full auto on #3") — investigation done, implementation
deliberately deferred (see §7).

The goal: replace usbd's register-polling wait for transfer completion
(`hc_wait_chhltd()`'s `yield()` loop reading `HCINT`) with the DWC2
core's own interrupt, routed through the PLIC to usbd the same way a
virtio-blk / SDHCI completion IRQ already reaches diskd / sdd.

---

## 1. What "interrupt-driven" means here (and doesn't)

racccoon has no in-kernel blocking wait for a device IRQ. The proven
pattern (diskd, sdd) is:

1. Device asserts its IRQ line → PLIC → S-mode external interrupt.
2. `handle_trap()` (`src/entry.c3:2146`) claims the IRQ, and if it
   matches a known driver's `board::IRQ_*` **and** that driver's pid is
   registered, posts a synthetic message (`msg_type = DISKD_IRQ_NOTIFY`,
   the opaque "your IRQ fired" sentinel — `src/entry.c3:123`) into the
   driver's single-slot inbox and marks it `PROC_RUNNABLE`.
3. `plic_complete(irq)`.
4. The driver, spinning in **user mode** on `ipc_poll_type()` (never a
   blocking `ipc_recv`), sees the notify and proceeds
   (`user/block/diskd.c3:192`).

Step 4 is user-mode-poll, not park-and-wake, **on purpose**:
`sstatus.SIE` has no per-process save/restore and `switch_context`
resets `sscratch` unconditionally, so enabling interrupts while a
process is parked mid-trap risks a nested trap corrupting the outer
frame — confirmed empirically (`SYS_IPC_POLL`'s comment,
`src/entry.c3:780`).

**Consequence for the benefit calculus.** Today `hc_wait_chhltd()`
already `yield()`s between `HCINT` reads — it is cooperative, not a hard
spin. So the win is *not* "usbd stops hogging the CPU." The wins are:

- usbd stops touching the `HCINT` MMIO register once per scheduler pass
  for the entire duration of every transfer, every 4 ms bInterval gap,
  and every NAK backoff — real bus traffic on a shared AHB.
- The scheduler stops being handed a "check again" runnable from usbd
  during those waits; with an idle keyboard + mouse + pad all polling,
  that is a meaningful reduction in scheduler churn and lets the idle
  `wfi` path actually sleep.
- Completion is noticed on the first `ipc_poll_type` spin iteration
  after the IRQ, versus after a `yield()` round-trip through every other
  runnable process. Lower, more predictable transfer latency.

Modest but real. This is a polish / scalability change, not a
correctness fix.

---

## 2. The blocker: the Duo PLIC is not proven

`boards/duo/board.c3` today:

- `PLIC_BASE` / `PLIC_S_CONTEXT` register formulas are **UNVERIFIED**
  for the Duo's `c900-plic` — carried over from QEMU `virt`'s
  convention "pending real confirmation" (`board.c3` comment near
  `PLIC_S_CONTEXT`).
- `IRQ_VIRTIO_BLK = 0` is a deliberate *no real IRQ* sentinel (diskd
  never spawns on the Duo anyway).
- `plic_init()` has an **active isolation experiment**: the
  `IRQ_SDHCI` (36) enable-bit write is commented out because real
  hardware hits an **interrupt storm** whose signature is
  `plic_claim() == 0` **and** raw pending bitmap `== 0` on every sample,
  forever — and "the PLIC enable bit itself" has never been ruled out
  as the cause (`board.c3` comment in `plic_init`, and
  `docs/devlog.md`).

So sdd runs in **polled PIO mode** precisely because the Duo interrupt
path does not work yet. Interrupt-driven USB rides the exact same
untrusted PLIC path and would need the storm solved first. **This plan
cannot be verified on hardware until then**, and there is no QEMU DWC2
(`board::HAS_USB` is Duo-only) so there is no QEMU leg either.

Recommended: solve the SDHCI PLIC storm first (it already has a driver
and a test rig). USB then reuses the now-trusted path.

**Update 2026-08-28 — the storm is root-caused** (see
`docs/devlog.md` and memory `racccoon-plic-storm`): it is the missing
T-HEAD C900 PLIC M-mode delegate write `writel(1, 0x701FFFFC)`, which
the Duo's stock OpenSBI never does. Fix is a ~1-line OpenSBI patch +
a `fip.bin` MONITOR repack. Once that lands and `IRQ_SDHCI` is
re-armed without storming, this whole plan is unblocked.

---

## 3. Facts already established

- **CV1800B USB interrupt = 30**, level-high, `interrupt-parent =
  <&plic0>`. Source: duo-buildroot-sdk
  `build/boards/default/dts/cv180x_riscv/cv180x_base_riscv.dtsi`,
  `usb@04340000 { interrupts = <30 IRQ_TYPE_LEVEL_HIGH>; }`.
  IRQ 30 < 32 → it lives in the **first** PLIC enable word
  (`PLIC_ENABLE_BASE`), the simple case, unlike `IRQ_SDHCI` (36) which
  needs the second word.
- The DWC2 core's global interrupt gate `GAHBCFG.GLBL_INTR_EN` is
  **already set** (`dwc2.c3:630`) — it was needed for periodic
  transfers to work at all. `GINTMSK` is currently **fully masked**, so
  the core never asserts its external line today (`dwc2.c3:54` comment).
- `hc_wait_chhltd()` (`dwc2.c3:752`) is the **single** wait point —
  every transfer path (plain, split-start, split-complete) funnels
  through it. One function to convert.
- racccoon uses **host channel 0 only** — one transfer in flight at a
  time, so exactly one `HCINT` completion source. No `HAINT` demux
  needed beyond "channel 0".
- usbd's `main()` loop (`usbd.c3:984`) is poll-only: it *never* blocks
  on `ipc_recv`; `usb_msc_ipc_poll()` is non-blocking. Adding an IRQ
  notify into its inbox is new but the slot is otherwise idle between
  MSC requests.

---

## 4. What must stay polled

- **`usb_wait_for_microframe()` / `usb_hfnum_microframe()`** — the
  split-transaction scheduler aligns start-split / complete-split to a
  target microframe by spinning on `HFNUM` (`hc_transfer_once_split`).
  You cannot interrupt-wait for "microframe N"; these sub-millisecond
  alignment spins stay exactly as they are.
- **`hc_wait_chhltd()`'s 2 s timeout fallback** — keep it. An
  interrupt-driven wait must still bail on a wedged channel that never
  raises CHHLTD; the fallback becomes "poll `HCINT` directly if the
  notify hasn't arrived within a shorter soft deadline, then the hard
  2 s deadline as today."
- **HPRT0 connect/disconnect** (`usbd.c3` main loop) — `GINTSTS.PRTINT`
  / `HPRT0.PRTCONNDET` could raise this too, but the ~1 s port poll is
  cheap and racing a hot-plug IRQ against the enumeration state machine
  is not worth it in v1. Stay polled.

---

## 5. Stages

### Stage 1 — PLIC + kernel wiring (no behaviour change)

Gated behind a new `const bool board::INTERRUPT_DRIVEN_USB = false`
(Duo) so every piece below is dead until it flips.

- `boards/duo/board.c3`:
  - `const uint IRQ_USB = 30;`
  - `const bool INTERRUPT_DRIVEN_USB = false;`
  - in `plic_init()`: `if (INTERRUPT_DRIVEN_USB && HAS_USB) { write
    priority word for IRQ_USB; set bit (1u << IRQ_USB) in the first
    enable word; }` — **must not touch the enable word when the flag is
    off** (the storm hazard).
- `boards/qemu/board.c3`: `IRQ_USB = 0` already present; add
  `INTERRUPT_DRIVEN_USB = false` for symbol parity. No-op (no DWC2).
- `src/process.c3`, `setup_usbd_mappings()`: map the three PLIC pages
  into usbd's page table (`board::PLIC_PRIORITY_PAGE`,
  `PLIC_ENABLE_PAGE`, `PLIC_CLAIM_PAGE`) — copy the three
  `map_device_page` lines from `setup_diskd_mappings`
  (`process.c3:713`). Harmless when the flag is off (usbd just never
  reads them).
- `src/entry.c3`, `handle_trap` external-interrupt branch
  (`entry.c3:2146`): add, mirroring the diskd and sdd blocks verbatim,

  ```c3
  if (irq == board::IRQ_USB && usbd_pid != 0)
  {
      Process* usbd_proc = proc_by_pid(usbd_pid);
      if (usbd_proc != null)
      {
          usbd_proc.msg_from    = 0;
          usbd_proc.msg_type    = DISKD_IRQ_NOTIFY; // opaque "your IRQ fired"
          usbd_proc.has_message = true;
          if (usbd_proc.state == PROC_BLOCKED) { usbd_proc.state = PROC_RUNNABLE; }
      }
  }
  ```

  Dead code until the PLIC actually delivers IRQ 30, which it can't
  until Stage 1's `plic_init` change is enabled. `usbd_pid` is already
  tracked (`process.c3`, `setup_usbd_mappings` tail).

Build both targets. Zero behaviour change with the flag off — this
stage is safe to commit once reviewed even though it can't be exercised.

### Stage 2 — DWC2 core interrupt enable (user side)

Gated behind a matching `const bool USBD_INTERRUPT_DRIVEN = false` in
`user/usb/dwc2.c3` (hand-synced with the board flag, the same way
`USB_MMIO_BASE` is duplicated today — user code can't see `board::`).

- Register constants to add: `USB_GINTMSK = 0x018`,
  `USB_GINTSTS_HCHINT = 1 << 25`, `USB_HAINT = 0x414`,
  `USB_HAINTMSK = 0x418`, `USB_HC0_HCINTMSK` already at `0x50C`.
- In `usbd_init()`, after `GAHBCFG`:
  `if (USBD_INTERRUPT_DRIVEN) { HCINTMSK ch0 |= CHHLTD; HAINTMSK |= (1
  << 0); GINTMSK |= HCHINT; }`
- Nothing else asserts — `GINTMSK` stays otherwise masked, so only a
  channel-halt on channel 0 raises the line. Matches the "one transfer
  in flight" invariant.

### Stage 3 — the wait conversion

`hc_wait_chhltd()` becomes:

```
if (!USBD_INTERRUPT_DRIVEN) { <today's yield()/HCINT loop, unchanged> }
else {
    start = rdtime()
    for (;;) {
        hcint = HCINT
        if (hcint & CHHLTD) { clear GINTSTS.HCHINT + HAINT ch0; *out = hcint; return 0 }
        if (rdtime()-start > 2s budget) { <timeout print>; return -1 }
        ipc_poll_type(&scratch, 0, &verb)   // drain the IRQ notify if present; ignore verb
        // no yield(): the poll itself is the pacing, exactly like diskd:192
    }
}
```

Note it still reads `HCINT` each pass — the notify is a *wakeup hint*,
not the source of truth (the DWC2 status bit is). This keeps it correct
even if an IRQ is missed or coalesced, and means Stage 3 can be
tested-by-reading against the polled path trivially: with the flag on
but `plic_init` left disabled, it degenerates to a busy-poll (no
`yield`) — slower, but should still enumerate, proving the control-flow
change in isolation before the PLIC is trusted.

### Stage 4 — usbd main-loop notify hygiene

A stray `DISKD_IRQ_NOTIFY` can land in usbd's inbox between transfers
(late IRQ, coalesced IRQ). `usb_msc_ipc_poll()` must not mistake it for
an MSC request. Add at the top of the main loop: peek with
`ipc_poll_type`; if `verb == DISKD_IRQ_NOTIFY`, consume and continue.
~5 lines.

### Stage 5 — hardware bring-up (blocked on §2)

Only possible once the Duo PLIC storm is solved. Enable both flags,
flash, and check:

- keyboard / mouse / MSC all still work (regression gate — the polled
  path is the reference).
- `plic_claim()` returns 30 when a transfer completes; no storm.
- transfer latency (time from channel-enable to `hc_wait_chhltd`
  return) drops versus the polled build.
- idle CPU: with devices attached but quiet, the idle `wfi` actually
  parks between the 4 ms polls instead of spinning usbd.

---

## 6. Files touched

| File | Change |
|---|---|
| `boards/duo/board.c3` | `IRQ_USB = 30`, `INTERRUPT_DRIVEN_USB`, `plic_init` enable (gated) |
| `boards/qemu/board.c3` | `INTERRUPT_DRIVEN_USB = false` (symbol parity) |
| `src/process.c3` | 3 PLIC `map_device_page` lines in `setup_usbd_mappings` |
| `src/entry.c3` | USB IRQ branch in `handle_trap` (mirror diskd/sdd) |
| `user/usb/dwc2.c3` | `USBD_INTERRUPT_DRIVEN`, GINTMSK/HAINTMSK/HCINTMSK enable, `hc_wait_chhltd` dual path, new register consts |
| `user/usb/usbd.c3` | main-loop notify drain (Stage 4) |
| `docs/devlog.md` | per session |

No new syscall. No new IPC verb (reuses `DISKD_IRQ_NOTIFY`). No change
to any device-layer file (`kbd.c3`, `msc.c3`, `xpad.c3`).

---

## 7. Why this session stopped at planning

- **Unverifiable now.** No QEMU DWC2, and hardware is AFK. The feature
  cadence (memory: "Feature cadence") requires verifying on real Duo
  before commit.
- **Blocked on the PLIC storm** (§2) — the interrupt path this depends
  on is itself an open hardware bug, and `plic_init`'s own comment says
  the PLIC *enable bit* is a live suspect. Adding a second enable-bit
  write there right now, unverified, could feed that fire.
- **Safety-critical surface.** The change touches `handle_trap` (the
  trap handler) and `plic_init`. Those are exactly the files the
  "verify on hardware, confirm before commit" rule exists to protect.
- **Modest benefit** (§1) — racccoon's wait is already cooperative;
  this is polish, not a fix. Not worth spending the unverifiable-change
  budget ahead of the PLIC storm and the ethernet-carrier work, both of
  which are higher value.

The implementation is small and fully specified above — a short session
once the PLIC path is trusted.
