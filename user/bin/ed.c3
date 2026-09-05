module user;

import std::nolibc::main_stub;

// A small `ed` — the classic Unix line editor, so racccoon can edit a
// file without host tools (see the "ideas beyond the roadmap" note).
// Deliberately tiny:
//
//   addressing   N   .   $   .+N   .-N   ,   N,M   /text/   ?text?
//                (search is a literal substring, not a regexp)
//   p n          print / print-with-line-numbers
//   a i c        append after / insert before / change — text ends at a
//                lone "." line
//   d            delete
//   j m          join / move
//   s/old/new/   substitute first (add g for all) — literal, per line
//   r file       read file in after the addressed line
//   w [file]     write (default: the file named on the command line)
//   = q Q        line number / quit (Q forces past unsaved changes)
//   <empty>      print the next line
//
// Limits: LINES lines, LINELEN bytes/line. Fits a script or a small
// source file; not a replacement for a real editor.

const int LINES   = 300;
const int LINELEN = 160;
const int IOBUF   = LINES * (LINELEN + 4);   // whole-file scratch

char[LINELEN][LINES] g_buf @noinit;
char[IOBUF]          g_io  @noinit;          // shared read/write scratch
int  g_n     = 0;        // lines in buffer
int  g_dot   = 0;        // current line (1-based; 0 = before line 1)
bool g_dirty = false;
char[100] g_fname @noinit;
bool g_have_fname = false;
bool g_quit_armed = false;
int  g_p = 0;           // parse cursor into the command line

fn int slen(char* s) { int i = 0; while (s[i] != 0) { i++; } return i; }

fn void scopy(char* dst, char* src, int cap) {
    int i = 0;
    while (src[i] != 0 && i < cap - 1) { dst[i] = src[i]; i++; }
    dst[i] = 0;
}

fn void put_int(int v) {
    char[12] d @noinit;
    int i = 0;
    bool neg = v < 0;
    uint u = neg ? (uint)(-v) : (uint)v;
    d[i] = (char)('0' + u % 10); i++; u /= 10;
    while (u > 0) { d[i] = (char)('0' + u % 10); i++; u /= 10; }
    if (neg) { d[i] = '-'; i++; }
    while (i > 0) { i--; putchar(d[i]); }
}

fn void err() { print("?\n"); }

// --- buffer ops -----------------------------------------------------

fn bool insert_line(int at, char* text) {
    if (g_n >= LINES) { return false; }
    for (int i = g_n; i >= at; i--) { scopy(&g_buf[i][0], &g_buf[i - 1][0], LINELEN); }
    scopy(&g_buf[at - 1][0], text, LINELEN);
    g_n++;
    return true;
}

fn void delete_range(int a, int b) {
    int cnt = b - a + 1;
    for (int i = a; i + cnt <= g_n; i++) { scopy(&g_buf[i - 1][0], &g_buf[i + cnt - 1][0], LINELEN); }
    g_n -= cnt;
}

// Read lines from stdin until a lone "." — insert them from `at` (1-based).
// Returns the last inserted line number.
fn int read_input(int at) {
    int line = at;
    for (;;) {
        char[LINELEN] t @noinit;
        int k = 0;
        for (;;) {
            int c = getchar();
            if (c < 0) { break; }
            if (c == '\r' || c == '\n') { break; }
            if (k < LINELEN - 1) { t[k] = (char)c; k++; }
        }
        t[k] = 0;
        if (t[0] == '.' && t[1] == 0) { break; }
        if (!insert_line(line, &t[0])) { err(); break; }
        line++;
    }
    g_dirty = true;
    return line - 1;
}

// Split g_io[0..len) on '\n' into g_buf starting after line `at` (0 = at
// the very top). Returns the new g_dot.
fn int splice_io(int len, int at) {
    int start = 0;
    int here = at;
    for (int i = 0; i <= len; i++) {
        if (i == len || g_io[i] == '\n') {
            if (i < len || i > start) {
                char[LINELEN] t @noinit;
                int k = 0;
                for (int j = start; j < i && k < LINELEN - 1; j++) { if (g_io[j] != '\r') { t[k] = g_io[j]; k++; } }
                t[k] = 0;
                here++;
                if (!insert_line(here, &t[0])) { print("?too many lines\n"); break; }
            }
            start = i + 1;
        }
    }
    g_dirty = true;
    return here;
}

// --- address parsing ----------------------------------------------

fn void skip_sp(char* s) { while (s[g_p] == ' ' || s[g_p] == '\t') { g_p++; } }

fn int find_line(char* needle, int from, int dir) {
    int i = from;
    for (int step = 0; step < g_n; step++) {
        i += dir;
        if (i < 1) { i = g_n; }
        if (i > g_n) { i = 1; }
        char* lp = &g_buf[i - 1][0];
        for (int j = 0; lp[j] != 0; j++) {
            int m = 0;
            while (needle[m] != 0 && lp[j + m] == needle[m]) { m++; }
            if (needle[m] == 0) { return i; }
        }
    }
    return -1;
}

// Parse one address at g_p. -1 = none given, -2 = error.
fn int parse_addr(char* s) {
    skip_sp(s);
    int base = -1;
    char c = s[g_p];
    if (c == '.') { g_p++; base = g_dot; }
    else if (c == '$') { g_p++; base = g_n; }
    else if (c >= '0' && c <= '9') {
        int v = 0;
        while (s[g_p] >= '0' && s[g_p] <= '9') { v = v * 10 + (s[g_p] - '0'); g_p++; }
        base = v;
    }
    else if (c == '/' || c == '?') {
        int dir = c == '/' ? 1 : -1;
        g_p++;
        char[80] pat @noinit;
        int k = 0;
        while (s[g_p] != 0 && s[g_p] != c && k < 79) { pat[k] = s[g_p]; k++; g_p++; }
        pat[k] = 0;
        if (s[g_p] == c) { g_p++; }
        base = find_line(&pat[0], g_dot, dir);
        if (base < 0) { return -2; }
    }
    else if (c == '+' || c == '-') { base = g_dot; }

    for (;;) {
        skip_sp(s);
        char o = s[g_p];
        if (o != '+' && o != '-') { break; }
        g_p++;
        int v = 0;
        bool got = false;
        while (s[g_p] >= '0' && s[g_p] <= '9') { v = v * 10 + (s[g_p] - '0'); g_p++; got = true; }
        if (!got) { v = 1; }
        if (base < 0) { base = g_dot; }
        base += (o == '+') ? v : -v;
    }
    return base;
}

// --- substitute ---------------------------------------------------

fn bool do_subst(int a, int b, char* pat, char* rep, bool global) {
    bool changed = false;
    int pl = slen(pat);
    if (pl == 0) { return false; }
    for (int ln = a; ln <= b; ln++) {
        char* lp = &g_buf[ln - 1][0];
        char[LINELEN] out @noinit;
        int o = 0;
        int i = 0;
        bool done_one = false;
        while (lp[i] != 0) {
            bool hit = false;
            if (!done_one || global) {
                int m = 0;
                while (pat[m] != 0 && lp[i + m] == pat[m]) { m++; }
                if (pat[m] == 0) { hit = true; }
            }
            if (hit) {
                for (int r = 0; rep[r] != 0 && o < LINELEN - 1; r++) { out[o] = rep[r]; o++; }
                i += pl;
                done_one = true;
                changed = true;
            } else {
                if (o < LINELEN - 1) { out[o] = lp[i]; o++; }
                i++;
            }
        }
        out[o] = 0;
        if (done_one) { scopy(lp, &out[0], LINELEN); g_dot = ln; }
    }
    if (changed) { g_dirty = true; }
    return changed;
}

// --- file I/O ----------------------------------------------------

fn void load(char* name) {
    scopy(&g_fname[0], name, 100);
    g_have_fname = true;
    int got = fs_read(name, &g_io[0], IOBUF - 1);
    if (got < 0) {
        print(name); print(": cannot read (new file)\n");
        return;
    }
    g_dot = splice_io(got, 0);
    g_dirty = false;
    put_int(got); print("\n");
}

fn void write_file(char* name) {
    int o = 0;
    for (int i = 0; i < g_n && o < IOBUF - 1; i++) {
        char* lp = &g_buf[i][0];
        for (int j = 0; lp[j] != 0 && o < IOBUF - 1; j++) { g_io[o] = lp[j]; o++; }
        if (o < IOBUF - 1) { g_io[o] = '\n'; o++; }
    }
    int w = fs_write(name, &g_io[0], o);
    if (w < 0) { err(); return; }
    put_int(o); print("\n");
    g_dirty = false;
}

// --- main loop --------------------------------------------------

fn void main(String[] args) {
    if (args.len >= 1) {
        char[100] argfile @noinit;
        int k = 0;
        while (k < 99 && k < (int)args[0].len) { argfile[k] = args[0][k]; k++; }
        argfile[k] = 0;
        load(&argfile[0]);
    }

    for (;;) {
        char[LINELEN + 80] cmd @noinit;
        int k = 0;
        int c0 = getchar();
        if (c0 < 0) { break; }
        while (c0 >= 0 && c0 != '\n' && c0 != '\r') {
            if (k < LINELEN + 79) { cmd[k] = (char)c0; k++; }
            c0 = getchar();
        }
        cmd[k] = 0;

        g_p = 0;
        int a1 = parse_addr(&cmd[0]);
        int a2 = a1;
        skip_sp(&cmd[0]);
        if (cmd[g_p] == ',') {
            g_p++;
            if (a1 < 0) { a1 = 1; }
            int e = parse_addr(&cmd[0]);
            a2 = (e < 0) ? g_n : e;
        }
        if (a1 == -2 || a2 == -2) { err(); continue; }

        skip_sp(&cmd[0]);
        char op = cmd[g_p];
        if (op != 0) { g_p++; }
        skip_sp(&cmd[0]);
        char* arg = &cmd[g_p];

        int lo = a1 < 0 ? g_dot : a1;
        int hi = a2 < 0 ? lo : a2;

        if (op == 0) {
            int t = a1 < 0 ? g_dot + 1 : a1;
            if (t < 1 || t > g_n) { err(); continue; }
            g_dot = t;
            print(&g_buf[t - 1][0]); print("\n");
            continue;
        }

        if (op != 'q') { g_quit_armed = false; }

        switch (op) {
            case 'p':
            case 'n':
                if (g_n == 0 || lo < 1 || hi > g_n || lo > hi) { err(); break; }
                for (int i = lo; i <= hi; i++) {
                    if (op == 'n') { put_int(i); putchar('\t'); }
                    print(&g_buf[i - 1][0]); print("\n");
                }
                g_dot = hi;
            case '=':
                put_int(a1 < 0 ? g_n : lo); print("\n");
            case 'a':
                {
                    int at = a1 < 0 ? g_dot : a1;
                    g_dot = read_input(at + 1);
                }
            case 'i':
                {
                    int at = a1 < 0 ? g_dot : a1;
                    if (at < 1) { at = 1; }
                    g_dot = read_input(at);
                }
            case 'c':
                if (g_n == 0 || lo < 1 || hi > g_n || lo > hi) { err(); break; }
                delete_range(lo, hi);
                g_dot = read_input(lo);
            case 'd':
                if (g_n == 0 || lo < 1 || hi > g_n || lo > hi) { err(); break; }
                delete_range(lo, hi);
                g_dot = lo <= g_n ? lo : g_n;
                g_dirty = true;
            case 'j':
                {
                    int ja = a1 < 0 ? g_dot : lo;
                    int jb = a2 < 0 ? ja + 1 : hi;
                    if (ja < 1 || jb > g_n || ja >= jb) { err(); break; }
                    char[LINELEN] merged @noinit;
                    int mo = 0;
                    for (int i = ja; i <= jb; i++) {
                        char* lp = &g_buf[i - 1][0];
                        for (int q = 0; lp[q] != 0 && mo < LINELEN - 1; q++) { merged[mo] = lp[q]; mo++; }
                    }
                    merged[mo] = 0;
                    delete_range(ja, jb);
                    insert_line(ja, &merged[0]);
                    g_dot = ja;
                    g_dirty = true;
                }
            case 'm':
                {
                    int save_gp = g_p;
                    g_p = 0;
                    int dst = parse_addr(arg);   // arg-relative
                    g_p = save_gp;
                    if (dst < 0 || dst > g_n || lo < 1 || hi > g_n || lo > hi) { err(); break; }
                    int tc = hi - lo + 1;
                    if (tc > 64) { err(); break; }
                    char[LINELEN][64] tmp @noinit;
                    for (int i = 0; i < tc; i++) { scopy(&tmp[i][0], &g_buf[lo - 1 + i][0], LINELEN); }
                    delete_range(lo, hi);
                    int at = dst < lo ? dst : dst - tc;
                    for (int i = 0; i < tc; i++) { insert_line(at + 1 + i, &tmp[i][0]); }
                    g_dot = at + tc;
                    g_dirty = true;
                }
            case 's':
                {
                    char sep = arg[0];
                    if (sep == 0) { err(); break; }
                    int sp = 1;
                    char[80] pat @noinit; int pk = 0;
                    while (arg[sp] != 0 && arg[sp] != sep && pk < 79) { pat[pk] = arg[sp]; pk++; sp++; }
                    pat[pk] = 0;
                    if (arg[sp] != sep) { err(); break; }
                    sp++;
                    char[80] rep @noinit; int rk = 0;
                    while (arg[sp] != 0 && arg[sp] != sep && rk < 79) { rep[rk] = arg[sp]; rk++; sp++; }
                    rep[rk] = 0;
                    bool g = arg[sp] == sep && arg[sp + 1] == 'g';
                    if (g_n == 0 || lo < 1 || hi > g_n || lo > hi) { err(); break; }
                    if (!do_subst(lo, hi, &pat[0], &rep[0], g)) { err(); }
                }
            case 'r':
                {
                    if (arg[0] == 0) { err(); break; }
                    int rg = fs_read(arg, &g_io[0], IOBUF - 1);
                    if (rg < 0) { err(); break; }
                    int at = a1 < 0 ? g_dot : a1;
                    g_dot = splice_io(rg, at);
                    put_int(rg); print("\n");
                }
            case 'w':
                {
                    if (arg[0] == 0 && !g_have_fname) { print("?no file name\n"); break; }
                    if (arg[0] != 0) { scopy(&g_fname[0], arg, 100); g_have_fname = true; }
                    write_file(&g_fname[0]);
                }
            case 'q':
                if (g_dirty && !g_quit_armed) { g_quit_armed = true; print("?unsaved changes (q again)\n"); break; }
                return;
            case 'Q':
                return;
            default:
                err();
        }
    }
}
