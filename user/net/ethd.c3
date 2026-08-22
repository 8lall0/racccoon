module user;

import std::nolibc::main_stub;

// ethd: orchestration only — ethd_init()'s own bring-up sequencing
// (clocks, then the embedded PHY init/led-pinmux/analog-init calls,
// then the MDIO address scan) and main()'s own MAC-enable + link-
// status poll loop. Everything register-level lives in
// user/net/dwmac.c3 (the generic DW MAC/MDIO layer) and
// user/net/ephy.c3 (this board's own Cvitek embedded-PHY bring-up) —
// this is the file that reads like "what ethd actually does," split
// out once the combined file grew large enough that the wire-level
// code and the orchestration were hard to tell apart in one file
// (docs/devlog.md), same reasoning/shape as usbd.c3's own dwc2.c3
// split.
//
// Phase 1 scope was MAC+PHY bring-up and MDIO link-status polling
// only. Phase 2 (see docs/devlog.md) adds real DMA packet TX/RX
// (user/net/dwmac.c3's own eth_dma_init/send/try_recv) and a minimal
// ARP+ICMP responder (user/net/eth_proto.c3, shared with netd.c3) so
// an external device on the same LAN can actually ping this board.
// QEMU has no real MAC equivalent at all — its own network path is
// virtio-net instead, see user/net/netd.c3.
//
// Confirmed working on real hardware, before and after the Phase 1
// split: genuine, physically-responsive link sensing (verified via
// cable unplug/replug) — see dwmac.c3/ephy.c3's own header comments
// for full sourcing.
//
// Static IP, no DHCP client exists yet (same narrow phased scoping
// USB/Ethernet Phase 1 already established) — 192.168.1.70/24,
// gateway 192.168.1.1, per the user's own LAN.
//
// 02:00:00:00:00:01 — locally-administered (bit 1 of the first octet
// set), unicast. Matches the exact bytes main() already writes into
// the MAC's own ADDR0LO/ADDR0HI filter registers below.
const char[6] ETHD_OUR_MAC = { (char)0x02, (char)0x00, (char)0x00, (char)0x00, (char)0x00, (char)0x01 };

const char[16] HEX_DIGITS = "0123456789abcdef";

fn void print_hex32(uint v)
{
    for (int shift = 28; shift >= 0; shift -= 4)
    {
        putchar(HEX_DIGITS[(v >> shift) & 0xF]);
    }
}

fn void ethd_panic(char* msg)
{
    print("ethd: ");
    print(msg);
    print("\n");
    // Same UB/optimizer hazard as diskd_panic/sdd_panic/usbd_panic's
    // own comment — exit(), not an empty for(;;){} loop.
    exit();
}

fn uint ethd_init()
{
    // Clocks first, same ordering as usbd.c3's own bring-up — see
    // board::ETH_CLK_PAGE's own comment on why this is defensive
    // rather than strictly known-required.
    uint clk_en_0 = clk_reg_read(ETH_CLK_EN_0_OFFSET);
    clk_en_0 |= ETH_CLK_EN_0_500M_ETH0 | ETH_CLK_EN_0_AXI4_ETH0;
    clk_reg_write(ETH_CLK_EN_0_OFFSET, clk_en_0);

    uint clk_en_0_rb = clk_reg_read(ETH_CLK_EN_0_OFFSET);
    uint div_clk_500m_eth0 = clk_reg_read(ETH_DIV_CLK_500M_ETH0_OFFSET);
    print("ethd: clocks enabled, REG_CLK_EN_0 readback=0x");
    print_hex32(clk_en_0_rb);
    print(" (500m_eth0=");
    print_uint((clk_en_0_rb & ETH_CLK_EN_0_500M_ETH0) != 0 ? 1 : 0);
    print(" axi4_eth0=");
    print_uint((clk_en_0_rb & ETH_CLK_EN_0_AXI4_ETH0) != 0 ? 1 : 0);
    print(") DIV_CLK_500M_ETH0=0x");
    print_hex32(div_clk_500m_eth0);
    print("\n");

    eth_phy_init();
    print("ethd: embedded PHY init sequence done\n");

    eth_phy_led_pinmux();
    print("ethd: LED/SD1-selphy pinmux done\n");

    eth_phy_analog_init();
    print("ethd: full analog PHY bring-up done (cv182xa_ephy_init equivalent)\n");

    // Real settle time after the PHY init sequence before trusting
    // MDIO to work at all — same reasoning as USB's own post-reset
    // settle delays.
    ulong settle_start = rdtime();
    while (rdtime() - settle_start < eth_us_to_ticks(50000)) { yield(); }

    // Find which MDIO address this embedded PHY actually answers on —
    // the devicetree declares no explicit address at all (no mdio/
    // phy-handle subnode), so this driver scans rather than guessing.
    // Confirmed signature: PHYID1 == 0x0043, the exact value
    // eth_phy_init() itself just wrote directly via APB.
    for (uint addr = 0; addr < 8; addr++)
    {
        uint phyid1;
        if (mdio_read(addr, MII_PHYID1, &phyid1) && phyid1 == ETH_PHY_ID1_EXPECTED)
        {
            print("ethd: embedded PHY found at MDIO address ");
            print_uint(addr);
            print("\n");

            // Real-hardware diagnostic: MDIO/register access to this
            // PHY is confirmed working (we just read PHYID1
            // successfully), but a real test round showed no link
            // detected on either end of the cable at all — checking
            // whether BMCR's own POWER_DOWN/ISOLATE bits are
            // unexpectedly set, which would explain working register
            // access with zero actual analog line signaling.
            uint bmcr = 0;
            if (mdio_read(addr, MII_BMCR, &bmcr))
            {
                print("ethd: BMCR=0x");
                print_hex32(bmcr);
                print(" powerdown=");
                print_uint((bmcr & MII_BMCR_POWERDOWN) != 0 ? 1 : 0);
                print(" isolate=");
                print_uint((bmcr & MII_BMCR_ISOLATE) != 0 ? 1 : 0);
                print(" autoneg_en=");
                print_uint((bmcr & MII_BMCR_AUTONEG_ENABLE) != 0 ? 1 : 0);
                print("\n");
            }

            // Defensive fix, not just a diagnostic: explicitly clear
            // POWER_DOWN/ISOLATE and set AUTONEG_ENABLE + RESTART_
            // AUTONEG, regardless of what the read above showed —
            // matches this project's own established "redoing it is
            // safe either way" caution for untested real-hardware PHY
            // state, same reasoning as USB's own defensive RST_USB
            // toggle.
            uint bmcr_fixed = (bmcr & ~(MII_BMCR_POWERDOWN | MII_BMCR_ISOLATE))
                | MII_BMCR_AUTONEG_ENABLE | MII_BMCR_RESTART_AUTONEG;
            mdio_write(addr, MII_BMCR, bmcr_fixed);
            print("ethd: BMCR power-down/isolate cleared, auto-negotiation restarted\n");

            return addr;
        }
    }

    ethd_panic("no PHY responded with the expected PHYID1 on any scanned MDIO address");
    return 0; // unreachable — ethd_panic() calls exit()
}

// Minimal DHCP client (RFC 2131): DISCOVER -> OFFER -> REQUEST -> ACK,
// once at startup, no lease renewal — see user/net/dhcp.c3's own
// header comment for full scope/rationale (added specifically because
// a static IP hit a real router-side ARP-defense wall — see this
// file's own header comment). Mirrors user/net/netd.c3's own
// netd_run_dhcp_client() exactly, just over eth_dma_send/
// eth_dma_try_recv instead of the virtio queues.
fn bool ethd_run_dhcp_client(char* our_mac, uint* our_ip_out, uint* gateway_ip_out)
{
    char[600] scratch @noinit;
    char[1600] rx_frame @noinit;

    for (int attempt = 0; attempt < 3; attempt++)
    {
        uint xid = (uint)rdtime() ^ (uint)attempt;

        uint discover_len;
        dhcp_build_discover(&scratch[0], &discover_len, our_mac, xid);
        if (!eth_dma_send(&scratch[0], discover_len)) { continue; }

        uint offered_ip = 0;
        uint offer_server_ip = 0;
        bool got_offer = false;
        ulong offer_start = rdtime();
        ulong offer_budget = eth_us_to_ticks(2000000);
        while (rdtime() - offer_start < offer_budget)
        {
            uint rx_len;
            if (eth_dma_try_recv(&rx_frame[0], &rx_len))
            {
                uint msg_type, yiaddr, server_id, router;
                if (dhcp_parse_message(&rx_frame[0], rx_len, xid, &msg_type, &yiaddr, &server_id, &router) && msg_type == DHCP_MSG_OFFER)
                {
                    offered_ip = yiaddr;
                    offer_server_ip = server_id;
                    got_offer = true;
                    break;
                }
            }
            yield();
        }
        if (!got_offer) { continue; }

        uint request_len;
        dhcp_build_request(&scratch[0], &request_len, our_mac, xid, offered_ip, offer_server_ip);
        if (!eth_dma_send(&scratch[0], request_len)) { continue; }

        ulong ack_start = rdtime();
        ulong ack_budget = eth_us_to_ticks(2000000);
        while (rdtime() - ack_start < ack_budget)
        {
            uint rx_len;
            if (eth_dma_try_recv(&rx_frame[0], &rx_len))
            {
                uint msg_type, yiaddr, server_id, router;
                if (dhcp_parse_message(&rx_frame[0], rx_len, xid, &msg_type, &yiaddr, &server_id, &router))
                {
                    if (msg_type == DHCP_MSG_ACK)
                    {
                        *our_ip_out = yiaddr;
                        *gateway_ip_out = router;
                        return true;
                    }
                    if (msg_type == DHCP_MSG_NAK) { break; }
                }
            }
            yield();
        }
    }
    return false;
}

// One-shot startup self-test: ARP-resolve the gateway, then ping it,
// printing the round-trip result either way. Diagnostic only — never
// panics on failure, since the real point of Phase 2 is the passive
// responder in main()'s own loop, not this self-test (unlike QEMU's
// own SLIRP gateway, a real router isn't guaranteed to be reachable or
// even present — this is a nice-to-have confirmation, not a
// requirement). Mirrors user/net/netd.c3's own netd_self_test()
// exactly, just over eth_dma_send/eth_dma_try_recv instead of the
// virtio queues.
fn void ethd_self_test(char* our_mac, uint our_ip, uint gateway_ip)
{
    char[1600] scratch @noinit;
    char[1600] rx_frame @noinit;
    char[6] gateway_mac;

    uint arp_len;
    eth_build_arp_request(&scratch[0], &arp_len, our_mac, our_ip, gateway_ip);
    bool sent = eth_dma_send(&scratch[0], arp_len);
    print("ethd: self-test: diag: ARP send ");
    print(sent ? "kicked" : "FAILED (tx desc still dma-owned)");
    print(", tx status right after=0x");
    print_hex32(eth_tx_desc.txrx_status);
    print("\n");

    bool got_mac = false;
    uint any_rx_count = 0;
    ulong arp_start = rdtime();
    ulong arp_budget = eth_us_to_ticks(2000000);
    while (rdtime() - arp_start < arp_budget)
    {
        uint rx_len;
        if (eth_dma_try_recv(&rx_frame[0], &rx_len))
        {
            any_rx_count++;
            if (eth_parse_arp_reply(&rx_frame[0], rx_len, gateway_ip, &gateway_mac[0]))
            {
                got_mac = true;
                break;
            }
        }
        yield();
    }
    print("ethd: self-test: ARP resolve of gateway ");
    print(got_mac ? "ok\n" : "TIMED OUT\n");
    print("ethd: self-test: diag: saw ");
    print_uint(any_rx_count);
    print(" other frame(s) during that window, tx status now=0x");
    print_hex32(eth_tx_desc.txrx_status);
    print(", dma_status=0x");
    print_hex32(dma_reg_read(DMA_STATUS));
    print("\n");
    if (!got_mac) { return; }

    uint icmp_len;
    ushort ping_id = 0x1234;
    ushort ping_seq = 1;
    eth_build_icmp_echo_request(&scratch[0], &icmp_len, our_mac, our_ip, &gateway_mac[0], gateway_ip, ping_id, ping_seq);
    if (!eth_dma_send(&scratch[0], icmp_len))
    {
        print("ethd: self-test: ping send failed\n");
        return;
    }

    bool got_reply = false;
    ulong ping_start = rdtime();
    ulong ping_budget = eth_us_to_ticks(2000000);
    while (rdtime() - ping_start < ping_budget)
    {
        uint rx_len;
        if (eth_dma_try_recv(&rx_frame[0], &rx_len))
        {
            if (eth_parse_icmp_echo_reply(&rx_frame[0], rx_len, ping_id, ping_seq))
            {
                got_reply = true;
                break;
            }
        }
        yield();
    }
    print("ethd: self-test: ping to gateway ");
    print(got_reply ? "ok\n" : "TIMED OUT\n");
}

fn void main()
{
    uint phy_addr = ethd_init();

    // Phase 2: bring up the single-descriptor DMA ring (see
    // dwmac.c3's own eth_dma_init() for the full sequence/sourcing) —
    // BEFORE enabling the MAC's own RX/TX datapath below, matching the
    // real driver's own ordering exactly (designware_eth_init(), then
    // a separate, later designware_eth_enable()) — found to matter on
    // real hardware: enabling RX/TX first, before eth_dma_init()'s own
    // MII_PORTSELECT fixup and DMA reset ran, left the datapath
    // silently non-functional (every register write still looked
    // correct, nothing ever reached a real peer on the wire).
    uptr dma_base = ethd_info();
    eth_dma_init(dma_base);
    print("ethd: DMA ring initialized\n");

    // A real MAC address — set AFTER eth_dma_init() above, not before:
    // the real driver's own designware_eth_init() rewrites it at this
    // exact point too, with the comment "Soft reset above clears HW
    // address registers. So we have to set it here once again." — the
    // DMA block's own soft reset (inside eth_dma_init()) really does
    // clear the MAC's ADDR0HI/LO filter registers, on this same IP, so
    // writing them any earlier is silently undone. 02:00:00:00:00:01 —
    // locally-administered (bit 1 of the first octet set), unicast.
    // ADDR0LO = bytes 0-3 (0x02,0x00,0x00,0x00 packed little-endian),
    // ADDR0HI = bytes 4-5 (0x00,0x01).
    mac_reg_write(ETH_MAC_ADDR0LO, 0x00000002);
    mac_reg_write(ETH_MAC_ADDR0HI, 0x00000100);

    // MAC datapath enable, now that the DMA engine is actually ready.
    uint conf = mac_reg_read(ETH_MAC_CONF);
    conf |= ETH_CONF_RXENABLE | ETH_CONF_TXENABLE | ETH_CONF_FES_100 | ETH_CONF_FULLDPLXMODE;
    mac_reg_write(ETH_MAC_CONF, conf);
    print("ethd: MAC address set, RX/TX enabled\n");

    // Wait for the link to actually come up before attempting the
    // self-test below — auto-negotiation (just restarted a few steps
    // up, in ethd_init()'s own BMCR fixup) takes real time to
    // complete, and a real hardware round sent the self-test's own
    // ARP request while the link was still down, before the peer
    // switch/router had any reason to be listening at all. Bounded at
    // 5s — real 100BASE-TX auto-negotiation typically completes well
    // under that; if it doesn't, the self-test is skipped (not fatal
    // — the passive responder below works fine once the link
    // eventually comes up regardless of whether this wait succeeded).
    bool link_ready = false;
    ulong link_wait_start = rdtime();
    ulong link_wait_budget = eth_us_to_ticks(5000000);
    while (rdtime() - link_wait_start < link_wait_budget)
    {
        uint bmsr;
        if (mdio_read(phy_addr, MII_BMSR, &bmsr) && (bmsr & MII_BMSR_LINK_STATUS) != 0)
        {
            link_ready = true;
            break;
        }
        yield();
    }

    uint our_ip = make_ip(192, 168, 1, 70);
    uint gateway_ip = make_ip(192, 168, 1, 1);
    if (link_ready)
    {
        // Diagnostic: what did auto-negotiation actually resolve to?
        // MAC_CONF is hardcoded to FES_100|FULLDPLXMODE below (forced,
        // never read back from the PHY) — if the real link partner
        // negotiated something else (e.g. genuine 10Mbps, or
        // half-duplex), that MAC/PHY mismatch is a well-known real
        // cause of exactly this failure shape (TX appears to complete
        // at the DMA level — it only reflects the MAC's own FIFO
        // accepting the frame, not real successful delivery — while
        // RX stays completely dead).
        uint bmsr_diag = 0;
        uint anlpar_diag = 0;
        mdio_read(phy_addr, MII_BMSR, &bmsr_diag);
        mdio_read(phy_addr, MII_ANLPAR, &anlpar_diag);
        print("ethd: self-test: diag: autoneg_complete=");
        print_uint((bmsr_diag & MII_BMSR_AUTONEG_COMPLETE) != 0 ? 1 : 0);
        print(" link_partner_ability=0x");
        print_hex32(anlpar_diag);
        print(" (100fd=");
        print_uint((anlpar_diag & MII_ANLPAR_100_FULL) != 0 ? 1 : 0);
        print(" 100hd=");
        print_uint((anlpar_diag & MII_ANLPAR_100_HALF) != 0 ? 1 : 0);
        print(" 10fd=");
        print_uint((anlpar_diag & MII_ANLPAR_10_FULL) != 0 ? 1 : 0);
        print(" 10hd=");
        print_uint((anlpar_diag & MII_ANLPAR_10_HALF) != 0 ? 1 : 0);
        print(")\n");

        // DHCP — added specifically because a static IP hit a real
        // router-side wall (see this file's own header comment): a
        // live tcpdump capture confirmed this board's own ARP
        // requests reach the wire perfectly formed, but the router
        // never replies to a device using a static IP it never itself
        // assigned. Falls back to the static our_ip/gateway_ip above
        // on failure/timeout — no regression for a network without a
        // DHCP server at all.
        uint dhcp_ip;
        uint dhcp_gateway;
        if (ethd_run_dhcp_client(&ETHD_OUR_MAC[0], &dhcp_ip, &dhcp_gateway))
        {
            our_ip = dhcp_ip;
            gateway_ip = dhcp_gateway;
            print("ethd: DHCP: bound, ip=");
            print_ip(our_ip);
            print(" gateway=");
            print_ip(gateway_ip);
            print("\n");
        }
        else
        {
            print("ethd: DHCP: failed, falling back to static IP\n");
        }

        ethd_self_test(&ETHD_OUR_MAC[0], our_ip, gateway_ip);
    }
    else
    {
        print("ethd: self-test: skipped, link not up within 5s\n");
    }

    print("ethd: init done, polling MDIO link status\n");

    bool last_up = link_ready;
    bool first = true;
    for (;;)
    {
        uint bmsr;
        if (mdio_read(phy_addr, MII_BMSR, &bmsr))
        {
            bool up = (bmsr & MII_BMSR_LINK_STATUS) != 0;
            if (up != last_up || first)
            {
                print(up ? "ethd: link up\n" : "ethd: link down\n");
                last_up = up;
                first = false;
            }
        }

        // Passive responder — answers ARP/ICMP-echo requests addressed
        // to our_ip, same as netd's own main loop.
        char[1600] rx_frame @noinit;
        uint rx_len;
        if (eth_dma_try_recv(&rx_frame[0], &rx_len))
        {
            char[1600] reply @noinit;
            uint reply_len;
            if (eth_proto_respond(&rx_frame[0], rx_len, &ETHD_OUR_MAC[0], our_ip, &reply[0], &reply_len))
            {
                eth_dma_send(&reply[0], reply_len);
            }
        }

        // yield()-paced, not a bare spin — see user/usb/dwc2.c3's own
        // SYS_YIELD comment for why a genuinely syscall-free poll here
        // is a real deadlock risk on this kernel, not just wasted CPU.
        ulong poll_start = rdtime();
        while (rdtime() - poll_start < eth_us_to_ticks(500000)) { yield(); }
    }
}
