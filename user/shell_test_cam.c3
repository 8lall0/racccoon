module user;

import std::nolibc::fmt;

// shell_test builtins — CAM-GC2083 bring-up against a known-good
// reference: the register state Milk-V's Linux had while streaming
// (shell_test_cam_golden.c3, docs/camera-linux-*.txt). Talks to cifd's
// PEEK/POKE verbs (its mapped pages only) and i2cd's XFER. Duo only.

const uint CAM_CIF_PEEK = 3;     // must match user/cif/cifd.c3
const uint CAM_CIF_POKE = 4;
const uint CAM_CIF_MSG  = 8;
const uint CAM_I2C_XFER = 1;     // must match user/i2c/i2cd.c3
const uint CAM_I2C_MSG  = 8;
const uint CAM_GC2083   = 0x37;
const uint CAM_CSI_STATUS = 0x0a0c2440;
const ulong CAM_MOUNT_WAIT = 20; // same bound cifinit uses for the /srv mounts

// Linux read csi_wrap0 +0x890, but on racccoon touching it faults cifd —
// skip it.
fn bool cam_golden_skip(uint a) { return a == 0x0a0d0890; }

fn uint cam_hex(char* s)
{
    uint v = 0;
    int i = 0;
    if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) { i = 2; }
    for (; s[i] != 0; i++)
    {
        char c = s[i];
        uint d;
        if (c >= '0' && c <= '9') { d = (uint)(c - '0'); }
        else if (c >= 'a' && c <= 'f') { d = (uint)(c - 'a') + 10; }
        else if (c >= 'A' && c <= 'F') { d = (uint)(c - 'A') + 10; }
        else { break; }
        v = v * 16 + d;
    }
    return v;
}

// One cifd PEEK/POKE. Returns 0 on success, -1 (and prints) otherwise.
fn int cam_cif(uint verb, uint addr, uint val, uint* out)
{
    if (ns_mount_wait("/srv/cifd/", "cifd", CAM_MOUNT_WAIT) < 0) { print("cam: cifd not available\n"); return -1; }
    char[CAM_CIF_MSG] req;
    for (int i = 0; i < 4; i++) { req[i] = (char)(addr >> (8 * i)); req[4 + i] = (char)(val >> (8 * i)); }
    uint rv = 0;
    int from = p9_call_path("/srv/cifd/", verb, &req[0], (int)CAM_CIF_MSG, &req[0], (int)CAM_CIF_MSG, &rv);
    if (from <= 0 || rv != verb) { print("cam: no reply from cifd\n"); return -1; }
    if (req[0] != 0) { print("cam: cifd refused 0x"); print_hex32(addr); print(" (not one of its pages)\n"); return -1; }
    if (out != null) { *out = (uint)req[1] | ((uint)req[2] << 8) | ((uint)req[3] << 16) | ((uint)req[4] << 24); }
    return 0;
}

// GC2083 register access (16-bit address, 8-bit value) through i2cd.
fn int cam_sns(uint reg, bool write, char val, char* out)
{
    if (ns_mount_wait("/srv/i2cd/", "i2cd", CAM_MOUNT_WAIT) < 0) { print("cam: i2cd not available\n"); return -1; }
    char[CAM_I2C_MSG] req;
    for (int i = 0; i < 8; i++) { req[i] = 0; }
    req[0] = (char)CAM_GC2083;
    req[1] = write ? (char)3 : (char)2;
    req[2] = write ? (char)0 : (char)1;
    req[3] = (char)(reg >> 8); req[4] = (char)reg; req[5] = val;
    uint rv = 0;
    int from = p9_call_path("/srv/i2cd/", CAM_I2C_XFER, &req[0], (int)CAM_I2C_MSG, &req[0], (int)CAM_I2C_MSG, &rv);
    if (from <= 0 || rv != CAM_I2C_XFER) { print("cam: no reply from i2cd\n"); return -1; }
    if (req[0] != 0) { print("cam: i2c error on reg 0x"); print_hex32(reg); print("\n"); return -1; }
    if (out != null) { *out = req[1]; }
    return 0;
}

fn int cam_region_code(char* s)
{
    if (strcmp(s, "mac") == 0) { return 0; }
    if (strcmp(s, "wrap") == 0) { return 1; }
    if (strcmp(s, "vip") == 0) { return 2; }
    if (strcmp(s, "clk") == 0) { return 3; }
    if (strcmp(s, "rst") == 0) { return 4; }
    return -1;
}

fn void cam_print_status()
{
    uint st = 0;
    if (cam_cif(CAM_CIF_PEEK, CAM_CSI_STATUS, 0, &st) < 0) { return; }
    print("CSI_STATUS=0x"); print_hex32(st);
    uint fmt_ = (st >> 16) & 0x3f;
    print(fmt_ != 0 ? " (DECODING, format bits 0x" : " (no packet decoded, format bits 0x");
    print_hex32(fmt_); print(")\n");
}

fn bool shell_test_cam_dispatch(char* cmd, char** cmd_argv, int cmd_argc) {
    if (strcmp(cmd, "cifpeek") == 0) {
        if (cmd_argc < 1) { print("usage: cifpeek <hexaddr> [count]\n"); return true; }
        uint a = cam_hex(cmd_argv[0]);
        int n = cmd_argc > 1 ? (int)cam_hex(cmd_argv[1]) : 1;
        for (int i = 0; i < n; i++) {
            uint v = 0;
            if (cam_cif(CAM_CIF_PEEK, a + (uint)i * 4, 0, &v) < 0) { break; }
            print_hex32(a + (uint)i * 4); print(" 0x"); print_hex32(v); print("\n");
        }
    } else if (strcmp(cmd, "cifpoke") == 0) {
        if (cmd_argc < 2) { print("usage: cifpoke <hexaddr> <hexval>\n"); return true; }
        uint a = cam_hex(cmd_argv[0]);
        uint v = cam_hex(cmd_argv[1]);
        uint back = 0;
        if (cam_cif(CAM_CIF_POKE, a, v, null) == 0 && cam_cif(CAM_CIF_PEEK, a, 0, &back) == 0) {
            print_hex32(a); print(" <- 0x"); print_hex32(v); print(", reads 0x"); print_hex32(back); print("\n");
        }
    } else if (strcmp(cmd, "cifstat") == 0) {
        cam_print_status();
    } else if (strcmp(cmd, "cifdiff") == 0) {
        // Live state vs the Linux golden state, region by region.
        int want = cmd_argc > 0 ? cam_region_code(cmd_argv[0]) : -1;
        int ndiff = 0;
        int nread = 0;
        for (int i = 0; i < CAM_GOLDEN_N; i++) {
            if (want >= 0 && (int)CAM_GOLDEN_REGION[i] != want) { continue; }
            if (cam_golden_skip(CAM_GOLDEN_ADDR[i])) { continue; }
            uint v = 0;
            if (cam_cif(CAM_CIF_PEEK, CAM_GOLDEN_ADDR[i], 0, &v) < 0) { break; }
            nread++;
            if (v != CAM_GOLDEN_VAL[i]) {
                ndiff++;
                print_hex32(CAM_GOLDEN_ADDR[i]); print(" racccoon 0x"); print_hex32(v);
                print("  linux 0x"); print_hex32(CAM_GOLDEN_VAL[i]); print("\n");
            }
        }
        print("cifdiff: "); print_uint((uint)ndiff); print(" of "); print_uint((uint)nread); print(" words differ from the Linux golden state\n");
    } else if (strcmp(cmd, "cifgolden") == 0) {
        // Write the Linux golden values: VIP_SYS gates, then the D-PHY
        // wrapper, then the CSI MAC — never clocks or resets, and never
        // MAC's status/interrupt words (+0x440..+0x47c).
        char* which = cmd_argc > 0 ? cmd_argv[0] : "all";
        bool all = strcmp(which, "all") == 0;
        int written = 0;
        for (int pass = 0; pass < 3; pass++) {
            int region = pass == 0 ? 2 : (pass == 1 ? 1 : 0);
            if (!all && cam_region_code(which) != region) { continue; }
            for (int i = 0; i < CAM_GOLDEN_N; i++) {
                if ((int)CAM_GOLDEN_REGION[i] != region) { continue; }
                uint a = CAM_GOLDEN_ADDR[i];
                if (cam_golden_skip(a)) { continue; }
                if (region == 2 && a > 0x0a0c8004) { continue; }          // VIP_SYS: just the gate/reset pair
                if (region == 0 && a >= 0x0a0c2440 && a <= 0x0a0c247c) { continue; }
                if (cam_cif(CAM_CIF_POKE, a, CAM_GOLDEN_VAL[i], null) < 0) { return true; }
                written++;
            }
        }
        print("cifgolden: wrote "); print_uint((uint)written); print(" words ("); print(which); print(")\n");
        ulong hz = timebase_hz();
        for (int k = 0; k < 5; k++) {
            ulong t = rdtime();
            while (rdtime() - t < hz / 5) { yield(); }
            cam_print_status();
        }
    } else if (strcmp(cmd, "snspeek") == 0) {
        if (cmd_argc < 1) { print("usage: snspeek <hexreg> [count]\n"); return true; }
        uint r = cam_hex(cmd_argv[0]);
        int n = cmd_argc > 1 ? (int)cam_hex(cmd_argv[1]) : 1;
        for (int i = 0; i < n; i++) {
            char v = 0;
            if (cam_sns(r + (uint)i, false, 0, &v) < 0) { break; }
            print("0x"); print_hex32(r + (uint)i); print(" = 0x"); print_hex32((uint)v); print("\n");
        }
    } else if (strcmp(cmd, "snspoke") == 0) {
        if (cmd_argc < 2) { print("usage: snspoke <hexreg> <hexval>\n"); return true; }
        uint r = cam_hex(cmd_argv[0]);
        char v = (char)cam_hex(cmd_argv[1]);
        char back = 0;
        if (cam_sns(r, true, v, null) == 0 && cam_sns(r, false, 0, &back) == 0) {
            print("0x"); print_hex32(r); print(" <- 0x"); print_hex32((uint)v); print(", reads 0x"); print_hex32((uint)back); print("\n");
        }
    } else {
        return false;
    }
    return true;
}
