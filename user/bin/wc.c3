module user;

import std::nolibc::main_stub;

// wc [-lwc] [file...] — line / word / byte counts. No file (or "-") =
// stdin, for `… | wc`. Counts are printed right-aligned-ish, then the
// name; with several files a "total" line follows.

int g_l, g_w, g_c;

fn void count_bytes(char* p, int n, bool* inword) {
    for (int i = 0; i < n; i++) {
        char ch = p[i];
        g_c++;
        if (ch == '\n') { g_l++; }
        bool sp = ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r';
        if (!sp && !*inword) { g_w++; *inword = true; }
        if (sp) { *inword = false; }
    }
}

fn void put_uint(uint v) {
    char[12] d @noinit;
    int i = 0;
    d[i] = (char)('0' + v % 10); i++; v /= 10;
    while (v > 0) { d[i] = (char)('0' + v % 10); i++; v /= 10; }
    print("  ");
    while (i > 0) { i--; putchar(d[i]); }
}

fn void report(bool wl, bool ww, bool wc, char* name) {
    if (wl) { put_uint((uint)g_l); }
    if (ww) { put_uint((uint)g_w); }
    if (wc) { put_uint((uint)g_c); }
    if (name != null) { putchar(' '); print(name); }
    putchar('\n');
}

fn void main(String[] args) {
    bool wl = false;
    bool ww = false;
    bool wc = false;
    usz fi = 0;
    while (fi < args.len && args[fi].len >= 2 && args[fi][0] == '-' && args[fi][1] != 0) {
        for (usz k = 1; k < args[fi].len; k++) {
            char f = args[fi][k];
            if (f == 'l') { wl = true; }
            else if (f == 'w') { ww = true; }
            else if (f == 'c') { wc = true; }
            else { print("wc: bad option\n"); exitcode(2); }
        }
        fi++;
    }
    if (!wl && !ww && !wc) { wl = true; ww = true; wc = true; }

    if (fi >= args.len) {
        bool inword = false;
        char[512] buf @noinit;
        for (;;) {
            int c = getchar();
            if (c < 0) { break; }
            buf[0] = (char)c;
            count_bytes(&buf[0], 1, &inword);
        }
        report(wl, ww, wc, null);
        return;
    }

    int tl = 0;
    int tw = 0;
    int tc = 0;
    int nf = 0;
    for (usz a = fi; a < args.len; a++) {
        char[100] path @noinit;
        usz pn = args[a].len < 99 ? args[a].len : 99;
        for (usz k = 0; k < pn; k++) { path[k] = args[a][k]; }
        path[pn] = 0;

        g_l = 0; g_w = 0; g_c = 0;
        bool inword = false;
        char[4096] buf @noinit;
        uint off = 0;
        for (;;) {
            int n = fs_read_at(&path[0], &buf[0], 4096, off);
            if (n <= 0) { break; }
            count_bytes(&buf[0], n, &inword);
            off += (uint)n;
            if (n < 4096) { break; }
        }
        if (off == 0) {
            int probe = fs_read(&path[0], &buf[0], 1);
            if (probe < 0) { print("wc: "); print(&path[0]); print(": not found\n"); continue; }
        }
        report(wl, ww, wc, &path[0]);
        tl += g_l; tw += g_w; tc += g_c;
        nf++;
    }
    if (nf > 1) {
        g_l = tl; g_w = tw; g_c = tc;
        report(wl, ww, wc, "total");
    }
}
