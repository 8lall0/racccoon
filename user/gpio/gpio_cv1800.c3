module user;

// gpiod's CV1800B backend (the Milk-V Duo) — the board-neutral core is
// user/gpio/gpiod.c3. The CV1800B's Synopsys DesignWare APB GPIO
// controller (5 independent single-port banks, `snps,dw-apb-gpio` in
// the vendor's own devicetree, u-boot-2021.10/arch/riscv/dts/
// cv180x_base.dtsi) — a standard, simple block, one 4KB page per bank,
// identical register layout in every bank:
//   +0x00 SWPORTx_DR   — data-output register (bit = value driven,
//                        only meaningful while that bit's DDR bit is 1)
//   +0x04 SWPORTx_DDR  — direction register (1 = output, 0 = input)
//   +0x50 EXT_PORTx    — external pin state (read the REAL input value
//                        here, not SWPORTx_DR — confirmed via
//                        linux_5.10/drivers/gpio/gpio-dwapb.c's own
//                        bgpio_init() call, a plain 32-bit generic-gpio
//                        chip with no clock-enable bit found anywhere
//                        in the devicetree, unlike the Ethernet MAC's
//                        own ETH_CLK_EN gating — not independently
//                        confirmed on real hardware yet, this driver's
//                        own boot-time pin toggle is the first real
//                        test of that assumption).
//
// Poll-only, deliberately — no PLIC interrupt wiring, even though this
// same IP block also has a real interrupt-control register set at
// +0x30 (INTEN) through +0x4c (PORTA_EOI), and a specific PLIC IRQ
// number (60 for bank A) was found in an upstream, in-progress Linux
// mainline devicetree patch (not present in this project's own local
// vendor SDK checkout — that has zero "interrupts =" on any GPIO
// devicetree node at all). Investigated and explicitly deferred: this
// project's one real attempt at any non-timer, non-virtio PLIC
// interrupt (IRQ_SDHCI, see boards/duo/board.c3's own comment and
// docs/devlog.md) put the CPU into a PERMANENT SCAUSE_SUPERVISOR_
// EXTERNAL trap storm the moment that one PLIC enable-bit was set —
// independent of whether the device ever asserted anything — requiring
// a reflash to escape, not just a bad log. Whether that's specific to
// IRQ 36 or affects this whole PLIC context was never resolved. A
// follow-up check for reassurance (does the vendor's own shipping
// Linux get GPIO, or any peripheral, interrupt working reliably on
// this exact RISC-V chip?) found none: no real Linux devicetree exists
// for this chip in the vendor SDK at all (only for its ARM sibling,
// which uses GIC, not this PLIC), and even the SD controller's own
// devicetree node — the one whose real-hardware interrupt attempt
// caused the storm — has no "interrupts =" property in the vendor's
// own shared devicetree either. Given a demonstrated, permanent,
// reflash-requiring failure mode and no positive evidence the
// underlying mechanism works reliably on this exact silicon at all,
// staying poll-only here matches USB/Ethernet's own already-deliberate
// choice for the identical reason. Revisit only with real hardware
// debug tooling (logic analyzer, vendor engineering support) able to
// actually resolve the open question, not by guessing again.
//
// Owns GPIO bank A/C and the shared pinmux page exclusively — matches
// this project's own diskd/sdd/usbd/ethd pattern (one owning process
// per real device, everyone else talks over IPC) rather than mapping
// raw MMIO into arbitrary processes. This matters concretely here:
// PINMUX_BASE is the exact same physical page SD_PINMUX_PAGE/
// USB_PINMUX_PAGE/ETH_LED_PINMUX_PAGE already map for their own pads —
// a process with raw access to it could reconfigure e.g. SD0_PWR_EN's
// own function-select bits by accident and break the SD card this
// project boots its whole root filesystem from.
//
// The pin allowlist below is not just a safety boundary, it's the
// whole reason this can be a fixed table at all: there's no formula
// from a (bank, bit) pair to its own pinmux funcsel register offset —
// each pad's offset in cv180x_reg_fmux_gpio.h was found by hand, and
// three verified pads land at three unrelated offsets. A pin not in
// this table simply has no known-safe funcsel address to write, so
// this driver refuses it rather than guessing.
//
// Four pins, verified against every pad this project's own
// boards/duo/board.c3/user/block/sdhci.c3/user/usb/dwc2.c3/
// user/net/ephy.c3 already claims at PINMUX_BASE, and against
// u-boot's own board_init()/pinmux_config() calls for cases actually
// enabled in this exact board's real .config (cv1800b_milkv_duo_sd):
//   - GPIOC24 (pad AUD_AOUTR, funcsel +0x12c): the onboard status LED
//     (confirmed by the board's own owner, cross-checked against
//     WiringX/PinPong's documented Linux sysfs GPIO 440 = bank C
//     base 416 + 24) — not header-exposed, no external hardware
//     needed. This driver's own proof of concept: blinks it once a
//     second from boot.
//   - GPIOA28 (pad IIC0_SCL, funcsel +0x4c): header pin 1. Caveat: a
//     standard I2C0 bus pin — plausible someone already has I2C
//     hardware wired here.
//   - GPIOA22 (pad SPINOR_SCK, funcsel +0x30): header pin 24. Caveat:
//     named for an onboard SPI-NOR flash chip this board variant
//     (_sd, not _spinor/_spinand) doesn't populate — safe today, but
//     claiming it forecloses SPI-NOR support later.
//   - GPIOC8 (pad PAD_MIPIRX1N, funcsel +0xec): SENSOR_RSTN on the
//     CAM-GC2083 camera FPC (see boards/duo/board.c3's own camera
//     comment for the full pin sourcing) — not header-exposed, only
//     reachable with the camera module attached. The camera's own
//     I2C1/CAM_MCLK0 pins on the same 4-ball group are alt-function
//     pins, not plain GPIO, so they're i2cd's own direct PINMUX writes
//     rather than another entry here.
// Ruled out along the way: header pins 16/17 (UART0 — the live serial
// console every single boot message and test result in this project
// has ever reached anyone through; repurposing it would silence
// output entirely) and pin 19 (SD0_PWR_EN, funcsel +0x1c — the exact
// offset user/block/sdhci.c3's own PAD_SDIO0_PWR_EN_REG already
// claims and writes at every SD init).
const uint GPIO_BANK_A_BASE = 0x03020000;
const uint GPIO_BANK_C_BASE = 0x03022000;
const uint GPIO_PINMUX_BASE = 0x03001000;

const uint GPIO_REG_DR       = 0x00;
const uint GPIO_REG_DDR      = 0x04;
const uint GPIO_REG_EXT_PORT = 0x50;

// Pins by global number: bank letter A..E = 0..4, number = bank * 32 + bit
// (GPIOC24 = 88) — gpiod.c3's numbering, the old bank-letter wire form
// maps onto it.
const uint GPIO_A = 0;
const uint GPIO_C = 64;

struct Cv_pin
{
	uint pin;
	uint bank_base;
	uint bit;
	uint funcsel_offset;
	uint funcsel_value;
}

const int CV_PIN_COUNT = 4;
const Cv_pin[CV_PIN_COUNT] CV_PINS = {
	{ GPIO_C + 24, GPIO_BANK_C_BASE, 24, 0x12c, 3 },   // the onboard LED
	{ GPIO_A + 28, GPIO_BANK_A_BASE, 28, 0x4c, 3 },    // header pin 1
	{ GPIO_A + 22, GPIO_BANK_A_BASE, 22, 0x30, 3 },    // header pin 24
	{ GPIO_C + 8, GPIO_BANK_C_BASE, 8, 0xec, 3 },      // CAM SENSOR_RSTN
};
const uint CV_LED = GPIO_C + 24;
const uint CV_CAM_RSTN = GPIO_C + 8;

// mmio_read32 / mmio_write32: user/user.c3 (shared).

fn Cv_pin* cv_pin(uint pin)
{
	for (int i = 0; i < CV_PIN_COUNT; i++)
	{
		if (CV_PINS[i].pin == pin) { return &CV_PINS[i]; }
	}
	return null;
}

fn void cv_bit_set(uptr reg, uint bit, bool on)
{
	uint v = mmio_read32(reg);
	v = on ? (v | (1u << bit)) : (v & ~(1u << bit));
	mmio_write32(reg, v);
}

// --- the backend interface gpiod.c3 calls --------------------------------

fn bool gb_pin_allowed(uint pin) { return cv_pin(pin) != null; }

fn void gb_set_dir(uint pin, bool output)
{
	Cv_pin* p = cv_pin(pin);
	cv_bit_set((uptr)(p.bank_base + GPIO_REG_DDR), p.bit, output);
}

fn void gb_write(uint pin, bool value)
{
	Cv_pin* p = cv_pin(pin);
	cv_bit_set((uptr)(p.bank_base + GPIO_REG_DR), p.bit, value);
}

fn bool gb_read(uint pin)
{
	Cv_pin* p = cv_pin(pin);
	return (mmio_read32((uptr)(p.bank_base + GPIO_REG_EXT_PORT)) & (1u << p.bit)) != 0;
}

// Pad electricals: not wired up here (each pad's funcsel is all this
// driver knows about the pinmux page).
fn bool gb_pad(uint pin, uint flags) { return false; }

// Poll-only (see the top of this file): no watches.
fn bool gb_irq_supported() { return false; }
fn void gb_irq_config(uint pin, uint trigger) {}
fn void gb_irq_enable(uint pin, bool on) {}
fn void gb_irq_clear(uint pin) {}
fn bool gb_irq_fired(uint pin) { return false; }

bool g_cv_led;

fn void gb_init()
{
	foreach (&p : CV_PINS)
	{
		uptr r = (uptr)(GPIO_PINMUX_BASE + p.funcsel_offset);
		mmio_write32(r, (mmio_read32(r) & ~0x7u) | (p.funcsel_value & 0x7));
	}
	gb_set_dir(CV_LED, true);

	// GPIOC8, the CAM-GC2083's own SENSOR_RSTN/XSHUTDOWN.
	// Driven low (reset asserted, a known-safe state) immediately —
	// the GC2083 datasheet explicitly calls XSHUTDOWN "floating
	// forbidden", and without this it sits at the GPIO controller's
	// own power-on default (input, i.e. floating) from boot until
	// whatever shell command eventually calls GPIO_IPC_SET_DIR on it,
	// possibly a long time after the sensor's own power rails came up.
	// camtest.c3's own reset pulse still does the real, controlled
	// low->high release right before its I2C read; this only closes
	// the floating gap before that.
	gb_set_dir(CV_CAM_RSTN, true);
	gb_write(CV_CAM_RSTN, false);
	g_cv_led = true;
	print("gpiod: CV1800B, blinking the onboard LED (GPIOC24) every 1s\n");
}

// The LED blink, once a second (the backend's periodic hook).
fn ulong gb_tick_ticks() { return timebase_hz(); }
fn void gb_tick()
{
	g_cv_led = !g_cv_led;
	gb_write(CV_LED, g_cv_led);
}
