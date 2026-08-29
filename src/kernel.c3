module kernel;

import std::io;
import board;

// Also hardcoded (can't be interpolated into compile-time asm() strings,
// see write_reg's comment in entry.c3) as the literal 0x1000000 in
// process.c3's user_entry() and in user/user.ld's base address. Keep all
// three in sync if this ever changes.
const USER_BASE = 0x1000000;

char[] __kernel_base @export("__kernel_base");
char[] __kernel_map_base @export("__kernel_map_base");
char[] __bss @export("__bss");
char[] __bss_end @export("__bss_end");
char[] __stack_top @export("__stack_top");
char[] __free_ram @export("__free_ram");
char[] __free_ram_end @export("__free_ram_end");
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
extern char[] _binary_netd_bin_start @cname("_binary_netd_bin_start");
extern char[] _binary_netd_bin_end @cname("_binary_netd_bin_end");
extern char[] _binary_gpiod_bin_start @cname("_binary_gpiod_bin_start");
extern char[] _binary_gpiod_bin_end @cname("_binary_gpiod_bin_end");

fn void boot() @naked @export("boot") @section(".text.boot") @noinline @nostrip @used
{
	asm(`
        la sp, __stack_top
        j kernel_main
    `);
}

fn void kernel_main() @export("kernel_main") @noinline @nostrip
{
	mem::set(&__bss, 0, (sz)((uptr)&__bss_end - (uptr)&__bss));

	io::print("1: BSS cleared\n");

	self_test_pte_roundtrip();

	write_reg("stvec", "kernel_entry");

	// Trap-frame anchor for traps taken *before* the first switch_context
	// call (i.e. while running kernel_main itself, bare-mode, no process
	// yet). See boot_trap_stack's comment in entry.c3 for why this is a
	// dedicated buffer and not __stack_top itself. Must be set before any
	// interrupt can actually fire — kernel_entry's very first instruction
	// (csrrw sp, sscratch, sp) would otherwise swap in garbage and build
	// the trap frame at a bogus address.
	write_csr("sscratch", (uptr)&boot_trap_stack + boot_trap_stack.len);

	board::plic_init();
	enable_external_interrupts();
	enable_user_timer_access();
	// Re-enabled after switching arm_timer() (entry.c3) to the SBI
	// legacy set_timer call instead of a direct stimecmp CSR write —
	// see its own comment and docs/devlog.md for why the direct-CSR
	// version hung the real Duo.
	enable_timer_interrupts();

	io::print("2: Trap handler set\n");

	idle_proc = create_process(null, 0);
	io::print("3: Idle created\n");

	idle_proc.pid = 0;
	current_proc = idle_proc;

	io::print("4: Idle configured\n");

	// Spawned once, here, not through the respawn loop below — echod is
	// the IPC test server (see docs/devlog.md), not something that needs
	// to come back after exiting. It's always the first process created
	// after idle, so it always lands in the first free slot and gets
	// pid 2 — user/shell.c3's "ping" command hardcodes that. Good enough
	// for proving IPC works; a real name -> pid lookup is namespace work,
	// not part of this first slice.
	Process* echod_proc = create_process((void*)&_binary_echod_bin_start, (uint)((uptr)&_binary_echod_bin_end - (uptr)&_binary_echod_bin_start));
	echod_proc.is_boot_server = true;
	echod_pid = echod_proc.pid;
	supervisor_register("echod", (char*)&_binary_echod_bin_start, (char*)&_binary_echod_bin_end,
		false, 0, false, &echod_pid, echod_proc);
	io::print("Idle process started\n");

	// diskd/fsd (see user/diskd.c3 and user/fsd.c3, microkernel plan
	// phases 4/5) need a real block device — board::HAS_BLOCK_DEVICE is
	// false on any platform without one (Milk-V Duo, for now: no
	// virtio-mmio equivalent, no storage driver yet — see
	// docs/devlog.md). Skipped entirely there: fsd_pid stays 0, and
	// every later create_process's default "" -> fsd namespace mount
	// just never resolves to anything, so the shell's
	// readfile/writefile commands fail cleanly instead of hanging on a
	// server that was never spawned.
	if (board::HAS_BLOCK_DEVICE)
	{
		// Created after echod so echod keeps its pid-2 convention above.
		// Which driver — board::HAS_SD_BLOCK/HAS_VIRTIO_BLOCK (mutually
		// exclusive, see board.c3) pick real-SD (Duo, user/sdd.c3) vs
		// virtio-blk (QEMU, user/diskd.c3). Either way the driver process
		// lands in this same third slot (pid 3, right after idle/echod),
		// which is what lets fsd.c3's DISKD_PID hardcode stay valid
		// unchanged regardless of which board this is.
		if (board::HAS_SD_BLOCK)
		{
			Process* sdd_proc = create_process((void*)&_binary_sdd_bin_start, (uint)((uptr)&_binary_sdd_bin_end - (uptr)&_binary_sdd_bin_start));
			sdd_proc.is_boot_server = true;
			setup_sdd_mappings(sdd_proc);
			storage_pid = sdd_proc.pid;
			io::print("sdd created\n");
		}
		else if (board::HAS_VIRTIO_BLOCK)
		{
			Process* diskd_proc = create_process((void*)&_binary_diskd_bin_start, (uint)((uptr)&_binary_diskd_bin_end - (uptr)&_binary_diskd_bin_start));
			diskd_proc.is_boot_server = true;
			setup_diskd_mappings(diskd_proc);
			storage_pid = diskd_proc.pid;
			io::print("diskd created\n");
		}

		// Created after the storage driver so it's already registered
		// (diskd_pid/sdd_pid) by the time fsd's own fs_init() (run the
		// first time the scheduler picks it, same as any other process)
		// sends it a request. fsd_pid has to be set before ANY later
		// create_process call populates a default namespace, since that's
		// where it's actually consumed — every process created from here
		// on (i.e. every shell) gets a working "" -> fsd mount;
		// idle/echod/the storage driver, created before this line, don't
		// and don't need to (see process.c3's create_process).
		Process* fsd_proc = create_process((void*)&_binary_fsd_bin_start, (uint)((uptr)&_binary_fsd_bin_end - (uptr)&_binary_fsd_bin_start));
		fsd_proc.is_boot_server = true;
		setup_fsd_mappings(fsd_proc, board::FS_PARTITION_START_SECTOR, false);
		fsd_pid = fsd_proc.pid;
		supervisor_register("fsd", (char*)&_binary_fsd_bin_start, (char*)&_binary_fsd_bin_end,
			true, board::FS_PARTITION_START_SECTOR, false, &fsd_pid, fsd_proc);
		io::print("fsd created\n");

		// A second, simultaneously-mounted fsd instance, reachable under
		// the "/2/" prefix (see fsd2_pid's own comment in process.c3) —
		// spawned from the *same* fsd binary, just pointed at a different
		// partition. Exactly two static mounts, not a general N; see
		// docs/devlog.md for why that's the right scope for the actual
		// problem this solves (testing FAT32 and ext2 simultaneously,
		// without physically swapping FS_PARTITION_START_SECTOR and
		// reflashing). Same "must be set before any later create_process
		// call populates a default namespace" ordering constraint as
		// fsd_pid above.
		if (board::HAS_SECOND_FS_PARTITION)
		{
			Process* fsd2_proc = create_process((void*)&_binary_fsd_bin_start, (uint)((uptr)&_binary_fsd_bin_end - (uptr)&_binary_fsd_bin_start));
			fsd2_proc.is_boot_server = true;
			setup_fsd_mappings(fsd2_proc, board::FS_PARTITION_2_START_SECTOR, true);
			fsd2_pid = fsd2_proc.pid;
			supervisor_register("fsd2", (char*)&_binary_fsd_bin_start, (char*)&_binary_fsd_bin_end,
				true, board::FS_PARTITION_2_START_SECTOR, true, &fsd2_pid, fsd2_proc);
			io::print("fsd2 created\n");
		}
	}

	// procd (the "/proc/" server, user/procd.c3) — unconditional on
	// every board, unlike diskd/sdd/fsd/fsd2: it has no storage-hardware
	// dependency, just SYS_PROC_INFO, which every process can already
	// call. Spawned last, after every board-conditional server above, so
	// it never disturbs their own hardcoded pid conventions (echod=2,
	// fsd.c3's own DISKD_PID=3) regardless of which of
	// HAS_BLOCK_DEVICE/HAS_SECOND_FS_PARTITION are set. Same "must be set
	// before any later create_process call populates a default
	// namespace" ordering constraint as fsd_pid/fsd2_pid above.
	Process* procd_proc = create_process((void*)&_binary_procd_bin_start, (uint)((uptr)&_binary_procd_bin_end - (uptr)&_binary_procd_bin_start));
	procd_proc.is_boot_server = true;
	procd_pid = procd_proc.pid;
	supervisor_register("procd", (char*)&_binary_procd_bin_start, (char*)&_binary_procd_bin_end,
		false, 0, false, &procd_pid, procd_proc);
	io::print("procd created\n");

	// envd (the "/env/" server, user/envd.c3) — same unconditional,
	// spawned-right-after-procd reasoning as procd's own comment above:
	// no storage-hardware dependency (just SYS_IPC_RECV_GEN/
	// SYS_PROC_INFO, both already usable by every process regardless of
	// board), and ordering still matters for the same reason
	// (create_process's default namespace population, right below).
	Process* envd_proc = create_process((void*)&_binary_envd_bin_start, (uint)((uptr)&_binary_envd_bin_end - (uptr)&_binary_envd_bin_start));
	envd_proc.is_boot_server = true;
	envd_pid = envd_proc.pid;
	supervisor_register("envd", (char*)&_binary_envd_bin_start, (char*)&_binary_envd_bin_end,
		false, 0, false, &envd_pid, envd_proc);
	io::print("envd created\n");

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
	create_process((void*)&_binary_shell_bin_start, (uint)((uptr)&_binary_shell_bin_end - (uptr)&_binary_shell_bin_start));
	io::print("shell created\n");

	// usbd (the USB host-controller driver, user/usbd.c3) — Duo only
	// (board::HAS_USB; QEMU's own riscv64 virt machine has no DWC2
	// equivalent). Spawned last, after every other server (including
	// the shell above): unlike diskd/fsd, nothing hardcodes usbd's pid
	// yet (Phase 1 is bring-up + HPRT polling only, no IPC clients), so
	// there's no fixed-slot convention to preserve by spawning it
	// earlier.
	if (board::HAS_USB)
	{
		Process* usbd_proc = create_process((void*)&_binary_usbd_bin_start, (uint)((uptr)&_binary_usbd_bin_end - (uptr)&_binary_usbd_bin_start));
		usbd_proc.is_boot_server = true;
		setup_usbd_mappings(usbd_proc);
		io::print("usbd created\n");
	}

	// ethd (the real Ethernet MAC driver, user/ethd.c3) — Duo only —
	// or netd (virtio-net, user/netd.c3) — QEMU only — mutually
	// exclusive, same board::HAS_ETH_MAC/HAS_VIRTIO_NET shape as
	// board::HAS_SD_BLOCK/HAS_VIRTIO_BLOCK gates diskd vs sdd. Spawned
	// last, same reasoning as usbd above: no fixed-slot convention to
	// preserve yet, Phase 1 has no IPC clients.
	if (board::HAS_ETH_MAC)
	{
		Process* ethd_proc = create_process((void*)&_binary_ethd_bin_start, (uint)((uptr)&_binary_ethd_bin_end - (uptr)&_binary_ethd_bin_start));
		ethd_proc.is_boot_server = true;
		setup_ethd_mappings(ethd_proc);
		io::print("ethd created\n");
	}
	if (board::HAS_VIRTIO_NET)
	{
		Process* netd_proc = create_process((void*)&_binary_netd_bin_start, (uint)((uptr)&_binary_netd_bin_end - (uptr)&_binary_netd_bin_start));
		netd_proc.is_boot_server = true;
		setup_netd_mappings(netd_proc);
		io::print("netd created\n");
	}

	// gpiod (the GPIO driver, user/gpio/gpiod.c3) — Duo only
	// (board::HAS_GPIO; QEMU's own riscv64 virt machine has no matching
	// hardware). Spawned last, same reasoning as usbd/ethd above: no
	// fixed-slot convention to preserve, no IPC clients until something
	// dynamically ns_mount_wait()s "/srv/gpiod/" the way mountusb does
	// for usbd.
	if (board::HAS_GPIO)
	{
		Process* gpiod_proc = create_process((void*)&_binary_gpiod_bin_start, (uint)((uptr)&_binary_gpiod_bin_end - (uptr)&_binary_gpiod_bin_start));
		gpiod_proc.is_boot_server = true;
		setup_gpiod_mappings(gpiod_proc);
		io::print("gpiod created\n");
	}

	// Single call site for create_process(shell) below (a *respawn*
	// only now — the initial spawn is explicit above), used once idle
	// notices nothing else is runnable (e.g. the shell itself exiting).
	for (;;)
	{
		bool shell_running = false;
		for (int i = 0; i < PROCS_MAX; i++)
		{
			if (procs[i].state == PROC_RUNNABLE && procs[i].pid > 0)
			{
				shell_running = true;
				break;
			}
		}
		if (!shell_running)
		{
			create_process((void*)&_binary_shell_bin_start, (uint)((uptr)&_binary_shell_bin_end - (uptr)&_binary_shell_bin_start));
		}

		yield();
	}
}

