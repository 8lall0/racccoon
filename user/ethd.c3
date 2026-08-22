module user;

// ethd: Ethernet MAC + embedded-PHY driver for the Milk-V Duo — Phase 1
// only (mirrors user/usbd.c3's own Phase 1 scope exactly): bring the
// MAC and its on-chip PHY up, and poll MDIO link status. NOT in scope
// yet: DMA descriptor rings, packet TX/RX. QEMU has no real MAC
// equivalent at all — its own network path is virtio-net instead, see
// user/netd.c3, boards/qemu/board.c3's own comment.
//
// Register offsets/bit layouts sourced directly from duo-buildroot-sdk's
// own driver code, read this session:
//   - MAC/DMA registers: u-boot-2021.10/drivers/net/designware.c/.h —
//     the generic Synopsys DesignWare ("stmmac") Ethernet MAC driver
//     this board's own "cvitek,ethernet" devicetree compatible string
//     binds to; confirmed genuinely standard DW MAC via the real
//     devicetree's own snps,*/clock-names="stmmaceth" properties
//     (cv180x_base.dtsi), not proprietary despite the vendor compatible
//     string, unlike DWC2 USB's own fully-custom register additions.
//   - Embedded PHY init sequence: U-Boot's own cv180x_ephy_id_init()
//     (board/cvitek/cv180x/board.c) — called unconditionally in
//     board_init() on real ASIC hardware. Confirmed this is the
//     complete, only bring-up this exact board needs: the real vendor
//     Linux glue driver (linux_5.10/drivers/net/ethernet/stmicro/
//     stmmac/dwmac-cvitek.c)'s own PHY-reset step only fires if the
//     devicetree provides an `ephy_ctl_reg` property or an enabled
//     `phy-reset-gpios` — this board's own cv180x_base.dtsi has
//     neither (phy-reset-gpios is commented out there), so Linux does
//     no PHY bring-up at all for this exact board, relying entirely
//     on U-Boot having already run cv180x_ephy_id_init() — the same
//     "replicate the one real init path, nothing redoes it" situation
//     already found for DWC2's own dwc2_set_hw_id().
//
// Real-hardware iteration expected here — untested-on-this-exact-
// hardware bring-up, same honest framing user/usbd.c3's own header
// comment used for its own first round.

// --- MAC registers (relative to board::ETH_MMIO_BASE)
const uint ETH_MAC_CONF        = 0x00;
const uint ETH_MAC_FRAMEFILT   = 0x04;
const uint ETH_MAC_MIIADDR     = 0x10;
const uint ETH_MAC_MIIDATA     = 0x14;
const uint ETH_MAC_FLOWCONTROL = 0x18;
const uint ETH_MAC_INTREG      = 0x38;
const uint ETH_MAC_INTMASK     = 0x3C;
const uint ETH_MAC_ADDR0HI     = 0x40;
const uint ETH_MAC_ADDR0LO     = 0x44;

// MAC configuration register bits
const uint ETH_CONF_FES_100        = 1 << 14; // Fast Ethernet Speed: 1=100Mbps, 0=10Mbps — read-only status once auto-negotiation completes on most DW MAC integrations
const uint ETH_CONF_DISABLERXOWN   = 1 << 13;
const uint ETH_CONF_FULLDPLXMODE   = 1 << 11;
const uint ETH_CONF_RXENABLE       = 1 << 2;
const uint ETH_CONF_TXENABLE       = 1 << 3;

// MII address register (MDIO transaction control) bits
const uint ETH_MII_BUSY            = 1 << 0;
const uint ETH_MII_WRITE           = 1 << 1;
const uint ETH_MII_CLKRANGE_150_250M = 0x10; // CSR clock range select — this SoC's own clk_axi4_eth0 (the MAC's register-access clock) runs in the 150-250MHz band, matching every other "clk_axi4_*" peripheral clock on this chip already confirmed running at that order of magnitude
const uint ETH_MIIADDR_SHIFT       = 11; // PHY address field
const uint ETH_MIIREG_SHIFT        = 6;  // PHY register field

// Standard IEEE 802.3 clause 22 MII/MDIO PHY registers — protocol
// constants, not hardware-specific at all.
const uint MII_BMCR  = 0; // Basic Mode Control Register
const uint MII_BMSR  = 1; // Basic Mode Status Register
const uint MII_PHYID1 = 2;
const uint MII_PHYID2 = 3;
const uint MII_BMSR_LINK_STATUS = 1 << 2;
const uint MII_BMSR_AUTONEG_COMPLETE = 1 << 5;
const uint MII_BMCR_DUPLEX_MODE   = 1 << 8;
const uint MII_BMCR_RESTART_AUTONEG = 1 << 9;
const uint MII_BMCR_ISOLATE       = 1 << 10;
const uint MII_BMCR_POWERDOWN     = 1 << 11;
const uint MII_BMCR_AUTONEG_ENABLE = 1 << 12;
const uint MII_BMCR_SPEED_100     = 1 << 13;

// --- Embedded PHY register block (relative to board::ETH_PHY_PAGE) —
// exact offsets from cv180x_ephy_id_init(), see this file's own header
// comment.
const uint ETH_PHY_APB_SEL_OFFSET   = 0x804;
const uint ETH_PHY_CTRL_OFFSET      = 0x800;
const uint ETH_PHY_PAGE_SEL_OFFSET  = 0x07C;
const uint ETH_PHY_ANA_OFFSET       = 0x040;
const uint ETH_PHY_ID1_OFFSET       = 0x008;
const uint ETH_PHY_ID2_OFFSET       = 0x00C;
// p5.0x12 (register 18, page 5) — PLL Lock_Status, bit 15. U-Boot's
// own cv180x_ephy_id_init() documents waiting for this in a comment
// ("Wait PLL_Lock, Lock_Status p5.0x12@[15] = 1") but the actual code
// skips it (mdelay(1), commented out) — real-hardware evidence (this
// session) found the digital PHY register state completely healthy
// (BMCR: autoneg enabled, no power-down, no isolate) with genuinely
// no link detected on either end of the cable at all, which is
// exactly the signature a PLL that never actually locked would
// produce: register access still works (that's the digital side),
// but the analog transceiver has nothing real to drive onto the wire.
// Offset = register-number * 4, same convention every other offset in
// this init sequence already follows (PHY_ID1/PHY_ID2 = registers
// 2/3 = offsets 0x008/0x00C).
const uint ETH_PHY_PLL_LOCK_OFFSET  = 0x048;
const uint ETH_PHY_PLL_LOCK_BIT     = 1 << 15;
// Confirmed via cv180x_ephy_id_init()'s own PHY_ID writes (0x0043/
// 0x5649 written directly via APB before control switches to MDIO) —
// used here to positively identify which MDIO address this embedded
// PHY answers on, since the devicetree declares no explicit phy-addr
// at all (no mdio/phy-handle subnode — the real DWMAC driver's own
// generic behavior in that case is to scan every address).
const uint ETH_PHY_ID1_EXPECTED = 0x0043;

// --- Clock-controller register (relative to board::ETH_CLK_PAGE) —
// see board::ETH_CLK_PAGE's own comment for sourcing.
const uint ETH_CLK_EN_0_OFFSET       = 0x000;
const uint ETH_CLK_EN_0_500M_ETH0    = 1 << 25;
const uint ETH_CLK_EN_0_AXI4_ETH0    = 1 << 26;
// clk_500m_eth0's own divider — real-hardware evidence (this session)
// found the digital PHY register state fully healthy (PLL locked,
// BMCR clean) yet zero link ever detected by three independent peer
// devices (two laptop ports, a router), which pushed this driver to
// stop trusting "the gate-enable write must have worked" and actually
// read back both the gate and this divider — never previously
// verified at all.
const uint ETH_DIV_CLK_500M_ETH0_OFFSET = 0x08C;

// --- Base addresses (duplicated locally — board is kernel-only,
// unreachable from user-mode code, same convention every other driver
// here already follows).
const uint ETH_BASE      = 0x04070000;
const uint ETH_PHY_BASE  = 0x03009000;
const uint ETH_CLK_BASE  = 0x03002000;
const uint ETH_LED_PINMUX_BASE = 0x03001000;
const uint ETH_SD1_SELPHY_BASE = 0x05027000;
const uint ETH_EFUSE_BASE_0 = 0x03050000;
const uint ETH_EFUSE_BASE_1 = 0x03051000;

// cv180x_ephy_led_pinmux()'s own register offsets/values — see
// board::ETH_LED_PINMUX_PAGE's own comment for sourcing.
const uint ETH_LED_PADMUX_0_OFFSET = 0x09C;
const uint ETH_LED_PADMUX_1_OFFSET = 0x0A0;
const uint ETH_SD1_CLK_SELPHY_OFFSET = 0x0B0;
const uint ETH_SD1_CMD_SELPHY_OFFSET = 0x0B4;

// cv182xa_ephy_init()'s own efuse-trim constants — see
// board::ETH_EFUSE_PAGE_0's own comment for sourcing.
const uint ETH_EFUSE_VALID_OFFSET   = 0x120; // within ETH_EFUSE_PAGE_0
const uint ETH_EFUSE_TXITUNE_FLAG   = 1 << 9;
const uint ETH_EFUSE_TXECHORC_FLAG  = 1 << 8;
const uint ETH_EFUSE_TXRXTERM_FLAG  = 1 << 11;
const uint ETH_EFUSE_TRIM_A_OFFSET  = 0x024; // within ETH_EFUSE_PAGE_1
const uint ETH_EFUSE_TRIM_B_OFFSET  = 0x020; // within ETH_EFUSE_PAGE_1

const uint ETH_TIMEBASE_HZ = 25000000; // same sourcing as user/sdd.c3's/user/usbd.c3's own duplicate — see either's header comment

fn ulong eth_us_to_ticks(ulong us)
{
    return us * ETH_TIMEBASE_HZ / 1000000;
}

fn uint mmio_read32(uptr addr)
{
    ulong v;
    asm
    {
        lw v, [addr];
    }
    return (uint)v;
}

fn void mmio_write32(uptr addr, uint v)
{
    ulong vv = (ulong)v;
    asm
    {
        sw vv, [addr];
    }
}

fn uint mac_reg_read(uint offset) { return mmio_read32((uptr)(ETH_BASE + offset)); }
fn void mac_reg_write(uint offset, uint v) { mmio_write32((uptr)(ETH_BASE + offset), v); }

fn uint phy_reg_read(uint offset) { return mmio_read32((uptr)(ETH_PHY_BASE + offset)); }
fn void phy_reg_write(uint offset, uint v) { mmio_write32((uptr)(ETH_PHY_BASE + offset), v); }

fn uint clk_reg_read(uint offset) { return mmio_read32((uptr)(ETH_CLK_BASE + offset)); }
fn void clk_reg_write(uint offset, uint v) { mmio_write32((uptr)(ETH_CLK_BASE + offset), v); }

fn void led_pinmux_write(uint offset, uint v) { mmio_write32((uptr)(ETH_LED_PINMUX_BASE + offset), v); }
fn void sd1_selphy_write(uint offset, uint v) { mmio_write32((uptr)(ETH_SD1_SELPHY_BASE + offset), v); }

fn uint efuse0_read(uint offset) { return mmio_read32((uptr)(ETH_EFUSE_BASE_0 + offset)); }
fn uint efuse1_read(uint offset) { return mmio_read32((uptr)(ETH_EFUSE_BASE_1 + offset)); }

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

// A single MDIO transaction over the MAC's own miiaddr/miidata
// registers — standard DW MAC MDIO idiom, sourced from designware.c's
// own dw_mdio_read()/dw_mdio_write().
fn bool mdio_wait_ready()
{
    ulong start = rdtime();
    ulong budget = eth_us_to_ticks(100000);
    while (mac_reg_read(ETH_MAC_MIIADDR) & ETH_MII_BUSY)
    {
        if (rdtime() - start > budget)
        {
            print("ethd: MDIO timed out waiting for MII_BUSY to clear\n");
            return false;
        }
        yield();
    }
    return true;
}

fn bool mdio_read(uint phy_addr, uint reg, uint* value_out)
{
    if (!mdio_wait_ready()) { return false; }

    uint miiaddr = (phy_addr << ETH_MIIADDR_SHIFT)
        | (reg << ETH_MIIREG_SHIFT)
        | ETH_MII_CLKRANGE_150_250M
        | ETH_MII_BUSY;
    mac_reg_write(ETH_MAC_MIIADDR, miiaddr);

    if (!mdio_wait_ready()) { return false; }

    *value_out = mac_reg_read(ETH_MAC_MIIDATA) & 0xFFFF;
    return true;
}

fn bool mdio_write(uint phy_addr, uint reg, uint value)
{
    if (!mdio_wait_ready()) { return false; }

    mac_reg_write(ETH_MAC_MIIDATA, value & 0xFFFF);

    uint miiaddr = (phy_addr << ETH_MIIADDR_SHIFT)
        | (reg << ETH_MIIREG_SHIFT)
        | ETH_MII_CLKRANGE_150_250M
        | ETH_MII_WRITE
        | ETH_MII_BUSY;
    mac_reg_write(ETH_MAC_MIIADDR, miiaddr);

    return mdio_wait_ready();
}

// Real, exact register sequence from U-Boot's own cv180x_ephy_id_init()
// — see this file's own header comment for sourcing/confirmation this
// is the complete bring-up this exact board needs.
fn void eth_phy_init()
{
    phy_reg_write(ETH_PHY_APB_SEL_OFFSET, 0x0001); // rg_ephy_apb_rw_sel — use APB interface
    phy_reg_write(ETH_PHY_CTRL_OFFSET, 0x0900);    // release [0]=0/shutdown
    phy_reg_write(ETH_PHY_CTRL_OFFSET, 0x0904);    // release [2]=1/dig_rst_n — mii_reg becomes accessible
    phy_reg_write(ETH_PHY_PAGE_SEL_OFFSET, 0x0500); // ANA INIT (PD/EN), switch to MII-page5
    phy_reg_write(ETH_PHY_ANA_OFFSET, 0x0c00);      // release ANA_PD, p5.0x10[13:8]
    phy_reg_write(ETH_PHY_ANA_OFFSET, 0x0c7e);      // release ANA_EN, p5.0x10[7:0]

    // Real PLL-lock check — see ETH_PHY_PLL_LOCK_OFFSET's own comment
    // for why this replaces a blind delay. Direct APB read, not MDIO:
    // control hasn't switched to MDIO yet at this point in the
    // sequence.
    ulong pll_start = rdtime();
    ulong pll_budget = eth_us_to_ticks(10000);
    bool pll_locked = false;
    while (rdtime() - pll_start < pll_budget)
    {
        if (phy_reg_read(ETH_PHY_PLL_LOCK_OFFSET) & ETH_PHY_PLL_LOCK_BIT)
        {
            pll_locked = true;
            break;
        }
        yield();
    }
    print("ethd: PLL lock status = ");
    print(pll_locked ? "locked\n" : "NOT locked within 10ms budget\n");

    phy_reg_write(ETH_PHY_CTRL_OFFSET, 0x0906);     // release [1]=1/ana_rst_n
    phy_reg_write(ETH_PHY_PAGE_SEL_OFFSET, 0x0500);  // switch to MII-page5 again
    phy_reg_write(ETH_PHY_ID1_OFFSET, 0x0043);       // PHY_ID1
    phy_reg_write(ETH_PHY_ID2_OFFSET, 0x5649);       // PHY_ID2
    phy_reg_write(ETH_PHY_APB_SEL_OFFSET, 0x0000);   // switch to MDIO control by ETH_MAC
}

// Real, exact register sequence from U-Boot's own
// cv180x_ephy_led_pinmux() — called together with eth_phy_init()
// above in the real board_init(), unconditionally, under the same
// #if defined(CONFIG_PHY_CVITEK) guard. See board::ETH_LED_PINMUX_PAGE's
// own comment for why this driver only replicated the first of the
// two functions until now.
fn void eth_phy_led_pinmux()
{
    led_pinmux_write(ETH_LED_PADMUX_0_OFFSET, 0x05);
    led_pinmux_write(ETH_LED_PADMUX_1_OFFSET, 0x05);
    sd1_selphy_write(ETH_SD1_CLK_SELPHY_OFFSET, 0x11111111); // (SD1_CLK selphy)
    sd1_selphy_write(ETH_SD1_CMD_SELPHY_OFFSET, 0x11111111); // (SD1_CMD selphy)
}

// The real, complete PHY analog bring-up — see board::ETH_EFUSE_PAGE_0's
// own comment for full sourcing/context. Faithful translation of
// u-boot-2021.10/drivers/net/phy/cvitek.c's own cv182xa_ephy_init(),
// called from the actual PHY framework's own .config callback — the
// piece board.c's own cv180x_ephy_id_init() (eth_phy_init() above)
// was never meant to stand alone for. Steps that function's own
// comments mark "/* do this in board.c */" (shutdown/dig_rst_n
// release, PHY_ID, page-0 switch) are skipped here since eth_phy_init()
// already did them; everything else — including a genuine redundant
// re-run of the ANA_PD/ANA_EN release right after, exactly as the real
// sequence does — is reproduced as-is, not reordered or "cleaned up",
// since matching the real, proven flow exactly matters more here than
// this driver's own sense of tidiness. CV180X-specific LPF/HPF branch
// used (the source has a separate CV181X branch this board doesn't
// need).
fn void eth_phy_analog_init()
{
    phy_reg_write(0x804, 0x0001); // rg_ephy_apb_rw_sel — APB interface

    // ANA INIT (PD/EN), switch to MII-page5 — redundant with
    // eth_phy_init()'s own earlier release, reproduced exactly as the
    // real sequence does.
    phy_reg_write(0x07c, 0x0500);
    phy_reg_write(0x040, 0x0c00); // Release ANA_PD
    phy_reg_write(0x040, 0x0c7e); // Release ANA_EN

    phy_reg_write(0x800, 0x0906); // Release ana_rst_n
    phy_reg_write(0x07c, 0x0500); // @Switch to MII-page5

    // Efuse-based analog trim — TX bias current, echo cancellation,
    // TX/RX termination. Falls back to fixed defaults if the efuse
    // valid-bit for each isn't set (this exact board's own silicon may
    // or may not have these trimmed at the factory — both paths are
    // real, sourced code, not a guess).
    uint efuse_valid = efuse0_read(ETH_EFUSE_VALID_OFFSET);

    if ((efuse_valid & ETH_EFUSE_TXITUNE_FLAG) == ETH_EFUSE_TXITUNE_FLAG)
    {
        uint trim = efuse1_read(ETH_EFUSE_TRIM_A_OFFSET);
        uint val = ((trim >> 24) & 0xFF) | (((trim >> 16) & 0xFF) << 8);
        phy_reg_write(0x064, (phy_reg_read(0x064) & ~(uint)0xFFFF) | (val & 0xFFFF));
    }
    else
    {
        phy_reg_write(0x064, 0x5a5a);
    }

    if ((efuse_valid & ETH_EFUSE_TXECHORC_FLAG) == ETH_EFUSE_TXECHORC_FLAG)
    {
        uint trim = efuse1_read(ETH_EFUSE_TRIM_A_OFFSET);
        uint val = ((trim >> 8) & 0xFF) << 8;
        phy_reg_write(0x054, (phy_reg_read(0x054) & ~(uint)0xFF00) | (val & 0xFF00));
    }
    else
    {
        phy_reg_write(0x054, 0x0000);
    }

    if ((efuse_valid & ETH_EFUSE_TXRXTERM_FLAG) == ETH_EFUSE_TXRXTERM_FLAG)
    {
        uint trim = efuse1_read(ETH_EFUSE_TRIM_B_OFFSET);
        uint val = (((trim >> 28) & 0xF) << 4) | (((trim >> 24) & 0xF) << 8);
        phy_reg_write(0x058, (phy_reg_read(0x058) & ~(uint)0xFF0) | (val & 0xFF0));
    }
    else
    {
        phy_reg_write(0x058, 0x0bb0);
    }

    // ETH_100BaseT
    phy_reg_write(0x05c, 0x0c10); // Rise update
    phy_reg_write(0x068, 0x0003); // Falling phase
    phy_reg_write(0x054, 0x0000); // Double TX Bias Current

    // Switch to MII-page16 — MLT3 Positive phase code, +0
    phy_reg_write(0x07c, 0x1000);
    phy_reg_write(0x068, 0x1000);
    phy_reg_write(0x06c, 0x3020);
    phy_reg_write(0x070, 0x5040);
    phy_reg_write(0x074, 0x7060);
    // MLT3 +I
    phy_reg_write(0x058, 0x1708);
    phy_reg_write(0x05c, 0x3827);
    phy_reg_write(0x060, 0x5748);
    phy_reg_write(0x064, 0x7867);

    // Switch to MII-page17 — MLT3 Negative phase code, -0
    phy_reg_write(0x07c, 0x1100);
    phy_reg_write(0x040, 0x9080);
    phy_reg_write(0x044, 0xb0a0);
    phy_reg_write(0x048, 0xd0c0);
    phy_reg_write(0x04c, 0xf0e0);
    // MLT3 -I
    phy_reg_write(0x050, 0x9788);
    phy_reg_write(0x054, 0xb8a7);
    phy_reg_write(0x058, 0xd7c8);
    phy_reg_write(0x05c, 0xf8e7);

    // @Switch to MII-page5
    phy_reg_write(0x07c, 0x0500);
    phy_reg_write(0x040, 0x0001 | phy_reg_read(0x040)); // En TX_Rterm
    phy_reg_write(0x04c, 0x0820 | phy_reg_read(0x04c)); // change rx vcm

    // Link Pulse — the actual analog waveform shape for NLP/link
    // pulses; without this, the PHY may never generate a spec-
    // compliant link signal at all even with every digital control bit
    // otherwise correct — this is this driver's own leading hypothesis
    // for why PLL-locked/BMCR-clean/MDIO-working still showed zero
    // link on three independent peer devices before this fix.
    // Switch to MII-page10
    phy_reg_write(0x07c, 0x0a00);
    phy_reg_write(0x040, 0x3e00);
    phy_reg_write(0x044, 0x7864);
    phy_reg_write(0x048, 0x6470);
    phy_reg_write(0x04c, 0x5f62);
    phy_reg_write(0x050, 0x5a5a);
    phy_reg_write(0x054, 0x5458);
    phy_reg_write(0x058, 0xb23a);
    phy_reg_write(0x05c, 0x94a0);
    phy_reg_write(0x060, 0x9092);
    phy_reg_write(0x064, 0x8a8e);
    phy_reg_write(0x068, 0x8688);
    phy_reg_write(0x06c, 0x8484);
    phy_reg_write(0x070, 0x0082);

    // TP_IDLE — Switch to MII-page11
    phy_reg_write(0x07c, 0x0b00);
    phy_reg_write(0x040, 0x5252);
    phy_reg_write(0x044, 0x5252);
    phy_reg_write(0x048, 0x4B52);
    phy_reg_write(0x04c, 0x3D47);
    phy_reg_write(0x050, 0xAA99);
    phy_reg_write(0x054, 0x989E);
    phy_reg_write(0x058, 0x9395);
    phy_reg_write(0x05C, 0x9091);
    phy_reg_write(0x060, 0x8E8F);
    phy_reg_write(0x064, 0x8D8E);
    phy_reg_write(0x068, 0x8C8C);
    phy_reg_write(0x06C, 0x8B8B);
    phy_reg_write(0x070, 0x008A);

    // ETH 10BaseT Data — Switch to MII-page13
    phy_reg_write(0x07c, 0x0d00);
    phy_reg_write(0x040, 0x1E0A);
    phy_reg_write(0x044, 0x3862);
    phy_reg_write(0x048, 0x1E62);
    phy_reg_write(0x04c, 0x2A08);
    phy_reg_write(0x050, 0x244C);
    phy_reg_write(0x054, 0x1A44);
    phy_reg_write(0x058, 0x061C);

    // Switch to MII-page14
    phy_reg_write(0x07c, 0x0e00);
    phy_reg_write(0x040, 0x2D30);
    phy_reg_write(0x044, 0x3470);
    phy_reg_write(0x048, 0x0648);
    phy_reg_write(0x04c, 0x261C);
    phy_reg_write(0x050, 0x3160);
    phy_reg_write(0x054, 0x2D5E);

    // Switch to MII-page15
    phy_reg_write(0x07c, 0x0f00);
    phy_reg_write(0x040, 0x2922);
    phy_reg_write(0x044, 0x366E);
    phy_reg_write(0x048, 0x0752);
    phy_reg_write(0x04c, 0x2556);
    phy_reg_write(0x050, 0x2348);
    phy_reg_write(0x054, 0x0C30);

    // Switch to MII-page16
    phy_reg_write(0x07c, 0x1000);
    phy_reg_write(0x040, 0x1E08);
    phy_reg_write(0x044, 0x3868);
    phy_reg_write(0x048, 0x1462);
    phy_reg_write(0x04c, 0x1A0E);
    phy_reg_write(0x050, 0x305E);
    phy_reg_write(0x054, 0x2F62);

    // LED PAD MUX — skipped, done by eth_phy_led_pinmux() above (the
    // real source has this same block commented out for the same
    // reason: it's redundant with board.c's own call).

    // LED — Switch to MII-page1
    phy_reg_write(0x07c, 0x0100);
    // select LED_LNK/SPD/DPX out to LED_PAD
    phy_reg_write(0x068, phy_reg_read(0x068) & ~(uint)0x0f00);

    // Switch to MII-page19
    phy_reg_write(0x07c, 0x1300);
    phy_reg_write(0x058, 0x0012);
    phy_reg_write(0x05C, 0x6848); // agc max/min swing

    // Switch to MII-page18 — LPF/HPF filter coefficients. CV180X
    // ("phobos") branch specifically — the source also has a separate
    // CV181X ("mars") branch this board doesn't need.
    phy_reg_write(0x07c, 0x1200);
    phy_reg_write(0x048, 0x0801);
    phy_reg_write(0x04C, 0x1717);
    phy_reg_write(0x05C, 0x0108);
    phy_reg_write(0x050, 0x3afc);
    phy_reg_write(0x054, 0x08d3);
    phy_reg_write(0x060, 0x00fb);

    // Switch to MII-page0
    phy_reg_write(0x07c, 0x0000);

    // EPHY start auto-negotiation procedure — a real, distinct trigger
    // (0x090e) never written before now; board.c's own sequence only
    // ever reaches 0x0906 (ana_rst_n release), missing the extra bit
    // this adds.
    phy_reg_write(0x800, 0x090e);

    // EPHY resets to half-duplex; force full-duplex (matches this
    // sequence's own "from jinyu.zhao" comment in the real source).
    phy_reg_write(0x000, phy_reg_read(0x000) | 0x100);

    phy_reg_write(0x804, 0x0000); // switch to MDIO control by ETH_MAC
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

fn void main() @export("main")
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

        // yield()-paced, not a bare spin — see user/usbd.c3's own
        // SYS_YIELD comment for why a genuinely syscall-free poll here
        // is a real deadlock risk on this kernel, not just wasted CPU.
        ulong poll_start = rdtime();
        while (rdtime() - poll_start < eth_us_to_ticks(500000)) { yield(); }
    }
}
