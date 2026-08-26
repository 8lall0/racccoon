module user;

import std::nolibc::main_stub;

// Interactive command-line access to gpiod (user/gpio/gpiod.c3) — its
// own allowlisted GPIO pins, from the shell, rather than only the
// driver's own fixed boot-time LED blink. Talks to gpiod over the
// dynamic srv_post()/ns_mount_wait() mechanism, same as usbrw.c3
// already established for usbd — gpiod's own pid isn't fixed (spawned
// last at boot, after the shell), so this can't use a static namespace
// default the way "/proc/"/"/env/" do.
//
// Wire protocol: byte 0 = bank letter ('A'/'C'), byte 1 = bit, byte 2
// = arg (dir: 0=in/1=out; write: 0/1; unused for read). Reply: byte 0
// = result (0 ok, 1 = pin not in gpiod's own allowlist), byte 1 =
// value read back (read only). These constants must match
// user/gpio/gpiod.c3's own copy by hand, same "kept in sync by hand"
// convention this project already established for DISKD_READ/WRITE
// across diskd.c3/fsd.c3's own separate copies.
const uint GPIO_IPC_SET_DIR = 1;
const uint GPIO_IPC_WRITE   = 2;
const uint GPIO_IPC_READ    = 3;
const uint GPIO_IPC_MSG_MAX = 8;

const ulong GPIOD_MOUNT_WAIT_ATTEMPTS = 20;

// str_eq/print_int aren't available to an ordinary command binary —
// small local copies, same convention usbrw.c3 already established.
fn bool str_eq(char* a, char* b)
{
    int i = 0;
    while (a[i] != 0 && b[i] != 0)
    {
        if (a[i] != b[i]) { return false; }
        i++;
    }
    return a[i] == b[i];
}

// Minimal decimal parser — no atoi exists anywhere in this project yet
// (usbrw.c3's own copy). Returns -1 on any non-digit character or an
// empty string.
fn int parse_uint(char* s)
{
    if (s[0] == 0) { return -1; }
    int v = 0;
    for (int i = 0; s[i] != 0; i++)
    {
        if (s[i] < '0' || s[i] > '9') { return -1; }
        v = v * 10 + (int)(s[i] - '0');
    }
    return v;
}

// out_value may be null (dir/write don't need anything back). Returns
// false if gpiod is unreachable, the request itself failed, or the
// pin isn't one gpiod's own allowlist recognizes.
fn bool gpio_call(uint verb, char bank_letter, int bit, char arg, char* out_value)
{
    if (ns_mount_wait("/srv/gpiod/", "gpiod", GPIOD_MOUNT_WAIT_ATTEMPTS) < 0)
    {
        print("gpio: gpiod not available (no GPIO controller on this board?)\n");
        return false;
    }

    char[GPIO_IPC_MSG_MAX] req @noinit;
    req[0] = bank_letter;
    req[1] = (char)bit;
    req[2] = arg;

    uint reply_verb = 0;
    int from = p9_call_path("/srv/gpiod/", verb, &req[0], (int)GPIO_IPC_MSG_MAX, &req[0], (int)GPIO_IPC_MSG_MAX, &reply_verb);
    if (from <= 0 || reply_verb != verb)
    {
        print("gpio: request failed (no reply from gpiod)\n");
        return false;
    }

    if (req[0] != 0)
    {
        print("gpio: not one of gpiod's own allowlisted pins\n");
        return false;
    }

    if (out_value != null) { *out_value = req[1]; }
    return true;
}

fn void usage()
{
    print("usage: gpio <bank><bit> dir <in|out>   (e.g. gpio A28 dir out)\n");
    print("       gpio <bank><bit> write <0|1>\n");
    print("       gpio <bank><bit> read\n");
}

fn void main(String[] args)
{
    if (args.len < 2) { usage(); return; }

    char* pin = args[0].ptr;
    char bank_letter = pin[0];
    int bit = parse_uint(&pin[1]);
    if (bit < 0 || bit > 31)
    {
        print("gpio: \"");
        print(pin);
        print("\" isn't a valid <bank><bit> (e.g. A28, C24)\n");
        return;
    }

    char* subcmd = args[1].ptr;
    if (str_eq(subcmd, "dir"))
    {
        if (args.len != 3 || (!str_eq(args[2].ptr, "in") && !str_eq(args[2].ptr, "out"))) { usage(); return; }
        bool out = str_eq(args[2].ptr, "out");
        if (!gpio_call(GPIO_IPC_SET_DIR, bank_letter, bit, out ? (char)1 : (char)0, null)) { return; }
        print("gpio: ");
        print(pin);
        print(out ? " set to output\n" : " set to input\n");
    }
    else if (str_eq(subcmd, "write"))
    {
        if (args.len != 3) { usage(); return; }
        int val = parse_uint(args[2].ptr);
        if (val != 0 && val != 1) { usage(); return; }
        if (!gpio_call(GPIO_IPC_WRITE, bank_letter, bit, (char)val, null)) { return; }
        print("gpio: ");
        print(pin);
        print(val == 1 ? " -> 1\n" : " -> 0\n");
    }
    else if (str_eq(subcmd, "read"))
    {
        if (args.len != 2) { usage(); return; }
        char value = 0;
        if (!gpio_call(GPIO_IPC_READ, bank_letter, bit, (char)0, &value)) { return; }
        print("gpio: ");
        print(pin);
        print(value != 0 ? " = 1\n" : " = 0\n");
    }
    else
    {
        usage();
    }
}
