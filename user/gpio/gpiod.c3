module user;

import std::nolibc::main_stub;

// gpiod: the GPIO server — the board-neutral core. The SoC side is a
// backend linked in per board (scripts/build_user.sh's GPIO_SOC_SRC):
//   user/gpio/gpio_cv1800.c3 — the Milk-V Duo's DesignWare APB GPIO
//     (poll-only, a 4-pin allowlist, the LED blink)
//   user/gpio/gpio_jh7110.c3 — the Orange Pi RV's JH7110 sys GPIO, pad
//     config and pin interrupts (PLIC 86)
// Each backend provides gb_init / gb_pin_allowed / gb_set_dir / gb_write /
// gb_read / gb_pad / gb_irq_* / gb_tick*. The wire protocol and a client
// are user/gpio/gpio_client.c3.
//
// gpiod owns its board's GPIO / pinmux pages exclusively (the board's
// "gpio" device) — one owning process per real device, everyone else
// talks over IPC, so no driver can reconfigure another device's pads by
// accident. Pins are global numbers, checked against the backend's
// allowlist.
//
// It sleeps in await_any: a request (AW_MSG), its interrupt (AW_IRQ, when
// the backend has them), or the backend's periodic tick. Pin watches: up
// to WATCH_MAX (pin, subscriber) pairs; when a watched pin fires gpiod
// masks it and wake()s the subscriber, which re-arms it (GPIO_IPC_REARM)
// once it has serviced the source.

const int WATCH_MAX = 8;

struct Watch
{
	bool used;
	bool armed;
	uint pin;
	int pid;
	uint gen;
}

Watch[WATCH_MAX] g_watch;

fn Watch* watch_find(uint pin, int pid)
{
	for (int i = 0; i < WATCH_MAX; i++)
	{
		if (g_watch[i].used && g_watch[i].pin == pin && g_watch[i].pid == pid) { return &g_watch[i]; }
	}
	return null;
}

// The pin's interrupt fired: mask it, tell its subscriber.
fn void watch_service()
{
	for (int i = 0; i < WATCH_MAX; i++)
	{
		Watch* w = &g_watch[i];
		if (!w.used || !w.armed || !gb_irq_fired(w.pin)) { continue; }
		gb_irq_enable(w.pin, false);
		gb_irq_clear(w.pin);
		w.armed = false;
		if (wake(w.pid, w.gen) < 0) { w.used = false; } // the subscriber is gone
	}
}

// Request [0] '#' + pin in [1] / [3], or a bank letter + bit in [1]
// (gpio_client.c3); -1 if neither.
fn int request_pin(char* m)
{
	uint form = (uint)(m[0] & 0xFF);
	if (form == '#') { return (int)((uint)(m[1] & 0xFF) | ((uint)(m[3] & 0xFF) << 8)); }
	if (form >= 'A' && form <= 'E' && (uint)(m[1] & 0xFF) < 32) { return (int)((form - 'A') * 32 + (uint)(m[1] & 0xFF)); }
	return -1;
}

fn uint handle(uint verb, char* m, int from, uint from_gen, char* value)
{
	int p = request_pin(m);
	if (p < 0 || !gb_pin_allowed((uint)p)) { return GPIO_EPIN; }
	uint pin = (uint)p;
	uint arg = (uint)(m[2] & 0xFF);
	switch (verb)
	{
		case GPIO_IPC_SET_DIR: gb_set_dir(pin, arg != 0);
		case GPIO_IPC_WRITE: gb_write(pin, arg != 0);
		case GPIO_IPC_READ: *value = gb_read(pin) ? (char)1 : (char)0;
		case GPIO_IPC_PAD: if (!gb_pad(pin, arg)) { return GPIO_EUNSUP; }
		case GPIO_IPC_WATCH:
			if (!gb_irq_supported()) { return GPIO_EUNSUP; }
			Watch* w = watch_find(pin, from);
			for (int i = 0; i < WATCH_MAX && w == null; i++) { if (!g_watch[i].used) { w = &g_watch[i]; } }
			if (w == null) { return GPIO_EFULL; }
			*w = { .used = true, .armed = true, .pin = pin, .pid = from, .gen = from_gen };
			gb_irq_config(pin, arg);
			gb_irq_enable(pin, true);
		case GPIO_IPC_REARM:
			Watch* w = watch_find(pin, from);
			if (w == null) { return GPIO_EPIN; }
			if (!w.armed)
			{
				w.armed = true;
				gb_irq_clear(pin);
				gb_irq_enable(pin, true);
			}
		case GPIO_IPC_UNWATCH:
			Watch* w = watch_find(pin, from);
			if (w != null) { gb_irq_enable(pin, false); w.used = false; }
		default: return GPIO_EUNSUP;
	}
	return GPIO_OK;
}

fn void main()
{
	gb_init();
	// Same dynamic srv_post()/ns_mount_wait() two-step usbd.c3 already
	// established — this pid isn't fixed, so a static namespace default
	// would be stale for every shell-spawned command (user/bin/gpio.c3).
	srv_post("gpiod");

	ulong tick = gb_tick_ticks();
	ulong next_tick = rdtime() + tick;
	for (;;)
	{
		ulong wait = 0;
		if (tick != 0)
		{
			ulong now = rdtime();
			wait = next_tick > now ? next_tick - now : 1;
		}
		int ready = await_any(AW_MSG | (gb_irq_supported() ? AW_IRQ : 0), wait, null, 0);
		if (ready < 0) { continue; }
		if (((uint)ready & AW_IRQ) != 0)
		{
			watch_service();
			syscall(SYS_DRIVER_IRQ_ARM, 0, 0, 0);
		}
		if (((uint)ready & AW_MSG) != 0)
		{
			char[GPIO_IPC_MSG_MAX] m @noinit;
			uint verb = 0;
			uint from_gen = 0;
			int from = ipc_recv_type_gen(&m[0], (int)GPIO_IPC_MSG_MAX, &verb, &from_gen);
			if (from > 0)
			{
				char[GPIO_IPC_MSG_MAX] reply;
				for (int k = 0; k < (int)GPIO_IPC_MSG_MAX; k++) { reply[k] = 0; }
				reply[0] = (char)handle(verb, &m[0], from, from_gen, &reply[1]);
				ipc_reply(from, verb, &reply[0], (int)GPIO_IPC_MSG_MAX, from_gen);
			}
		}
		if (tick != 0 && rdtime() >= next_tick)
		{
			gb_tick();
			next_tick += tick;
			if (next_tick < rdtime()) { next_tick = rdtime() + tick; }
		}
	}
}
