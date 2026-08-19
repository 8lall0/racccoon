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
	create_process((void*)&_binary_echod_bin_start, (uint)((uptr)&_binary_echod_bin_end - (uptr)&_binary_echod_bin_start));
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
			setup_sdd_mappings(sdd_proc);
			io::print("sdd created\n");
		}
		else if (board::HAS_VIRTIO_BLOCK)
		{
			Process* diskd_proc = create_process((void*)&_binary_diskd_bin_start, (uint)((uptr)&_binary_diskd_bin_end - (uptr)&_binary_diskd_bin_start));
			setup_diskd_mappings(diskd_proc);
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
		setup_fsd_mappings(fsd_proc, board::FS_PARTITION_START_SECTOR);
		fsd_pid = fsd_proc.pid;
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
			setup_fsd_mappings(fsd2_proc, board::FS_PARTITION_2_START_SECTOR);
			fsd2_pid = fsd2_proc.pid;
			io::print("fsd2 created\n");
		}
	}

	// Single call site for create_process(shell), used for both the
	// initial spawn and every respawn once idle notices nothing else is
	// runnable.
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

