module kernel;

import std::io;
import board;
import panic;

// Also hardcoded (can't be interpolated into compile-time asm() strings,
// see write_reg's comment in entry.c3) as the literal 0x1000000 in
// process.c3's user_entry() and in user/user.ld's base address. Keep all
// three in sync if this ever changes.
const USER_BASE = 0x1000000;

// Linker-script symbols (src/kernel.ld / boards/*/kernel.ld) — declared
// `extern ... @cname`, NOT `char[] X @export("X")`. c3c 0.8.4 turned the
// latter into a real 16-byte .bss *definition* of the same name, so `&X`
// resolved to that object instead of the linker-script address: the boot
// self-test (self_test_pte_roundtrip) saw a non-page-aligned __free_ram
// and panicked on every board. (0.8.3 emitted a bare symbol, which is why
// this worked before — by accident.) `extern` says what these really are.
extern char[] __kernel_base @cname("__kernel_base");
extern char[] __kernel_map_base @cname("__kernel_map_base");
extern char[] __bss @cname("__bss");
extern char[] __bss_end @cname("__bss_end");
extern char[] __stack_top @cname("__stack_top");
extern char[] __free_ram @cname("__free_ram");
extern char[] __free_ram_end @cname("__free_ram_end");
// _bin_end (a real address, objcopy-provided), not _bin_size: RV64 port.
// _bin_size is an objcopy convention where the symbol's "address" isn't
// a real memory location at all — it's the byte count itself, encoded
// as an absolute (SHN_ABS) symbol value, and `&_bin_size` is the
// classic trick to read that value back as an integer. That trick only
// works under *absolute* addressing (lui+addi materializing the literal
// value). This kernel's own code now compiles under RV64's medium code
// model (see docs/devlog.md — kernel_main lives ~2GB from address 0,
// past what "small"/medlow absolute addressing can reach at all), which
// generates *PC-relative* (auipc-based) addressing for every symbol
// reference uniformly — computing a PC-relative delta to a fake
// "address" that's actually just a small integer produces a huge,
// meaningless offset (kernel_main's real PC minus a value near zero),
// which is exactly what overflowed the ±2GB link-time range check.
// _bin_end has no such problem: it's a real address in the same
// section as _bin_start, so `_bin_end - _bin_start` (both real,
// nearby, PC-relative-safe addresses) gives the same byte count
// without ever materializing the broken fake-address symbol.
extern char[] _binary_shell_bin_start @cname("_binary_shell_bin_start");
extern char[] _binary_shell_bin_end @cname("_binary_shell_bin_end");
extern char[] _binary_echod_bin_start @cname("_binary_echod_bin_start");
extern char[] _binary_echod_bin_end @cname("_binary_echod_bin_end");
extern char[] _binary_diskd_bin_start @cname("_binary_diskd_bin_start");
extern char[] _binary_diskd_bin_end @cname("_binary_diskd_bin_end");
extern char[] _binary_sdd_bin_start @cname("_binary_sdd_bin_start");
extern char[] _binary_sdd_bin_end @cname("_binary_sdd_bin_end");
extern char[] _binary_fsd_bin_start @cname("_binary_fsd_bin_start");
extern char[] _binary_fsd_bin_end @cname("_binary_fsd_bin_end");
extern char[] _binary_procd_bin_start @cname("_binary_procd_bin_start");
extern char[] _binary_procd_bin_end @cname("_binary_procd_bin_end");
extern char[] _binary_envd_bin_start @cname("_binary_envd_bin_start");
extern char[] _binary_envd_bin_end @cname("_binary_envd_bin_end");
extern char[] _binary_usbd_bin_start @cname("_binary_usbd_bin_start");
extern char[] _binary_usbd_bin_end @cname("_binary_usbd_bin_end");
extern char[] _binary_ethd_bin_start @cname("_binary_ethd_bin_start");
extern char[] _binary_ethd_bin_end @cname("_binary_ethd_bin_end");
extern char[] _binary_ipd_bin_start @cname("_binary_ipd_bin_start");
extern char[] _binary_ipd_bin_end @cname("_binary_ipd_bin_end");
extern char[] _binary_netd_bin_start @cname("_binary_netd_bin_start");
extern char[] _binary_netd_bin_end @cname("_binary_netd_bin_end");
extern char[] _binary_gpiod_bin_start @cname("_binary_gpiod_bin_start");
extern char[] _binary_gpiod_bin_end @cname("_binary_gpiod_bin_end");
extern char[] _binary_brcmd_bin_start @cname("_binary_brcmd_bin_start");
extern char[] _binary_brcmd_bin_end @cname("_binary_brcmd_bin_end");
extern char[] _binary_i2cd_bin_start @cname("_binary_i2cd_bin_start");
extern char[] _binary_i2cd_bin_end @cname("_binary_i2cd_bin_end");
extern char[] _binary_cifd_bin_start @cname("_binary_cifd_bin_start");
extern char[] _binary_cifd_bin_end @cname("_binary_cifd_bin_end");

// @section(".text.boot.entry") — pinned first in .text.boot by both
// linker scripts so OpenSBI's fixed 0x80200000 payload-entry jump always
// lands here and never in smp.c3's secondary_entry (which shares
// .text.boot). c3c merges every `module kernel` file into one object and
// picks its own function emission order; it once put secondary_entry
// first, and any unrelated edit to a kernel-module file can flip it
// again — so the ordering is pinned here, not left to chance.
fn void boot() @naked @export("boot") @section(".text.boot.entry") @noinline @nostrip @used
{
	// OpenSBI enters S-mode here with a0 = the boot hart's id, a1 = the
	// DTB address. a0 is left untouched (la/j don't clobber it) and picked
	// up as kernel_main's first parameter — NOT stashed to memory here:
	// boot_hartid_raw lives in .bss and kernel_main's first act is to zero
	// .bss, which would wipe it straight back to 0. That bug was invisible
	// on every board whose boot hart is hart 0 (QEMU virt, the Milk-V Duo)
	// and only surfaced on the sifive_u harness, whose boot hart is 1 —
	// see docs/devlog.md. Secondary harts are started separately
	// (sbi_hart_start) and land at secondary_entry, not here.
	asm(`
        la sp, __stack_top
        j kernel_main
    `);
}

fn void kernel_main(ulong boot_hart) @export("kernel_main") @noinline @nostrip
{
	mem::set(&__bss, 0, (sz)((uptr)&__bss_end - (uptr)&__bss));

	// a0 from boot() — the hart OpenSBI handed the S-mode payload to.
	// Written only now, after the .bss clear above, because that is where
	// boot_hartid_raw lives (see boot()'s comment). smp_init_boot_hart()
	// just below copies it into boot_hartid.
	boot_hartid_raw = boot_hart;

	io::print("1: BSS cleared\n");

	// SMP Stage A/C1: establish the boot hart's identity before anything
	// that takes a Stage B lock (create_process -> proc_table_lock,
	// alloc_lock — indexed by this_hartid()) and before any trap can fire:
	// tp + sscratch point at hart_scratch[boot_hartid], whose .kstack is
	// the trap-frame anchor for traps taken while kernel_main itself runs
	// (boot_trap_stack — a dedicated buffer, not __stack_top, which
	// kernel_main is running on; see its comment in entry.c3). 16-byte
	// aligned in hart_identity_init: a char[] global's address isn't
	// guaranteed aligned, and a misaligned sscratch frame was a real
	// Orange Pi bug. kernel_entry's first instruction swaps sscratch, so
	// this must precede stvec.
	smp_init_boot_hart();

	self_test_pte_roundtrip();

	write_reg("stvec", "kernel_entry");

	plic_init();
	plic_arm_devices();

	// Turn the FPU on (sstatus.FS = Initial) — the C906 and QEMU virt both
	// have F+D, and the kernel is built rv64imafdc now (scripts/build.sh).
	// Field surgery, not `| bit`: an OR would corrupt a Clean handoff into
	// Dirty. The read-back probe turns a fused-off / mis-handed-off FPU
	// into a clear panic here instead of a bare scause=2 later.
	ulong fs_sstatus = read_reg("sstatus");
	write_csr("sstatus", (fs_sstatus & ~SSTATUS_FS_MASK) | SSTATUS_FS_INITIAL);
	if ((read_reg("sstatus") & SSTATUS_FS_MASK) == 0)
	{
		panic::panic("FPU unavailable (sstatus.FS won't set) — rebuild soft-float");
	}

	enable_external_interrupts();
	enable_user_timer_access();
	// Re-enabled after switching arm_timer() (entry.c3) to the SBI
	// legacy set_timer call instead of a direct stimecmp CSR write —
	// see its own comment and docs/devlog.md for why the direct-CSR
	// version hung the real Duo.
	enable_timer_interrupts();

	io::print("2: Trap handler set\n");

	idle_proc = create_process(null, 0);
	if (idle_proc == null) { panic::panic("can't create the idle process"); }
	io::print("3: Idle created\n");

	proc_set_name(idle_proc, "idle");
	idle_proc.pid = 0;
	current_proc = idle_proc;

	io::print("4: Idle configured\n");

	// The IPC test server (see docs/devlog.md). Supervised like the rest
	// now; the shell's "ping" resolves it through the namespace
	// ("/srv/echo/" -> echod, healed on respawn by the supervisor),
	// so its slot/pid is no longer load-bearing.
	service_boot("echod", (char*)&_binary_echod_bin_start, (char*)&_binary_echod_bin_end,
		mount: "/srv/echo/");
	io::print("Idle process started\n");

	// diskd/fsd (see user/diskd.c3 and user/fsd.c3, microkernel plan
	// phases 4/5) need a real block device — the board declares one in
	// board::DEVICES (device.c3): "sd" (real SD card, user/sdd.c3) or
	// "virtio-blk" (QEMU, user/diskd.c3), mutually exclusive. A board with
	// neither (the Orange Pi RV scaffold, for now — no storage driver yet)
	// skips all of this: fsd is never registered, so no later process's default
	// namespace gets a "" -> fsd mount (seed_default_namespace skips it),
	// so the shell's readfile/writefile commands fail cleanly instead of
	// hanging on a server that was never spawned.
	//
	// fsd learns whichever pid the driver lands at from
	// SYS_FS_PARTITION_INFO (storage_pid), not a fixed slot, and
	// re-queries it if the driver respawns — so the two are supervised.
	bool have_storage = false;
	int sd_dev = device_find("sd");
	int vblk_dev = device_find("virtio-blk");
	if (sd_dev >= 0)
	{
		service_boot("sdd", (char*)&_binary_sdd_bin_start, (char*)&_binary_sdd_bin_end,
			pid_global: &storage_pid, device: sd_dev);
		io::print("sdd created\n");
		have_storage = true;
	}
	else if (vblk_dev >= 0)
	{
		service_boot("diskd", (char*)&_binary_diskd_bin_start, (char*)&_binary_diskd_bin_end,
			pid_global: &storage_pid, device: vblk_dev);
		io::print("diskd created\n");
		have_storage = true;
	}

	if (have_storage)
	{
		// Created after the storage driver so it's already registered
		// (storage_pid) by the time fsd's own fs_init() (run the first
		// time the scheduler picks it, same as any other process) sends
		// it a request. fsd has to be registered (service_boot) before ANY later
		// create_process call populates a default namespace, since the seeding
		// reads the service table — every process created from here
		// on (i.e. every shell) gets a working "" -> fsd mount;
		// idle/echod/the storage driver, created before this line, don't
		// and don't need to (see process.c3's create_process).
		service_boot("fsd", (char*)&_binary_fsd_bin_start, (char*)&_binary_fsd_bin_end,
			mount: "", is_fsd: true,
			fsd_partition: board::FS_PARTITION_START_SECTOR, fsd_secondary: false);
		io::print("fsd created\n");

		// A second, simultaneously-mounted fsd instance, reachable under
		// the "/mnt/fs2/" prefix (its `mount:` below) —
		// spawned from the *same* fsd binary, just pointed at a different
		// partition. Exactly two static mounts, not a general N; see
		// docs/devlog.md for why that's the right scope for the actual
		// problem this solves (testing FAT32 and ext2 simultaneously,
		// without physically swapping FS_PARTITION_START_SECTOR and
		// reflashing). Same "registered before any later create_process
		// call populates a default namespace" ordering constraint as
		// fsd above.
		if (board::HAS_SECOND_FS_PARTITION)
		{
			service_boot("fsd2", (char*)&_binary_fsd_bin_start, (char*)&_binary_fsd_bin_end,
				mount: "/mnt/fs2/", is_fsd: true,
				fsd_partition: board::FS_PARTITION_2_START_SECTOR, fsd_secondary: true);
			io::print("fsd2 created\n");
		}
	}

	// procd (the "/proc/" server, user/procd.c3) — unconditional on
	// every board, unlike diskd/sdd/fsd/fsd2: it has no storage-hardware
	// dependency, just SYS_PROC_INFO, which every process can already
	// call. Spawned last, after every board-conditional server above, so
	// it never disturbs their own hardcoded pid conventions (echod=2,
	// fsd.c3's own DISKD_PID=3) regardless of which of
	// the board has storage / HAS_SECOND_FS_PARTITION is set. Same "must be set
	// before any later create_process call populates a default
	// namespace" ordering constraint as fsd/fsd2 above.
	service_boot("procd", (char*)&_binary_procd_bin_start, (char*)&_binary_procd_bin_end,
		mount: "/proc/");
	io::print("procd created\n");

	// envd (the "/env/" server, user/envd.c3) — same unconditional,
	// spawned-right-after-procd reasoning as procd's own comment above:
	// no storage-hardware dependency (just SYS_IPC_RECV_GEN/
	// SYS_PROC_INFO, both already usable by every process regardless of
	// board), and ordering still matters for the same reason
	// (create_process's default namespace population, right below).
	service_boot("envd", (char*)&_binary_envd_bin_start, (char*)&_binary_envd_bin_end,
		mount: "/env/");
	io::print("envd created\n");

	// ipd (the IP stack, user/net/ipd.c3) — mounted at /net/. No device of
	// its own: it attaches the link rings ("ether<N>") that netd / ethd /
	// the Wi-Fi driver create whenever they come up, so it can start
	// before any of them. Spawned before the shell for the same reason as
	// procd/envd: the shell's default namespace only gets the mounts of
	// services that already exist.
	service_boot("ipd", (char*)&_binary_ipd_bin_start, (char*)&_binary_ipd_bin_end,
		mount: "/net/");
	io::print("ipd created\n");

	// The shell — created explicitly here, BEFORE usbd below, not left
	// to the lazy "idle notices nothing else is runnable" path the
	// final loop below still handles for every later respawn. Real bug
	// found bringing usbd up on real hardware (docs/devlog.md): every
	// boot-time server up to this point (echod/diskd-or-sdd/fsd/fsd2/
	// procd/envd) eventually reaches a genuine PROC_BLOCKED wait
	// (SYS_IPC_RECV), so the chain of yield() calls each one's own
	// init-then-block sequence triggers always eventually cascades
	// back to idle_proc (this function, mid its own final loop) —
	// which is the ONLY place that lazily creates the shell. usbd is
	// the first process in this project's history that never reaches
	// a genuine block at all (it stays PROC_RUNNABLE forever, just
	// yielding — the same deliberate shape SYS_GETCHAR/SYS_JOIN
	// already use) — once it's scheduled, that cascade-back-to-idle
	// never happens again, so the lazy path would never fire and the
	// shell would never get created at all, a real, total, silent
	// deadlock (confirmed directly: real hardware hung right after
	// usbd's own "polling HPRT0" message, before ever printing a shell
	// prompt). Creating the shell explicitly, before usbd, sidesteps
	// this: once both exist, they're both "permanently runnable, only
	// yielding" in the same sense (matching SYS_GETCHAR's own idle
	// wait), and the round-robin scan already correctly alternates
	// between any number of such processes — the same shape that
	// already works fine for e.g. hotplugtest's own dangling-fid race.
	Process* shell_proc = create_process((void*)&_binary_shell_bin_start, (uint)((uptr)&_binary_shell_bin_end - (uptr)&_binary_shell_bin_start));
	if (shell_proc == null) { panic::panic("can't create the shell"); }
	proc_set_name(shell_proc, "shell");
	console_noteg = shell_proc.noteg; // ^C goes to the shell's note group (src/note.c3)
	io::print("shell created\n");

	// The remaining hardware drivers — each spawns only on a board that
	// declares its device (board::DEVICES, device.c3), and gets exactly
	// what that entry describes: no per-driver kernel setup code.
	//
	// All spawned last, after every other server (including the shell
	// above): nothing hardcodes these pids (no fixed-slot convention to
	// preserve) and none has IPC clients until something dynamically
	// ns_mount_wait()s its "/srv/<name>/" the way mountusb does for usbd.
	//
	// usbd (user/usb/usbd.c3, DWC2 host — Duo). watch_hangs = false for
	// usbd/ethd: their bring-up (a USB bus reset + 1s settle, an Ethernet
	// PHY train, …) can legitimately not touch their IPC poll for
	// seconds, which would false-trip the has_message stall check. They
	// still get respawn-on-exit — a driver that panic()s comes back.
	int usb_dev = device_find("usb");
	if (usb_dev >= 0)
	{
		service_boot("usbd", (char*)&_binary_usbd_bin_start, (char*)&_binary_usbd_bin_end,
			device: usb_dev, watch_hangs: false);
		io::print("usbd created\n");
	}

	// ethd (the real Ethernet MAC driver, user/net/ethd.c3 — Duo) or netd
	// (virtio-net, user/net/netd.c3 — QEMU): mutually exclusive, same
	// device-presence shape as "sd" vs "virtio-blk" above.
	int eth_dev = device_find("eth-mac");
	if (eth_dev >= 0)
	{
		service_boot("ethd", (char*)&_binary_ethd_bin_start, (char*)&_binary_ethd_bin_end,
			device: eth_dev, watch_hangs: false);
		io::print("ethd created\n");
	}
	int vnet_dev = device_find("virtio-net");
	if (vnet_dev >= 0)
	{
		service_boot("netd", (char*)&_binary_netd_bin_start, (char*)&_binary_netd_bin_end,
			device: vnet_dev);
		io::print("netd created\n");
	}

	// gpiod (the GPIO driver, user/gpio/gpiod.c3 — Duo). watch_hangs =
	// true (unlike usbd/ethd): gpiod's bring-up is three MMIO writes, not
	// a multi-second bus reset / PHY train, and its poll loop clears
	// has_message every iteration — so a stuck inbox for SVC_STALL_LIMIT
	// ticks genuinely means wedged. Gives the driver-respawn path (§5.5) a
	// safety net: a respawned gpiod that fails to re-init gets killed +
	// respawned rather than hanging every client that IPCs it forever.
	int gpio_dev = device_find("gpio");
	if (gpio_dev >= 0)
	{
		service_boot("gpiod", (char*)&_binary_gpiod_bin_start, (char*)&_binary_gpiod_bin_end,
			device: gpio_dev);
		io::print("gpiod created\n");
	}

	// The CAM-GC2083 camera (docs/camera-plan.md) — Duo: i2cd (I2C1, the
	// sensor's bus) and cifd (the MIPI CSI-2 receiver). Spawned last for
	// the same reason as gpiod, and watch_hangs like it.
	int i2c_dev = device_find("i2c");
	if (i2c_dev >= 0)
	{
		service_boot("i2cd", (char*)&_binary_i2cd_bin_start, (char*)&_binary_i2cd_bin_end,
			device: i2c_dev);
		io::print("i2cd created\n");
	}
	// The Orange Pi RV's AP6256 Wi-Fi on sdio0 (user/wifi/brcmd.c3): loads
	// the firmware, joins /adm/wifi, serves /bin/wifi at /srv/brcmd/ and
	// the "ether1" link ring for ipd. Polled.
	int wifi_dev = device_find("wifi");
	if (wifi_dev >= 0)
	{
		service_boot("brcmd", (char*)&_binary_brcmd_bin_start, (char*)&_binary_brcmd_bin_end,
			device: wifi_dev);
		io::print("brcmd created\n");
	}
	int cif_dev = device_find("cif");
	if (cif_dev >= 0)
	{
		service_boot("cifd", (char*)&_binary_cifd_bin_start, (char*)&_binary_cifd_bin_end,
			device: cif_dev);
		io::print("cifd created\n");
	}

	// Multi-core scaffold (src/smp.c3): enumerate + start whatever harts
	// the board allows, each of which announces itself and parks. No-op
	// on a single-hart boot (default QEMU, the Duo). Deliberately last —
	// the boot servers above must all be up first, since a secondary
	// today does nothing but wfi and a real scheduler isn't wired in.
	smp_start_secondaries();

	// SMP Stage C2: the idle loop is kernel code — hold the giant lock for
	// it, like handle_trap does. yield() drops and retakes it around each
	// switch_context, so a runnable process gets the kernel while idle is
	// parked. (Stage C3: an all-blocked system busy-spins yield() here
	// holding the lock — idle then needs a wfi with the lock dropped.)
	kernel_lock.acquire();

	// Single call site for create_process(shell) below (a *respawn*
	// only now — the initial spawn is explicit above): once the console
	// shell process we started is gone (`exit`, killed, faulted), start a
	// fresh one. It used to respawn whenever nothing at all was RUNNABLE,
	// which was a stand-in for "the shell exited" while every wait spun
	// RUNNABLE — but sleeping waits (the FIFO send queue, timed
	// await_any, ipd and netd) make "everyone asleep" a normal moment, and
	// that started a second shell next to a live one (two shells then
	// split the console's keystrokes).
	int shell_pid = shell_proc.pid;
	uint shell_gen = shell_proc.generation;
	for (;;)
	{
		Process* sh = proc_by_pid(shell_pid);
		if (sh == null || sh.generation != shell_gen)
		{
			Process* respawned_shell = create_process((void*)&_binary_shell_bin_start, (uint)((uptr)&_binary_shell_bin_end - (uptr)&_binary_shell_bin_start));
			if (respawned_shell != null)   // out of memory: try again next pass
			{
				proc_set_name(respawned_shell, "shell");
				console_noteg = respawned_shell.noteg;
				shell_pid = respawned_shell.pid;
				shell_gen = respawned_shell.generation;
			}
		}

		yield();
	}
}

