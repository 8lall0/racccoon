module user;

import std::nolibc::fmt;

// shell_test builtins — filesystem: fsd backends (FAT32/ext2/exFAT),
// offsets, permissions, mounts, hotplug. Split out of shell_test.c3's
// main(), which tries each shell_test_*_dispatch in turn; true = cmd was
// one of these.

// bigreadtest's own receive buffer (below) — a global, not a local:
// 300000 bytes is well past what this process's own stack (STACK_SIZE,
// src/process.c3) could hold. Sized to exactly match BIGFILE_SIZE, the
// fixture size scripts/build.sh seeds bigfile.bin at. (The exec buffer
// next to it used to be a static too; it's SYS_MAP'd now — exec_buf(),
// user/shell_common.c3.)
const int BIGFILE_SIZE = 300000;
char[BIGFILE_SIZE] bigread_buf;


// exfatgrow's listing buffer — global for the same stack-budget reason
// bigread_buf above is (FS_LIST_ENTRY_SIZE * a generous entry count).
char[40 * 36] exfatgrow_listbuf;

// fsneg's throwaway read/list target — nothing reads it back, it just
// needs to be a valid buffer for the calls that are expected to fail.
char[64] fsneg_scratch;

fn bool shell_test_fs_dispatch(char* cmd, char** cmd_argv, int cmd_argc) {
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
    } else if (strcmp(cmd, "fscachestat") == 0) {
        // fsd sector read cache (user/fs/fsd.c3). Prints the running
        // hit/miss counters; run it before and after a read-heavy
        // command (a Go build, cat of a big file) to see the effect.
        ulong fc_hits = 0; ulong fc_misses = 0;
        if (fs_cache_stats(&fc_hits, &fc_misses) != 0) {
            print("fscachestat: FAILED (fsd didn't answer)\n");
        } else {
            ulong fc_total = fc_hits + fc_misses;
            print("fscachestat: "); print_uint((uint)fc_hits); print(" hit / ");
            print_uint((uint)fc_misses); print(" miss");
            if (fc_total > 0) {
                print(" ("); print_uint((uint)((fc_hits * 100) / fc_total)); print("% hit)");
            }
            putchar('\n');
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
        if (test_skip_unless_ext2_root("fspermtest", "FAT32/exFAT keep no uid/mode")) return true;
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
        // actually gone, src/syscalls.c3's SYS_JOIN) is exactly the
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
        if (test_skip_unless_ext2_root("chmodtest", "FAT32/exFAT keep no uid/mode")) return true;
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
        // Proves srv_post()/ns_mount()/ns_unmount() (src/syscalls.c3)
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
        // Proves ns_mount_wait() (src/syscalls.c3) genuinely closes the
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
        // (src/syscalls.c3's SYS_NS_MOUNT_WAIT case) for the real bug
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
            // fix (src/entry.c3 / syscalls.c3 / process.c3) correctly stops timer
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
    } else {
        return false;
    }
    return true;
}
