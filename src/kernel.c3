module kernel;

import std::io;

// Also hardcoded (can't be interpolated into compile-time asm() strings,
// see write_reg's comment in entry.c3) as the literal 0x1000000 in
// process.c3's user_entry() and in user/user.ld's base address. Keep all
// three in sync if this ever changes.
const USER_BASE = 0x1000000;

char[] __kernel_base @export("__kernel_base");
char[] __bss @export("__bss");
char[] __bss_end @export("__bss_end");
char[] __stack_top @export("__stack_top");
char[] __free_ram @export("__free_ram");
char[] __free_ram_end @export("__free_ram_end");
extern char[] _binary_shell_bin_start @cname("_binary_shell_bin_start");
extern char[] _binary_shell_bin_size @cname("_binary_shell_bin_size");
extern char[] _binary_echod_bin_start @cname("_binary_echod_bin_start");
extern char[] _binary_echod_bin_size @cname("_binary_echod_bin_size");
extern char[] _binary_diskd_bin_start @cname("_binary_diskd_bin_start");
extern char[] _binary_diskd_bin_size @cname("_binary_diskd_bin_size");
extern char[] _binary_fsd_bin_start @cname("_binary_fsd_bin_start");
extern char[] _binary_fsd_bin_size @cname("_binary_fsd_bin_size");

fn void boot() @naked @export("boot") @section(".text.boot") @noinline @nostrip @used
{
	asm(`
        la sp, __stack_top
        j kernel_main
    `);
}

fn void kernel_main() @export("kernel_main") @noinline @nostrip
{
	mem::set(&__bss, 0, (sz)((uint)&__bss_end - (uint)&__bss));

	io::print("1: BSS cleared\n");

	write_reg("stvec", "kernel_entry");

	// Trap-frame anchor for traps taken *before* the first switch_context
	// call (i.e. while running kernel_main itself, bare-mode, no process
	// yet). See boot_trap_stack's comment in entry.c3 for why this is a
	// dedicated buffer and not __stack_top itself. Must be set before any
	// interrupt can actually fire — kernel_entry's very first instruction
	// (csrrw sp, sscratch, sp) would otherwise swap in garbage and build
	// the trap frame at a bogus address.
	write_csr("sscratch", (uint)&boot_trap_stack + boot_trap_stack.len);

	plic_init();
	enable_external_interrupts();

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
	create_process((void*)&_binary_echod_bin_start, (uint)&_binary_echod_bin_size);
	io::print("Idle process started\n");

	// diskd next (see user/diskd.c3, microkernel plan phase 4) — created
	// after echod so echod keeps its pid-2 convention above.
	Process* diskd_proc = create_process((void*)&_binary_diskd_bin_start, (uint)&_binary_diskd_bin_size);
	setup_diskd_mappings(diskd_proc);
	io::print("diskd created\n");

	// fsd (see user/fsd.c3, microkernel plan phase 5) — the filesystem,
	// now entirely out of the kernel. Created after diskd so diskd is
	// already registered (diskd_pid) by the time fsd's own fs_init()
	// (run the first time the scheduler picks it, same as any other
	// process) sends it a request. fsd_pid has to be set before ANY
	// later create_process call populates a default namespace, since
	// that's where it's actually consumed — every process created from
	// here on (i.e. every shell) gets a working "" -> fsd mount;
	// idle/echod/diskd, created before this line, don't and don't need
	// to (see process.c3's create_process).
	Process* fsd_proc = create_process((void*)&_binary_fsd_bin_start, (uint)&_binary_fsd_bin_size);
	fsd_pid = fsd_proc.pid;
	io::print("fsd created\n");

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
			create_process((void*)&_binary_shell_bin_start, (uint)&_binary_shell_bin_size);
		}

		yield();
	}
}

