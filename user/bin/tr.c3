module user;

import std::nolibc::main_stub;

// tr SET1 SET2  — map each byte in SET1 to the byte at the same index
//                 in SET2 (SET2's last byte repeats if it's shorter).
// tr -d SET1    — delete every byte in SET1.
// Ranges: `a-z` expands. Reads stdin, writes stdout.

char[256] g_expanded @noinit;
int g_ex_len;

fn void expand_set(String s, char* out, int* outlen) {
    int o = 0;
    usz i = 0;
    while (i < s.len && o < 255) {
        if (i + 2 < s.len && s[i + 1] == '-' && s[i] <= s[i + 2]) {
            for (char c = s[i]; c <= s[i + 2] && o < 255; c++) { out[o] = c; o++; }
            i += 3;
        } else {
            out[o] = s[i]; o++; i++;
        }
    }
    *outlen = o;
}

fn void main(String[] args) {
    bool del = false;
    usz ai = 0;
    if (ai < args.len && args[ai].len == 2 && args[ai][0] == '-' && args[ai][1] == 'd') {
        del = true;
        ai++;
    }

    if (del) {
        if (args.len - ai != 1) { print("usage: tr -d SET\n"); exitcode(2); }
        char[256] set @noinit;
        int sl = 0;
        expand_set(args[ai], &set[0], &sl);
        for (;;) {
            int c = getchar();
            if (c < 0) { break; }
            bool drop = false;
            for (int k = 0; k < sl; k++) { if (set[k] == (char)c) { drop = true; break; } }
            if (!drop) { putchar((char)c); }
        }
        return;
    }

    if (args.len - ai != 2) { print("usage: tr SET1 SET2   |   tr -d SET1\n"); exitcode(2); }
    char[256] s1 @noinit;
    char[256] s2 @noinit;
    int l1 = 0;
    int l2 = 0;
    expand_set(args[ai], &s1[0], &l1);
    expand_set(args[ai + 1], &s2[0], &l2);
    if (l2 == 0) { print("tr: SET2 is empty\n"); exitcode(2); }

    for (;;) {
        int c = getchar();
        if (c < 0) { break; }
        char oc = (char)c;
        for (int k = 0; k < l1; k++) {
            if (s1[k] == oc) {
                oc = (k < l2) ? s2[k] : s2[l2 - 1];
                break;
            }
        }
        putchar(oc);
    }
}
