module user;

import std::io;

// nc — a netcat over ipd (/net):
//   nc a.b.c.d port        tcp client
//   nc -l port             tcp: accept one connection
//   nc -u a.b.c.d port     udp client
//   nc -u -l port          udp: answer whoever sent last
// stdin goes to the network (a line at a time from the console, in 1 KiB
// chunks from a pipe), the network goes to stdout. A forked child does
// the receiving. At the end of stdin nc keeps reading until the peer
// closes; -N also half-closes the tcp connection (sends our FIN) right
// then, for servers that wait for it. udp just stops.


fn void copy_out(int h, bool udp_headers) {
    char[8192] buf;
    for (;;) {
        int n = net_read(h, &buf[0], 8192);
        if (n <= 0) { return; }
        int start = udp_headers ? 6 : 0;
        if (n > start) { write_stdout(&buf[start], n - start); }
    }
}

fn void main(String[] args) {
    bool udp = false;
    bool listen = false;
    bool shut = false;
    usz a = 0;
    while (a < args.len && args[a].len == 2 && args[a][0] == '-') {
        if (args[a][1] == 'u') { udp = true; }
        else if (args[a][1] == 'l') { listen = true; }
        else if (args[a][1] == 'N') { shut = true; }
        else { break; }
        a++;
    }
    if ((listen && args.len != a + 1) || (!listen && args.len != a + 2)) {
        io::print("usage: nc [-u] [-N] host port | nc [-u] [-N] -l port\n");
        exitcode(2);
    }
    char[64] addr;
    int o = 0;
    char* pre = udp ? "udp!" : "tcp!";
    for (int i = 0; pre[i] != 0; i++) { addr[o] = pre[i]; o++; }
    if (listen) { addr[o] = '*'; addr[o + 1] = '!'; o += 2; }
    for (usz i = 0; i < args[a].len && o < 40; i++) { addr[o] = args[a][i]; o++; }
    if (!listen) {
        addr[o] = '!'; o++;
        for (usz i = 0; i < args[a + 1].len && o < 62; i++) { addr[o] = args[a + 1][i]; o++; }
    }
    addr[o] = 0;

    int h;
    bool headers = false;
    if (listen) {
        int ls = announce(&addr[0]);
        if (ls < 0) { io::print("nc: can't announce\n"); exitcode(1); }
        if (udp) {
            h = ls;
            headers = true;
            net_ctl(h, "headers");
        } else {
            h = net_listen(ls);
            hangup(ls);
            if (h < 0) { io::print("nc: listen failed\n"); exitcode(1); }
        }
    } else {
        h = dial(&addr[0]);
        if (h < 0) { io::print("nc: connection failed\n"); exitcode(1); }
    }

    // A udp listener replies to the most recent sender: the receiving
    // child can't tell the parent who that is, so with -u -l the reply
    // address comes from the first datagram, read here before forking.
    char[6] peer;
    if (headers) {
        char[2048] first;
        int n = net_read(h, &first[0], 2048);
        if (n < 6) { exitcode(1); }
        for (int i = 0; i < 6; i++) { peer[i] = first[i]; }
        for (int i = 6; i < n; i++) { putchar(first[i]); }
    }

    uint g = 0;
    int child = rfork(RFPROC, &g);
    if (child == 0) {
        copy_out(h, headers);
        exitcode(0);
    }

    char[1030] line;
    int ln = headers ? 6 : 0;
    if (headers) { for (int i = 0; i < 6; i++) { line[i] = peer[i]; } }
    bool console = stdin_is_console() != 0;
    for (;;) {
        int c = getchar();
        if (c >= 0) {
            line[ln] = (char)c;
            ln++;
        }
        bool flush = c < 0 || ln >= 1030 || (console && c == '\n') || (console && c == '\r');
        if (console && c == '\r') { line[ln - 1] = '\n'; putchar('\n'); }
        if (flush && ln > (headers ? 6 : 0)) {
            if (net_write(h, &line[0], ln) < 0) { break; }
            ln = headers ? 6 : 0;
        }
        if (c < 0) { break; }
    }
    if (udp) {
        kill(child, g);
    } else {
        if (shut) { net_ctl(h, "close"); }
        join(child, g);
    }
    hangup(h);
}
