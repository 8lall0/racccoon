module user;

import std::nolibc::fmt;

// shell_test builtins — drivers + supervisor: kill-and-respawn tests,
// SYS_DEV_INFO, the keystroke queue, `loud`. Split out of
// shell_test.c3's main(), which tries each shell_test_*_dispatch in
// turn; true = cmd was one of these.

fn bool shell_test_drivers_dispatch(char* cmd, char** cmd_argv, int cmd_argc) {
    if (strcmp(cmd, "fsdkilltest") == 0) {
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
        // supervisor re-inits it (device_setup re-runs the
        // MMIO+DMA setup) and fsd re-resolves its new pid on the
        // next read (user/fs/fsd.c3's diskd_rw). docs/roadmap.md §5.
        //
        // A read alone can't prove the *new* driver works: fsd's read
        // cache answers a just-read file without touching the driver (on
        // the Duo this passed before sdd had even been respawned). So it
        // also writes a file and reads it back — the cache is read-only,
        // writes always reach the driver. Then it waits 3 s, writes
        // again (fsd re-resolves the driver if it died meanwhile) and
        // requires the same driver instance (pid + generation — a
        // respawn usually reuses the slot, so the pid alone repeats): a
        // respawned driver that dies
        // during its own bring-up (seen on the Duo as a second "svc:
        // respawned sdd") fails here instead of passing unnoticed.
        uint sk_part = 0;
        int  sk_pid  = 0;
        int sk_info = fs_partition_info(&sk_part, null, &sk_pid);
        uint sk_gen0 = 0;
        if (sk_pid > 0) proc_info(sk_pid, null, &sk_gen0, null);
        char[64] sk_buf @noinit;
        char* sk_probe = "bin/echod";   // on every image (see fsdkilltest)
        char* sk_tmp = "tmp/skt.txt";
        char* sk_msg = "storagekill write-through\n";
        int sk_msglen = 26;
        int sk_before = fs_read(sk_probe, &sk_buf, 64);
        int sk_killed = sk_pid > 0 ? kill(sk_pid, 0) : -1;
        ulong sk_deadline = rdtime() + timebase_hz() * 20; // 20s wall-clock, any board
        int sk_after = -1;
        bool sk_rw_ok = false;
        while (!sk_rw_ok && rdtime() < sk_deadline) {
            yield();
            sk_after = fs_read(sk_probe, &sk_buf, 64);
            if (fs_write(sk_tmp, sk_msg, sk_msglen) != sk_msglen) continue;
            char[32] sk_rb @noinit;
            if (fs_read(sk_tmp, &sk_rb, 32) != sk_msglen) continue;
            sk_rw_ok = true;
            for (int sk_i = 0; sk_i < sk_msglen; sk_i++) {
                if (sk_rb[sk_i] != sk_msg[sk_i]) { sk_rw_ok = false; break; }
            }
        }
        int sk_pid1 = 0;
        uint sk_gen1 = 0;
        fs_partition_info(&sk_part, null, &sk_pid1);
        if (sk_pid1 > 0) proc_info(sk_pid1, null, &sk_gen1, null);
        ulong sk_settle = rdtime() + timebase_hz() * 3;
        while (rdtime() < sk_settle) { yield(); }
        bool sk_rw2_ok = fs_write(sk_tmp, sk_msg, sk_msglen) == sk_msglen;
        int sk_pid2 = 0;
        uint sk_gen2 = 0;
        fs_partition_info(&sk_part, null, &sk_pid2);
        if (sk_pid2 > 0) proc_info(sk_pid2, null, &sk_gen2, null);
        fs_delete(sk_tmp);
        bool sk_stable = sk_pid1 > 0 && sk_pid1 == sk_pid2 && sk_gen1 == sk_gen2;
        // The supervisor respawns into the freed slot, and each
        // create_process bumps that slot's generation — so a respawn
        // that died and was respawned again *before* the first write
        // succeeded shows up as a jump of 2+, not 1. (Only judged when
        // the slot was reused; nothing else spawns during the test.)
        uint sk_respawns = (sk_pid1 == sk_pid && sk_gen1 >= sk_gen0) ? sk_gen1 - sk_gen0 : 1;
        sk_stable = sk_stable && sk_respawns == 1;
        if (sk_info == 0 && sk_pid > 0 && sk_before >= 0 && sk_killed == 0 && sk_after == sk_before
            && sk_rw_ok && sk_rw2_ok && sk_stable) {
            print("storagekilltest: ok (storage driver killed, respawned once, writes + reads work)\n");
        } else {
            print("storagekilltest: FAILED (read=");
            print(sk_after == sk_before ? "ok" : "bad");
            print(" write=");
            print(sk_rw_ok ? "ok" : "bad");
            print(" write2=");
            print(sk_rw2_ok ? "ok" : "bad");
            print(" respawns=");
            print_uint(sk_respawns);
            print(" driver pid/gen ");
            print_uint((uint)sk_pid); putchar('/'); print_uint(sk_gen0);
            print(" -> ");
            print_uint((uint)sk_pid1); putchar('/'); print_uint(sk_gen1);
            print(" -> ");
            print_uint((uint)sk_pid2); putchar('/'); print_uint(sk_gen2);
            print(")\n");
        }
    } else if (strcmp(cmd, "devinfotest") == 0) {
        // SYS_DEV_INFO (src/device.c3): only a process a board device
        // was handed to — a hardware driver — gets an answer. The shell
        // owns no device, so it gets -1, as does a request bigger than
        // the reply capacity, and so does a forked child (rfork resets
        // Process.device, so a child landing in a slot a killed driver
        // just vacated never reads that driver's DMA addresses — run
        // netdkilltest first on QEMU to exercise exactly that).
        uptr[4] dv_out;
        int dv_shell = dev_info(&dv_out[0], 4);
        int dv_big   = dev_info(&dv_out[0], 5);
        uint dv_gen = 0;
        int dv_c = rfork(RFPROC, &dv_gen);
        if (dv_c == 0) {
            uptr[4] dv_child;
            exitcode(dev_info(&dv_child[0], 4) == -1 ? 7 : 1);
        }
        int dv_code = -1;
        if (dv_c > 0) { dv_code = join(dv_c, dv_gen); }
        if (dv_shell == -1 && dv_big == -1 && dv_code == 7) {
            print("devinfotest: ok (non-driver processes get -1)\n");
        } else {
            print("devinfotest: FAILED shell="); print_uint((uint)dv_shell);
            print(" big="); print_uint((uint)dv_big);
            print(" child="); print_uint((uint)dv_code); putchar('\n');
        }
    } else if (strcmp(cmd, "netdkilltest") == 0) {
        // The storage driver's supervisor path (storagekilltest),
        // one driver over: kill netd and confirm the supervisor
        // re-inits it (device_setup re-runs for the "virtio-net" device) and the
        // namespace reseat points our handle back at the fresh pid. The
        // handle lives at /srv/netd/, not /net/: /net/ is ipd's (the IP
        // stack) — mounting netd there shadowed it for every later test.
        if (ns_mount("/srv/netd/", "netd") < 0) {
            print("netdkilltest: FAILED (netd not posted)\n");
        } else {
            uint nk_m = 0;
            int nk_pid = ns_resolve("/srv/netd/", &nk_m);
            int nk_killed = nk_pid > 0 ? kill(nk_pid, 0) : -1;
            int nk_ok = -1;
            ulong nk_deadline = rdtime() + timebase_hz() * 20; // 20s wall-clock, any board
            while (nk_ok < 0 && rdtime() < nk_deadline) {
                yield();
                uint m = 0;
                int np = ns_resolve("/srv/netd/", &m);
                // m == 10 ("/srv/netd/") means it resolved to the netd
                // mount, reseated to the live respawn — not the ""
                // catch-all it falls to while netd is down.
                if (np > 0 && m == 10) {
                    uint g = 0;
                    if (proc_info(np, null, &g, null) == 0) nk_ok = 0;
                }
            }
            if (nk_pid > 0 && nk_killed == 0 && nk_ok == 0) {
                print("netdkilltest: ok (netd killed, respawned, /srv/netd/ reseated)\n");
            } else {
                print("netdkilltest: FAILED\n");
            }
        }
    } else if (strcmp(cmd, "gpiodkilltest") == 0) {
        // §5.5, Duo-only: gpiod isn't spawned on QEMU (no GPIO
        // controller on the virt board). Kill it, let the supervisor
        // respawn it (device_setup re-maps the "gpio" device's
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
        // the supervisor respawn it (device_setup re-maps the
        // "usb" device's DWC2 MMIO + DMA ring), and
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
    } else {
        return false;
    }
    return true;
}
