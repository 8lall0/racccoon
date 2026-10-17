module user;

import std::nolibc::fmt;

// shell_test builtins — IPC, 9P and the namespace: echod/p9 round trips,
// srv/ns/env, IPC-death and hung-server handling. Split out of
// shell_test.c3's main(), which tries each shell_test_*_dispatch in
// turn; true = cmd was one of these.

// ringbench's read/write buffer — a global for the same stack-budget
// reason bigread_buf above is one (the shell's own stack can't hold an
// 8 KiB frame-local on top of everything else a builtin nests).
char[8192] ringbench_buf;

// ringbench (below) prints per-operation counters as X.YY without a
// float in sight: total * 100 / iters, then split.
fn void ringbench_perop(ulong total, ulong iters) {
    ulong h = iters > 0 ? (total * 100) / iters : 0;
    print_uint((uint)(h / 100));
    putchar('.');
    uint frac = (uint)(h % 100);
    if (frac < 10) { putchar('0'); }
    print_uint(frac);
}

fn bool shell_test_ipc_dispatch(char* cmd, char** cmd_argv, int cmd_argc) {
    if (strcmp(cmd, "ping") == 0) {
        // Resolved through the namespace now — "/srv/echo/" is where
        // echod is named (src/process.c3's default mount table),
        // finally landing on the "real name -> pid lookup" this
        // command's own comment used to say was still just a
        // placeholder.
        int echo_pid = ns_resolve("/srv/echo/", null);
        ipc_send(echo_pid, 0, "hello echod", 12);
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
        // No hardcoded pid: "/srv/echo/some/path" is resolved through
        // this process's own namespace (src/process.c3's default
        // mount table, "/srv/echo/" -> echod) to find the server,
        // over the 9P-lite verbs (user.c3's p9_call_path).
        char[64] reply @noinit;
        uint reply_verb = 0;

        int from_walk = p9_call_path("/srv/echo/some/path", P9_TWALK, "some/path", 10, &reply, 64, &reply_verb);
        if (from_walk > 0 && reply_verb == P9_TWALK) {
            print("walk ack: ");
            print(&reply);
            print("\n");
        } else {
            print("walk failed\n");
        }

        int from_read = p9_call_path("/srv/echo/", P9_TREAD, null, 0, &reply, 64, &reply_verb);
        if (from_read > 0 && reply_verb == P9_TREAD) {
            print("read: ");
            print(&reply);
        } else {
            print("read failed\n");
        }
    } else if (strcmp(cmd, "p9realtest") == 0) {
        // Real 9P semantics against echod's own sandbox (see
        // user/echod.c3) — genuine FIDs, a real walk-by-name, real
        // offset-based reads, not p9test's own toy P9_TWALK/P9_TREAD
        // pair above (kept completely unchanged — ping/runtest/
        // argvtest all still depend on that exact behavior). Not
        // hardcoding echod's own pid, same reasoning p9test already
        // established — resolved through this process's own
        // namespace instead.
        int p9r_pid = ns_resolve("/srv/echo/", null);
        char[40] p9r_buf @noinit;

        int p9r_attach = p9_attach(p9r_pid, 1); // fid 1 = root

        int p9r_walk1 = p9_walk(p9r_pid, 1, 2, "hello"); // fid 2 = "hello"
        int p9r_open1 = p9_open(p9r_pid, 2);
        int p9r_read1 = p9_read(p9r_pid, 2, 0, 32, &p9r_buf);
        p9r_buf[p9r_read1 >= 0 ? p9r_read1 : 0] = 0;
        bool p9r_read1_ok = p9r_read1 == 20 && strcmp(&p9r_buf, "hello from real 9p\n") == 0;

        // A genuine mid-string offset read — not just "always from
        // position 0", the exact thing the old P9_TREAD could never
        // do (it ignores offset entirely).
        int p9r_read2 = p9_read(p9r_pid, 2, 6, 10, &p9r_buf);
        p9r_buf[p9r_read2 >= 0 ? p9r_read2 : 0] = 0;
        bool p9r_read2_ok = p9r_read2 == 10 && strcmp(&p9r_buf, "from real ") == 0;

        int p9r_clunk1 = p9_clunk(p9r_pid, 2);

        int p9r_walk_bad = p9_walk(p9r_pid, 1, 3, "nope"); // must fail — no such name

        int p9r_walk2 = p9_walk(p9r_pid, 1, 4, "motd"); // fid 4 = "motd" — a second, independently reachable node
        int p9r_open2 = p9_open(p9r_pid, 4);
        int p9r_read3 = p9_read(p9r_pid, 4, 0, 40, &p9r_buf);
        p9r_buf[p9r_read3 >= 0 ? p9r_read3 : 0] = 0;
        bool p9r_read3_ok = p9r_read3 == 38 && strcmp(&p9r_buf, "welcome to racccoon's own 9p sandbox\n") == 0;
        int p9r_clunk2 = p9_clunk(p9r_pid, 4);

        // Real, genuinely hierarchical walk — root -> docs ->
        // readme, two separate single-element P9_WALK calls
        // composed, exactly how real 9P's own Twalk descends. docs
        // (fid 5) is a directory: opening it directly must fail.
        int p9r_walk_docs = p9_walk(p9r_pid, 1, 5, "docs");
        int p9r_open_docs = p9_open(p9r_pid, 5); // must FAIL — docs is a directory
        int p9r_walk_readme = p9_walk(p9r_pid, 5, 6, "readme"); // walked FROM docs, not root
        int p9r_open_readme = p9_open(p9r_pid, 6);
        int p9r_read_readme = p9_read(p9r_pid, 6, 0, 40, &p9r_buf);
        p9r_buf[p9r_read_readme >= 0 ? p9r_read_readme : 0] = 0;
        bool p9r_read_readme_ok = p9r_read_readme == 32 && strcmp(&p9r_buf, "real 9p, genuinely hierarchical\n") == 0;
        int p9r_clunk_readme = p9_clunk(p9r_pid, 6);
        int p9r_clunk_docs = p9_clunk(p9r_pid, 5);

        int p9r_clunk_root = p9_clunk(p9r_pid, 1);

        if (p9r_attach == 0 && p9r_walk1 == 0 && p9r_open1 == 0 && p9r_read1_ok
            && p9r_read2_ok && p9r_clunk1 == 0 && p9r_walk_bad < 0
            && p9r_walk2 == 0 && p9r_open2 == 0 && p9r_read3_ok
            && p9r_clunk2 == 0
            && p9r_walk_docs == 0 && p9r_open_docs < 0 && p9r_walk_readme == 0
            && p9r_open_readme == 0 && p9r_read_readme_ok && p9r_clunk_readme == 0
            && p9r_clunk_docs == 0
            && p9r_clunk_root == 0) {
            print("p9realtest: ok\n");
        } else {
            print("p9realtest: FAILED\n");
        }
    } else if (strcmp(cmd, "p9fstest") == 0) {
        // Same real 9P verbs as p9realtest above, this time against
        // fsd — the real file server, backed by real ext2 data, not
        // a synthetic tree (see docs/devlog.md). No new client
        // functions needed: p9_attach/p9_walk/p9_open/p9_read/
        // p9_clunk already work against any pid, the actual point
        // of building the protocol generically against echod's own
        // sandbox first. Read-only, ext2 only — fails cleanly
        // (every call returns -1) on a FAT32-only mount, confirmed
        // separately, not part of this test's own ok/FAILED check.
        int p9f_pid = ns_resolve("", null);
        char[40] p9f_buf @noinit;

        int p9f_attach = p9_attach(p9f_pid, 1); // fid 1 = ext2 root inode

        int p9f_walk_hello = p9_walk(p9f_pid, 1, 2, "hello.txt"); // fid 2, a real root-level fixture
        int p9f_open_hello = p9_open(p9f_pid, 2);
        int p9f_read_hello = p9_read(p9f_pid, 2, 0, 32, &p9f_buf);
        p9f_buf[p9f_read_hello >= 0 ? p9f_read_hello : 0] = 0;
        bool p9f_read_hello_ok = p9f_read_hello == 17 && strcmp(&p9f_buf, "Hello from ext2!\n") == 0;
        int p9f_clunk_hello = p9_clunk(p9f_pid, 2);

        int p9f_walk_subdir = p9_walk(p9f_pid, 1, 3, "subdir"); // fid 3, a real directory
        int p9f_open_subdir = p9_open(p9f_pid, 3); // must FAIL — subdir is a directory
        int p9f_walk_nested = p9_walk(p9f_pid, 3, 4, "nested.txt"); // fid 4, walked FROM subdir (fid 3), not root
        int p9f_open_nested = p9_open(p9f_pid, 4);
        int p9f_read_nested = p9_read(p9f_pid, 4, 0, 40, &p9f_buf);
        p9f_buf[p9f_read_nested >= 0 ? p9f_read_nested : 0] = 0;
        bool p9f_read_nested_ok = p9f_read_nested == 32 && strcmp(&p9f_buf, "Hello from an ext2 subdirectory!") == 0;
        int p9f_clunk_nested = p9_clunk(p9f_pid, 4);
        int p9f_clunk_subdir = p9_clunk(p9f_pid, 3);

        int p9f_walk_bad = p9_walk(p9f_pid, 1, 5, "nope.txt"); // must fail — no such file

        int p9f_clunk_root = p9_clunk(p9f_pid, 1);

        if (p9f_attach == 0 && p9f_walk_hello == 0 && p9f_open_hello == 0 && p9f_read_hello_ok
            && p9f_clunk_hello == 0
            && p9f_walk_subdir == 0 && p9f_open_subdir < 0 && p9f_walk_nested == 0
            && p9f_open_nested == 0 && p9f_read_nested_ok && p9f_clunk_nested == 0
            && p9f_clunk_subdir == 0
            && p9f_walk_bad < 0 && p9f_clunk_root == 0) {
            print("p9fstest: ok\n");
        } else {
            print("p9fstest: FAILED\n");
        }
    } else if (strcmp(cmd, "p9fswritetest") == 0) {
        // Follow-up to p9fstest above: real writes against fsd
        // (Tcreate, Tremove full, genuine offset-aware Twrite —
        // see docs/devlog.md). Exercises create-then-immediately-
        // write-then-read, a mid-file overwrite, an append that
        // grows the file, the no-holes rejection, and the
        // dangling-fid safety check with two real, independently-
        // attached fids on the same inode.
        int p9w_pid = ns_resolve("", null);
        char[40] p9w_buf @noinit;

        int p9w_attach1 = p9_attach(p9w_pid, 1); // fid 1 = root

        int p9w_walk_missing = p9_walk(p9w_pid, 1, 2, "p9wtest.txt"); // must fail — doesn't exist yet

        int p9w_create = p9_create(p9w_pid, 1, "p9wtest.txt", 0); // fid 1 transforms into the new (already-open) file

        int p9w_write = p9_write(p9w_pid, 1, 0, "hello from real 9p write\n", 26);

        int p9w_read = p9_read(p9w_pid, 1, 0, 40, &p9w_buf);
        p9w_buf[p9w_read >= 0 ? p9w_read : 0] = 0;
        bool p9w_read_ok = p9w_read == 26 && strcmp(&p9w_buf, "hello from real 9p write\n") == 0;

        // Mid-file overwrite: the on-disk content is actually 26
        // bytes ("hello from real 9p write\n" is 25 real
        // characters — the c3 string literal's own trailing null
        // made it into the file too, since the write above passed
        // len 26; harmless, both reads/strcmp below still line up
        // exactly on it). Byte 6 is where "from " starts.
        int p9w_write2 = p9_write(p9w_pid, 1, 6, "THERE", 5);

        int p9w_read2 = p9_read(p9w_pid, 1, 0, 40, &p9w_buf);
        p9w_buf[p9w_read2 >= 0 ? p9w_read2 : 0] = 0;
        bool p9w_read2_ok = p9w_read2 == 26 && strcmp(&p9w_buf, "hello THEREreal 9p write\n") == 0;

        // Append exactly at the current end (26 bytes) — grows the
        // file to 32. The stray trailing-null byte from the
        // original write (see above) now sits mid-buffer at index
        // 25, which would make a plain strcmp stop early — so this
        // check compares real byte ranges directly instead: [0,25)
        // against the unchanged head, then [26,32) against the
        // newly appended tail.
        int p9w_write3 = p9_write(p9w_pid, 1, 26, " more\n", 6);

        int p9w_read3 = p9_read(p9w_pid, 1, 0, 40, &p9w_buf);
        bool p9w_read3_ok = p9w_read3 == 32;
        if (p9w_read3_ok) {
            char* p9w_head = "hello THEREreal 9p write\n";
            for (int p9w_i = 0; p9w_i < 25; p9w_i++) {
                if (p9w_buf[p9w_i] != p9w_head[p9w_i]) { p9w_read3_ok = false; break; }
            }
            char* p9w_tail = " more\n";
            for (int p9w_j = 0; p9w_j < 6; p9w_j++) {
                if (p9w_buf[26 + p9w_j] != p9w_tail[p9w_j]) { p9w_read3_ok = false; break; }
            }
        }

        int p9w_write_gap = p9_write(p9w_pid, 1, 100, "gap", 3); // offset far past the (now 32-byte) end — must fail, no holes

        int p9w_attach2 = p9_attach(p9w_pid, 2); // fid 2 = root, independently
        int p9w_walk2 = p9_walk(p9w_pid, 2, 3, "p9wtest.txt"); // fid 3, a second fid on the same inode
        int p9w_open3 = p9_open(p9w_pid, 3);

        int p9w_remove_dangling = p9_remove(p9w_pid, 1); // must FAIL — fid 3 still has it open
        int p9w_clunk3 = p9_clunk(p9w_pid, 3);
        int p9w_remove_ok = p9_remove(p9w_pid, 1); // now succeeds — fid 1 consumed either way
        int p9w_clunk2 = p9_clunk(p9w_pid, 2);

        if (p9w_attach1 == 0 && p9w_walk_missing < 0 && p9w_create == 0
            && p9w_write == 26 && p9w_read_ok
            && p9w_write2 == 5 && p9w_read2_ok
            && p9w_write3 == 6 && p9w_read3_ok
            && p9w_write_gap < 0
            && p9w_attach2 == 0 && p9w_walk2 == 0 && p9w_open3 == 0
            && p9w_remove_dangling < 0 && p9w_clunk3 == 0
            && p9w_remove_ok == 0 && p9w_clunk2 == 0) {
            print("p9fswritetest: ok\n");
        } else {
            print("p9fswritetest: FAILED\n");
        }
    } else if (strcmp(cmd, "p9mkdirtest") == 0) {
        // mkdir via real 9P (P9_CREATE's perm gaining P9_DMDIR —
        // see docs/devlog.md): creates a real directory through a
        // fid, walks into it independently (proving it's a real
        // directory entry, not just local fid state), creates and
        // writes a file inside it, then exercises P9_REMOVE's
        // existing non-empty-directory refusal and eventual
        // success — all of that reused unchanged from
        // ext2_delete_resolved (entry 59), since it already
        // branches on a directory's own mode regardless of
        // whether the directory was made via a path (ext2_mkdir)
        // or, as here, a fid.
        int p9m_pid = ns_resolve("", null);
        char[32] p9m_buf @noinit;

        int p9m_attach1 = p9_attach(p9m_pid, 1); // fid 1 = root
        int p9m_mkdir = p9_create(p9m_pid, 1, "p9dirtest", P9_DMDIR); // fid 1 transforms into the new dir, NOT opened

        int p9m_attach2 = p9_attach(p9m_pid, 2); // fid 2 = root, independently
        int p9m_walk = p9_walk(p9m_pid, 2, 3, "p9dirtest"); // fid 3 — walks the SAME entry from scratch

        int p9m_create_inner = p9_create(p9m_pid, 3, "inner.txt", 0); // fid 3 transforms into "p9dirtest/inner.txt", already open
        int p9m_write_inner = p9_write(p9m_pid, 3, 0, "nested content\n", 15);
        int p9m_read_inner = p9_read(p9m_pid, 3, 0, 32, &p9m_buf);
        p9m_buf[p9m_read_inner >= 0 ? p9m_read_inner : 0] = 0;
        bool p9m_read_inner_ok = p9m_read_inner == 15 && strcmp(&p9m_buf, "nested content\n") == 0;

        // Matches real Tremove's own contract (entry 59): a
        // genuine removal attempt consumes the fid regardless of
        // whether it actually succeeds — so fid 1 is gone after
        // this next call even though it fails. The final
        // successful removal below needs a fresh fid on the same
        // directory, walked again from fid 2.
        int p9m_remove_nonempty = p9_remove(p9m_pid, 1); // must FAIL — p9dirtest still has inner.txt in it
        int p9m_remove_inner = p9_remove(p9m_pid, 3); // removes inner.txt

        int p9m_walk2 = p9_walk(p9m_pid, 2, 4, "p9dirtest"); // fid 4 — a fresh reference to the same directory
        int p9m_remove_dir = p9_remove(p9m_pid, 4); // now succeeds — p9dirtest is empty

        int p9m_clunk2 = p9_clunk(p9m_pid, 2);

        if (p9m_attach1 == 0 && p9m_mkdir == 0
            && p9m_attach2 == 0 && p9m_walk == 0
            && p9m_create_inner == 0 && p9m_write_inner == 15 && p9m_read_inner_ok
            && p9m_remove_nonempty < 0 && p9m_remove_inner == 0
            && p9m_walk2 == 0 && p9m_remove_dir == 0
            && p9m_clunk2 == 0) {
            print("p9mkdirtest: ok\n");
        } else {
            print("p9mkdirtest: FAILED\n");
        }
    } else if (strcmp(cmd, "ringbench") == 0) {
        // P0 of the IPC-rings work (docs/ipc-rings.md): the number the
        // ring data-plane has to beat — the current client->fsd read
        // round-trip cost over SYS_IPC_CALL. `ringbench [bytes]
        // [iters]`, defaults 4096 / 20000. The file is written once
        // and the fsd cache is primed first, so the loop measures
        // pure IPC round-trip overhead (rendezvous + 2 bounce copies
        // + context switches), not disk.
        int rb_bytes = 4096;
        int rb_iters = 20000;
        if (cmd_argc > 0) {
            int rb_v = 0; char* rb_cp = cmd_argv[0];
            while (*rb_cp >= '0' && *rb_cp <= '9') { rb_v = rb_v * 10 + (int)(*rb_cp - '0'); rb_cp++; }
            if (rb_v > 0) { rb_bytes = rb_v; }
        }
        if (cmd_argc > 1) {
            int rb_v = 0; char* rb_cp = cmd_argv[1];
            while (*rb_cp >= '0' && *rb_cp <= '9') { rb_v = rb_v * 10 + (int)(*rb_cp - '0'); rb_cp++; }
            if (rb_v > 0) { rb_iters = rb_v; }
        }
        if (rb_bytes < 1) { rb_bytes = 1; }
        if (rb_bytes > 7168) { rb_bytes = 7168; } // headroom under MSG_MAX for the fsd reply framing

        for (int rb_i = 0; rb_i < rb_bytes; rb_i++) { ringbench_buf[rb_i] = (char)(rb_i & 0x7F); }
        if (fs_write("/tmp/rbench", &ringbench_buf[0], rb_bytes) != rb_bytes) {
            print("ringbench: setup write failed\n");
        } else {
            fs_read_at("/tmp/rbench", &ringbench_buf[0], rb_bytes, 0); // prime the fsd cache

            // SYS_PROF returns the PRE-reset totals, then zeroes — so
            // after this reset call the odometer is 0 and the single
            // post-loop read below IS the delta. (Subtracting the
            // reset snapshot underflows against the huge boot-time
            // totals — the same trap synhist hit.)
            ulong[4] rb_pr @noinit;
            prof_read(&rb_pr[0], 1);
            ulong rb_t0 = rdtime();
            int rb_bad = 0;
            for (int rb_i = 0; rb_i < rb_iters; rb_i++) {
                if (fs_read_at("/tmp/rbench", &ringbench_buf[0], rb_bytes, 0) != rb_bytes) { rb_bad++; }
            }
            ulong rb_wall = rdtime() - rb_t0;
            prof_read(&rb_pr[0], 0);

            ulong rb_hz  = timebase_hz();
            ulong rb_ns  = 1000000000;
            ulong rb_it  = (ulong)rb_iters;
            ulong rb_calls    = rb_pr[0];
            ulong rb_yields   = rb_pr[2];
            ulong rb_switches = rb_pr[3];
            ulong rb_nsop = (rb_hz > 0) ? (rb_wall * rb_ns) / (rb_it * rb_hz) : 0;

            print("ringbench: "); print_uint((uint)rb_bytes); print("B x ");
            print_uint((uint)rb_iters); print(" fs_read_at via SYS_IPC_CALL\n");
            print("  wall       ");
            print_uint((uint)(rb_hz > 0 ? rb_wall / rb_hz : 0)); print("s  ");
            print_uint((uint)rb_nsop); print(" ns/op\n");
            print("  ipc_calls  "); ringbench_perop(rb_calls, rb_it); print(" /op\n");
            print("  switches   "); ringbench_perop(rb_switches, rb_it); print(" /op\n");
            print("  yields     "); ringbench_perop(rb_yields, rb_it); print(" /op\n");
            if (rb_bad > 0) { print("  WARN short reads: "); print_uint((uint)rb_bad); putchar('\n'); }
            fs_delete("/tmp/rbench");
        }
    } else if (strcmp(cmd, "nstest") == 0) {
        // Direct namespace-resolution smoke test: prove ns_resolve
        // itself works, independent of the 9P-lite/fsd layers built
        // on top of it. Four mounts today (src/process.c3's
        // create_process): "/srv/echo/" -> echod (pid 2), "" -> fsd
        // (catch-all for anything that doesn't start with "/" —
        // which is every plain filename, "nope" included), "/mnt/fs2/" ->
        // fsd2, "/proc/" -> procd.
        int pid_root = ns_resolve("/srv/echo/anything", null);
        print("resolve /srv/echo/anything -> pid ");
        putchar((char)('0' + pid_root));
        print("\n");

        int pid_fallback = ns_resolve("nope", null);
        print("resolve nope -> pid ");
        putchar((char)('0' + pid_fallback));
        print(" (catch-all)\n");
    } else if (strcmp(cmd, "srvtest") == 0) {
        // Proves the real srv-post + mount two-step end to end:
        // srv_post() (a running server registers itself under a short
        // name in the kernel's global srv_table) and ns_mount() (any
        // process binds that name at a path prefix in its *own*
        // namespace) — the dynamic counterpart to the four static
        // prefixes create_process() has always populated every
        // process with.
        //
        // rfork(RFPROC) a child that posts itself as "echo2" and then
        // serves like echod (ipc_recv_type_gen/ipc_reply, this
        // session's own generation-safe reply path) — same inline
        // child shape killtest/rforktest already use.
        uint srv_gen = 0;
        int srv_r = rfork(RFPROC, &srv_gen);
        if (srv_r < 0) {
            print("rfork failed\n");
        } else if (srv_r == 0) {
            srv_post("echo2");
            for (;;) {
                char[64] srv_buf @noinit;
                uint srv_verb = 0;
                uint srv_from_gen = 0;
                int srv_from = ipc_recv_type_gen(&srv_buf, 64, &srv_verb, &srv_from_gen);
                if (srv_from <= 0) continue;
                ipc_reply(srv_from, srv_verb, &srv_buf, 64, srv_from_gen);
            }
        } else {
            // No synchronization between rfork() returning here and
            // the child's first instruction — the child may not have
            // posted yet. This can NOT be closed with a bare busy-
            // retry on ns_mount() the way killtest's spin-child gets
            // away with: the timer interrupt only fires once per full
            // real second (arm_timer(board::TIMEBASE_HZ),
            // src/entry.c3) — a tight loop of nothing but fast,
            // non-blocking syscalls can easily finish before a single
            // tick ever occurs, so the child would never actually get
            // scheduled (confirmed the hard way: an earlier version
            // of this test spun 100000 iterations and still never
            // observed the post). A direct message to the child's own
            // already-known pid (srv_r, from rfork's own return value
            // — not through the namespace) sidesteps the timer
            // entirely: SYS_IPC_SEND's blocking rendezvous wait calls
            // the kernel's internal yield() on every failed check,
            // the same mechanism every other blocking-IPC test in
            // this suite already relies on for real scheduling. Since
            // srv_post() is the child's very first statement, by the
            // time it reaches its own ipc_recv_type_gen() to consume
            // this sync message, the post has already happened.
            ipc_send(srv_r, 0, "sync", 5);
            char[16] srv_sync_reply @noinit;
            ipc_recv(&srv_sync_reply, 16);

            int srv_mounted = ns_mount("/srv/echo2/", "echo2");
            int srv_pid = ns_resolve("/srv/echo2/", null);
            ipc_send(srv_pid, 0, "hi echo2", 9);
            char[16] srv_reply @noinit;
            int srv_from2 = ipc_recv(&srv_reply, 16);
            int srv_unmounted = ns_unmount("/srv/echo2/");
            int srv_killed = kill(srv_r, srv_gen);
            if (srv_mounted == 0 && srv_pid > 0 && srv_from2 > 0 && strcmp(&srv_reply, "hi echo2") == 0 && srv_unmounted == 0 && srv_killed == 0) {
                print("srvtest: ok\n");
            } else {
                print("srvtest: FAILED\n");
            }
        }
    } else if (strcmp(cmd, "envtest") == 0) {
        // /env (user/envd.c3): per-process environment variables,
        // reusing all four existing FS_* verbs (FS_READ/FS_WRITE/
        // FS_LIST/FS_DELETE) — fs_write()/fs_read()/fs_list()/
        // fs_delete() reach it with zero client-side changes, same
        // as every other synthetic server this session built.
        fs_write("/env/GREETING", "hello", 5);
        char[32] env_buf @noinit;
        int env_len = fs_read("/env/GREETING", &env_buf, 32);
        if (env_len >= 0) env_buf[env_len] = 0;
        bool env_read_ok = env_len == 5 && strcmp(&env_buf, "hello") == 0;

        char[576] env_listbuf @noinit;
        int env_count = fs_list("/env/", &env_listbuf, 16);
        bool env_list_ok = false;
        for (int ei = 0; ei < env_count; ei++) {
            char* rec = &env_listbuf[ei * 36];
            if (strcmp(rec, "GREETING") == 0) env_list_ok = true;
        }

        int env_del = fs_delete("/env/GREETING");
        int env_after_del = fs_read("/env/GREETING", &env_buf, 32);
        bool env_del_ok = env_del == 0 && env_after_del < 0;

        // Inheritance + isolation proof (the part that actually
        // matters): a child forked *after* the parent sets
        // "GREETING" must see that value on its very first read —
        // proving envd's lazy inherit-on-first-touch actually ran —
        // then, after overwriting its own copy with a different
        // value, the parent's own var (re-read afterward) must come
        // back exactly what the parent itself wrote, never the
        // child's — proving inheritance is a one-time snapshot, not
        // a live link, and that two processes' vars under the same
        // name still don't collide. Direct message to the child's
        // own known pid first, not a busy-retry — same fix srvtest
        // needed for the same reason (the timer only fires once per
        // real second, see that entry's own root-cause writeup).
        fs_write("/env/GREETING", "parent_value", 12);
        uint env_child_gen = 0;
        int env_child_r = rfork(RFPROC, &env_child_gen);
        if (env_child_r == 0) {
            char[16] env_sync_buf @noinit;
            int env_parent_pid = ipc_recv(&env_sync_buf, 16);

            char[32] env_child_buf @noinit;
            int env_inherited_len = fs_read("/env/GREETING", &env_child_buf, 32);
            if (env_inherited_len >= 0) env_child_buf[env_inherited_len] = 0;
            bool env_inherited_ok = env_inherited_len == 12 && strcmp(&env_child_buf, "parent_value") == 0;

            fs_write("/env/GREETING", "child_value", 11);
            ipc_send(env_parent_pid, 0, env_inherited_ok ? "done1" : "done0", 6);
            exit();
        } else if (env_child_r > 0) {
            ipc_send(env_child_r, 0, "go", 3);
            char[16] env_done_buf @noinit;
            ipc_recv(&env_done_buf, 16);
            bool env_inherited_ok = strcmp(&env_done_buf, "done1") == 0;

            int env_isolated_len = fs_read("/env/GREETING", &env_buf, 32);
            if (env_isolated_len >= 0) env_buf[env_isolated_len] = 0;
            bool env_isolated_ok = env_isolated_len == 12 && strcmp(&env_buf, "parent_value") == 0;

            fs_delete("/env/GREETING");

            if (env_read_ok && env_list_ok && env_del_ok && env_inherited_ok && env_isolated_ok) {
                print("envtest: ok\n");
            } else {
                print("envtest: FAILED\n");
            }
        } else {
            print("rfork failed\n");
        }
    } else if (strcmp(cmd, "hungservertest") == 0) {
        // Proves the supervisor's hang watchdog (src/supervisor.c3,
        // docs/roadmap.md §5.6): wedge echod (ECHOD_HANG -> it spins
        // forever without returning to ipc_recv), then confirm the
        // watchdog notices the next request piling up unconsumed and
        // kills + respawns it. NB: if the watchdog is broken this
        // test hangs at the second send — that's the signal.
        int hg_pid = ns_resolve("/srv/echo/", null);
        ipc_send(hg_pid, ECHOD_HANG, "x", 1);   // consumed; echod now spinning

        // Piles up unconsumed in echod's inbox. Blocks until the
        // watchdog tears the hung echod down (~5 s), which wakes this
        // send with -1.
        int hg_wedged = ipc_send(hg_pid, 0, "poke", 5);

        // Recover: the respawn + namespace reseat happen in the same
        // timer tick as the kill, so "/srv/echo/" now resolves to the
        // fresh echod. Round-trip to prove it serves again.
        int hg_ok = -1;
        ulong hg_deadline = rdtime() + timebase_hz() * 20; // 20s wall-clock, any board
        while (hg_ok < 0 && rdtime() < hg_deadline) {
            yield();
            // Only probe once "/srv/echo/" resolves to the echod
            // mount itself (matched-prefix length 10), not the ""
            // catch-all (length 0) it falls through to while echod is
            // dead — sending to the root fsd would just hang here.
            uint hg_mlen = 0;
            int hp = ns_resolve("/srv/echo/", &hg_mlen);
            if (hp <= 0 || hg_mlen != 10) continue;
            if (ipc_send(hp, 0, "hi", 3) < 0) continue;
            char[64] hr @noinit;
            if (ipc_recv(&hr, 64) > 0) hg_ok = 0;
        }
        if (hg_wedged < 0 && hg_ok == 0) {
            print("hungservertest: ok (wedged echod killed + respawned, serving again)\n");
        } else {
            print("hungservertest: FAILED\n");
        }
    } else if (strcmp(cmd, "ipcdeathtest") == 0) {
        // Proves the IPC rendezvous no longer hangs forever when the
        // peer dies mid-transfer (src/syscalls.c3 sys_exit /
        // ipc_wake_waiters_on, docs/roadmap.md §5). A child is
        // spawned that never calls ipc_recv and just exit()s after a
        // short busy delay; the parent ipc_send()s to it and would
        // block in the phase-2 rendezvous forever without the fix.
        // With it, the child's exit sweeps the parent awake with -1.
        uint idt_gen = 0;
        int idt_pid = rfork(RFPROC, &idt_gen);
        if (idt_pid < 0) {
            print("ipcdeathtest: rfork failed\n");
        } else if (idt_pid == 0) {
            // Long enough for the parent to reach its ipc_send and
            // park in the rendezvous; then vanish without ever
            // receiving.
            for (uint idt_i = 0; idt_i < 3000000; idt_i++) { }
            exit();
        } else {
            char[8] idt_msg = "hi";
            int idt_r = ipc_send(idt_pid, 1, &idt_msg, 2);
            int idt_joined = join(idt_pid, idt_gen);
            if (idt_r < 0 && idt_joined == 0) {
                print("ipcdeathtest: ok (send returned -1, no hang)\n");
            } else {
                print("ipcdeathtest: FAILED\n");
            }
        }
    } else {
        return false;
    }
    return true;
}
