module user;

// gpiod's JH7110 backend (the Orange Pi RV) — the board-neutral core is
// user/gpio/gpiod.c3. The sys pinctrl block (sys iomux, 0x13040000)
// carries the SoC's GPIO0-63 and the pad configuration of pads 0-74; one
// page, owned by gpiod (the board's "gpio" device), so drivers ask for
// pins over IPC (brcmd: the AP6256's WL_REG_ON, its WL_HOST_WAKE line and
// the sdio0 pads). Layout from Linux pinctrl-starfive-jh7110(-sys).c:
//   GPIO output: four GPIOs per 32-bit register, one byte each (offset
//     4*(n/4), shift 8*(n%4)); DOEN at 0x000 (6-bit field, 0 = output
//     enabled, 1 = disabled), DOUT at 0x040 (7-bit field, 1 = high).
//   GPIO input: GPIOIN at 0x118 (+4 for 32-63), one bit per GPIO — only
//     live once GPIOEN (0x0dc) is 1: before that it reads all zeroes
//     (found on the board 2026-10-23).
//   Interrupts (one PLIC source for all 64, 86): per GPIO bit, word 0 for
//     0-31 and +4 for 32-63 — IS 0x0e0 (1 edge / 0 level), IC 0x0e8
//     (edge clear, write the bit 0 then 1), IBE 0x0f0 (both edges), IEV
//     0x0f8 (1 rising / low level, 0 falling / high level), IE 0x100
//     (1 = unmasked), RIS 0x108 raw, MIS 0x110 masked.
//   Pad config: one register per pad at 0x120 + 4*pad (pads 0-74); bits
//     IE 0, DS 2:1 (3 = 12 mA), PU 3, PD 4, SLEW 5, SMT 6.
const uptr JH_IOMUX = 0x13040000;
const uint JH_DOEN = 0x000;
const uint JH_DOUT = 0x040;
const uint JH_GPIOEN = 0x0dc;
const uint JH_IS = 0x0e0;
const uint JH_IC = 0x0e8;
const uint JH_IBE = 0x0f0;
const uint JH_IEV = 0x0f8;
const uint JH_IE = 0x100;
const uint JH_MIS = 0x110;
const uint JH_GPIOIN = 0x118;
const uint JH_PADCFG = 0x120;
const uint JH_PAD_IE = 1u << 0;
const uint JH_PAD_DS_MASK = 3u << 1;
const uint JH_PAD_DS_12MA = 3u << 1;
const uint JH_PAD_PU = 1u << 3;
const uint JH_PAD_PD = 1u << 4;

// The pins gpiod hands out on this board: the AP6256's two lines and the
// sdio0 pads (pad config only). Everything else on the block (the UART
// console, the microSD's sdio1, Ethernet, the 40-pin header) is refused
// until someone needs it.
const uint JH_WL_HOST_WAKE = 21;   // jh7110-orangepi-rv.dts: "out-of-band IRQ on GPIO21"
const uint JH_WL_REG_ON = 62;      // the wifi_pwrseq reset-gpios
const uint JH_PAD_SD0_FIRST = 64;  // PAD_SD0_CLK .. PAD_SD0_DATA7
const uint JH_PAD_SD0_LAST = 73;

fn uptr jh_reg(uint off) { return JH_IOMUX + (uptr)off; }

fn void jh_bit(uint off, uint pin, bool on)
{
	uptr r = jh_reg(off + 4 * (pin / 32));
	uint m = 1u << (pin % 32);
	uint v = mmio_read32(r);
	mmio_write32(r, on ? (v | m) : (v & ~m));
}

// --- the backend interface gpiod.c3 calls --------------------------------

fn bool gb_pin_allowed(uint pin)
{
	return pin == JH_WL_HOST_WAKE || pin == JH_WL_REG_ON || (pin >= JH_PAD_SD0_FIRST && pin <= JH_PAD_SD0_LAST);
}

fn bool jh_is_gpio(uint pin) { return pin < 64; }

fn void gb_set_dir(uint pin, bool output)
{
	if (!jh_is_gpio(pin)) { return; }
	uptr r = jh_reg(JH_DOEN + 4 * (pin / 4));
	uint shift = 8 * (pin % 4);
	mmio_write32(r, (mmio_read32(r) & ~(0x3Fu << shift)) | ((output ? 0u : 1u) << shift));
}

fn void gb_write(uint pin, bool value)
{
	if (!jh_is_gpio(pin)) { return; }
	uptr r = jh_reg(JH_DOUT + 4 * (pin / 4));
	uint shift = 8 * (pin % 4);
	mmio_write32(r, (mmio_read32(r) & ~(0x7Fu << shift)) | ((value ? 1u : 0u) << shift));
}

fn bool gb_read(uint pin)
{
	if (!jh_is_gpio(pin)) { return false; }
	return (mmio_read32(jh_reg(JH_GPIOIN + 4 * (pin / 32))) & (1u << (pin % 32))) != 0;
}

// Pad electricals, GPIO_PAD_* flags (user/gpio/gpio_client.c3).
fn bool gb_pad(uint pin, uint flags)
{
	if (pin > 74) { return false; }
	uptr r = jh_reg(JH_PADCFG + 4 * pin);
	uint v = mmio_read32(r) & ~(JH_PAD_IE | JH_PAD_DS_MASK | JH_PAD_PU | JH_PAD_PD);
	if ((flags & GPIO_PAD_INPUT) != 0) { v |= JH_PAD_IE; }
	if ((flags & GPIO_PAD_PULL_UP) != 0) { v |= JH_PAD_PU; }
	if ((flags & GPIO_PAD_PULL_DOWN) != 0) { v |= JH_PAD_PD; }
	if ((flags & GPIO_PAD_STRONG) != 0) { v |= JH_PAD_DS_12MA; }
	mmio_write32(r, v);
	return true;
}

fn bool gb_irq_supported() { return true; }

fn void gb_irq_config(uint pin, uint trigger)
{
	if (!jh_is_gpio(pin)) { return; }
	bool edge = trigger == GPIO_TRIG_RISING || trigger == GPIO_TRIG_FALLING;
	bool iev = trigger == GPIO_TRIG_RISING || trigger == GPIO_TRIG_LEVEL_LOW;
	jh_bit(JH_IS, pin, edge);
	jh_bit(JH_IBE, pin, false);
	jh_bit(JH_IEV, pin, iev);
	gb_irq_clear(pin);
}

fn void gb_irq_enable(uint pin, bool on) { if (jh_is_gpio(pin)) { jh_bit(JH_IE, pin, on); } }

// Edge flags clear on a 0 -> 1 write of the bit (Linux jh7110_irq_ack);
// a level source clears itself once the line drops.
fn void gb_irq_clear(uint pin)
{
	if (!jh_is_gpio(pin)) { return; }
	jh_bit(JH_IC, pin, false);
	jh_bit(JH_IC, pin, true);
}

fn bool gb_irq_fired(uint pin)
{
	if (!jh_is_gpio(pin)) { return false; }
	return (mmio_read32(jh_reg(JH_MIS + 4 * (pin / 32))) & (1u << (pin % 32))) != 0;
}

fn void gb_init()
{
	// jh7110_sys_init_hw: everything masked, edge flags cleared, GPIOEN on.
	mmio_write32(jh_reg(JH_IE), 0);
	mmio_write32(jh_reg(JH_IE + 4), 0);
	mmio_write32(jh_reg(JH_IC), 0xFFFFFFFF);
	mmio_write32(jh_reg(JH_IC + 4), 0xFFFFFFFF);
	mmio_write32(jh_reg(JH_GPIOEN), 1);
	print("gpiod: JH7110 sys GPIO, interrupts on PLIC 86\n");
}

fn ulong gb_tick_ticks() { return 0; }
fn void gb_tick() {}
