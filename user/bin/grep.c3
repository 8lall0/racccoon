module user;

import std::nolibc::main_stub;

// grep [-vinc] PATTERN [file...] — print lines containing PATTERN
// (literal substring, not a regexp — same call as ed's search). No
// file = stdin. -v invert, -i case-insensitive, -n prefix line number,
// -c print only the count. Exit 0 if any line matched, 1 if none.

bool g_v, g_i, g_n, g_c;
char[128] g_pat @noinit;
int g_patlen;
int g_hits;

fn char lc(char x) { return (x >= 'A' && x <= 'Z') ? (char)(x + 32) : x; }

fn bool line_matches(char* s, int len) {
    if (g_patlen == 0) { return true; }
    for (int i = 0; i + g_patlen <= len; i++) {
        int m = 0;
        while (m < g_patlen) {
            char a = s[i + m];
            char b = g_pat[m];
            if (g_i) { a = lc(a); b = lc(b); }
            if (a != b) { break; }
            m++;
        }
        if (m == g_patlen) { return true; }
    }
    return false;
}

fn void put_int(int v) {
    char[12] d @noinit;
    int i = 0;
    d[i] = (char)('0' + v % 10); i++; v /= 10;
    while (v > 0) { d[i] = (char)('0' + v % 10); i++; v /= 10; }
    while (i > 0) { i--; putchar(d[i]); }
}

fn void handle_line(char* s, int len, int lineno, char* fileprefix) {
    bool hit = line_matches(s, len);
    if (g_v) { hit = !hit; }
    if (!hit) { return; }
    g_hits++;
    if (g_c) { return; }
    if (fileprefix != null) { print(fileprefix); putchar(':'); }
    if (g_n) { put_int(lineno); putchar(':'); }
    for (int i = 0; i < len; i++) { putchar(s[i]); }
    putchar('\n');
}

fn void grep_stdin() {
    char[1024] line @noinit;
    int k = 0;
    int no = 0;
    for (;;) {
        int c = getchar();
        if (c < 0) { if (k > 0) { no++; handle_line(&line[0], k, no, null); } break; }
        if (c == '\n') { no++; handle_line(&line[0], k, no, null); k = 0; continue; }
        if (c == '\r') { continue; }
        if (k < 1023) { line[k] = (char)c; k++; }
    }
}

fn void grep_file(char* path, char* prefix) {
    char[8192] buf @noinit;
    int n = fs_read(path, &buf[0], 8191);
    if (n < 0) { print("grep: "); print(path); print(": not found\n"); return; }
    int start = 0;
    int no = 0;
    for (int i = 0; i <= n; i++) {
        if (i == n || buf[i] == '\n') {
            if (i > start || i < n) {
                no++;
                int e = i;
                if (e > start && buf[e - 1] == '\r') { e--; }
                handle_line(&buf[start], e - start, no, prefix);
            }
            start = i + 1;
        }
    }
}

fn void main(String[] args) {
    usz ai = 0;
    while (ai < args.len && args[ai].len >= 2 && args[ai][0] == '-') {
        for (usz k = 1; k < args[ai].len; k++) {
            char f = args[ai][k];
            if (f == 'v') { g_v = true; }
            else if (f == 'i') { g_i = true; }
            else if (f == 'n') { g_n = true; }
            else if (f == 'c') { g_c = true; }
            else { print("grep: bad option\n"); exitcode(2); }
        }
        ai++;
    }
    if (ai >= args.len) { print("usage: grep [-vinc] PATTERN [file...]\n"); exitcode(2); }

    g_patlen = args[ai].len < 127 ? (int)args[ai].len : 127;
    for (int k = 0; k < g_patlen; k++) { g_pat[k] = args[ai][k]; }
    g_pat[g_patlen] = 0;
    ai++;

    bool multi = args.len - ai > 1;
    if (ai >= args.len) {
        grep_stdin();
    } else {
        for (usz a = ai; a < args.len; a++) {
            char[100] path @noinit;
            usz pn = args[a].len < 99 ? args[a].len : 99;
            for (usz k = 0; k < pn; k++) { path[k] = args[a][k]; }
            path[pn] = 0;
            int before = g_hits;
            grep_file(&path[0], multi ? &path[0] : null);
            if (g_c) {
                if (multi) { print(&path[0]); putchar(':'); }
                put_int(g_hits - before);
                putchar('\n');
            }
        }
    }
    if (g_c && ai >= args.len) { put_int(g_hits); putchar('\n'); }

    exitcode(g_hits > 0 ? 0 : 1);
}
