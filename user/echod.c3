module user;

// Minimal IPC test server. Started out as a pure echo (proving two
// processes can exchange a message at all — see docs/devlog.md); now
// also speaks the first two 9P-lite verbs (P9_TWALK/P9_TREAD, defined in
// user.c3), to prove the protocol layer works over the same raw
// primitive. Anything else — including the untyped (type 0) messages
// shell.c3's "ping" command still sends — falls through to the original
// raw echo, so that command keeps working unchanged.
fn void main() @export("main") {
    char[64] buf @noinit;
    for (;;) {
        uint verb = 0;
        int from = ipc_recv_type(&buf, 64, &verb);
        if (from <= 0) continue;

        if (verb == P9_TREAD) {
            char* canned = "hello from 9p-lite\n";
            ipc_send(from, P9_TREAD, canned, 21);
        } else if (verb == P9_TWALK) {
            // No real namespace yet (that's a later phase) — just prove
            // the path made it across by handing it straight back.
            ipc_send(from, P9_TWALK, &buf, 64);
        } else {
            ipc_send(from, verb, &buf, 64);
        }
    }
}
