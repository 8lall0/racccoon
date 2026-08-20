module user;

// Minimal IPC test server. Started out as a pure echo (proving two
// processes can exchange a message at all — see docs/devlog.md); now
// also speaks the first two 9P-lite verbs (P9_TWALK/P9_TREAD, defined in
// user.c3), to prove the protocol layer works over the same raw
// primitive. Anything else — including the untyped (type 0) messages
// shell.c3's "ping"/"runtest" commands still send — falls through to
// the original raw echo, so those keep working unchanged.
fn void main() @export("main") {
    // If exec()'d with an argument (user/shell.c3's argvtest), argv[0]
    // replaces the hardcoded P9_TREAD reply below — concrete, observable
    // proof argv actually reached this process, not just that exec()
    // itself returned success. Boot-time (pid 2, no argv) and runtest's
    // own no-args exec() both get argc=0 here, so the canned reply stays
    // exactly what it's always been for them.
    char** argv;
    int argc = get_argv(&argv);
    char* canned = "hello from 9p-lite\n";
    int canned_len = 21;
    if (argc > 0) {
        canned = argv[0];
        canned_len = 0;
        while (canned[canned_len] != 0) canned_len++;
    }

    char[64] buf @noinit;
    for (;;) {
        uint verb = 0;
        uint from_gen = 0;
        int from = ipc_recv_type_gen(&buf, 64, &verb, &from_gen);
        if (from <= 0) continue;

        if (verb == P9_TREAD) {
            ipc_reply(from, P9_TREAD, canned, canned_len, from_gen);
        } else if (verb == P9_TWALK) {
            // No real namespace yet (that's a later phase) — just prove
            // the path made it across by handing it straight back.
            ipc_reply(from, P9_TWALK, &buf, 64, from_gen);
        } else {
            ipc_reply(from, verb, &buf, 64, from_gen);
        }
    }
}
