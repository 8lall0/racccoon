module user;

import std::io;

// wifi [scan|list|status] — the USB Wi-Fi adapter's driver lives in usbd
// (user/usb/rtl8192eu.c3); this talks to it over IPC at /srv/usbd/.
//   wifi scan     start a scan of channels 1-13 (~3 s), then list
//   wifi list     the networks seen: bssid channel signal security ssid
//   wifi status   adapter / station state
//   wifi join SSID [PASSPHRASE]
//                 associate (WPA2-PSK with a passphrase, else open); then
//                 ipd runs DHCP on ether1. The PMK is computed here.
//   wifi join     the same, with the SSID and passphrase from /adm/wifi
//                 (line 1 SSID, line 2 passphrase; keep it root-only)
//   wifi save SSID [PASSPHRASE]
//                 store the network in /adm/wifi (SSID + the PMK as hex,
//                 mode 0600) for usbd to join at boot, then join it now
//   wifi leave    deauthenticate and drop the link
const uint WIFI_IPC_SCAN   = 40;
const uint WIFI_IPC_LIST   = 41;
const uint WIFI_IPC_STATUS = 42;
const uint WIFI_IPC_JOIN   = 43;
const uint WIFI_IPC_LEAVE  = 44;

char[33] g_ssid;
char[65] g_pass;
bool g_have_pass;

fn int wifi_call(uint verb, char* out, int cap) {
    char[4096] buf;
    buf[0] = 0;
    if (verb == WIFI_IPC_JOIN) {
        // [ssid, NUL-padded to 33][have_pmk][pmk 32]
        for (int k = 0; k < 33; k++) buf[k] = g_ssid[k];
        buf[33] = g_have_pass ? 1 : 0;
        if (g_have_pass) wifi_pmk(&buf[34]);
    }
    uint rv = 0;
    int from = p9_call_path("/srv/usbd/", verb, &buf[0], 516, &buf[0], 4096, &rv);
    if (from <= 0) return -1;
    int n = (int)((uint)buf[0] | ((uint)buf[1] << 8));
    if (n > cap - 1) n = cap - 1;
    for (int i = 0; i < n; i++) out[i] = buf[4 + i];
    out[n] = 0;
    return n;
}

fn int hexval(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

// PMK = PBKDF2-HMAC-SHA1(passphrase, SSID, 4096, 32), or 64 hex digits taken as the PSK itself.
fn void wifi_pmk(char* out) {
    uint pl = 0;
    while (g_pass[pl] != 0) pl++;
    if (pl == 64) {
        bool hex = true;
        for (uint i = 0; i < 64; i++) if (hexval(g_pass[i]) < 0) hex = false;
        if (hex) {
            for (uint i = 0; i < 32; i++) out[i] = (char)(hexval(g_pass[2 * i]) * 16 + hexval(g_pass[2 * i + 1]));
            return;
        }
    }
    uint sl = 0;
    while (g_ssid[sl] != 0) sl++;
    pbkdf2_sha1(&g_pass[0], pl, &g_ssid[0], sl, 4096, out, 32);
}

fn void copy_str(char* dst, int cap, char* src, int len) {
    int k = 0;
    for (; k < len && k < cap - 1; k++) dst[k] = src[k];
    dst[k] = 0;
}

// /adm/wifi: line 1 SSID, line 2 passphrase (optional).
fn bool load_adm_wifi() {
    char[256] f;
    int n = fs_read("/adm/wifi", &f[0], 255);
    if (n <= 0) return false;
    int a = 0;
    while (a < n && f[a] != '\n' && f[a] != '\r') a++;
    copy_str(&g_ssid[0], 33, &f[0], a);
    while (a < n && (f[a] == '\n' || f[a] == '\r')) a++;
    int b = a;
    while (b < n && f[b] != '\n' && f[b] != '\r') b++;
    copy_str(&g_pass[0], 65, &f[a], b - a);
    g_have_pass = b > a;
    return g_ssid[0] != 0;
}

fn bool check_pass() {
    if (!g_have_pass) return true;
    uint pl = 0;
    while (g_pass[pl] != 0) pl++;
    if (pl < 8 || pl > 64) { io::print("wifi: a WPA2 passphrase is 8..63 characters (or 64 hex digits)\n"); return false; }
    return true;
}

// SSID line + (for WPA2) the PMK as 64 hex digits, root-only.
fn bool save_adm_wifi() {
    char[128] f;
    int n = 0;
    for (int k = 0; g_ssid[k] != 0; k++) { f[n] = g_ssid[k]; n++; }
    f[n] = '\n'; n++;
    if (g_have_pass) {
        char[32] pmk;
        wifi_pmk(&pmk[0]);
        char* hx = "0123456789abcdef";
        for (int i = 0; i < 32; i++) { f[n] = hx[((uint)pmk[i] >> 4) & 15]; f[n + 1] = hx[(uint)pmk[i] & 15]; n += 2; }
        // the join below must not run PBKDF2 a second time on the passphrase: hand it the PMK hex
        for (int i = 0; i < 64; i++) g_pass[i] = f[n - 64 + i];
        g_pass[64] = 0;
    }
    f[n] = '\n'; n++;
    if (fs_write("/adm/wifi", &f[0], n) < 0) return false;
    fs_chmod("/adm/wifi", 0600);
    return true;
}

fn void main(String[] args) {
    if (ns_mount_wait("/srv/usbd/", "usbd", 20) < 0) { io::print("wifi: usbd isn't running\n"); exitcode(1); }
    char[4096] out;
    uint verb = WIFI_IPC_STATUS;
    bool then_list = false;
    if (args.len >= 1) {
        if (args[0].len == 4 && args[0][0] == 's' && args[0][1] == 'c') { verb = WIFI_IPC_SCAN; then_list = true; }
        else if (args[0].len == 4 && args[0][0] == 'l') { verb = WIFI_IPC_LIST; }
        else if (args[0].len == 5 && args[0][0] == 'l') { verb = WIFI_IPC_LEAVE; }
        else if (args[0].len == 4 && args[0][0] == 's' && args[0][1] == 'a') {
            if (args.len < 2) { io::print("usage: wifi save SSID [PASSPHRASE]\n"); exitcode(1); }
            copy_str(&g_ssid[0], 33, args[1].ptr, (int)args[1].len);
            if (args.len >= 3) { copy_str(&g_pass[0], 65, args[2].ptr, (int)args[2].len); g_have_pass = true; }
            if (!check_pass()) exitcode(1);
            if (!save_adm_wifi()) { io::print("wifi: can't write /adm/wifi\n"); exitcode(1); }
            io::print("wifi: saved to /adm/wifi\n");
            verb = WIFI_IPC_JOIN;
        }
        else if (args[0].len == 4 && args[0][0] == 'j') {
            verb = WIFI_IPC_JOIN;
            if (args.len >= 2) {
                copy_str(&g_ssid[0], 33, args[1].ptr, (int)args[1].len);
                if (args.len >= 3) {
                    copy_str(&g_pass[0], 65, args[2].ptr, (int)args[2].len);
                    g_have_pass = true;
                }
            } else if (!load_adm_wifi()) {
                io::print("usage: wifi join SSID [PASSPHRASE]  (or put SSID / passphrase lines in /adm/wifi)\n");
                exitcode(1);
            }
            if (!check_pass()) exitcode(1);
        }
    }
    if (wifi_call(verb, &out[0], 4096) < 0) { io::print("wifi: no answer from usbd\n"); exitcode(1); }
    if (then_list) {
        ulong end = rdtime() + timebase_hz() * 4;
        while (rdtime() < end) { await_any(0, timebase_hz() / 10, null, 0); }
        wifi_call(WIFI_IPC_LIST, &out[0], 4096);
    }
    io::print((ZString)&out[0]);
}
