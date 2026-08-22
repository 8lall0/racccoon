module user;

// ephy: the Cvitek embedded-PHY-specific bring-up for the Milk-V
// Duo's on-chip Ethernet PHY — a genuinely separate vendor concern
// from the generic DW MAC layer (user/net/dwmac.c3), not just an
// arbitrary split: this analog/init sequence is specific to this
// exact embedded PHY, while dwmac.c3's own register layer would be
// unchanged on a board with a different (e.g. external RMII) PHY.
// Split out from what used to be one combined ethd.c3 once it grew
// large enough that "the part that talks to the wire" and "the part
// that decides what to do next" were hard to tell apart in one file
// (docs/devlog.md) — same reasoning, same shape as usbd.c3's own
// dwc2.c3 split.
//
// Register offsets/values sourced directly from duo-buildroot-sdk's
// own driver code:
//   - eth_phy_init(): U-Boot's own cv180x_ephy_id_init() (board/cvitek/
//     cv180x/board.c) — called unconditionally in board_init() on real
//     ASIC hardware. Confirmed this alone is NOT the complete bring-up
//     this exact board needs (see eth_phy_analog_init()'s own comment)
//     — the real vendor Linux glue driver (linux_5.10/drivers/net/
//     ethernet/stmicro/stmmac/dwmac-cvitek.c)'s own PHY-reset step only
//     fires if the devicetree provides an `ephy_ctl_reg` property or an
//     enabled `phy-reset-gpios`; this board's own cv180x_base.dtsi has
//     neither, so Linux does no PHY bring-up at all for this exact
//     board, relying entirely on U-Boot having already run this.
//   - eth_phy_analog_init(): the REAL, complete bring-up — a faithful
//     translation of u-boot-2021.10/drivers/net/phy/cvitek.c's own
//     cv182xa_ephy_init(), called from the actual PHY framework's own
//     .config callback. Found only after eth_phy_init() alone (a real,
//     genuinely-called board.c function) left every digital PHY fact
//     checked out healthy — PLL locked, BMCR clean, MDIO working — with
//     zero link ever detected by three independent peer devices; see
//     this function's own comment below for the full trace.

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

// mmio_read32/write32 themselves live in user/net/dwmac.c3 — same
// module ("module user;" everywhere in this directory, matching
// user/fs/fat32.c3's own established precedent), so no import or
// redefinition needed here, same as eth_us_to_ticks() below.
fn uint phy_reg_read(uint offset) { return mmio_read32((uptr)(ETH_PHY_BASE + offset)); }
fn void phy_reg_write(uint offset, uint v) { mmio_write32((uptr)(ETH_PHY_BASE + offset), v); }

fn uint clk_reg_read(uint offset) { return mmio_read32((uptr)(ETH_CLK_BASE + offset)); }
fn void clk_reg_write(uint offset, uint v) { mmio_write32((uptr)(ETH_CLK_BASE + offset), v); }

fn void led_pinmux_write(uint offset, uint v) { mmio_write32((uptr)(ETH_LED_PINMUX_BASE + offset), v); }
fn void sd1_selphy_write(uint offset, uint v) { mmio_write32((uptr)(ETH_SD1_SELPHY_BASE + offset), v); }

fn uint efuse0_read(uint offset) { return mmio_read32((uptr)(ETH_EFUSE_BASE_0 + offset)); }
fn uint efuse1_read(uint offset) { return mmio_read32((uptr)(ETH_EFUSE_BASE_1 + offset)); }

// Real, exact register sequence from U-Boot's own cv180x_ephy_id_init()
// — see this file's own header comment for sourcing/confirmation this
// is NOT the complete bring-up this exact board needs on its own (see
// eth_phy_analog_init() below for the rest).
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

// The real, complete PHY analog bring-up — see this file's own header
// comment for full sourcing/context. Faithful translation of
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
