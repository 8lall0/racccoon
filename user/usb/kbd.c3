module user;

// kbd: USB HID boot-protocol keyboard — the "what the 8 report bytes
// mean" layer for user/usb/usbd.c3, same device/class split as
// user/usb/xpad.c3 (gamepad) and user/usb/msc.c3 (mass storage). All
// wire-level work (control/interrupt transfers, the g_hid session and
// its cooperative poll) stays in dwc2.c3/usbd.c3.
//
// Boot protocol (USB HID 1.11, Appendix B.1): a FIXED 8-byte input
// report, so no report-descriptor parsing is needed — usbd.c3 issues
// SET_PROTOCOL(0) at enumeration to select it.
//   [0] modifier bitmap: bit0 LCtrl, 1 LShift, 2 LAlt, 3 LGui,
//                        4 RCtrl, 5 RShift, 6 RAlt, 7 RGui
//   [1] reserved (OEM)
//   [2..7] up to six usage IDs of currently-held keys (HID Usage Table
//          "Keyboard/Keypad" page, 0x07). 0x00 = slot empty. 0x01 in
//          any slot = ErrorRollOver (more keys held than the array can
//          report) — the whole report is meaningless, skip it.
//
// A key is "held" for as long as its usage ID stays in [2..7]; the
// press *event* is the transition into that set (diff against the
// previous report). Releases aren't surfaced — a console has no use for
// them.
//
// SET_IDLE(0) turns off the keyboard's own hardware key-repeat (so a
// held key produces no new reports at all), so kbd_tick() below does
// repeat in software: usbd.c3 calls it on every keyboard poll, held-key
// or not.
//
// US QWERTY layout only. Non-US keys produce the US symbol at that
// scancode — a layout-table swap is future work, not a bug.

// Interface match (USB_CLASS_HID / USB_HID_SUBCLASS_BOOT /
// USB_HID_PROTOCOL_KEYBOARD) lives in dwc2.c3 with the other class
// constants — usbd.c3's dispatch is what uses it.

const uint KBD_REPORT_LEN = 8;
const uint KBD_KEY_SLOTS  = 6; // [2..7]
const uint KBD_USAGE_ERR_ROLLOVER = 0x01;
const uint KBD_USAGE_CAPS_LOCK    = 0x39;

// Modifier bitmap ([0]) bits.
const uint KBD_MOD_LSHIFT = 0x02;
const uint KBD_MOD_RSHIFT = 0x20;
const uint KBD_MOD_LCTRL  = 0x01;
const uint KBD_MOD_RCTRL  = 0x10;

// Number-row scancodes 0x1E..0x27 = 1 2 3 4 5 6 7 8 9 0, and their
// shifted symbols. Index = usage - 0x1E.
const char[10] KBD_DIGITS  = "1234567890";
const char[10] KBD_SYMBOLS = "!@#$%^&*()";

// Output-report LED bitmap (boot keyboard): bit0 NumLock, bit1
// CapsLock, bit2 ScrollLock. usbd.c3 SET_REPORTs g_kbd_led_state to the
// keyboard whenever g_kbd_led_dirty is set.
const char KBD_LED_CAPS = 0x02;

// USB_TIMEBASE_HZ (dwc2.c3) is 25 MHz on the Duo -> 25000 ticks/ms.
const ulong KBD_REPEAT_DELAY_TICKS    = 500 * (ulong)(USB_TIMEBASE_HZ / 1000); // ~500 ms before repeat starts
const ulong KBD_REPEAT_INTERVAL_TICKS = 40  * (ulong)(USB_TIMEBASE_HZ / 1000); // ~40 ms between repeats (~25/s)

// Previous report, for press-edge detection. Zeroed by kbd_reset_state()
// at the start of each session (usbd.c3's keyboard-dispatch branch).
char[8] g_kbd_prev;

// Caps Lock: a sticky toggle, flipped on each press of usage 0x39.
// Affects letter case only (XORs with Shift), never digits/symbols.
bool g_kbd_caps_lock;
char g_kbd_led_state;   // current LED bitmap
bool g_kbd_led_dirty;   // usbd.c3 clears this after pushing g_kbd_led_state to the device

// Software auto-repeat: the one held key currently eligible to repeat
// (0 = none), the modifiers to repeat it with, and when the next repeat
// is due.
uint  g_kbd_repeat_usage;
uint  g_kbd_repeat_mods;
ulong g_kbd_repeat_at;

fn void kbd_reset_state()
{
    for (uint i = 0; i < KBD_REPORT_LEN; i++) { g_kbd_prev[i] = (char)0; }
    g_kbd_caps_lock     = false;
    g_kbd_led_state     = (char)0;
    g_kbd_led_dirty     = false; // most keyboards power up with LEDs off; first Caps toggle syncs it
    g_kbd_repeat_usage  = 0;
    g_kbd_repeat_mods   = 0;
    g_kbd_repeat_at     = 0;
}

// Was `usage` present in the six key slots of `slots` (a pointer at
// report byte [2])? Used to tell a newly-pressed key from a held one.
fn bool kbd_usage_held(char* slots, uint usage)
{
    for (uint i = 0; i < KBD_KEY_SLOTS; i++)
    {
        if (((uint)slots[i] & 0xFF) == usage) { return true; }
    }
    return false;
}

// Translate one HID keyboard usage ID + the current modifier byte into
// the byte(s) it produces, written to `out` (needs room for 3).
// Returns the count, or 0 for a key this layer doesn't map (pure
// modifiers, Caps/Num/Scroll Lock, F-keys, keypad, ...).
fn uint kbd_usage_to_bytes(uint usage, uint mods, char* out)
{
    bool shift = (mods & (KBD_MOD_LSHIFT | KBD_MOD_RSHIFT)) != 0;
    bool ctrl  = (mods & (KBD_MOD_LCTRL  | KBD_MOD_RCTRL))  != 0;

    // Letters a-z (0x04..0x1D).
    if (usage >= 0x04 && usage <= 0x1D)
    {
        uint letter = usage - 0x04; // 0..25
        if (ctrl)
        {
            // Ctrl-A..Ctrl-Z -> 0x01..0x1A, so Ctrl-C etc. reach the
            // shell exactly as they do over the serial console.
            out[0] = (char)(0x01 + letter);
            return 1;
        }
        // Caps Lock inverts Shift for letters only.
        bool upper = shift != g_kbd_caps_lock;
        out[0] = (char)((upper ? 0x41 : 0x61) + letter); // 'A' / 'a'
        return 1;
    }

    // Number row (0x1E..0x27).
    if (usage >= 0x1E && usage <= 0x27)
    {
        uint idx = usage - 0x1E;
        out[0] = shift ? KBD_SYMBOLS[idx] : KBD_DIGITS[idx];
        return 1;
    }

    switch (usage)
    {
        case 0x28: out[0] = (char)'\r';  return 1; // Enter — shell ends a line on CR
        case 0x29: out[0] = (char)0x1B;  return 1; // Esc
        case 0x2A: out[0] = (char)0x08;  return 1; // Backspace
        case 0x2B: out[0] = (char)'\t';  return 1; // Tab
        case 0x2C: out[0] = (char)' ';   return 1; // Space
        case 0x2D: out[0] = (char)(shift ? '_'  : '-');  return 1;
        case 0x2E: out[0] = (char)(shift ? '+'  : '=');  return 1;
        case 0x2F: out[0] = (char)(shift ? '{'  : '[');  return 1;
        case 0x30: out[0] = (char)(shift ? '}'  : ']');  return 1;
        case 0x31: out[0] = (char)(shift ? '|'  : '\\'); return 1;
        case 0x33: out[0] = (char)(shift ? ':'  : ';');  return 1;
        case 0x34: out[0] = (char)(shift ? '"'  : '\''); return 1;
        case 0x35: out[0] = (char)(shift ? '~'  : '`');  return 1;
        case 0x36: out[0] = (char)(shift ? '<'  : ',');  return 1;
        case 0x37: out[0] = (char)(shift ? '>'  : '.');  return 1;
        case 0x38: out[0] = (char)(shift ? '?'  : '/');  return 1;
        // Arrow keys -> ANSI cursor sequences (ESC [ A/B/C/D). The
        // production shell doesn't act on these yet, but emitting the
        // standard bytes is the right thing and costs nothing.
        case 0x4F: out[0] = (char)0x1B; out[1] = (char)'['; out[2] = (char)'C'; return 3; // Right
        case 0x50: out[0] = (char)0x1B; out[1] = (char)'['; out[2] = (char)'D'; return 3; // Left
        case 0x51: out[0] = (char)0x1B; out[1] = (char)'['; out[2] = (char)'B'; return 3; // Down
        case 0x52: out[0] = (char)0x1B; out[1] = (char)'['; out[2] = (char)'A'; return 3; // Up
        default: return 0;
    }
}

// A decoded keystroke byte goes into the kernel keystroke queue
// (SYS_KBD_PUSH, src/kbd.c3), which SYS_GETCHAR drains alongside the
// serial console — so it reaches the shell exactly as a typed serial
// byte would, and the shell's own echo puts it on screen. A full queue
// (only under an extreme backlog) drops the byte; log that, since a
// silently-swallowed keystroke is otherwise a mystery.
fn void kbd_emit(char c)
{
    if (syscall(SYS_KBD_PUSH, (long)((uint)c & 0xFF), 0, 0) != 0)
    {
        print("usbd: kbd: keystroke queue full, byte dropped\n");
    }
}

fn void kbd_emit_usage(uint usage, uint mods)
{
    char[3] bytes @noinit;
    uint n = kbd_usage_to_bytes(usage, mods, &bytes[0]);
    for (uint k = 0; k < n; k++) { kbd_emit(bytes[k]); }
}

// The held key (last non-empty slot that maps to real bytes) that
// auto-repeat should track — 0 if none. Last-slot heuristic: for the
// common 1-2 key case it's the most recently pressed, which is the
// key a user expects to repeat.
fn uint kbd_repeat_candidate(char* report, uint mods)
{
    uint cand = 0;
    for (uint i = 2; i < KBD_REPORT_LEN; i++)
    {
        uint usage = (uint)report[i] & 0xFF;
        if (usage == 0 || usage == KBD_USAGE_ERR_ROLLOVER) { continue; }
        char[3] scratch @noinit;
        if (kbd_usage_to_bytes(usage, mods, &scratch[0]) > 0) { cand = usage; }
    }
    return cand;
}

// One 8-byte boot report from usb_hid_poll_slot(). Emits a keystroke
// for every key newly held vs. the previous report, toggles Caps Lock,
// updates the auto-repeat target, then stores the report.
fn void kbd_handle_report(char* report, uint len)
{
    if (len < KBD_REPORT_LEN) { return; } // not a boot-protocol report

    // ErrorRollOver: keep g_kbd_prev untouched so the keys still down
    // when the overflow clears aren't re-fired as fresh presses.
    if (((uint)report[2] & 0xFF) == KBD_USAGE_ERR_ROLLOVER) { return; }

    uint mods = (uint)report[0] & 0xFF;

    for (uint i = 2; i < KBD_REPORT_LEN; i++)
    {
        uint usage = (uint)report[i] & 0xFF;
        if (usage == 0 || usage == KBD_USAGE_ERR_ROLLOVER) { continue; }
        if (kbd_usage_held(&g_kbd_prev[2], usage)) { continue; } // already down last time

        if (usage == KBD_USAGE_CAPS_LOCK)
        {
            g_kbd_caps_lock = !g_kbd_caps_lock;
            g_kbd_led_state = g_kbd_caps_lock ? KBD_LED_CAPS : (char)0;
            g_kbd_led_dirty = true;
            continue;
        }

        kbd_emit_usage(usage, mods);
    }

    // Auto-repeat target: whichever mapped key is held now. A change of
    // target (new key, or the old one released) restarts the initial
    // delay; the same key held just keeps its modifiers fresh (so
    // adding/removing Shift mid-hold is honoured).
    uint cand = kbd_repeat_candidate(report, mods);
    if (cand != g_kbd_repeat_usage)
    {
        g_kbd_repeat_usage = cand;
        g_kbd_repeat_mods  = mods;
        if (cand != 0) { g_kbd_repeat_at = rdtime() + KBD_REPEAT_DELAY_TICKS; }
    }
    else if (cand != 0)
    {
        g_kbd_repeat_mods = mods;
    }

    for (uint i = 0; i < KBD_REPORT_LEN; i++) { g_kbd_prev[i] = report[i]; }
}

// Called on every keyboard poll (usbd.c3), report or not — drives
// software auto-repeat for a held key.
fn void kbd_tick()
{
    if (g_kbd_repeat_usage == 0) { return; }
    ulong now = rdtime();
    if (now < g_kbd_repeat_at) { return; }
    kbd_emit_usage(g_kbd_repeat_usage, g_kbd_repeat_mods);
    g_kbd_repeat_at = now + KBD_REPEAT_INTERVAL_TICKS;
}
