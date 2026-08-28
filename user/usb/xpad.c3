module user;

// xpad: Xbox 360 wired controller (USB ID 045e:028e) specifics — the
// "what this one device means" layer for user/usb/usbd.c3's own
// orchestration, same split shape as user/net/dwmac.c3/ephy.c3 (MAC-
// generic vs. this-board's-PHY-specific) and user/fs/fat32.c3/ext2.c3
// (filesystem-generic core vs. one filesystem's own format) — every
// genuinely device-specific byte-format detail lives here, so
// user/usb/dwc2.c3 stays a generic USB host-controller layer, useful
// for any future device class.
//
// This controller does NOT use the standard USB HID class/report-
// descriptor mechanism — it's Microsoft's own proprietary "XInput"
// protocol: interface class 0xFF (vendor-specific), subclass 93
// (0x5D), protocol 1 for the wired pad specifically (protocol 129 is
// the wireless receiver's own, structurally different report format —
// out of scope here). This is exactly why Linux needs its own
// dedicated `xpad` driver instead of the generic `usbhid` one — same
// name chosen here on purpose.
//
// Sourced directly from the real Linux driver, not guessed or half-
// remembered: duo-buildroot-sdk's own linux_5.10/drivers/input/
// joystick/xpad.c — the USB-core `usb_device_id` match table
// (XPAD_XBOX360_VENDOR_PROTOCOL, class/subclass/protocol below), the
// `bNumEndpoints == 2` interface-identification guard, and
// xpad360_process_packet()'s own exact byte offsets/bitmasks for the
// wired report format.
//
// No initialization sequence needed beyond standard enumeration + one
// SET_CONFIGURATION (already how every other device this driver talks
// to gets configured) — confirmed by the real driver itself: zero
// control-transfer calls anywhere in its own XTYPE_XBOX360 code path,
// it just claims the interface and starts reading the interrupt IN
// endpoint directly.

const uint XPAD_VENDOR_ID  = 0x045E;
const uint XPAD_IFACE_CLASS    = 0xFF; // vendor-specific
const uint XPAD_IFACE_SUBCLASS = 93;   // 0x5D
const uint XPAD_IFACE_PROTOCOL = 1;    // wired pad — 129 is the wireless receiver, a different (unhandled) report format

// The real report is 20 bytes on the wire; buffers are sized more
// generously elsewhere (matching this driver's own general habit of
// over-allocating fixed buffers rather than trimming to the exact
// minimum).
const uint XPAD_REPORT_MIN_LEN = 14; // through the right-stick Y field, byte offset 12-13 — see xpad_parse_report() below

struct Xpad_state
{
    bool dpad_up;
    bool dpad_down;
    bool dpad_left;
    bool dpad_right;
    bool start;
    bool back;
    bool thumb_l;
    bool thumb_r;
    bool bumper_l;
    bool bumper_r;
    bool guide;
    bool a;
    bool b;
    bool x;
    bool y;
    uint trigger_l; // 0-255
    uint trigger_r; // 0-255
    int stick_lx;   // signed 16-bit range
    int stick_ly;
    int stick_rx;
    int stick_ry;
}

// Parses one wired-360 input report. Returns false for anything that
// isn't a real input report (byte 0 must be 0x00 — the real driver's
// own marker for "this is a controller-state report", other values
// are other message types this driver has no use for, e.g.
// rumble/LED acknowledgements) or is too short to be one.
fn bool xpad_parse_report(char* data, uint len, Xpad_state* out)
{
    if (len < XPAD_REPORT_MIN_LEN) { return false; }
    if (data[0] != (char)0x00) { return false; }

    uint b2 = (uint)data[2] & 0xFF;
    uint b3 = (uint)data[3] & 0xFF;

    out.dpad_up    = (b2 & 0x01) != 0;
    out.dpad_down  = (b2 & 0x02) != 0;
    out.dpad_left  = (b2 & 0x04) != 0;
    out.dpad_right = (b2 & 0x08) != 0;
    out.start      = (b2 & 0x10) != 0;
    out.back       = (b2 & 0x20) != 0;
    out.thumb_l    = (b2 & 0x40) != 0;
    out.thumb_r    = (b2 & 0x80) != 0;

    out.bumper_l = (b3 & 0x01) != 0;
    out.bumper_r = (b3 & 0x02) != 0;
    out.guide    = (b3 & 0x04) != 0;
    out.a        = (b3 & 0x10) != 0;
    out.b        = (b3 & 0x20) != 0;
    out.x        = (b3 & 0x40) != 0;
    out.y        = (b3 & 0x80) != 0;

    out.trigger_l = (uint)data[4] & 0xFF;
    out.trigger_r = (uint)data[5] & 0xFF;

    // Little-endian signed 16-bit sticks. Y axes are bitwise-NOT'd by
    // the real driver, not negated (`~(__s16)value`, not `-value`) —
    // replicated exactly; getting this wrong only shows up as an
    // off-by-one at the axis extremes, easy to miss without checking
    // against the real source.
    out.stick_lx = (int)(short)(((uint)data[6] & 0xFF) | (((uint)data[7] & 0xFF) << 8));
    out.stick_ly = (int)(short)~(((uint)data[8] & 0xFF) | (((uint)data[9] & 0xFF) << 8));
    out.stick_rx = (int)(short)(((uint)data[10] & 0xFF) | (((uint)data[11] & 0xFF) << 8));
    out.stick_ry = (int)(short)~(((uint)data[12] & 0xFF) | (((uint)data[13] & 0xFF) << 8));

    return true;
}

// Last decoded pad state, for the change detection in
// xpad_handle_report. Zeroed by xpad_reset_state() when usbd.c3 begins
// an xpad session.
Xpad_state g_xpad_last;

fn void xpad_reset_state()
{
    Xpad_state zero;
    g_xpad_last = zero;
}

fn void xpad_print_button_change(char* name, bool now, bool before)
{
    if (now == before) { return; }
    print("usbd: xpad: ");
    print(name);
    print(now ? " pressed\n" : " released\n");
}

// One interrupt-IN report from usbd.c3's cooperative HID poll. Prints
// every button / trigger / stick change since the last report, then
// stores it. No IPC / game-input subsystem — there's no consumer for
// that yet; this is still "prove the USB stack talks to the pad end to
// end," now without a for(;;) loop hogging usbd (docs/devlog.md).
fn void xpad_handle_report(char* report, uint len)
{
    Xpad_state state;
    if (!xpad_parse_report(report, len, &state)) { return; }

    xpad_print_button_change("A", state.a, g_xpad_last.a);
    xpad_print_button_change("B", state.b, g_xpad_last.b);
    xpad_print_button_change("X", state.x, g_xpad_last.x);
    xpad_print_button_change("Y", state.y, g_xpad_last.y);
    xpad_print_button_change("start", state.start, g_xpad_last.start);
    xpad_print_button_change("back", state.back, g_xpad_last.back);
    xpad_print_button_change("guide", state.guide, g_xpad_last.guide);
    xpad_print_button_change("LB", state.bumper_l, g_xpad_last.bumper_l);
    xpad_print_button_change("RB", state.bumper_r, g_xpad_last.bumper_r);
    xpad_print_button_change("L3", state.thumb_l, g_xpad_last.thumb_l);
    xpad_print_button_change("R3", state.thumb_r, g_xpad_last.thumb_r);
    xpad_print_button_change("dpad-up", state.dpad_up, g_xpad_last.dpad_up);
    xpad_print_button_change("dpad-down", state.dpad_down, g_xpad_last.dpad_down);
    xpad_print_button_change("dpad-left", state.dpad_left, g_xpad_last.dpad_left);
    xpad_print_button_change("dpad-right", state.dpad_right, g_xpad_last.dpad_right);

    if (state.trigger_l != g_xpad_last.trigger_l || state.trigger_r != g_xpad_last.trigger_r)
    {
        print("usbd: xpad: triggers l=");
        print_uint(state.trigger_l);
        print(" r=");
        print_uint(state.trigger_r);
        print("\n");
    }
    if (state.stick_lx != g_xpad_last.stick_lx || state.stick_ly != g_xpad_last.stick_ly
        || state.stick_rx != g_xpad_last.stick_rx || state.stick_ry != g_xpad_last.stick_ry)
    {
        print("usbd: xpad: sticks lx=");
        print_int(state.stick_lx);
        print(" ly=");
        print_int(state.stick_ly);
        print(" rx=");
        print_int(state.stick_rx);
        print(" ry=");
        print_int(state.stick_ry);
        print("\n");
    }

    g_xpad_last = state;
}
