module user;

// gpiod's wire protocol (user/gpio/gpiod.c3) and a small client for it.
//
// Every request and reply is GPIO_IPC_MSG_MAX bytes:
//   request [0] pin form: '#' = a global pin number in [1] (low) + [3]
//               (high); or a bank letter 'A'..'E' with the bit in [1]
//               (the Duo's original form: pin = bank * 32 + bit)
//           [2] arg (SET_DIR 1 = out; WRITE 0/1; PAD GPIO_PAD_* flags;
//               WATCH a GPIO_TRIG_* trigger)
//   reply   [0] status (GPIO_OK, GPIO_EPIN pin not on this board's
//               allowlist, GPIO_EUNSUP not supported by the backend,
//               GPIO_EFULL no free watch slot), [1] value (READ)
//
// A watch (GPIO_IPC_WATCH) makes gpiod wake() the caller when the pin's
// interrupt fires; the source then stays masked until the caller sends
// GPIO_IPC_REARM, after it has serviced whatever drives the line — so a
// level-triggered pin can't storm, and nothing is lost: a line still
// asserted at re-arm fires again at once.
const uint GPIO_IPC_SET_DIR = 1;
const uint GPIO_IPC_WRITE   = 2;
const uint GPIO_IPC_READ    = 3;
const uint GPIO_IPC_PAD     = 4;
const uint GPIO_IPC_WATCH   = 5;
const uint GPIO_IPC_REARM   = 6;
const uint GPIO_IPC_UNWATCH = 7;
const uint GPIO_IPC_MSG_MAX = 8;

const uint GPIO_OK     = 0;
const uint GPIO_EPIN   = 1;
const uint GPIO_EUNSUP = 2;
const uint GPIO_EFULL  = 3;
const uint GPIO_ENOSRV = 0xFF;   // client side: no reply from gpiod

const uint GPIO_PAD_INPUT     = 1;   // input buffer enabled
const uint GPIO_PAD_PULL_UP   = 2;
const uint GPIO_PAD_PULL_DOWN = 4;
const uint GPIO_PAD_STRONG    = 8;   // the strongest drive the pad has

const uint GPIO_TRIG_LEVEL_HIGH = 1;
const uint GPIO_TRIG_LEVEL_LOW  = 2;
const uint GPIO_TRIG_RISING     = 3;
const uint GPIO_TRIG_FALLING    = 4;

// One request for global pin `pin` (gpiod must be mounted at /srv/gpiod/,
// e.g. ns_mount_wait("/srv/gpiod/", "gpiod", n)). Returns the status;
// `*value` gets the reply's value byte when non-null.
fn uint gpio_request(uint verb, uint pin, uint arg, char* value)
{
	char[GPIO_IPC_MSG_MAX] m;
	for (int k = 0; k < (int)GPIO_IPC_MSG_MAX; k++) { m[k] = 0; }
	m[0] = '#';
	m[1] = (char)(pin & 0xFF);
	m[2] = (char)arg;
	m[3] = (char)((pin >> 8) & 0xFF);
	uint rv = 0;
	int from = p9_call_path("/srv/gpiod/", verb, &m[0], (int)GPIO_IPC_MSG_MAX, &m[0], (int)GPIO_IPC_MSG_MAX, &rv);
	if (from <= 0 || rv != verb) { return GPIO_ENOSRV; }
	if (value != null) { *value = m[1]; }
	return (uint)(m[0] & 0xFF);
}
