module kernel;

// SMP scheduler, Stage B (docs/roadmap.md §8, docs/devlog.md): a real
// test-and-set spinlock plus a per-hart interrupt-disable nest, and the
// first shared kernel structures put behind them (the page allocator, the
// keyboard queue, the procs[] slot table — see allocation.c3 / kbd.c3 /
// process.c3).
//
// Nothing contends these yet. Stage A left the kernel with exactly one
// scheduling hart (this_hartid() in smp.c3 is still a constant), so every
// acquire() here wins its first swap. What the locks buy today:
//   - the guarded structures are already correct for the day a second
//     hart starts running kernel code (Stage C), with no scramble to
//     retrofit them under a working scheduler,
//   - irq_push_off() closes a real *single-hart* reentrancy hole: the
//     timer tick runs supervisor_tick() -> create_process() -> alloc_pages()
//     mid-trap, so an alloc_lock taken in a syscall path could be
//     re-entered by the tick on the same hart. Disabling S-mode
//     interrupts for the critical section is what makes that safe.
//
// Deliberately NOT locked in Stage B: console output (sbi::__putchar).
// Interleaved console writes are cosmetic, never corruption, and a naive
// console lock deadlocks the panic path (panic() prints while something
// else may hold it). That needs a panic-aware lock-break — a Stage C item.

// --- raw atomics -----------------------------------------------------------
// The kernel is built with the A extension (scripts/build.sh:
// --riscv-cpu=rvimac, llc -mattr=+a), so amoswap.w is always available on
// both QEMU virt and the C906. @naked + a0/a1-by-ABI, same shape as
// switch_context / flush_tlb_page in process.c3 — these must NOT bridge
// through the read_reg_tmp / write_csr_tmp globals (not reentrant, and a
// hazard the moment a second hart exists — see smp.c3's own note).

// amoswap.w with acquire ordering: atomically stores `newval` at *word and
// returns the previous value. a0 = word, a1 = newval, result in a0.
fn uint amoswap_w_acquire(uint* word, uint newval) @naked @noinline
{
	asm(`
        amoswap.w.aq a0, a1, (a0)
        ret
    `);
}

// amoswap.w with release ordering, result discarded. a0 = word, a1 = newval.
fn void amoswap_w_release(uint* word, uint newval) @naked @noinline
{
	asm(`
        amoswap.w.rl zero, a1, (a0)
        ret
    `);
}

// Atomically clear sstatus.SIE (bit 1) and return the FULL prior sstatus,
// so the caller can tell whether interrupts had been enabled. Single
// instruction, no memory bridge.
fn ulong sstatus_clear_sie() @naked @noinline
{
	asm(`
        csrrci a0, sstatus, 2
        ret
    `);
}

// --- per-hart interrupt-disable nest -------------------------------------
// xv6's push_off/pop_off: nested acquire()s stack, and S-mode interrupts
// come back on only when the outermost release() unwinds — and only if
// they were on when the nest was first entered. Indexed by this_hartid()
// so it is already per-hart; in Stage B every access is hart 0's slot.
struct IrqNest
{
	int  depth;
	bool were_enabled; // sstatus.SIE state when depth went 0 -> 1
}

IrqNest[SMP_MAX_HARTS] g_irq_nest;

fn void irq_push_off() @noinline
{
	ulong prev = sstatus_clear_sie();
	IrqNest* n = &g_irq_nest[this_hartid()];
	if (n.depth == 0)
	{
		n.were_enabled = (prev & SSTATUS_SIE) != 0;
	}
	n.depth++;
}

fn void irq_pop_off() @noinline
{
	IrqNest* n = &g_irq_nest[this_hartid()];
	// Underflow guard: a stray pop with no matching push is a kernel bug,
	// but clamping beats leaving depth negative (which would then never
	// re-enable interrupts).
	if (n.depth > 0) { n.depth--; }
	if (n.depth == 0 && n.were_enabled)
	{
		asm(`csrsi sstatus, 2`);
	}
}

// --- the lock ------------------------------------------------------------
// One 32-bit word. Held with S-mode interrupts off on the holding hart
// (irq_push_off), so a lock taken in a syscall path can't be re-entered by
// that hart's own timer tick. Not recursive — acquiring a Spinlock the
// current hart already holds deadlocks (Stage B: silently; Stage C will
// add a holder check).
struct Spinlock
{
	uint locked;
}

fn void Spinlock.acquire(&self) @noinline
{
	irq_push_off();
	// Uncontended in Stage B — the loop body never runs. The compiler
	// can't hoist the amoswap (it's an opaque asm with a memory side
	// effect), so this is a correct spin for Stage C too.
	while (amoswap_w_acquire(&self.locked, 1) != 0)
	{
		asm(`nop`);
	}
}

fn void Spinlock.release(&self) @noinline
{
	amoswap_w_release(&self.locked, 0);
	irq_pop_off();
}
