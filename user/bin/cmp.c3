module user;

import std::nolibc::main_stub;

// cmp FILE1 FILE2 — byte-compare two files. Silent + exit 0 if
// identical; prints "differ: byte N, line L" + exit 1 on the first
// difference; exit 2 on an unreadable file.

fn void put_int(int v) {
    char[12] d @noinit;
    int i = 0;
    d[i] = (char)('0' + v % 10); i++; v /= 10;
    while (v > 0) { d[i] = (char)('0' + v % 10); i++; v /= 10; }
    while (i > 0) { i--; putchar(d[i]); }
}

fn void main(String[] args) {
    if (args.len != 2) { print("usage: cmp FILE1 FILE2\n"); exitcode(2); }

    char[100] p1 @noinit;
    char[100] p2 @noinit;
    usz n1 = args[0].len < 99 ? args[0].len : 99;
    usz n2 = args[1].len < 99 ? args[1].len : 99;
    for (usz k = 0; k < n1; k++) { p1[k] = args[0][k]; } p1[n1] = 0;
    for (usz k = 0; k < n2; k++) { p2[k] = args[1][k]; } p2[n2] = 0;

    char[4096] b1 @noinit;
    char[4096] b2 @noinit;
    uint off = 0;
    int byte_no = 0;
    int line_no = 1;
    for (;;) {
        int r1 = fs_read_at(&p1[0], &b1[0], 4096, off);
        int r2 = fs_read_at(&p2[0], &b2[0], 4096, off);
        if (r1 < 0) { print("cmp: "); print(&p1[0]); print(": not found\n"); exitcode(2); }
        if (r2 < 0) { print("cmp: "); print(&p2[0]); print(": not found\n"); exitcode(2); }
        int m = r1 < r2 ? r1 : r2;
        for (int i = 0; i < m; i++) {
            byte_no++;
            if (b1[i] != b2[i]) {
                print(&p1[0]); putchar(' '); print(&p2[0]);
                print(" differ: byte "); put_int(byte_no);
                print(", line "); put_int(line_no);
                putchar('\n');
                exitcode(1);
            }
            if (b1[i] == '\n') { line_no++; }
        }
        if (r1 != r2) {
            print(&p1[0]); putchar(' '); print(&p2[0]);
            print(" differ: one is shorter (byte "); put_int(byte_no + 1); print(")\n");
            exitcode(1);
        }
        if (r1 < 4096) { break; }
        off += 4096;
    }
    exitcode(0);
}
