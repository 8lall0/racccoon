module user;

import std::io;

// Minimal integer `expr` — enough for shell loop counters
// (`i=`{expr $i + 1}`, docs/roadmap.md §2.5). Evaluates one expression
// given as separate argv words and prints the result. Exit status: 0 if
// the result is a non-zero number, 1 if it is 0, 2 on a parse error
// (POSIX-ish).
//
//   expr N + N - N            + - with * / % binding tighter
//   expr N '*' N              (* is quoted in the shell — it's a glob char)
//   expr S1 = S2  / != < <= > >=   comparison, prints 1 or 0
//
// No parentheses, no string ops beyond compare, no regex `:` — a
// deliberately tiny calculator, not GNU expr.

int[64] g_vals @noinit;   // parsed integer value of each arg (0 if non-numeric)
bool[64] g_isnum @noinit;
String[] g_a;
usz g_n;
usz g_pos;
bool g_err;

fn bool streq(String a, String b) {
    if (a.len != b.len) return false;
    for (usz i = 0; i < a.len; i++) { if (a[i] != b[i]) return false; }
    return true;
}

fn bool at(usz i, String s) { return i < g_n && streq(g_a[i], s); }

fn long factor() {
    if (g_pos >= g_n) { g_err = true; return 0; }
    if (!g_isnum[g_pos]) { g_err = true; return 0; }
    long v = (long)g_vals[g_pos];
    g_pos++;
    return v;
}

fn long term() {
    long v = factor();
    while (g_pos < g_n && (at(g_pos, "*") || at(g_pos, "/") || at(g_pos, "%"))) {
        String op = g_a[g_pos];
        g_pos++;
        long r = factor();
        if (streq(op, "*")) { v = v * r; }
        else if (r == 0)    { g_err = true; return 0; }
        else if (streq(op, "/")) { v = v / r; }
        else { v = v % r; }
    }
    return v;
}

fn long sum() {
    long v = term();
    while (g_pos < g_n && (at(g_pos, "+") || at(g_pos, "-"))) {
        String op = g_a[g_pos];
        g_pos++;
        long r = term();
        v = streq(op, "+") ? v + r : v - r;
    }
    return v;
}

fn void put_long(long v) {
    char[24] b @noinit;
    int i = 0;
    bool neg = v < 0;
    ulong u = neg ? (ulong)(-v) : (ulong)v;
    b[i] = (char)('0' + (int)(u % 10)); i++; u /= 10;
    while (u > 0) { b[i] = (char)('0' + (int)(u % 10)); i++; u /= 10; }
    if (neg) { b[i] = '-'; i++; }
    while (i > 0) { i--; io::putchar(b[i]); }
    io::putchar('\n');
}

fn void main(String[] args) {
    g_a = args;
    g_n = args.len > 64 ? 64 : args.len;
    for (usz i = 0; i < g_n; i++) {
        int? v = args[i].to_int();
        if (catch v) { g_isnum[i] = false; g_vals[i] = 0; }
        else { g_isnum[i] = true; g_vals[i] = v; }
    }

    if (g_n == 0) { io::print("usage: expr ARG...\n"); exitcode(2); }

    // Comparison form: exactly `S1 OP S2`.
    if (g_n == 3) {
        String op = args[1];
        bool cmp = streq(op, "=") || streq(op, "!=") || streq(op, "<")
                || streq(op, "<=") || streq(op, ">") || streq(op, ">=");
        if (cmp) {
            bool both_num = g_isnum[0] && g_isnum[2];
            int res;
            if (both_num) {
                int x = g_vals[0];
                int y = g_vals[2];
                if (streq(op, "="))       { res = x == y ? 1 : 0; }
                else if (streq(op, "!=")) { res = x != y ? 1 : 0; }
                else if (streq(op, "<"))  { res = x <  y ? 1 : 0; }
                else if (streq(op, "<=")) { res = x <= y ? 1 : 0; }
                else if (streq(op, ">"))  { res = x >  y ? 1 : 0; }
                else                      { res = x >= y ? 1 : 0; }
            } else {
                bool eq = streq(args[0], args[2]);
                res = (streq(op, "=") && eq) || (streq(op, "!=") && !eq) ? 1 : 0;
            }
            put_long(res);
            exitcode(res != 0 ? 0 : 1);
        }
    }

    g_pos = 0;
    g_err = false;
    long r = sum();
    if (g_err || g_pos != g_n) { io::print("expr: syntax error\n"); exitcode(2); }
    put_long(r);
    exitcode(r != 0 ? 0 : 1);
}
