module user;

// dwmac: the generic Synopsys DesignWare ("stmmac") Ethernet MAC
// register/MDIO layer for the Milk-V Duo — the "how" layer for
// user/net/ethd.c3's own orchestration, and the layer any OTHER real
// DW-MAC-based board could reuse unchanged (this board's own embedded-
// PHY specifics live in user/net/ephy.c3 instead, a genuinely separate
// vendor concern from the MAC itself). Split out from what used to be
// one combined ethd.c3 once it grew large enough that "the part that
// talks to the MAC" and "the part that decides what to do next" were
// hard to tell apart in one file (docs/devlog.md) — same reasoning,
// same shape as usbd.c3's own dwc2.c3 split.
//
// Register offsets/bit layouts sourced from duo-buildroot-sdk's own
// u-boot-2021.10/drivers/net/designware.c/.h — the generic DW MAC
// driver this board's own "cvitek,ethernet" devicetree compatible
// string binds to; confirmed genuinely standard DW MAC via the real
// devicetree's own snps,*/clock-names="stmmaceth" properties
// (cv180x_base.dtsi), not proprietary despite the vendor compatible
// string, unlike DWC2 USB's own fully-custom register additions.

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

// --- Base address (duplicated locally — board is kernel-only,
// unreachable from user-mode code, same convention every other driver
// here already follows).
const uint ETH_BASE = 0x04070000;

const uint ETH_TIMEBASE_HZ = 25000000; // same sourcing as user/block/sdd.c3's/user/usb/dwc2.c3's own duplicate — see either's header comment

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
