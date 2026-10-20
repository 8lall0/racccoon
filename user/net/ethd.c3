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
// DHCP-first, static-IP fallback (192.168.1.70/24, gateway
// 192.168.1.1) — see user/net/dhcp.c3's own header comment for why
// DHCP was added: a static IP hit a real router-side ARP-defense
// wall on this exact LAN.
//
// 02:00:00:00:00:01 — locally-administered (bit 1 of the first octet
// set), unicast. Matches the exact bytes main() already writes into
// the MAC's own ADDR0LO/ADDR0HI filter registers below.
const char[6] ETHD_OUR_MAC = { (char)0x02, (char)0x00, (char)0x00, (char)0x00, (char)0x00, (char)0x01 };

// Gates the self-test's own bring-up-era diagnostic prints (TX
// descriptor/DMA_STATUS register dumps, auto-negotiation detail) —
// necessary while actively chasing the real hardware bugs entry 72's
// own devlog trail describes (missing DMA page mapping,
// MII_PORTSELECT, write ordering, MAC address wiped by reset), not
// useful day to day, and busy enough to bury the shell's own "> "
// prompt (printed once, early, with no trailing newline — see
// user/shell.c3's own main()) in every boot log since. Off by
// default; flip to true for the same level of detail if a real
// hardware bug ever needs it again — same convention as
// USBD_VERBOSE (user/usb/dwc2.c3) and SDD_VERBOSE
// (user/block/sdhci.c3). Meaningful, non-repeating status (link up/
// down, self-test pass/fail, DHCP bound) stays visible regardless.
const bool ETHD_VERBOSE = false;

// print_hex32 / panic: user/user.c3 (shared).

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

    panic("ethd: ", "no PHY responded with the expected PHYID1 on any scanned MDIO address");
    return 0; // unreachable — panic() calls exit()
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

    // A pure link driver from here on (user/net/link.c3): frames go to and
    // from ipd through the "ether0" rings; ARP/ICMP/DHCP live in ipd.
    // Polled — the dwmac RX interrupt was never brought up on this board —
    // every 20 ms, or at once when ipd rings for a transmit.
    Link link;
    if (!link_create(&link, "ether0", &ETHD_OUR_MAC[0], 1500)) { panic("ethd: ", "can't create link ether0"); }
    print("ethd: link ether0 created, polling MDIO link status\n");

    bool last_up = false;
    bool first = true;
    ulong hz = timebase_hz();
    ulong next_mdio = 0;
    for (;;)
    {
        if (rdtime() >= next_mdio)
        {
            next_mdio = rdtime() + hz / 2;
            uint bmsr;
            if (mdio_read(phy_addr, MII_BMSR, &bmsr))
            {
                bool up = (bmsr & MII_BMSR_LINK_STATUS) != 0;
                link.h.link_up = up ? 1 : 0;
                if (up != last_up || first)
                {
                    print(up ? "ethd: link up\n" : "ethd: link down\n");
                    last_up = up;
                    first = false;
                }
            }
        }

        bool got = false;
        char[1600] rx_frame @noinit;
        uint rx_len;
        while (eth_dma_try_recv(&rx_frame[0], &rx_len))
        {
            link_put(&link, &rx_frame[0], rx_len);
            got = true;
        }
        if (got) { link_kick(&link); }

        char[LINK_FRAME_MAX] tx_frame @noinit;
        for (;;)
        {
            int n = link_get(&link, &tx_frame[0]);
            if (n < 0) { break; }
            if (n > 0) { eth_dma_send(&tx_frame[0], (uint)n); }
        }

        await_any(AW_WAKE, hz / 50, null, 0);
    }
}
