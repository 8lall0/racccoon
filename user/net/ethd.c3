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
// Phase 1 scope, unchanged by this split: bring the MAC and its
// on-chip PHY up, confirm link status via MDIO polling. NOT in scope
// yet: DMA descriptor rings, packet TX/RX. QEMU has no real MAC
// equivalent at all — its own network path is virtio-net instead, see
// user/net/netd.c3, boards/qemu/board.c3's own comment.
//
// Confirmed working on real hardware, before and after this split:
// genuine, physically-responsive link sensing (verified via cable
// unplug/replug) — see dwmac.c3/ephy.c3's own header comments for
// full sourcing.

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

fn void main()
{
    uint phy_addr = ethd_init();

    // MAC datapath enable + a real MAC address — never touched at all
    // before now (Phase 1's own reasoning: pure MDIO link-status
    // polling shouldn't need either, since that's PHY-register access,
    // independent of the MAC's own RX/TX enable or address filter).
    // Added anyway once every digital PHY-side fact checked out
    // healthy (PLL locked, BMCR clean) with genuinely zero link ever
    // detected by three independent peer devices — cheap, harmless,
    // and closes a real gap, even though link detection itself
    // shouldn't depend on it.
    // 02:00:00:00:00:01 — locally-administered (bit1 of the first
    // octet set), unicast. ADDR0LO = bytes 0-3 (0x02,0x00,0x00,0x00
    // packed little-endian), ADDR0HI = bytes 4-5 (0x00,0x01).
    mac_reg_write(ETH_MAC_ADDR0LO, 0x00000002);
    mac_reg_write(ETH_MAC_ADDR0HI, 0x00000100);
    uint conf = mac_reg_read(ETH_MAC_CONF);
    conf |= ETH_CONF_RXENABLE | ETH_CONF_TXENABLE | ETH_CONF_FES_100 | ETH_CONF_FULLDPLXMODE;
    mac_reg_write(ETH_MAC_CONF, conf);
    print("ethd: MAC address set, RX/TX enabled\n");

    print("ethd: init done, polling MDIO link status\n");

    bool last_up = false;
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

        // yield()-paced, not a bare spin — see user/usb/dwc2.c3's own
        // SYS_YIELD comment for why a genuinely syscall-free poll here
        // is a real deadlock risk on this kernel, not just wasted CPU.
        ulong poll_start = rdtime();
        while (rdtime() - poll_start < eth_us_to_ticks(500000)) { yield(); }
    }
}
