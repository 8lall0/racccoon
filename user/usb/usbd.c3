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
