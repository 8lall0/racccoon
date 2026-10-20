module user;

import std::io;

// rshd [port] — remote shell over TCP (default port 23). Each connection
// gets /bin/rc (the production shell, login prompt included) with a
// pipe for stdin and one for stdout:
//
//   network ──(input pump)──▶ pipe ──▶ rc ──▶ pipe ──(session)──▶ network
//
// The session runs in its own note group (RFNOTEG), so the client's ^C
// (a 0x03 byte, turned into an "interrupt" note by the input pump) stops
// the remote shell's foreground command, not rshd or the console. When
// the client hangs up, the shell's stdin reaches EOF and it exits; when
// the shell exits, its stdout reaches EOF and the connection is closed.
// No authentication beyond rc's own login: this is a LAN tool.

fn void input_pump(int conn, int to_shell, int shell_group) {
    char[4096] buf;
    for (;;) {
        int n = net_read(conn, &buf[0], 4096);
        if (n <= 0) { break; }
        int start = 0;
        for (int i = 0; i < n; i++) {
            if (buf[i] == 3) {
                if (i > start) { pipe_write(to_shell, &buf[start], i - start); }
                postnote_group(shell_group, "interrupt");
                start = i + 1;
            }
        }
        if (n > start) { pipe_write(to_shell, &buf[start], n - start); }
    }
}

fn void session(int conn) {
    net_ctl(conn, "own");
    int to_shell = pipe_new();
    int from_shell = pipe_new();
    if (to_shell < 0 || from_shell < 0) {
        net_write(conn, "rshd: out of pipes\r\n", 20);
        hangup(conn);
        return;
    }
    pipe_hold(to_shell, 1, 1);     // we write the shell's stdin
    pipe_hold(from_shell, 0, 1);   // we read its stdout

    uint sg = 0;
    int sh = rfork_io(RFPROC | RFNOTEG, &sg, from_shell, to_shell);
    if (sh == 0) {
        char[1] none;
        char* buf = (char*)map_pages(exec_max());
        exec("/bin/rc", buf, exec_max(), 0, (char**)&none, 0);
        exitcode(127);
    }
    if (sh < 0) {
        net_write(conn, "rshd: can't start rc\r\n", 22);
        hangup(conn);
        return;
    }

    uint pg = 0;
    int pump = rfork(RFPROC, &pg);
    // A pipe hold is a counter on the pipe, not a per-process reference:
    // the writer hold taken above stays until the pump finishes (the client
    // hung up) and drops it, which is the shell's EOF.
    if (pump == 0) {
        input_pump(conn, to_shell, sh);
        pipe_hold(to_shell, 1, -1);
        exitcode(0);
    }

    char[4096] out;
    for (;;) {
        int n = pipe_read(from_shell, &out[0], 4096);
        if (n <= 0) { break; }
        if (net_write(conn, &out[0], n) < 0) { break; }
    }
    pipe_hold(from_shell, 0, -1);
    // The shell is gone. If the pump is still running we stop it and drop
    // its writer hold for it; if it already finished, it dropped it itself.
    if (kill(pump, pg) == 0) { pipe_hold(to_shell, 1, -1); }
    kill(sh, sg);
    hangup(conn);
}

fn void main(String[] args) {
    char[32] addr;
    char* pre = "tcp!*!";
    int o = 0;
    for (int i = 0; pre[i] != 0; i++) { addr[o] = pre[i]; o++; }
    if (args.len >= 1) {
        for (usz i = 0; i < args[0].len && o < 30; i++) { addr[o] = args[0][i]; o++; }
    } else {
        addr[o] = '2'; addr[o + 1] = '3'; o += 2;
    }
    addr[o] = 0;
    int ls = announce(&addr[0]);
    if (ls < 0) { io::print("rshd: can't announce\n"); exitcode(1); }
    io::printfn("rshd: listening on %s", (ZString)&addr[0]);
    for (;;) {
        int c = net_listen(ls);
        if (c < 0) { continue; }
        uint g = 0;
        int s = rfork(RFPROC | RFNOTEG, &g);
        if (s == 0) {
            session(c);
            exitcode(0);
        }
    }
}
