module kernel;

import std::io;
import panic;
import board;
import sbi;

const SCAUSE_ECALL             = 8;
// RV64 port: the interrupt bit is scause's MSB — bit 63 on RV64, not
// bit 31 as on RV32. This is a real correctness-critical difference,
// not just a width bump; getting it wrong silently misclassifies every
// interrupt as an exception (or vice versa).
const ulong SCAUSE_INTERRUPT_BIT = (1ul << 63);
const SCAUSE_SUPERVISOR_EXTERNAL = 9;        // interrupt cause code for a PLIC-routed external interrupt — same code on both XLENs
const SCAUSE_SUPERVISOR_TIMER    = 5;        // interrupt cause code for a real timer interrupt (sstc's stimecmp) — same code on both XLENs

// Dedicated trap-frame anchor for traps taken during kernel_main's
// bare-mode phase, between enable_external_interrupts() and the first
// process existing — a brief window, but interrupts are live during it.
// Deliberately NOT __stack_top:
// __stack_top is the *top* of the live boot stack kernel_main is actively
// executing on, not a spare/unused region — anchoring sscratch there
// means the trap frame plus handle_trap's own call depth (io::printfn,
// plic_claim, ...) grows down from the top of a stack kernel_main is
// simultaneously using several frames deep into, and collides with it.
// A real process doesn't have this problem: its sscratch points at its
// own dedicated 64KB stack, which nothing else is using concurrently.
// This buffer plays that same "dedicated, nothing else touches it" role
// for the brief pre-process window.
char[4096] boot_trap_stack;

// Syscall numbers. Kernel and user are separate c3c compilations with no
// shared header, so these must be kept in sync by hand with the SYS_*
// consts in user/user.c3.
const SYS_PUTCHAR   = 1;
const SYS_GETCHAR   = 2;
const SYS_EXIT      = 3;
// 4 and 5 were SYS_READFILE/SYS_WRITEFILE — removed once fsd (user/fsd.c3)
// took over file access entirely (microkernel plan phase 5). Left unused
// rather than renumbered, matching user/user.c3's copy.
const SYS_IPC_SEND  = 6;
const SYS_IPC_RECV  = 7;
const SYS_NS_RESOLVE = 8;
const SYS_DISKD_INFO = 9; // diskd-only: returns its vq/req physical addrs
const SYS_IPC_POLL   = 10; // non-blocking SYS_IPC_RECV, see its case below
const SYS_RFORK       = 11;
const SYS_NS_UNMOUNT  = 12; // remove one of the caller's own namespace mounts by exact prefix
const SYS_JOIN        = 13; // block until the given pid no longer exists — see its case below
const SYS_FS_PARTITION_INFO = 14; // fsd-only: returns current_proc.fs_partition_start —
                                    // board is a kernel-only module (see user/sdd.c3's own
                                    // header comment), so this is fsd.c3's only way to learn
                                    // a board-specific fact despite being one board-agnostic
                                    // user binary, same shape as SYS_DISKD_INFO above. Reads
                                    // the CALLER's own per-process field, not a single shared
                                    // board constant directly — see process.c3's
                                    // setup_fsd_mappings()/fs_partition_start comments for why:
                                    // two fsd instances can be mounted simultaneously now, each
                                    // needing a different answer to this same syscall.
const SYS_FUTEX_WAIT = 15; // block while *addr == expected — see its case below
const SYS_FUTEX_WAKE = 16; // wake every waiter blocked on addr in this address space

// SYS_NS_MOUNT_WAIT's own attempt-count argument is a plain, caller-
// supplied ulong with no cap of its own — see that case's comment for
// why a hard ceiling here is worth having even though every legitimate
// caller already asks for far less (the largest today,
// user/shell.c3's own MOUNTUSB_WAIT_ATTEMPTS, is 2,000,000).
const ulong NS_MOUNT_WAIT_MAX_ATTEMPTS = 50000000;
const SYS_PROC_INFO  = 17; // procd-only in practice, but open to any caller — see its case below
const SYS_KILL       = 18; // procd-only in practice (the /proc/<pid>/ctl write path), open to any caller — see its case below
const SYS_IPC_RECV_GEN = 19; // same as SYS_IPC_RECV, plus the sender's generation — see its case below
const SYS_IPC_REPLY    = 20; // same as SYS_IPC_SEND, plus an optional target-generation check — see its case below
const SYS_SRV_POST     = 21; // posts current_proc under a short name in the global srv_table — see its case below
const SYS_NS_MOUNT     = 22; // binds a posted srv_table name at a path prefix in the caller's own namespace — see its case below
const SYS_PARENT_INFO  = 23; // returns a process's parent pid/generation, if it has one — see its case below
const SYS_EXEC         = 24; // replaces the calling process's own image in place — see its case below
const SYS_SETUID       = 25; // sets the caller's own uid, only while still root — see its case below
const SYS_NS_MOUNT_WAIT = 26; // SYS_NS_MOUNT, but blocks (bounded by a retry count) until the target actually posts — see its case below
const SYS_YIELD         = 27; // voluntarily gives up the rest of this process's timeslice once — see its case below
const SYS_USBD_INFO     = 28; // usbd-only: returns its DMA buffer's physical address — same shape/reasoning as SYS_DISKD_INFO above
const SYS_NETD_INFO     = 29; // netd-only: returns its RX/TX virtqueue physical addresses, plus (Ethernet Phase 2) its packet-buffer page — see its case below
const SYS_ETHD_INFO     = 30; // ethd-only: returns its DMA region's physical address (Ethernet Phase 2) — same shape/reasoning as SYS_USBD_INFO above
const SYS_KBD_PUSH      = 31; // usbd-only in practice: pushes one decoded USB-keyboard byte into the kernel keystroke queue SYS_GETCHAR drains (src/kbd.c3) — see its case below
const SYS_DRIVER_IRQ_ARM = 32; // interrupt-driven driver: re-enable this driver's PLIC source, disabled by handle_trap on each fire (level source); the source is the one the caller registered in the Irq_route table (process.c3) — see its case below
const SYS_SDD_INFO      = 33; // sdd-only: returns its SDMA staging buffer's physical address — see its case below

// Generous cap on the image SYS_EXEC will install — real racccoon
// binaries (build/user/*.bin) run 70-105KB; this leaves real headroom
// without being large enough to make a single runaway request a
// meaningful way to exhaust physical memory. user/user.c3's own
// exec() wrapper enforces the same bound on its own read-into-buffer
// loop before ever reaching this syscall.
const EXEC_MAX_IMAGE_SIZE  = 262144;
const EXEC_MAX_IMAGE_PAGES = EXEC_MAX_IMAGE_SIZE / PAGE_SIZE;

// argv blob cap (user/user.c3's exec(), NUL-separated strings packed
// right after the image in the same buffer) — one page is plenty for
// real CLI args, and keeps this a small, fixed second staging pass
// distinct from the image's own.
const EXEC_MAX_ARGV_SIZE  = 4096;
const EXEC_MAX_ARGV_PAGES = EXEC_MAX_ARGV_SIZE / PAGE_SIZE;

// Real ELF64/RISC-V executables (racccoon's own toolchain output,
// build/user/*.elf, before objcopy strips it to a flat binary) can be
// exec()'d too now, not just racccoon's own flat-binary format — see
// SYS_EXEC's own case. 8 PT_LOAD segments is generous headroom; a real
// binary from this toolchain needs 3 (confirmed via llvm-readelf on
// build/user/echod.elf: .text, .rodata, .data+.bss).
const EXEC_MAX_ELF_SEGMENTS = 8;

// rfork flags — Plan 9 names, this kernel's own subset. RFPROC is
// required (rfork() without it returns -1 in this v1: real Plan 9 uses
// that combination to change the *caller's* own group membership in
// place, not meaningful yet here since there's nothing group-scoped
// besides memory to change). RFMEM shares the parent's address space
// instead of copying it — the one flag that turns this same call into
// "spawn a thread." See the SYS_RFORK case below and process.c3's
// fork_entry for the full mechanism.
const int RFPROC = 1 << 0;
const int RFMEM  = 1 << 1;

// Sentinel msg_type handle_trap posts to wake an interrupt-driven
// driver when its PLIC source fires (see handle_trap's interrupt branch
// and the Irq_route table in process.c3) — distinguishes "your device
// fired, go check its status register" from an actual client request in
// the driver's single inbox slot. Opaque to the driver: diskd, sdd,
// usbd all treat it the same way. Named for its first user; must match
// user/diskd.c3's copy (and user/sdd.c3, user/usb/dwc2.c3).
const uint DISKD_IRQ_NOTIFY = 0xFFFFFFFF;

// RV64 port: these bridge globals carry full CSR values now (sepc/satp
// hold real 64-bit addresses; sstatus/sie are 64-bit bitfields), so they
// widen from uint to ulong — and every asm block bridging through them
// uses sd/ld instead of sw/lw accordingly.
ulong read_reg_tmp @export("read_reg_tmp");

macro read_reg(String $reg)
{
	// Bridged through memory (t0/t1), not a0: the previous version read the
	// CSR into a0 via opaque string asm(), which the compiler can't see the
	// side effects of. Any caller that still has a value live in a0 at this
	// point (e.g. a pointer parameter it hasn't spilled) gets it silently
	// clobbered — this corrupted handle_trap's own Trap_frame* parameter in
	// practice, since the compiler had no reason to move it out of a0.
	asm(@sprintf(`
        csrr t0, %s
        la t1, read_reg_tmp
        sd t0, 0(t1)
    `, $reg));
	return read_reg_tmp;
}

macro write_reg(String $reg, String $value)
{
	// Single asm() call: two separate asm() statements bridging a value
	// through t0 can be reordered/interleaved by the optimizer, since it
	// doesn't know t0 must stay live across them (this bit us for real:
	// stvec ended up not pointing at kernel_entry until this was merged).
	asm(@sprintf(`
        la t0, %s
        csrw %s, t0
    `, $value, $reg));
}

ulong write_sepc_tmp @export("write_sepc_tmp");

fn void write_sepc(ulong value) @noinline
{
	// Single asm() call, bridged through a memory location rather than a
	// register: a normal (non-naked) function gives no guarantee about
	// which register `value` lives in by the time this runs, and splitting
	// this across separate asm() statements reintroduces the reordering
	// hazard described on write_reg.
	write_sepc_tmp = value;
	asm(`
        la t0, write_sepc_tmp
        ld t0, 0(t0)
        csrw sepc, t0
    `);
}

ulong write_csr_tmp @export("write_csr_tmp");

macro write_csr(String $reg, value)
{
	// Same memory-bridged, single-atomic-asm() pattern as write_sepc,
	// generalized to any CSR name (known at compile time, so @sprintf's
	// %s-only limitation is fine here).
	write_csr_tmp = value;
	asm(@sprintf(`
        la t0, write_csr_tmp
        ld t0, 0(t0)
        csrw %s, t0
    `, $reg));
}

const SIE_SEIE     = (1 << 9);  // sie: supervisor external interrupt enable
const SSTATUS_SIE  = (1 << 1);  // sstatus: global supervisor interrupt enable
// SSTATUS_SPIE (what sret restores SIE from — see handle_trap's own end,
// below) is process.c3's own const, not redeclared here: unlike
// DISKD_READ/etc across the separate user-mode binaries, entry.c3 and
// process.c3 compile into one shared kernel module, so a duplicate name
// is a real conflict, not a harmless copy.
const SCOUNTEREN_TM = (1 << 1); // scounteren: lets U-mode execute rdtime without trapping

fn void enable_external_interrupts()
{
	write_csr("sie", read_reg("sie") | SIE_SEIE);
	write_csr("sstatus", read_reg("sstatus") | SSTATUS_SIE);
}

// Arms the next timer interrupt via the SBI legacy set_timer call
// (sbi::__set_timer) — deliberately not a direct write to stimecmp
// (the sstc extension's own S-mode-writable CSR): confirmed on real
// Milk-V Duo hardware that writing stimecmp directly hangs the board
// silently (see docs/devlog.md and sbi::__set_timer's own comment for
// the full story — likely menvcfg.STCE not being set by the Duo's own
// firmware, unlike QEMU's OpenSBI). The SBI ecall asks M-mode firmware
// to do the actual timer-comparator programming instead, needing no
// such S-mode CSR permission at all. A supervisor timer interrupt
// (SCAUSE_SUPERVISOR_TIMER) fires once `time` reaches `now +
// delta_ticks`; handle_trap's own timer case re-arms it every time it
// fires, or the same interrupt would immediately refire forever (an
// interrupt storm, not a periodic tick) — see that case's own comment.
fn void arm_timer(ulong delta_ticks)
{
	ulong now = read_reg("time");
	sbi::__set_timer(now + delta_ticks);
}

const SIE_STIE = (1 << 5); // sie: supervisor timer interrupt enable

// Total real timer interrupts handled since boot — inert bookkeeping,
// not consulted by anything yet, but real, useful infrastructure for
// whatever needs to observe "is this firing, how often" later (this
// session's own verification used it directly — see docs/devlog.md).
ulong timer_tick_count = 0;

// Real preemptive-scheduling support (see docs/devlog.md): the sstc
// timer interrupt fires, re-arms, and — for real processes — forces a
// reschedule via yield() (see the SCAUSE_SUPERVISOR_TIMER case in
// handle_trap below) instead of only ever returning to whatever was
// running. This is safe specifically because of where a timer
// interrupt can land: unlike a hand-placed yield() call (always at a
// caller-chosen, already-safe moment), an interrupt can in principle
// land in the middle of *anything* — but the interrupt-latency
// characteristic below establishes it can only ever land during
// genuine user-mode execution, never mid-syscall kernel bookkeeping
// (SYS_IPC_SEND's own multi-step state updates, mid-page-table-edit,
// etc.), so no new concurrent-access hazard is introduced there.
//
// Real interrupt-latency characteristic found while verifying this,
// and exactly why the above is safe: SYS_GETCHAR (and SYS_IPC_RECV,
// SYS_JOIN's poll loop — every *blocking* syscall in this kernel)
// busy-loops with yield() *inside its own still-open trap*, never
// reaching sret until its condition is met. Hardware auto-clears
// sstatus.SIE on trap entry and only restores it on sret — so while
// any process is stuck inside one of these (e.g. the shell idly
// waiting for a keystroke), sstatus.SIE stays globally disabled for
// every process switch_context() switches to in the meantime, not just
// the one that's blocked (SIE is one shared, un-banked hardware bit,
// switch_context is a plain software stack swap, not a trap return —
// nothing about it touches SIE). Confirmed directly: with the shell
// left idle, a timer armed for ~1s out didn't actually fire until
// whenever the next keystroke arrived, sometimes many seconds later;
// with the shell kept continuously busy (no idle GETCHAR wait), it
// fired reliably every ~1s as armed. Direct consequence: a timer
// interrupt can only ever land during genuine, uninterrupted user-mode
// execution — never inside any trap's own kernel-mode handling,
// regardless of how many yield()-driven switches happen inside it —
// which is what makes forcing a reschedule from this handler safe
// without any new locking.
//
// The other half of that safety — current_proc.pid > 0 in the
// SCAUSE_SUPERVISOR_TIMER case below — excludes idle_proc (pid 0),
// which covers two cases the argument above doesn't: kernel_main's own
// boot-time sequence (create_process/alloc_pages for echod/diskd/fsd/
// etc — real S-mode kernel code, not user-mode, and not reentrant —
// running with interrupts already on, since this function is called
// early in kernel_main), and idle's own post-boot respawn loop (which
// already calls yield() every iteration on its own, so forcing another
// one adds no benefit, only risk).
fn void enable_timer_interrupts()
{
	// Arm *before* enabling sie.STIE, not after: stimecmp's reset value
	// is implementation-defined and could easily be 0, which would make
	// `time >= stimecmp` already true the instant STIE goes live —
	// enabling the source with a real future deadline already in place
	// avoids that spurious-immediate-fire window entirely.
	arm_timer(board::TIMEBASE_HZ); // first tick ~1 second out
	write_csr("sie", read_reg("sie") | SIE_STIE);
}

// mcounteren.TM (M-mode -> S-mode) is expected to already be enabled by
// OpenSBI — standard practice, needed for any S-mode OS to read `time`
// at all — so nothing to do for this kernel's own S-mode access.
// scounteren.TM (S-mode -> U-mode) is this kernel's own responsibility,
// and was never set before this: any user-mode `rdtime` would have
// trapped. See user/sdd.c3's own real-time wait budgets (docs/devlog.md)
// for the actual motivation — busy-wait loops there used to be raw
// iteration counts with no real correspondence to wall-clock time.
fn void enable_user_timer_access()
{
	write_csr("scounteren", read_reg("scounteren") | SCOUNTEREN_TM);
}

// @align(4) alone is not reliably honored (found via disassembly diffing:
// unrelated code-size changes elsewhere shifted this function to a
// 2-byte-but-not-4-byte-aligned address in a real build). stvec's low 2
// bits ARE the trap mode field per the RISC-V spec (0=Direct, 1=Vectored,
// 2/3=Reserved) — writing a misaligned address here puts the CPU into
// Reserved trap mode, undefined behavior, which is almost certainly the
// real mechanism behind this project's whole string of "silent reboot,
// no trap ever printed" bugs blamed on the compiler. Pinned into its own
// section with linker-enforced alignment in kernel.ld instead, since the
// linker script's ALIGN() is what's actually trustworthy here.
//
// RV64 port: sd/ld instead of sw/lw, 8*N offsets instead of 4*N — every
// saved register is 8 bytes now, so the 31-word frame is 248 bytes, not
// 124.
fn void kernel_entry() @align(4) @section(".text.trap") @export("kernel_entry") @noinline @nostrip
{
	asm(`
        csrrw sp, sscratch, sp

        addi sp, sp, -8 * 31
        sd ra,  8 * 0(sp)
        sd gp,  8 * 1(sp)
        sd tp,  8 * 2(sp)
        sd t0,  8 * 3(sp)
        sd t1,  8 * 4(sp)
        sd t2,  8 * 5(sp)
        sd t3,  8 * 6(sp)
        sd t4,  8 * 7(sp)
        sd t5,  8 * 8(sp)
        sd t6,  8 * 9(sp)
        sd a0,  8 * 10(sp)
        sd a1,  8 * 11(sp)
        sd a2,  8 * 12(sp)
        sd a3,  8 * 13(sp)
        sd a4,  8 * 14(sp)
        sd a5,  8 * 15(sp)
        sd a6,  8 * 16(sp)
        sd a7,  8 * 17(sp)
        sd s0,  8 * 18(sp)
        sd s1,  8 * 19(sp)
        sd s2,  8 * 20(sp)
        sd s3,  8 * 21(sp)
        sd s4,  8 * 22(sp)
        sd s5,  8 * 23(sp)
        sd s6,  8 * 24(sp)
        sd s7,  8 * 25(sp)
        sd s8,  8 * 26(sp)
        sd s9,  8 * 27(sp)
        sd s10, 8 * 28(sp)
        sd s11, 8 * 29(sp)

        csrr a0, sscratch
        sd a0, 8 * 30(sp)

        addi a0, sp, 8 * 31

        csrw sscratch, a0
        mv a0, sp
        call handle_trap

        ld ra,  8 * 0(sp)
        ld gp,  8 * 1(sp)
        ld tp,  8 * 2(sp)
        ld t0,  8 * 3(sp)
        ld t1,  8 * 4(sp)
        ld t2,  8 * 5(sp)
        ld t3,  8 * 6(sp)
        ld t4,  8 * 7(sp)
        ld t5,  8 * 8(sp)
        ld t6,  8 * 9(sp)
        ld a0,  8 * 10(sp)
        ld a1,  8 * 11(sp)
        ld a2,  8 * 12(sp)
        ld a3,  8 * 13(sp)
        ld a4,  8 * 14(sp)
        ld a5,  8 * 15(sp)
        ld a6,  8 * 16(sp)
        ld a7,  8 * 17(sp)
        ld s0,  8 * 18(sp)
        ld s1,  8 * 19(sp)
        ld s2,  8 * 20(sp)
        ld s3,  8 * 21(sp)
        ld s4,  8 * 22(sp)
        ld s5,  8 * 23(sp)
        ld s6,  8 * 24(sp)
        ld s7,  8 * 25(sp)
        ld s8,  8 * 26(sp)
        ld s9,  8 * 27(sp)
        ld s10, 8 * 28(sp)
        ld s11, 8 * 29(sp)
        ld sp,  8 * 30(sp)
        sret
    `);
}

struct Trap_frame @packed
{
	ulong ra;
	ulong gp;
	ulong tp;
	ulong t0;
	ulong t1;
	ulong t2;
	ulong t3;
	ulong t4;
	ulong t5;
	ulong t6;
	ulong a0;
	ulong a1;
	ulong a2;
	ulong a3;
	ulong a4;
	ulong a5;
	ulong a6;
	ulong a7;
	ulong s0;
	ulong s1;
	ulong s2;
	ulong s3;
	ulong s4;
	ulong s5;
	ulong s6;
	ulong s7;
	ulong s8;
	ulong s9;
	ulong s10;
	ulong s11;
	ulong sp;
}

// Extracted from handle_syscall's SYS_KILL case (2026-08-28 probe of
// the c3c switch-call landmine — see the case site). Kills an
// arbitrary target process: the write half of /proc/<pid>/ctl
// (user/procd.c3). Permission: root (uid 0) kills anyone, else only
// a same-uid caller — and only a *direct* SYS_KILL; procd is root so
// its own ctl handler re-checks the real requester first. a1 =
// expected generation (0 = wildcard), same stale-slot guard as
// SYS_JOIN. Known gap: a process blocked waiting on the target
// stays blocked forever (same as SYS_IPC_SEND's stale-pid gap).
fn void sys_kill(Trap_frame* f) @noinline
{
	int kill_pid = (int)f.a0;
	uint kill_expected_generation = (uint)f.a1;
	if (kill_pid == current_proc.pid)
	{
		// Same self-deadlock-shaped reasoning as SYS_JOIN's
		// own self-check, though the failure mode here is
		// different (this would tear down the very page
		// table the code performing the teardown is running
		// under) — reject; SYS_EXIT already exists for
		// killing yourself.
		f.a0 = (ulong)(-1);
		return;
	}
	Process* kill_target = proc_by_pid(kill_pid);
	if (kill_target == null || (kill_expected_generation != 0 && kill_target.generation != kill_expected_generation))
	{
		f.a0 = (ulong)(-1);
		return;
	}
	if (current_proc.uid != 0 && current_proc.uid != kill_target.uid)
	{
		f.a0 = (ulong)(-1);
		return;
	}

	// Leak-safety half of blocking_depth's own fix
	// (process.c3): this kill tears kill_target down regardless
	// of what it was doing (the same "any other process
	// currently blocked... is left blocked forever" gap this
	// case already accepts, just below) — without this, a
	// target killed while genuinely mid one of the blocking
	// waits that incremented blocking_depth would leak that
	// increment permanently. blocking_depth is only ever
	// consulted by fork_entry()'s own check now (not
	// kernel_entry's shared tail — see blocking_depth's own
	// comment for why not), so a leak here wouldn't wedge the
	// whole system, just make every future freshly-rfork()'d
	// child's own first sret conservatively start with
	// interrupts off — still worth closing cleanly rather than
	// leaving an ever-growing counter. kill_target.in_blocking_wait
	// isn't reset here: the slot is about to become PROC_UNUSED
	// and gets explicitly reset on its next reuse (SYS_RFORK's
	// own child.in_blocking_wait = false, create_process()'s
	// equivalent).
	if (kill_target.in_blocking_wait) blocking_depth--;

	// Same page-table-teardown-if-not-shared logic as
	// SYS_EXIT above, just targeting kill_target instead of
	// current_proc — see that case's own comment for the
	// full reasoning (shared-table rfork(RFPROC|RFMEM)
	// siblings, the 3-level Sv39 walk, etc.). Inlined for the
	// same reason SYS_EXIT is: a call out to a moderately
	// complex function from inside this switch has
	// reproducibly broken boot before.
	bool kill_table_shared = false;
	for (int kshare_i = 0; kshare_i < PROCS_MAX; kshare_i++)
	{
		if (&procs[kshare_i] == kill_target) continue;
		if (procs[kshare_i].state == PROC_UNUSED) continue;
		if (procs[kshare_i].page_table == kill_target.page_table)
		{
			kill_table_shared = true;
			break;
		}
	}

	if (!kill_table_shared)
	{
		ulong* kill_table2 = kill_target.page_table;
		for (uint kvpn2 = 0; kvpn2 < 512; kvpn2++)
		{
			if ((kill_table2[kvpn2] & PAGE_V) == 0) continue;
			ulong* kill_table1 = (ulong*)pte_to_paddr(kill_table2[kvpn2]);

			for (uint kvpn1 = 0; kvpn1 < 512; kvpn1++)
			{
				if ((kill_table1[kvpn1] & PAGE_V) == 0) continue;
				ulong* kill_table0 = (ulong*)pte_to_paddr(kill_table1[kvpn1]);

				for (uint kvpn0 = 0; kvpn0 < 512; kvpn0++)
				{
					if ((kill_table0[kvpn0] & PAGE_V) == 0) continue;
					if (kill_table0[kvpn0] & PAGE_U)
					{
						uptr kill_leaf_paddr = pte_to_paddr(kill_table0[kvpn0]);
						free_pages(kill_leaf_paddr, 1);
					}
				}

				free_pages((uptr)kill_table0, 1);
			}

			free_pages((uptr)kill_table1, 1);
		}
		free_pages((uptr)kill_table2, 1);
	}

	kill_target.state = PROC_UNUSED;
	kill_target.pid = 0;
	f.a0 = 0;
}

// exec()/exit() teardown: frees every page this process's table owns
// (PAGE_U leaves + the on-demand 2nd/3rd-level tables + the root),
// unless an rfork(RFPROC|RFMEM) sibling still shares the same
// page_table pointer. Then marks the slot PROC_UNUSED and yield()s,
// which never returns (the scan can't pick a PROC_UNUSED self).
// (Was inlined in handle_syscall as a c3c-0.8.2 landmine workaround;
// 0.8.3 probe 2026-08-28 showed the extraction is safe now.)
fn void sys_exit() @noinline
{
		bool exit_table_shared = false;
		for (int share_i = 0; share_i < PROCS_MAX; share_i++)
		{
			if (&procs[share_i] == current_proc) continue;
			if (procs[share_i].state == PROC_UNUSED) continue;
			if (procs[share_i].page_table == current_proc.page_table)
			{
				exit_table_shared = true;
				break;
			}
		}

		if (!exit_table_shared)
		{
			ulong* exiting_table2 = current_proc.page_table;
			for (uint vpn2 = 0; vpn2 < 512; vpn2++)
			{
				if ((exiting_table2[vpn2] & PAGE_V) == 0) continue;
				ulong* table1 = (ulong*)pte_to_paddr(exiting_table2[vpn2]);

				for (uint vpn1 = 0; vpn1 < 512; vpn1++)
				{
					if ((table1[vpn1] & PAGE_V) == 0) continue;
					ulong* table0 = (ulong*)pte_to_paddr(table1[vpn1]);

					for (uint vpn0 = 0; vpn0 < 512; vpn0++)
					{
						if ((table0[vpn0] & PAGE_V) == 0) continue;
						if (table0[vpn0] & PAGE_U)
						{
							uptr leaf_paddr = pte_to_paddr(table0[vpn0]);
							free_pages(leaf_paddr, 1);
						}
					}

					free_pages((uptr)table0, 1);
				}

				free_pages((uptr)table1, 1);
			}
			free_pages((uptr)exiting_table2, 1);
		}

		current_proc.state = PROC_UNUSED;
		current_proc.pid = 0;

		// yield() never returns here: current_proc is now PROC_UNUSED,
		// so its scan can't match itself, and switch_context's `ret`
		// jumps permanently into whatever process it picks instead.
		yield();
}

// rfork(): the RFPROC (new process) / RFMEM (share address space =
// thread) primitive. RFMEM -> child.page_table aliases the parent's;
// otherwise a fresh root table + a byte-for-byte copy of every PAGE_U
// leaf. Namespace is always copied. The child's first-resume state is
// a copy of this trap frame (a0=0) plus sepc as a 32nd word, consumed
// by fork_entry() (process.c3). Returns the child pid to the parent.
fn void sys_rfork(Trap_frame* f) @noinline
{
		int rfork_flags = (int)f.a0;
		uint* rfork_gen_out_check = (uint*)(uptr)f.a1;
		if ((rfork_flags & RFPROC) == 0
			|| (rfork_gen_out_check != null && !user_range_valid(current_proc.page_table, (uptr)rfork_gen_out_check, 4, true)))
		{
			f.a0 = (ulong)(-1);
			return;
		}

		Process* child = null;
		int child_i;
		for (child_i = 0; child_i < PROCS_MAX; child_i++)
		{
			if (procs[child_i].state == PROC_UNUSED)
			{
				child = &procs[child_i];
				break;
			}
		}
		if (!child)
		{
			f.a0 = (ulong)(-1);
			return;
		}

		if (rfork_flags & RFMEM)
		{
			// True sharing: same root table pointer, so every mapping
			// either process makes or already has is visible to
			// both — this is what makes it a "thread" rather than a
			// process. SYS_EXIT's own free loop above has a guard
			// specifically for this case.
			child.page_table = current_proc.page_table;
		}
		else
		{
			// Independent copy: fresh root table, same kernel-range +
			// PLIC identity mapping create_process always does, then
			// every PAGE_U leaf in the parent's table gets a fresh
			// physical page with a byte-for-byte copy, mapped at the
			// same vaddr with the same flags — map_page() allocates
			// the child's own intermediate (2nd/3rd level) tables on
			// demand as each leaf is mapped, exactly like
			// create_process already relies on, so this walk only
			// needs to find the parent's leaves and their flags, not
			// manage the child's table structure itself. Same walk
			// shape as SYS_EXIT's free loop above (now 3 levels for
			// Sv39, not 2), copy instead of free.
			ulong* child_table = (ulong*)alloc_pages(1);
			for (uptr paddr = (uptr)&__kernel_map_base; paddr < (uptr)&__free_ram_end; paddr += PAGE_SIZE)
			{
				map_page(child_table, paddr, paddr, PAGE_R | PAGE_W | PAGE_X);
			}
			map_device_page(child_table, board::PLIC_PRIORITY_PAGE, board::PLIC_PRIORITY_PAGE, PAGE_R | PAGE_W);
			map_device_page(child_table, board::PLIC_ENABLE_PAGE, board::PLIC_ENABLE_PAGE, PAGE_R | PAGE_W);
			map_device_page(child_table, board::PLIC_CLAIM_PAGE, board::PLIC_CLAIM_PAGE, PAGE_R | PAGE_W);

			ulong* parent_table2 = current_proc.page_table;
			for (uint vpn2 = 0; vpn2 < 512; vpn2++)
			{
				if ((parent_table2[vpn2] & PAGE_V) == 0) continue;
				ulong* parent_table1 = (ulong*)pte_to_paddr(parent_table2[vpn2]);

				for (uint vpn1 = 0; vpn1 < 512; vpn1++)
				{
					if ((parent_table1[vpn1] & PAGE_V) == 0) continue;
					ulong* parent_table0 = (ulong*)pte_to_paddr(parent_table1[vpn1]);

					for (uint vpn0 = 0; vpn0 < 512; vpn0++)
					{
						if ((parent_table0[vpn0] & PAGE_V) == 0) continue;
						if ((parent_table0[vpn0] & PAGE_U) == 0) continue;

						uptr parent_leaf_paddr = pte_to_paddr(parent_table0[vpn0]);
						uptr child_leaf_paddr  = alloc_pages(1);
						mem::copy((void*)child_leaf_paddr, (void*)parent_leaf_paddr, (sz)PAGE_SIZE);

						uptr child_vaddr  = ((uptr)vpn2 << 30) | ((uptr)vpn1 << 21) | ((uptr)vpn0 << 12);
						uint parent_flags = (uint)(parent_table0[vpn0] & 0x1f); // V|R|W|X|U — see page.c3's map_page encoding
						map_page(child_table, child_vaddr, child_leaf_paddr, parent_flags);
					}
				}
			}
			child.page_table = child_table;
		}

		// Namespace: always copied, regardless of RFMEM — cheap
		// (4 x Mount), and there's no mount/unmount syscall yet to
		// make "shared" vs. "copied" observably different. The seam
		// a future RFNAMEG-equivalent would slot into.
		for (int ns_i = 0; ns_i < NS_MOUNTS_MAX; ns_i++)
		{
			child.namespace[ns_i] = current_proc.namespace[ns_i];
		}

		// Build the child's first-resume state: a copy of this
		// trap's own Trap_frame (a0 zeroed — the child's return
		// value), plus this trap's own resume address as an extra
		// 32nd word, since sepc is a single CSR fork_entry can't
		// otherwise inherit. See fork_entry's own comment in
		// process.c3 for how this block gets consumed. 32 words of
		// 8 bytes now (Sv64 port), not 4.
		uptr* child_sp = (uptr*)&child.stack;
		child_sp += STACK_SIZE / 8;
		child_sp -= 32;

		mem::copy((void*)child_sp, f, (sz)Trap_frame::size);
		Trap_frame* child_frame = (Trap_frame*)child_sp;
		child_frame.a0 = 0;
		child_sp[31] = (uptr)(read_reg("sepc") + 4);

		for (int rf_j = 0; rf_j < 12; rf_j++)
		{
			*(--child_sp) = 0;
		}
		*(--child_sp) = (uptr)&fork_entry;

		child.has_message = false;
		// Same reused-slot reasoning as has_message above — a
		// previous occupant of this slot could have been killed
		// while genuinely mid a blocking wait (SYS_KILL's own
		// leak-safety check, below in this same file, only cleans up
		// blocking_depth itself, not this per-process flag). See
		// Process.in_blocking_wait's own comment (process.c3).
		child.in_blocking_wait = false;
		child.pid   = child_i + 1;
		child.generation++;
		child.sp    = (uptr)child_sp;
		child.state = PROC_RUNNABLE;
		// Unlike create_process() (always 0 — see Process.parent_pid's
		// own comment, process.c3), rfork's own child genuinely does
		// have a parent: this forking process, right now. Captured
		// for SYS_PARENT_INFO below, built for user/envd.c3's own
		// lazy env-inheritance but open to any caller, same reasoning
		// as SYS_PROC_INFO's own comment.
		child.parent_pid = current_proc.pid;
		child.parent_generation = current_proc.generation;
		// Inherited unchanged — the only way it ever changes is
		// SYS_SETUID, which the child can call on itself just like
		// any other process (see that case's own comment).
		child.uid = current_proc.uid;

		// Optional out-pointer (a1), same "null means don't care"
		// convention as SYS_IPC_RECV's type_out — lets the caller
		// capture this child's generation for a later SYS_JOIN to
		// check against, so a join can tell "this pid exited" apart
		// from "this pid got reused by something else." generation
		// itself stays a plain uint (a counter, not an address).
		uint* rfork_gen_out = (uint*)(uptr)f.a1;
		if (rfork_gen_out != null)
		{
			*rfork_gen_out = child.generation;
		}

		f.a0 = (ulong)child.pid;
}

// exec(): replace the calling process's image in place — same pid,
// page table, and namespace (that persistence is the point of a
// Plan-9 exec). a0/a1 = a user pointer+size to the already-read new
// image (user/user.c3's exec() wrapper reads it first); a2/a4 = the
// argv blob length and argc, blob packed right after the image.
// Sniffs ELF64/RISC-V by magic, else treats it as racccoon's flat
// RWX binary. Stages every new page (image, then argv) BEFORE
// touching the current image, so a mid-way alloc failure rolls back
// cleanly; only then frees the old PAGE_U leaves, maps the staged
// pages, flush_tlb() (satp is unchanged so nothing else would), and
// redirects saved_sepc to the entry point. On success control never
// returns to the caller, so a0/a1 are repurposed to hand start()
// argc + the argv base. (Was inlined as a c3c-0.8.2 switch-call
// landmine workaround — 0.8.3 probe 2026-08-28 cleared it.)
fn void sys_exec(Trap_frame* f) @noinline
{
		char* exec_image = (char*)(uptr)f.a0;
		uint exec_image_size = (uint)f.a1;
		// argv blob (user/user.c3's exec(), NUL-separated strings) —
		// packed right after the image content in this same buffer.
		// syscall4's own 4th real argument lands in a4, not a3 (a3 is
		// always the syscall number — see syscall4's own comment,
		// user.c3).
		uint exec_argv_len = (uint)f.a2;
		int exec_argc = (int)f.a4;
		if (exec_image_size == 0 || exec_image_size > EXEC_MAX_IMAGE_SIZE || exec_argv_len > EXEC_MAX_ARGV_SIZE)
		{
			f.a0 = (ulong)(-1);
			return;
		}
		// exec_image is the caller's own buffer (user/user.c3's own
		// exec() wrapper reads the whole new image into it before
		// this ever runs) — the argv blob is packed right after the
		// image content in that same buffer, so one check covering
		// the combined length validates both. Without this, a caller
		// could point exec_image at arbitrary (e.g. kernel) memory
		// and exfiltrate up to EXEC_MAX_IMAGE_SIZE+EXEC_MAX_ARGV_SIZE
		// bytes of it into its own, now-executable/readable pages —
		// every offset/size check below this point is real and
		// careful, but none of them ever validated this root pointer
		// itself.
		if (!user_range_valid(current_proc.page_table, (uptr)exec_image, (ulong)exec_image_size + (ulong)exec_argv_len, false))
		{
			f.a0 = (ulong)(-1);
			return;
		}

		// Stage every new page FIRST, before touching anything
		// about the process's current image — a failed allocation
		// partway through must leave the old image completely
		// intact, not half-replaced, same "fail toward not losing
		// what's already there" discipline this session's own
		// ext2 slot-reuse fix already established.
		//
		// exec_staged/exec_seg_perm are explicitly zeroed (not
		// @noinit) rather than relying on the flat-binary path's own
		// "every slot from 0..exec_page_count gets touched
		// sequentially" — the ELF path below fills these sparsely,
		// by segment page-range, and needs 0 to reliably mean "not
		// yet allocated" everywhere, including slots no segment ever
		// touches (a real, if rare, alignment gap between segments —
		// stays unmapped later, not silently zero-filled).
		uint exec_page_count = 0;
		uptr[EXEC_MAX_IMAGE_PAGES] exec_staged;
		uint[EXEC_MAX_IMAGE_PAGES] exec_seg_perm;
		for (uint zp = 0; zp < EXEC_MAX_IMAGE_PAGES; zp++)
		{
			exec_staged[zp] = 0;
			exec_seg_perm[zp] = 0;
		}
		bool exec_stage_ok = true;
		ulong exec_entry_point = USER_BASE;

		// Real ELF64/RISC-V executable? (racccoon's own toolchain
		// output, build/user/*.elf, before objcopy strips it to a
		// flat binary — see docs/devlog.md for the full design and
		// the real llvm-readelf output this was built against.)
		// Sniffed by magic, not by any caller-provided flag: exec()
		// itself (user.c3) has no format opinion, it just reads
		// bytes and hands them here.
		bool exec_is_elf = exec_image_size >= 64
			&& exec_image[0] == (char)0x7F && exec_image[1] == 'E'
			&& exec_image[2] == 'L' && exec_image[3] == 'F';

		if (exec_is_elf)
		{
			// e_ident[4]=EI_CLASS (2=ELFCLASS64), e_ident[5]=EI_DATA
			// (1=little-endian) — reject anything else outright
			// rather than misinterpret a 32-bit or big-endian file
			// as this layout.
			if ((char)exec_image[4] != (char)2 || (char)exec_image[5] != (char)1)
			{
				f.a0 = (ulong)(-1);
				return;
			}

			ushort* exec_e_type_p     = (ushort*)&exec_image[16];
			ushort* exec_e_machine_p  = (ushort*)&exec_image[18];
			ulong*  exec_e_entry_p    = (ulong*)&exec_image[24];
			ulong*  exec_e_phoff_p    = (ulong*)&exec_image[32];
			ushort* exec_e_phentsize_p = (ushort*)&exec_image[54];
			ushort* exec_e_phnum_p    = (ushort*)&exec_image[56];

			ushort exec_e_type      = *exec_e_type_p;
			ushort exec_e_machine   = *exec_e_machine_p;
			ulong  exec_e_entry     = *exec_e_entry_p;
			ulong  exec_e_phoff     = *exec_e_phoff_p;
			ushort exec_e_phentsize = *exec_e_phentsize_p;
			ushort exec_e_phnum     = *exec_e_phnum_p;

			// e_type=2 (ET_EXEC) only — ET_DYN (PIE) would need real
			// relocation processing, out of scope. e_machine=243
			// (EM_RISCV). e_phentsize must be the real Elf64_Phdr
			// size (56 bytes) — anything else means this isn't a
			// layout the fixed-offset reads below can trust.
			if (exec_e_type != 2 || exec_e_machine != 243 || exec_e_phentsize != 56
				|| exec_e_phnum == 0 || exec_e_phnum > EXEC_MAX_ELF_SEGMENTS)
			{
				f.a0 = (ulong)(-1);
				return;
			}
			// Program headers must actually fit inside the buffer
			// exec() really read — bounds-checked before a single
			// byte of any header is trusted, not assumed from
			// e_phnum/e_phoff alone.
			if (exec_e_phoff > (ulong)exec_image_size
				|| (ulong)exec_e_phnum * 56 > (ulong)exec_image_size - exec_e_phoff)
			{
				f.a0 = (ulong)(-1);
				return;
			}

			for (uint pi = 0; pi < (uint)exec_e_phnum && exec_stage_ok; pi++)
			{
				char* exec_ph = exec_image + exec_e_phoff + (ulong)(pi * 56);
				uint* exec_p_type_p   = (uint*)&exec_ph[0];
				uint* exec_p_flags_p  = (uint*)&exec_ph[4];
				ulong* exec_p_offset_p = (ulong*)&exec_ph[8];
				ulong* exec_p_vaddr_p  = (ulong*)&exec_ph[16];
				ulong* exec_p_filesz_p = (ulong*)&exec_ph[32];
				ulong* exec_p_memsz_p  = (ulong*)&exec_ph[40];

				// PT_LOAD is type 1 — everything else (GNU_STACK,
				// .riscv.attributes, ...) is skipped entirely, same
				// as a real loader only ever maps PT_LOAD segments.
				if (*exec_p_type_p != 1) continue;

				uint  exec_p_flags  = *exec_p_flags_p;
				ulong exec_p_offset = *exec_p_offset_p;
				ulong exec_p_vaddr  = *exec_p_vaddr_p;
				ulong exec_p_filesz = *exec_p_filesz_p;
				ulong exec_p_memsz  = *exec_p_memsz_p;

				// Every bound checked without risking overflow:
				// p_memsz itself capped before it's ever added to
				// p_vaddr, source range checked against the real
				// buffer size, not assumed from the header alone.
				if (exec_p_filesz > exec_p_memsz
					|| exec_p_memsz > (ulong)EXEC_MAX_IMAGE_SIZE
					|| exec_p_vaddr < (ulong)USER_BASE
					|| exec_p_vaddr - (ulong)USER_BASE > (ulong)EXEC_MAX_IMAGE_SIZE - exec_p_memsz
					|| exec_p_offset > (ulong)exec_image_size
					|| exec_p_filesz > (ulong)exec_image_size - exec_p_offset)
				{
					exec_stage_ok = false;
					break;
				}

				uint exec_seg_start_off = (uint)(exec_p_vaddr - (ulong)USER_BASE);
				uint exec_seg_page_start = exec_seg_start_off / PAGE_SIZE;
				uint exec_seg_page_end = (uint)((exec_p_vaddr - (ulong)USER_BASE + exec_p_memsz + (ulong)PAGE_SIZE - 1) / (ulong)PAGE_SIZE);

				// p_flags bits: PF_X=1, PF_W=2, PF_R=4 — every real
				// racccoon segment is readable, but union whatever
				// this segment actually declares rather than
				// assuming PAGE_R unconditionally.
				uint exec_seg_flags = 0;
				if ((exec_p_flags & 4) != 0) exec_seg_flags |= PAGE_R;
				if ((exec_p_flags & 2) != 0) exec_seg_flags |= PAGE_W;
				if ((exec_p_flags & 1) != 0) exec_seg_flags |= PAGE_X;

				// A physical page can't grant partial-page
				// permissions — echod.elf's own segments 0/1 share
				// page 1 (0x1001000-0x1001fff) with different
				// permissions each, confirmed via llvm-readelf, not
				// a hypothetical case. Union every touching
				// segment's own flags into that page rather than
				// letting the last one silently win.
				for (uint spi = exec_seg_page_start; spi < exec_seg_page_end; spi++)
				{
					if (exec_staged[spi] == 0)
					{
						uptr exec_seg_page = alloc_pages(1);
						if (exec_seg_page == 0)
						{
							exec_stage_ok = false;
							break;
						}
						exec_staged[spi] = exec_seg_page;
					}
					exec_seg_perm[spi] |= exec_seg_flags;
					if (spi + 1 > exec_page_count) exec_page_count = spi + 1;
				}
				if (!exec_stage_ok) break;

				// Copy p_filesz bytes from the file into the right
				// page-relative positions — same partial-copy-at-
				// page-boundaries shape user/fs/fat32.c3's
				// fat32_read_file_at (and ext2's own equivalent)
				// already use for their own offset-based reads.
				// alloc_pages() already zero-fills every page it
				// hands back (src/allocation.c3) — the memsz-filesz
				// gap (echod.elf's own segment 2: filesz=0x30,
				// memsz=0x10150) comes out correctly zeroed for
				// free, no explicit zeroing needed here.
				uint exec_copied = 0;
				while (exec_copied < (uint)exec_p_filesz)
				{
					uint exec_dst_off = exec_seg_start_off + exec_copied;
					uint exec_dst_page = exec_dst_off / PAGE_SIZE;
					uint exec_dst_in_page = exec_dst_off % PAGE_SIZE;
					uint exec_chunk = PAGE_SIZE - exec_dst_in_page;
					uint exec_remaining = (uint)exec_p_filesz - exec_copied;
					if (exec_chunk > exec_remaining) exec_chunk = exec_remaining;
					mem::copy((void*)(exec_staged[exec_dst_page] + exec_dst_in_page), exec_image + exec_p_offset + exec_copied, (sz)exec_chunk);
					exec_copied += exec_chunk;
				}
			}

			if (exec_stage_ok)
			{
				// e_entry must land on a page a real PT_LOAD segment
				// actually staged above — not just "somewhere inside
				// the generous EXEC_MAX_IMAGE_SIZE ceiling."
				if (exec_e_entry < (ulong)USER_BASE
					|| exec_e_entry - (ulong)USER_BASE >= (ulong)(exec_page_count * PAGE_SIZE)
					|| exec_staged[(uint)((exec_e_entry - (ulong)USER_BASE) / (ulong)PAGE_SIZE)] == 0)
				{
					exec_stage_ok = false;
				}
				else
				{
					exec_entry_point = exec_e_entry;
				}
			}

			if (!exec_stage_ok)
			{
				for (uint fp = 0; fp < EXEC_MAX_IMAGE_PAGES; fp++)
				{
					if (exec_staged[fp] != 0) free_pages(exec_staged[fp], 1);
				}
				f.a0 = (ulong)(-1);
				return;
			}
		}
		else
		{
			// racccoon's own flat-binary format — one contiguous
			// blob at USER_BASE, mapped RWX uniformly, unchanged
			// from before the ELF path above existed.
			exec_page_count = (exec_image_size + PAGE_SIZE - 1) / PAGE_SIZE;
			for (uint ep = 0; ep < exec_page_count; ep++)
			{
				uptr exec_page = alloc_pages(1);
				if (exec_page == 0)
				{
					exec_stage_ok = false;
					for (uint fp = 0; fp < ep; fp++) free_pages(exec_staged[fp], 1);
					break;
				}
				uint exec_off = ep * PAGE_SIZE;
				uint exec_remaining = exec_image_size - exec_off;
				uint exec_copy_size = exec_remaining < PAGE_SIZE ? exec_remaining : PAGE_SIZE;
				mem::copy((void*)exec_page, exec_image + exec_off, (sz)exec_copy_size);
				exec_staged[ep] = exec_page;
				exec_seg_perm[ep] = PAGE_R | PAGE_W | PAGE_X;
			}
			if (!exec_stage_ok)
			{
				f.a0 = (ulong)(-1);
				return;
			}
			exec_entry_point = USER_BASE;
		}

		// Same staging discipline, second pass, for the (usually
		// much smaller) argv blob — a separate array so a failure
		// here can still roll back the image pages already staged
		// above without touching the old image at all.
		uint argv_page_count = (exec_argv_len + PAGE_SIZE - 1) / PAGE_SIZE;
		uptr[EXEC_MAX_ARGV_PAGES] argv_staged @noinit;
		bool argv_stage_ok = true;
		for (uint ap = 0; ap < argv_page_count; ap++)
		{
			uptr argv_page = alloc_pages(1);
			if (argv_page == 0)
			{
				argv_stage_ok = false;
				for (uint fp = 0; fp < ap; fp++) free_pages(argv_staged[fp], 1);
				break;
			}
			uint argv_off = ap * PAGE_SIZE;
			uint argv_remaining = exec_argv_len - argv_off;
			uint argv_copy_size = argv_remaining < PAGE_SIZE ? argv_remaining : PAGE_SIZE;
			mem::copy((void*)argv_page, exec_image + exec_image_size + argv_off, (sz)argv_copy_size);
			argv_staged[ap] = argv_page;
		}
		if (!argv_stage_ok)
		{
			// Guarded (not every slot 0..exec_page_count is
			// necessarily allocated for the ELF path — a real gap
			// between segments stays 0) — the flat-binary path's own
			// slots are always non-zero here too, so this is a no-op
			// change for that path.
			for (uint fp = 0; fp < exec_page_count; fp++)
			{
				if (exec_staged[fp] != 0) free_pages(exec_staged[fp], 1);
			}
			f.a0 = (ulong)(-1);
			return;
		}

		// Only now: free every existing PAGE_U leaf in this SAME
		// page table (same walk SYS_EXIT/SYS_KILL already do) —
		// not the table itself, and not the kernel-identity/PLIC
		// mappings, since this process keeps existing, just
		// running different code. Cleared to 0 (not just freed)
		// so map_page below finds a clean slot to reuse at each
		// address, the same way a never-yet-mapped one would be.
		ulong* exec_table2 = current_proc.page_table;
		for (uint evpn2 = 0; evpn2 < 512; evpn2++)
		{
			if ((exec_table2[evpn2] & PAGE_V) == 0) continue;
			ulong* exec_table1 = (ulong*)pte_to_paddr(exec_table2[evpn2]);

			for (uint evpn1 = 0; evpn1 < 512; evpn1++)
			{
				if ((exec_table1[evpn1] & PAGE_V) == 0) continue;
				ulong* exec_table0 = (ulong*)pte_to_paddr(exec_table1[evpn1]);

				for (uint evpn0 = 0; evpn0 < 512; evpn0++)
				{
					if ((exec_table0[evpn0] & PAGE_V) == 0) continue;
					if (exec_table0[evpn0] & PAGE_U)
					{
						uptr exec_leaf_paddr = pte_to_paddr(exec_table0[evpn0]);
						free_pages(exec_leaf_paddr, 1);
						exec_table0[evpn0] = 0;
					}
				}
			}
		}

		// Map the newly staged pages at USER_BASE, with each page's
		// own accumulated permission (uniform RWX for the flat-binary
		// path, the real per-segment union for ELF — see exec_seg_perm's
		// own comment above). A real gap between ELF segments
		// (exec_staged[mp] == 0) stays unmapped, not silently
		// zero-filled.
		for (uint mp = 0; mp < exec_page_count; mp++)
		{
			if (exec_staged[mp] == 0) continue;
			map_page(current_proc.page_table, (uptr)USER_BASE + (uptr)(mp * PAGE_SIZE), exec_staged[mp], PAGE_U | exec_seg_perm[mp]);
		}

		// argv's own pages, right after the image's own last mapped
		// page — exec_page_count is already a whole number of pages,
		// so this is exactly contiguous, no gap.
		uptr exec_argv_base = (uptr)USER_BASE + (uptr)(exec_page_count * PAGE_SIZE);
		for (uint avp = 0; avp < argv_page_count; avp++)
		{
			map_page(current_proc.page_table, exec_argv_base + (uptr)(avp * PAGE_SIZE), argv_staged[avp], PAGE_U | PAGE_R | PAGE_W);
		}

		// This process's own page table entries for USER_BASE just
		// changed, but unlike a normal process switch, satp itself
		// does NOT change here (same process) — so switch_context's
		// own sfence.vma (process.c3) never runs for this remap. The
		// CPU can otherwise keep translating USER_BASE (and its
		// following pages) through stale, cached TLB entries from
		// the old image, executing whatever's left in the now-freed
		// physical pages instead of the new ones. Confirmed the hard
		// way: a checksum of the freshly-read image data proved
		// byte-for-byte correct, yet execution still faulted with an
		// illegal instruction inside what should have been the new
		// image — the data was always right, only the CPU's own
		// cached mapping to it was stale.
		flush_tlb();

		// Redirect execution: the standard trap-return path
		// restores this into the real sepc CSR before sret, so the
		// next time this process runs, it starts fresh at
		// exec_entry_point instead of resuming where the old
		// program's ecall left off — USER_BASE for the flat-binary
		// path (unchanged), the validated real e_entry for ELF (for
		// racccoon's own toolchain output this is USER_BASE too,
		// confirmed via llvm-readelf, but a real loader shouldn't
		// assume that). No user-mode stack pointer needs setting
		// here — user/user.c3's own start() sets its own sp from a
		// link-time __stack_top constant baked into every image, as
		// its very first instruction, so whatever the trapframe's
		// stale sp says is irrelevant the moment a fresh image
		// starts running.
		current_proc.saved_sepc = exec_entry_point;
		// argc/argv's own base address, handed off via a0/a1 exactly
		// the way a normal syscall would hand back a return value —
		// safe to repurpose them for this instead, since control
		// never returns to the caller on success (the redirect above
		// means the syscall-wrapper code that would have read a0 as
		// a return value never executes). user/user.c3's start()
		// stashes both before ever calling main(); get_argv() reads
		// them from there. exec_argc is always >= 0 here (a real
		// error already returned -1 and broken out above), so
		// handle_trap()'s own just_execd check below tests
		// "(long)f.a0 >= 0" rather than "== 0" to tell this success
		// path apart from that failure one.
		f.a0 = (ulong)exec_argc;
		f.a1 = (ulong)exec_argv_base;
}

fn void handle_syscall(Trap_frame* f) @noinline
{
	switch (f.a3)
	{
		case SYS_PUTCHAR:
			board::console_putchar((int)f.a0);
		case SYS_GETCHAR:
			current_proc.in_blocking_wait = true;
			blocking_depth++;
			for (;;)
			{
				// USB keyboard first (src/kbd.c3, fed by usbd through
				// SYS_KBD_PUSH), then the serial console — a caller can't
				// tell which a byte came from, and both stay live at once.
				int ch = kbd_queue_pop();
				if (ch < 0) { ch = board::console_getchar(); }
				if (ch >= 0)
				{
					f.a0 = (ulong)ch;
					break;
				}
				yield();
			}
			current_proc.in_blocking_wait = false;
			blocking_depth--;
		case SYS_EXIT:
			sys_exit();
		case SYS_IPC_SEND:
			// Inline for the same reason as SYS_EXIT above — this is the
			// pattern proven not to trigger the unexplained c3c reboot
			// bug in this switch. dest_pid/type/data are a0-a2 as usual;
			// len is a4, since a3 is always the syscall number (see
			// syscall4 in user/user.c3 — this is the one syscall that
			// needs a 4th argument).
			int ipc_dest_pid = (int)f.a0;
			uint ipc_type    = (uint)f.a1;
			char* ipc_data   = (char*)(uptr)f.a2;
			int ipc_len      = (int)f.a4;
			int ipc_copy_len = ipc_len > MSG_MAX ? MSG_MAX : ipc_len;
			if (ipc_copy_len < 0) ipc_copy_len = 0;
			if (!user_range_valid(current_proc.page_table, (uptr)ipc_data, (ulong)ipc_copy_len, false))
			{
				f.a0 = (ulong)(-1);
				break;
			}
			// proc_by_pid here only ever guards against a plain dead/
			// never-existed pid (e.g. a stale hardcoded pid like echod's
			// or diskd's, if one of those ever exited). The stale-
			// namespace-pid hazard this comment used to describe — a
			// Mount entry silently resolving to an unrelated process that
			// reused a dead target's slot, found while building the
			// second, simultaneously-mounted fsd (docs/devlog.md) — is
			// now closed one layer up, in SYS_NS_RESOLVE's own generation
			// check (see Mount.server_generation's comment, process.c3):
			// a caller can never obtain a hijacked pid through namespace
			// resolution in the first place, so this check doesn't need
			// to re-derive that distinction itself.
			Process* ipc_target = proc_by_pid(ipc_dest_pid);
			if (!ipc_target)
			{
				f.a0 = (ulong)(-1);
				break;
			}

			// Wait for the target's inbox to actually be free — a
			// previous sender's message that hasn't been consumed yet
			// must never be silently overwritten. Busy-poll like
			// SYS_GETCHAR: nothing specifically wakes a queued sender
			// when the slot frees up, it's whoever notices next.
			while (ipc_target.has_message)
			{
				yield();
			}

			mem::copy(&ipc_target.msg_data, ipc_data, (sz)ipc_copy_len);
			ipc_target.msg_from = current_proc.pid;
			ipc_target.msg_from_generation = current_proc.generation;
			ipc_target.msg_type = ipc_type;
			current_proc.msg_acked = false;
			ipc_target.has_message = true;
			if (ipc_target.state == PROC_BLOCKED)
			{
				ipc_target.state = PROC_RUNNABLE;
			}

			// True rendezvous: don't return to the caller until the
			// receiver has actually consumed *this* message — SYS_IPC_RECV
			// and SYS_IPC_POLL both wake us explicitly via msg_acked once
			// they do (targeted at us specifically via msg_from, not just
			// "the inbox looks empty again", which could just as easily
			// mean a different sender's message arrived and got consumed
			// instead).
			while (!current_proc.msg_acked)
			{
				current_proc.state = PROC_BLOCKED;
				yield();
			}
			f.a0 = 0;
		case SYS_IPC_REPLY:
			// Same shape as SYS_IPC_SEND above (kept as a full,
			// separate copy rather than factored out — same
			// inlining reason as SYS_EXIT/SYS_KILL), plus one
			// addition: an optional expected_generation (a5) check
			// on the target, mirroring SYS_KILL's own wildcard
			// convention (0 = don't care). This is the piece that
			// actually closes the reply-side stale-pid window —
			// SYS_IPC_SEND's own proc_by_pid check only ever
			// guarded against a dead/never-existed pid, never
			// against "this pid, but a different process now"; a
			// server built to reply safely calls SYS_IPC_RECV_GEN
			// (below) to capture the requester's generation right
			// when the request arrives, then passes it straight
			// back in here. Without that captured generation, a
			// server whose reply lands after the original requester
			// has already exited and had its pid slot reused would
			// otherwise silently misdeliver the reply to the new,
			// unrelated occupant.
			int reply_dest_pid = (int)f.a0;
			uint reply_type    = (uint)f.a1;
			char* reply_data   = (char*)(uptr)f.a2;
			int reply_len      = (int)f.a4;
			uint reply_expected_generation = (uint)f.a5;
			int reply_copy_len = reply_len > MSG_MAX ? MSG_MAX : reply_len;
			if (reply_copy_len < 0) reply_copy_len = 0;
			if (!user_range_valid(current_proc.page_table, (uptr)reply_data, (ulong)reply_copy_len, false))
			{
				f.a0 = (ulong)(-1);
				break;
			}
			Process* reply_target = proc_by_pid(reply_dest_pid);
			if (!reply_target || (reply_expected_generation != 0 && reply_target.generation != reply_expected_generation))
			{
				f.a0 = (ulong)(-1);
				break;
			}

			while (reply_target.has_message)
			{
				yield();
			}

			mem::copy(&reply_target.msg_data, reply_data, (sz)reply_copy_len);
			reply_target.msg_from = current_proc.pid;
			reply_target.msg_from_generation = current_proc.generation;
			reply_target.msg_type = reply_type;
			current_proc.msg_acked = false;
			reply_target.has_message = true;
			if (reply_target.state == PROC_BLOCKED)
			{
				reply_target.state = PROC_RUNNABLE;
			}

			while (!current_proc.msg_acked)
			{
				current_proc.state = PROC_BLOCKED;
				yield();
			}
			f.a0 = 0;
		case SYS_IPC_RECV:
			// a2 (previously always 0 from user.c3's original ipc_recv) is
			// now an optional out-pointer for the message's type/verb —
			// null means "don't care", same as every existing call site
			// still passes.
			char* recv_buf       = (char*)(uptr)f.a0;
			int recv_len         = (int)f.a1;
			uint* recv_type_out  = (uint*)(uptr)f.a2;
			int recv_valid_len = recv_len > MSG_MAX ? MSG_MAX : recv_len;
			if (recv_valid_len < 0) recv_valid_len = 0;
			if (!user_range_valid(current_proc.page_table, (uptr)recv_buf, (ulong)recv_valid_len, true)
				|| (recv_type_out != null && !user_range_valid(current_proc.page_table, (uptr)recv_type_out, 4, true)))
			{
				f.a0 = (ulong)(-1);
				break;
			}
			current_proc.in_blocking_wait = true;
			blocking_depth++;
			for (;;)
			{
				if (current_proc.has_message)
				{
					int recv_copy_len = recv_len > MSG_MAX ? MSG_MAX : recv_len;
					if (recv_copy_len < 0) recv_copy_len = 0;
					mem::copy(recv_buf, &current_proc.msg_data, (sz)recv_copy_len);
					if (recv_type_out != null)
					{
						*recv_type_out = current_proc.msg_type;
					}
					f.a0 = (ulong)current_proc.msg_from;
					current_proc.has_message = false;

					// Wake the sender: it's genuinely blocked (see
					// SYS_IPC_SEND) waiting specifically for this ack,
					// not just for the inbox to look empty from the
					// outside.
					Process* recv_acked_sender = proc_by_pid(current_proc.msg_from);
					if (recv_acked_sender != null)
					{
						recv_acked_sender.msg_acked = true;
						if (recv_acked_sender.state == PROC_BLOCKED)
						{
							recv_acked_sender.state = PROC_RUNNABLE;
						}
					}
					break;
				}
				current_proc.state = PROC_BLOCKED;
				yield();
			}
			current_proc.in_blocking_wait = false;
			blocking_depth--;
		case SYS_IPC_RECV_GEN:
			// Same shape as SYS_IPC_RECV above (kept as a full,
			// separate copy, same reasoning as SYS_IPC_REPLY's own
			// comment), plus one addition: also writes the sender's
			// captured Process.generation (a3) out through a new
			// optional out-pointer (a4) — the piece a server needs
			// to later reply safely via SYS_IPC_REPLY instead of
			// plain SYS_IPC_SEND. A distinct syscall number, not a
			// widened SYS_IPC_RECV, on purpose: every existing
			// SYS_IPC_RECV caller only ever sets a0-a2 (see
			// user.c3's plain 3-arg syscall() wrapper), leaving a4
			// holding whatever garbage was there before — reading it
			// as a live out-pointer on the *same* syscall number
			// would risk writing through that garbage for every
			// caller that hasn't been updated to know about this.
			char* recv_gen_buf       = (char*)(uptr)f.a0;
			int recv_gen_len         = (int)f.a1;
			uint* recv_gen_type_out  = (uint*)(uptr)f.a2;
			uint* recv_gen_from_generation_out = (uint*)(uptr)f.a4;
			int recv_gen_valid_len = recv_gen_len > MSG_MAX ? MSG_MAX : recv_gen_len;
			if (recv_gen_valid_len < 0) recv_gen_valid_len = 0;
			if (!user_range_valid(current_proc.page_table, (uptr)recv_gen_buf, (ulong)recv_gen_valid_len, true)
				|| (recv_gen_type_out != null && !user_range_valid(current_proc.page_table, (uptr)recv_gen_type_out, 4, true))
				|| (recv_gen_from_generation_out != null && !user_range_valid(current_proc.page_table, (uptr)recv_gen_from_generation_out, 4, true)))
			{
				f.a0 = (ulong)(-1);
				break;
			}
			current_proc.in_blocking_wait = true;
			blocking_depth++;
			for (;;)
			{
				if (current_proc.has_message)
				{
					int recv_gen_copy_len = recv_gen_len > MSG_MAX ? MSG_MAX : recv_gen_len;
					if (recv_gen_copy_len < 0) recv_gen_copy_len = 0;
					mem::copy(recv_gen_buf, &current_proc.msg_data, (sz)recv_gen_copy_len);
					if (recv_gen_type_out != null)
					{
						*recv_gen_type_out = current_proc.msg_type;
					}
					if (recv_gen_from_generation_out != null)
					{
						*recv_gen_from_generation_out = current_proc.msg_from_generation;
					}
					f.a0 = (ulong)current_proc.msg_from;
					current_proc.has_message = false;

					Process* recv_gen_acked_sender = proc_by_pid(current_proc.msg_from);
					if (recv_gen_acked_sender != null)
					{
						recv_gen_acked_sender.msg_acked = true;
						if (recv_gen_acked_sender.state == PROC_BLOCKED)
						{
							recv_gen_acked_sender.state = PROC_RUNNABLE;
						}
					}
					break;
				}
				current_proc.state = PROC_BLOCKED;
				yield();
			}
			current_proc.in_blocking_wait = false;
			blocking_depth--;
		case SYS_IPC_POLL:
			// Non-blocking counterpart to SYS_IPC_RECV: checks once,
			// never sets PROC_BLOCKED, never yields. Exists for diskd's
			// completion-wait (user/diskd.c3), which genuinely needs an
			// interrupt to fire to make progress — and a *blocking*
			// ipc_recv there is unsafe: sstatus.SIE has no per-process
			// save/restore (kernel_entry only saves GPRs), and
			// switch_context unconditionally resets sscratch to a fixed
			// "top of this process's stack" value on every switch,
			// including when *resuming* a process that's paused mid-trap
			// (not freshly entering one). That reset is only correct for
			// a fresh trap entry; enabling interrupts while blocked mid-
			// trap risks a nested trap building its frame at that fixed
			// address, colliding with — and corrupting — the still-in-
			// progress outer frame lower on the same stack. Confirmed
			// empirically: doing exactly that (enable_interrupts() right
			// before yield() in SYS_IPC_RECV's loop) turned an
			// intermittent hang into an intermittent page-fault panic
			// instead of fixing it. Polling from genuine user-mode code
			// sidesteps the whole problem: this process is never parked
			// mid-trap between polls, so sstatus.SIE's natural value
			// (on, from user_entry) is safe to leave alone, and the
			// interrupt can fire and get routed normally in between.
			char* poll_buf      = (char*)(uptr)f.a0;
			int poll_len        = (int)f.a1;
			uint* poll_type_out = (uint*)(uptr)f.a2;
			if (!current_proc.has_message)
			{
				f.a0 = (ulong)(-1);
				break;
			}
			int poll_copy_len = poll_len > MSG_MAX ? MSG_MAX : poll_len;
			if (poll_copy_len < 0) poll_copy_len = 0;
			if (!user_range_valid(current_proc.page_table, (uptr)poll_buf, (ulong)poll_copy_len, true)
				|| (poll_type_out != null && !user_range_valid(current_proc.page_table, (uptr)poll_type_out, 4, true)))
			{
				f.a0 = (ulong)(-1);
				break;
			}
			mem::copy(poll_buf, &current_proc.msg_data, (sz)poll_copy_len);
			if (poll_type_out != null)
			{
				*poll_type_out = current_proc.msg_type;
			}
			f.a0 = (ulong)current_proc.msg_from;
			current_proc.has_message = false;

			// Same "wake the real sender" step as SYS_IPC_RECV — normally
			// a no-op here, since diskd's only use of this is for the
			// synthetic interrupt notify (msg_from=0, which proc_by_pid
			// always rejects, so there's no real sender to wake), but
			// correct regardless if that ever changes.
			Process* poll_acked_sender = proc_by_pid(current_proc.msg_from);
			if (poll_acked_sender != null)
			{
				poll_acked_sender.msg_acked = true;
				if (poll_acked_sender.state == PROC_BLOCKED)
				{
					poll_acked_sender.state = PROC_RUNNABLE;
				}
			}
		case SYS_NS_RESOLVE:
			// Inline for the same reason as every other case in this
			// switch — see SYS_EXIT's comment. Walks the caller's own
			// namespace (never a different process's — resolution is
			// always relative to whoever's asking) for the first mount
			// whose prefix matches the given path, longest-prefix-first so
			// a more specific mount always wins over a broader one that
			// also matches. Returns -1 (in f.a0, read as signed by the
			// caller) if nothing matches.
			char* ns_path = (char*)(uptr)f.a0;
			uint* ns_prefix_len_out_check = (uint*)(uptr)f.a1;
			if (!user_range_valid(current_proc.page_table, (uptr)ns_path, NS_PREFIX_MAX, false)
				|| (ns_prefix_len_out_check != null && !user_range_valid(current_proc.page_table, (uptr)ns_prefix_len_out_check, 4, true)))
			{
				f.a0 = (ulong)(-1);
				break;
			}
			int ns_result = -1;
			int ns_best_len = -1;
			for (int m = 0; m < NS_MOUNTS_MAX; m++)
			{
				if (current_proc.namespace[m].server_pid == 0) continue;
				// Generation check closes the stale-pid hazard documented
				// on Mount.server_generation (process.c3): if the process
				// that originally held this pid has since exited and the
				// slot was reused (or never got this far at all), either
				// proc_by_pid returns null or its live generation won't
				// match what was recorded when this entry was bound —
				// either way, treat it exactly like server_pid == 0 rather
				// than resolve to the wrong, unrelated process.
				Process* ns_target = proc_by_pid(current_proc.namespace[m].server_pid);
				if (!ns_target || ns_target.generation != current_proc.namespace[m].server_generation) continue;
				char* ns_prefix = &current_proc.namespace[m].prefix[0];
				if (!str_starts_with(ns_path, ns_prefix)) continue;

				int ns_len = 0;
				while (ns_prefix[ns_len] != 0) ns_len++;
				if (ns_len > ns_best_len)
				{
					ns_best_len = ns_len;
					ns_result = current_proc.namespace[m].server_pid;
				}
			}
			f.a0 = (ulong)(iptr)ns_result;

			// Optional out-pointer (a1), same "null means don't care"
			// convention as SYS_RFORK's generation out-pointer above —
			// lets the caller strip the matched prefix itself (see
			// user/user.c3's fs_read/fs_write) before building a wire-
			// format request, so a server mounted under a non-empty
			// prefix (e.g. the second fsd, under "/2/") still only ever
			// sees the bare remainder, exactly like the "" catch-all
			// mount already did by construction (its own prefix length
			// is always 0). 0 when nothing matched — the caller already
			// has -1 in f.a0 to detect that case, this just avoids
			// leaving the out-pointer's target uninitialized.
			uint* ns_prefix_len_out = (uint*)(uptr)f.a1;
			if (ns_prefix_len_out != null)
			{
				*ns_prefix_len_out = (uint)(ns_best_len < 0 ? 0 : ns_best_len);
			}
		case SYS_DISKD_INFO:
			// diskd-only, called once at its own startup — see
			// setup_diskd_mappings in process.c3 for why these addresses
			// can't be known at compile time or derived by diskd itself.
			// a0/a1 are out-pointers (same convention as SYS_IPC_RECV's
			// optional type-out pointer): a0 -> vq paddr, a1 -> req paddr.
			uptr* diskd_vq_out  = (uptr*)(uptr)f.a0;
			uptr* diskd_req_out = (uptr*)(uptr)f.a1;
			if (!user_range_valid(current_proc.page_table, (uptr)diskd_vq_out, 8, true)
				|| !user_range_valid(current_proc.page_table, (uptr)diskd_req_out, 8, true))
			{
				f.a0 = (ulong)(-1);
				break;
			}
			*diskd_vq_out  = diskd_vq_paddr;
			*diskd_req_out = diskd_req_paddr;
		case SYS_FS_PARTITION_INFO:
			// fsd-only, called once at its own startup — a0 is an
			// out-pointer, same convention as SYS_DISKD_INFO above.
			// Reads the CALLER's own current_proc.fs_partition_start
			// (set by process.c3's setup_fsd_mappings() at spawn time),
			// not board::FS_PARTITION_START_SECTOR directly — see that
			// field's own comment for why: two fsd instances can be
			// mounted simultaneously now, so a single shared board
			// constant can't answer this the same way for both.
			uint* fs_partition_out = (uint*)(uptr)f.a0;
			bool* fs_is_secondary_out = (bool*)(uptr)f.a1;
			if (!user_range_valid(current_proc.page_table, (uptr)fs_partition_out, 4, true)
				|| (fs_is_secondary_out != null && !user_range_valid(current_proc.page_table, (uptr)fs_is_secondary_out, 1, true)))
			{
				f.a0 = (ulong)(-1);
				break;
			}
			*fs_partition_out = current_proc.fs_partition_start;
			// a1 is a second, optional out-pointer (same "null means
			// the caller doesn't care" convention SYS_NS_RESOLVE/
			// SYS_RFORK already use) — see is_secondary_fs's own
			// comment (process.c3) for why fsd.c3 needs this at all.
			if (fs_is_secondary_out != null)
			{
				*fs_is_secondary_out = current_proc.is_secondary_fs;
			}
		case SYS_RFORK:
			sys_rfork(f);
		case SYS_NS_UNMOUNT:
			// Removes one of the *caller's own* namespace mounts by
			// exact prefix match (str_eq, not the longest-prefix match
			// SYS_NS_RESOLVE uses — this targets one specific entry, not
			// "whichever mount a path would resolve to"). Since a fresh
			// rfork(RFPROC) child gets its own independent copy of the
			// parent's namespace (see SYS_RFORK above), this is what
			// lets a child sandbox itself after forking, without
			// affecting the parent or any other process. Returns 0 if
			// found and removed, -1 if no mount had that exact prefix.
			char* unmount_prefix = (char*)(uptr)f.a0;
			if (!user_range_valid(current_proc.page_table, (uptr)unmount_prefix, NS_PREFIX_MAX, false))
			{
				f.a0 = (ulong)(-1);
				break;
			}
			int unmount_result = -1;
			for (int um = 0; um < NS_MOUNTS_MAX; um++)
			{
				if (current_proc.namespace[um].server_pid == 0) continue;
				if (str_eq(&current_proc.namespace[um].prefix[0], unmount_prefix))
				{
					current_proc.namespace[um].server_pid = 0;
					unmount_result = 0;
					break;
				}
			}
			f.a0 = (ulong)(iptr)unmount_result;
		case SYS_JOIN:
			// Blocks until the joined process is actually gone — plain
			// polling (check, yield(), recheck), the same proven shape
			// as SYS_GETCHAR's own retry loop, not an event-driven wake.
			//
			// "Actually gone" means either the slot is empty
			// (proc_by_pid returns null) *or* it's been reused by an
			// unrelated process — detected via the join_generation the
			// caller captured when it created this pid (rfork's or
			// threadcreate's optional generation_out), compared against
			// Process.generation (src/process.c3), which increments on
			// every reuse of a slot and never resets. Without this
			// check, a pid recycled into a new process (always possible,
			// since a slot's next occupant gets the exact same pid —
			// pid = slot index + 1) would look identical to the
			// original process still running, and join would wait for
			// the wrong thing.
			int join_pid = (int)f.a0;
			uint join_generation = (uint)f.a1;
			if (join_pid == current_proc.pid)
			{
				// Can't wait for yourself to disappear while you're the
				// one running — always self-deadlock. Reject rather than
				// hang.
				f.a0 = (ulong)(-1);
				break;
			}
			// Stays PROC_RUNNABLE throughout, same as SYS_GETCHAR's own
			// loop above — deliberately not PROC_BLOCKED: that state
			// only ever gets cleared by something *else* explicitly
			// flipping it back (SYS_IPC_SEND does this for a receiver).
			// Nothing does that for a join — SYS_EXIT only ever touches
			// its own process's state — so setting PROC_BLOCKED here
			// would make this process permanently unschedulable the
			// moment it's set, even after the joined pid actually exits.
			current_proc.in_blocking_wait = true;
			blocking_depth++;
			for (;;)
			{
				Process* join_target = proc_by_pid(join_pid);
				if (join_target == null) break;
				if (join_target.generation != join_generation) break;
				yield();
			}
			current_proc.in_blocking_wait = false;
			blocking_depth--;
			f.a0 = 0;
		case SYS_FUTEX_WAIT:
			// Blocks while the user-space word at addr still equals
			// expected. The check-then-block sequence below is atomic
			// with respect to any concurrent SYS_FUTEX_WAKE precisely
			// because kernel-mode code is never preempted (see
			// enable_timer_interrupts()'s own comment above arm_timer)
			// — no other process's SYS_FUTEX_WAKE can run between this
			// read and setting PROC_BLOCKED, so a wake can never be
			// lost in that window. Returns immediately (no block, no
			// yield) if the value already differs — same as any real
			// futex, the caller (user/user.c3's Mutex.lock) always
			// re-checks its own condition either way, spuriously or
			// not.
			int* futex_addr     = (int*)(uptr)f.a0;
			int futex_expected  = (int)f.a1;
			if (!user_range_valid(current_proc.page_table, (uptr)futex_addr, 4, false))
			{
				f.a0 = (ulong)(-1);
				break;
			}
			if (*futex_addr != futex_expected)
			{
				f.a0 = 0;
				break;
			}
			current_proc.futex_addr = (uptr)futex_addr;
			current_proc.in_blocking_wait = true;
			blocking_depth++;
			for (;;)
			{
				// PROC_BLOCKED, not PROC_RUNNABLE the way SYS_JOIN
				// stays above: unlike a join, something always does
				// explicitly clear this — SYS_FUTEX_WAKE below, the
				// only other place futex_addr is ever touched.
				current_proc.state = PROC_BLOCKED;
				yield();
				if (current_proc.futex_addr == 0) break;
			}
			current_proc.in_blocking_wait = false;
			blocking_depth--;
			f.a0 = 0;
		case SYS_FUTEX_WAKE:
			// Wakes every process currently blocked on this exact
			// address *within the same address space* — page_table
			// equality is the same "genuinely shares memory" test
			// SYS_EXIT's own table-teardown skip already uses above:
			// RFMEM siblings share the literal page_table pointer,
			// never just a copy, and every ordinary process gets its
			// own fresh one, so this can't mistake two unrelated
			// processes' coincidentally-equal user-space addresses for
			// the same futex.
			uptr wake_addr = (uptr)f.a0;
			for (int wake_i = 0; wake_i < PROCS_MAX; wake_i++)
			{
				Process* waiter = &procs[wake_i];
				if (waiter.state != PROC_BLOCKED) continue;
				if (waiter.futex_addr != wake_addr) continue;
				if (waiter.page_table != current_proc.page_table) continue;
				waiter.futex_addr = 0;
				waiter.state = PROC_RUNNABLE;
			}
			f.a0 = 0;
		case SYS_PROC_INFO:
			// Read-only, no permission check — process existence/state
			// isn't sensitive in this kernel's threat model (no
			// user/permission concept at all), the same way an
			// unprivileged `ps` is fine on a real Unix. Built for
			// procd (user/procd.c3), the "/proc/" server, but open to
			// any caller — there's no reason to restrict it further
			// than that. uid (a4, optional out-pointer, null means
			// don't care — same convention as state_out/generation_out)
			// is the same "not sensitive, an identity not a secret"
			// reasoning — real Unix `ps` shows everyone's uid too. Added
			// alongside the new Process.uid field specifically so
			// procd's own ctl handler can look up the *real* requester's
			// uid (not its own, always root) before calling kill() —
			// see that case's own comment. a4, not a3: a3 is always the
			// syscall number (see syscall4's own comment, user.c3) —
			// this is why proc_info()'s wrapper now uses syscall4
			// instead of the plain 3-arg syscall(), same shape
			// fs_read_at already uses for its own 4th argument. Safe to
			// widen this specific wrapper directly rather than adding a
			// new syscall number the way SYS_IPC_RECV_GEN did over
			// SYS_IPC_RECV: proc_info() has exactly one caller in this
			// whole tree (procd.c3) and it's updated in this same
			// change, not a real ABI with independent callers to keep
			// working unmodified.
			int query_pid = (int)f.a0;
			Process* queried = proc_by_pid(query_pid);
			if (queried == null)
			{
				f.a0 = (ulong)(-1);
				break;
			}
			uint* state_out = (uint*)(uptr)f.a1;
			uint* generation_out = (uint*)(uptr)f.a2;
			int* uid_out = (int*)(uptr)f.a4;
			if ((state_out != null && !user_range_valid(current_proc.page_table, (uptr)state_out, 4, true))
				|| (generation_out != null && !user_range_valid(current_proc.page_table, (uptr)generation_out, 4, true))
				|| (uid_out != null && !user_range_valid(current_proc.page_table, (uptr)uid_out, 4, true)))
			{
				f.a0 = (ulong)(-1);
				break;
			}
			if (state_out != null) *state_out = (uint)queried.state;
			if (generation_out != null) *generation_out = queried.generation;
			if (uid_out != null) *uid_out = queried.uid;
			f.a0 = 0;
		case SYS_KILL:
			// PROBE (2026-08-28): extracted to sys_kill() to test whether
			// c3c 0.8.3 fixed the "call a moderately-complex function from
			// handle_syscall's switch reboot-loops from the first syscall"
			// landmine that hit 3x on 0.8.2 (see SYS_EXIT + docs/devlog.md
			// 2026-08-14). Boots clean on QEMU + Duo => rest of the split
			// is safe; reboot loop => revert, landmine still live.
			sys_kill(f);
		case SYS_SRV_POST:
			// Posts current_proc (always self — no pid argument; there's
			// no reason to let one process post another's pid even in a
			// kernel with no general permission model, since "post"
			// fundamentally means "here is my own connection") under a
			// short name in the global srv_table (src/process.c3) — the
			// "srv" half of the real Plan 9 post+mount two-step
			// SYS_NS_MOUNT (below) is the other half of. Idempotent by
			// name, same "already exists is fine" shape as
			// fat32_mkdir/ext2_mkdir's own /tmp auto-create: an existing
			// entry with this exact name is rebound in place (e.g. after
			// a server restart) rather than refused.
			char* post_name = (char*)(uptr)f.a0;
			if (!user_range_valid(current_proc.page_table, (uptr)post_name, SRV_NAME_MAX, false))
			{
				f.a0 = (ulong)(-1);
				break;
			}
			int post_free_slot = -1;
			int post_result = -1;
			bool post_denied = false;
			for (int ps = 0; ps < SRV_MAX; ps++)
			{
				if (srv_table[ps].pid == 0)
				{
					if (post_free_slot == -1) post_free_slot = ps;
					continue;
				}
				if (str_eq(&srv_table[ps].name[0], post_name))
				{
					// Reclaiming a name still held by a genuinely live
					// process (a dead holder's slot is the "server
					// restart" case, still unrestricted) needs root or
					// the same uid as that live holder (Process.uid,
					// process.c3) — otherwise any process could
					// silently hijack another's posted service name.
					Process* post_existing = proc_by_pid(srv_table[ps].pid);
					if (post_existing != null && current_proc.uid != 0 && current_proc.uid != post_existing.uid)
					{
						post_denied = true;
						break;
					}
					srv_table[ps].pid = current_proc.pid;
					srv_table[ps].generation = current_proc.generation;
					post_result = 0;
					break;
				}
			}
			if (!post_denied && post_result != 0 && post_free_slot != -1)
			{
				str_copy(&srv_table[post_free_slot].name[0], post_name, SRV_NAME_MAX);
				srv_table[post_free_slot].pid = current_proc.pid;
				srv_table[post_free_slot].generation = current_proc.generation;
				post_result = 0;
			}
			f.a0 = (ulong)(iptr)post_result;
		case SYS_NS_MOUNT:
			// Looks srv_name up in srv_table and, if it names a still-live
			// server, adds prefix -> (pid, generation) into the *calling*
			// process's own namespace — the "mount" half of the two-step.
			// The actual lookup+bind logic lives in ns_mount_try()
			// (process.c3), shared with SYS_NS_MOUNT_WAIT below (a retry
			// loop around this exact same single attempt).
			char* mount_prefix = (char*)(uptr)f.a0;
			char* mount_srv_name = (char*)(uptr)f.a1;
			if (!user_range_valid(current_proc.page_table, (uptr)mount_prefix, NS_PREFIX_MAX, false)
				|| !user_range_valid(current_proc.page_table, (uptr)mount_srv_name, SRV_NAME_MAX, false))
			{
				f.a0 = (ulong)(-1);
				break;
			}
			f.a0 = (ulong)(iptr)(ns_mount_try(mount_prefix, mount_srv_name) ? 0 : -1);
		case SYS_NS_MOUNT_WAIT:
			// Same as SYS_NS_MOUNT, but blocks — retrying ns_mount_try()
			// in a loop — until either it succeeds or max_attempts retries
			// have all failed. Closes a real gap SYS_NS_MOUNT alone has no
			// answer for: a dynamically-spawned server (an unpredictable
			// pid, no fixed boot-time slot — see SYS_RFORK above) posts
			// itself at some unpredictable time after its own init
			// finishes, and a client that tries to mount it too early
			// would otherwise just fail outright with no way to wait for
			// "not yet, but soon."
			//
			// Bounded by a plain retry count, not a wall-clock deadline —
			// found the hard way, real hardware/QEMU testing this session:
			// an earlier version computed a time-CSR deadline via
			// read_reg("time") (see arm_timer's own, much simpler,
			// single-call use of it above) and re-read it on every loop
			// iteration, alongside mw_prefix/mw_srv_name kept live across
			// each read — read_reg's own comment already documents that
			// its asm() block's real register effects aren't visible to
			// the compiler ("the previous version... silently clobbered");
			// combining it with other locals surviving across repeated
			// calls inside a loop reproduced exactly that class of
			// corruption, crashing with a garbage pointer dereference
			// inside ns_mount_try itself. A plain iteration count
			// sidesteps read_reg entirely — less precise than a real
			// wall-clock timeout, but correctness beats precision here,
			// and every call site fully controls its own patience via how
			// large a count it passes.
			//
			// Same PROC_RUNNABLE-throughout polling shape as SYS_JOIN
			// above, not PROC_BLOCKED: nothing would ever explicitly clear
			// that state for this condition (the poster doesn't know or
			// care who might be waiting), so setting it would hang this
			// process forever even once the target actually posts.
			// yield() between checks is the same cooperative context-
			// switch SYS_JOIN's own loop already uses, safe to call
			// repeatedly from inside a syscall handler.
			//
			// blocking_depth (process.c3) tracking below is what actually
			// found and fixes a real, separate kernel bug this syscall
			// exposed: a freshly-rfork()'d child getting its first
			// scheduling turn while this loop is still open could
			// incorrectly re-enable global interrupts early (fork_entry's
			// own synthetic first sret never touched sstatus at all
			// before this fix) — see blocking_depth's own comment for the
			// full mechanism.
			char* mw_prefix = (char*)(uptr)f.a0;
			char* mw_srv_name = (char*)(uptr)f.a1;
			ulong mw_max_attempts = f.a2;
			if (!user_range_valid(current_proc.page_table, (uptr)mw_prefix, NS_PREFIX_MAX, false)
				|| !user_range_valid(current_proc.page_table, (uptr)mw_srv_name, SRV_NAME_MAX, false))
			{
				f.a0 = (ulong)(-1);
				break;
			}
			// A caller-controlled ulong with no cap would let one process
			// tie up its own blocking_depth-tracked slot for up to
			// 2^64-1 cooperative retries — each one harmless on its own
			// (a bounded ns_mount_try() + yield()), but there's no reason
			// to trust an unbounded request at all when every legitimate
			// caller in this tree already asks for a few million at most
			// (see e.g. user/shell.c3's own MOUNTUSB_WAIT_ATTEMPTS).
			if (mw_max_attempts > NS_MOUNT_WAIT_MAX_ATTEMPTS) mw_max_attempts = NS_MOUNT_WAIT_MAX_ATTEMPTS;
			bool mw_ok = false;
			current_proc.in_blocking_wait = true;
			blocking_depth++;
			for (ulong mw_i = 0; mw_i < mw_max_attempts; mw_i++)
			{
				mw_ok = ns_mount_try(mw_prefix, mw_srv_name);
				if (mw_ok) break;
				yield();
			}
			current_proc.in_blocking_wait = false;
			blocking_depth--;
			f.a0 = (ulong)(iptr)(mw_ok ? 0 : -1);
		case SYS_YIELD:
			// Plain, single, unconditional yield() — for a process that
			// needs to busy-wait on something with no syscall of its
			// own (a hardware register poll, a real-time delay), so it
			// can stay cooperatively preemptible instead of a syscall-
			// free spin that nothing can ever switch away from. Found
			// necessary building usbd.c3 (docs/devlog.md): this
			// kernel's own pre-existing, accepted design means SIE
			// stays globally disabled for as long as *any* process is
			// idling inside SYS_GETCHAR (the shell's own normal resting
			// state waiting for a keystroke) — so a genuinely
			// syscall-free loop elsewhere can never be preempted once
			// the shell reaches its idle prompt, a real, total
			// deadlock, not just a missed-scheduling-slice
			// inefficiency. Not one of the blocking_depth-counted
			// waits (process.c3) — this trap's own sret is a real,
			// single, ordinary trap-entry/exit pair reflecting this
			// process's own genuine state, no staleness risk the way a
			// multi-yield loop held open across an unrelated process's
			// own scheduling would have.
			yield();
			f.a0 = 0;
		case SYS_USBD_INFO:
			// usbd-only, called once at its own startup — see
			// setup_usbd_mappings in process.c3 for why this address
			// can't be known at compile time or derived by usbd itself.
			// a0 is an out-pointer, same convention as SYS_DISKD_INFO
			// above.
			uptr* usbd_dma_out = (uptr*)(uptr)f.a0;
			if (!user_range_valid(current_proc.page_table, (uptr)usbd_dma_out, 8, true))
			{
				f.a0 = (ulong)(-1);
				break;
			}
			*usbd_dma_out = usbd_dma_paddr;
		case SYS_NETD_INFO:
			// netd-only, called once at its own startup — see
			// setup_netd_mappings in process.c3 for why these addresses
			// can't be known at compile time. a0/a1/a2 are out-pointers,
			// same convention as SYS_DISKD_INFO above: a0 -> RX
			// virtqueue paddr, a1 -> TX virtqueue paddr, a2 -> packet-
			// buffer page paddr (Ethernet Phase 2 — see
			// netd_pktbuf_paddr's own comment, process.c3).
			uptr* netd_rxq_out = (uptr*)(uptr)f.a0;
			uptr* netd_txq_out = (uptr*)(uptr)f.a1;
			uptr* netd_pktbuf_out = (uptr*)(uptr)f.a2;
			if (!user_range_valid(current_proc.page_table, (uptr)netd_rxq_out, 8, true)
				|| !user_range_valid(current_proc.page_table, (uptr)netd_txq_out, 8, true)
				|| !user_range_valid(current_proc.page_table, (uptr)netd_pktbuf_out, 8, true))
			{
				f.a0 = (ulong)(-1);
				break;
			}
			*netd_rxq_out = netd_rxq_paddr;
			*netd_txq_out = netd_txq_paddr;
			*netd_pktbuf_out = netd_pktbuf_paddr;
		case SYS_ETHD_INFO:
			// ethd-only, called once at its own startup — see
			// setup_ethd_mappings in process.c3 for why this address
			// can't be known at compile time or derived by ethd itself.
			// a0 is an out-pointer, same convention as SYS_USBD_INFO
			// above.
			uptr* ethd_dma_out = (uptr*)(uptr)f.a0;
			if (!user_range_valid(current_proc.page_table, (uptr)ethd_dma_out, 8, true))
			{
				f.a0 = (ulong)(-1);
				break;
			}
			*ethd_dma_out = ethd_dma_paddr;
		case SYS_KBD_PUSH:
			// usbd-only in practice (user/usb/kbd.c3's kbd_emit): one
			// decoded keyboard byte in a0, appended to the kernel
			// keystroke queue SYS_GETCHAR drains (src/kbd.c3). Returns 0,
			// or -1 if the queue was full (byte dropped). Not pid-gated,
			// same as every other "*_INFO" syscall here — a byte in the
			// input stream is low-stakes, and usbd is the only thing that
			// ever calls this.
			if (kbd_queue_push((char)(f.a0 & 0xFF)))
			{
				f.a0 = 0;
			}
			else
			{
				f.a0 = (ulong)(-1);
			}
		case SYS_DRIVER_IRQ_ARM:
			// A driver re-enables its own PLIC source after servicing a
			// completion — handle_trap disabled it on the way in (the
			// device line is level-high and can't be cleared from the
			// trap handler). The source is whichever one the caller
			// registered in the Irq_route table (setup_*_mappings,
			// process.c3). A non-driver caller finds no route -> no-op.
			// Idempotent (first transfer / timeout path harmlessly
			// re-sets an already-set enable bit).
			Irq_route* arm_route = irq_route_by_pid(current_proc.pid);
			if (arm_route != null)
			{
				board::plic_set_enabled(arm_route.irq, true);
			}
			f.a0 = 0;
		case SYS_SDD_INFO:
			// sdd-only, called once at startup — see setup_sdd_mappings
			// in process.c3. a0 is an out-pointer, same convention as
			// SYS_USBD_INFO.
			uptr* sdd_dma_out = (uptr*)(uptr)f.a0;
			if (!user_range_valid(current_proc.page_table, (uptr)sdd_dma_out, 8, true))
			{
				f.a0 = (ulong)(-1);
				break;
			}
			*sdd_dma_out = sdd_dma_paddr;
		case SYS_PARENT_INFO:
			// Read-only, no permission check — same reasoning as
			// SYS_PROC_INFO above. Returns the given pid's parent_pid
			// (Process.parent_pid, process.c3) — -1 if the pid doesn't
			// exist or genuinely has no parent (0, create_process()'d
			// directly rather than forked; 0 is never a valid pid, so
			// it's a safe sentinel translated to -1 here, matching
			// every other "not found" convention in this protocol) —
			// with the parent's own generation handed back through an
			// optional out-pointer, so a caller (built for
			// user/envd.c3's own lazy env-inheritance) can confirm that
			// parent is still the exact instance this pid was forked
			// from before trusting anything copied from it.
			int parent_query_pid = (int)f.a0;
			Process* parent_queried = proc_by_pid(parent_query_pid);
			if (parent_queried == null || parent_queried.parent_pid == 0)
			{
				f.a0 = (ulong)(-1);
				break;
			}
			uint* parent_generation_out = (uint*)(uptr)f.a1;
			if (parent_generation_out != null && !user_range_valid(current_proc.page_table, (uptr)parent_generation_out, 4, true))
			{
				f.a0 = (ulong)(-1);
				break;
			}
			if (parent_generation_out != null) *parent_generation_out = parent_queried.parent_generation;
			f.a0 = (ulong)(iptr)parent_queried.parent_pid;
		case SYS_EXEC:
			sys_exec(f);
		case SYS_SETUID:
			// Sets the CALLER's own uid — never another process's (real
			// setuid() semantics; there's no "setuid on someone else's
			// behalf" primitive here). Only while still root: once a
			// process has dropped to a non-zero uid, it can never call
			// this again, so a privilege drop is permanent. This is
			// deliberately the only privilege primitive this kernel has
			// — no login, no credentials, just "a root process can
			// voluntarily drop itself (or a freshly-rforked child, which
			// inherits root too — see SYS_RFORK's own comment) to a
			// lower, permanent privilege level," the standard fork() +
			// child-calls-setuid() idiom. Without this, every process
			// would stay uid 0 forever by inheritance and SYS_KILL/
			// SYS_SRV_POST's own new checks below would never actually
			// deny anything.
			if (current_proc.uid != 0)
			{
				f.a0 = (ulong)(-1);
				break;
			}
			current_proc.uid = (int)f.a0;
			f.a0 = 0;
		default:
			// An unrecognized syscall number from any process — a
			// genuine bug in that process, or a deliberately hostile
			// one — must never be able to take down the whole kernel
			// for every other process. Deny cleanly, same convention as
			// every other rejection in this switch, instead of the
			// panic::panic() this used to be.
			f.a0 = (ulong)(-1);
	}
}

fn void handle_trap(Trap_frame* f) @export("handle_trap") @noinline @nostrip
{
	ulong scause  = read_reg("scause");
	ulong stval   = read_reg("stval");
	ulong user_pc = read_reg("sepc");
	// Captured here, restored (via write_sepc) right before this
	// function returns — see Process.saved_sepc's own comment for why
	// this needs to be per-process state now, not just this shared
	// hardware register left to survive a trap's own handling
	// untouched. Correct as-is for every existing case (hardware
	// already points sepc at the right resume address for an
	// interrupt); the ecall branch below overwrites it with the
	// post-ecall address once it knows that's needed.
	current_proc.saved_sepc = user_pc;

	if (scause & SCAUSE_INTERRUPT_BIT)
	{
		ulong code = scause & ~SCAUSE_INTERRUPT_BIT;
		if (code == SCAUSE_SUPERVISOR_EXTERNAL)
		{
			// Claiming acknowledges the IRQ to the PLIC. 0 means a
			// spurious claim (nothing pending) — don't complete an IRQ
			// that wasn't actually claimed.
			uint irq = board::plic_claim();

			// Route it to the driver that registered it (Irq_route
			// table, process.c3). Wake that process specifically rather
			// than relying on "whatever happened to be running/wfi-
			// waiting" — a device interrupt can land while any process
			// (or the kernel's own boot code) is active, and only the
			// owning driver cares. Uses the driver's single-slot IPC
			// inbox: safe because a driver only waits for this notify
			// right after kicking its device, never with an unconsumed
			// client request sitting there (see user/diskd.c3's loop).
			// DISKD_IRQ_NOTIFY is an opaque "your IRQ fired" marker to
			// whichever driver gets it — the driver responds by re-
			// reading its own device's status register, not by
			// inspecting the notify.
			Irq_route* route = irq_route_by_irq(irq);
			if (route != null)
			{
				Process* driver = proc_by_pid(route.pid);
				if (driver != null)
				{
					driver.msg_from    = 0;
					driver.msg_type    = DISKD_IRQ_NOTIFY;
					driver.has_message = true;
					if (driver.state == PROC_BLOCKED)
					{
						driver.state = PROC_RUNNABLE;
					}
				}
			}
			if (irq != 0)
			{
				board::plic_complete(irq);
			}
			// A `level` source (DWC2, SDHCI, dwmac) keeps its device
			// status line asserted until the driver clears it; on this
			// SoC a still-pending external interrupt at sret re-traps
			// before the returned-to context runs an instruction, so
			// leaving it enabled hangs the driver out of ever reaching
			// that clear. Disable AFTER plic_complete (the PLIC ignores a
			// completion for a disabled source); the driver re-arms via
			// SYS_DRIVER_IRQ_ARM before its next wait. Also disable any
			// unrecognized non-zero source — a misrouted level IRQ left
			// enabled is a guaranteed storm. An edge/latched route
			// (virtio-mmio, level=false) is the only case left enabled.
			if (irq != 0 && (route == null || route.level))
			{
				board::plic_set_enabled(irq, false);
			}
		}
		else if (code == SCAUSE_SUPERVISOR_TIMER)
		{
			// Rearm first, before anything else: stimecmp is what
			// actually clears the pending interrupt (time < stimecmp
			// again), so leaving the old, already-elapsed value in
			// place would refire the instant interrupts are next
			// enabled — an interrupt storm, not a periodic tick.
			arm_timer(board::TIMEBASE_HZ);
			timer_tick_count += 1;

			// Real preemption: force a reschedule on every tick, not
			// just when a process happens to yield() on its own. See
			// enable_timer_interrupts()'s own comment above for why
			// this is safe and why it's gated on pid > 0.
			if (current_proc.pid > 0)
			{
				yield();
			}
		}
		// No sepc adjustment for interrupts: unlike ecall (which must skip
		// past the trapping instruction), the hardware already points sepc
		// at the correct resume address — for wfi specifically, the
		// instruction right after it.
	}
	else if (scause == SCAUSE_ECALL)
	{
		// Syscall number, captured before handle_syscall runs: SYS_EXEC's
		// own case (below) needs to know, after the fact, whether it's
		// the one that just ran — f.a3 is preserved unchanged through the
		// switch (no case touches it), so reading it after the call is
		// exactly as reliable as reading it before.
		ulong syscall_num = f.a3;
		handle_syscall(f);
		// current_proc, not necessarily the same process that entered
		// this trap: any of the blocking syscalls above (SYS_GETCHAR,
		// SYS_IPC_RECV, SYS_JOIN's poll loop) can yield() through many
		// other processes before finally returning here — but by the
		// time handle_syscall returns, execution has unwound back onto
		// *this* process's own kernel stack (switch_context is a plain
		// stack swap; a process's own call chain, including this exact
		// frame, only ever resumes where it left off), so current_proc
		// is correctly this process again. user_pc is this same
		// process's own local copy from trap entry, untouched by
		// anything that happened to other processes in between.
		//
		// SYS_EXEC on success is the one exception: its own case already
		// set saved_sepc to USER_BASE (this process is about to run a
		// completely different image, not resume the ecall it just
		// made) — this unconditional "+4, resume right after the ecall"
		// would silently clobber that back to the old image's own
		// address. Found the hard way: SYS_EXEC's own staging/mapping
		// logic was already provably correct (a byte-for-byte checksum
		// of the loaded image matched, and per-step debug prints showed
		// no failure at any point) yet execution kept faulting inside
		// the *old* image's own code right after the ecall returned —
		// this is why: the redirect was being set correctly and then
		// overwritten before it ever took effect.
		// f.a0 carries argc on a successful SYS_EXEC now (0 or more, see
		// that case's own comment), not a plain 0 return value — a real
		// failure still sets it to (ulong)(-1), so "non-negative" is the
		// right success test, not "== 0" (argc can genuinely be nonzero).
		bool just_execd = syscall_num == SYS_EXEC && (long)f.a0 >= 0;
		if (!just_execd)
		{
			current_proc.saved_sepc = user_pc + 4;
		}
	}
	else
	{
		io::printfn("unexpected trap scause=%x, stval=%x, sepc=%x, current_pid=%d\n", scause, stval, user_pc, current_proc.pid);
		panic::panic("it's a trap!");
	}

	// The one place the real sepc CSR actually gets written, always
	// immediately before this function returns (and so, immediately
	// before kernel_entry's own tail-end sret, with nothing able to run
	// in between) — see Process.saved_sepc's own comment for why this
	// needs to read per-process state rather than just trust the
	// hardware register survived whatever this trap's own handling did.
	write_sepc(current_proc.saved_sepc);

	// No blocking_depth check here, deliberately — see its own comment
	// (process.c3) for why not: an earlier version of this fix also
	// forced SPIE off here whenever blocking_depth was nonzero, but
	// blocking_depth is *effectively always* nonzero during normal
	// operation (echod/fsd/procd/envd — every idle server — sit
	// permanently blocked in SYS_IPC_RECV waiting for their next
	// client; that's their normal steady state, not a transient
	// window). Gating this shared tail on it would have disabled real
	// timer-interrupt preemption for the *entire system*, forever, from
	// very early in boot onward — found directly, real hardware/QEMU
	// testing this session, when hotplugtest itself started hanging
	// once this was in place. The kernel_entry tail's own sret already
	// correctly restores SIE from *this process's own* sstatus snapshot
	// (auto-captured at *this same trap's* own entry) — safe by the
	// existing, already-proven invariant (enable_timer_interrupts()'s
	// own comment above): SIE only actually needs forcing off for a
	// *synthetic* sret with no real corresponding trap-entry of its
	// own, which only ever happens in fork_entry() (process.c3) — never
	// here.
}
