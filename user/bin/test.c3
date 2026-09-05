module user;

import std::io;

// POSIX-ish `test` / `[` — the primitive the shell's `if` / `while`
// conditions are built on (docs/roadmap.md §2.5). Exit 0 = true, 1 =
// false, 2 = usage error. Invoked as `[` it drops a trailing `]`; the
// same binary is seeded as both /bin/test and /bin/[ (scripts/build.sh).
//
// Supported:
//   -e P / -f P / -d P / -s P      exists / is a file / is a dir / non-empty
//   -z S / -n S                    string is empty / non-empty
//   S                              one arg: true iff non-empty
//   S1 = S2 / S1 != S2             string (in)equality
//   N1 -eq -ne -lt -le -gt -ge N2  integer comparison
//   ! EXPR                         negate any of the above
//
// No -a / -o / parens — rc/racccoon scripts use `&&` / `||` between
// separate `test` calls instead, which is clearer anyway.

fn bool streq(String a, String b) {
    if (a.len != b.len) return false;
    for (usz i = 0; i < a.len; i++) { if (a[i] != b[i]) return false; }
    return true;
}

fn void cstr(String s, char* out, usz cap) {
    usz n = s.len < cap - 1 ? s.len : cap - 1;
    for (usz i = 0; i < n; i++) { out[i] = s[i]; }
    out[n] = 0;
}

fn bool path_stat(String p, uint* size, int* type) {
    char[128] buf @noinit;
    cstr(p, &buf[0], 128);
    return fs_stat(&buf[0], size, type) == 0;
}

// Evaluate the (count) args starting at a[from]. 0 = true, 1 = false, 2 = usage.
fn int eval(String[] a, usz from, usz count) {
    if (count == 0) return 1;                   // `test` with nothing -> false

    if (streq(a[from], "!")) {
        int r = eval(a, from + 1, count - 1);
        if (r == 2) return 2;
        return r == 0 ? 1 : 0;
    }

    if (count == 1) {
        return a[from].len > 0 ? 0 : 1;
    }

    if (count == 2) {
        String op = a[from];
        String x  = a[from + 1];
        if (streq(op, "-z")) return x.len == 0 ? 0 : 1;
        if (streq(op, "-n")) return x.len != 0 ? 0 : 1;
        uint fsz; int fty;
        bool ok = path_stat(x, &fsz, &fty);
        if (streq(op, "-e")) return ok ? 0 : 1;
        if (streq(op, "-f")) return (ok && fty == 0) ? 0 : 1;
        if (streq(op, "-d")) return (ok && fty == 1) ? 0 : 1;
        if (streq(op, "-s")) return (ok && fsz > 0) ? 0 : 1;
        io::print("test: unknown unary operator\n");
        return 2;
    }

    if (count == 3) {
        String x  = a[from];
        String op = a[from + 1];
        String y  = a[from + 2];
        if (streq(op, "="))  return streq(x, y) ? 0 : 1;
        if (streq(op, "!=")) return streq(x, y) ? 1 : 0;

        int? xi = x.to_int();
        int? yi = y.to_int();
        if (catch xi) { io::print("test: integer expected\n"); return 2; }
        if (catch yi) { io::print("test: integer expected\n"); return 2; }
        if (streq(op, "-eq")) return xi == yi ? 0 : 1;
        if (streq(op, "-ne")) return xi != yi ? 0 : 1;
        if (streq(op, "-lt")) return xi <  yi ? 0 : 1;
        if (streq(op, "-le")) return xi <= yi ? 0 : 1;
        if (streq(op, "-gt")) return xi >  yi ? 0 : 1;
        if (streq(op, "-ge")) return xi >= yi ? 0 : 1;
        io::print("test: unknown binary operator\n");
        return 2;
    }

    io::print("test: too many arguments\n");
    return 2;
}

fn void main(String[] args) {
    usz count = args.len;
    // `[ ... ]` — drop the required trailing `]` (a plain `test` never
    // has one, so this is safe for both names).
    if (count > 0 && streq(args[count - 1], "]")) { count--; }
    exitcode(eval(args, 0, count));
}
