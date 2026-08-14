module kernel;

import panic;
import libc;
import std::io;

const PROCS_MAX     = 8; // Maximum number of processes
const PROC_UNUSED   = 0; // Unused process control structure
const PROC_RUNNABLE = 1; // Runnable process
// 8192 was enough for the syscall-only trap path (getchar/putchar), but the
// file-system call chain (handle_syscall -> fs_lookup/fs_flush ->
// read_write_disk -> virtq_kick/virtq_is_busy) overflowed it, corrupting
// adjacent Process structs in the procs[] array. Confirmed by reproducing
// with this bumped up and the corruption disappearing.
const STACK_SIZE    = 65536; // Stack size

struct Process
{
	int pid; // Process ID
	int state; // Process state: PROC_UNUSED or PROC_RUNNABLE
	uint sp; // Stack pointer
	uint* page_table;
	char[STACK_SIZE] stack; // Kernel stack
}

fn void switch_context(uint* prev_sp, uint* next_sp, uint satp, uint sscratch) @naked @noinline
{
	asm(`
        addi sp, sp, -13 * 4
        sw ra,  0  * 4(sp)
        sw s0,  1  * 4(sp)
        sw s1,  2  * 4(sp)
        sw s2,  3  * 4(sp)
        sw s3,  4  * 4(sp)
        sw s4,  5  * 4(sp)
        sw s5,  6  * 4(sp)
        sw s6,  7  * 4(sp)
        sw s7,  8  * 4(sp)
        sw s8,  9  * 4(sp)
        sw s9,  10 * 4(sp)
        sw s10, 11 * 4(sp)
        sw s11, 12 * 4(sp)
        sw sp, (a0)

        sfence.vma
        csrw satp, a2
        sfence.vma
        csrw sscratch, a3

        lw sp, (a1)
        lw ra,  0  * 4(sp)
        lw s0,  1  * 4(sp)
        lw s1,  2  * 4(sp)
        lw s2,  3  * 4(sp)
        lw s3,  4  * 4(sp)
        lw s4,  5  * 4(sp)
        lw s5,  6  * 4(sp)
        lw s6,  7  * 4(sp)
        lw s7,  8  * 4(sp)
        lw s8,  9  * 4(sp)
        lw s9,  10 * 4(sp)
        lw s10, 11 * 4(sp)
        lw s11, 12 * 4(sp)
        addi sp, sp, 13 * 4
        ret
    `);
}

const SSTATUS_SPIE = (1 << 5);
const SSTATUS_SUM   = (1 << 18); // let S-mode access U-mode pages (needed for syscalls like readfile/writefile that dereference user pointers directly)

fn void user_entry() @naked @noinline @noreturn
{
	// USER_BASE (kernel.c3's const of the same name) and
	// SSTATUS_SPIE|SSTATUS_SUM (0x40020, this file's consts above)
	// hardcoded: compile-time asm() only supports %s substitution, so the
	// constants can't be interpolated here. USER_BASE must also match
	// user/user.ld's base address.
	asm(`
        li t0, 0x1000000
        csrw sepc, t0
        li t1, 0x40020
        csrw sstatus, t1
        sret
    `);
}

Process[PROCS_MAX] procs; // All process control structures.

fn Process* create_process(void* image, uint image_size)
{
	// Find an unused process control structure.
	Process* proc = null;
	int i;
	for (i = 0; i < PROCS_MAX; i++)
	{
		if (procs[i].state == PROC_UNUSED)
		{
			proc = &procs[i];
			break;
		}
	}

	if (!proc)
	{
		panic::panic("no free process slots");
	}

	uint* sp = (uint*)&proc.stack;
	sp += STACK_SIZE / 4;
	for (int j = 0; j < 12; j++)
	{
		*(--sp) = 0;
	}
	// Setting RA
	*(--sp) = (uint)&user_entry;

	uint* page_table = (uint*)alloc_pages(1);
	for (uint paddr = (uint)&__kernel_base; paddr < (uint)&__free_ram_end; paddr += PAGE_SIZE)
	{
		map_page(page_table, paddr, paddr, PAGE_R | PAGE_W | PAGE_X);
	}
	// virtio-blk MMIO registers: outside the kernel image/RAM range above,
	// but syscalls like SYS_WRITEFILE reach the driver (fs_flush ->
	// read_write_disk) from inside a process's own page table, not just
	// from kernel_main's bare-addressing bring-up.
	map_page(page_table, VIRTIO_BLK_PADDR, VIRTIO_BLK_PADDR, PAGE_R | PAGE_W);

	// PLIC registers: same reasoning as virtio-blk above — handle_trap's
	// plic_claim()/plic_complete() run under whichever process's page
	// table happens to be active when the interrupt arrives, since
	// read_write_disk's wfi wait can be reached from inside a syscall.
	// Three separate pages, not a range — see plic.c3.
	map_page(page_table, PLIC_PRIORITY_PAGE, PLIC_PRIORITY_PAGE, PAGE_R | PAGE_W);
	map_page(page_table, PLIC_ENABLE_PAGE, PLIC_ENABLE_PAGE, PAGE_R | PAGE_W);
	map_page(page_table, PLIC_CLAIM_PAGE, PLIC_CLAIM_PAGE, PAGE_R | PAGE_W);

	// Copy the process image into freshly allocated user pages, page by page.
	char* img = image;
	for (uint off = 0; off < image_size; off += PAGE_SIZE)
	{
		uint page          = alloc_pages(1);
		uint remaining     = image_size - off;
		uint copy_size     = remaining < PAGE_SIZE ? remaining : PAGE_SIZE;

		mem::copy((void*)page, img + off, (sz)copy_size);
		map_page(page_table, USER_BASE + off, page, PAGE_U | PAGE_R | PAGE_W | PAGE_X);
	}

	// Initialize fields.
	proc.pid = i + 1;
	proc.state = PROC_RUNNABLE;
	proc.sp = (uint)sp;
	proc.page_table = page_table;
	return proc;
}

Process* current_proc; // Currently running process
Process* idle_proc;    // Idle process

fn void yield() @noinline
{
	Process* next = idle_proc;
	for (int i = 0; i < PROCS_MAX; i++)
	{
		Process* proc = &procs[(current_proc.pid + i) % PROCS_MAX];
		if (proc.state == PROC_RUNNABLE && proc.pid > 0)
		{
			next = proc;
			break;
		}
	}

	if (next == current_proc)
	{
		return;
	}

	Process* prev = current_proc;
	current_proc = next;

	switch_context(&prev.sp, &next.sp, ((uint)next.page_table >> 12) | 0x80000000, (uint)&next.stack + STACK_SIZE);
}