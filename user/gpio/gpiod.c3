module user;

import std::nolibc::main_stub;

// gpiod: driver for the CV1800B's Synopsys DesignWare APB GPIO
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
// Three pins, verified against every pad this project's own
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

// This board's own real timebase — board is a kernel-only module
// (unreachable from user code), so this is a duplicated-by-hand copy,
// same convention as user/block/sdhci.c3's own SD_TIMEBASE_HZ.
const ulong GPIOD_TIMEBASE_HZ = 25000000;

// mmio_read32 / mmio_write32: user/user.c3 (shared).

const int GPIO_PIN_COUNT = 3;
char[GPIO_PIN_COUNT] gpio_pin_bank_letter; // 'A' or 'C'
uint[GPIO_PIN_COUNT] gpio_pin_bank_base;
uint[GPIO_PIN_COUNT] gpio_pin_bit;
uint[GPIO_PIN_COUNT] gpio_pin_funcsel_offset;
uint[GPIO_PIN_COUNT] gpio_pin_funcsel_value;

fn void gpio_pin_table_init()
{
    gpio_pin_bank_letter[0]     = 'C';
    gpio_pin_bank_base[0]       = GPIO_BANK_C_BASE;
    gpio_pin_bit[0]             = 24;
    gpio_pin_funcsel_offset[0]  = 0x12c;
    gpio_pin_funcsel_value[0]   = 3;

    gpio_pin_bank_letter[1]     = 'A';
    gpio_pin_bank_base[1]       = GPIO_BANK_A_BASE;
    gpio_pin_bit[1]             = 28;
    gpio_pin_funcsel_offset[1]  = 0x4c;
    gpio_pin_funcsel_value[1]   = 3;

    gpio_pin_bank_letter[2]     = 'A';
    gpio_pin_bank_base[2]       = GPIO_BANK_A_BASE;
    gpio_pin_bit[2]             = 22;
    gpio_pin_funcsel_offset[2]  = 0x30;
    gpio_pin_funcsel_value[2]   = 3;
}

// -1 if (bank_letter, bit) isn't one of the allowlisted pins above —
// the one check every IPC verb and this driver's own boot-time setup
// goes through before touching any register.
fn int gpio_pin_find(char bank_letter, uint bit)
{
    for (int i = 0; i < GPIO_PIN_COUNT; i++)
    {
        if (gpio_pin_bank_letter[i] == bank_letter && gpio_pin_bit[i] == bit) { return i; }
    }
    return -1;
}

// Read-modify-write: only bits [2:0] of the pad's own funcsel register
// select its alternate function — every other bit belongs to a
// different pad's own field in the same word and must survive
// untouched.
fn void gpio_configure_pinmux(int idx)
{
    uint reg = mmio_read32((uptr)(GPIO_PINMUX_BASE + gpio_pin_funcsel_offset[idx]));
    reg = (reg & ~(uint)0x7) | (gpio_pin_funcsel_value[idx] & 0x7);
    mmio_write32((uptr)(GPIO_PINMUX_BASE + gpio_pin_funcsel_offset[idx]), reg);
}

fn void gpio_set_dir(int idx, bool output)
{
    uint mask = 1u << gpio_pin_bit[idx];
    uint reg = mmio_read32((uptr)(gpio_pin_bank_base[idx] + GPIO_REG_DDR));
    reg = output ? (reg | mask) : (reg & ~mask);
    mmio_write32((uptr)(gpio_pin_bank_base[idx] + GPIO_REG_DDR), reg);
}

fn void gpio_write(int idx, bool value)
{
    uint mask = 1u << gpio_pin_bit[idx];
    uint reg = mmio_read32((uptr)(gpio_pin_bank_base[idx] + GPIO_REG_DR));
    reg = value ? (reg | mask) : (reg & ~mask);
    mmio_write32((uptr)(gpio_pin_bank_base[idx] + GPIO_REG_DR), reg);
}

fn bool gpio_read(int idx)
{
    uint reg = mmio_read32((uptr)(gpio_pin_bank_base[idx] + GPIO_REG_EXT_PORT));
    return (reg & (1u << gpio_pin_bit[idx])) != 0;
}

// Wire protocol: byte 0 = bank letter ('A'/'C'), byte 1 = bit (0-31),
// byte 2 = arg (SET_DIR: 0=in/1=out; WRITE: 0/1; unused for READ).
// Reply: byte 0 = result (0 ok, 1 = pin not in the allowlist), byte 1
// = value read back (READ only). Small, fixed-size messages — no
// caller-supplied length to bound, unlike diskd/usbd's own sector-
// sized protocols.
const uint GPIO_IPC_SET_DIR   = 1;
const uint GPIO_IPC_WRITE     = 2;
const uint GPIO_IPC_READ      = 3;
const uint GPIO_IPC_MSG_MAX   = 8;

fn void gpiod_ipc_poll()
{
    char[GPIO_IPC_MSG_MAX] buf @noinit;
    uint verb = 0;
    int from = ipc_poll_type(&buf[0], (int)GPIO_IPC_MSG_MAX, &verb);
    if (from < 0) { return; }
    if (verb != GPIO_IPC_SET_DIR && verb != GPIO_IPC_WRITE && verb != GPIO_IPC_READ) { return; }

    char bank_letter = buf[0];
    uint bit = (uint)buf[1];
    char arg = buf[2];

    char[GPIO_IPC_MSG_MAX] reply @noinit;
    reply[0] = (char)0;
    reply[1] = (char)0;

    int idx = gpio_pin_find(bank_letter, bit);
    if (idx < 0)
    {
        reply[0] = (char)1;
    }
    else if (verb == GPIO_IPC_SET_DIR)
    {
        gpio_set_dir(idx, arg != (char)0);
    }
    else if (verb == GPIO_IPC_WRITE)
    {
        gpio_write(idx, arg != (char)0);
    }
    else
    {
        reply[1] = gpio_read(idx) ? (char)1 : (char)0;
    }

    ipc_reply(from, verb, &reply[0], (int)GPIO_IPC_MSG_MAX, 0);
}

fn void main()
{
    gpio_pin_table_init();
    for (int i = 0; i < GPIO_PIN_COUNT; i++)
    {
        gpio_configure_pinmux(i);
    }
    gpio_set_dir(0, true); // index 0 = the onboard LED (GPIOC24), output

    // Same dynamic srv_post()/ns_mount_wait() two-step usbd.c3 already
    // established — this pid isn't fixed (spawned last, after the
    // shell, see kernel.c3's own comment), so a static namespace
    // default would be permanently stale for every shell-spawned
    // command (user/bin/gpio.c3).
    srv_post("gpiod");
    print("gpiod: init done, blinking the onboard LED (GPIOC24) every 1s\n");

    bool led_on = true;
    ulong last_toggle = rdtime();
    for (;;)
    {
        gpiod_ipc_poll();

        ulong now = rdtime();
        if (now - last_toggle >= GPIOD_TIMEBASE_HZ)
        {
            led_on = !led_on;
            gpio_write(0, led_on);
            last_toggle = now;
        }

        // ipc_poll_type() (SYS_IPC_POLL) explicitly never yields — see
        // its own case comment, src/entry.c3 — so without this, this
        // loop is exactly the "syscall-free spin that nothing can ever
        // switch away from" SYS_YIELD exists to prevent (that comment's
        // own words). This kernel's timer preemption only fires once
        // per real second (arm_timer(board::TIMEBASE_HZ)), so a loop
        // that never voluntarily yields can still monopolize the CPU
        // for nearly a full second at a stretch once it does get
        // scheduled — real symptom hit once already, on real hardware:
        // usbd/ethd's own already-busy polling plus this one more
        // non-yielding process was enough real contention to make the
        // shell's own exec() of /bin/ls fail outright. Every other
        // polling driver in this project (usbd.c3/ethd.c3) already
        // calls yield() in its own busy loops for exactly this reason —
        // this was simply missed writing this driver's first cut.
        yield();
    }
}
