module user;

import std::nolibc::mem;

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
const uint ETH_CONF_PORTSELECT     = 1 << 15; // MII_PORTSELECT in the real driver — set for MII, clear for RMII (this board); see eth_dma_init()'s own comment
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
const uint MII_ANAR   = 4; // Auto-Negotiation Advertisement Register — what we advertised
const uint MII_ANLPAR = 5; // Auto-Negotiation Link Partner Ability Register — what the peer advertised back
const uint MII_BMSR_LINK_STATUS = 1 << 2;
const uint MII_BMSR_AUTONEG_COMPLETE = 1 << 5;
const uint MII_ANLPAR_100_FULL = 1 << 8;
const uint MII_ANLPAR_100_HALF = 1 << 7;
const uint MII_ANLPAR_10_FULL  = 1 << 6;
const uint MII_ANLPAR_10_HALF  = 1 << 5;
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

// mmio_read32 / mmio_write32: user/user.c3 (shared).

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

// --- DMA descriptor ring (Ethernet Phase 2 — real packet TX/RX). See
// docs/devlog.md for the full sourcing trail. Offsets/bits below are
// straight from duo-buildroot-sdk's own u-boot-2021.10/drivers/net/
// designware.c/.h — the same generic DW MAC driver this board's own
// "cvitek,ethernet" devicetree compatible string binds to (see this
// file's own header comment). This board does NOT define
// CONFIG_DW_ALTDESCRIPTOR (confirmed absent from every cv180x-*
// config/board file in the SDK), so the plain (non-alt) descriptor
// bit layout applies throughout below.
//
// Deliberate simplification vs. the real driver's 16-entry ring:
// exactly one TX descriptor and one RX descriptor, each self-chained
// (dmamac_next points to its own physical address) — a valid
// degenerate one-entry ring, matching the one-outstanding-transfer
// discipline this codebase already uses everywhere else (USB's single
// host channel, diskd/sdd's one request at a time).
const uint ETH_DMA_BASE = ETH_BASE + 0x1000;

const uint DMA_BUS_MODE       = 0x00;
const uint DMA_TX_POLL_DEMAND = 0x04;
const uint DMA_RX_POLL_DEMAND = 0x08;
const uint DMA_RX_BASE_ADDR   = 0x0C;
const uint DMA_TX_BASE_ADDR   = 0x10;
const uint DMA_STATUS         = 0x14;
const uint DMA_CONTROL        = 0x18; // "operation mode" in the real header
const uint DMA_INTR_ENA       = 0x1C; // never touched — polling only, matching every other device in this codebase; u-boot's own driver never uses IRQs either

fn uint dma_reg_read(uint offset) { return mmio_read32((uptr)(ETH_DMA_BASE + offset)); }
fn void dma_reg_write(uint offset, uint v) { mmio_write32((uptr)(ETH_DMA_BASE + offset), v); }

const uint DMA_BUS_MODE_SRST        = 1 << 0;
const uint DMA_BUS_MODE_PRIORXTX_41 = 3 << 14; // RX:TX priority ratio 4:1
const uint DMA_BUS_MODE_FIXEDBURST  = 1 << 16;
const uint DMA_BUS_MODE_PBL_8       = 8 << 8; // Programmable Burst Length — u-boot's own CONFIG_DW_GMAC_DEFAULT_DMA_PBL default, no board override found for this SoC

const uint DMA_CONTROL_RXSTART      = 1 << 1;
const uint DMA_CONTROL_TXSTART      = 1 << 13;
const uint DMA_CONTROL_FLUSHTXFIFO  = 1 << 20;
const uint DMA_CONTROL_STOREFORWARD = 1 << 21;

const uint DMA_POLL_DEMAND_KICK = 0xFFFFFFFF; // POLL_DATA in the real header — value is arbitrary, any write at all rings the doorbell

// Descriptor layout: 16 bytes, native (CPU) endianness — no byte-swap
// needed, this SoC's DMA engine and CPU share the same endianness.
// dmamac_addr is the buffer pointer; dmamac_next is the NEXT
// descriptor's own physical address (chained-list model, not a
// ring-end-bit model — matches the real driver exactly, just with a
// one-entry chain instead of sixteen).
struct Dw_dma_desc @packed
{
    uint txrx_status;
    uint dmamac_cntl;
    uint dmamac_addr;
    uint dmamac_next;
}

const uint DESC_OWNBYDMA = 0x80000000; // bit 31, same for both tx/rx status words — plain hex literal, see user/usb/dwc2.c3's own USB_HCCHAR_CHEN comment for why a bit-31 constant is written this way rather than `1 << 31`
const uint DESC_TXCTRL_TXLAST    = 1 << 30;
const uint DESC_TXCTRL_TXFIRST   = 1 << 29;
const uint DESC_TXCTRL_TXCHAIN   = 1 << 24;
const uint DESC_TXCTRL_SIZE1MASK = 0x7FF;
const uint DESC_RXCTRL_RXCHAIN   = 1 << 24;
const uint DESC_RXCTRL_SIZE1MASK = 0x7FF;
const uint DESC_RXSTS_FRMLENMSK   = 0x3FFF << 16;
const uint DESC_RXSTS_FRMLENSHFT  = 16;

const uint ETH_DMA_BUF_SIZE = 1600; // MAC_MAX_FRAME_SZ in the real driver — covers a full 1514-byte frame with slack
const uint ETH_ZLEN = 60; // minimum real Ethernet frame size — short frames are zero-padded up to this before transmit, matching the real driver's own _dw_eth_send()

// Fixed layout within the single physical page setup_ethd_mappings
// allocates (see src/process.c3): tx descriptor, rx descriptor, tx
// buffer, rx buffer, back to back — computed once from the base
// physical address SYS_ETHD_INFO hands back.
Dw_dma_desc* eth_tx_desc;
Dw_dma_desc* eth_rx_desc;
char* eth_tx_buf;
char* eth_rx_buf;

fn void eth_dma_init(uptr dma_base)
{
    eth_tx_desc = (Dw_dma_desc*)dma_base;
    eth_rx_desc = (Dw_dma_desc*)(dma_base + 16);
    eth_tx_buf  = (char*)(dma_base + 32);
    eth_rx_buf  = (char*)(dma_base + 32 + ETH_DMA_BUF_SIZE);

    uptr tx_desc_paddr = dma_base;
    uptr rx_desc_paddr = dma_base + 16;
    uptr tx_buf_paddr  = dma_base + 32;
    uptr rx_buf_paddr  = dma_base + 32 + ETH_DMA_BUF_SIZE;

    // MII_PORTSELECT (MAC_CONF bit 15) must be explicitly cleared
    // before the DMA soft reset below, not just left whatever it
    // powered up as — this board is RMII (confirmed via the real
    // devicetree's own phy-mode="rmii"), and the real driver's own
    // designware_eth_init() comment is explicit: "When a MII PHY is
    // used, we must set the PS bit for the DMA reset to succeed" —
    // the converse holds for RMII, where PS must be clear. Found on
    // real hardware after a round where every DMA register looked
    // fine (soft reset completed, descriptors armed, TX kicked with
    // no error) yet nothing ever reached a real peer on the wire —
    // exactly the signature of the MAC's digital core being
    // misconfigured for the wrong interface width/timing underneath
    // an otherwise-correct-looking register sequence.
    mac_reg_write(ETH_MAC_CONF, mac_reg_read(ETH_MAC_CONF) & ~ETH_CONF_PORTSELECT);

    // Soft-reset the DMA engine, poll for it to self-clear — same
    // idiom as every other reset-and-poll sequence in this codebase.
    dma_reg_write(DMA_BUS_MODE, DMA_BUS_MODE_SRST);
    ulong reset_start = rdtime();
    ulong reset_budget = eth_us_to_ticks(3000000); // real driver's own 3-second budget
    while ((dma_reg_read(DMA_BUS_MODE) & DMA_BUS_MODE_SRST) != 0)
    {
        if (rdtime() - reset_start > reset_budget)
        {
            print("ethd: DMA soft reset timed out\n");
            break;
        }
        yield();
    }

    // TX descriptor: self-chained (one-entry ring), CPU-owned until a
    // real frame is queued.
    eth_tx_desc.txrx_status = 0;
    eth_tx_desc.dmamac_cntl = DESC_TXCTRL_TXCHAIN;
    eth_tx_desc.dmamac_addr = (uint)tx_buf_paddr;
    eth_tx_desc.dmamac_next = (uint)tx_desc_paddr;

    // RX descriptor: self-chained, pre-armed DMA-owned so the engine
    // can start writing an incoming frame immediately.
    eth_rx_desc.dmamac_cntl = (ETH_DMA_BUF_SIZE & DESC_RXCTRL_SIZE1MASK) | DESC_RXCTRL_RXCHAIN;
    eth_rx_desc.dmamac_addr = (uint)rx_buf_paddr;
    eth_rx_desc.dmamac_next = (uint)rx_desc_paddr;
    eth_rx_desc.txrx_status = DESC_OWNBYDMA;

    dma_reg_write(DMA_RX_BASE_ADDR, (uint)rx_desc_paddr);
    dma_reg_write(DMA_TX_BASE_ADDR, (uint)tx_desc_paddr);

    dma_reg_write(DMA_BUS_MODE, DMA_BUS_MODE_FIXEDBURST | DMA_BUS_MODE_PRIORXTX_41 | DMA_BUS_MODE_PBL_8);

    // Two genuinely separate writes, matching the real driver exactly
    // — not combined into one, even though the bits involved are
    // disjoint and a single combined write reaches the same final
    // register value. FLUSHTXFIFO needs real time to at least begin
    // settling before TXSTART is asserted; a single write gives it
    // none at all (RXSTART/TXSTART would be requested in the very
    // same bus cycle as the flush), where two separate MMIO writes
    // (each a full instruction, not free) give it a little.
    dma_reg_write(DMA_CONTROL, dma_reg_read(DMA_CONTROL) | DMA_CONTROL_FLUSHTXFIFO | DMA_CONTROL_STOREFORWARD);
    dma_reg_write(DMA_CONTROL, dma_reg_read(DMA_CONTROL) | DMA_CONTROL_RXSTART | DMA_CONTROL_TXSTART);
}

// Sends one frame (already built by user/net/eth_proto.c3 or the
// self-test) — copies it into the TX buffer, short frames zero-padded
// up to ETH_ZLEN (matches the real driver), rings the poll-demand
// doorbell. Returns false if the single TX descriptor is still
// DMA-owned (a previous send hasn't completed) — the caller only ever
// has one frame in flight at a time, matching this driver's own
// one-outstanding-transfer discipline throughout.
fn bool eth_dma_send(char* data, uint len)
{
    if ((eth_tx_desc.txrx_status & DESC_OWNBYDMA) != 0) { return false; }

    mem::copy(eth_tx_buf, data, len);
    uint send_len = len;
    if (send_len < ETH_ZLEN)
    {
        mem::set(&eth_tx_buf[send_len], 0, (sz)(ETH_ZLEN - send_len));
        send_len = ETH_ZLEN;
    }

    eth_tx_desc.dmamac_cntl = DESC_TXCTRL_TXCHAIN | DESC_TXCTRL_TXFIRST | DESC_TXCTRL_TXLAST | (send_len & DESC_TXCTRL_SIZE1MASK);
    eth_tx_desc.txrx_status = DESC_OWNBYDMA;

    dma_reg_write(DMA_TX_POLL_DEMAND, DMA_POLL_DEMAND_KICK);
    return true;
}

// Non-blocking poll for a received frame — copies it into buf_out
// (must have room for ETH_DMA_BUF_SIZE bytes) and sets *len_out on
// success, then re-arms the single RX descriptor for the next frame.
// Returns false if nothing has arrived (the descriptor is still
// DMA-owned).
fn bool eth_dma_try_recv(char* buf_out, uint* len_out)
{
    if ((eth_rx_desc.txrx_status & DESC_OWNBYDMA) != 0) { return false; }

    uint len = (eth_rx_desc.txrx_status & DESC_RXSTS_FRMLENMSK) >> DESC_RXSTS_FRMLENSHFT;
    if (len > ETH_DMA_BUF_SIZE) { len = ETH_DMA_BUF_SIZE; } // defensive — never trust a hardware-reported length blindly
    mem::copy(buf_out, eth_rx_buf, len);
    *len_out = len;

    // Re-arm — give the descriptor back to DMA so it can receive the
    // next frame into the same buffer (equivalent to the real
    // driver's own _dw_free_pkt()).
    eth_rx_desc.txrx_status = DESC_OWNBYDMA;
    return true;
}
