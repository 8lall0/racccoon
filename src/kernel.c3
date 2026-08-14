module kernel;

import std::io;
import panic;

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

	io::print("2: Trap handler set\n");

	virtio_blk_init();
	fs_init();

	idle_proc = create_process(null, 0);
	io::print("3: Idle created\n");

	idle_proc.pid = 0;
	current_proc = idle_proc;

	io::print("4: Idle configured\n");

	create_process((void*)&_binary_shell_bin_start, (uint)&_binary_shell_bin_size);
	io::print("5: Shell process created\n");

	idle_entry();

	io::print("6: Should never reach here\n");

	panic::panic("BOOTED");
}

fn void idle_entry()
{
	io::print("Idle process started\n");
	for (;;)
	{
		yield();
	}
}

