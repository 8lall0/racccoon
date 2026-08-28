module user;

import std::nolibc::main_stub;

// usbd: orchestration only — main()'s own connect/disconnect polling
// loop and usb_enumerate_device()'s own enumeration/hub-walking logic.
// Everything register-level (DWC2 core bring-up, host-channel transfer
// engine, USB/hub-class request builders) lives in user/usb/dwc2.c3
// instead — this is the file that reads like "what usbd actually
// does," split out once dwc2.c3 grew large enough that "the part that
// talks to the wire" and "the part that decides what to do next" were
// hard to tell apart in one file (docs/devlog.md).
//
// Confirmed working on real hardware, before and after this split:
// host-mode bring-up (HPRT0 connect/disconnect detection) and full
// device enumeration (including through the Duo IO board's own
// onboard hub) — see dwc2.c3's own header comment for full sourcing.

// Real-hardware A/B round (docs/devlog.md): with the current
// microframe-precise split-interrupt scheduler, shared-TT mode
// produced the exact same result as multi-TT (byte-identical
// complete-split NAKs) — ruling this out as the interrupt-split IN
// differentiator. Back to true, the spec-correct default for a
// multi-TT-capable hub (see this constant's own use, below).
const bool USBD_MULTI_TT_SWITCH = true;

// Hub-downstream hot-plug state — set once after the root-port hub
// itself is enumerated (usb_enumerate_device's own hub branch), then
// consulted every ~1s by usb_poll_hub_ports() (main()'s own polling
// loop) to notice a device plugged into one of the hub's OWN ports
// *after* that one-time initial walk already ran. Real gap this
// project never had before: the initial walk only ever looked at
// whatever was already plugged in at the moment the hub itself finished
// enumerating — a device plugged into the hub any time after that was
// never noticed at all, silently, regardless of how long main()'s own
// root-port polling loop kept running. USB_HUB_MAX_PORTS_TRACKED (8) is
// generous headroom over the real IO board hub's own 4 ports.
const uint USB_HUB_MAX_PORTS_TRACKED = 8;
uint g_hub_addr = 0; // 0 = no hub known yet (root device wasn't a hub, or hasn't enumerated)
uint g_hub_max_packet0 = 0;
uint g_hub_num_ports = 0;
bool g_hub_root_is_high_speed = false;
bool[8] g_hub_port_connected; // index 0 unused (ports are 1-based); sized to USB_HUB_MAX_PORTS_TRACKED

// Active HID interrupt-IN devices (keyboard + mouse) — the cooperative
// equivalent of msc.c3's own g_msc_* session state. A session is
// established by usb_hid_begin_session() when
// usb_enumerate_hub_port_device() recognizes a boot keyboard/mouse (or
// any other interrupt-IN device), polled one shot at a time by
// usb_hid_poll() from main()'s loop, cleared on disconnect by
// usb_hid_clear_session(). Replaces the old
// usbd_generic_interrupt_read_loop(): that was a for(;;) that never
// returned, so a single plugged-in mouse froze usb_msc_ipc_poll() and
// usb_poll_hub_ports() dead (docs/devlog.md, USB keyboard planning).
//
// Two slots: HID_SLOT_KEYBOARD and HID_SLOT_OTHER (mouse / generic), so
// a keyboard and a mouse work at the same time — a normal desk setup.
// A second device of the same kind overwrites its slot (still a real
// limitation, but a rare one). split_* is the device's own
// split-transaction context, captured at begin-session and re-asserted
// before every poll: usb_msc_ipc_poll() and hub (re-)enumeration both
// overwrite dwc2.c3's global g_split_* in between our polls.
struct Hid_session
{
    bool present;
    bool is_keyboard;   // true -> reports go to kbd.c3; false -> raw hex dump
    uint hub_port;
    uint dev_addr;
    uint ep_num;
    uint max_packet;
    uint pid_toggle;
    ulong interval_ticks;
    ulong next_due;      // rdtime() value the next poll is due at
    uint report_count;
    uint ctrl_max_packet; // EP0 max packet — keyboard-only, for SET_REPORT (Caps Lock LED)
    uint iface_num;       // keyboard-only, wIndex for its HID class requests
    bool split_active;
    uint split_hub_addr;
    uint split_hub_port;
    bool split_low_speed;
}

const uint HID_SLOT_KEYBOARD = 0;
const uint HID_SLOT_OTHER    = 1;
const uint HID_SLOT_COUNT    = 2;
Hid_session[HID_SLOT_COUNT] g_hid;

// Re-checks every known hub port for a connection state change since
// the last check — the same GetPortStatus this file's own initial hub
// walk already does, just repeated. A newly-connected port gets the
// exact same usb_enumerate_hub_port_device() call the initial walk
// uses; a newly-empty port just clears its own tracked state (so a
// later re-plug on that same port is noticed too). No-op if the root
// device was never a hub (g_hub_addr stays 0 in that case).
fn void usb_poll_hub_ports()
{
    if (g_hub_addr == 0) { return; }

    uint ports = g_hub_num_ports < USB_HUB_MAX_PORTS_TRACKED ? g_hub_num_ports : USB_HUB_MAX_PORTS_TRACKED - 1;
    for (uint port = 1; port <= ports; port++)
    {
        // GetPortStatus talks straight to the hub — never a split
        // transaction. Reset the context first, every iteration: an
        // active HID session (usb_hid_poll) leaves dwc2.c3's global
        // g_split_* pointing at its own downstream device, and a
        // hot-plug enumerate on an *earlier* port in this same loop can
        // leave it pointing at a low-speed device — a real STALL on the
        // next port's status read otherwise (docs/devlog.md).
        // usb_hid_poll() re-asserts the HID context on its next pass.
        usb_set_split_context(false, 0, 0, false);

        char[4] port_status;
        if (!usb_get_port_status(g_hub_addr, g_hub_max_packet0, port, &port_status[0])) { continue; }

        bool now_connected = ((uint)port_status[0] & 0x1) != 0;
        if (now_connected && !g_hub_port_connected[port])
        {
            g_hub_port_connected[port] = true;
            print("usbd: hub port ");
            print_uint(port);
            print(": hot-plug detected\n");
            usb_enumerate_hub_port_device(g_hub_addr, g_hub_max_packet0, port, g_hub_root_is_high_speed);
        }
        else if (!now_connected && g_hub_port_connected[port])
        {
            g_hub_port_connected[port] = false;
            print("usbd: hub port ");
            print_uint(port);
            print(": disconnected\n");
            usb_msc_clear_session(port);
            usb_hid_clear_session(port);
        }
    }
}

// Orchestrates a full enumeration: bus reset -> read enough of the
// device descriptor to learn bMaxPacketSize0 -> SET_ADDRESS -> read
// the full device descriptor at the new address -> if it's a hub
// (the expected case, given the IO board's own onboard hub — see
// docs/devlog.md), fetch the hub descriptor and GET_PORT_STATUS every
// downstream port, printing what's plugged in behind it. Called from
// main()'s own polling loop on a real, debounced connect event — not
// at init time (see this file's own earlier history for why an
// unconditional reset-at-init caused a false-positive latch).
fn void usb_enumerate_device()
{
    print("usbd: enumerating device...\n");

    // Real bus reset — required by the USB 2.0 spec before a freshly
    // connected device will respond to anything at all. 50ms pulse is
    // the spec minimum; U-Boot's own dwc2_init_common() uses the same
    // value.
    uint hprt0 = usb_reg_read(USB_HPRT0);
    hprt0 &= ~USB_HPRT0_W1C_MASK;
    hprt0 |= USB_HPRT0_PRTRST;
    usb_reg_write(USB_HPRT0, hprt0);
    ulong rst_start = rdtime();
    while (rdtime() - rst_start < usb_us_to_ticks(50000)) { yield(); }
    hprt0 = usb_reg_read(USB_HPRT0);
    hprt0 &= ~(USB_HPRT0_W1C_MASK | USB_HPRT0_PRTRST);
    usb_reg_write(USB_HPRT0, hprt0);

    // Settle delay — U-Boot's own dwc2_init_common() comment: "gives
    // the host controller a bit time... fixes the USB detection
    // problems with some problematic USB keys," 1 full second. Matched
    // exactly rather than trimmed, since this whole path is untested
    // on real hardware yet.
    ulong settle_start = rdtime();
    while (rdtime() - settle_start < usb_us_to_ticks(1000000)) { yield(); }

    print_hprt0_raw("post-enum-reset");

    char[18] desc_buf;

    // Bootstrap MPS0 for the very first transfer, before we've read
    // any descriptor at all. For full/low-speed devices this is
    // genuinely ambiguous (bMaxPacketSize0 can be 8/16/32/64) hence
    // the traditional "assume 8, it's always safe" trick — but for a
    // HIGH-SPEED device, USB 2.0 spec section 5.5.3 makes EP0's MPS0 a
    // fixed, guaranteed 64, not something to discover at all. A real
    // hardware round hit a persistent (non-transient, all 3 retries
    // identical) STALL on this exact request while HPRT0.PRTSPD read
    // 0 (high-speed, confirmed via print_hprt0_raw above) — using 8
    // instead of the spec-mandated 64 here is a real, concrete
    // mismatch between what this driver tells the host channel to
    // expect and what a genuinely high-speed device expects on the
    // wire, and a plausible explanation for exactly that failure.
    uint bootstrap_mps0 = ((hprt0 & USB_HPRT0_PRTSPD_MASK) >> USB_HPRT0_PRTSPD_SHIFT) == 0 ? 64 : 8;
    print("usbd: bootstrap MPS0=");
    print_uint(bootstrap_mps0);
    print(" (");
    print(bootstrap_mps0 == 64 ? "high-speed, spec-fixed" : "full/low-speed, safe default");
    print(")\n");

    // Retried up to 3 times on failure — kept even after the MPS0 fix
    // above, since a transient STALL on the very first post-reset
    // request is also a real, independently known possibility (real
    // USB host stacks retry this for the same reason, e.g. Linux's own
    // usbcore).
    bool got_initial_desc = false;
    for (int attempt = 0; attempt < 3; attempt++)
    {
        if (usb_get_descriptor(0, bootstrap_mps0, USB_DESC_TYPE_DEVICE, 0, &desc_buf[0], 8))
        {
            got_initial_desc = true;
            break;
        }
        print("usbd: initial GET_DESCRIPTOR(8) attempt ");
        print_uint((uint)(attempt + 1));
        print(" failed, retrying\n");
        ulong retry_start = rdtime();
        while (rdtime() - retry_start < usb_us_to_ticks(100000)) { yield(); }
    }
    if (!got_initial_desc)
    {
        print("usbd: enumeration failed: initial GET_DESCRIPTOR(8) (all attempts)\n");
        return;
    }
    uint max_packet0 = (uint)desc_buf[7] & 0xFF;
    print("usbd: bMaxPacketSize0=");
    print_uint(max_packet0);
    print("\n");

    if (!usb_set_address(max_packet0, USB_ENUM_ADDR))
    {
        print("usbd: enumeration failed: SET_ADDRESS\n");
        return;
    }

    // SetAddress recovery interval — USB 2.0 spec requires the host
    // wait at least 2ms before expecting the device to respond at its
    // new address; a generous 10ms margin here.
    ulong addr_settle = rdtime();
    while (rdtime() - addr_settle < usb_us_to_ticks(10000)) { yield(); }

    if (!usb_get_descriptor(USB_ENUM_ADDR, max_packet0, USB_DESC_TYPE_DEVICE, 0, &desc_buf[0], 18))
    {
        print("usbd: enumeration failed: GET_DESCRIPTOR(18) at new address\n");
        return;
    }

    uint device_class = (uint)desc_buf[4] & 0xFF;
    uint vendor_id  = ((uint)desc_buf[8]  & 0xFF) | (((uint)desc_buf[9]  & 0xFF) << 8);
    uint product_id = ((uint)desc_buf[10] & 0xFF) | (((uint)desc_buf[11] & 0xFF) << 8);

    print("usbd: enumerated device: class=0x");
    print_hex8(device_class);
    print(" vid=0x");
    print_hex8((vendor_id >> 8) & 0xFF);
    print_hex8(vendor_id & 0xFF);
    print(" pid=0x");
    print_hex8((product_id >> 8) & 0xFF);
    print_hex8(product_id & 0xFF);
    print("\n");

    if (device_class == USB_CLASS_HUB)
    {
        print("usbd: device is a hub — fetching hub descriptor and per-port status\n");

        // SET_CONFIGURATION — required by USB 2.0 spec before most
        // per-port hub operations are valid; GetHubDescriptor above is
        // allowed in the unconfigured "Address" state, but
        // GetPortStatus is not. Hardcoded to configuration 1 (this
        // driver never fetches the configuration descriptor at all —
        // basic hubs almost universally have exactly one configuration,
        // and Phase 2's own scope doesn't need anything from that
        // descriptor beyond confirming this).
        if (!usb_set_configuration(USB_ENUM_ADDR, max_packet0, 1))
        {
            print("usbd: SET_CONFIGURATION failed\n");
            return;
        }

        // Real, sourced gap this driver never closed before (see
        // usb_set_interface's own comment, dwc2.c3): a Hi-Speed hub
        // reporting bDeviceProtocol==2 (multi-TT capable) defaults to
        // shared-TT behavior until explicitly switched — real Linux's
        // hub_configure() always does this switch for such a hub.
        uint hub_device_protocol = (uint)desc_buf[6] & 0xFF;
        print("usbd: hub bDeviceProtocol=");
        print_uint(hub_device_protocol);
        print(hub_device_protocol == USB_HUB_PROTOCOL_MULTI_TT ? " (multi-TT capable)\n" : " (single-TT or full-speed)\n");
        // USBD_MULTI_TT_SWITCH: the multi-TT SET_INTERFACE switch
        // (added in an earlier session, see git log "switch multi-TT-
        // capable hubs into per-port TT mode") was tested and kept
        // only against this driver's OLD, completely different
        // interrupt-split scheduler (frame-granularity, always-NYET) —
        // never re-tested against the current microframe-precise one
        // (dwc2.c3's own hc_transfer_once_split). Real, honest
        // possibility: the earlier "doesn't resolve interrupt-split"
        // verdict was correct for that old algorithm and isn't
        // necessarily still correct for this one. Flip to false for
        // that specific A/B test (docs/devlog.md).
        if (hub_device_protocol == USB_HUB_PROTOCOL_MULTI_TT && USBD_MULTI_TT_SWITCH)
        {
            if (usb_set_interface(USB_ENUM_ADDR, max_packet0, 0, 1))
            {
                print("usbd: hub switched to multi-TT (one TT per port)\n");
            }
            else
            {
                print("usbd: hub multi-TT SET_INTERFACE failed, staying in shared-TT mode\n");
            }
        }

        char[9] hub_desc;
        if (!usb_get_hub_descriptor(USB_ENUM_ADDR, max_packet0, &hub_desc[0], 9))
        {
            print("usbd: hub descriptor fetch failed\n");
            return;
        }
        uint num_ports = (uint)hub_desc[2] & 0xFF;
        print("usbd: hub has ");
        print_uint(num_ports);
        print(" ports\n");

        // Power on every port before querying status — required by
        // USB 2.0 spec: an unpowered port does no connect detection at
        // all and always reports empty, regardless of what's actually
        // plugged in. A real hardware round hit exactly that (every
        // port reporting "empty" with a real device attached before
        // boot) after skipping this step entirely. bPwrOn2PwrGood
        // (hub descriptor byte 5, in 2ms units) is the hub's own
        // specified settle time before port status is meaningful.
        //
        // TEMPORARY EXPERIMENT (docs/devlog.md): a real Xbox 360 wired
        // pad does a brief self-test buzz on power-up — pure firmware
        // behavior, independent of any host driver, confirmed
        // happening under real Linux on this exact hardware but NEVER
        // once under this driver despite many power cycles. That
        // points at power delivery, not USB protocol — the device
        // may be running under-powered, enough to answer simple
        // control transfers but never enough to fully boot its own
        // firmware (motor driver, report generation). Floor bumped
        // way up from the previous 20ms as a real-data probe: does a
        // much longer power-on settle time make the buzz (and,
        // possibly, real interrupt data) finally appear?
        uint pwr_on_2_pwr_good_ms = ((uint)hub_desc[5] & 0xFF) * 2;
        print("usbd: hub bPwrOn2PwrGood raw=");
        print_uint((uint)hub_desc[5] & 0xFF);
        print(" (");
        print_uint(pwr_on_2_pwr_good_ms);
        print("ms specified)\n");
        if (pwr_on_2_pwr_good_ms < 200) { pwr_on_2_pwr_good_ms = 200; }
        for (uint port = 1; port <= num_ports; port++)
        {
            if (!usb_set_port_feature(USB_ENUM_ADDR, max_packet0, port, USB_HUB_FEATURE_PORT_POWER))
            {
                print("usbd: hub port ");
                print_uint(port);
                print(": SetPortFeature(PORT_POWER) failed\n");
            }
        }
        ulong pwr_settle_start = rdtime();
        while (rdtime() - pwr_settle_start < usb_us_to_ticks((ulong)pwr_on_2_pwr_good_ms * 1000)) { yield(); }

        bool root_is_high_speed = ((hprt0 & USB_HPRT0_PRTSPD_MASK) >> USB_HPRT0_PRTSPD_SHIFT) == 0;
        for (uint port = 1; port <= num_ports; port++)
        {
            // GET_PORT_STATUS below talks straight to the hub — reset
            // the split context first. usb_enumerate_hub_port_device()
            // for a *previous* port may have left it pointing at a
            // downstream device (msc clears it on the way out, but an
            // HID keyboard/mouse session deliberately keeps it for
            // usb_hid_poll) — a real STALL on the next port's status
            // read, hit on hardware (docs/devlog.md). Same guard as
            // usb_poll_hub_ports().
            usb_set_split_context(false, 0, 0, false);

            char[4] port_status;
            if (usb_get_port_status(USB_ENUM_ADDR, max_packet0, port, &port_status[0]))
            {
                bool port_connected = ((uint)port_status[0] & 0x1) != 0;
                print("usbd: hub port ");
                print_uint(port);
                print(": ");
                print(port_connected ? "connected\n" : "empty\n");
                if (port < USB_HUB_MAX_PORTS_TRACKED) { g_hub_port_connected[port] = port_connected; }
                if (port_connected)
                {
                    usb_enumerate_hub_port_device(USB_ENUM_ADDR, max_packet0, port, root_is_high_speed);
                }
            }
            else
            {
                print("usbd: hub port ");
                print_uint(port);
                print(": GET_PORT_STATUS failed\n");
            }
        }

        // Enable ongoing hot-plug polling for this hub — see
        // usb_poll_hub_ports()'s own comment for why the initial walk
        // above isn't enough on its own.
        g_hub_addr = USB_ENUM_ADDR;
        g_hub_max_packet0 = max_packet0;
        g_hub_num_ports = num_ports;
        g_hub_root_is_high_speed = root_is_high_speed;
    }
    else
    {
        print("usbd: non-hub device (class 0x");
        print_hex8(device_class);
        print(") — no further action this phase\n");
    }
}

fn void print_int(int v)
{
    if (v < 0)
    {
        putchar('-');
        print_uint((uint)(-v));
    }
    else
    {
        print_uint((uint)v);
    }
}

// USB Phase 3: enumerates whatever's plugged into one of the hub's
// own downstream ports — the missing piece Phase 2 never did (it only
// ever queried per-port connect status, never actually reset+
// addressed+enumerated a downstream device). Same enumeration shape
// usb_enumerate_device() already uses for the root-port device (the
// hub itself), just addressed to USB_DOWNSTREAM_ADDR instead of
// USB_ENUM_ADDR, and reached via a real port reset first. Bootstrap
// MPS0 is always 8 here regardless of the downstream device's own
// negotiated speed — full/low-speed devices always have MPS0=8 fixed
// or ambiguous (8/16/32/64, "assume 8" is the standard safe trick),
// and even if this hub someday reports a Hi-Speed child, EP0's MPS0
// is spec-fixed at 64 for Hi-Speed, but this driver's own hub is
// full-speed-only in practice so far — leaving the high-speed case
// unimplemented here rather than guessing at it.
//
// root_is_high_speed comes from the caller's own already-read HPRT0
// (the root port's negotiated speed) — this driver no longer forces
// Full/Low-Speed-only (see usbd_init()'s own HCFG comment), so a real
// Hi-Speed-capable hub now negotiates Hi-Speed on the root port, and
// every transfer to a downstream device that isn't itself Hi-Speed
// needs USB 2.0 split transactions (g_split_active, set below once
// this device's own speed is known from usb_reset_hub_port).
fn void usb_enumerate_hub_port_device(uint hub_addr, uint hub_max_packet0, uint port, bool root_is_high_speed)
{
    // usb_reset_hub_port() below (SET_FEATURE(PORT_RESET) + status
    // polling) talks straight to the hub, before this function knows
    // the new device's speed and sets its own context — clear whatever
    // a prior device (an HID session that keeps its context, a
    // low-speed sibling port) left in dwc2.c3's global first.
    usb_set_split_context(false, 0, 0, false);

    uint device_speed;
    if (!usb_reset_hub_port(hub_addr, hub_max_packet0, port, &device_speed))
    {
        print("usbd: hub port ");
        print_uint(port);
        print(": reset failed, giving up on this device\n");
        return;
    }

    bool do_split = root_is_high_speed && device_speed != USB_DEV_SPEED_HIGH;
    usb_set_split_context(do_split, hub_addr, port, device_speed == USB_DEV_SPEED_LOW);
    print("usbd: hub port ");
    print_uint(port);
    print(": device speed=");
    print(device_speed == USB_DEV_SPEED_HIGH ? "high" : (device_speed == USB_DEV_SPEED_LOW ? "low" : "full"));
    print(do_split ? ", split transactions required\n" : ", no split needed\n");

    char[18] desc_buf;
    uint bootstrap_mps0 = 8;

    bool got_initial_desc = false;
    for (int attempt = 0; attempt < 3; attempt++)
    {
        if (usb_get_descriptor(0, bootstrap_mps0, USB_DESC_TYPE_DEVICE, 0, &desc_buf[0], 8))
        {
            got_initial_desc = true;
            break;
        }
        ulong retry_start = rdtime();
        while (rdtime() - retry_start < usb_us_to_ticks(100000)) { yield(); }
    }
    if (!got_initial_desc)
    {
        print("usbd: hub port ");
        print_uint(port);
        print(": initial GET_DESCRIPTOR(8) failed (all attempts)\n");
        usb_set_split_context(false, 0, 0, false);
        return;
    }
    uint max_packet0 = (uint)desc_buf[7] & 0xFF;

    if (!usb_set_address(max_packet0, USB_DOWNSTREAM_ADDR))
    {
        print("usbd: hub port ");
        print_uint(port);
        print(": SET_ADDRESS failed\n");
        usb_set_split_context(false, 0, 0, false);
        return;
    }
    ulong addr_settle = rdtime();
    while (rdtime() - addr_settle < usb_us_to_ticks(10000)) { yield(); }

    if (!usb_get_descriptor(USB_DOWNSTREAM_ADDR, max_packet0, USB_DESC_TYPE_DEVICE, 0, &desc_buf[0], 18))
    {
        print("usbd: hub port ");
        print_uint(port);
        print(": GET_DESCRIPTOR(18) at new address failed\n");
        usb_set_split_context(false, 0, 0, false);
        return;
    }

    uint vendor_id  = ((uint)desc_buf[8]  & 0xFF) | (((uint)desc_buf[9]  & 0xFF) << 8);
    uint product_id = ((uint)desc_buf[10] & 0xFF) | (((uint)desc_buf[11] & 0xFF) << 8);
    print("usbd: hub port ");
    print_uint(port);
    print(": enumerated device vid=0x");
    print_hex8((vendor_id >> 8) & 0xFF);
    print_hex8(vendor_id & 0xFF);
    print(" pid=0x");
    print_hex8((product_id >> 8) & 0xFF);
    print_hex8(product_id & 0xFF);
    print("\n");

    // Class dispatch (USB Phase 4): probe the configuration descriptor
    // against every device class this driver knows about, rather than
    // gating on vendor ID the way Phase 3 originally did — vendor ID
    // only identifies XPAD (a vendor-specific class), while mass
    // storage devices are recognized by interface class/subclass/
    // protocol instead, the same way real USB-core stacks dispatch to
    // class drivers. First interface match wins; a device could in
    // principle expose more than one recognized interface, but no
    // real device this driver targets does.
    char[256] config_buf;
    if (!usb_get_configuration_descriptor(USB_DOWNSTREAM_ADDR, max_packet0, &config_buf[0], 256))
    {
        print("usbd: hub port ");
        print_uint(port);
        print(": configuration descriptor fetch failed\n");
        usb_set_split_context(false, 0, 0, false);
        return;
    }

    uint iface_num;
    uint num_endpoints;
    uint ep_start;
    if (usb_find_interface(&config_buf[0], 256, XPAD_IFACE_CLASS, XPAD_IFACE_SUBCLASS, XPAD_IFACE_PROTOCOL, &iface_num, &num_endpoints, &ep_start))
    {
        if (!usb_set_configuration(USB_DOWNSTREAM_ADDR, max_packet0, 1))
        {
            print("usbd: xpad: SET_CONFIGURATION failed\n");
            usb_set_split_context(false, 0, 0, false);
            return;
        }

        // Walk the interface's own endpoint descriptors looking for
        // both the interrupt IN endpoint (reports) and the interrupt
        // OUT one (rumble/LED) — real vendor Linux 5.10's own
        // xpad.c (drivers/input/joystick/xpad.c, duo-buildroot-sdk)
        // sends an LED-set command over the OUT endpoint unconditionally
        // right after enumeration (xpad_probe() -> xpad_init_input() ->
        // xpad_led_probe() -> xpad_identify_controller(), never gated
        // behind any application opening the input device), which is
        // sent below before this driver starts polling the IN endpoint.
        uint ep_in_addr = 0;
        uint ep_in_max_packet = 0;
        uint ep_in_interval = 0;
        bool found_in = false;
        uint ep_out_addr = 0;
        uint ep_out_max_packet = 0;
        bool found_out = false;
        // Walks by real endpoint COUNT, not raw descriptor position —
        // a real Xbox 360 pad's own vendor-specific interface has a
        // proprietary 0x21 ("XInput") descriptor sitting between the
        // interface descriptor and its two real endpoint descriptors.
        // A previous version of this loop ran for exactly
        // `num_endpoints` (2) raw iterations regardless of descriptor
        // type — that extra non-endpoint descriptor consumed one
        // iteration, so it found endpoint #1 (IN) and then stopped one
        // iteration short of ever reaching endpoint #2 (OUT). Confirmed
        // on real hardware: "no interrupt OUT endpoint found" even
        // though the device unquestionably has one (real vendor Linux's
        // own xpad.c requires exactly 2 endpoints to even probe this
        // device at all). Also stops at the next Interface descriptor,
        // if one turns up before num_endpoints real endpoints have —
        // a malformed/unexpected descriptor shouldn't run past this
        // interface's own boundary into config_buf's fixed 256-byte
        // bound.
        uint off = ep_start;
        uint endpoints_found = 0;
        while (off + 1 < 256 && endpoints_found < num_endpoints)
        {
            uint b_length = (uint)config_buf[off] & 0xFF;
            if (b_length == 0) { break; }
            uint b_type = (uint)config_buf[off + 1] & 0xFF;
            if (b_type == USB_DESC_TYPE_INTERFACE) { break; }
            if (b_type == USB_DESC_TYPE_ENDPOINT)
            {
                char* ep_desc = &config_buf[off];
                uint addr = usb_ep_desc_address(ep_desc);
                uint xfer_type = usb_ep_desc_xfer_type(ep_desc);
                if (xfer_type == USB_EP_XFERTYPE_INTERRUPT && (addr & 0x80) != 0)
                {
                    ep_in_addr = addr;
                    ep_in_max_packet = usb_ep_desc_max_packet(ep_desc);
                    ep_in_interval = usb_ep_desc_interval(ep_desc);
                    found_in = true;
                }
                else if (xfer_type == USB_EP_XFERTYPE_INTERRUPT && (addr & 0x80) == 0)
                {
                    ep_out_addr = addr;
                    ep_out_max_packet = usb_ep_desc_max_packet(ep_desc);
                    found_out = true;
                }
                endpoints_found++;
            }
            off += b_length;
        }

        if (!found_in)
        {
            print("usbd: xpad: no interrupt IN endpoint found\n");
            usb_set_split_context(false, 0, 0, false);
            return;
        }

        print("usbd: xpad: controller found, interface ");
        print_uint(iface_num);
        print(", interrupt IN endpoint 0x");
        print_hex8(ep_in_addr);
        print(", max_packet=");
        print_uint(ep_in_max_packet);
        print(", bInterval=");
        print_uint(ep_in_interval);
        print("ms, reading reports\n");

        // real Linux's own xpad_send_led_command(), XTYPE_XBOX360 case:
        // {0x01, 0x03, command}, command = (pad_nr % 4) + 2 — pad_nr is
        // always 0 for the first (and only) controller this driver ever
        // tracks, so command=2 ("player 1," a steady, non-blinking LED
        // pattern per the real Xbox 360 LED command table).
        if (found_out)
        {
            char[3] led_cmd;
            led_cmd[0] = (char)0x01;
            led_cmd[1] = (char)0x03;
            led_cmd[2] = (char)0x02;
            if (usb_interrupt_transfer_out(USB_DOWNSTREAM_ADDR, ep_out_addr & 0x0F, ep_out_max_packet, &led_cmd[0], 3))
            {
                print("usbd: xpad: LED command sent\n");
            }
            else
            {
                print("usbd: xpad: LED command failed\n");
            }
        }
        else
        {
            print("usbd: xpad: no interrupt OUT endpoint found, skipping LED command\n");
        }

        usbd_xpad_read_loop(USB_DOWNSTREAM_ADDR, ep_in_addr & 0x0F, ep_in_max_packet, ep_in_interval);
        return;
    }

    if (usb_find_interface(&config_buf[0], 256, USB_CLASS_MASS_STORAGE, USB_MSC_SUBCLASS_SCSI, USB_MSC_PROTOCOL_BULK_ONLY, &iface_num, &num_endpoints, &ep_start))
    {
        if (!usb_set_configuration(USB_DOWNSTREAM_ADDR, max_packet0, 1))
        {
            print("usbd: msc: SET_CONFIGURATION failed\n");
            usb_set_split_context(false, 0, 0, false);
            return;
        }

        usb_enumerate_msc_device(USB_DOWNSTREAM_ADDR, max_packet0, &config_buf[0], iface_num, num_endpoints, ep_start, port);
        usb_set_split_context(false, 0, 0, false);
        return;
    }

    // HID boot mouse (class 3 / subclass 1 / protocol 2) — matched
    // BEFORE the keyboard check so a gaming mouse that also exposes a
    // boot-keyboard companion interface (for its programmable buttons —
    // vid 0x0951 pid 0x1729 was the real one that forced this) is
    // treated as the mouse it is, polled on its mouse interface. Raw
    // hex-dump session (is_keyboard = false), same as the generic
    // fallback — no mouse-report decode layer yet.
    if (usb_find_interface(&config_buf[0], 256, USB_CLASS_HID, USB_HID_SUBCLASS_BOOT, USB_HID_PROTOCOL_MOUSE, &iface_num, &num_endpoints, &ep_start))
    {
        if (!usb_set_configuration(USB_DOWNSTREAM_ADDR, max_packet0, 1))
        {
            print("usbd: mouse: SET_CONFIGURATION failed\n");
            usb_set_split_context(false, 0, 0, false);
            return;
        }

        uint m_ep_addr;
        uint m_ep_max_packet;
        uint m_ep_interval;
        if (!usb_iface_first_interrupt_in(&config_buf[0], 256, ep_start, num_endpoints, &m_ep_addr, &m_ep_max_packet, &m_ep_interval))
        {
            print("usbd: mouse: no interrupt IN endpoint on the mouse interface\n");
            usb_set_split_context(false, 0, 0, false);
            return;
        }

        print("usbd: mouse: boot mouse on interface ");
        print_uint(iface_num);
        print(", interrupt IN 0x");
        print_hex8(m_ep_addr);
        print(", bInterval=");
        print_uint(m_ep_interval);
        print("ms\n");

        // Keep the split context (same reasoning as the generic branch).
        usb_hid_begin_session(USB_DOWNSTREAM_ADDR, m_ep_addr & 0x0F, m_ep_max_packet, m_ep_interval, port, false);
        return;
    }

    // HID boot keyboard (class 3 / subclass 1 / protocol 1) — matched
    // before the generic interrupt-IN fallback below so a plain
    // keyboard goes through kbd.c3's decode instead of the raw hex
    // dump. A composite keyboard (keyboard + consumer-control) matches
    // here on its boot-keyboard interface; the other interfaces are
    // left alone.
    if (usb_find_interface(&config_buf[0], 256, USB_CLASS_HID, USB_HID_SUBCLASS_BOOT, USB_HID_PROTOCOL_KEYBOARD, &iface_num, &num_endpoints, &ep_start))
    {
        if (!usb_set_configuration(USB_DOWNSTREAM_ADDR, max_packet0, 1))
        {
            print("usbd: kbd: SET_CONFIGURATION failed\n");
            usb_set_split_context(false, 0, 0, false);
            return;
        }

        uint kbd_ep_addr;
        uint kbd_ep_max_packet;
        uint kbd_ep_interval;
        if (!usb_iface_first_interrupt_in(&config_buf[0], 256, ep_start, num_endpoints, &kbd_ep_addr, &kbd_ep_max_packet, &kbd_ep_interval))
        {
            print("usbd: kbd: no interrupt IN endpoint on the keyboard interface\n");
            usb_set_split_context(false, 0, 0, false);
            return;
        }

        // HID init: pin the report format to the fixed 8-byte boot
        // layout, and stop the device re-sending unchanged reports (no
        // hardware auto-repeat). Neither is fatal if the keyboard NAKs
        // it — most work in boot-ish mode anyway — so log and continue.
        if (usb_hid_set_protocol(USB_DOWNSTREAM_ADDR, max_packet0, iface_num, 0))
        {
            print("usbd: kbd: boot protocol selected\n");
        }
        else
        {
            print("usbd: kbd: SET_PROTOCOL failed (continuing)\n");
        }
        if (usb_hid_set_idle(USB_DOWNSTREAM_ADDR, max_packet0, iface_num, 0))
        {
            print("usbd: kbd: idle rate 0 (report-on-change)\n");
        }
        else
        {
            print("usbd: kbd: SET_IDLE failed (continuing)\n");
        }

        print("usbd: kbd: keyboard on interface ");
        print_uint(iface_num);
        print(", interrupt IN 0x");
        print_hex8(kbd_ep_addr);
        print(", bInterval=");
        print_uint(kbd_ep_interval);
        print("ms\n");

        // Same "keep the split context, don't clear it" reasoning as
        // the generic branch below.
        kbd_reset_state();
        usb_hid_begin_session(USB_DOWNSTREAM_ADDR, kbd_ep_addr & 0x0F, kbd_ep_max_packet, kbd_ep_interval, port, true);
        // Extra bits kbd.c3 needs for its Caps Lock LED SET_REPORT —
        // not worth widening usb_hid_begin_session's signature for a
        // keyboard-only detail.
        g_hid[HID_SLOT_KEYBOARD].ctrl_max_packet = max_packet0;
        g_hid[HID_SLOT_KEYBOARD].iface_num       = iface_num;
        return;
    }

    // Not xpad, not mass storage, not a boot keyboard, but if it has
    // ANY interrupt IN endpoint at all (a mouse almost certainly does),
    // register it as the active HID session and let usb_hid_poll()
    // service it cooperatively from main()'s loop. Started life as a
    // real-hardware diagnostic for "does split-interrupt IN work at all
    // through this hub for a boring device" (docs/devlog.md).
    uint generic_ep_addr;
    uint generic_ep_max_packet;
    uint generic_ep_interval;
    if (usb_find_any_interrupt_in(&config_buf[0], 256, &generic_ep_addr, &generic_ep_max_packet, &generic_ep_interval))
    {
        if (!usb_set_configuration(USB_DOWNSTREAM_ADDR, max_packet0, 1))
        {
            print("usbd: generic-hid: SET_CONFIGURATION failed\n");
            usb_set_split_context(false, 0, 0, false);
            return;
        }
        print("usbd: generic-hid: interrupt IN endpoint 0x");
        print_hex8(generic_ep_addr);
        print(", max_packet=");
        print_uint(generic_ep_max_packet);
        print(", bInterval=");
        print_uint(generic_ep_interval);
        print("ms, cooperative polling\n");
        // No usb_set_split_context(false, ...) here, unlike the xpad/msc
        // branches above — the split context set earlier in this
        // function (after the port reset) is exactly what usb_hid_poll()
        // needs to keep talking to this device, so usb_hid_begin_session()
        // captures it instead of clearing it.
        usb_hid_begin_session(USB_DOWNSTREAM_ADDR, generic_ep_addr & 0x0F, generic_ep_max_packet, generic_ep_interval, port, false);
        return;
    }

    print("usbd: hub port ");
    print_uint(port);
    print(": not a recognized device, no further action\n");
    usb_set_split_context(false, 0, 0, false);
}

// Records the just-enumerated HID interrupt-IN endpoint in its slot
// (HID_SLOT_KEYBOARD for a keyboard, HID_SLOT_OTHER for a mouse /
// anything else — so the two coexist). Mirror of msc.c3's own
// tail-of-usb_enumerate_msc_device() state capture. Interrupt endpoints
// always start at DATA0 right after SET_CONFIGURATION (same reasoning
// as usbd_xpad_read_loop's own pid_toggle init). next_due = now, so the
// first poll fires on the next main-loop pass.
fn void usb_hid_begin_session(uint dev_addr, uint ep_num, uint max_packet, uint interval_ms, uint hub_port, bool is_keyboard)
{
    Hid_session* s = &g_hid[is_keyboard ? HID_SLOT_KEYBOARD : HID_SLOT_OTHER];

    uint paced_interval_ms = interval_ms == 0 ? 1 : interval_ms;
    s.interval_ticks = usb_us_to_ticks((ulong)paced_interval_ms * 1000);
    s.next_due       = rdtime();
    s.dev_addr       = dev_addr;
    s.ep_num         = ep_num;
    s.max_packet     = max_packet;
    s.pid_toggle     = USB_PID_DATA0;
    s.hub_port       = hub_port;
    s.report_count   = 0;
    s.is_keyboard    = is_keyboard;

    // Snapshot the split context dwc2.c3 currently holds for this device
    // (our caller set it right after the port reset) so usb_hid_poll()
    // can re-assert it after unrelated transfers clobber the global —
    // see the Hid_session comment.
    s.split_active    = g_split_active;
    s.split_hub_addr  = g_split_hub_addr;
    s.split_hub_port  = g_split_hub_port;
    s.split_low_speed = g_device_is_low_speed;

    s.present = true;
}

// Mirror of usb_msc_clear_session — called from usb_poll_hub_ports()
// when a hub port goes empty. Clears whichever slot(s) that port held.
// Safe to call unconditionally.
fn void usb_hid_clear_session(uint disconnected_port)
{
    for (uint i = 0; i < HID_SLOT_COUNT; i++)
    {
        if (g_hid[i].present && g_hid[i].hub_port == disconnected_port)
        {
            g_hid[i].present = false;
        }
    }
}

// One non-blocking poll of one HID session slot, paced to that
// endpoint's own bInterval via next_due — early-returns until the next
// report is due or when the slot is empty. A keyboard slot's reports go
// to kbd.c3's decode; the other slot gets the raw hex dump the old
// usbd_generic_interrupt_read_loop() produced.
fn void usb_hid_poll_slot(uint slot)
{
    Hid_session* s = &g_hid[slot];
    if (!s.present) { return; }

    ulong now = rdtime();
    if (now < s.next_due) { return; }
    s.next_due = now + s.interval_ticks;

    // Re-assert this device's split context — usb_msc_ipc_poll(), hub
    // polling, and the other HID slot all overwrite dwc2.c3's global
    // g_split_* between our polls (see the Hid_session comment).
    usb_set_split_context(s.split_active, s.split_hub_addr, s.split_hub_port, s.split_low_speed);

    char[16] report @noinit;
    uint report_len;
    bool got = usb_interrupt_poll(s.dev_addr, s.ep_num, s.max_packet, &s.pid_toggle, &report[0], 16, &report_len);

    if (s.is_keyboard)
    {
        if (got) { kbd_handle_report(&report[0], report_len); }
        // kbd_tick() drives software auto-repeat, so it must run every
        // poll (a held key produces no new reports under SET_IDLE(0)).
        kbd_tick();
        // Flush a pending Caps Lock LED change (g_kbd_led_dirty, set by
        // kbd.c3 on each Caps toggle) — best-effort, cosmetic. The Caps
        // Lock *function* (letter case) lives entirely in kbd.c3 and
        // doesn't need this.
        //
        // Skipped over a split transaction: SET_REPORT has an OUT data
        // stage, and this driver has never done an OUT-data control
        // transfer over a USB 2.0 split before (every prior one was
        // no-data or IN-data) — on a low-speed keyboard behind the
        // hi-speed hub it doesn't light the LED, and attempting it just
        // burns the 3s NAK budget and prints an error per toggle.
        // Likely fix if it's ever wanted: dwc2.c3's control/bulk
        // complete-split path (~line 1152) should force HCTSIZ size 0
        // for a CSPLIT OUT, the way its interrupt path already does. A
        // directly-attached full-speed keyboard (no split) still gets
        // its LED.
        if (g_kbd_led_dirty)
        {
            if (!s.split_active)
            {
                usb_hid_set_report_leds(s.dev_addr, s.ctrl_max_packet, s.iface_num, g_kbd_led_state);
            }
            g_kbd_led_dirty = false;
        }
        return;
    }

    if (!got) { return; }

    // Non-keyboard HID (a mouse, or an unknown interrupt-IN device):
    // just dump the raw report, exactly what the old
    // usbd_generic_interrupt_read_loop() did.
    s.report_count++;
    print("usbd: generic-hid: report #");
    print_uint(s.report_count);
    print(" len=");
    print_uint(report_len);
    print(":");
    uint dump_len = report_len < 16 ? report_len : 16;
    for (uint i = 0; i < dump_len; i++)
    {
        putchar(' ');
        print_hex8((uint)report[i] & 0xFF);
    }
    print("\n");
}

// Polls every HID session slot — called from main()'s loop and its
// idle tail.
fn void usb_hid_poll()
{
    for (uint i = 0; i < HID_SLOT_COUNT; i++)
    {
        usb_hid_poll_slot(i);
    }
}

fn void print_button_change(char* name, bool now, bool before)
{
    if (now == before) { return; }
    print("usbd: xpad: ");
    print(name);
    print(now ? " pressed\n" : " released\n");
}

// Polls the controller's own interrupt IN endpoint forever, printing
// button/stick state changes as they happen — the direct, interactive
// proof this all works. No IPC/game-input-subsystem integration (no
// real consumer exists yet for that) — this phase's own scope is
// "prove the USB stack can talk to a real interrupt-endpoint device
// end to end," not building a general input subsystem.
fn void usbd_xpad_read_loop(uint dev_addr, uint ep_num, uint max_packet, uint interval_ms)
{
    Xpad_state last_state;
    Xpad_state state;
    // Interrupt/bulk endpoints always start at DATA0 right after
    // configuration — real, sourced difference from control's own
    // "always restart at DATA1 after SETUP" rule (see
    // usb_interrupt_poll's own comment for the full toggle-persistence
    // reasoning this then relies on for every poll after the first).
    uint pid_toggle = USB_PID_DATA0;

    // Real hosts schedule a periodic (interrupt) endpoint at exactly
    // its own declared bInterval — every prior poll before this fix
    // ignored it entirely and just hammered the endpoint back-to-back
    // (thousands of attempts/sec), which on real hardware got a clean
    // NAK every single time, never once XFERCOMP, even with the
    // controller actively being used (docs/devlog.md has the full
    // trace). A malformed/zero bInterval is clamped to 1ms — full-
    // speed interrupt endpoints (which this one is, forced by
    // USB_HCFG_FSLSSUPP) encode bInterval directly in 1ms frame
    // units, per USB 2.0 spec chapter 9.6.6, so no 2^(n-1) microframe
    // decoding is needed the way a high-speed endpoint would require.
    uint paced_interval_ms = interval_ms == 0 ? 1 : interval_ms;
    ulong interval_ticks = usb_us_to_ticks((ulong)paced_interval_ms * 1000);

    for (;;)
    {
        ulong poll_start = rdtime();
        char[32] report @noinit;
        uint report_len;
        if (usb_interrupt_poll(dev_addr, ep_num, max_packet, &pid_toggle, &report[0], 32, &report_len))
        {
            if (xpad_parse_report(&report[0], report_len, &state))
            {
                print_button_change("A", state.a, last_state.a);
                print_button_change("B", state.b, last_state.b);
                print_button_change("X", state.x, last_state.x);
                print_button_change("Y", state.y, last_state.y);
                print_button_change("start", state.start, last_state.start);
                print_button_change("back", state.back, last_state.back);
                print_button_change("guide", state.guide, last_state.guide);
                print_button_change("LB", state.bumper_l, last_state.bumper_l);
                print_button_change("RB", state.bumper_r, last_state.bumper_r);
                print_button_change("L3", state.thumb_l, last_state.thumb_l);
                print_button_change("R3", state.thumb_r, last_state.thumb_r);
                print_button_change("dpad-up", state.dpad_up, last_state.dpad_up);
                print_button_change("dpad-down", state.dpad_down, last_state.dpad_down);
                print_button_change("dpad-left", state.dpad_left, last_state.dpad_left);
                print_button_change("dpad-right", state.dpad_right, last_state.dpad_right);

                if (state.trigger_l != last_state.trigger_l || state.trigger_r != last_state.trigger_r)
                {
                    print("usbd: xpad: triggers l=");
                    print_uint(state.trigger_l);
                    print(" r=");
                    print_uint(state.trigger_r);
                    print("\n");
                }
                if (state.stick_lx != last_state.stick_lx || state.stick_ly != last_state.stick_ly
                    || state.stick_rx != last_state.stick_rx || state.stick_ry != last_state.stick_ry)
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

                last_state = state;
            }
        }

        // Pace to bInterval, not a bare spin — see this function's own
        // comment above. yield()-based, same SYS_YIELD deadlock
        // reasoning as main()'s own polling loop below.
        while (rdtime() - poll_start < interval_ticks) { yield(); }
    }
}

fn void main()
{
    usb_dma_paddr = usbd_info();
    usbd_init();
    // Posts this process under "usbd" in the global srv_table (same
    // Plan-9-style post+mount two-step fsd2 already uses, srv_post("fs2")
    // — see docs/devlog.md) so a client (usbrw, user/bin/usbrw.c3) can
    // reach it dynamically at any later time via ns_mount_wait()/
    // ns_resolve(), without usbd's own pid ever needing to be hardcoded
    // or baked into a namespace default — usbd's own pid isn't fixed
    // (it's spawned last, after the shell itself, see kernel.c3's own
    // comment) and rfork() copies the PARENT's namespace verbatim
    // (src/entry.c3's SYS_RFORK case), so a static default-namespace
    // entry set before usbd existed would stay permanently stale for
    // every shell-spawned command — the dynamic srv_post/ns_mount_wait
    // path sidesteps that entirely.
    srv_post("usbd");
    print("usbd: init done, polling HPRT0 for connect/disconnect\n");

    bool last_connected = false;
    int poll_count = 0;
    for (;;)
    {
        usb_msc_ipc_poll();
        usb_hid_poll();

        uint hprt0 = usb_reg_read(USB_HPRT0);
        bool connected = (hprt0 & USB_HPRT0_PRTCONNSTS) != 0;
        if (connected != last_connected)
        {
            print(connected ? "usbd: device connected\n" : "usbd: device disconnected\n");
            last_connected = connected;
            if (connected)
            {
                usb_enumerate_device();
            }
        }

        // Periodic raw diagnostic dump (~every 2s, not gated on
        // PRTCONNSTS changing) — PRTLNSTS in particular is a direct
        // sample of the D+/D- differential pair, true regardless of
        // whether the core's own connect-detect logic ever reacts. See
        // print_hprt0_raw's own comment for how to read it.
        poll_count += 1;
        if (poll_count % 20 == 0)
        {
            print_hprt0_raw("poll");
        }

        // Hub-downstream hot-plug — see usb_poll_hub_ports()'s own
        // comment. ~1s cadence: frequent enough to notice a real plug
        // event promptly, infrequent enough not to hammer the hub with
        // GetPortStatus every 100ms tick for no reason.
        if (poll_count % 10 == 0)
        {
            usb_poll_hub_ports();
        }

        // Clear PRTCONNDET (W1C) if it's set, without disturbing any
        // other W1C bit — keeps the register tidy for whenever a later
        // phase starts consulting it instead of just PRTCONNSTS.
        if (hprt0 & USB_HPRT0_PRTCONNDET)
        {
            uint clear = (hprt0 & ~USB_HPRT0_W1C_MASK) | USB_HPRT0_PRTCONNDET;
            usb_reg_write(USB_HPRT0, clear);
        }

        // yield()-paced, not a bare spin — this is the loop that
        // actually deadlocked the system on real hardware the first
        // time (docs/devlog.md): a genuinely syscall-free poll here
        // can never be preempted once the shell is idling on a
        // keystroke (SYS_GETCHAR), since this kernel's own design
        // means that alone holds interrupts globally disabled for as
        // long as it lasts.
        //
        // usb_hid_poll() runs throughout this idle window, not just
        // once per ~100ms outer pass: a HID endpoint's bInterval is
        // ~8ms and each slot is internally paced (next_due), so
        // quantizing it to this loop's 100ms would drop mouse motion /
        // keystrokes under any real use. Cheap early-return per slot
        // when nothing's attached.
        ulong poll_start = rdtime();
        while (rdtime() - poll_start < usb_us_to_ticks(100000))
        {
            usb_hid_poll();
            yield();
        }
    }
}
