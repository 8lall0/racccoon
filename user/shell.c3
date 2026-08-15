module user;

int rfork_shared_value = 0;

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
            int len = fs_read("hello.txt", &buf, 128);
            if (len >= 0) {
                buf[len] = 0;
                print(&buf);
                print("\n");
            }
        } else if (strcmp(cmd, "writefile") == 0) {
            fs_write("hello.txt", "Hello from shell!\n", 19);
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
            // itself works, independent of the 9P-lite/fsd layers built
            // on top of it. Two mounts today (src/process.c3's
            // create_process): "/" -> echod (pid 2), and a "" catch-all
            // -> fsd (pid 4) for anything that doesn't start with "/" —
            // which is every plain filename, "nope" included.
            int pid_root = ns_resolve("/anything");
            print("resolve /anything -> pid ");
            putchar((char)('0' + pid_root));
            print("\n");

            int pid_fallback = ns_resolve("nope");
            print("resolve nope -> pid ");
            putchar((char)('0' + pid_fallback));
            print(" (catch-all)\n");
        } else if (strcmp(cmd, "rforktest") == 0) {
            // Plain rfork(RFPROC): the child gets an independent copy of
            // this process's address space (src/entry.c3's SYS_RFORK,
            // non-RFMEM branch). Both branches below are the *same*
            // rfork() call returning twice — proof that the child really
            // resumed from here, not a fresh entry point.
            int r = rfork(RFPROC);
            if (r < 0) {
                print("rfork failed\n");
            } else if (r == 0) {
                print("child: hello from the fork\n");
                exit();
            } else {
                print("parent: child is pid ");
                putchar((char)('0' + r));
                print("\n");
            }
        } else if (strcmp(cmd, "rforkmemtest") == 0) {
            // rfork(RFPROC | RFMEM): the child shares this process's
            // address space instead of copying it — the same call as
            // rforktest, one flag apart, is now "spawn a thread." Set a
            // global before forking; if the child sees the same value,
            // it's genuinely the same memory, not a copy.
            //
            // The ecall is inlined here rather than going through the
            // usual rfork()/syscall() wrappers: RFMEM shares the live
            // user stack too (a real, observed sharp edge, not a
            // hypothetical one — see docs/devlog.md), and syscall()/
            // rfork() being separate function calls means their own
            // return addresses get spilled onto that shared stack. The
            // parent's very next function call — even just the print()
            // that would otherwise go here — runs before the child ever
            // gets scheduled, and overwrites exactly that memory; the
            // child then resumes into garbage while unwinding back out
            // of frames that no longer hold what it left there. Staying
            // inside main()'s own single frame, with no function-call
            // boundary to unwind back through, sidesteps that for this
            // demonstration — it doesn't protect this process's *actual*
            // stack in general, only this one command's use of rfork.
            rfork_shared_value = 42;
            int rf_flags = RFPROC | RFMEM;
            int rf_sysno = SYS_RFORK;
            int r;
            asm {
                mv $a0, rf_flags;
                mv $a3, rf_sysno;
                ecall;
                mv r, $a0;
            }
            if (r < 0) {
                print("rfork failed\n");
            } else if (r == 0) {
                print("child: shared_value is ");
                putchar((char)('0' + rfork_shared_value / 10));
                putchar((char)('0' + rfork_shared_value % 10));
                print("\n");
                exit();
            } else {
                print("parent: forked a thread sharing this address space\n");
            }
        } else {
            print("unknown command: ");
            print(cmd);
            print("\n");
        }
    }
}
