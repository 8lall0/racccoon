module user;

import std::nolibc::fmt;

// shell_test builtins — language runtimes / toolchains on racccoon:
// wasm, c3 std::io, Go, tcc, C++, LLVM. Split out of shell_test.c3's
// main(), which tries each shell_test_*_dispatch in turn; true = cmd was
// one of these.

// Runs `path` (argv = the real arguments) in a child whose stdout is a
// pipe, echoes what it prints and keeps the first cap-1 bytes in `out`,
// NUL-terminated. Returns the exit code; 127 = it couldn't be exec'd.
fn int lang_run_captured(char* path, char** argv, int argc, char* out, int cap) {
    int p = pipe_new();
    pipe_hold(p, 0, 1);   // a reader from the start, so no write is dropped
    uint g = 0;
    int c = rfork_io(RFPROC, &g, p, -1);
    if (c == 0) {
        exec(path, exec_buf(), exec_buf_max(), 0, argv, argc);
        exitcode(127);
    }
    int n = 0;
    for (;;) {
        char[128] chunk;
        int got = pipe_read(p, &chunk, 128);
        if (got <= 0) { break; }
        for (int i = 0; i < got; i++) {
            putchar(chunk[i]);
            if (n < cap - 1) { out[n] = chunk[i]; n++; }
        }
    }
    out[n] = 0;
    pipe_hold(p, 0, -1);
    return join(c, g);
}

// lang_run_captured for a whole command line ("bin/clang -c x.c …"):
// split on spaces (no quoting) into a copy, word 0 is the program.
fn int lang_run_line(char* line, char* out, int cap) {
    char[1024] lb;
    int n = 0;
    while (line[n] != 0 && n < 1023) { lb[n] = line[n]; n++; }
    lb[n] = 0;
    char*[48] av;
    int ac = 0;
    int i = 0;
    while (lb[i] != 0 && ac < 48) {
        while (lb[i] == ' ') { lb[i] = 0; i++; }
        if (lb[i] == 0) { break; }
        av[ac] = &lb[i];
        ac++;
        while (lb[i] != 0 && lb[i] != ' ') { i++; }
    }
    if (ac == 0) { return -1; }
    return lang_run_captured(av[0], &av[1], ac - 1, out, cap);
}

// Byte-compares two files: their common length if identical, -1 if they
// differ (in content or size) or either can't be read.
fn int lang_same_file(char* a, char* b) {
    uint off = 0;
    char[1024] ba;
    char[1024] bb;
    for (;;) {
        int na = fs_read_at(a, &ba, 1024, off);
        int nb = fs_read_at(b, &bb, 1024, off);
        if (na != nb || na < 0) { return -1; }
        if (na == 0) { return (int)off; }
        for (int i = 0; i < na; i++) {
            if (ba[i] != bb[i]) { return -1; }
        }
        off += (uint)na;
    }
}

// True if NUL-terminated `hay` contains `needle`.
fn bool lang_has_text(char* hay, char* needle) {
    for (int i = 0; hay[i] != 0; i++) {
        int k = 0;
        while (needle[k] != 0 && hay[i + k] == needle[k]) { k++; }
        if (needle[k] == 0) { return true; }
    }
    return false;
}

fn bool shell_test_lang_dispatch(char* cmd, char** cmd_argv, int cmd_argc) {
    if (strcmp(cmd, "wasmtest") == 0) {
        // /bin/wasm (roadmap §4): exec it on the add.wasm fixture
        // (seeded onto every disk image by build.sh). add.wasm's
        // _start computes 2+3 and calls racccoon.print_i32 -> the
        // console shows "5"; _start has no result so it exits 0.
        int wt_ok = 0;
        char*[14] wt_fx;
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
        wt_fx[10] = "bulkmem.wasm"; // -> "367" (overlapping memory.copy + memory.fill, §4 bulk-memory)
        wt_fx[11] = "datainit.wasm"; // -> "156" (passive data seg: memory.init + data.drop)
        wt_fx[12] = "tableinit.wasm"; // -> "99" (passive elem seg: table.init + elem.drop + table.copy)
        wt_fx[13] = "tablegrowfill.wasm"; // -> "118" (table.size + table.grow + table.fill)
        for (int wf = 0; wf < 14; wf++) {
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
    } else if (strcmp(cmd, "wasitest") == 0) {
        // /bin/wasm's WASI preview1 shim: standard C programs built with
        // `zig cc -target wasm32-wasi` (test/wasm-src/*.c, wasi-libc) —
        // no racccoon-specific code in them. Each fixture checks itself
        // and exits 0, or the number of the check that failed (wasi_exit:
        // exactly 7, via exit() -> proc_exit). wasi_hello also reads
        // WASITEST from the environment (environ_get over /env), set here.
        fs_write("/env/WASITEST", "hello", 5);
        char*[5] wi_fx;
        wi_fx[0] = "wasi_hello.wasm";  // printf, argv, environ, signed bytes
        wi_fx[1] = "wasi_files.wasm";  // path_open/fd_* /readdir/rename/unlink/mkdir/rmdir
        wi_fx[2] = "wasi_exit.wasm";   // exit(7)
        wi_fx[3] = "wasi_sleep.wasm";  // usleep/nanosleep/sleep -> poll_oneoff, timed on CLOCK_MONOTONIC
        wi_fx[4] = "wasi_sjlj.wasm";   // setjmp/longjmp out of deep recursion (racccoon.setjmp/longjmp)
        int[5] wi_want = { 0, 0, 7, 0, 0 };
        bool wi_ok = true;
        for (int wf = 0; wf < 5; wf++) {
            char*[3] wi_av;
            wi_av[0] = wi_fx[wf]; wi_av[1] = "a"; wi_av[2] = "b";
            int wi_ac = wf == 0 ? 3 : 1;
            uint wi_gen = 0;
            int wi_c = rfork(RFPROC, &wi_gen);
            if (wi_c == 0) {
                exec("bin/wasm", exec_buf(), exec_buf_max(), 0, &wi_av[0], wi_ac);
                exitcode(127);
            }
            int wi_code = join(wi_c, wi_gen);
            print("wasm "); print(wi_fx[wf]); print(" -> exit ");
            print_uint((uint)wi_code);
            if (wi_code != wi_want[wf]) { print("  (expected "); print_uint((uint)wi_want[wf]); print(")"); wi_ok = false; }
            putchar('\n');
        }
        print(wi_ok ? "wasitest: ok\n" : "wasitest: FAILED\n");
    } else if (strcmp(cmd, "luatest") == 0) {
        // Lua 5.4 (third_party/lua via WASI, /lib/lua.wasm): one -e chunk of
        // self-checks, os.exit(0) only if every one holds. Exercises the
        // interpreter-assisted setjmp/longjmp (error/pcall), coroutines,
        // string/table libs and WASI file I/O. Kept small: /bin/wasm is slow.
        char* lt_code = "local n=0 local function c(ok) n=n+1 if not ok then print('luatest: check '..n..' failed') os.exit(n) end end "
            "c(select('#',pcall(error,'x'))==2) c(not pcall(function() local t=nil return t.k end)) "
            "local ok,e=pcall(error,{code=7}) c(not ok and e.code==7) "
            "c(('a,b,c'):gsub(',',';')=='a;b;c') c(string.format('%05.1f',3.14159)=='003.1') "
            "local t={5,3,9,1} table.sort(t) c(table.concat(t,' ')=='1 3 5 9') "
            "local co=coroutine.wrap(function(a) local b=coroutine.yield(a+1) return b*2 end) c(co(1)==2 and co(5)==10) "
            "local f=io.open('tmp/luat.txt','w') f:write('hi\\n',42) f:close() f=io.open('tmp/luat.txt') c(f:read('l')=='hi' and f:read('n')==42) f:close() os.remove('tmp/luat.txt') "
            "c(math.maxinteger+1==math.mininteger and 7//2==3 and 2^10==1024.0) "
            "print('luatest: '..n..' checks ok') os.exit(0)";
        char*[3] lt_av;
        lt_av[0] = "/lib/lua.wasm"; lt_av[1] = "-e"; lt_av[2] = lt_code;
        uint lt_gen = 0;
        int lt_c = rfork(RFPROC, &lt_gen);
        if (lt_c == 0) {
            exec("bin/wasm", exec_buf(), exec_buf_max(), 0, &lt_av[0], 3);
            exitcode(127);
        }
        int lt_code_rc = join(lt_c, lt_gen);
        print(lt_code_rc == 0 ? "luatest: ok\n" : "luatest: FAILED\n");
    } else if (strcmp(cmd, "stdiotest") == 0) {
        // /bin/stdiotest (docs/devlog.md, "std::io on racccoon") —
        // a program built against the REAL c3 stdlib (std::io)
        // instead of std::nolibc, proving io::printn/printfn work
        // end to end (user/std_racccoon/, scripts/build_user.sh's
        // build_user_program_stdio). Its own output goes straight
        // to the console (printfn's %d/%x); this just proves it
        // runs to a clean exit, same rfork/exec/join(code) shape
        // as wasmtest.
        uint st_gen = 0;
        int st_c = rfork(RFPROC, &st_gen);
        if (st_c == 0) {
            char*[1] st_av;
            st_av[0] = "bin/stdiotest";
            exec("bin/stdiotest", exec_buf(), exec_buf_max(), 0, &st_av[0], 1);
            exitcode(127);
        }
        int st_code = join(st_c, st_gen);
        // Second run: stdin wired to a pipe holding two lines, read back
        // through io::readline (libc fgetc -> SYS_GETCHAR), plus the
        // libc stubs failing the C way (user/std_racccoon/libc.c3).
        int st_p = pipe_new();
        if (st_p < 0) {
            st_code = -1;
        } else {
            pipe_hold(st_p, 1, 1);   // our writer end, released below = EOF
            uint st_gen2 = 0;
            int st_c2 = rfork_io(RFPROC, &st_gen2, -1, st_p);
            if (st_c2 == 0) {
                char*[1] st_av2;
                st_av2[0] = "-stdin";   // exec() prepends the program path itself
                exec("bin/stdiotest", exec_buf(), exec_buf_max(), 0, &st_av2[0], 1);
                exitcode(127);
            }
            pipe_write(st_p, "alpha\nbeta\n", 11);
            pipe_hold(st_p, 1, -1);
            if (join(st_c2, st_gen2) != 0) { st_code = -1; }
        }
        print(st_code == 0 ? "stdiotest: ok\n" : "stdiotest: FAILED\n");
    } else if (strcmp(cmd, "gotest") == 0 || strcmp(cmd, "gostage2test") == 0 || strcmp(cmd, "gostage3test") == 0 || strcmp(cmd, "gostage35test") == 0 || strcmp(cmd, "gostage41test") == 0 || strcmp(cmd, "gostage42test") == 0) {
        // Go on racccoon (docs/go-port-plan.md). /bin/go-* are
        // GOOS=racccoon static riscv64 binaries built by
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
        // cmd/link defaults -T/-R for racccoon/riscv64 so the output loads.
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

            // Profile the build itself (docs: "profile go build").
            ulong[4] gb_p1 @noinit;
            ulong[64] gb_hist @noinit;     // per-syscall counts — chasing the diskd poll storm
            ulong[6] gb_os0 @noinit; ulong[6] gb_os1 @noinit;
            fs_opstats(&gb_os0[0]);
            ulong gb_ch0 = gb_os0[0]; ulong gb_cm0 = gb_os0[1];
            // SYS_PROF / SYS_PROF_HIST return the PRE-reset totals then
            // zero — so after these reset calls the odometer is 0 and
            // the single post-build read IS the delta. (Subtracting the
            // reset snapshot underflows against the huge boot-time
            // totals — the trap ringbench / synhist both hit.)
            prof_hist(&gb_hist[0], 1);
            prof_read(&gb_p1[0], 1);
            ulong gb_wt0 = rdtime();

            uint gb_g1 = 0;
            int gb_c1 = rfork(RFPROC, &gb_g1);
            if (gb_c1 == 0) { exec("/bin/go", exec_buf(), exec_buf_max(), 0, &gb_av4[0], 4); exitcode(127); }
            int gb_rc1 = join(gb_c1, gb_g1);

            ulong gb_wt1 = rdtime();
            prof_read(&gb_p1[0], 0);
            prof_hist(&gb_hist[0], 0);      // gb_hist now holds the build's per-syscall counts
            fs_opstats(&gb_os1[0]);
            ulong gb_ch1 = gb_os1[0]; ulong gb_cm1 = gb_os1[1];
            chdir("/");

            ulong gb_sc_total = 0;
            for (int gb_sv = 0; gb_sv < 64; gb_sv++) { gb_sc_total += gb_hist[gb_sv]; }

            ulong gb_hz = timebase_hz();
            ulong gb_wall = gb_wt1 - gb_wt0;
            ulong gb_ipc_t = gb_p1[1];
            print("gobuildtest prof: wall=");
            print_uint((uint)(gb_hz > 0 ? gb_wall / gb_hz : 0)); print("s ipc_calls=");
            print_uint((uint)gb_p1[0]); print(" ipc_time=");
            print_uint((uint)(gb_hz > 0 ? gb_ipc_t / gb_hz : 0)); print("s (");
            print_uint((uint)(gb_wall > 0 ? (gb_ipc_t * 100) / gb_wall : 0)); print("% x-wall) yields=");
            print_uint((uint)gb_p1[2]); print(" switches=");
            print_uint((uint)gb_p1[3]); print(" cache=");
            print_uint((uint)(gb_ch1 - gb_ch0)); print("h/");
            print_uint((uint)(gb_cm1 - gb_cm0)); print("m\n");
            print("gobuildtest prof: syscalls=");
            print_uint((uint)(gb_sc_total / 1000)); print("k  sys10(ipc_poll)=");
            print_uint((uint)(gb_hist[10] / 1000)); print("k  sys55(irq_wait)=");
            print_uint((uint)(gb_hist[55] / 1000)); print("k\n");
            print("gobuildtest prof: fsd reads=");
            print_uint((uint)(gb_os1[2] - gb_os0[2])); print(" writes=");
            print_uint((uint)(gb_os1[3] - gb_os0[3])); print(" meta=");
            print_uint((uint)(gb_os1[4] - gb_os0[4])); print(" diskd_ops=");
            print_uint((uint)(gb_os1[5] - gb_os0[5])); print("\n");

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
    } else if (strcmp(cmd, "cxxtest") == 0) {
        // /bin/cxxtest (test/cxx-src/cxxtest.cpp): C++ on racccoon —
        // static libc++/libc++abi over racccoon-libc. Its output is
        // captured because the last check (a global destructor's "dtor
        // ran", printed after main returned) can't show up in the exit
        // code. Skips without /bin/cxxtest (no llvm-project checkout at
        // build time).
        char[1024] ct_out;
        int ct_code = lang_run_captured("bin/cxxtest", null, 0, &ct_out, 1024);
        if (ct_code == 127) {
            print("cxxtest: skipped (no /bin/cxxtest)\n");
        } else {
            print(ct_code == 0 && lang_has_text(&ct_out, "dtor ran") ? "cxxtest: ok\n" : "cxxtest: FAILED\n");
        }
    } else if (strcmp(cmd, "llvmtest") == 0) {
        // /bin/llvm-readelf (lib/racccoon-libc/build_llvm.sh): LLVM's own
        // llvm-readobj, cross-built against libc++ + racccoon-libc,
        // reading a real RISC-V ELF on the disk (echod.elf, also elftest's
        // fixture). readobj picks readelf mode from argv[0], the path
        // exec passes. Skips without /bin/llvm-readelf.
        char*[2] lt_av;
        lt_av[0] = "-h";
        lt_av[1] = "/bin/echod.elf";
        char[2048] lt_out;
        int lt_code = lang_run_captured("bin/llvm-readelf", &lt_av[0], 2, &lt_out, 2048);
        if (lt_code == 127) {
            print("llvmtest: skipped (no /bin/llvm-readelf)\n");
        } else {
            bool lt_ok = lt_code == 0 && lang_has_text(&lt_out, "Machine:                           RISC-V")
                && lang_has_text(&lt_out, "Entry point address:               0x1000000");
            print(lt_ok ? "llvmtest: ok\n" : "llvmtest: FAILED\n");
        }
    } else if (strcmp(cmd, "llctest") == 0) {
        // /bin/llc (build_llvm.sh): LLVM IR -> a RISC-V object on
        // racccoon. /hello.ll is test/llvm-src/hello.ll; /hello.ref.o is
        // the host llc's object for it (same LLVM version), so the two
        // must be byte-identical. Skips without /bin/llc.
        char*[5] lc_av;
        lc_av[0] = "-mattr=+m,+a,+f,+d,+c";   // = build_llvm.sh's reference run
        lc_av[1] = "-filetype=obj";
        lc_av[2] = "/hello.ll";
        lc_av[3] = "-o";
        lc_av[4] = "/llctmp.o";
        char[512] lc_out;
        int lc_code = lang_run_captured("bin/llc", &lc_av[0], 5, &lc_out, 512);
        if (lc_code == 127) {
            print("llctest: skipped (no /bin/llc)\n");
        } else {
            int lc_same = lc_code == 0 ? lang_same_file("/llctmp.o", "/hello.ref.o") : -1;
            fs_delete("/llctmp.o");
            if (lc_same > 0) {
                print("llctest: ok (");
                print_uint((uint)lc_same);
                print(" bytes, identical to the host llc's)\n");
            } else {
                print(lc_code == 0 ? "llctest: FAILED (object differs from the host llc's)\n" : "llctest: FAILED (llc exit != 0)\n");
            }
        }
    } else if (strcmp(cmd, "lldtest") == 0) {
        // The whole toolchain on racccoon: /bin/llc compiles /hello.ll,
        // /bin/ld.lld links it with the files in /lib/racccoon (crt0,
        // libracccoon.a, libgcc.a, the linker script), and the result
        // runs. The ELF must be byte-identical to /hello.ref.elf, the
        // host ld.lld's link of the host llc's object (build_llvm.sh).
        // Links twice, the second time over the first's output.
        // Skips without /bin/ld.lld.
        char[512] ld_out;
        char*[5] ld_cav;
        ld_cav[0] = "-mattr=+m,+a,+f,+d,+c";
        ld_cav[1] = "-filetype=obj";
        ld_cav[2] = "/hello.ll";
        ld_cav[3] = "-o";
        ld_cav[4] = "/lldtmp.o";
        int ld_cc = lang_run_captured("bin/llc", &ld_cav[0], 5, &ld_out, 512);
        char*[8] ld_lav;
        ld_lav[0] = "-T";
        ld_lav[1] = "/lib/racccoon/racccoon-libc.ld";
        ld_lav[2] = "/lib/racccoon/crt0.o";
        ld_lav[3] = "/lldtmp.o";
        ld_lav[4] = "/lib/racccoon/libracccoon.a";
        ld_lav[5] = "/lib/racccoon/libgcc.a";
        ld_lav[6] = "-o";
        ld_lav[7] = "/lldtmp";
        int ld_lc = ld_cc == 0 ? lang_run_captured("bin/ld.lld", &ld_lav[0], 8, &ld_out, 512) : -1;
        // Link again over the existing /lldtmp: ld.lld then deletes the
        // old file on a "background" thread (lld's unlinkAsync), which
        // aborted in pthread_create until libc ran threads to completion.
        if (ld_lc == 0) { ld_lc = lang_run_captured("bin/ld.lld", &ld_lav[0], 8, &ld_out, 512); }
        if (ld_cc == 127 || ld_lc == 127) {
            print("lldtest: skipped (no /bin/llc or /bin/ld.lld)\n");
        } else {
            int ld_same = ld_lc == 0 ? lang_same_file("/lldtmp", "/hello.ref.elf") : -1;
            int ld_rc = ld_lc == 0 ? lang_run_captured("/lldtmp", null, 0, &ld_out, 512) : -1;
            bool ld_ran = ld_rc == 0 && lang_has_text(&ld_out, "hello from llc");
            fs_delete("/lldtmp.o");
            fs_delete("/lldtmp");
            if (ld_cc != 0) {
                print("lldtest: FAILED (llc exit != 0)\n");
            } else if (ld_lc != 0) {
                print("lldtest: FAILED (ld.lld exit != 0)\n");
            } else if (!ld_ran) {
                print("lldtest: FAILED (the linked program didn't run right)\n");
            } else if (ld_same <= 0) {
                print("lldtest: FAILED (ELF differs from the host ld.lld's)\n");
            } else {
                print("lldtest: ok (compiled, linked, ran; ");
                print_uint((uint)ld_same);
                print(" bytes, identical to the host's)\n");
            }
        }
    } else if (strcmp(cmd, "c3ctest") == 0) {
        // /bin/c3c (lib/racccoon-libc/build_c3c.sh): the C3 compiler,
        // LLVM backend inside, compiling /src/c3ctest.c3
        // (test/c3-src/c3ctest.c3) on racccoon. No --stdlib: it must find
        // /lib/c3 by itself. The object must match the host's
        // (scripts/selfbuild_ref.sh: same c3c source, same LLVM). Skips
        // without /bin/c3c.
        char*[10] cc_av;
        cc_av[0] = "compile-only";
        cc_av[1] = "--target";
        cc_av[2] = "elf-riscv64";
        cc_av[3] = "--use-stdlib=no";
        cc_av[4] = "--no-entry";
        cc_av[5] = "--single-module=yes";
        cc_av[6] = "-g0";
        cc_av[7] = "/src/c3ctest.c3";
        cc_av[8] = "-o";
        cc_av[9] = "/c3ctmp.o";
        char[1024] cc_out;
        int cc_code = lang_run_captured("bin/c3c", &cc_av[0], 10, &cc_out, 1024);
        if (cc_code == 127) {
            print("c3ctest: skipped (no /bin/c3c)\n");
        } else {
            int cc_same = cc_code == 0 ? lang_same_file("/c3ctmp.o", "/src/racccoon-ref/c3ctest.o") : -1;
            fs_delete("/c3ctmp.o");
            if (cc_same > 0) {
                print("c3ctest: ok (");
                print_uint((uint)cc_same);
                print(" bytes, identical to the host c3c's)\n");
            } else {
                print(cc_code == 0 ? "c3ctest: FAILED (object differs from the host c3c's)\n" : "c3ctest: FAILED (c3c exit != 0)\n");
            }
        }
    } else if (strcmp(cmd, "selfbuildtest") == 0) {
        // racccoon building its own kernel: /src/racccoon/selfbuild.rc
        // runs c3c (IR), llc (objects) and ld.lld (the QEMU test kernel
        // with the embedded user programs) — scripts/selfbuild_ref.sh
        // generated it and ran the same steps on the host. The two
        // kernel.elf must be byte-identical. Long under QEMU (minutes).
        // A script is interpreted by the shell, not exec'd, so it runs
        // here (its `cd` too — undone after). Skips without the script
        // (no C3C_SRC at build time).
        uint sb_size = 0;
        int sb_type = 0;
        if (fs_stat("/src/racccoon/selfbuild.rc", &sb_size, &sb_type) != 0) {
            print("selfbuildtest: skipped (no /src/racccoon/selfbuild.rc)\n");
        } else {
            shell_run_script("/src/racccoon/selfbuild.rc", null, 0);
            chdir("/");
            int sb_same = lang_same_file("/src/racccoon/build/kernel.elf", "/src/racccoon-ref/kernel.elf");
            if (sb_same > 0) {
                print("selfbuildtest: ok (racccoon built its own kernel: ");
                print_uint((uint)sb_same);
                print(" bytes, identical to the host's)\n");
            } else {
                print("selfbuildtest: FAILED (kernel.elf missing or differs from the host's)\n");
            }
        }
    } else if (strcmp(cmd, "clangtest") == 0) {
        // /bin/clang (build_llvm.sh) compiling C and C++ on racccoon —
        // /src/clangtest/hello.c and cxxtest.cpp (libc++ headers), with
        // the flags build_llvm.sh gave the host clang (same version) for
        // /src/clangtest/*.ref.o; the objects must be identical. The C
        // one is then linked with ld.lld and run. Skips without /bin/clang.
        char[2048] ct_out;
        int ct_c = lang_run_line("bin/clang --target=riscv64-unknown-elf -march=rv64imafdc -mabi=lp64d -mcmodel=medany -fno-pic -O2 -g0 -nostdinc -isystem /src/sys/libc/include -isystem /lib/clang/23/include -c /src/clangtest/hello.c -o /clangtmp_c.o", &ct_out, 2048);
        if (ct_c == 127) {
            print("clangtest: skipped (no /bin/clang)\n");
        } else {
            int ct_cx = lang_run_line("bin/clang --driver-mode=g++ --target=riscv64-unknown-elf -march=rv64imafdc -mabi=lp64d -mcmodel=medany -fno-pic -O2 -g0 -nostdinc -nostdinc++ -isystem /src/sys/libcxx/include -isystem /src/sys/libc/include -isystem /lib/clang/23/include -std=c++20 -fno-exceptions -fno-rtti -c /src/clangtest/cxxtest.cpp -o /clangtmp_cxx.o", &ct_out, 2048);
            int ct_same_c = ct_c == 0 ? lang_same_file("/clangtmp_c.o", "/src/clangtest/clang_c.ref.o") : -1;
            int ct_same_cx = ct_cx == 0 ? lang_same_file("/clangtmp_cxx.o", "/src/clangtest/clang_cxx.ref.o") : -1;
            int ct_l = ct_c == 0 ? lang_run_line("bin/ld.lld -T /lib/racccoon/racccoon-libc.ld /lib/racccoon/crt0.o /clangtmp_c.o /lib/racccoon/libracccoon.a /lib/racccoon/libgcc.a -o /clangtmp", &ct_out, 2048) : -1;
            int ct_r = ct_l == 0 ? lang_run_captured("/clangtmp", null, 0, &ct_out, 2048) : -1;
            bool ct_ran = ct_r == 0 && lang_has_text(&ct_out, "hello from llc");
            fs_delete("/clangtmp_c.o");
            fs_delete("/clangtmp_cxx.o");
            fs_delete("/clangtmp");
            if (ct_same_c > 0 && ct_same_cx > 0 && ct_ran) {
                print("clangtest: ok (C ");
                print_uint((uint)ct_same_c);
                print(" + C++ ");
                print_uint((uint)ct_same_cx);
                print(" bytes identical to the host clang's; linked and ran)\n");
            } else {
                print("clangtest: FAILED (");
                print(ct_c != 0 ? "C compile" : ct_same_c <= 0 ? "C object differs" : ct_cx != 0 ? "C++ compile" : ct_same_cx <= 0 ? "C++ object differs" : "link/run");
                print(")\n");
            }
        }
    } else if (strcmp(cmd, "c3cselftest") == 0) {
        // c3c compiling itself on racccoon: /src/c3c/c3cbuild.rc
        // (scripts/c3cbuild_ref.sh) runs /bin/clang on c3c's sources and
        // /bin/ld.lld against the LLVM/lld/libc++ archives in /src/sys/lib
        // — the cross build's own commands. The ELF must equal
        // /src/c3c-ref/c3c, the cross-built c3c; then that racccoon-built
        // c3c compiles /src/c3ctest.c3, which must match the host's object.
        // Very long under QEMU (an hour or more). Ext2 only: skips without
        // the script.
        uint cs_size = 0;
        int cs_type = 0;
        if (fs_stat("/src/c3c/c3cbuild.rc", &cs_size, &cs_type) != 0) {
            print("c3cselftest: skipped (no /src/c3c/c3cbuild.rc)\n");
        } else {
            shell_run_script("/src/c3c/c3cbuild.rc", null, 0);
            chdir("/");
            int cs_same = lang_same_file("/src/c3c/build/c3c", "/src/c3c-ref/c3c");
            char[1024] cs_out;
            int cs_cc = cs_same > 0 ? lang_run_line("/src/c3c/build/c3c compile-only --target elf-riscv64 --use-stdlib=no --no-entry --single-module=yes -g0 /src/c3ctest.c3 -o /c3cselftmp.o", &cs_out, 1024) : -1;
            int cs_obj = cs_cc == 0 ? lang_same_file("/c3cselftmp.o", "/src/racccoon-ref/c3ctest.o") : -1;
            fs_delete("/c3cselftmp.o");
            if (cs_same > 0 && cs_obj > 0) {
                print("c3cselftest: ok (c3c rebuilt itself on racccoon: ");
                print_uint((uint)cs_same);
                print(" bytes, identical to the cross build; and it compiles identically)\n");
            } else {
                print(cs_same <= 0 ? "c3cselftest: FAILED (the rebuilt c3c is missing or differs)\n"
                                   : "c3cselftest: FAILED (the rebuilt c3c's output differs)\n");
            }
        }
    } else {
        return false;
    }
    return true;
}
