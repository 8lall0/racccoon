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
        // specified settle time before port status is meaningful;
        // floored at 20ms in case a hub reports something tiny.
        uint pwr_on_2_pwr_good_ms = ((uint)hub_desc[5] & 0xFF) * 2;
        if (pwr_on_2_pwr_good_ms < 20) { pwr_on_2_pwr_good_ms = 20; }
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

        for (uint port = 1; port <= num_ports; port++)
        {
            char[4] port_status;
            if (usb_get_port_status(USB_ENUM_ADDR, max_packet0, port, &port_status[0]))
            {
                bool port_connected = ((uint)port_status[0] & 0x1) != 0;
                print("usbd: hub port ");
                print_uint(port);
                print(": ");
                print(port_connected ? "connected\n" : "empty\n");
                if (port_connected)
                {
                    bool root_is_high_speed = ((hprt0 & USB_HPRT0_PRTSPD_MASK) >> USB_HPRT0_PRTSPD_SHIFT) == 0;
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
    uint device_speed;
    if (!usb_reset_hub_port(hub_addr, hub_max_packet0, port, &device_speed))
    {
        print("usbd: hub port ");
        print_uint(port);
        print(": reset failed, giving up on this device\n");
        return;
    }

    bool do_split = root_is_high_speed && device_speed != USB_DEV_SPEED_HIGH;
    usb_set_split_context(do_split, hub_addr, port);
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
        usb_set_split_context(false, 0, 0);
        return;
    }
    uint max_packet0 = (uint)desc_buf[7] & 0xFF;

    if (!usb_set_address(max_packet0, USB_DOWNSTREAM_ADDR))
    {
        print("usbd: hub port ");
        print_uint(port);
        print(": SET_ADDRESS failed\n");
        usb_set_split_context(false, 0, 0);
        return;
    }
    ulong addr_settle = rdtime();
    while (rdtime() - addr_settle < usb_us_to_ticks(10000)) { yield(); }

    if (!usb_get_descriptor(USB_DOWNSTREAM_ADDR, max_packet0, USB_DESC_TYPE_DEVICE, 0, &desc_buf[0], 18))
    {
        print("usbd: hub port ");
        print_uint(port);
        print(": GET_DESCRIPTOR(18) at new address failed\n");
        usb_set_split_context(false, 0, 0);
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

    if (vendor_id != XPAD_VENDOR_ID)
    {
        print("usbd: hub port ");
        print_uint(port);
        print(": not a recognized device, no further action\n");
        usb_set_split_context(false, 0, 0);
        return;
    }

    char[256] config_buf;
    if (!usb_get_configuration_descriptor(USB_DOWNSTREAM_ADDR, max_packet0, &config_buf[0], 256))
    {
        print("usbd: xpad: configuration descriptor fetch failed\n");
        usb_set_split_context(false, 0, 0);
        return;
    }

    uint iface_num;
    uint num_endpoints;
    uint ep_start;
    if (!usb_find_interface(&config_buf[0], 256, XPAD_IFACE_CLASS, XPAD_IFACE_SUBCLASS, XPAD_IFACE_PROTOCOL, &iface_num, &num_endpoints, &ep_start))
    {
        print("usbd: xpad: no matching interface found in configuration descriptor\n");
        usb_set_split_context(false, 0, 0);
        return;
    }

    if (!usb_set_configuration(USB_DOWNSTREAM_ADDR, max_packet0, 1))
    {
        print("usbd: xpad: SET_CONFIGURATION failed\n");
        usb_set_split_context(false, 0, 0);
        return;
    }

    // Walk the interface's own endpoint descriptors looking for the
    // interrupt IN one this phase needs. The real device also has an
    // interrupt OUT endpoint (rumble/LED) — not used yet, no output
    // support this phase.
    uint ep_in_addr = 0;
    uint ep_in_max_packet = 0;
    uint ep_in_interval = 0;
    bool found_in = false;
    uint off = ep_start;
    for (uint i = 0; i < num_endpoints; i++)
    {
        uint b_length = (uint)config_buf[off] & 0xFF;
        if (b_length == 0) { break; }
        uint b_type = (uint)config_buf[off + 1] & 0xFF;
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
        }
        off += b_length;
    }

    if (!found_in)
    {
        print("usbd: xpad: no interrupt IN endpoint found\n");
        usb_set_split_context(false, 0, 0);
        return;
    }

    print("usbd: xpad: controller found, interface ");
    print_uint(iface_num);
    print(", interrupt IN endpoint 0x");
    print_hex8(ep_in_addr);
    print(", bInterval=");
    print_uint(ep_in_interval);
    print("ms, reading reports\n");

    usbd_xpad_read_loop(USB_DOWNSTREAM_ADDR, ep_in_addr & 0x0F, ep_in_max_packet, ep_in_interval);
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
    print("usbd: init done, polling HPRT0 for connect/disconnect\n");

    bool last_connected = false;
    int poll_count = 0;
    for (;;)
    {
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
        ulong poll_start = rdtime();
        while (rdtime() - poll_start < usb_us_to_ticks(100000)) { yield(); }
    }
}
