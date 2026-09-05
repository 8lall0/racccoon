module user;

import std::nolibc::main_stub;

// sort [-rnu] [file...] — sort lines. -r reverse, -n numeric (leading
// integer), -u drop adjacent duplicates after sorting. No file = stdin.
// In-memory: LINES x LINELEN fixed.

const int LINES   = 400;
const int LINELEN = 160;
char[LINELEN][LINES] g_lines @noinit;
int g_n = 0;
bool g_rev, g_num, g_uniq;

fn void add_line(char* s, int len) {
    if (g_n >= LINES) { return; }
    int k = 0;
    while (k < len && k < LINELEN - 1) { g_lines[g_n][k] = s[k]; k++; }
    g_lines[g_n][k] = 0;
    g_n++;
}

fn long numval(char* s) {
    int i = 0;
    while (s[i] == ' ' || s[i] == '\t') { i++; }
    bool neg = s[i] == '-';
    if (neg || s[i] == '+') { i++; }
    long v = 0;
    bool digits = false;
    while (s[i] >= '0' && s[i] <= '9') { v = v * 10 + (long)(s[i] - '0'); i++; digits = true; }
    if (!digits) { return 0; }
    return neg ? -v : v;
}

// <0 / 0 / >0
fn int cmp_lines(int a, int b) {
    int r;
    if (g_num) {
        long x = numval(&g_lines[a][0]);
        long y = numval(&g_lines[b][0]);
        r = x < y ? -1 : (x > y ? 1 : 0);
    } else {
        int i = 0;
        r = 0;
        for (;;) {
            char ca = g_lines[a][i];
            char cb = g_lines[b][i];
            if (ca != cb) { r = (int)((uint)ca) - (int)((uint)cb); break; }
            if (ca == 0) { break; }
            i++;
        }
    }
    return g_rev ? -r : r;
}

fn void swap_lines(int a, int b) {
    char[LINELEN] t @noinit;
    int k = 0;
    while (g_lines[a][k] != 0 && k < LINELEN - 1) { t[k] = g_lines[a][k]; k++; } t[k] = 0;
    k = 0; while (g_lines[b][k] != 0 && k < LINELEN - 1) { g_lines[a][k] = g_lines[b][k]; k++; } g_lines[a][k] = 0;
    k = 0; while (t[k] != 0 && k < LINELEN - 1) { g_lines[b][k] = t[k]; k++; } g_lines[b][k] = 0;
}

fn void ingest_bytes(char* p, int n, char* acc, int* al) {
    for (int i = 0; i < n; i++) {
        char c = p[i];
        if (c == '\r') { continue; }
        if (c == '\n') { add_line(acc, *al); *al = 0; continue; }
        if (*al < LINELEN - 1) { acc[*al] = c; (*al)++; }
    }
}

fn void main(String[] args) {
    usz fi = 0;
    while (fi < args.len && args[fi].len >= 2 && args[fi][0] == '-') {
        for (usz k = 1; k < args[fi].len; k++) {
            char f = args[fi][k];
            if (f == 'r') { g_rev = true; }
            else if (f == 'n') { g_num = true; }
            else if (f == 'u') { g_uniq = true; }
            else { print("sort: bad option\n"); exitcode(2); }
        }
        fi++;
    }

    char[LINELEN] acc @noinit;
    int al = 0;
    if (fi >= args.len) {
        char[4096] buf @noinit;
        for (;;) {
            int c = getchar();
            if (c < 0) { break; }
            buf[0] = (char)c;
            ingest_bytes(&buf[0], 1, &acc[0], &al);
        }
    } else {
        for (usz a = fi; a < args.len; a++) {
            char[100] path @noinit;
            usz pn = args[a].len < 99 ? args[a].len : 99;
            for (usz k = 0; k < pn; k++) { path[k] = args[a][k]; }
            path[pn] = 0;
            char[4096] buf @noinit;
            uint off = 0;
            int total = 0;
            for (;;) {
                int n = fs_read_at(&path[0], &buf[0], 4096, off);
                if (n <= 0) { break; }
                ingest_bytes(&buf[0], n, &acc[0], &al);
                off += (uint)n; total += n;
                if (n < 4096) { break; }
            }
            if (total == 0) {
                int probe = fs_read(&path[0], &buf[0], 1);
                if (probe < 0) { print("sort: "); print(&path[0]); print(": not found\n"); }
            }
        }
    }
    if (al > 0) { add_line(&acc[0], al); }

    // insertion sort — n is small (<= LINES), lines are short
    for (int i = 1; i < g_n; i++) {
        int j = i;
        while (j > 0 && cmp_lines(j - 1, j) > 0) { swap_lines(j - 1, j); j--; }
    }

    for (int i = 0; i < g_n; i++) {
        if (g_uniq && i > 0) {
            int k = 0;
            bool same = true;
            for (;;) {
                if (g_lines[i][k] != g_lines[i - 1][k]) { same = false; break; }
                if (g_lines[i][k] == 0) { break; }
                k++;
            }
            if (same) { continue; }
        }
        print(&g_lines[i][0]);
        putchar('\n');
    }
}
