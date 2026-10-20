module user;

import std::io;

// ping [-c count] a.b.c.d — ICMP echo through ipd (/net/icmp). One
// request per second; prints the round trip of each reply, or "timeout"
// when none came back within ~1 s.
fn void main(String[] args) {
    int count = 4;
    usz a = 0;
    if (args.len >= 2 && args[0].len == 2 && args[0][0] == '-' && args[0][1] == 'c') {
        int? c = args[1].to_int();
        if (catch c) { io::print("ping: bad count\n"); return; }
        count = c;
        a = 2;
    }
    if (args.len != a + 1) {
        io::print("usage: ping [-c count] a.b.c.d\n");
        return;
    }
    char[64] addr;
    char* pre = "icmp!";
    int o = 0;
    for (int i = 0; pre[i] != 0; i++) { addr[o] = pre[i]; o++; }
    for (usz i = 0; i < args[a].len && o < 63; i++) { addr[o] = args[a][i]; o++; }
    addr[o] = 0;
    int h = dial(&addr[0]);
    if (h < 0) { io::print("ping: no route\n"); exitcode(1); }
    ulong hz = timebase_hz();
    int got = 0;
    for (int seq = 1; seq <= count; seq++) {
        char[56] pay;
        for (int i = 0; i < 56; i++) { pay[i] = (char)(seq + i); }
        ulong t0 = rdtime();
        net_write(h, &pay[0], 56);
        char[128] r;
        int n = net_read1(h, &r[0], 128);
        ulong us = (rdtime() - t0) * 1000000 / hz;
        io::printf("%s: seq=%d ", (ZString)args[a].ptr, seq);
        if (n == 56) {
            got++;
            io::printfn("time=%d.%03d ms", (int)(us / 1000), (int)(us % 1000));
        } else {
            io::printn("timeout");
        }
        ulong next = t0 + hz;
        if (seq < count) { while (rdtime() < next) { await_any(0, next - rdtime(), null, 0); } }
    }
    hangup(h);
    io::printfn("%d sent, %d received", count, got);
    if (got == 0) { exitcode(1); }
}
