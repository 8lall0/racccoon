module user;

import std::nolibc::main_stub;
import std::nolibc::fmt;

// Test shell: every dev/regression-test command this project has
// accumulated across its whole tutorial/bring-up history. This is what
// scripts/build.sh embeds for QEMU — the real, end-user-only builtins
// (hello/exit/mountusb/the /bin/ fallback) live in user/shell_common.c3
// instead, shared with the trimmed production shell (user/shell.c3,
// what scripts/build_duo.sh embeds for real hardware). See
// docs/devlog.md for why this split exists (shell.c3 used to carry
// both).
int rfork_shared_value = 0;

// threadcreate's own private stack for threadtest, and the shared
// global the thread writes to — proving the parent can see what the
// thread wrote is what makes this "shared memory," not just "a process
// that happened to run."
char[4096] thread_stack;
int thread_result = 0;

// bigreadtest's own receive buffer (below) — a global, not a local:
// 300000 bytes is well past what this process's own stack (STACK_SIZE,
// src/process.c3) could hold. Sized to exactly match BIGFILE_SIZE, the
// fixture size scripts/build.sh seeds bigfile.bin at. (The exec buffer
// next to it used to be a static too; it's SYS_MAP'd now — exec_buf(),
// user/shell_common.c3.)
const int BIGFILE_SIZE = 300000;
char[BIGFILE_SIZE] bigread_buf;


fn void thread_body(void* arg) {
    thread_result = 99;
    print("thread: running on my own stack, wrote thread_result\n");
    exit();
}

// exfatgrow's listing buffer — global for the same stack-budget reason
// bigread_buf above is (FS_LIST_ENTRY_SIZE * a generous entry count).
char[40 * 36] exfatgrow_listbuf;

// fsneg's throwaway read/list target — nothing reads it back, it just
// needs to be a valid buffer for the calls that are expected to fail.
char[64] fsneg_scratch;

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

fn void main() {
    // QEMU timebase is 10 MHz — ~3 s covers the (fast) virtio boot
    // chatter; automated test runs wait much longer than this before
    // sending anything anyway.
    shell_boot_settle(30000000);
    for (;;) {
        shell_prompt();

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
            // A stray NUL (UART framing error) or a bare LF at the start
            // of a line (the trailing half of a CRLF the CR already
            // consumed, or a double-tap) must not become a one-character
            // phantom command — swallow it silently. Same fix as
            // shell_common.c3's shell_readline (production shell).
            if (ch == 0 || (ch == '\n' && i == 0)) {
                continue;
            }
            putchar(ch);
            if (i == 127) {
                print("\ncommand line too long\n");
                too_long = true;
                break;
            }
            if (ch == '\r' || ch == '\n') {
                print("\n");
                cmdline[i] = 0;
                break;
            }
            cmdline[i] = ch;
            i++;
        }

        if (too_long) continue;

        // $var expansion, then tokenize the result in place.
        char[512] expanded @noinit;
        shell_expand(&cmdline[0], &expanded[0], 512);

        const int SHELL_MAX_TOKENS = 16;
        char*[SHELL_MAX_TOKENS] tokens @noinit;
        int token_count = 0;
        int ti = 0;
        while (expanded[ti] != 0 && token_count < SHELL_MAX_TOKENS) {
            while (expanded[ti] == ' ') ti++;
            if (expanded[ti] == 0) break;
            tokens[token_count] = &expanded[ti];
            token_count++;
            while (expanded[ti] != 0 && expanded[ti] != ' ') ti++;
            if (expanded[ti] == ' ') { expanded[ti] = 0; ti++; }
        }
        if (token_count == 0) continue;

        char* cmd = tokens[0];
        char** cmd_argv = &tokens[1];
        int cmd_argc = token_count - 1;
                if (strcmp(cmd, "cycletest") == 0) {
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
        } else if (strcmp(cmd, "exfatgrow") == 0) {
            // exFAT directory extension (exfat_extend_dir): a fresh
            // directory starts as one NoFatChain cluster (~42 short-
            // named entry sets). Create 64 subdirectories in one, which
            // forces at least one grow — the first converts it to a real
            // FAT chain, rewriting its own DataLength / NoFatChain flag
            // in its parent (root) entry set. Proof it worked:
            //   - all 64 fs_mkdir succeed (a directory that couldn't
            //     grow would start returning -1 around the 42nd);
            //   - a marker file written into the LAST-created child
            //     reads back — that child's entry set only exists in the
            //     grown directory's second cluster, so the cursor walk
            //     had to follow the new chain link to find it;
            //   - a nested mkdir into that same late child succeeds;
            //   - fs_list returns a full reply (>= 30 records).
            // Cleanup is one fs_delete_recursive, which now walks a
            // multi-cluster directory. Only meaningful with an exFAT
            // root (scripts/launch64_exfat.sh); on FAT32/ext2 it just
            // re-exercises their own long-standing directory growth.
            const int XG_N = 64;
            int xg_parent = fs_mkdir("xg");
            int xg_made = 0;
            for (int xgk = 0; xgk < XG_N; xgk++) {
                char[24] xgp @noinit;
                char* xgpfx = "xg/d";
                int xgi = 0;
                while (xgpfx[xgi] != 0) { xgp[xgi] = xgpfx[xgi]; xgi++; }
                int xgd = fmt::format_uint((uint)xgk, &xgp[xgi]);
                xgp[xgi + xgd] = 0;
                if (fs_mkdir(&xgp) == 0) xg_made++;
            }
            int xg_marker_write = fs_write("xg/d63/marker.txt", "grew\n", 5);
            char[16] xg_buf @noinit;
            int xg_marker_read = fs_read("xg/d63/marker.txt", &xg_buf, 16);
            int xg_nested = fs_mkdir("xg/d63/sub");
            int xg_list = fs_list("xg", &exfatgrow_listbuf, 40);
            int xg_cleanup = fs_delete_recursive("xg");
            int xg_gone = fs_read("xg/d63/marker.txt", &xg_buf, 16);
            if (xg_parent == 0 && xg_made == XG_N && xg_marker_write == 5
                && xg_marker_read == 5 && xg_nested == 0 && xg_list >= 30
                && xg_cleanup == 0 && xg_gone < 0) {
                print("exfatgrow: ok\n");
            } else {
                print("exfatgrow: FAILED\n");
            }
        } else if (strcmp(cmd, "exfatgrowkeep") == 0) {
            // Same fill as exfatgrow but WITHOUT the cleanup — leaves a
            // real multi-cluster directory on disk so a host fsck.exfat
            // on the booted image can confirm the grown layout (chain,
            // DataLength, sealed tail slots) is spec-clean. Re-run needs
            // a pristine image (launch64_exfat.sh already boots a
            // throwaway copy).
            int xk_parent = fs_mkdir("xgk");
            int xk_made = 0;
            for (int xkk = 0; xkk < 64; xkk++) {
                char[24] xkp @noinit;
                char* xkpfx = "xgk/d";
                int xki = 0;
                while (xkpfx[xki] != 0) { xkp[xki] = xkpfx[xki]; xki++; }
                int xkd = fmt::format_uint((uint)xkk, &xkp[xki]);
                xkp[xki + xkd] = 0;
                if (fs_mkdir(&xkp) == 0) xk_made++;
            }
            int xk_w = fs_write("xgk/d63/marker.txt", "kept\n", 5);
            if (xk_parent == 0 && xk_made == 64 && xk_w == 5) {
                print("exfatgrowkeep: ok\n");
            } else {
                print("exfatgrowkeep: FAILED\n");
            }
        } else if (strcmp(cmd, "fswriteat") == 0) {
            // FS_WRITE_AT / FS_STAT across whatever fs is mounted — so
            // the four launch64*.sh scripts cover FAT32 / ext2 / dual /
            // exFAT with this one test. Writes a 9000-byte file in
            // <=1020-byte chunks (multi-cluster on FAT32/exFAT, 9 blocks
            // on the 1KB-block QEMU ext2 images — under the 12-direct
            // cap), reads it back and byte-compares, then checks a
            // mid-file overwrite, an append via FS_OFFSET_APPEND, the
            // no-holes rejection, a write to a directory, and fs_stat's
            // size/type. Pattern byte at position p is (char)(p & 0xFF).
            const int FWA_N = 9000;
            char[1024] fwa_chunk @noinit;
            bool fwa_ok = true;

            // write in chunks
            int fwa_pos = 0;
            while (fwa_pos < FWA_N && fwa_ok) {
                int fwa_c = FWA_N - fwa_pos;
                if (fwa_c > 1000) fwa_c = 1000;
                for (int fwa_i = 0; fwa_i < fwa_c; fwa_i++) {
                    fwa_chunk[fwa_i] = (char)((fwa_pos + fwa_i) & 0xFF);
                }
                int fwa_w = fs_write_at("wat.bin", &fwa_chunk, fwa_c, (uint)fwa_pos);
                if (fwa_w != fwa_c) fwa_ok = false;
                fwa_pos += fwa_c;
            }

            // read back and compare
            int fwa_rpos = 0;
            while (fwa_rpos < FWA_N && fwa_ok) {
                int fwa_rc = fs_read_at("wat.bin", &fwa_chunk, 1000, (uint)fwa_rpos);
                if (fwa_rc <= 0) { fwa_ok = false; break; }
                for (int fwa_j = 0; fwa_j < fwa_rc; fwa_j++) {
                    if (fwa_chunk[fwa_j] != (char)((fwa_rpos + fwa_j) & 0xFF)) { fwa_ok = false; break; }
                }
                fwa_rpos += fwa_rc;
            }

            // fs_stat: 9000-byte file
            uint fwa_size = 0;
            int fwa_type = -1;
            int fwa_st = fs_stat("wat.bin", &fwa_size, &fwa_type);
            bool fwa_stat_ok = fwa_st == 0 && fwa_size == (uint)FWA_N && fwa_type == 0;

            // mid-file overwrite at a non-aligned offset
            int fwa_ov = fs_write_at("wat.bin", "ZZZZ", 4, 5001);
            char[16] fwa_small @noinit;
            int fwa_ovr = fs_read_at("wat.bin", &fwa_small, 8, 4999);
            bool fwa_ov_ok = fwa_ov == 4 && fwa_ovr == 8
                && fwa_small[0] == (char)(4999 & 0xFF)   // unchanged
                && fwa_small[1] == (char)(5000 & 0xFF)   // unchanged
                && fwa_small[2] == 'Z' && fwa_small[3] == 'Z'
                && fwa_small[4] == 'Z' && fwa_small[5] == 'Z'
                && fwa_small[6] == (char)(5005 & 0xFF);  // unchanged

            // append via FS_OFFSET_APPEND
            int fwa_ap = fs_write_at("wat.bin", "TAIL", 4, FS_OFFSET_APPEND);
            uint fwa_size2 = 0;
            int fwa_st2 = fs_stat("wat.bin", &fwa_size2, null);
            int fwa_apr = fs_read_at("wat.bin", &fwa_small, 4, (uint)FWA_N);
            bool fwa_ap_ok = fwa_ap == 4 && fwa_st2 == 0 && fwa_size2 == (uint)(FWA_N + 4)
                && fwa_apr == 4
                && fwa_small[0] == 'T' && fwa_small[1] == 'A' && fwa_small[2] == 'I' && fwa_small[3] == 'L';

            // no holes: an offset well past the end must fail
            int fwa_hole = fs_write_at("wat.bin", "no", 2, 99999);

            // a write to an existing directory must fail
            int fwa_md = fs_mkdir("watdir");
            int fwa_wd = fs_write_at("watdir", "x", 1, 0);
            int fwa_rmd = fs_delete("watdir");

            int fwa_cleanup = fs_delete("wat.bin");

            if (fwa_ok && fwa_stat_ok && fwa_ov_ok && fwa_ap_ok
                && fwa_hole < 0 && fwa_md == 0 && fwa_wd < 0 && fwa_rmd == 0
                && fwa_cleanup == 0) {
                print("fswriteat: ok\n");
            } else {
                print("fswriteat: parts w="); print_uint((uint)(fwa_ok ? 1 : 0));
                print(" stat="); print_uint((uint)(fwa_stat_ok ? 1 : 0));
                print(" ov="); print_uint((uint)(fwa_ov_ok ? 1 : 0));
                print(" ap="); print_uint((uint)(fwa_ap_ok ? 1 : 0));
                print(" hole="); print_uint((uint)fwa_hole);
                print(" md="); print_uint((uint)fwa_md);
                print(" wd="); print_uint((uint)fwa_wd);
                print(" rmd="); print_uint((uint)fwa_rmd);
                print(" cl="); print_uint((uint)fwa_cleanup);
                print("\nfswriteat: FAILED\n");
            }
        } else if (strcmp(cmd, "fsneg") == 0) {
            // Negative-case consistency across the FS_* verbs — every one
            // of these must return -1 on all three backends (run via the
            // four launch64*.sh). Guards the "harden the fs ecosystem"
            // edges: empty path, missing file, wrong node type, name
            // collisions.
            int n_we = fs_write("", "x", 1);                 // empty path
            int n_wae = fs_write_at("", "x", 1, 0);          // empty path
            int n_de = fs_delete("");                        // empty path
            int n_rd = fs_read("ngnope.txt", &fsneg_scratch, 16);   // missing
            int n_rda = fs_read_at("ngnope.txt", &fsneg_scratch, 16, 0); // missing
            uint n_sz = 0; int n_ty = 0;
            int n_ste = fs_stat("ngnope.txt", &n_sz, &n_ty);        // missing

            int n_mk1 = fs_mkdir("ngdir");                   // ok (0)
            int n_mk2 = fs_mkdir("ngdir");                   // already exists -> -1
            int n_wd = fs_write("ngdir", "x", 1);           // write to a dir -> -1
            int n_wad = fs_write_at("ngdir", "x", 1, 0);    // write_at to a dir -> -1
            int n_ld = fs_stat("ngdir", &n_sz, &n_ty);      // ok, type 1
            bool n_dir_ok = n_ld == 0 && n_ty == 1;

            int n_cf = fs_write("ngf.txt", "hi", 2);        // ok (2)
            int n_lf = fs_list("ngf.txt", &fsneg_scratch, 4); // list a file -> -1
            int n_rnf = fs_rename("ngf.txt", "ngdir");      // dest exists -> -1
            int n_rmf = fs_delete("ngf.txt");               // ok (0)
            int n_rmd = fs_delete("ngdir");                 // ok (0)

            if (n_we < 0 && n_wae < 0 && n_de < 0 && n_rd < 0 && n_rda < 0
                && n_ste < 0 && n_mk1 == 0 && n_mk2 < 0 && n_wd < 0 && n_wad < 0
                && n_dir_ok && n_cf == 2 && n_lf < 0 && n_rnf < 0
                && n_rmf == 0 && n_rmd == 0) {
                print("fsneg: ok\n");
            } else {
                print("fsneg: FAILED\n");
            }
        } else if (strcmp(cmd, "fswriteatfrag") == 0) {
            // Interleaved growth of two files, 1000 bytes at a time,
            // alternating — so on exFAT each file's clusters end up
            // non-contiguous and exfat_grow_file_chain has to convert
            // the file from NoFatChain to a real FAT chain (the one
            // exfat_write_at path exfatgrow's directory test doesn't
            // reach). 10000 bytes each stays under ext2's 12-direct
            // cap, so this runs identically on all four launch scripts.
            // Then both files are read back and byte-compared; pattern
            // byte at position p of file k is (char)((p + k) & 0xFF).
            const int FRAG_N = 10000;
            char[1024] frg_chunk @noinit;
            bool frg_ok = true;
            int frg_pos = 0;
            while (frg_pos < FRAG_N && frg_ok) {
                int frg_c = FRAG_N - frg_pos;
                if (frg_c > 1000) frg_c = 1000;
                for (int frg_i = 0; frg_i < frg_c; frg_i++) {
                    frg_chunk[frg_i] = (char)((frg_pos + frg_i) & 0xFF);
                }
                if (fs_write_at("fragA.bin", &frg_chunk, frg_c, (uint)frg_pos) != frg_c) frg_ok = false;
                for (int frg_i = 0; frg_i < frg_c; frg_i++) {
                    frg_chunk[frg_i] = (char)((frg_pos + frg_i + 1) & 0xFF);
                }
                if (fs_write_at("fragB.bin", &frg_chunk, frg_c, (uint)frg_pos) != frg_c) frg_ok = false;
                frg_pos += frg_c;
            }

            for (int frg_k = 0; frg_k < 2 && frg_ok; frg_k++) {
                char* frg_name = frg_k == 0 ? "fragA.bin" : "fragB.bin";
                int frg_rp = 0;
                while (frg_rp < FRAG_N && frg_ok) {
                    int frg_rc = fs_read_at(frg_name, &frg_chunk, 1000, (uint)frg_rp);
                    if (frg_rc <= 0) { frg_ok = false; break; }
                    for (int frg_j = 0; frg_j < frg_rc; frg_j++) {
                        if (frg_chunk[frg_j] != (char)((frg_rp + frg_j + frg_k) & 0xFF)) { frg_ok = false; break; }
                    }
                    frg_rp += frg_rc;
                }
            }

            uint frg_sa = 0; uint frg_sb = 0;
            int frg_sta = fs_stat("fragA.bin", &frg_sa, null);
            int frg_stb = fs_stat("fragB.bin", &frg_sb, null);

            int frg_ca = fs_delete("fragA.bin");
            int frg_cb = fs_delete("fragB.bin");

            if (frg_ok && frg_sta == 0 && frg_sa == (uint)FRAG_N
                && frg_stb == 0 && frg_sb == (uint)FRAG_N
                && frg_ca == 0 && frg_cb == 0) {
                print("fswriteatfrag: ok\n");
            } else {
                print("fswriteatfrag: FAILED\n");
            }
        } else if (strcmp(cmd, "lfntest") == 0) {
            // Proves real VFAT long-filename (LFN) support in fat32.c3:
            // reading a name a real, external tool (mtools' mcopy, this
            // image's own build step) already wrote as a genuine LFN
            // chain, writing a brand-new long name from inside racccoon
            // itself (exercising fat32_prepare_new_entry's own alias
            // generation + LFN-chain write), and renaming one long name
            // to another (exercising fat32_rename's own LFN-aware
            // lookup/creation/chain-cleanup together). Hardcoded, real
            // space-containing names throughout — deliberately not
            // typed at the interactive shell's own prompt, since its
            // tokenizer splits on spaces with no quoting support at all
            // (a separate, known gap — see docs/devlog.md).
            //
            // "My Long File Name.txt" is a real fixture baked into
            // build/disk.img by scripts/build.sh itself (via mcopy,
            // which — being a real, independent VFAT implementation —
            // writes a genuine on-disk LFN chain, not anything this
            // driver produced itself); on ext2 (this file's own logic
            // never touches ext2.c3) it's absent, so this test simply
            // reports the read as failed there rather than asserting
            // anything about a fixture that was never seeded — the
            // write/rename side below still exercises real ext2 long
            // names fine either way, ext2 having never needed LFN
            // support to begin with.
            char[64] lfn_buf @noinit;
            int lfn_read_len = fs_read("My Long File Name.txt", &lfn_buf, 64);
            bool lfn_fixture_ok = true;
            if (lfn_read_len >= 0) {
                lfn_buf[lfn_read_len] = 0;
                lfn_fixture_ok = strcmp(&lfn_buf, "Hello from disk!\n") == 0;
            }

            char* lfn_new_name = "tmp/A Brand New Long Name Test.txt";
            char* lfn_new_content = "written with a real long name\n";
            int lfn_write_len = fs_write(lfn_new_name, lfn_new_content, 31);
            char[64] lfn_new_buf @noinit;
            int lfn_new_read_len = fs_read(lfn_new_name, &lfn_new_buf, 64);
            bool lfn_write_ok = false;
            if (lfn_new_read_len >= 0) {
                lfn_new_buf[lfn_new_read_len] = 0;
                lfn_write_ok = strcmp(&lfn_new_buf, lfn_new_content) == 0;
            }

            // fs_list's own truncated-for-display record — just confirms
            // *something* starting with the long name's own first 31
            // chars shows up, not a byte-exact match (see
            // FS_LIST_NAME_MAX's own truncation, user.c3).
            char[576] lfn_listbuf @noinit;
            int lfn_list_count = fs_list("tmp", &lfn_listbuf, 16);
            bool lfn_list_ok = false;
            for (int li = 0; li < lfn_list_count; li++) {
                char* rec = &lfn_listbuf[li * 36];
                if (rec[0] == 'A' && rec[1] == ' ' && rec[2] == 'B') { lfn_list_ok = true; }
            }

            char* lfn_renamed_name = "tmp/Yet Another Long Name.txt";
            int lfn_rename_result = fs_rename(lfn_new_name, lfn_renamed_name);
            int lfn_old_after_rename = fs_read(lfn_new_name, &lfn_new_buf, 64);
            int lfn_new_after_rename = fs_read(lfn_renamed_name, &lfn_new_buf, 64);

            int lfn_delete_result = fs_delete(lfn_renamed_name);
            int lfn_after_delete = fs_read(lfn_renamed_name, &lfn_new_buf, 64);

            if (lfn_fixture_ok && lfn_write_len == 31 && lfn_write_ok && lfn_list_ok
                && lfn_rename_result == 0 && lfn_old_after_rename < 0 && lfn_new_after_rename >= 0
                && lfn_delete_result == 0 && lfn_after_delete < 0) {
                print("lfntest: ok\n");
            } else {
                print("lfntest: FAILED (fixture_ok=");
                print(lfn_fixture_ok ? "1" : "0");
                print(" write_len=");
                print_uint((uint)(lfn_write_len < 0 ? 0 : lfn_write_len));
                print(" write_ok=");
                print(lfn_write_ok ? "1" : "0");
                print(" list_ok=");
                print(lfn_list_ok ? "1" : "0");
                print(" rename=");
                print_uint((uint)(lfn_rename_result < 0 ? 999 : (uint)lfn_rename_result));
                print(")\n");
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
        } else if (strcmp(cmd, "hardentest") == 0) {
            // Regression guard for src/page.c3's user_range_valid() and
            // its call sites in src/entry.c3: proves a syscall given a
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
            // Bare (root-mount) paths — NOT the old "/mnt/fs2/"-prefixed
            // form this test originally used. That prefix existed for a
            // real reason (see git history): the old topology could
            // have FAT32 and ext2 mounted simultaneously, and an
            // unprefixed path resolving through the "" catch-all might
            // land on whichever fsd was created first — FAT32 has no
            // uid concept, so a bare path could silently bypass ext2's
            // checks entirely. Entry 53's Plan9-style reorganization
            // removed that ambiguity structurally: "" now *always*
            // means ext2, everywhere real 9P work in this project
            // targets it (root is ext2-exclusive on real hardware, and
            // the first partition on every QEMU image that has one) —
            // the same reasoning p9fstest/p9fswritetest already rely
            // on. The old "/mnt/fs2/" prefix instead became entry 58's
            // own documented real-hardware gap: since entry 53, real
            // hardware never spawns a second fsd at all, so
            // "/mnt/fs2/" doesn't resolve to anything there, and every
            // call here failed at ns_resolve() *before* ever reaching
            // ext2's own permission checks — a false-looking "correctly
            // denied" that actually meant "unreachable". Root paths fix
            // that at the source: the exact same mount this test's
            // checks now exercise is genuinely reachable on every
            // topology this project tests against.
            fs_write("owner_only.txt", "root content", 12);
            // A real two-entry tree, not a bare empty dir — an empty
            // dir wouldn't exercise ext2_delete_dir_contents' own child
            // walk at all, so wouldn't actually prove recursive-delete
            // ownership enforcement (see ext2_delete_recursive's own
            // comment).
            fs_mkdir("owner_only_dir");
            fs_write("owner_only_dir/inner.txt", "root content", 12);

            uint fp_gen = 0;
            int fp_r = rfork(RFPROC, &fp_gen);
            if (fp_r < 0) {
                print("rfork failed\n");
            } else if (fp_r == 0) {
                int fp_su = setuid(42);
                print("fspermtest: setuid(42) ");
                print(fp_su == 0 ? "ok\n" : "FAILED\n");

                int fp_write1 = fs_write("owner_only.txt", "attacker content", 17);
                print("fspermtest: overwrite root-owned file as non-owner ");
                print(fp_write1 < 0 ? "correctly denied\n" : "WRONGLY succeeded\n");

                int fp_del1 = fs_delete("owner_only.txt");
                print("fspermtest: delete root-owned file as non-owner ");
                print(fp_del1 < 0 ? "correctly denied\n" : "WRONGLY succeeded\n");

                int fp_ren1 = fs_rename("owner_only.txt", "stolen.txt");
                print("fspermtest: rename root-owned file as non-owner ");
                print(fp_ren1 < 0 ? "correctly denied\n" : "WRONGLY succeeded\n");

                int fp_write2 = fs_write("attacker_owned.txt", "mine", 4);
                print("fspermtest: create own file ");
                print(fp_write2 >= 0 ? "ok\n" : "FAILED\n");

                int fp_write3 = fs_write("attacker_owned.txt", "mine still", 10);
                print("fspermtest: overwrite own file ");
                print(fp_write3 >= 0 ? "ok\n" : "FAILED\n");

                int fp_ren2 = fs_rename("attacker_owned.txt", "attacker_renamed.txt");
                print("fspermtest: rename own file ");
                print(fp_ren2 >= 0 ? "ok\n" : "FAILED\n");

                int fp_del2 = fs_delete("attacker_renamed.txt");
                print("fspermtest: delete own file ");
                print(fp_del2 >= 0 ? "ok\n" : "FAILED\n");

                int fp_delr1 = fs_delete_recursive("owner_only_dir");
                print("fspermtest: recursive-delete root-owned dir as non-owner ");
                print(fp_delr1 < 0 ? "correctly denied\n" : "WRONGLY succeeded\n");

                fs_mkdir("attacker_owned_dir");
                fs_write("attacker_owned_dir/inner.txt", "mine", 4);
                int fp_delr2 = fs_delete_recursive("attacker_owned_dir");
                print("fspermtest: recursive-delete own dir ");
                print(fp_delr2 >= 0 ? "ok\n" : "FAILED\n");

                exit();
            } else {
                join(fp_r, fp_gen);

                char[32] fp_readback @noinit;
                int fp_len = fs_read("owner_only.txt", &fp_readback, 32);
                if (fp_len >= 0) fp_readback[fp_len] = 0;
                bool fp_intact = fp_len == 12 && strcmp(&fp_readback, "root content") == 0;

                char[32] fp_dir_readback @noinit;
                int fp_dir_len = fs_read("owner_only_dir/inner.txt", &fp_dir_readback, 32);
                if (fp_dir_len >= 0) fp_dir_readback[fp_dir_len] = 0;
                bool fp_dir_intact = fp_dir_len == 12 && strcmp(&fp_dir_readback, "root content") == 0;

                int fp_write_root = fs_write("owner_only.txt", "root content v2", 16);
                int fp_del_root = fs_delete("owner_only.txt");
                // Root's own legitimate recursive-delete path, exercising
                // requester_uid == 0 still working unchanged through the
                // new checks — also this test's own cleanup.
                int fp_delr_root = fs_delete_recursive("owner_only_dir");

                if (fp_intact && fp_dir_intact && fp_write_root >= 0 && fp_del_root >= 0 && fp_delr_root >= 0) {
                    print("fspermtest: ok\n");
                } else {
                    print("fspermtest: FAILED\n");
                }
            }
        } else if (strcmp(cmd, "chmodtest") == 0) {
            // FS_CHMOD / FS_CHOWN against the ext2 root (user/fs/ext2.c3
            // ext2_chmod/ext2_chown, docs/roadmap.md §2). Root creates a
            // file, hands it to uid 42 with chown, then tightens it with
            // chmod; a uid-42 child proves owner-chmod works and that a
            // non-root chown is refused; a uid-43 child proves the
            // permission bits chmod wrote to disk are actually honored
            // by ext2_write_allowed (denied at 0600, allowed once root
            // opens it to 0666). Bare root paths, same reasoning as
            // fspermtest — "" always resolves to ext2.
            fs_write("cht.txt", "root", 4);
            int cm_own = fs_chown("cht.txt", 42);      // root: give it to 42
            int cm_mod = fs_chmod("cht.txt", 0o600);   // root: owner-only rw

            bool child42_ok = false;
            uint cm_g1 = 0;
            int cm_c1 = rfork(RFPROC, &cm_g1);
            if (cm_c1 == 0) {
                setuid(42);
                int w = fs_write("cht.txt", "mine!", 5);          // owns it, S_IWUSR -> ok
                int md = fs_chmod("cht.txt", 0o644);              // owner may chmod -> ok
                int ow = fs_chown("cht.txt", 99);                // non-root chown -> denied
                print("chmodtest: owner write "); print(w >= 0 ? "ok\n" : "FAILED\n");
                print("chmodtest: owner chmod "); print(md == 0 ? "ok\n" : "FAILED\n");
                print("chmodtest: non-root chown "); print(ow < 0 ? "correctly denied\n" : "WRONGLY succeeded\n");
                exit();
            } else if (cm_c1 > 0) {
                join(cm_c1, cm_g1);
                child42_ok = true;
            }

            fs_chmod("cht.txt", 0o600); // root: back to owner-only

            bool child43_denied = false;
            uint cm_g2 = 0;
            int cm_c2 = rfork(RFPROC, &cm_g2);
            if (cm_c2 == 0) {
                setuid(43);
                int w = fs_write("cht.txt", "hax", 3);            // not owner, no other-write -> denied
                int md = fs_chmod("cht.txt", 0o777);             // not owner -> denied
                print("chmodtest: other write at 0600 "); print(w < 0 ? "correctly denied\n" : "WRONGLY succeeded\n");
                print("chmodtest: non-owner chmod "); print(md < 0 ? "correctly denied\n" : "WRONGLY succeeded\n");
                exit();
            } else if (cm_c2 > 0) {
                join(cm_c2, cm_g2);
                child43_denied = true;
            }

            int cm_open = fs_chmod("cht.txt", 0o666); // root: allow other-write

            bool child43_allowed = false;
            uint cm_g3 = 0;
            int cm_c3 = rfork(RFPROC, &cm_g3);
            if (cm_c3 == 0) {
                setuid(43);
                int w = fs_write("cht.txt", "otherok", 7);        // other-write bit now set -> ok
                print("chmodtest: other write at 0666 "); print(w >= 0 ? "ok\n" : "FAILED\n");
                exit();
            } else if (cm_c3 > 0) {
                join(cm_c3, cm_g3);
                child43_allowed = true;
            }

            int cm_del = fs_delete("cht.txt"); // root cleanup

            if (cm_own == 0 && cm_mod == 0 && cm_open == 0 && cm_del >= 0
                && child42_ok && child43_denied && child43_allowed) {
                print("chmodtest: ok\n");
            } else {
                print("chmodtest: FAILED\n");
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
        } else if (strcmp(cmd, "hotplugtest") == 0) {
            // Proves ns_mount_wait() (src/entry.c3) genuinely closes the
            // gap mounttest above deliberately avoids: mounttest only
            // ever mounts something *already* posted well before the
            // command runs — this spawns a "late driver" child that
            // posts itself only after a real, unpredictable delay (a
            // genuine busy-loop — there's no sleep() syscall in user
            // mode), and races a real ns_mount_wait() call against it
            // from the parent, proving the wait actually blocks and
            // retries rather than just checking once. A second call
            // against a name nothing ever posts proves the give-up path
            // works too — it stops rather than hanging forever.
            //
            // ns_mount_wait's own third argument is a plain retry count,
            // not a wall-clock timeout — see its own comment
            // (src/entry.c3's SYS_NS_MOUNT_WAIT case) for the real bug
            // that drove that choice: a wall-clock version crashed here,
            // combining read_reg("time") with other locals surviving
            // across repeated calls inside a loop.
            const ulong HP_SUCCESS_MAX_ATTEMPTS = 200000; // generous — each attempt yields, giving the child real CPU time to finish its own delay
            const ulong HP_FAIL_MAX_ATTEMPTS = 20;         // small on purpose — this path exists to prove it gives up, not to spend real test time waiting

            uint hp_gen = 0;
            int hp_r = rfork(RFPROC, &hp_gen);
            if (hp_r < 0) {
                print("rfork failed\n");
            } else if (hp_r == 0) {
                for (uint hp_i = 0; hp_i < 5000000; hp_i++) { }
                srv_post("latesrv");
                // Blocks on a real message nobody will ever send, rather
                // than a bare for(;;){} spin — matches how a real driver
                // would actually idle (an eventual genuine I/O wait, not
                // a busy loop with zero syscalls), and, unlike a plain
                // spin, yields the CPU through the same safe,
                // blocking_depth-covered mechanism every other blocking
                // wait in this kernel already uses. A syscall-free spin
                // loop turned out to be a real design bug in this test,
                // not just an inconvenience: once blocking_depth's own
                // fix (src/entry.c3 / process.c3) correctly stops timer
                // interrupts from firing while any process is mid a
                // blocking wait, nothing would ever forcibly preempt a
                // child that never yields on its own — a genuine
                // deadlock, found directly by hitting it once this fix
                // landed.
                char[16] hp_child_buf @noinit;
                ipc_recv(&hp_child_buf, 16);
            } else {
                int hp_wait_ok = ns_mount_wait("/mnt/late/", "latesrv", HP_SUCCESS_MAX_ATTEMPTS);
                int hp_wait_fail = ns_mount_wait("/mnt/never/", "nope_never_posts", HP_FAIL_MAX_ATTEMPTS);
                int hp_killed = kill(hp_r, hp_gen);

                if (hp_wait_ok == 0 && hp_wait_fail < 0 && hp_killed == 0) {
                    print("hotplugtest: ok\n");
                } else {
                    print("hotplugtest: FAILED\n");
                }
            }
        } else if (strcmp(cmd, "fsdkilltest") == 0) {
            // Proves the boot-server supervisor (src/supervisor.c3,
            // docs/roadmap.md §5.2): kill fsd outright, then confirm it
            // comes back on its own and file reads work again — via the
            // healed namespace mount, without this process re-mounting
            // anything.
            // Probe with a file that exists on every image — QEMU
            // (build.sh) and the real Duo (populate_duo_bin.sh) both put
            // `bin/echod` at the root. `hello.txt` is a QEMU-only
            // fixture — reading it here made the test FAIL on the Duo
            // for want of the file, not any respawn fault.
            char[64] fk_buf @noinit;
            char* fk_probe = "bin/echod";
            int fk_before = fs_read(fk_probe, &fk_buf, 64);
            int fk_fsd = ns_resolve(fk_probe, null);
            int fk_killed = kill(fk_fsd, 0); // 0 = wildcard generation
            // Wait real wall-clock time (the supervisor ticks ~1/s from
            // the timer) and keep retrying the read. rdtime() the same
            // way mutextest/cycletest do — real time, not an insn count.
            ulong fk_deadline = rdtime() + timebase_hz() * 20; // 20s wall-clock, any board
            int fk_after = -1;
            while (fk_after < 0 && rdtime() < fk_deadline) {
                yield();
                fk_after = fs_read(fk_probe, &fk_buf, 64);
            }
            if (fk_before >= 0 && fk_killed == 0 && fk_after == fk_before) {
                print("fsdkilltest: ok (fsd killed, respawned, reads work)\n");
            } else {
                print("fsdkilltest: FAILED\n");
            }
        } else if (strcmp(cmd, "storagekilltest") == 0) {
            // Like fsdkilltest, one layer down: kill the block-storage
            // driver (diskd on QEMU / sdd on the Duo) and confirm the
            // supervisor re-inits it (SVC_KIND_DISKD/_SDD re-run the
            // MMIO+DMA setup) and fsd re-resolves its new pid on the
            // next read (user/fs/fsd.c3's diskd_rw). docs/roadmap.md §5.
            uint sk_part = 0;
            int  sk_pid  = 0;
            int sk_info = fs_partition_info(&sk_part, null, &sk_pid);
            char[64] sk_buf @noinit;
            char* sk_probe = "bin/echod";   // on every image (see fsdkilltest)
            int sk_before = fs_read(sk_probe, &sk_buf, 64);
            int sk_killed = sk_pid > 0 ? kill(sk_pid, 0) : -1;
            ulong sk_deadline = rdtime() + timebase_hz() * 20; // 20s wall-clock, any board
            int sk_after = -1;
            while (sk_after < 0 && rdtime() < sk_deadline) {
                yield();
                sk_after = fs_read(sk_probe, &sk_buf, 64);
            }
            if (sk_info == 0 && sk_pid > 0 && sk_before >= 0 && sk_killed == 0 && sk_after == sk_before) {
                print("storagekilltest: ok (storage driver killed, respawned, reads work)\n");
            } else {
                print("storagekilltest: FAILED\n");
            }
        } else if (strcmp(cmd, "wasmtest") == 0) {
            // /bin/wasm (roadmap §4): exec it on the add.wasm fixture
            // (seeded onto every disk image by build.sh). add.wasm's
            // _start computes 2+3 and calls racccoon.print_i32 -> the
            // console shows "5"; _start has no result so it exits 0.
            int wt_ok = 0;
            char*[10] wt_fx;
            wt_fx[0] = "add.wasm";     // -> "5"    (call + host import)
            wt_fx[1] = "mem.wasm";     // -> "142"  (linear memory + grow)
            wt_fx[2] = "loop.wasm";    // -> "55"   (block/loop/br/br_if)
            wt_fx[3] = "fac.wasm";     // -> "120"  (if/else + recursion)
            wt_fx[4] = "start.wasm";   // -> "123"  (SEC_START + mutable global + print_i64)
            wt_fx[5] = "echo.wasm";    // -> "a b"  (table + call_indirect + print_str + arg)
            wt_fx[6] = "float.wasm";   // -> "88"   (f64 sqrt/mul/floor/div + f32 mul + trunc)
            wt_fx[7] = "float2.wasm";  // -> "80"   (f64 neg/abs/min/max/copysign/convert/promote/gt)
            wt_fx[8] = "fib.wasm";     // -> "6765" (real Zig program: `fib.wasm 20`, i64 loop + arg)
            wt_fx[9] = "upper.wasm";   // -> "HI"   (real Zig program: `upper.wasm hi`, mem + print_str)
            for (int wf = 0; wf < 10; wf++) {
                char* wt_arg = wt_fx[wf];
                char*[3] wt_av;
                wt_av[0] = wt_arg; wt_av[1] = "a"; wt_av[2] = "b";
                if (wf == 8) { wt_av[1] = "20"; }
                if (wf == 9) { wt_av[1] = "hi"; }
                int wt_ac = (wf == 5) ? 3 : ((wf == 8 || wf == 9) ? 2 : 1);
                uint wt_gen = 0;
                int wt_c = rfork(RFPROC, &wt_gen);
                if (wt_c == 0) {
                    exec("bin/wasm", exec_buf(), exec_buf_max(), 0, &wt_av[0], wt_ac);
                    exitcode(127);
                }
                print("wasm "); print(wt_arg); print(" -> ");
                int wt_code = join(wt_c, wt_gen);
                if (wt_code != 0) { wt_ok = -1; }
            }
            print(wt_ok == 0 ? "wasmtest: ok\n" : "wasmtest: FAILED\n");
        } else if (strcmp(cmd, "gotest") == 0 || strcmp(cmd, "gostage2test") == 0 || strcmp(cmd, "gostage3test") == 0 || strcmp(cmd, "gostage35test") == 0 || strcmp(cmd, "gostage41test") == 0 || strcmp(cmd, "gostage42test") == 0) {
            // Go on racccoon (docs/go-port-plan.md). /bin/go-* are
            // GOOS=tamago static riscv64 binaries built by
            // scripts/build_go.sh from go/cmd/*, loaded through
            // SYS_EXEC's ELF path. Same rfork -> exec -> join(code) shape
            // as wasmtest; skip cleanly (exit 127) if the binary isn't on
            // this image — they only exist when TAMAGO was set at build
            // time, same as tcctest without /bin/tcc.
            //
            //   gotest       — go/cmd/hello: println, int/float math,
            //                  slice+append, map, defer, panic/recover.
            //                  A clean exit 0 means the whole Go runtime
            //                  came up on the racccoon goos provider
            //                  (go/goos/): SYS_MAP heap arena + stack
            //                  (CPUInit), the scheduler, GC-managed
            //                  allocation, and goos.Exit -> SYS_EXIT.
            //   gostage2test — go/cmd/gostage2: the runtime under load —
            //                  the GC cycling through ~48 MiB of garbage,
            //                  200 goroutines + channels + WaitGroup +
            //                  mutex, and the timer path (time.Sleep /
            //                  Ticker). Slow (spin-idle scheduler + real
            //                  GC on emulated hw).
            //   gostage3test — go/cmd/gostage3: real file I/O against fsd
            //                  via the go/racccoon package (SYS_NS_RESOLVE
            //                  + SYS_IPC_CALL, the FS_* verbs) — read a
            //                  fixture, walk a paginated directory, write
            //                  + read back + rename + remove under /tmp,
            //                  build a directory tree. e2fsck must be
            //                  clean after.
            //   gostage35test — go/cmd/gostage35: the *standard* os
            //                  package (os.Open / ReadFile / ReadDir /
            //                  Create / Rename / Getwd / RemoveAll,
            //                  os.IsNotExist) routed to fsd through
            //                  runtime/goos.FS — the go/racccoon blank
            //                  import + lib/go/racccoon.patch. e2fsck
            //                  clean after.
            //   gostage41test — go/cmd/gostage41: os/exec (rfork+SYS_EXEC
            //                  + SYS_JOIN via runtime/goos.Spawn/Wait) —
            //                  runs /bin/echo, /bin/false (exit code
            //                  propagates), a missing command, and
            //                  another Go binary spawned from Go, all
            //                  with the child inheriting the console.
            //   gostage42test — go/cmd/gostage42: os/exec OUTPUT CAPTURE
            //                  (exec.Cmd.Output / CombinedOutput / a
            //                  bytes.Buffer Stdout) — the child's stdout
            //                  is wired to a kernel pipe by rfork (a2),
            //                  drained by goos.Spawn. Includes a 22 KiB
            //                  capture past the 4 KiB pipe buffer
            //                  (/bin/go-spew) and a console-inherit
            //                  regression check.
            //
            // The program prints to the console directly (goos.Printk ->
            // SYS_PUTCHAR) so its output shows inline above the verdict.
            char* gt_path;
            char* gt_name;
            if (strcmp(cmd, "gostage2test") == 0) {
                gt_path = "bin/go-gostage2"; gt_name = "gostage2test";
            } else if (strcmp(cmd, "gostage3test") == 0) {
                gt_path = "bin/go-gostage3"; gt_name = "gostage3test";
            } else if (strcmp(cmd, "gostage35test") == 0) {
                gt_path = "bin/go-gostage35"; gt_name = "gostage35test";
            } else if (strcmp(cmd, "gostage41test") == 0) {
                gt_path = "bin/go-gostage41"; gt_name = "gostage41test";
            } else if (strcmp(cmd, "gostage42test") == 0) {
                gt_path = "bin/go-gostage42"; gt_name = "gostage42test";
            } else {
                gt_path = "bin/go-hello"; gt_name = "gotest";
            }
            // gostage35test also checks os.Args — pass it two.
            char*[2] gt_av;
            gt_av[0] = "alpha"; gt_av[1] = "beta";
            bool gt_s35 = strcmp(cmd, "gostage35test") == 0;
            uint gt_gen = 0;
            int gt_c = rfork(RFPROC, &gt_gen);
            if (gt_c < 0) {
                print("rfork failed\n");
            } else if (gt_c == 0) {
                if (gt_s35) {
                    exec(gt_path, exec_buf(), exec_buf_max(), 0, &gt_av[0], 2);
                } else {
                    exec(gt_path, exec_buf(), exec_buf_max(), 0, null, 0);
                }
                exitcode(127);
            } else {
                int gt_code = join(gt_c, gt_gen);
                print(gt_name);
                if (gt_code == 127) {
                    print(": skipped (no ");
                    print(gt_path);
                    print(" — build with TAMAGO set)\n");
                } else if (gt_code == 0) {
                    print(": ok\n");
                } else {
                    char[16] gt_cs @noinit;
                    int gt_d = fmt::format_uint((uint)gt_code, &gt_cs[0]);
                    gt_cs[gt_d] = 0;
                    print(": FAILED (exit ");
                    print(&gt_cs[0]);
                    print(")\n");
                }
            }
        } else if (strcmp(cmd, "goversiontest") == 0) {
            // Stage 4.4 (docs/go-port-plan.md): the `go` command itself
            // runs on racccoon. `go version` + `go env GOROOT` — the
            // cheap check, no $GOROOT/src needed. `go build` is
            // gobuildtest below. Slow (a ~14 MiB binary off fsd, twice)
            // — not in the quick sweep. Skips cleanly without /bin/go.
            uint gv_size = 0; int gv_type = 0;
            if (fs_stat("/bin/go", &gv_size, &gv_type) < 0) {
                print("goversiontest: skipped (no /bin/go — build with TAMAGO set)\n");
            } else {
                char*[1] gv_ver_av; gv_ver_av[0] = "version";
                uint gv_g1 = 0;
                int gv_c1 = rfork(RFPROC, &gv_g1);
                if (gv_c1 == 0) { exec("/bin/go", exec_buf(), exec_buf_max(), 0, &gv_ver_av[0], 1); exitcode(127); }
                int gv_rc1 = join(gv_c1, gv_g1);

                char*[2] gv_env_av; gv_env_av[0] = "env"; gv_env_av[1] = "GOROOT";
                uint gv_g2 = 0;
                int gv_c2 = rfork(RFPROC, &gv_g2);
                if (gv_c2 == 0) { exec("/bin/go", exec_buf(), exec_buf_max(), 0, &gv_env_av[0], 2); exitcode(127); }
                int gv_rc2 = join(gv_c2, gv_g2);

                if (gv_rc1 == 0 && gv_rc2 == 0) {
                    print("goversiontest: ok\n");
                } else {
                    print("goversiontest: FAILED (version exit "); print_uint((uint)gv_rc1);
                    print(", env exit "); print_uint((uint)gv_rc2); print(")\n");
                }
            }
        } else if (strcmp(cmd, "gobuildtest") == 0) {
            // Stage 4.4 (docs/go-port-plan.md): `go build` on racccoon.
            // `cd /gomod` (a one-file module seeded by build.sh),
            // `/bin/go build -o /tmp/gbt .`, then run /tmp/gbt and check
            // it printed the expected line. The stdlib closure comes
            // from the prepopulated /gocache (a host build with the same
            // cross-toolchain — content-addressed cache keys match), so
            // only runtime / runtime/goos / main compile on-device;
            // cmd/link defaults -T/-R for tamago so the output loads.
            // VERY slow — a fresh QEMU boot plus the on-device compiles
            // and link, several minutes. Not in the quick sweep.
            uint gb_sz = 0; int gb_ty = 0;
            if (fs_stat("/gomod/go.mod", &gb_sz, &gb_ty) < 0) {
                print("gobuildtest: skipped (no /gomod — build with TAMAGO set)\n");
            } else {
                fs_delete("/tmp/gbt");
                if (chdir("/gomod") != 0) { print("gobuildtest: chdir /gomod failed\n"); }
                char*[4] gb_av4;
                gb_av4[0] = "build"; gb_av4[1] = "-o"; gb_av4[2] = "/tmp/gbt"; gb_av4[3] = ".";
                uint gb_g1 = 0;
                int gb_c1 = rfork(RFPROC, &gb_g1);
                if (gb_c1 == 0) { exec("/bin/go", exec_buf(), exec_buf_max(), 0, &gb_av4[0], 4); exitcode(127); }
                int gb_rc1 = join(gb_c1, gb_g1);
                chdir("/");

                if (gb_rc1 != 0) {
                    print("gobuildtest: FAILED (go build exit "); print_uint((uint)gb_rc1); print(")\n");
                } else {
                    uint gb_o = 0; int gb_ot = 0;
                    if (fs_stat("/tmp/gbt", &gb_o, &gb_ot) < 0) {
                        print("gobuildtest: FAILED (no /tmp/gbt produced)\n");
                    } else {
                        uint gb_g2 = 0;
                        int gb_c2 = rfork(RFPROC, &gb_g2);
                        if (gb_c2 == 0) { exec("/tmp/gbt", exec_buf(), exec_buf_max(), 0, null, 0); exitcode(127); }
                        int gb_rc2 = join(gb_c2, gb_g2);
                        print(gb_rc2 == 0
                            ? "gobuildtest: ok (go build produced a working binary)\n"
                            : "gobuildtest: FAILED (built binary exit != 0)\n");
                    }
                }
            }
        } else if (strcmp(cmd, "gotoolchaintest") == 0) {
            // Stage 4.3 (docs/go-port-plan.md) — racccoon's OWN go tool
            // compile + go tool link, running natively on racccoon,
            // build go/cmd/hello's real source (importing "runtime" and
            // its ~27 transitive internal/* deps — a real stdlib closure,
            // not the import-free case gotest's binary already covers)
            // into a working ELF, then run it. Closes the self-hosting
            // loop: a binary racccoon's own toolchain produced, running
            // on racccoon, whose output must match Stage 1's
            // host-cross-compiled /bin/go-hello byte for byte.
            //
            // Needs /lib/go/{importcfg,importcfg.link,pkg/*.a} + /hello.go
            // (build_go_toolchain.sh, seeded onto disk_ext2.img by
            // build.sh — gated on TAMAGO like the rest of the Go port,
            // and only on the 256 MiB ext2 image: go-compile (~22 MiB) +
            // go-link (~6 MiB) + the ~15 MiB closure don't fit the small
            // FAT32/dual images). Skips cleanly if they're not there.
            // Slow (minutes — a fresh QEMU boot, ~30 MB of toolchain
            // binary loaded off fsd 1124 bytes/IPC-RTT, twice, plus the
            // ~15 MiB closure at link time) — not part of the quick
            // regression sweep, run on demand.
            uint gtc_size = 0; int gtc_type = 0;
            if (fs_stat("/lib/go/importcfg", &gtc_size, &gtc_type) < 0) {
                print("gotoolchaintest: skipped (no /lib/go/importcfg — build with TAMAGO set)\n");
            } else {
                fs_delete("/tmp/hello.o");
                fs_delete("/tmp/hello.elf");

                char*[8] gtc_cc_av;
                gtc_cc_av[0] = "-o"; gtc_cc_av[1] = "/tmp/hello.o"; gtc_cc_av[2] = "-p"; gtc_cc_av[3] = "main";
                gtc_cc_av[4] = "-complete"; gtc_cc_av[5] = "-importcfg"; gtc_cc_av[6] = "/lib/go/importcfg";
                gtc_cc_av[7] = "-pack"; // archive format — matches what importcfg.link expects a packagefile to be
                // "/hello.go" itself is a 9th arg the fixed-size array
                // above doesn't have room for cleanly — appended via a
                // second exec() argv slot instead, so the array stays a
                // single literal.
                char*[9] gtc_cc_full;
                for (int gi = 0; gi < 8; gi++) { gtc_cc_full[gi] = gtc_cc_av[gi]; }
                gtc_cc_full[8] = "/hello.go";

                uint gtc_g1 = 0;
                int gtc_c1 = rfork(RFPROC, &gtc_g1);
                if (gtc_c1 == 0) {
                    exec("bin/go-compile", exec_buf(), exec_buf_max(), 0, &gtc_cc_full[0], 9);
                    exitcode(127);
                }
                int gtc_compile_rc = join(gtc_c1, gtc_g1);

                if (gtc_compile_rc != 0) {
                    print("gotoolchaintest: FAILED (go-compile exit "); print_uint((uint)gtc_compile_rc); print(")\n");
                } else {
                    // -T/-R match scripts/build_go.sh's own link flags —
                    // every PT_LOAD must land inside [USER_BASE,
                    // USER_BASE+EXEC_MAX_IMAGE_SIZE); go-link's default
                    // link address is nowhere near there.
                    char*[9] gtc_ln_av;
                    gtc_ln_av[0] = "-o"; gtc_ln_av[1] = "/tmp/hello.elf"; gtc_ln_av[2] = "-importcfg";
                    gtc_ln_av[3] = "/lib/go/importcfg.link"; gtc_ln_av[4] = "-buildmode=exe";
                    gtc_ln_av[5] = "-T"; gtc_ln_av[6] = "0x1010000"; gtc_ln_av[7] = "-R";
                    gtc_ln_av[8] = "0x1000";
                    char*[10] gtc_ln_full;
                    for (int gj = 0; gj < 9; gj++) { gtc_ln_full[gj] = gtc_ln_av[gj]; }
                    gtc_ln_full[9] = "/tmp/hello.o";
                    uint gtc_g2 = 0;
                    int gtc_c2 = rfork(RFPROC, &gtc_g2);
                    if (gtc_c2 == 0) {
                        exec("bin/go-link", exec_buf(), exec_buf_max(), 0, &gtc_ln_full[0], 10);
                        exitcode(127);
                    }
                    int gtc_link_rc = join(gtc_c2, gtc_g2);

                    if (gtc_link_rc != 0) {
                        print("gotoolchaintest: FAILED (go-link exit "); print_uint((uint)gtc_link_rc); print(")\n");
                    } else {
                        uint gtc_g3 = 0;
                        int gtc_c3 = rfork(RFPROC, &gtc_g3);
                        if (gtc_c3 == 0) {
                            exec("/tmp/hello.elf", exec_buf(), exec_buf_max(), 0, null, 0);
                            exitcode(127);
                        }
                        int gtc_run_rc = join(gtc_c3, gtc_g3);
                        print(gtc_run_rc == 0 ? "gotoolchaintest: ok\n" : "gotoolchaintest: FAILED (linked binary exit != 0)\n");
                    }
                }
                fs_delete("/tmp/hello.o");
                fs_delete("/tmp/hello.elf");
            }
        } else if (strcmp(cmd, "tcctest") == 0) {
            // roadmap §7: /bin/tcc compiles + links /hello.c into a
            // runnable binary. Skips cleanly if tcc isn't on this image
            // (no third_party/tinycc submodule -> seed_tcc.sh no-op).
            char*[3] tt_cc_av;
            tt_cc_av[0] = "/hello.c"; tt_cc_av[1] = "-o"; tt_cc_av[2] = "/tcctmp";
            uint tt_g1 = 0;
            int tt_c1 = rfork(RFPROC, &tt_g1);
            if (tt_c1 == 0) {
                exec("bin/tcc", exec_buf(), exec_buf_max(), 0, &tt_cc_av[0], 3);
                exitcode(127);
            }
            int tt_cc = join(tt_c1, tt_g1);
            if (tt_cc == 127) {
                print("tcctest: skipped (no /bin/tcc)\n");
            } else if (tt_cc != 0) {
                print("tcctest: FAILED (tcc exit ");
                print_uint((uint)tt_cc);
                print(")\n");
            } else {
                char*[1] tt_run_av;
                tt_run_av[0] = "x";
                uint tt_g2 = 0;
                int tt_c2 = rfork(RFPROC, &tt_g2);
                if (tt_c2 == 0) {
                    exec("/tcctmp", exec_buf(), exec_buf_max(), 0, &tt_run_av[0], 1);
                    exitcode(127);
                }
                int tt_run = join(tt_c2, tt_g2);
                fs_delete("/tcctmp");
                print(tt_run == 0 ? "tcctest: ok\n" : "tcctest: FAILED (compiled binary exit != 0)\n");
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
            bool oom_pressure = oom_rfork_refused || oom_probe_killed;
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
                int ft_alive = fs_read("bin/echod", &ft_probe, 8); // shell still works?
                if (ft_code != 0 && ft_alive >= 0) {
                    print("faulttest: ok (faulting child killed, kernel + shell fine)\n");
                } else {
                    print("faulttest: FAILED code="); print_uint((uint)ft_code);
                    print(" alive="); print_uint((uint)(ft_alive >= 0)); putchar('\n');
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
        } else if (strcmp(cmd, "netdkilltest") == 0) {
            // The storage driver's supervisor path (storagekilltest),
            // one driver over: kill netd and confirm the supervisor
            // re-inits it (SVC_KIND_NETD -> setup_netd_mappings) and the
            // namespace reseat points "/net/" back at the fresh pid.
            if (ns_mount("/net/", "netd") < 0) {
                print("netdkilltest: FAILED (netd not posted)\n");
            } else {
                uint nk_m = 0;
                int nk_pid = ns_resolve("/net/", &nk_m);
                int nk_killed = nk_pid > 0 ? kill(nk_pid, 0) : -1;
                int nk_ok = -1;
                ulong nk_deadline = rdtime() + timebase_hz() * 20; // 20s wall-clock, any board
                while (nk_ok < 0 && rdtime() < nk_deadline) {
                    yield();
                    uint m = 0;
                    int np = ns_resolve("/net/", &m);
                    // m == 5 ("/net/") means it resolved to the netd
                    // mount, reseated to the live respawn — not the ""
                    // catch-all it falls to while netd is down.
                    if (np > 0 && m == 5) {
                        uint g = 0;
                        if (proc_info(np, null, &g, null) == 0) nk_ok = 0;
                    }
                }
                if (nk_pid > 0 && nk_killed == 0 && nk_ok == 0) {
                    print("netdkilltest: ok (netd killed, respawned, /net/ reseated)\n");
                } else {
                    print("netdkilltest: FAILED\n");
                }
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
            // peer dies mid-transfer (src/entry.c3 sys_exit /
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
        } else if (strcmp(cmd, "gpiodkilltest") == 0) {
            // §5.5, Duo-only: gpiod isn't spawned on QEMU (no GPIO
            // controller on the virt board). Kill it, let the supervisor
            // respawn it (SVC_KIND_GPIOD -> setup_gpiod_mappings re-maps
            // bank A/C + the pinmux page), then send a real SET_DIR to
            // confirm the fresh gpiod re-mapped its MMIO, rebuilt its pin
            // table, and services IPC.
            //
            // Guards: (a) only accept a pid that resolved *through the
            // /srv/gpiod/ mount* (prefix length 11) — between the kill
            // and the respawn, /srv/gpiod/ falls to the "" catch-all
            // (fsd); (b) require a *different generation* than the
            // instance we killed — a respawn reuses the same slot, hence
            // the same pid (pid = slot + 1), so "np != old pid" never
            // fires. Same m-guard netdkilltest uses (m == 5 for "/net/").
            if (ns_mount_wait("/srv/gpiod/", "gpiod", 5) < 0) {
                print("gpiodkilltest: skipped (no gpiod — not a Duo?)\n");
            } else {
                uint gk_m = 0;
                int gk_old = ns_resolve("/srv/gpiod/", &gk_m);
                uint gk_old_gen = 0;
                if (gk_old > 0) { proc_info(gk_old, null, &gk_old_gen, null); }
                int gk_killed = gk_old > 0 ? kill(gk_old, 0) : -1;
                int gk_new = -1;
                ulong gk_deadline = rdtime() + timebase_hz() * 20; // 20s wall-clock, any board
                while (gk_new < 0 && rdtime() < gk_deadline) {
                    yield();
                    ns_mount("/srv/gpiod/", "gpiod");   // re-point at the fresh post
                    uint m = 0;
                    int np = ns_resolve("/srv/gpiod/", &m);
                    if (np > 0 && m == 11) {
                        uint g = 0;
                        if (proc_info(np, null, &g, null) == 0 && g != gk_old_gen) { gk_new = np; }
                    }
                }
                int gk_resp = -1;
                if (gk_new > 0) {
                    char[8] gk_req @noinit;
                    gk_req[0] = 'C'; gk_req[1] = (char)24; gk_req[2] = (char)1; // GPIOC24 dir=out
                    uint gk_rv = 0;
                    int gk_from = p9_call_path("/srv/gpiod/", 1 /*GPIO_IPC_SET_DIR*/, &gk_req[0], 8, &gk_req[0], 8, &gk_rv);
                    if (gk_from > 0 && gk_rv == 1 && gk_req[0] == 0) { gk_resp = 0; }
                }
                if (gk_killed == 0 && gk_new > 0 && gk_resp == 0) {
                    print("gpiodkilltest: ok (gpiod killed, respawned, re-inited, C24 dir set)\n");
                } else if (gk_killed == 0 && gk_new > 0) {
                    print("gpiodkilltest: FAILED — respawned + re-posted, but SET_DIR got no valid reply (hw re-init? §5.5)\n");
                } else {
                    print("gpiodkilltest: FAILED — no respawn seen within the deadline\n");
                }
            }
        } else if (strcmp(cmd, "usbdkilltest") == 0) {
            // §5.5, Duo-only: usbd isn't spawned on QEMU. Kill it, let
            // the supervisor respawn it (SVC_KIND_USBD ->
            // setup_usbd_mappings re-maps the DWC2 MMIO + DMA ring), and
            // confirm the fresh usbd came back and re-posted /srv/usbd/.
            // A full HID re-enumeration check needs a device on the bus
            // and a keystroke — this covers the respawn + MMIO re-map +
            // srv_post half, which is what the supervisor path owns.
            // Guards: resolved through /srv/usbd/ (prefix len 10) AND a
            // different generation than the killed instance (a respawn
            // reuses the slot -> same pid). Same shape as gpiodkilltest.
            if (ns_mount_wait("/srv/usbd/", "usbd", 5) < 0) {
                print("usbdkilltest: skipped (no usbd — not a Duo?)\n");
            } else {
                uint uk_m = 0;
                int uk_old = ns_resolve("/srv/usbd/", &uk_m);
                uint uk_old_gen = 0;
                if (uk_old > 0) { proc_info(uk_old, null, &uk_old_gen, null); }
                int uk_killed = uk_old > 0 ? kill(uk_old, 0) : -1;
                int uk_new = -1;
                ulong uk_deadline = rdtime() + timebase_hz() * 20; // 20s wall-clock, any board
                while (uk_new < 0 && rdtime() < uk_deadline) {
                    yield();
                    ns_mount("/srv/usbd/", "usbd");
                    uint m = 0;
                    int np = ns_resolve("/srv/usbd/", &m);
                    if (np > 0 && m == 10) {
                        uint g = 0;
                        if (proc_info(np, null, &g, null) == 0 && g != uk_old_gen) { uk_new = np; }
                    }
                }
                if (uk_killed == 0 && uk_new > 0) {
                    print("usbdkilltest: ok (usbd killed, respawned, /srv/usbd/ re-posted)\n");
                    print("  now press a key — if it echoes, HID re-enum works too\n");
                } else {
                    print("usbdkilltest: FAILED\n");
                }
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
        } else if (strcmp(cmd, "loud") == 0) {
            // Re-enable boot-server console output (undoes the settle-time
            // boot_quiet()). For watching a *respawned* server's init
            // chatter — e.g. `loud` then `storagekilltest` to see the
            // respawned sdd's own CMD0/CMD8/ACMD41 enumeration prints.
            boot_loud();
            print("boot-server output re-enabled\n");
        } else if (strcmp(cmd, "kbdpush") == 0) {
            // Stage-3 smoke test for the kernel keystroke queue
            // (src/kbd.c3): push a few bytes through SYS_KBD_PUSH and
            // watch them turn up at the next prompt exactly as if typed.
            // No USB needed — this is the QEMU-side proof of the
            // SYS_KBD_PUSH -> SYS_GETCHAR path that user/usb/kbd.c3
            // feeds on real hardware.
            char* kbdpush_str = "kbd-queue-works";
            int kbdpush_n = 0;
            for (int k = 0; kbdpush_str[k] != 0; k++) {
                if (syscall(SYS_KBD_PUSH, (long)kbdpush_str[k], 0, 0) == 0) { kbdpush_n++; }
            }
            print("kbdpush: queued ");
            print_uint((uint)kbdpush_n);
            print(" bytes — they should appear on the next prompt line\n");
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
            // Not a dev/test builtin: hand the raw line to the real
            // executor — `;` / `&&` / `||` sequencing, then per-pipeline
            // `$var` expansion + `|` / `<` / `>` / `>>`, else just
            // shell_dispatch_common || the /bin fallback (see
            // shell_exec_line, user/shell_common.c3).
            shell_exec_line(&cmdline[0]);
        }
    }
}
