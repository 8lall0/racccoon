module user;

import std::nolibc::fmt;

// shell_test builtins — processes: exec/argv/PATH,
// rfork/threads/sandbox, kill/ps, memory (map/oom/fault), fpu, syscall
// hardening. Split out of shell_test.c3's main(), which tries each
// shell_test_*_dispatch in turn; true = cmd was one of these.

int rfork_shared_value = 0;

// proclimittest: more simultaneous processes than the old 16-slot table
// held. PLT_N children each park in ipc_recv(); the parent checks every
// one is live, then releases each with a message carrying a per-child
// exit code and joins it. A wrong code means a message went to the wrong
// slot; fewer than PLT_N forks means the table (or the page pool behind
// each slot's kernel stack + inbox) ran out.
const int PLT_N = 40;

// segtest: named shared segments (src/segment.c3).
fn void seg_test() {
    int pass = 0;
    int total = 0;

    // 1. An rfork child inherits the attachment — and it's the same
    // memory, not a copy: its write shows up here.
    total++;
    char* p = segattach("st", 8192);
    bool ok = p != null;
    if (ok) {
        p[0] = 'A';
        p[4096] = 'B';
        uint g = 0;
        int c = rfork(RFPROC, &g);
        if (c == 0) {
            bool seen = p[0] == 'A' && p[4096] == 'B';
            p[1] = 'C';
            exitcode(seen ? 1 : 2);
        }
        ok = join(c, g) == 1 && p[1] == 'C';
    }
    print("segtest: rfork child shares the segment: ");
    if (ok) { pass++; print("ok\n"); } else { print("FAILED\n"); }

    // 2. Attach by name from another address space (a child that
    // detached its inherited mapping first).
    total++;
    ok = p != null;
    if (ok) {
        uint g = 0;
        int c = rfork(RFPROC, &g);
        if (c == 0) {
            if (segdetach(p) != 0) { exitcode(3); }
            char* q = segattach("st", 0);
            if (q == null) { exitcode(4); }
            bool seen = q[0] == 'A' && q[1] == 'C';
            q[2] = 'D';
            exitcode(seen ? 1 : 2);
        }
        ok = join(c, g) == 1 && p[2] == 'D';
    }
    print("segtest: attach by name sees the same pages: ");
    if (ok) { pass++; print("ok\n"); } else { print("FAILED\n"); }

    // 3. Last detach frees it: attaching the name again gets fresh,
    // zeroed memory.
    total++;
    ok = p != null && segdetach(p) == 0;
    if (ok) {
        char* r = segattach("st", 4096);
        ok = r != null && r[0] == 0 && r[1] == 0 && r[2] == 0;
        if (r != null) { segdetach(r); }
    }
    print("segtest: freed on last detach: ");
    if (ok) { pass++; print("ok\n"); } else { print("FAILED\n"); }

    // 4. Create/destroy more segments than the table holds (16): only
    // works if each one is really released.
    total++;
    int cycles = 0;
    for (int i = 0; i < 24; i++) {
        char[8] nm;
        nm[0] = 'c'; nm[1] = (char)('a' + i); nm[2] = 0;
        char* r = segattach(&nm[0], 65536);
        if (r == null) { break; }
        r[65535] = 1;
        if (segdetach(r) != 0) { break; }
        cycles++;
    }
    print("segtest: 24 create/destroy cycles: ");
    if (cycles == 24) { pass++; print("ok\n"); } else { print("FAILED at "); print_uint((uint)cycles); print("\n"); }

    // 5. Another uid may not attach root's segment.
    total++;
    char* pv = segattach("pv", 4096);
    ok = pv != null;
    if (ok) {
        uint g = 0;
        int c = rfork(RFPROC, &g);
        if (c == 0) {
            segdetach(pv);
            setuid(77);
            exitcode(segattach("pv", 0) == null ? 1 : 2);
        }
        ok = join(c, g) == 1;
        segdetach(pv);
    }
    print("segtest: other uid refused: ");
    if (ok) { pass++; print("ok\n"); } else { print("FAILED\n"); }

    // 6. Exiting without a detach releases it too (proc_destroy's hook).
    total++;
    uint eg = 0;
    int ec = rfork(RFPROC, &eg);
    if (ec == 0) {
        char* e = segattach("ex", 4096);
        if (e == null) { exitcode(2); }
        e[0] = 'Z';
        exitcode(1);
    }
    ok = join(ec, eg) == 1;
    if (ok) {
        char* e2 = segattach("ex", 4096);
        ok = e2 != null && e2[0] == 0;
        if (e2 != null) { segdetach(e2); }
    }
    print("segtest: released when the last holder exits: ");
    if (ok) { pass++; print("ok\n"); } else { print("FAILED\n"); }

    // 7. A Mutex inside the segment works across processes: both sides
    // hold it across a yield (so the other really blocks in futex_wait)
    // and bump a shared counter. Needs SYS_FUTEX_WAKE to find a waiter in
    // a *different* address space — it matches the physical word.
    total++;
    char* mseg = segattach("mx", 4096);
    ok = mseg != null;
    if (ok) {
        Mutex* mx = (Mutex*)mseg;
        int* counter = (int*)(mseg + 64);
        const int MX_N = 200;
        uint g = 0;
        int c = rfork(RFPROC, &g);
        for (int i = 0; i < MX_N; i++) {
            mx.lock();
            int v = *counter;
            yield();
            *counter = v + 1;
            mx.unlock();
        }
        if (c == 0) { exitcode(1); }
        ok = c > 0 && join(c, g) == 1 && *counter == 2 * MX_N;
        if (!ok) { print("segtest: counter = "); print_uint((uint)*counter); print("\n"); }
        segdetach(mseg);
    }
    print("segtest: Mutex in a segment, across processes: ");
    if (ok) { pass++; print("ok\n"); } else { print("FAILED\n"); }

    print("segtest: ");
    print_uint((uint)pass);
    print("/");
    print_uint((uint)total);
    print(pass == total ? " — PASS\n" : " — FAIL\n");
}

// notetest: notes (src/note.c3). Each case runs in an rforked child —
// which inherits the shell's own note handler until it installs its own.
int nt_count = 0;
char[8] nt_first;

fn void nt_handler(char* msg) {
    if (nt_count == 0) {
        for (int i = 0; i < 7; i++) { nt_first[i] = msg[i]; }
        nt_first[7] = 0;
    }
    nt_count++;
    noted(NCONT);
}

// Spin (yielding, so each trap can deliver a note) until `n` notes have
// been handled or ~3 s pass.
fn void nt_wait_count(int n) {
    ulong end = rdtime() + timebase_hz() * 3;
    while (nt_count < n && rdtime() < end) { yield(); }
}

fn void nt_settle() {
    ulong end = rdtime() + timebase_hz() / 2;
    while (rdtime() < end) { yield(); }
}

fn void note_test() {
    int pass = 0;
    int total = 0;

    // 1. Three notes, queued at once, each handled in order.
    total++;
    uint g = 0;
    int c = rfork(RFPROC, &g);
    if (c == 0) {
        nt_count = 0;
        notify(&nt_handler);
        nt_wait_count(3);
        bool first_ok = nt_first[0] == 'p' && nt_first[1] == 'i' && nt_first[2] == 'n' && nt_first[3] == 'g' && nt_first[4] == '1';
        exitcode(nt_count == 3 && first_ok ? 42 : 40 + nt_count);
    }
    nt_settle();
    postnote(c, "ping1");
    postnote(c, "ping2");
    postnote(c, "ping3");
    int r = join(c, g);
    print("notetest: handler caught 3 queued notes in order: ");
    if (r == 42) { pass++; print("ok\n"); } else { print("FAILED (code "); print_uint((uint)r); print(")\n"); }

    // 2. No handler: a note kills (join returns -1).
    total++;
    c = rfork(RFPROC, &g);
    if (c == 0) {
        notify(null);
        ulong end = rdtime() + timebase_hz() * 3;
        while (rdtime() < end) { yield(); }
        exitcode(7);
    }
    nt_settle();
    postnote(c, "interrupt");
    r = join(c, g);
    print("notetest: no handler -> killed: ");
    if (r == -1) { pass++; print("ok\n"); } else { print("FAILED (code "); print_uint((uint)r); print(")\n"); }

    // 3. A blocked ipc_recv is cut short; interrupted() says why.
    total++;
    c = rfork(RFPROC, &g);
    if (c == 0) {
        nt_count = 0;
        notify(&nt_handler);
        char[8] b;
        int rr = ipc_recv(&b[0], 8);
        bool intr = interrupted();
        exitcode(rr == -1 && intr && nt_count == 1 ? 5 : 6);
    }
    nt_settle();
    postnote(c, "wake");
    r = join(c, g);
    print("notetest: blocked ipc_recv interrupted: ");
    if (r == 5) { pass++; print("ok\n"); } else { print("FAILED (code "); print_uint((uint)r); print(")\n"); }

    // 4. "kill" kills even with a handler installed.
    total++;
    c = rfork(RFPROC, &g);
    if (c == 0) {
        notify(&nt_handler);
        ulong end = rdtime() + timebase_hz() * 3;
        while (rdtime() < end) { yield(); }
        exitcode(7);
    }
    nt_settle();
    postnote(c, "kill");
    r = join(c, g);
    print("notetest: kill overrides the handler: ");
    if (r == -1) { pass++; print("ok\n"); } else { print("FAILED (code "); print_uint((uint)r); print(")\n"); }

    // 5. A group post reaches every member: a leader started with
    // RFNOTEG and its own child; neither has a handler.
    total++;
    c = rfork(RFPROC | RFNOTEG, &g);
    if (c == 0) {
        notify(null);
        uint g2 = 0;
        rfork(RFPROC, &g2);   // the grandchild shares this note group
        ulong end = rdtime() + timebase_hz() * 3;
        while (rdtime() < end) { yield(); }
        exitcode(7);
    }
    nt_settle();
    int n = postnote_group(c, "interrupt");
    r = join(c, g);
    print("notetest: group post reached ");
    print_uint((uint)n);
    print(" processes (expect 2), leader killed: ");
    if (n == 2 && r == -1) { pass++; print("ok\n"); } else { print("FAILED\n"); }

    print("notetest: ");
    print_uint((uint)pass);
    print("/");
    print_uint((uint)total);
    print(pass == total ? " — PASS\n" : " — FAIL\n");
}

fn void proclimit_test() {
    int[PLT_N] plt_pid;
    uint[PLT_N] plt_gen;
    int made = 0;
    for (int i = 0; i < PLT_N; i++) {
        int r = rfork(RFPROC, &plt_gen[i]);
        if (r == 0) {
            char[8] cb;
            ipc_recv(&cb[0], 8);
            exitcode((int)cb[0]);
        }
        if (r < 0) break;
        plt_pid[i] = r;
        made++;
    }
    int alive = 0;
    for (int i = 0; i < made; i++) {
        uint g = 0;
        if (proc_info(plt_pid[i], null, &g, null) == 0 && g == plt_gen[i]) alive++;
    }
    int good = 0;
    for (int i = 0; i < made; i++) {
        char[8] m;
        m[0] = (char)(i + 1);
        ipc_send(plt_pid[i], 1, &m[0], 8);
        if (join(plt_pid[i], plt_gen[i]) == i + 1) good++;
    }
    print("proclimittest: forked ");
    print_uint((uint)made);
    print(" alive ");
    print_uint((uint)alive);
    print(" reaped-with-right-code ");
    print_uint((uint)good);
    if (made == PLT_N && alive == PLT_N && good == PLT_N) {
        print(" — PASS\n");
    } else {
        print(" — FAIL\n");
    }
}

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
//
// A misleading "a=0 b=0" result was chased down once (docs/devlog.md)
// and turned out to be neither of those — process.c3's PROCS_MAX was
// too small, so threadcreate() below silently failed for one or both
// threads and they never ran at all. See the threadcreate-failure check
// below for how that's now reported distinctly instead of looking like
// IPC corruption.
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

// mutextest: two threads increment the same shared counter through
// user.c3's Mutex — unlike racetest (which proves the *kernel's* own
// IPC rendezvous can't be corrupted by concurrent senders), this proves
// user.c3's own Mutex genuinely serializes access, including the actual
// futex_wait/futex_wake path, not just the uncontended CAS fast path.
//
// Found the hard way while writing this test: creating both threads
// and just incrementing in a tight loop, even for millions of
// iterations, essentially never exercises real contention. Neither
// thread has any other reason to yield mid-loop, so with nothing
// forcing an interleave, one thread runs to completion (or close to
// it) before the other gets meaningful CPU time — confirmed directly
// by temporarily removing the lock/unlock calls entirely and still
// getting a fully correct count, which would only happen if the two
// threads' increments essentially never actually landed at the same
// moment. A stray real timer interrupt (~once/second — see
// enable_timer_interrupts()'s own comment) can preempt mid-loop, but
// the vulnerable window in a bare "counter = counter + 1" is only 1-2
// instructions wide out of the thousands executed between ticks — far
// too narrow a target to hit reliably.
//
// Fixed by deliberately *widening the gap between the read and the
// write themselves* — the standard technique for reliably demonstrating
// this class of race (see e.g. any textbook "read, sleep, write" data-
// race demo), not just delaying before an otherwise-still-adjacent
// read-modify-write. Each iteration reads mutex_test_counter into a
// local, spins for a real, fixed slice of wall-clock time (using
// rdtime() the same way sdd.c3 already does for its own real-time
// budgets — not a raw instruction count, so this holds for comparable
// real time on both boards despite their different TIMEBASE_HZ), *then*
// writes local+1 back. With that gap spanning a meaningful fraction of
// a preemption tick (~once/second — see enable_timer_interrupts()'s own
// comment) and several iterations for a tick to land somewhere inside
// it, the other thread reliably gets a real chance to read the same
// stale value in between — exactly what the lock exists to prevent.
const ulong MUTEX_TEST_GAP_TICKS = 2000000; // ~0.2s at 10MHz (QEMU), ~0.08s at 25MHz (Duo)
const int MUTEX_TEST_ITERS = 8;
char[4096] mutex_stack_a;
char[4096] mutex_stack_b;
Mutex mutex_test_lock;
int mutex_test_counter = 0;

fn void mutex_thread_body(void* arg) {
    for (int i = 0; i < MUTEX_TEST_ITERS; i++) {
        mutex_test_lock.lock();
        int tmp = mutex_test_counter;
        ulong gap_start = rdtime();
        while (rdtime() - gap_start < MUTEX_TEST_GAP_TICKS) {}
        mutex_test_counter = tmp + 1;
        mutex_test_lock.unlock();
    }
    exit();
}

fn bool shell_test_proc_dispatch(char* cmd, char** cmd_argv, int cmd_argc) {
    if (strcmp(cmd, "synhist") == 0) {
        // DIAGNOSTIC (temporary): per-syscall-number histogram over a
        // ~5 s window while the shell just yields — catches a
        // background spinner (netd link-poll, a server busy-wait).
        // `synhist go` also wraps gostage2test to catch a Go-runtime
        // spin. Chasing the go-build syscall storm.
        ulong[64] sh_a @noinit; ulong[64] sh_b @noinit;
        bool sh_go = (cmd_argc > 0 && strcmp(cmd_argv[0], "go") == 0);
        prof_hist(&sh_a[0], 1);   // reset — the kernel histogram is now 0
        ulong sh_hz = timebase_hz();
        ulong sh_t0 = rdtime();
        if (sh_go) {
            char*[1] sh_av; sh_av[0] = "x";
            uint sh_g = 0; int sh_c = rfork(RFPROC, &sh_g);
            if (sh_c == 0) { exec("bin/go-gostage2", exec_buf(), exec_buf_max(), 0, &sh_av[0], 1); exitcode(127); }
            join(sh_c, sh_g);
        } else {
            ulong sh_win = sh_hz * 5;
            while (rdtime() - sh_t0 < sh_win) { yield(); }
        }
        ulong sh_wall = rdtime() - sh_t0;
        prof_hist(&sh_b[0], 0);   // sh_b IS the window's counts (reset above)
        print("synhist: window ");
        print_uint((uint)(sh_hz > 0 ? sh_wall / sh_hz : 0)); print("s\n");
        for (int sv = 0; sv < 64; sv++) {
            ulong sd = sh_b[sv];
            if (sd == 0) continue;
            ulong rate = (sh_wall > 0 && sh_hz > 0) ? (sd * sh_hz) / sh_wall : 0;
            print("  sys "); print_uint((uint)sv); print(": ");
            print_uint((uint)(sd / 1000)); print("k  (");
            print_uint((uint)(rate / 1000)); print("k/s)\n");
        }
    } else if (strcmp(cmd, "hardentest") == 0) {
        // Regression guard for src/page.c3's user_range_valid() and
        // its call sites in src/syscalls.c3: proves a syscall given a
        // deliberately bad user pointer, or a syscall number the
        // kernel doesn't recognize, denies cleanly (this process
        // gets -1 back) instead of the whole kernel panicking —
        // exactly the two concrete failures this hardening pass
        // fixed (see docs/devlog.md). Both are real ecalls, not a
        // simulation: if either regresses, this either hangs the
        // whole suite (a panic halts every process, this one
        // included) or this specific command never returns.
        int ht_null_futex = futex_wait((int*)null, 0);
        print("hardentest: SYS_FUTEX_WAIT on a null pointer ");
        print(ht_null_futex < 0 ? "correctly denied\n" : "WRONGLY succeeded\n");

        // Well past the highest syscall number the kernel's switch
        // has a case for (33 today) — genuinely unrecognized, with
        // enough headroom that adding real syscalls won't silently
        // turn this into a call to one of them (which is exactly
        // what happened when this used a number just past the end).
        int ht_bad_syscall = syscall(999, 0, 0, 0);
        print("hardentest: unrecognized syscall number ");
        print(ht_bad_syscall < 0 ? "correctly denied\n" : "WRONGLY succeeded\n");

        if (ht_null_futex < 0 && ht_bad_syscall < 0) {
            print("hardentest: ok\n");
        } else {
            print("hardentest: FAILED\n");
        }
    } else if (strcmp(cmd, "pstest") == 0) {
        // /proc: process info as files (user/procd.c3), a real Plan
        // 9 idea — reads through the exact same fs_read() every
        // fsd-backed command already uses; procd is just another
        // process answering the same FS_READ verb with synthesized
        // content instead of disk sectors. pid 2 = echod, always
        // alive, so this always has something real to read.
        char[128] ps_buf @noinit;
        int ps_len = fs_read("/proc/2/status", &ps_buf, 128);
        if (ps_len >= 0) {
            ps_buf[ps_len] = 0;
            print(&ps_buf);
        } else {
            print("pstest: failed\n");
        }
    } else if (strcmp(cmd, "lsproc") == 0) {
        // Same as ls/lssub, against /proc — proves fs_list() works
        // against a *synthetic* server exactly the same way it does
        // against a disk-backed one, the actual point of building
        // procd on top of the existing FS_READ/FS_LIST protocol
        // instead of a new one.
        char[576] proc_listbuf @noinit;
        // Trailing slash matters: ns_resolve matches by
        // str_starts_with against the mount's own "/proc/" prefix
        // (src/process.c3) — "/proc" alone (no slash) doesn't
        // contain that whole prefix, so it would silently fall
        // through to the "" catch-all (fsd) instead, and fail there
        // since "/proc" isn't a real fsd directory. Found exactly
        // this way: fsd's own -1 looked identical to procd's own
        // "not found" until traced back to which server actually
        // received the request.
        int proc_count = fs_list("/proc/", &proc_listbuf, 16);
        if (proc_count < 0) {
            print("lsproc: failed\n");
        } else {
            for (int pi = 0; pi < proc_count; pi++) {
                char* rec = &proc_listbuf[pi * 36];
                print(rec);
                if (rec[32] != 0) {
                    print("/");
                }
                print("\n");
            }
        }
    } else if (strcmp(cmd, "killtest") == 0) {
        // /proc/<pid>/ctl (procd.c3's FS_WRITE handler): the one
        // write path /proc has, and the only command it accepts is
        // "kill" — fs_write() here is the exact same generic call
        // every disk-backed write already uses, same as pstest/
        // lsproc's fs_read()/fs_list() against a synthetic server.
        //
        // Spawns a throwaway child that spins forever (plain
        // rfork(RFPROC), same as rforktest) instead of exiting on
        // its own, so there's something genuinely alive to kill —
        // real preemptive scheduling (src/entry.c3's timer path)
        // means this doesn't starve the parent while it spins.
        int kt_r = rfork(RFPROC, null);
        if (kt_r < 0) {
            print("rfork failed\n");
        } else if (kt_r == 0) {
            for (;;) {
                rfork_shared_value = rfork_shared_value + 1;
            }
        } else {
            char[16] kt_status_path @noinit;
            char[16] kt_ctl_path @noinit;
            int kt_pos = 0;
            char* kt_prefix = "/proc/";
            while (kt_prefix[kt_pos] != 0) {
                kt_status_path[kt_pos] = kt_prefix[kt_pos];
                kt_ctl_path[kt_pos] = kt_prefix[kt_pos];
                kt_pos++;
            }
            int kt_digits = fmt::format_uint((uint)kt_r, &kt_status_path[kt_pos]);
            for (int kd = 0; kd < kt_digits; kd++) {
                kt_ctl_path[kt_pos + kd] = kt_status_path[kt_pos + kd];
            }
            kt_pos += kt_digits;
            char* kt_status_suffix = "/status";
            int kt_si = 0;
            while (kt_status_suffix[kt_si] != 0) {
                kt_status_path[kt_pos + kt_si] = kt_status_suffix[kt_si];
                kt_si++;
            }
            kt_status_path[kt_pos + kt_si] = 0;
            char* kt_ctl_suffix = "/ctl";
            int kt_ci = 0;
            while (kt_ctl_suffix[kt_ci] != 0) {
                kt_ctl_path[kt_pos + kt_ci] = kt_ctl_suffix[kt_ci];
                kt_ci++;
            }
            kt_ctl_path[kt_pos + kt_ci] = 0;

            char[128] kt_buf @noinit;
            int kt_before_len = fs_read(&kt_status_path, &kt_buf, 128);
            print("killtest: child ");
            print(kt_before_len >= 0 ? "alive before kill\n" : "MISSING before kill (already wrong)\n");

            int kt_write_result = fs_write(&kt_ctl_path, "kill", 4);
            int kt_after_len = fs_read(&kt_status_path, &kt_buf, 128);
            if (kt_write_result >= 0 && kt_after_len < 0) {
                print("killtest: PASS (kill succeeded, child gone)\n");
            } else {
                print("killtest: FAILED\n");
            }

            // Edge cases: killing an already-dead pid must fail
            // cleanly (proc_by_pid finds nothing), and echod (pid
            // 2, always alive) must survive a garbage ctl command
            // unharmed — procd only ever recognizes "kill".
            int kt_double_kill = fs_write(&kt_ctl_path, "kill", 4);
            print("killtest: re-kill of dead pid ");
            print(kt_double_kill < 0 ? "correctly failed\n" : "WRONGLY succeeded\n");

            int kt_bogus_result = fs_write("/proc/2/ctl", "bogus", 5);
            int kt_echod_after = fs_read("/proc/2/status", &kt_buf, 128);
            print("killtest: bogus ctl command ");
            print(kt_bogus_result < 0 && kt_echod_after >= 0 ? "correctly rejected, echod still alive\n" : "WRONGLY accepted or echod harmed\n");
        }
    } else if (strcmp(cmd, "runtest") == 0) {
        // exec() (user.c3): replaces the calling process's own
        // image in place — the first real /bin support this
        // codebase has had. rfork(RFPROC)s a throwaway child (same
        // shape killtest/srvtest/envtest already use) that execs
        // "bin/echod" — a real, already-built binary
        // (build/user/echod.bin, known behavior, already exercised
        // at boot as pid 2), copied onto both test images by
        // scripts/build.sh specifically for this, rather than
        // writing a new one just to exec.
        //
        // Two-step handshake, not a single direct ping: this
        // child's own exec() does real IPC round trips of its own
        // (the FS_READ_AT calls to fsd, loading the new image)
        // before it ever reaches echod's real loop, and this
        // process's single inbox slot has no per-sender filtering
        // (src/syscalls.c3's SYS_IPC_RECV) — a ping sent too early can
        // land mid-round-trip and get bounced back as P9_STRAY
        // (user.c3's p9_call). A retry-with-backoff version of this
        // test tried exactly that and failed outright: fsd's own
        // round trip through diskd for a deep offset can outlast
        // any fixed backoff, so the retries just kept re-winning the
        // race against fsd's real reply forever. Fixed properly
        // instead: the child sends "sync" first (its very first
        // action, same as srvtest's own child, so this can never
        // race anything) so the parent learns its pid isn't stale;
        // the parent's reply to that carries no information the
        // child needs, just an ack. Then the child calls exec()
        // with notify_pid set to this process's own pid — exec()
        // sends exactly one more message, right after its last
        // fs_read_at() and before the point of no return, so by the
        // time the parent receives it, the child will never send
        // fsd anything again and it's genuinely safe to talk to.
        uint run_gen = 0;
        int run_r = rfork(RFPROC, &run_gen);
        if (run_r < 0) {
            print("rfork failed\n");
        } else if (run_r == 0) {
            char[16] run_sync_buf @noinit;
            int run_parent = ipc_recv(&run_sync_buf, 16);
            ipc_send(run_parent, 0, "ack", 4);
            exec("bin/echod", exec_buf(), exec_buf_max(), run_parent, null, 0);
            // exec() only ever returns on failure — success means
            // this process is now running echod's own code, not
            // this line, and exec() already sent "ready" itself
            // right before the point of no return. On failure it
            // never sent anything, so the parent (still waiting on
            // that "ready") needs an explicit word here — otherwise
            // it blocks forever on a message that will never come.
            ipc_send(run_parent, 0, "failed", 7);
            exit();
        } else {
            ipc_send(run_r, 0, "sync", 5);
            char[16] run_ack_buf @noinit;
            ipc_recv(&run_ack_buf, 16);

            char[16] run_ready_buf @noinit;
            ipc_recv(&run_ready_buf, 16);

            if (strcmp(&run_ready_buf, "ready") != 0) {
                // exec() itself failed to load the image — the
                // child already reported this and is exiting on its
                // own, nothing left to kill.
                print("runtest: FAILED (exec load failed)\n");
            } else {
                ipc_send(run_r, 0, "hi echod", 9);
                char[16] run_reply @noinit;
                int run_from = ipc_recv(&run_reply, 16);
                int run_killed = kill(run_r, run_gen);
                if (run_from == run_r && strcmp(&run_reply, "hi echod") == 0 && run_killed == 0) {
                    print("runtest: ok\n");
                } else {
                    print("runtest: FAILED\n");
                }
            }
        }
    } else if (strcmp(cmd, "runtest2") == 0) {
        // Same as runtest above, but "/mnt/fs2/bin/echod" — the second
        // mount, not the default (root) one. Exists specifically to
        // exercise mount 2 unambiguously, same reasoning fspermtest's
        // own comment explains in full — real Duo hardware no longer
        // has this ambiguity at all (root is ext2-exclusive now, see
        // this entry's own Plan9-style reorganization, docs/devlog.md),
        // but QEMU's own dual-mount image still has a real second
        // mount this needs to target on purpose, not by accident of
        // whatever happens to be default.
        uint rt2_gen = 0;
        int rt2_r = rfork(RFPROC, &rt2_gen);
        if (rt2_r < 0) {
            print("rfork failed\n");
        } else if (rt2_r == 0) {
            char[16] rt2_sync_buf @noinit;
            int rt2_parent = ipc_recv(&rt2_sync_buf, 16);
            ipc_send(rt2_parent, 0, "ack", 4);
            exec("/mnt/fs2/bin/echod", exec_buf(), exec_buf_max(), rt2_parent, null, 0);
            ipc_send(rt2_parent, 0, "failed", 7);
            exit();
        } else {
            ipc_send(rt2_r, 0, "sync", 5);
            char[16] rt2_ack_buf @noinit;
            ipc_recv(&rt2_ack_buf, 16);

            char[16] rt2_ready_buf @noinit;
            ipc_recv(&rt2_ready_buf, 16);

            if (strcmp(&rt2_ready_buf, "ready") != 0) {
                print("runtest2: FAILED (exec load failed)\n");
            } else {
                ipc_send(rt2_r, 0, "hi echod", 9);
                char[16] rt2_reply @noinit;
                int rt2_from = ipc_recv(&rt2_reply, 16);
                int rt2_killed = kill(rt2_r, rt2_gen);
                if (rt2_from == rt2_r && strcmp(&rt2_reply, "hi echod") == 0 && rt2_killed == 0) {
                    print("runtest2: ok\n");
                } else {
                    print("runtest2: FAILED\n");
                }
            }
        }
    } else if (strcmp(cmd, "elftest") == 0) {
        // Same rfork+sync+exec+"ready" handshake as runtest above
        // (see its own comment for why each step's there), except
        // this execs bin/echod.elf — a real ELF64/RISC-V executable
        // (build/user/echod.elf, racccoon's own toolchain output,
        // before objcopy strips it to the flat bin/echod runtest
        // uses), exercising SYS_EXEC's own ELF loader (src/syscalls.c3)
        // instead of the flat-binary path. Same "hi echod" echo
        // check as runtest — proving the loaded process is
        // genuinely executing (its code segment ran, its
        // .bss-resident stack worked), not just that the syscall
        // returned success.
        uint el_gen = 0;
        int el_r = rfork(RFPROC, &el_gen);
        if (el_r < 0) {
            print("rfork failed\n");
        } else if (el_r == 0) {
            char[16] el_sync_buf @noinit;
            int el_parent = ipc_recv(&el_sync_buf, 16);
            ipc_send(el_parent, 0, "ack", 4);
            exec("bin/echod.elf", exec_buf(), exec_buf_max(), el_parent, null, 0);
            ipc_send(el_parent, 0, "failed", 7);
            exit();
        } else {
            ipc_send(el_r, 0, "sync", 5);
            char[16] el_ack_buf @noinit;
            ipc_recv(&el_ack_buf, 16);

            char[16] el_ready_buf @noinit;
            ipc_recv(&el_ready_buf, 16);

            if (strcmp(&el_ready_buf, "ready") != 0) {
                print("elftest: FAILED (exec load failed)\n");
            } else {
                ipc_send(el_r, 0, "hi echod", 9);
                char[16] el_reply @noinit;
                int el_from = ipc_recv(&el_reply, 16);
                int el_killed = kill(el_r, el_gen);
                if (el_from == el_r && strcmp(&el_reply, "hi echod") == 0 && el_killed == 0) {
                    print("elftest: ok\n");
                } else {
                    print("elftest: FAILED\n");
                }
            }
        }
    } else if (strcmp(cmd, "elftest2") == 0) {
        // Same as elftest above, but "/mnt/fs2/bin/echod.elf" — see
        // runtest2's own comment for why this needs its own,
        // explicitly mount-2-targeted variant.
        uint el2_gen = 0;
        int el2_r = rfork(RFPROC, &el2_gen);
        if (el2_r < 0) {
            print("rfork failed\n");
        } else if (el2_r == 0) {
            char[16] el2_sync_buf @noinit;
            int el2_parent = ipc_recv(&el2_sync_buf, 16);
            ipc_send(el2_parent, 0, "ack", 4);
            exec("/mnt/fs2/bin/echod.elf", exec_buf(), exec_buf_max(), el2_parent, null, 0);
            ipc_send(el2_parent, 0, "failed", 7);
            exit();
        } else {
            ipc_send(el2_r, 0, "sync", 5);
            char[16] el2_ack_buf @noinit;
            ipc_recv(&el2_ack_buf, 16);

            char[16] el2_ready_buf @noinit;
            ipc_recv(&el2_ready_buf, 16);

            if (strcmp(&el2_ready_buf, "ready") != 0) {
                print("elftest2: FAILED (exec load failed)\n");
            } else {
                ipc_send(el2_r, 0, "hi echod", 9);
                char[16] el2_reply @noinit;
                int el2_from = ipc_recv(&el2_reply, 16);
                int el2_killed = kill(el2_r, el2_gen);
                if (el2_from == el2_r && strcmp(&el2_reply, "hi echod") == 0 && el2_killed == 0) {
                    print("elftest2: ok\n");
                } else {
                    print("elftest2: FAILED\n");
                }
            }
        }
    } else if (strcmp(cmd, "argvtest") == 0) {
        // Same rfork+sync+exec+ready handshake as runtest above
        // (see its own comment for why each step's there) — the
        // difference is this one execs bin/echod with one real
        // argument, then checks it actually reached the new image
        // via a P9_TREAD round trip instead of runtest's untyped
        // ping: echod's own main() (echod.c3) replaces its
        // hardcoded P9_TREAD reply with argv[0] whenever argc > 0,
        // so a matching reply is concrete, observable proof argv
        // made it across exec(), not just that exec() succeeded.
        char* av_arg = "argvtest-marker";

        uint av_gen = 0;
        int av_r = rfork(RFPROC, &av_gen);
        if (av_r < 0) {
            print("rfork failed\n");
        } else if (av_r == 0) {
            char[16] av_sync_buf @noinit;
            int av_parent = ipc_recv(&av_sync_buf, 16);
            ipc_send(av_parent, 0, "ack", 4);
            exec("bin/echod", exec_buf(), exec_buf_max(), av_parent, &av_arg, 1);
            ipc_send(av_parent, 0, "failed", 7);
            exit();
        } else {
            ipc_send(av_r, 0, "sync", 5);
            char[16] av_ack_buf @noinit;
            ipc_recv(&av_ack_buf, 16);

            char[16] av_ready_buf @noinit;
            ipc_recv(&av_ready_buf, 16);

            if (strcmp(&av_ready_buf, "ready") != 0) {
                print("argvtest: FAILED (exec load failed)\n");
            } else {
                char[64] av_reply @noinit;
                uint av_reply_verb = 0;
                int av_from = p9_call(av_r, P9_TREAD, null, 0, &av_reply, 64, &av_reply_verb);
                int av_killed = kill(av_r, av_gen);
                if (av_from == av_r && av_reply_verb == P9_TREAD && strcmp(&av_reply, av_arg) == 0 && av_killed == 0) {
                    print("argvtest: ok\n");
                } else {
                    print("argvtest: FAILED\n");
                }
            }
        }
    } else if (strcmp(cmd, "argvtest2") == 0) {
        // Same as argvtest above, but "/mnt/fs2/bin/echod" — see
        // runtest2's own comment for why this needs its own,
        // explicitly mount-2-targeted variant.
        char* av2_arg = "argvtest2-marker";

        uint av2_gen = 0;
        int av2_r = rfork(RFPROC, &av2_gen);
        if (av2_r < 0) {
            print("rfork failed\n");
        } else if (av2_r == 0) {
            char[16] av2_sync_buf @noinit;
            int av2_parent = ipc_recv(&av2_sync_buf, 16);
            ipc_send(av2_parent, 0, "ack", 4);
            exec("/mnt/fs2/bin/echod", exec_buf(), exec_buf_max(), av2_parent, &av2_arg, 1);
            ipc_send(av2_parent, 0, "failed", 7);
            exit();
        } else {
            ipc_send(av2_r, 0, "sync", 5);
            char[16] av2_ack_buf @noinit;
            ipc_recv(&av2_ack_buf, 16);

            char[16] av2_ready_buf @noinit;
            ipc_recv(&av2_ready_buf, 16);

            if (strcmp(&av2_ready_buf, "ready") != 0) {
                print("argvtest2: FAILED (exec load failed)\n");
            } else {
                char[64] av2_reply @noinit;
                uint av2_reply_verb = 0;
                int av2_from = p9_call(av2_r, P9_TREAD, null, 0, &av2_reply, 64, &av2_reply_verb);
                int av2_killed = kill(av2_r, av2_gen);
                if (av2_from == av2_r && av2_reply_verb == P9_TREAD && strcmp(&av2_reply, av2_arg) == 0 && av2_killed == 0) {
                    print("argvtest2: ok\n");
                } else {
                    print("argvtest2: FAILED\n");
                }
            }
        }
    } else if (strcmp(cmd, "pathtest") == 0) {
        // exec_path() (user.c3): resolves a bare name ("echod")
        // against /env/PATH — a real $PATH-style search list —
        // instead of exec()'s own exact-path requirement. Sets
        // /env/PATH to a search list with a deliberately WRONG
        // first prefix ("nonexistent/:bin/") before rfork(), so the
        // child inherits it (same lazy-inheritance envtest already
        // proved works) — success here is only possible if
        // exec_path() genuinely tried the first prefix, failed, and
        // moved to the second, not just that the (correct-by-
        // default) fallback still works. Same rfork+sync+exec+
        // "ready" handshake runtest/argvtest already established.
        fs_write("/env/PATH", "nonexistent/:bin/", 17);

        uint pt_gen = 0;
        int pt_r = rfork(RFPROC, &pt_gen);
        if (pt_r < 0) {
            print("rfork failed\n");
        } else if (pt_r == 0) {
            char[16] pt_sync_buf @noinit;
            int pt_parent = ipc_recv(&pt_sync_buf, 16);
            ipc_send(pt_parent, 0, "ack", 4);
            exec_path("echod", exec_buf(), exec_buf_max(), pt_parent, null, 0);
            ipc_send(pt_parent, 0, "failed", 7);
            exit();
        } else {
            ipc_send(pt_r, 0, "sync", 5);
            char[16] pt_ack_buf @noinit;
            ipc_recv(&pt_ack_buf, 16);

            char[16] pt_ready_buf @noinit;
            ipc_recv(&pt_ready_buf, 16);

            fs_delete("/env/PATH");

            if (strcmp(&pt_ready_buf, "ready") != 0) {
                print("pathtest: FAILED (exec load failed)\n");
            } else {
                ipc_send(pt_r, 0, "hi echod", 9);
                char[16] pt_reply @noinit;
                int pt_from = ipc_recv(&pt_reply, 16);
                int pt_killed = kill(pt_r, pt_gen);
                if (pt_from == pt_r && strcmp(&pt_reply, "hi echod") == 0 && pt_killed == 0) {
                    print("pathtest: ok\n");
                } else {
                    print("pathtest: FAILED\n");
                }
            }
        }
    } else if (strcmp(cmd, "pathtest2") == 0) {
        // Same as pathtest above, but every /env/PATH segment
        // "/mnt/fs2/"-prefixed, so exec_path() builds candidates against
        // mount 2 specifically ("/mnt/fs2/nonexistent/echod" then
        // "/mnt/fs2/bin/echod") — see runtest2's own comment for why
        // this needs its own, explicitly mount-2-targeted variant.
        fs_write("/env/PATH", "/mnt/fs2/nonexistent/:/mnt/fs2/bin/", 35);

        uint pt2_gen = 0;
        int pt2_r = rfork(RFPROC, &pt2_gen);
        if (pt2_r < 0) {
            print("rfork failed\n");
        } else if (pt2_r == 0) {
            char[16] pt2_sync_buf @noinit;
            int pt2_parent = ipc_recv(&pt2_sync_buf, 16);
            ipc_send(pt2_parent, 0, "ack", 4);
            exec_path("echod", exec_buf(), exec_buf_max(), pt2_parent, null, 0);
            ipc_send(pt2_parent, 0, "failed", 7);
            exit();
        } else {
            ipc_send(pt2_r, 0, "sync", 5);
            char[16] pt2_ack_buf @noinit;
            ipc_recv(&pt2_ack_buf, 16);

            char[16] pt2_ready_buf @noinit;
            ipc_recv(&pt2_ready_buf, 16);

            fs_delete("/env/PATH");

            if (strcmp(&pt2_ready_buf, "ready") != 0) {
                print("pathtest2: FAILED (exec load failed)\n");
            } else {
                ipc_send(pt2_r, 0, "hi echod", 9);
                char[16] pt2_reply @noinit;
                int pt2_from = ipc_recv(&pt2_reply, 16);
                int pt2_killed = kill(pt2_r, pt2_gen);
                if (pt2_from == pt2_r && strcmp(&pt2_reply, "hi echod") == 0 && pt2_killed == 0) {
                    print("pathtest2: ok\n");
                } else {
                    print("pathtest2: FAILED\n");
                }
            }
        }
    } else if (strcmp(cmd, "maptest") == 0) {
        // SYS_MAP: fresh zero-filled RW pages past the image, bumping.
        char* mp1 = (char*)map_pages(100);      // -> 1 page
        char* mp2 = (char*)map_pages(9000);     // -> 3 pages, right after
        bool mp_zero = mp1 != null && mp1[0] == 0 && mp1[4095] == 0;
        bool mp_bump = mp1 != null && mp2 != null && mp2 == mp1 + 4096;
        if (mp1 != null) { mp1[0] = 'A'; mp1[4095] = 'Z'; }
        bool mp_rw = mp1 != null && mp1[0] == 'A' && mp1[4095] == 'Z';
        // child gets its own fresh heap_top (its own address space)
        uint mt_gen = 0;
        int mt_c = rfork(RFPROC, &mt_gen);
        if (mt_c == 0) {
            char* cmp = (char*)map_pages(4096);
            exitcode(cmp != null && cmp[0] == 0 ? 7 : 1);
        }
        int mt_code = join(mt_c, mt_gen);
        if (mp_zero && mp_bump && mp_rw && mt_code == 7) {
            print("maptest: ok\n");
        } else {
            print("maptest: FAILED zero="); print_uint((uint)mp_zero);
            print(" bump="); print_uint((uint)mp_bump);
            print(" rw="); print_uint((uint)mp_rw);
            print(" child="); print_uint((uint)mt_code); putchar('\n');
        }
    } else if (strcmp(cmd, "oomtest") == 0) {
        // Lazy SYS_MAP (docs/devlog.md): a map only reserves address
        // space; real pages are demand-faulted on first touch, and
        // running out of RAM there kills just the faulting process —
        // never a kernel panic. Fork "glutton" children that each map
        // AND write every page of their full per-process ceiling
        // (16 MiB Duo / 512 MiB QEMU). Two gluttons overcommit any
        // board's pool, so at least one is OOM-killed mid-touch
        // (join returns -1) or rfork() refuses to start one. Confirm:
        // no panic, real pressure, and once the dead gluttons are
        // reaped the RAM comes back (a fresh 1 MiB glutton survives).
        const int OOM_KIDS = 8;
        int[OOM_KIDS] oom_pid;
        uint[OOM_KIDS] oom_gen;
        int oom_spawned = 0;
        bool oom_rfork_refused = false;
        for (int oi = 0; oi < OOM_KIDS; oi++) {
            uint g = 0;
            int c = rfork(RFPROC, &g);
            if (c < 0) { oom_rfork_refused = true; break; }
            if (c == 0) {
                // Reserve to the ceiling a cluster at a time, writing
                // one byte per page so the RAM is really committed,
                // then park holding it. A fault in the touch loop
                // (out of memory) kills just this child — fine.
                for (int oom_k = 0; oom_k < 8192; oom_k++) {
                    char* oom_p = (char*)map_pages(262144); // 256 KiB
                    if (oom_p == null) break;               // hit the ceiling
                    for (int oom_q = 0; oom_q < 262144; oom_q += 4096) { oom_p[oom_q] = (char)1; }
                }
                for (;;) { yield(); }
            }
            oom_pid[oom_spawned] = c;
            oom_gen[oom_spawned] = g;
            oom_spawned++;
        }
        // Let the gluttons commit their pages.
        ulong oom_settle = rdtime() + timebase_hz();
        while (rdtime() < oom_settle) { yield(); }
        // Pressure probe: one more child that maps + touches its full
        // ceiling. With the gluttons holding the pool it can't get its
        // pages — it faults and the kernel OOM-kills it (join != 7),
        // or rfork() already refused to start it. Either way: no panic.
        bool oom_probe_killed = false;
        uint oom_pg = 0;
        int oom_probe = rfork(RFPROC, &oom_pg);
        if (oom_probe < 0) {
            oom_rfork_refused = true;
        } else if (oom_probe == 0) {
            for (int oom_k = 0; oom_k < 8192; oom_k++) {
                char* oom_p = (char*)map_pages(262144);
                if (oom_p == null) break;
                for (int oom_q = 0; oom_q < 262144; oom_q += 4096) { oom_p[oom_q] = (char)1; }
            }
            exitcode(7);
        } else {
            if (join(oom_probe, oom_pg) != 7) { oom_probe_killed = true; }
        }
        // A glutton that's already gone was OOM-killed mid-touch — the
        // pressure the comment above promises. Counted on its own: with
        // the 64-slot table every glutton gets a slot, so once they've
        // all died and handed their RAM back the probe can succeed (the
        // old 16-slot table refused an rfork first and hid that).
        bool oom_glutton_killed = false;
        for (int oi = 0; oi < oom_spawned; oi++) {
            uint kg = 0;
            if (proc_info(oom_pid[oi], null, &kg, null) != 0 || kg != oom_gen[oi]) { oom_glutton_killed = true; }
        }
        // Reap the gluttons and confirm RAM comes back.
        for (int oi = 0; oi < oom_spawned; oi++) { kill(oom_pid[oi], oom_gen[oi]); }
        ulong oom_recover = rdtime() + timebase_hz() * 3;
        int oom_after_code = -1;
        while (oom_after_code != 7 && rdtime() < oom_recover) {
            yield();
            uint rg = 0;
            int rc = rfork(RFPROC, &rg);
            if (rc == 0) {
                char* rp = (char*)map_pages(1048576);
                bool oom_rec_ok = rp != null;
                if (oom_rec_ok) {
                    for (int oom_i = 0; oom_i < 1048576; oom_i += 4096) { rp[oom_i] = (char)2; }
                    rp[1048575] = (char)3;
                }
                exitcode(oom_rec_ok ? 7 : 1);
            }
            if (rc > 0) { oom_after_code = join(rc, rg); }
        }
        bool oom_pressure = oom_rfork_refused || oom_probe_killed || oom_glutton_killed;
        if (oom_spawned > 0 && oom_pressure && oom_after_code == 7) {
            print("oomtest: ok (demand-fault OOM kills the process, no panic, RAM recovered)\n");
        } else {
            print("oomtest: FAILED spawned="); print_uint((uint)oom_spawned);
            print(" pressure="); print_uint((uint)oom_pressure);
            print(" recovered="); print_uint((uint)(oom_after_code == 7));
            putchar('\n');
        }
    } else if (strcmp(cmd, "faulttest") == 0) {
        // A user-mode fault (bad pointer, illegal instruction) kills
        // just that process — the kernel prints "user fault: … —
        // killing the process" and carries on. Without the fix this
        // was panic("it's a trap!"), i.e. the whole system down.
        uint ft_gen = 0;
        int ft_c = rfork(RFPROC, &ft_gen);
        if (ft_c < 0) {
            print("faulttest: rfork failed\n");
        } else if (ft_c == 0) {
            // Store to a wild address — nothing is mapped at 3 GiB
            // in a user page table. Store page fault (scause 15).
            char* wild = (char*)0xC0000000;
            wild[0] = (char)1;
            exitcode(0); // unreachable — the fault kills us first
        } else {
            int ft_code = join(ft_c, ft_gen);
            // proc_destroy records -1 for a killed process; the
            // shell just needs a non-zero (failed) code and to
            // still be alive to run the next command.
            char[8] ft_probe @noinit;
            // shell still works? On a board with a filesystem, re-read
            // a known file. On a no-fs board (the sifive_u opi
            // harness) fs_read is always -1, so a plain syscall
            // round-trip stands in — either way this only has to show
            // the shell survived the child's fault and can still run.
            int ft_alive = fs_read("bin/echod", &ft_probe, 8);
            bool ft_shell_ok = (ft_alive >= 0) || (getuid() >= 0);
            if (ft_code != 0 && ft_shell_ok) {
                print("faulttest: ok (faulting child killed, kernel + shell fine)\n");
            } else {
                print("faulttest: FAILED code="); print_uint((uint)ft_code);
                print(" alive="); print_uint((uint)ft_shell_ok); putchar('\n');
            }
        }
    } else if (strcmp(cmd, "fputest") == 0) {
        // Hardware FPU (roadmap §3): prove f-registers survive a
        // context switch and a fork. No %f in the print path — scale
        // to an integer and show N.mmm by hand.
        double fp_x = 1.0;
        for (int fi = 0; fi < 10; fi++) { fp_x = fp_x * 1.1; }   // 1.1^10 ≈ 2.5937
        long fp_xs = (long)(fp_x * 1000.0 + 0.5);

        // Fork a child that hammers float math (and blocks on IPC, so
        // the scheduler switches back and forth) while the parent
        // holds a live double in a register across the whole thing.
        double fp_guard = 1234.5;
        uint fpc_gen = 0;
        int fpc = rfork(RFPROC, &fpc_gen);
        if (fpc == 0) {
            char[8] fp_sync @noinit;
            int fp_pp = ipc_recv(&fp_sync, 8);
            double fp_c = 2.0;
            for (int fj = 0; fj < 20; fj++) { fp_c = fp_c / 1.5 + 0.25; }
            long fp_cs = (long)(fp_c * 1000.0 + 0.5);
            // child's own fp_guard-equivalent, inherited from parent
            bool fp_inh = (long)(fp_guard * 10.0 + 0.5) == 12345;
            ipc_send(fp_pp, 0, fp_inh ? "y" : "n", 2);
            // hand the child's result back as a small int in the pid
            exitcode((int)(fp_cs % 100));
        } else if (fpc > 0) {
            ipc_send(fpc, 0, "go", 3);
            char[8] fp_ack @noinit;
            ipc_recv(&fp_ack, 8);
            int fp_child_code = join(fpc, fpc_gen);   // child result: (long)(0.75*1000) % 100 = 50
            // Parent's live double must be untouched by the child's
            // float work + the two context switches.
            bool fp_guard_ok = (long)(fp_guard * 10.0 + 0.5) == 12345;
            bool fp_child_inh = strcmp(&fp_ack, "y") == 0;
            double fp_after = fp_x + fp_guard;   // more float, post-fork
            long fp_afters = (long)(fp_after * 100.0 + 0.5);   // ~123709
            if (fp_xs == 2594 && fp_guard_ok && fp_child_inh
                && fp_afters == 123709 && fp_child_code == 50) {
                print("fputest: ok (1.1^10=");
                print_uint((uint)(fp_xs / 1000)); putchar('.');
                print_uint((uint)(fp_xs % 1000));
                print(", guard held across fork+switch)\n");
            } else {
                print("fputest: FAILED xs="); print_uint((uint)fp_xs);
                print(" guard="); print_uint((uint)fp_guard_ok);
                print(" inh="); print_uint((uint)fp_child_inh);
                print(" after="); print_uint((uint)fp_afters);
                print(" ccode="); print_uint((uint)fp_child_code);
                putchar('\n');
            }
        } else {
            print("fputest: FAILED (rfork)\n");
        }
    } else if (strcmp(cmd, "notetest") == 0) {
        note_test();
    } else if (strcmp(cmd, "segtest") == 0) {
        seg_test();
    } else if (strcmp(cmd, "proclimittest") == 0) {
        proclimit_test();
    } else if (strcmp(cmd, "rforktest") == 0) {
        // Plain rfork(RFPROC): the child gets an independent copy of
        // this process's address space (src/syscalls.c3's SYS_RFORK,
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
    } else if (strcmp(cmd, "sandboxtest") == 0) {
        // Plain rfork(RFPROC) — a real, independent copy, so this
        // has none of raw RFMEM's shared-stack hazard (see
        // threadcreate's own comment, user.c3, for why a bare
        // rfork(RFPROC|RFMEM) is unsafe to use directly: the child
        // shares the live parent stack for its entire remaining
        // lifetime, not just the instant it resumes — an earlier,
        // now-removed version of a hand-rolled RFMEM demo command
        // genuinely paged-faulted the kernel once, under real
        // timing, once the parent's own subsequent activity reused
        // stack memory the child's own spilled return addresses
        // still depended on; see docs/devlog.md). The child
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
        // rfork(RFPROC|RFMEM). Unlike a bare RFMEM fork, this is
        // safe to use normally: the thread gets its own real stack
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
        // threadcreate() can fail (no free process slot — see
        // process.c3's PROCS_MAX comment for a real case this caught:
        // a silent -1 here used to masquerade as "corrupted or lost"
        // below, since join() on a pid that was never created returns
        // immediately and race_ok_a/b are left at their reset value).
        // Reported distinctly so a future PROCS_MAX-exhaustion regression
        // is never confused with an actual IPC/rendezvous bug again.
        if (tid_a < 0 || tid_b < 0) {
            print("racetest: threadcreate failed (no free process slot) — inconclusive\n");
        } else {
            join(tid_a, gen_a);
            join(tid_b, gen_b);
            print("racetest: a=");
            putchar((char)('0' + race_ok_a));
            print(" b=");
            putchar((char)('0' + race_ok_b));
            print(" (1=correct reply, 0=corrupted or lost)\n");
        }
    } else if (strcmp(cmd, "mutextest") == 0) {
        mutex_test_counter = 0;
        mutex_test_lock.locked.store(0);
        char* mstack_a_top = (char*)&mutex_stack_a + mutex_stack_a.len;
        char* mstack_b_top = (char*)&mutex_stack_b + mutex_stack_b.len;
        uint mgen_a = 0;
        uint mgen_b = 0;
        int mtid_a = threadcreate(&mutex_thread_body, null, mstack_a_top, &mgen_a);
        int mtid_b = threadcreate(&mutex_thread_body, null, mstack_b_top, &mgen_b);
        if (mtid_a < 0 || mtid_b < 0) {
            print("mutextest: threadcreate failed (no free process slot) — inconclusive\n");
        } else {
            join(mtid_a, mgen_a);
            join(mtid_b, mgen_b);
            print("mutextest: counter = ");
            print_uint((uint)mutex_test_counter);
            print(" (expected ");
            print_uint((uint)(MUTEX_TEST_ITERS * 2));
            print(")\n");
        }
    } else {
        return false;
    }
    return true;
}
