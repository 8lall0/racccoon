module user;

import std::nolibc::fmt;

int rfork_shared_value = 0;
int rfork_child_ran = 0; // set by rforkmemtest's child, checked by rforkmemresult

// threadcreate's own private stack for threadtest, and the shared
// global the thread writes to — proving the parent can see what the
// thread wrote is what makes this "shared memory," not just "a process
// that happened to run."
char[4096] thread_stack;
int thread_result = 0;

// exec()'s own receive buffer for runtest below — caller-owned per
// exec()'s own header comment (user.c3): a global here, not inside
// user.c3 itself, so only binaries that actually call exec() pay the
// size (matches src/entry.c3's own EXEC_MAX_IMAGE_SIZE, the kernel-
// side cap this must be at least as large as).
const int RUN_EXEC_BUF_MAX = 262144;
char[RUN_EXEC_BUF_MAX] run_exec_buf;

// bigreadtest's own receive buffer (below) — global for the same reason
// run_exec_buf above is: 300000 bytes is well past what this process's
// own stack (STACK_SIZE, src/process.c3) could hold as a local. Sized
// to exactly match BIGFILE_SIZE, the fixture size scripts/build.sh
// seeds bigfile.bin at.
const int BIGFILE_SIZE = 300000;
char[BIGFILE_SIZE] bigread_buf;

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

fn void main() @export("main") {
    for (;;) {
        print("> ");

        char[128] cmdline @noinit;
        int i = 0;
        bool too_long = false;
        for (;;) {
            char ch = (char)getchar();
            // 0x7F (DEL) and 0x08 (BS) — different terminal
            // emulators/serial console tools send different bytes for
            // Backspace, no way to know which in advance, so both are
            // handled. Checked before the echo/full-buffer logic below
            // (not gated behind i == 127) so a user can also backspace
            // their way back from a genuinely full line instead of it
            // being unconditionally abandoned — falls out of the
            // ordering, not extra logic. The raw byte is never echoed
            // via putchar() — "\b \b" (cursor back, blank, cursor back
            // again) is what actually erases the character on-screen.
            if (ch == 127 || ch == 8) {
                if (i > 0) {
                    i--;
                    print("\b \b");
                }
                continue;
            }
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

        // Tokenize on spaces, in place — each token is a pointer
        // straight into cmdline, NUL-terminated where the next space
        // was, same "no separate storage" approach exec()'s own
        // NUL-separated argv blob already uses (user.c3). cmd_argv/
        // cmd_argc (everything after the command name) only matter to
        // the /bin/ fallback branch at the very end of this chain —
        // every builtin below ignores them, unchanged from before this
        // tokenization existed.
        const int SHELL_MAX_TOKENS = 8;
        char*[SHELL_MAX_TOKENS] tokens @noinit;
        int token_count = 0;
        int ti = 0;
        while (cmdline[ti] != 0 && token_count < SHELL_MAX_TOKENS) {
            while (cmdline[ti] == ' ') ti++;
            if (cmdline[ti] == 0) break;
            tokens[token_count] = &cmdline[ti];
            token_count++;
            while (cmdline[ti] != 0 && cmdline[ti] != ' ') ti++;
            if (cmdline[ti] == ' ') { cmdline[ti] = 0; ti++; }
        }
        if (token_count == 0) continue;

        char* cmd = tokens[0];
        char** cmd_argv = &tokens[1];
        int cmd_argc = token_count - 1;
        if (strcmp(cmd, "hello") == 0) {
            print("Hello world from shell!\n");
        } else if (strcmp(cmd, "exit") == 0) {
            exit();
        } else if (strcmp(cmd, "cycletest") == 0) {
            // Proves fat32_rename/ext2_rename now refuse "moving a
            // directory into its own subtree" instead of silently
            // creating a cycle in the directory tree. Builds a real
            // 2-level nested directory (tmp/cyc_a/cyc_b), then tries two
            // ways to break it: renaming tmp/cyc_a directly into itself
            // (depth-0 cycle — the new parent *is* the directory being
            // moved) and into its own grandchild tmp/cyc_a/cyc_b
            // (depth-1 cycle). Both must be refused (fs_rename returns
            // -1) and must leave the tree genuinely untouched — checked
            // by writing into and reading back from tmp/cyc_a/cyc_b
            // afterward, not just trusting the -1. A real, non-cyclic
            // move (cyc_b out to a sibling) proves the fix didn't just
            // start refusing every directory rename.
            fs_mkdir("tmp/cyc_a");
            fs_mkdir("tmp/cyc_a/cyc_b");
            int cyc_self = fs_rename("tmp/cyc_a", "tmp/cyc_a/self");
            int cyc_grandchild = fs_rename("tmp/cyc_a", "tmp/cyc_a/cyc_b/deeper");
            fs_write("tmp/cyc_a/cyc_b/marker.txt", "still intact\n", 13);
            char[32] cyc_buf @noinit;
            int cyc_still_intact = fs_read("tmp/cyc_a/cyc_b/marker.txt", &cyc_buf, 32);
            int cyc_real_move = fs_rename("tmp/cyc_a/cyc_b", "tmp/cyc_b_moved");
            int cleanup_a = fs_delete_recursive("tmp/cyc_a");
            int cleanup_b = fs_delete_recursive("tmp/cyc_b_moved");
            if (cyc_self < 0 && cyc_grandchild < 0 && cyc_still_intact >= 0 && cyc_real_move == 0 && cleanup_a == 0 && cleanup_b == 0) {
                print("cycletest: ok\n");
            } else {
                print("cycletest: FAILED\n");
            }
        } else if (strcmp(cmd, "ping") == 0) {
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
            // (Tcreate, Tremove full, Twrite offset-0 only — see
            // docs/devlog.md). Exercises create-then-immediately-
            // write-then-read, the offset-0-only restriction, and the
            // dangling-fid safety check with two real, independently-
            // attached fids on the same inode.
            int p9w_pid = ns_resolve("", null);
            char[40] p9w_buf @noinit;

            int p9w_attach1 = p9_attach(p9w_pid, 1); // fid 1 = root

            int p9w_walk_missing = p9_walk(p9w_pid, 1, 2, "p9wtest.txt"); // must fail — doesn't exist yet

            int p9w_create = p9_create(p9w_pid, 1, "p9wtest.txt"); // fid 1 transforms into the new (already-open) file

            int p9w_write = p9_write(p9w_pid, 1, 0, "hello from real 9p write\n", 26);

            int p9w_read = p9_read(p9w_pid, 1, 0, 40, &p9w_buf);
            p9w_buf[p9w_read >= 0 ? p9w_read : 0] = 0;
            bool p9w_read_ok = p9w_read == 26 && strcmp(&p9w_buf, "hello from real 9p write\n") == 0;

            int p9w_write_bad_offset = p9_write(p9w_pid, 1, 4, "x", 1); // must fail — offset-0-only restriction

            int p9w_attach2 = p9_attach(p9w_pid, 2); // fid 2 = root, independently
            int p9w_walk2 = p9_walk(p9w_pid, 2, 3, "p9wtest.txt"); // fid 3, a second fid on the same inode
            int p9w_open3 = p9_open(p9w_pid, 3);

            int p9w_remove_dangling = p9_remove(p9w_pid, 1); // must FAIL — fid 3 still has it open
            int p9w_clunk3 = p9_clunk(p9w_pid, 3);
            int p9w_remove_ok = p9_remove(p9w_pid, 1); // now succeeds — fid 1 consumed either way
            int p9w_clunk2 = p9_clunk(p9w_pid, 2);

            if (p9w_attach1 == 0 && p9w_walk_missing < 0 && p9w_create == 0
                && p9w_write == 26 && p9w_read_ok && p9w_write_bad_offset < 0
                && p9w_attach2 == 0 && p9w_walk2 == 0 && p9w_open3 == 0
                && p9w_remove_dangling < 0 && p9w_clunk3 == 0
                && p9w_remove_ok == 0 && p9w_clunk2 == 0) {
                print("p9fswritetest: ok\n");
            } else {
                print("p9fswritetest: FAILED\n");
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
            // (src/entry.c3's SYS_IPC_RECV) — a ping sent too early can
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
                exec("bin/echod", &run_exec_buf, RUN_EXEC_BUF_MAX, run_parent, null, 0);
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
                exec("/mnt/fs2/bin/echod", &run_exec_buf, RUN_EXEC_BUF_MAX, rt2_parent, null, 0);
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
            // uses), exercising SYS_EXEC's own ELF loader (src/entry.c3)
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
                exec("bin/echod.elf", &run_exec_buf, RUN_EXEC_BUF_MAX, el_parent, null, 0);
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
                exec("/mnt/fs2/bin/echod.elf", &run_exec_buf, RUN_EXEC_BUF_MAX, el2_parent, null, 0);
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
                exec("bin/echod", &run_exec_buf, RUN_EXEC_BUF_MAX, av_parent, &av_arg, 1);
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
                exec("/mnt/fs2/bin/echod", &run_exec_buf, RUN_EXEC_BUF_MAX, av2_parent, &av2_arg, 1);
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
                exec_path("echod", &run_exec_buf, RUN_EXEC_BUF_MAX, pt_parent, null, 0);
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
                exec_path("echod", &run_exec_buf, RUN_EXEC_BUF_MAX, pt2_parent, null, 0);
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
        } else if (strcmp(cmd, "permtest") == 0) {
            // Process.uid (src/process.c3): root (uid 0, this shell's
            // own default by inheritance) may kill/reclaim anything; a
            // non-root process may not. Three processes: this shell
            // (root), a "victim" child (inherits root, posts itself as
            // "victim" then spins forever — same spin shape killtest's
            // own child already uses), and an "attacker" child that
            // drops to uid 42 (setuid() — only possible because it
            // inherited root from the shell) then tries, and must fail
            // at, every angle: kill() directly, setuid(0) again
            // (re-escalation), srv_post("victim") (hijacking its
            // name), and the /proc/<pid>/ctl "kill" path — the one
            // that would silently succeed without procd's own
            // permission check (user/procd.c3), since procd itself is
            // always root.
            uint pm_victim_gen = 0;
            int pm_victim = rfork(RFPROC, &pm_victim_gen);
            if (pm_victim < 0) {
                print("rfork failed\n");
            } else if (pm_victim == 0) {
                srv_post("victim");
                // Sync point: this recv() can't return until the
                // parent's own send below does, so by the time that
                // happens, srv_post() above is guaranteed to have
                // already run — same reasoning srvtest's own child
                // sync relies on.
                char[16] pm_sync_buf @noinit;
                ipc_recv(&pm_sync_buf, 16);
                for (;;) {
                    rfork_shared_value = rfork_shared_value + 1;
                }
            } else {
                ipc_send(pm_victim, 0, "sync", 5);

                uint pm_attacker_gen = 0;
                int pm_attacker = rfork(RFPROC, &pm_attacker_gen);
                if (pm_attacker < 0) {
                    print("rfork failed\n");
                } else if (pm_attacker == 0) {
                    char[16] pm_go_buf @noinit;
                    int pm_parent = ipc_recv(&pm_go_buf, 16);

                    int pm_su1 = setuid(42);
                    print("permtest: setuid(42) ");
                    print(pm_su1 == 0 ? "ok\n" : "FAILED\n");

                    int pm_kill1 = kill(pm_victim, pm_victim_gen);
                    print("permtest: kill(victim) as non-root ");
                    print(pm_kill1 != 0 ? "correctly denied\n" : "WRONGLY succeeded\n");

                    int pm_su2 = setuid(0);
                    print("permtest: re-setuid(0) as non-root ");
                    print(pm_su2 != 0 ? "correctly denied\n" : "WRONGLY succeeded\n");

                    int pm_post = srv_post("victim");
                    print("permtest: srv_post hijack as non-root ");
                    print(pm_post != 0 ? "correctly denied\n" : "WRONGLY succeeded\n");

                    char[16] pm_ctl_path @noinit;
                    int pm_pos = 0;
                    char* pm_prefix = "/proc/";
                    while (pm_prefix[pm_pos] != 0) {
                        pm_ctl_path[pm_pos] = pm_prefix[pm_pos];
                        pm_pos++;
                    }
                    int pm_digits = fmt::format_uint((uint)pm_victim, &pm_ctl_path[pm_pos]);
                    pm_pos += pm_digits;
                    char* pm_suffix = "/ctl";
                    int pm_si = 0;
                    while (pm_suffix[pm_si] != 0) {
                        pm_ctl_path[pm_pos + pm_si] = pm_suffix[pm_si];
                        pm_si++;
                    }
                    pm_pos += pm_si;
                    pm_ctl_path[pm_pos] = 0;
                    int pm_ctl_result = fs_write(&pm_ctl_path, "kill", 4);
                    print("permtest: /proc/ctl kill as non-root ");
                    print(pm_ctl_result < 0 ? "correctly denied\n" : "WRONGLY succeeded\n");

                    ipc_send(pm_parent, 0, "done", 5);
                    exit();
                } else {
                    ipc_send(pm_attacker, 0, "go", 3);
                    char[16] pm_done_buf @noinit;
                    ipc_recv(&pm_done_buf, 16);

                    // Confirms the victim genuinely survived every one
                    // of the attacker's attempts above — not just that
                    // they each returned an error code.
                    uint pm_victim_state = 0;
                    int pm_victim_alive = proc_info(pm_victim, &pm_victim_state, null, null);
                    int pm_victim_killed = kill(pm_victim, pm_victim_gen);

                    if (pm_victim_alive == 0 && pm_victim_killed == 0) {
                        print("permtest: ok\n");
                    } else {
                        print("permtest: FAILED\n");
                    }
                }
            }
        } else if (strcmp(cmd, "fspermtest") == 0) {
            // Real ext2 file permissions (i_uid + owner/other write
            // bits, user/fs/ext2.c3): root (this shell, uid 0) may
            // overwrite/delete anything; a non-root process may only
            // touch what it owns (or what a file's own "other" bit
            // allows). Creates a file directly (root-owned), rforks a
            // child that drops to uid 42 and tries to tamper with it
            // (both attempts must fail), then proves it can still
            // fully manage its own files — create, overwrite, and
            // delete all succeeding proves creation really does stamp
            // the creator's own uid, not just that non-owner access
            // gets denied.
            //
            // No IPC handshake needed the way permtest's own attacker
            // needed one: fs_write()/fs_delete() are already
            // synchronous blocking round trips, and join() (below,
            // real Plan-9-style: blocks until the joined process is
            // actually gone, src/entry.c3's SYS_JOIN) is exactly the
            // "wait for the child to be genuinely, fully done" this
            // needs.
            //
            // "/mnt/fs2/" prefix on every path here, not bare filenames —
            // found the hard way testing this on real Duo hardware,
            // back when both DUOBOOT/FAT32 and EXT2TEST/ext2 were
            // simultaneously mounted (see docs/devlog.md): an
            // unprefixed path resolves through the "" catch-all mount
            // (src/process.c3's default namespace), which binds to
            // whichever fsd was created *first* — FAT32 has no uid
            // concept at all to enforce, so a bare path silently
            // "succeeded" without ever reaching ext2 at all. Real
            // hardware no longer mounts FAT32 as anything racccoon's
            // own fsd touches (see this entry's own Plan9-style
            // reorganization), so this specific failure mode is now
            // structurally impossible there — "/mnt/fs2/" stays the
            // convention regardless, since QEMU's own dual-mount image
            // (scripts/launch64_dual.sh) still has a real second mount
            // this test needs to target unambiguously.
            fs_write("/mnt/fs2/owner_only.txt", "root content", 12);
            // A real two-entry tree, not a bare empty dir — an empty
            // dir wouldn't exercise ext2_delete_dir_contents' own child
            // walk at all, so wouldn't actually prove recursive-delete
            // ownership enforcement (see ext2_delete_recursive's own
            // comment).
            fs_mkdir("/mnt/fs2/owner_only_dir");
            fs_write("/mnt/fs2/owner_only_dir/inner.txt", "root content", 12);

            uint fp_gen = 0;
            int fp_r = rfork(RFPROC, &fp_gen);
            if (fp_r < 0) {
                print("rfork failed\n");
            } else if (fp_r == 0) {
                int fp_su = setuid(42);
                print("fspermtest: setuid(42) ");
                print(fp_su == 0 ? "ok\n" : "FAILED\n");

                int fp_write1 = fs_write("/mnt/fs2/owner_only.txt", "attacker content", 17);
                print("fspermtest: overwrite root-owned file as non-owner ");
                print(fp_write1 < 0 ? "correctly denied\n" : "WRONGLY succeeded\n");

                int fp_del1 = fs_delete("/mnt/fs2/owner_only.txt");
                print("fspermtest: delete root-owned file as non-owner ");
                print(fp_del1 < 0 ? "correctly denied\n" : "WRONGLY succeeded\n");

                int fp_ren1 = fs_rename("/mnt/fs2/owner_only.txt", "/mnt/fs2/stolen.txt");
                print("fspermtest: rename root-owned file as non-owner ");
                print(fp_ren1 < 0 ? "correctly denied\n" : "WRONGLY succeeded\n");

                int fp_write2 = fs_write("/mnt/fs2/attacker_owned.txt", "mine", 4);
                print("fspermtest: create own file ");
                print(fp_write2 >= 0 ? "ok\n" : "FAILED\n");

                int fp_write3 = fs_write("/mnt/fs2/attacker_owned.txt", "mine still", 10);
                print("fspermtest: overwrite own file ");
                print(fp_write3 >= 0 ? "ok\n" : "FAILED\n");

                int fp_ren2 = fs_rename("/mnt/fs2/attacker_owned.txt", "/mnt/fs2/attacker_renamed.txt");
                print("fspermtest: rename own file ");
                print(fp_ren2 >= 0 ? "ok\n" : "FAILED\n");

                int fp_del2 = fs_delete("/mnt/fs2/attacker_renamed.txt");
                print("fspermtest: delete own file ");
                print(fp_del2 >= 0 ? "ok\n" : "FAILED\n");

                int fp_delr1 = fs_delete_recursive("/mnt/fs2/owner_only_dir");
                print("fspermtest: recursive-delete root-owned dir as non-owner ");
                print(fp_delr1 < 0 ? "correctly denied\n" : "WRONGLY succeeded\n");

                fs_mkdir("/mnt/fs2/attacker_owned_dir");
                fs_write("/mnt/fs2/attacker_owned_dir/inner.txt", "mine", 4);
                int fp_delr2 = fs_delete_recursive("/mnt/fs2/attacker_owned_dir");
                print("fspermtest: recursive-delete own dir ");
                print(fp_delr2 >= 0 ? "ok\n" : "FAILED\n");

                exit();
            } else {
                join(fp_r, fp_gen);

                char[32] fp_readback @noinit;
                int fp_len = fs_read("/mnt/fs2/owner_only.txt", &fp_readback, 32);
                if (fp_len >= 0) fp_readback[fp_len] = 0;
                bool fp_intact = fp_len == 12 && strcmp(&fp_readback, "root content") == 0;

                char[32] fp_dir_readback @noinit;
                int fp_dir_len = fs_read("/mnt/fs2/owner_only_dir/inner.txt", &fp_dir_readback, 32);
                if (fp_dir_len >= 0) fp_dir_readback[fp_dir_len] = 0;
                bool fp_dir_intact = fp_dir_len == 12 && strcmp(&fp_dir_readback, "root content") == 0;

                int fp_write_root = fs_write("/mnt/fs2/owner_only.txt", "root content v2", 16);
                int fp_del_root = fs_delete("/mnt/fs2/owner_only.txt");
                // Root's own legitimate recursive-delete path, exercising
                // requester_uid == 0 still working unchanged through the
                // new checks — also this test's own cleanup.
                int fp_delr_root = fs_delete_recursive("/mnt/fs2/owner_only_dir");

                if (fp_intact && fp_dir_intact && fp_write_root >= 0 && fp_del_root >= 0 && fp_delr_root >= 0) {
                    print("fspermtest: ok\n");
                } else {
                    print("fspermtest: FAILED\n");
                }
            }
        } else if (strcmp(cmd, "bigreadtest") == 0) {
            // Exercises ext2's double-indirect block support
            // (user/fs/ext2.c3's ext2_resolve_block/ext2_resolve_leaf):
            // bigfile.bin (scripts/build.sh, BIGFILE_SIZE bytes,
            // byte[i] = i % 256) is genuinely past single-indirect
            // reach even at QEMU's own smallest 1024-byte block size
            // (12 + 256 = 268 blocks = 268KB; this fixture is 300KB) —
            // the first file this driver has ever been asked to read
            // that far. "/mnt/fs2/" prefix, unambiguously targeting the
            // second mount — same reasoning fspermtest's own header
            // comment already established. Reads via fs_read_at in chunks, same shape
            // exec()'s own loop uses (user/user.c3), then verifies
            // every single byte against the known pattern — not just
            // that some plausible-looking bytes came back, since a
            // wrong block resolution would still return real, on-disk
            // bytes, just the wrong ones, and any single wrong block
            // anywhere in the file is instantly detectable this way.
            uint br_total = 0;
            bool br_read_ok = true;
            for (;;) {
                if (br_total >= (uint)BIGFILE_SIZE) break;
                int br_chunk = (int)((uint)BIGFILE_SIZE - br_total);
                if (br_chunk > 1024) br_chunk = 1024;
                int br_got = fs_read_at("/mnt/fs2/bigfile.bin", &bigread_buf[br_total], br_chunk, br_total);
                if (br_got < 0) { br_read_ok = false; break; }
                if (br_got == 0) break;
                br_total += (uint)br_got;
            }

            uint br_mismatch_at = (uint)BIGFILE_SIZE; // sentinel: no mismatch found
            bool br_content_ok = br_read_ok && br_total == (uint)BIGFILE_SIZE;
            if (br_content_ok) {
                for (uint br_i = 0; br_i < (uint)BIGFILE_SIZE; br_i++) {
                    if ((char)(br_i % 256) != bigread_buf[br_i]) { br_content_ok = false; br_mismatch_at = br_i; break; }
                }
            }

            print("bigreadtest: ");
            if (br_content_ok) {
                print("ok\n");
            } else {
                print("FAILED (read_ok=");
                print(br_read_ok ? "1" : "0");
                print(" total=");
                print_uint(br_total);
                print("/");
                print_uint((uint)BIGFILE_SIZE);
                if (br_mismatch_at != (uint)BIGFILE_SIZE) {
                    print(" first_mismatch_at=");
                    print_uint(br_mismatch_at);
                }
                print(")\n");
            }
        } else if (strcmp(cmd, "mounttest") == 0) {
            // Proves srv_post()/ns_mount()/ns_unmount() (src/entry.c3)
            // genuinely work at runtime, not just as the boot-time
            // plumbing create_process() already uses once, statically,
            // for the default "/mnt/fs2/" binding (src/process.c3).
            // fsd2 already srv_post()s itself as "fs2" once it mounts
            // (user/fsd.c3) — this unmounts the default binding,
            // confirms it's really gone, then re-establishes it by name
            // through the exact same syscalls any user process could
            // call itself, and confirms that works too. Entirely
            // post-boot, manually triggered — no race with fsd2's own
            // startup the way rebuilding this at boot time would have
            // (see src/process.c3's own comment on why the default stays
            // static).
            char[32] mt_buf @noinit;
            int mt_before = fs_read("/mnt/fs2/hello.txt", &mt_buf, 32);

            int mt_unmounted = ns_unmount("/mnt/fs2/");
            int mt_after_unmount = fs_read("/mnt/fs2/hello.txt", &mt_buf, 32);

            int mt_remounted = ns_mount("/mnt/fs2/", "fs2");
            int mt_after_remount = fs_read("/mnt/fs2/hello.txt", &mt_buf, 32);

            if (mt_before >= 0 && mt_unmounted == 0 && mt_after_unmount < 0
                && mt_remounted == 0 && mt_after_remount >= 0) {
                print("mounttest: ok\n");
            } else {
                print("mounttest: FAILED\n");
            }
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
            // Not a builtin — try /bin/<cmd> (cat/ls/write/rm/mkdir/mv,
            // user/cat.c3 etc.), same shape runtest's own rfork()+exec()
            // already uses, just with the tokenized cmd_argv/cmd_argc
            // instead of a fixed argv. Bare "/bin/<cmd>", not $PATH-
            // resolved — matches every other bin/echod reference in this
            // file; $PATH lookup is pathtest's own, separately-tested
            // feature (exec_path), orthogonal to this.
            char[100] bin_path @noinit;
            int bp_i = 0;
            char* prefix = "/bin/";
            while (prefix[bp_i] != 0) { bin_path[bp_i] = prefix[bp_i]; bp_i++; }
            int bp_j = 0;
            while (cmd[bp_j] != 0 && bp_i < 99) { bin_path[bp_i] = cmd[bp_j]; bp_i++; bp_j++; }
            bin_path[bp_i] = 0;

            uint sh_gen = 0;
            int sh_r = rfork(RFPROC, &sh_gen);
            if (sh_r < 0) {
                print("rfork failed\n");
            } else if (sh_r == 0) {
                exec(&bin_path, &run_exec_buf, RUN_EXEC_BUF_MAX, 0, cmd_argv, cmd_argc);
                print(cmd);
                print(": command not found\n");
                exit();
            } else {
                join(sh_r, sh_gen);
            }
        }
    }
}
