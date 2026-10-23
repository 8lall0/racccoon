module user;

// The JH7110's sys iomux (sys pinctrl, 0x13040000) for user-mode drivers
// that own a page of it through their board device (the Orange Pi's
// "wifi" device: brcmd). Layout from Linux pinctrl-starfive-jh7110(-sys).c:
//   GPIO output: four GPIOs per 32-bit register, one byte each (offset
//     4*(n/4), shift 8*(n%4)); DOEN at 0x000 (6-bit field, 0 = output
//     enabled), DOUT at 0x040 (7-bit field, 1 = high).
//   Pad config: one register per pad at 0x120 + 4*pad (pads 0-74); bits
//     IE 0, DS 2:1 (3 = 12 mA), PU 3, PD 4, SLEW 5, SMT 6.
const uptr JH7110_SYS_IOMUX = 0x13040000;
const uint JH7110_IOMUX_DOEN = 0x000;
const uint JH7110_IOMUX_DOUT = 0x040;
const uint JH7110_IOMUX_PADCFG = 0x120;
const uint JH7110_PADCFG_IE = 1u << 0;
const uint JH7110_PADCFG_DS_12MA = 3u << 1;
const uint JH7110_PADCFG_PU = 1u << 3;
const uint JH7110_PADCFG_PD = 1u << 4;

// Sys GPIO `gpio` as an output, driven `high` or low.
fn void jh7110_gpio_out(uint gpio, bool high)
{
	uint off = 4 * (gpio / 4);
	uint shift = 8 * (gpio % 4);
	uptr doen = JH7110_SYS_IOMUX + JH7110_IOMUX_DOEN + off;
	uptr dout = JH7110_SYS_IOMUX + JH7110_IOMUX_DOUT + off;
	uint v = mmio_read32(dout);
	v = (v & ~(0x7Fu << shift)) | ((high ? 1u : 0u) << shift);
	mmio_write32(dout, v);
	uint e = mmio_read32(doen);
	e = e & ~(0x3Fu << shift); // 0 = output enabled
	mmio_write32(doen, e);
}

// sdio0's pads (PAD_SD0_CLK 64 .. PAD_SD0_DATA7 73) as jh7110-common.dtsi's
// mmc0_pins sets them: pull-up, 12 mA, input enabled. Nothing in the boot
// chain does (U-Boot gives up on mmc 0 first).
fn void jh7110_sdio0_pads()
{
	for (uint pad = 64; pad <= 73; pad++)
	{
		uptr reg = JH7110_SYS_IOMUX + (uptr)(JH7110_IOMUX_PADCFG + 4 * pad);
		uint v = mmio_read32(reg);
		v = (v & ~(JH7110_PADCFG_IE | (3u << 1) | JH7110_PADCFG_PU | JH7110_PADCFG_PD))
			| JH7110_PADCFG_IE | JH7110_PADCFG_DS_12MA | JH7110_PADCFG_PU;
		mmio_write32(reg, v);
	}
}
