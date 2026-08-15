module user;

fn void main() @export("main") {
    for (;;) {
        print("> ");

        char[128] cmdline @noinit;
        int i = 0;
        bool too_long = false;
        for (;;) {
            char ch = (char)getchar();
            putchar(ch);
            if (i == 127) {
                print("\ncommand line too long\n");
                too_long = true;
                break;
            }
            if (ch == '\r') {
                print("\n");
                cmdline[i] = 0;
                break;
            }
            cmdline[i] = ch;
            i++;
        }

        if (too_long) continue;

        char* cmd = &cmdline[0];
        if (strcmp(cmd, "hello") == 0) {
            print("Hello world from shell!\n");
        } else if (strcmp(cmd, "exit") == 0) {
            exit();
        } else if (strcmp(cmd, "readfile") == 0) {
            char[128] buf @noinit;
            int len = readfile("hello.txt", &buf, 128);
            if (len >= 0) {
                buf[len] = 0;
                print(&buf);
                print("\n");
            }
        } else if (strcmp(cmd, "writefile") == 0) {
            writefile("hello.txt", "Hello from shell!\n", 19);
        } else if (strcmp(cmd, "ping") == 0) {
            // echod is always the first process spawned after idle (see
            // kernel.c3), so it's always pid 2 — a placeholder until
            // there's a real name -> pid lookup (namespace work, not this
            // first IPC slice).
            ipc_send(2, 0, "hello echod", 12);
            char[64] reply @noinit;
            int from = ipc_recv(&reply, 64);
            if (from > 0) {
                print("echod (pid ");
                putchar((char)('0' + from));
                print(") replied: ");
                print(&reply);
                print("\n");
            } else {
                print("ping: no reply\n");
            }
        } else if (strcmp(cmd, "p9test") == 0) {
            // No hardcoded pid anymore: "/some/path" is resolved through
            // this process's own namespace (src/process.c3's default
            // mount table, "/" -> echod) to find the server, over the
            // 9P-lite verbs (user.c3's p9_call_path).
            char[64] reply @noinit;
            uint reply_verb = 0;

            int from_walk = p9_call_path("/some/path", P9_TWALK, "some/path", 10, &reply, 64, &reply_verb);
            if (from_walk > 0 && reply_verb == P9_TWALK) {
                print("walk ack: ");
                print(&reply);
                print("\n");
            } else {
                print("walk failed\n");
            }

            int from_read = p9_call_path("/", P9_TREAD, null, 0, &reply, 64, &reply_verb);
            if (from_read > 0 && reply_verb == P9_TREAD) {
                print("read: ");
                print(&reply);
            } else {
                print("read failed\n");
            }
        } else if (strcmp(cmd, "nstest") == 0) {
            // Direct namespace-resolution smoke test: prove ns_resolve
            // itself works (matches "/" -> pid 2, rejects an unmounted
            // prefix), independent of the 9P-lite layer built on top of it.
            int pid_root = ns_resolve("/anything");
            print("resolve /anything -> pid ");
            putchar((char)('0' + pid_root));
            print("\n");

            int pid_none = ns_resolve("nope");
            if (pid_none < 0) {
                print("resolve nope -> no mount (as expected)\n");
            } else {
                print("resolve nope -> unexpectedly matched\n");
            }
        } else {
            print("unknown command: ");
            print(cmd);
            print("\n");
        }
    }
}
