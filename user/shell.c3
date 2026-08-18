module user;

int rfork_shared_value = 0;
int rfork_child_ran = 0; // set by rforkmemtest's child, checked by rforkmemresult

// threadcreate's own private stack for threadtest, and the shared
// global the thread writes to — proving the parent can see what the
// thread wrote is what makes this "shared memory," not just "a process
// that happened to run."
char[4096] thread_stack;
int thread_result = 0;

fn void thread_body(void* arg) {
    thread_result = 99;
    print("thread: running on my own stack, wrote thread_result\n");
    exit();
}

// racetest: two threads (true concurrency at the IPC level — both share
// this process's memory and can genuinely interleave mid-send) message
// echod at once. Before SYS_IPC_SEND was hardened into a rendezvous, a
// second sender could silently overwrite the first sender's still-
// unconsumed message in echod's single-slot inbox — this is what that
// actually looks like when it goes wrong: one reply comes back matching
// the *other* thread's payload instead of its own, or a thread hangs
// forever waiting for a reply to a message echod never actually saw.
char[4096] race_stack_a;
char[4096] race_stack_b;
char[16] race_reply_a;
char[16] race_reply_b;
int race_ok_a = 0;
int race_ok_b = 0;

fn void race_thread_a(void* arg) {
    ipc_send(2, 0, "AAAA", 5);
    ipc_recv(&race_reply_a, 16);
    race_ok_a = strcmp(&race_reply_a, "AAAA") == 0 ? 1 : 0;
    exit();
}

fn void race_thread_b(void* arg) {
    ipc_send(2, 0, "BBBB", 5);
    ipc_recv(&race_reply_b, 16);
    race_ok_b = strcmp(&race_reply_b, "BBBB") == 0 ? 1 : 0;
    exit();
}

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
        } else if (strcmp(cmd, "readfile2") == 0) {
            // Exercises the second, simultaneously-mounted fsd instance
            // (see src/process.c3's fsd2_pid/docs/devlog.md) — same
            // "/2/" prefix ns_resolve()/fs_read() strip before the
            // request ever reaches the wire, so this is otherwise
            // identical to readfile above, just against whatever
            // partition board::FS_PARTITION_2_START_SECTOR names.
            char[128] buf2 @noinit;
            int len2 = fs_read("/2/hello.txt", &buf2, 128);
            if (len2 >= 0) {
                buf2[len2] = 0;
                print(&buf2);
                print("\n");
            } else {
                print("readfile2: not found (no second fsd mounted?)\n");
            }
        } else if (strcmp(cmd, "writefile") == 0) {
            fs_write("hello.txt", "Hello from shell!\n", 19);
        } else if (strcmp(cmd, "newfile") == 0) {
            // Exercises directory-entry creation specifically (writefile
            // above only ever overwrites the already-existing hello.txt)
            // — write, then read back through the same fs_read() path
            // readfile uses, to confirm the new file is genuinely
            // findable and correct, not just that the write call
            // returned success.
            fs_write("newtest.txt", "Created by newfile test\n", 25);
            char[128] buf @noinit;
            int len = fs_read("newtest.txt", &buf, 128);
            if (len >= 0) {
                buf[len] = 0;
                print(&buf);
            } else {
                print("newfile: readback failed\n");
            }
        } else if (strcmp(cmd, "protectedwrite") == 0) {
            // Deliberately attempts to write the one file fsd is
            // supposed to refuse no matter what (see user/fsd.c3's
            // header comment) — the actual point of the write-
            // protection work, not a hypothetical. -1 (rejected) is the
            // only correct result on the real board; on QEMU's
            // disposable test image, fip.bin doesn't exist at all, so
            // this exercises the "create a new file" path instead —
            // still harmless there, just not the real test.
            int result = fs_write("fip.bin", "should never land\n", 18);
            if (result < 0) {
                print("protectedwrite: rejected (correct)\n");
            } else {
                print("protectedwrite: WARNING: write was ACCEPTED\n");
            }
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
            int pid_root = ns_resolve("/anything", null);
            print("resolve /anything -> pid ");
            putchar((char)('0' + pid_root));
            print("\n");

            int pid_fallback = ns_resolve("nope", null);
            print("resolve nope -> pid ");
            putchar((char)('0' + pid_fallback));
            print(" (catch-all)\n");
        } else if (strcmp(cmd, "rforktest") == 0) {
            // Plain rfork(RFPROC): the child gets an independent copy of
            // this process's address space (src/entry.c3's SYS_RFORK,
            // non-RFMEM branch). Both branches below are the *same*
            // rfork() call returning twice — proof that the child really
            // resumed from here, not a fresh entry point. Passing null
            // for generation_out: this child is never joined, so there's
            // nothing to capture it for.
            int r = rfork(RFPROC, null);
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
            // global before forking; if the child sees the same value
            // (checked later via rforkmemresult), it's genuinely the
            // same memory, not a copy.
            //
            // The ecall is inlined rather than going through the usual
            // rfork()/syscall() wrappers, and — this matters, found the
            // hard way — so is *everything the child does afterward*.
            // RFMEM shares the live user stack for the child's entire
            // remaining lifetime, not just the instant it resumes: an
            // earlier version of this command had the child call
            // print()/putchar()/exit() same as rforktest's child does,
            // and it genuinely paged-faulted the kernel once, under
            // real timing, once enough of the parent's own subsequent
            // activity (itself just continuing normally — printing its
            // own message, handling the next command) had reused the
            // same stack memory those functions' own spilled return
            // addresses depended on (see docs/devlog.md). The child
            // path below does a plain global assignment (no function
            // call, no stack touched at all) and exits via a second raw
            // ecall — nothing here ever calls into rfork()/syscall()/
            // print()/putchar()/exit(). This is exactly the discipline
            // threadcreate (see threadtest) automates properly, with an
            // actual private stack instead of "be careful by hand" —
            // that's the one to reach for outside a deliberately
            // minimal demonstration like this.
            rfork_shared_value = 42;
            rfork_child_ran = 0;
            // RV64 port: these locals widen to `long` — c3c's block-form
            // asm (the `$a0`-style bindings below) requires a register
            // binding to be native register width, and a 32-bit `int`
            // is rejected on a 64-bit target (same restriction as
            // user.c3's syscall()/syscall4() — see docs/devlog.md).
            long rf_flags = RFPROC | RFMEM;
            long rf_sysno = SYS_RFORK;
            long rf_gen_out = 0; // null — this child is never joined
            long r;
            asm {
                mv $a0, rf_flags;
                mv $a1, rf_gen_out;
                mv $a3, rf_sysno;
                ecall;
                mv r, $a0;
            }
            if (r < 0) {
                print("rfork failed\n");
            } else if (r == 0) {
                rfork_child_ran = rfork_shared_value;
                long exit_sysno = SYS_EXIT;
                asm {
                    mv $a3, exit_sysno;
                    ecall;
                }
            } else {
                print("parent: forked a thread sharing this address space\n");
            }
        } else if (strcmp(cmd, "rforkmemresult") == 0) {
            // Separate command, same reasoning as threadresult: the
            // child runs whenever the scheduler gets to it, not
            // synchronously with rforkmemtest.
            print("rfork_child_ran = ");
            putchar((char)('0' + rfork_child_ran / 10));
            putchar((char)('0' + rfork_child_ran % 10));
            print("\n");
        } else if (strcmp(cmd, "sandboxtest") == 0) {
            // Plain rfork(RFPROC) — a real, independent copy, so this
            // has none of rforkmemtest's shared-stack hazard. The child
            // drops its own fsd mount right after forking; the parent's
            // own namespace (and any other process's) is untouched,
            // since the child got its own copy at fork time, not a
            // reference to the parent's. Never joined, so null for
            // generation_out.
            int r = rfork(RFPROC, null);
            if (r < 0) {
                print("rfork failed\n");
            } else if (r == 0) {
                ns_unmount("");
                print("sandboxed child: readfile hello.txt -> ");
                char[32] buf @noinit;
                int len = fs_read("hello.txt", &buf, 32);
                if (len < 0) {
                    print("denied (fsd unmounted)\n");
                } else {
                    print("leaked!\n");
                }
                print("sandboxed child: ping echod -> ");
                ipc_send(2, 0, "hi", 2);
                char[16] reply @noinit;
                int from = ipc_recv(&reply, 16);
                if (from > 0) {
                    print("still works\n");
                } else {
                    print("no reply\n");
                }
                exit();
            } else {
                print("parent: spawned sandboxed child, pid ");
                putchar((char)('0' + r));
                print("\n");
            }
        } else if (strcmp(cmd, "threadtest") == 0) {
            // threadcreate (user.c3) — the stack-aware wrapper around
            // rfork(RFPROC|RFMEM). Unlike rforkmemtest, this is safe to
            // use normally: the thread gets its own real stack
            // (thread_stack) before it ever runs any C-level code, not
            // just a protected instant during the resume itself.
            thread_result = 0;
            char* thread_stack_top = (char*)&thread_stack + thread_stack.len;
            // Never joined here, so null for generation_out — that's
            // exactly what threadjointest is for.
            int tid = threadcreate(&thread_body, null, thread_stack_top, null);
            if (tid < 0) {
                print("threadcreate failed\n");
            } else {
                print("parent: created thread, tid ");
                putchar((char)('0' + tid));
                print(" (check with threadresult once it's run)\n");
            }
        } else if (strcmp(cmd, "threadresult") == 0) {
            // Separate command on purpose: the thread runs whenever the
            // scheduler gets to it, not synchronously with threadtest.
            // A nonzero value here, written by a process running on its
            // own independent stack, is what proves this is genuinely
            // shared memory rather than a copy.
            print("thread_result = ");
            putchar((char)('0' + thread_result / 10));
            putchar((char)('0' + thread_result % 10));
            print("\n");
        } else if (strcmp(cmd, "threadjointest") == 0) {
            // Same as threadtest, but joins the thread instead of
            // leaving the caller to guess when it's safe to check —
            // this is the whole reason join() exists. No more "ping a
            // few times and hope": join() blocks until the thread is
            // actually gone, so the result read right after it returns
            // is guaranteed current, not a guess.
            thread_result = 0;
            char* thread_stack_top = (char*)&thread_stack + thread_stack.len;
            uint tid_generation = 0;
            int tid = threadcreate(&thread_body, null, thread_stack_top, &tid_generation);
            if (tid < 0) {
                print("threadcreate failed\n");
            } else {
                join(tid, tid_generation);
                print("joined — thread_result = ");
                putchar((char)('0' + thread_result / 10));
                putchar((char)('0' + thread_result % 10));
                print("\n");
            }
        } else if (strcmp(cmd, "racetest") == 0) {
            race_ok_a = 0;
            race_ok_b = 0;
            char* stack_a_top = (char*)&race_stack_a + race_stack_a.len;
            char* stack_b_top = (char*)&race_stack_b + race_stack_b.len;
            uint gen_a = 0;
            uint gen_b = 0;
            int tid_a = threadcreate(&race_thread_a, null, stack_a_top, &gen_a);
            int tid_b = threadcreate(&race_thread_b, null, stack_b_top, &gen_b);
            join(tid_a, gen_a);
            join(tid_b, gen_b);
            print("racetest: a=");
            putchar((char)('0' + race_ok_a));
            print(" b=");
            putchar((char)('0' + race_ok_b));
            print(" (1=correct reply, 0=corrupted or lost)\n");
        } else {
            print("unknown command: ");
            print(cmd);
            print("\n");
        }
    }
}
