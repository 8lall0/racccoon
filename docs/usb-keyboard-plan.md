# USB keyboard support — staged plan

Status: **planning only**, no code yet. Written 2026-08-28.

The goal: plug a plain USB keyboard into the Duo (through the powered hub
the test rig already uses) and type at the racccoon shell prompt, with
the serial console still working in parallel.

---

## 1. Why this is small

Everything hard is already done and proven on real Milk-V Duo hardware
(see `docs/devlog.md`, memory note "USB status"):

- DWC2 host controller bring-up, VBUS, pinmux, PHY clocks.
- Full enumeration: device + config descriptors, `SET_ADDRESS`,
  `SET_CONFIGURATION`, hub class, downstream-port power + reset,
  USB 2.0 split transactions for a full/low-speed device behind a
  high-speed hub.
- **Interrupt IN endpoint reads** — `usb_interrupt_poll()`, bInterval
  pacing, PID-toggle persistence — confirmed with a real USB mouse.
- A generic "read any interrupt IN endpoint and dump the report bytes"
  path (`usbd_generic_interrupt_read_loop`, `user/usb/usbd.c3:647`).
- A device-specific report-parser precedent: `user/usb/xpad.c3`
  (`Xpad_state` + `xpad_parse_report`).
- A generic control-transfer primitive: `usb_control_transfer(dev_addr,
  max_packet0, setup8, buf, len, is_in)` (`user/usb/dwc2.c3:1189`) —
  everything HID init needs.

A USB boot keyboard is a HID interrupt-IN device with an 8-byte report.
The remaining work is **three focused pieces** plus one structural
refactor.

---

## 2. What's missing

### A. Structural: cooperative HID polling

Today, once `usb_enumerate_device()` finds an interrupt endpoint it calls
`usbd_generic_interrupt_read_loop()` / `usbd_xpad_read_loop()`, which are
`for (;;)` loops that **never return** — usbd then stops enumerating,
stops serving MSC IPC, stops hub polling. Fine for "prove it works",
wrong for a keyboard that must coexist with everything else.

Fix: store the active HID endpoint in module state
(`{dev_addr, ep_num, max_packet, interval_ms, pid_toggle}` + last report)
at enumeration time instead of entering a loop, and add a single-shot
`usb_hid_poll()` call to `main()`'s loop (`user/usb/usbd.c3:797`).

`main()`'s loop currently ticks at ~100 ms (MSC IPC + hub poll). A
keyboard's bInterval is ~8–10 ms and fast typing is ~125 ms/keystroke —
100 ms is too coarse and would drop keys. So the loop needs a **split
cadence**: poll the HID endpoint every ~16 ms, keep MSC IPC / hub poll /
HPRT diagnostics on their existing ~100 ms–1 s schedules, each gated on
its own next-due timestamp. Still one `yield()`-paced loop, same
deadlock reasoning as the existing comment at `usbd.c3:842`.

### B. `user/usb/kbd.c3` — the HID boot-keyboard layer

Modeled on `xpad.c3`. Contents:

- Interface match constants: HID class `0x03`, boot subclass `0x01`,
  keyboard protocol `0x01`.
- `Kbd_report` = the 8 boot-protocol bytes: `[0]` modifier bitmap
  (LCtrl/LShift/LAlt/LGui/RCtrl/RShift/RAlt/RGui), `[1]` reserved,
  `[2..7]` up to six pressed HID usage IDs.
- `kbd_diff(prev, cur, out_chars, out_n)` — a key is *newly pressed* if
  its usage ID is in `cur[2..7]` but not `prev[2..7]`. Emit a byte per
  newly-pressed key. Ignore a report whose `[2]` is `0x01`
  (ErrorRollOver).
- `kbd_usage_to_ascii(usage, modifiers)` — a static US-layout table:
  - `0x04..0x1D` → `a..z` (upper if Shift, unaffected by Caps in v1),
  - `0x1E..0x27` → `1..0` / `!@#$%^&*()` with Shift,
  - `0x28` Enter → `\n`, `0x2A` Backspace → `0x08`, `0x2B` Tab → `\t`,
    `0x2C` Space → ` `, `0x2D..0x38` the `-=[]\;'`,./` cluster + Shift
    variants,
  - Ctrl + `a..z` → control codes `0x01..0x1A` (so Ctrl-C etc. reach the
    shell the same as over serial),
  - arrows/Esc `0x29`,`0x4F..0x52` → the same escape sequences the shell
    already decodes from serial (`user/shell.c3:22` notes it handles
    these) — emit `ESC [ C` / `ESC [ D` etc.
  - unmapped usage → produce nothing.

### C. HID initialization (one-time, at enumeration)

Two control transfers via `usb_control_transfer`, built as raw setup
packets:

- `SET_PROTOCOL(0)` — `bmRequestType 0x21`, `bRequest 0x0B`,
  `wValue 0` (boot), `wIndex = iface_num`, no data. Forces boot report
  format regardless of the keyboard's default.
- `SET_IDLE(0)` — `bmRequestType 0x21`, `bRequest 0x0A`, `wValue 0`,
  `wIndex = iface_num`, no data. "Report only on change" — avoids a
  stream of identical reports. Consequence: no hardware auto-repeat (see
  §4).

`GET_REPORT` / the HID report descriptor are **not** needed — boot
protocol has a fixed layout.

### D. Delivery to the shell — kernel keystroke queue

The shell reads input through `SYS_GETCHAR`, which loops in-kernel on
`board::console_getchar()` (`src/entry.c3:436`). Add a second source:

- A small ring buffer in the kernel (~64 bytes), e.g. in a new
  `src/kernel/kbd.c3` or inline in `entry.c3`.
- New syscall **`SYS_KBD_PUSH` (= 31)** — usbd pushes decoded ASCII/escape
  bytes. Producer side only; ~15 lines in `entry.c3` + the mirrored
  `const` in `user.c3`, same as every syscall 28–30.
- `SYS_GETCHAR`'s wait loop drains the kbd ring first, then falls back to
  `console_getchar()`. **The shell and every other consumer need zero
  changes** — serial and USB both feed the same character stream.

This matches the existing "kernel mediates console I/O" model and avoids
giving the shell a dependency on usbd's pid.

### E. Dispatch wiring

In `usb_enumerate_hub_device()` (`usbd.c3`, the XPAD → MSC → generic
chain around line 476–636), insert a HID-keyboard check
(`usb_find_interface(cfg, 256, 0x03, 0x01, 0x01, ...)`) **before** the
generic-any-interrupt-in fallback. First match wins, as today. Composite
keyboards (keyboard + consumer-control + mouse interfaces) match on the
boot-keyboard interface and the rest are ignored.

---

## 3. Stages

### Stage 1 — cooperative HID poll refactor — **BUILT, hardware-verify pending**
Store endpoint state, add `usb_hid_poll()` + split-cadence loop, keep the
existing behaviour: still just `print()` the raw report bytes for now.
**Verify (Duo):** plug the known-good mouse — reports still print, *and*
MSC IPC / hub hot-plug still work afterwards (plug a USB stick after the
mouse, `mountusb` still succeeds). This de-risks the refactor before any
keyboard code exists.

Done in `user/usb/usbd.c3` (devlog 2026-08-28): `g_hid_*` session state +
`usb_hid_begin_session` / `usb_hid_poll` / `usb_hid_clear_session`
mirroring `msc.c3`; `usbd_generic_interrupt_read_loop` deleted; `main()`
idle tail pumps `usb_hid_poll()`; `usb_poll_hub_ports` asserts non-split
up front. QEMU + Duo builds clean. Not yet run on hardware.

### Stage 2 — `kbd.c3` parse + decode, print to console — **DONE, verified on real Duo**
`user/usb/kbd.c3` (`kbd_handle_report` / `kbd_usage_to_bytes` /
`kbd_emit` / `g_kbd_prev`); `dwc2.c3` `usb_hid_set_protocol` +
`usb_hid_set_idle` + `usb_iface_first_interrupt_in`; `usbd.c3`
`g_hid_is_keyboard` + HID `3/1/1` dispatch branch.

Confirmed on hardware 2026-08-28: low-speed keyboard on the hub, all
keys decode correctly on serial (letters, Shift, `!@#$%`, Enter). Fixed
a split-context leak the same session (`usb_set_split_context(false,…)`
now asserted before every hub-directed transfer — was causing a
GET_PORT_STATUS STALL right after keyboard enum). See devlog.

### Stage 3 — kernel keystroke queue, real shell input — **DONE, QEMU-verified; Duo check pending**
Add `SYS_KBD_PUSH` + the ring buffer + the `SYS_GETCHAR` drain. usbd
pushes instead of printing.
**Verify (Duo):** at the `>` prompt, type `ls` on the USB keyboard, press
Enter — it runs. Backspace edits the line. Serial console still works at
the same time. (Ctrl-C has no effect — racccoon has no SIGINT; `0x03`
just enters the line buffer, same as over serial.)

Done + **verified on real Duo** (devlog 2026-08-28): `src/kbd.c3` ring
buffer, `SYS_KBD_PUSH` (=31), `SYS_GETCHAR` drains the queue then the
serial console, `kbd_emit()` pushes. `kbdpush` shell_test builtin.
Typing at the `>` prompt works, `ls` runs.

### Stage 4 — polish
- Caps Lock: track state from the keyboard's Caps usage (`0x39`), XOR
  with Shift for letters. Optionally drive the Caps Lock LED via
  `SET_REPORT` (`bmRequestType 0x21`, `bRequest 0x09`, 1 data byte).
- Software auto-repeat: if a key is still held N ms later (tracked
  against the last report + a timestamp), re-emit it, then every M ms.
- Devlog entry, memory note, commit.

---

## 4. Known limitations (documented, not bugs)

| Limitation | Note |
|---|---|
| US QWERTY layout only | non-US keys produce US symbols; a layout table swap is a later job |
| No auto-repeat until Stage 4 | `SET_IDLE(0)` disables hardware repeat; v1 = one char per press |
| 6-key rollover | boot protocol caps at 6 simultaneous keys; fine for a shell |
| Real-Duo-only | QEMU `virt` has no DWC2 (`board::HAS_USB` is Duo-only) — no QEMU leg to this, same as the rest of the USB stack |
| One keyboard + one mouse | two session slots (`Hid_session[2]`); a 2nd device of the *same* kind overwrites its slot |
| Combo receiver (kbd+mouse in one device) | matches the mouse branch → its keyboard interface goes unpolled; real fix is binding both interfaces of one device to their own slots |

---

## 5. Files touched

- `user/usb/kbd.c3` — **new**, ~150 lines (mostly the keycode table)
- `user/usb/usbd.c3` — endpoint state, `usb_hid_poll()`, split-cadence
  loop, dispatch entry, replace the infinite read loop
- `user/usb/dwc2.c3` — maybe a `usb_hid_set_protocol()` / `usb_hid_set_idle()`
  helper (or build the setup packets in `kbd.c3`)
- `src/entry.c3` — `SYS_KBD_PUSH` case, ring buffer, `SYS_GETCHAR` drain
- `src/kernel/kbd.c3` — **new** (optional), the ring buffer
- `user/user.c3` — `const SYS_KBD_PUSH = 31`
- `scripts/build_user.sh` — add `user/usb/kbd.c3` to the `usbd` line
- No `board.c3` change (no new MMIO, no new IRQ — reuses the USB stack)
- No `kernel.c3` / `process.c3` change (usbd already spawned + mapped)
