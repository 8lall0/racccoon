module user;

// shell_test builtins — networking (ipd, user/net/ipd.c3): nettest (UDP
// and ICMP), tcptest (TCP). Everything runs over the loopback interface
// except the ping to slirp's gateway, so the results don't depend on the
// host. Tried by shell_test.c3's main() like the other shell_test_*
// dispatchers.

fn void nt_say(char* what, bool ok, int* pass, int* total) {
    *total = *total + 1;
    print(what);
    if (ok) { *pass = *pass + 1; print(": ok\n"); } else { print(": FAILED\n"); }
}

fn bool nt_eq(char* a, char* b, int n) {
    for (int i = 0; i < n; i++) { if (a[i] != b[i]) return false; }
    return true;
}

fn void net_test() {
    int pass = 0;
    int total = 0;
    ulong hz = timebase_hz();

    // 1. UDP over loopback: a headers-mode server answers whoever wrote.
    int srv = announce("udp!*!7007");
    bool ok = srv >= 0 && net_ctl(srv, "headers") == 0;
    if (ok) {
        uint g = 0;
        int c = rfork(RFPROC, &g);
        if (c == 0) {
            int h = dial("udp!127.0.0.1!7007");
            if (h < 0) exitcode(2);
            net_write(h, "ping", 4);
            char[64] r;
            int n = net_read1(h, &r[0], 64);
            hangup(h);
            exitcode(n == 4 && nt_eq(&r[0], "pong", 4) ? 1 : 3);
        }
        char[64] q;
        int n = net_read1(srv, &q[0], 64);   // [addr 4][port 2]"ping"
        bool got = n == 10 && nt_eq(&q[6], "ping", 4);
        if (got) {
            q[6] = 'p'; q[7] = 'o'; q[8] = 'n'; q[9] = 'g';
            net_write(srv, &q[0], 10);
        }
        ok = got && join(c, g) == 1;
    }
    if (srv >= 0) hangup(srv);
    nt_say("nettest: udp request/reply over loopback", ok, &pass, &total);

    // 2. ICMP echo to ourselves and to slirp's gateway.
    char* targets0 = "icmp!127.0.0.1";
    char* targets1 = "icmp!10.0.2.2";
    for (int t = 0; t < 2; t++) {
        int h = dial(t == 0 ? targets0 : targets1);
        bool pok = false;
        if (h >= 0) {
            char[32] pay;
            for (int i = 0; i < 32; i++) pay[i] = (char)('a' + i % 26);
            for (int tries = 0; tries < 3 && !pok; tries++) {
                net_write(h, &pay[0], 32);
                char[64] r;
                int n = net_read1(h, &r[0], 64);
                pok = n == 32 && nt_eq(&r[0], &pay[0], 32);
            }
            hangup(h);
        }
        nt_say(t == 0 ? "nettest: ping 127.0.0.1" : "nettest: ping 10.0.2.2 (slirp gateway)", pok, &pass, &total);
    }

    // 3. The interface got an address.
    char[256] st;
    int n = fs_read("/net/ipifc/0/status", &st[0], 255);
    bool bound = false;
    for (int i = 0; i + 10 < n; i++) {
        if (nt_eq(&st[i], "dhcp bound", 10)) bound = true;
    }
    nt_say("nettest: ether0 has a DHCP lease", bound, &pass, &total);

    print("nettest: ");
    print_uint((uint)pass);
    print("/");
    print_uint((uint)total);
    print(pass == total ? " — PASS\n" : " — FAIL\n");
}

// 1 MiB, a byte pattern a receiver can check without a copy of it.
const int TT_BYTES = 1048576;

fn char tt_byte(int i) { return (char)((i * 7 + (i >> 9)) & 0xFF); }

char[8192] tt_buf;

fn void tcp_test() {
    int pass = 0;
    int total = 0;

    // 1. Nobody listening: refused, quickly.
    ulong t0 = rdtime();
    int h = dial("tcp!127.0.0.1!7999");
    ulong dt = rdtime() - t0;
    nt_say("tcptest: connect to a closed port is refused", h < 0 && dt < timebase_hz() * 3, &pass, &total);
    if (h >= 0) hangup(h);

    // 2. 1 MiB over loopback. The child sends the pattern, half-closes, and
    // waits for the server's verdict; the server checks every byte, then
    // answers "ok" (or "bad") and hangs up.
    int ls = announce("tcp!*!7008");
    bool ok = false;
    if (ls >= 0) {
        uint g = 0;
        int c = rfork(RFPROC, &g);
        if (c == 0) {
            int d = dial("tcp!127.0.0.1!7008");
            if (d < 0) exitcode(2);
            int sent = 0;
            while (sent < TT_BYTES) {
                int n = TT_BYTES - sent;
                if (n > 8000) n = 8000;
                for (int i = 0; i < n; i++) tt_buf[i] = tt_byte(sent + i);
                if (net_write(d, &tt_buf[0], n) != n) exitcode(3);
                sent += n;
            }
            net_ctl(d, "close");                  // half-close: our FIN
            char[8] v;
            int vn = net_read(d, &v[0], 8);
            int eof = net_read(d, &v[4], 4);      // then the server's FIN
            hangup(d);
            exitcode(vn == 2 && v[0] == 'o' && v[1] == 'k' && eof == 0 ? 1 : 4);
        }
        int a = net_listen(ls);
        int got = 0;
        bool good = a >= 0;
        while (good) {
            int n = net_read(a, &tt_buf[0], 8192);
            if (n <= 0) break;
            for (int i = 0; i < n; i++) {
                if (tt_buf[i] != tt_byte(got + i)) { good = false; break; }
            }
            got += n;
        }
        good = good && got == TT_BYTES;
        if (a >= 0) {
            net_write(a, good ? "ok" : "bad", good ? 2 : 3);
            hangup(a);
        }
        int code = join(c, g);
        ok = good && code == 1;
        if (!ok) {
            print("tcptest: received ");
            print_uint((uint)got);
            print(" bytes, child exit ");
            print_uint((uint)code);
            print("\n");
        }
        hangup(ls);
    }
    nt_say("tcptest: 1 MiB over loopback, half-close, reply, close", ok, &pass, &total);

    print("tcptest: ");
    print_uint((uint)pass);
    print("/");
    print_uint((uint)total);
    print(pass == total ? " — PASS\n" : " — FAIL\n");
}

// dltest a.b.c.d port bytes: download from a host server that sends the
// byte pattern (i * 7) & 0xFF repeating every 64 KiB, check every byte,
// report count, first mismatch and throughput — TCP alone, no pipe.
fn int dl_atoi(char* s) {
    int v = 0;
    for (int i = 0; s[i] >= '0' && s[i] <= '9'; i++) v = v * 10 + (s[i] - '0');
    return v;
}

fn void dl_test(char** argv, int argc) {
    if (argc != 3) { print("usage: dltest a.b.c.d port bytes\n"); return; }
    char[64] addr;
    int o = 0;
    char* pre = "tcp!";
    for (int i = 0; pre[i] != 0; i++) { addr[o] = pre[i]; o++; }
    for (int i = 0; argv[0][i] != 0; i++) { addr[o] = argv[0][i]; o++; }
    addr[o] = '!'; o++;
    for (int i = 0; argv[1][i] != 0; i++) { addr[o] = argv[1][i]; o++; }
    addr[o] = 0;
    int want = dl_atoi(argv[2]);
    ulong t0 = rdtime();
    int h = dial(&addr[0]);
    if (h < 0) { print("dltest: dial failed\n"); return; }
    int got = 0;
    int bad_at = -1;
    int r = 0;
    for (;;) {
        r = net_read(h, &tt_buf[0], 8192);
        if (r <= 0) break;
        for (int i = 0; i < r && bad_at < 0; i++) {
            if (tt_buf[i] != (char)(((got + i) % 65536 * 7) & 0xFF)) bad_at = got + i;
        }
        got += r;
    }
    ulong dt = rdtime() - t0;
    char[128] st;
    net_status(h, &st[0], 128);
    hangup(h);
    print("dltest: got ");
    print_uint((uint)got);
    print(" of ");
    print_uint((uint)want);
    print(", last read ");
    if (r < 0) { print("-1"); } else { print_uint((uint)r); }
    print(", first bad byte ");
    if (bad_at < 0) { print("none"); } else { print_uint((uint)bad_at); }
    ulong ms = dt * 1000 / timebase_hz();
    print(", ");
    print_uint((uint)ms);
    print(" ms, status: ");
    print(&st[0]);
    print(got == want && bad_at < 0 ? "dltest: ok\n" : "dltest: FAILED\n");
}

// cryptotest: user/crypto/crypto.c3 against published test vectors —
// FIPS 180 (SHA-1), RFC 2202 (HMAC-SHA1), IEEE 802.11i H.4 (PBKDF2 for
// WPA2, the PRF), FIPS 197 (AES-128), RFC 3394 (key unwrap).
fn int ct_hex(char* hex, char* out) {
    int n = 0;
    for (int i = 0; hex[i] != 0 && hex[i + 1] != 0; i += 2) {
        int v = 0;
        for (int k = 0; k < 2; k++) {
            char c = hex[i + k];
            int d = c >= '0' && c <= '9' ? c - '0' : (c >= 'a' && c <= 'f' ? c - 'a' + 10 : c - 'A' + 10);
            v = v * 16 + d;
        }
        out[n] = (char)v;
        n++;
    }
    return n;
}

fn bool ct_check(char* got, char* want_hex) {
    char[128] want;
    int n = ct_hex(want_hex, &want[0]);
    return nt_eq(got, &want[0], n);
}

fn void crypto_test() {
    int pass = 0;
    int total = 0;
    char[64] out;

    sha1("abc", 3, &out[0]);
    nt_say("cryptotest: sha1(\"abc\")", ct_check(&out[0], "a9993e364706816aba3e25717850c26c9cd0d89d"), &pass, &total);

    char[80] mil;
    for (int i = 0; i < 80; i++) mil[i] = 'a';
    Sha1 sh;
    sha1_init(&sh);
    for (int i = 0; i < 12500; i++) sha1_update(&sh, &mil[0], 80);   // a million 'a'
    sha1_final(&sh, &out[0]);
    nt_say("cryptotest: sha1(10^6 x 'a')", ct_check(&out[0], "34aa973cd4c4daa4f61eeb2bdbad27316534016f"), &pass, &total);

    char[20] k20;
    for (int i = 0; i < 20; i++) k20[i] = (char)0x0b;
    hmac_sha1(&k20[0], 20, "Hi There", 8, &out[0]);
    nt_say("cryptotest: hmac-sha1 rfc2202 #1", ct_check(&out[0], "b617318655057264e28bc0b6fb378c8ef146be00"), &pass, &total);

    hmac_sha1("Jefe", 4, "what do ya want for nothing?", 28, &out[0]);
    nt_say("cryptotest: hmac-sha1 rfc2202 #2", ct_check(&out[0], "effcdf6ae5eb2fa2d27416d5f184df9c259a7c79"), &pass, &total);

    ulong t0 = rdtime();
    pbkdf2_sha1("password", 8, "IEEE", 4, 4096, &out[0], 32);
    ulong ms = (rdtime() - t0) * 1000 / timebase_hz();
    nt_say("cryptotest: wpa2 psk \"password\"/\"IEEE\"", ct_check(&out[0], "f42c6fc52df0ebef9ebb4b90b38a5f902e83fe1b135a70e23aed762e9710a12e"), &pass, &total);
    print("cryptotest: (one WPA2 passphrase hash took ");
    print_uint((uint)ms);
    print(" ms)\n");

    pbkdf2_sha1("ThisIsAPassword", 15, "ThisIsASSID", 11, 4096, &out[0], 32);
    nt_say("cryptotest: wpa2 psk \"ThisIsAPassword\"/\"ThisIsASSID\"", ct_check(&out[0], "0dc0d6eb90555ed6419756b9a15ec3e3209b63df707dd508d14581f8982721af"), &pass, &total);

    prf_sha1(&k20[0], 20, "prefix", "Hi There", 8, &out[0], 64);
    nt_say("cryptotest: 802.11i prf-512", ct_check(&out[0], "bcd4c650b30b9684951829e0d75f9d54b862175ed9f00606e17d8da35402ffee75df78c3d31e0f889f012120c0862beb67753e7439ae242edb8373698356cf5a"), &pass, &total);

    char[16] key;
    char[16] pt;
    ct_hex("000102030405060708090a0b0c0d0e0f", &key[0]);
    ct_hex("00112233445566778899aabbccddeeff", &pt[0]);
    Aes128 a;
    aes128_key(&a, &key[0]);
    char[16] ct;
    aes128_encrypt(&a, &pt[0], &ct[0]);
    nt_say("cryptotest: aes-128 fips-197 encrypt", ct_check(&ct[0], "69c4e0d86a7b0430d8cdb78070b4c55a"), &pass, &total);
    char[16] back;
    aes128_decrypt(&a, &ct[0], &back[0]);
    nt_say("cryptotest: aes-128 decrypt", nt_eq(&back[0], &pt[0], 16), &pass, &total);

    char[24] wrapped;
    ct_hex("1fa68b0a8112b447aef34bd8fb5a7b829d3e862371d2cfe5", &wrapped[0]);
    char[16] unw;
    bool uok = aes_key_unwrap(&key[0], &wrapped[0], 24, &unw[0]);
    nt_say("cryptotest: rfc3394 key unwrap", uok && ct_check(&unw[0], "00112233445566778899aabbccddeeff"), &pass, &total);
    wrapped[5] ^= (char)1;
    nt_say("cryptotest: rfc3394 rejects a corrupted wrap", !aes_key_unwrap(&key[0], &wrapped[0], 24, &unw[0]), &pass, &total);

    print("cryptotest: ");
    print_uint((uint)pass);
    print("/");
    print_uint((uint)total);
    print(pass == total ? " — PASS\n" : " — FAIL\n");
}

fn bool shell_test_net_dispatch(char* cmd, char** cmd_argv, int cmd_argc) {
    if (strcmp(cmd, "nettest") == 0) {
        net_test();
    } else if (strcmp(cmd, "tcptest") == 0) {
        tcp_test();
    } else if (strcmp(cmd, "cryptotest") == 0) {
        crypto_test();
    } else if (strcmp(cmd, "dltest") == 0) {
        dl_test(cmd_argv, cmd_argc);
    } else {
        return false;
    }
    return true;
}
