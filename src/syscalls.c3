module kernel;

import std::io;
import panic;
import board;
import sbi;

// The syscall layer, split out of entry.c3 (which keeps the trap path:
// CSR helpers, kernel_entry, Trap_frame, timer, external IRQs, lazy
// faults, handle_trap). handle_trap's SCAUSE_ECALL case calls
// handle_syscall() below; everything else here is reached from it.
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
// 9 was SYS_DISKD_INFO — subsumed by SYS_DEV_INFO (60). Left unused, not renumbered.
const SYS_IPC_POLL   = 10; // non-blocking SYS_IPC_RECV, see its case below
const SYS_RFORK       = 11;
const SYS_NS_UNMOUNT  = 12; // remove one of the caller's own namespace mounts by exact prefix
const SYS_JOIN        = 13; // block until the given pid no longer exists — see its case below
const SYS_FS_PARTITION_INFO = 14; // fsd-only: returns current_proc.fs_partition_start —
                                    // board is a kernel-only module (see user/sdd.c3's own
                                    // header comment), so this is fsd.c3's only way to learn
                                    // a board-specific fact despite being one board-agnostic
                                    // user binary, same shape as SYS_DEV_INFO below. Reads
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
// 28 was SYS_USBD_INFO — subsumed by SYS_DEV_INFO (60).
// 29 was SYS_NETD_INFO — subsumed by SYS_DEV_INFO (60).
// 30 was SYS_ETHD_INFO — subsumed by SYS_DEV_INFO (60).
const SYS_KBD_PUSH      = 31; // usbd-only in practice: pushes one decoded USB-keyboard byte into the kernel keystroke queue SYS_GETCHAR drains (src/kbd.c3) — see its case below
const SYS_DRIVER_IRQ_ARM = 32; // interrupt-driven driver: re-enable this driver's PLIC source, disabled by handle_trap on each fire (level source); the source is the one the caller registered in the Irq_route table (process.c3) — see its case below
// 33 was SYS_SDD_INFO — subsumed by SYS_DEV_INFO (60).
const SYS_IPC_CALL      = 34; // one-shot RPC: deliver a request to a server and block for its reply, all in the kernel — the reply can't be pre-empted by a stray sender, and the whole thing aborts with -1 if the server dies at any point (see its case below); user-space p9_call is now just this
const SYS_GETUID        = 35; // the caller's own uid — see its case below
const SYS_BOOT_QUIET    = 36; // shell-only, called once after boot settles: silences boot servers' console output — see SYS_PUTCHAR
const SYS_CHDIR         = 37; // set the caller's cwd (a0 = absolute, normalised path, <100 bytes) — the shell's `cd`
const SYS_GETCWD        = 38; // copy the caller's cwd out (a0 = buf, a1 = cap) — `pwd`, the prompt, the fs_* wrappers
const SYS_PIPE          = 39; // allocate an anonymous pipe, returns its id or -1 — src/pipe.c3
const SYS_PIPE_SETOUT   = 40; // point a child's stdout at a pipe: a0 = child pid, a1 = pipe id (or -1 to detach)
const SYS_PIPE_SETIN    = 41; // point a child's stdin at a pipe: a0 = child pid, a1 = pipe id (or -1)
const SYS_PIPE_READ     = 42; // drain a pipe into a buffer: a0 = id, a1 = buf, a2 = max; returns bytes (0 = EOF)
const SYS_PIPE_WRITE    = 43; // feed a buffer into a pipe: a0 = id, a1 = buf, a2 = len; returns bytes written
const SYS_PIPE_HOLD     = 44; // the shell claims/releases a pipe end it pumps itself (>/< redirection): a0 = id, a1 = as_writer, a2 = delta (+1/-1)
const SYS_NS_LIST       = 45; // copy the caller's own namespace (mount table) out: a0 = buf, a1 = max records (36 bytes each: 32-byte prefix + 4-byte LE pid); returns the count — the shell's `namespace`
const SYS_NS_BIND       = 46; // bind whatever currently serves a1 (a path resolved through the caller's namespace) at a0 (a new prefix) in that same namespace — Plan 9's `bind`, the source-is-a-path counterpart to SYS_NS_MOUNT
const SYS_MAP           = 47; // map a0 bytes (rounded up to pages) of fresh zero-filled RW memory just past the caller's image, returns the base vaddr or -1 — the userspace "give me a heap" primitive (/bin/wasm's module buffer + stacks + linear memory)
const SYS_STDIN_ISATTY  = 48; // 1 if the caller's stdin is the console, 0 if a pipe — a poor-man's isatty(0) for the stdin-reading filters (/bin/head, /bin/cat)
const SYS_TIMEBASE      = 49; // board::TIMEBASE_HZ — the `time` CSR's tick rate, so userspace can turn an rdtime() delta into wall-clock seconds (QEMU 10MHz vs Duo 25MHz)
const SYS_GETPID        = 50; // the caller's own pid — a c3 program gets its children's pids from rfork() but never its own; the C libc's getpid() needs it (temp-file names, etc.)
const SYS_EXEC_MAX      = 51; // board::EXEC_MAX_IMAGE_SIZE — the shell reads this to size its own exec() receive buffer per-board instead of hardcoding a constant
const SYS_NS_TRANSLATE  = 52; // a0 = path, a1 = union member index, a2 = out buf, a4 = out cap — writes the server-relative path for that member, returns the serving pid (-1 = no match); the union-aware successor to SYS_NS_RESOLVE + caller-side prefix strip
const SYS_PROF          = 53; // a0 = out buf (>= 32 bytes: 4 LE u64 — ipc_calls, ipc_ticks, yields, switches), a1 = reset flag — cheap on-device profiling odometer (gobuildtest)
const SYS_PROF_HIST     = 54; // DIAGNOSTIC (temporary): a0 = out buf (512 bytes = 64 LE u64, indexed by syscall number), a1 = reset flag — the `synhist` builtin, chasing the go-build syscall storm
const SYS_DRIVER_IRQ_WAIT = 55; // interrupt-driven driver: block until this driver's pending device-completion notify (driver_irq_pending) is set, hand-draining the PLIC each pass — one syscall per completion in place of diskd's per-sector SYS_IPC_POLL spin (docs/ipc-rings.md P1). Returns 0, or -1 if not a routed driver.
const SYS_DISK_ARENA_INFO = 56; // diskd + primary fsd only: a0 -> arena paddr, a1 -> arena size (u32). The fsd<->diskd shared payload region (docs/ipc-rings.md P1 step 2) — identity-mapped into both by device_setup (device.c3) / setup_fsd_mappings. Returns 0, or -1 for any other caller / before it's allocated.
const SYS_KLOG_READ  = 57; // a0 = out buf, a1 = max bytes, a2 = ulong* cursor (bytes-consumed counter; 0 = from the oldest byte still in the ring). Copies newer kernel-console bytes out, advances *cursor, returns the count. The kernel log ring (sbi.c3) — /bin/dmesg.
const SYS_PROC_STAT  = 58; // a0 = slot (1..PROCS_MAX), a1 = out buf (>= 52 bytes): [0..3] state LE, [4..7] uid LE, [8..11] generation LE, [12..15] resident pages LE, [16..19] real pid LE, [20..51] name (NUL-padded). Returns 0, or -1 for an unused slot. /bin/ps + /bin/top.
const SYS_GETCHAR_NB = 59; // non-blocking console read: one keystroke from the USB-kbd queue or serial console, or -1 immediately if none waiting. Console only (returns -1 when stdin is a pipe). Lets a follow/redraw loop (`dmesg -f`, `top`) bail on a keypress — racccoon has no ^C.
const SYS_POSTNOTE   = 61; // a0 = pid (a1 == 0) or note group (a1 == 1), a2 = message: post a note (src/note.c3) — root or same uid per target; returns how many got it, or -1
const SYS_NOTIFY     = 62; // a0 = note handler address (0 = none: notes kill) — src/note.c3
const SYS_NOTED      = 63; // a0 = NCONT (resume the interrupted context) / NDFLT (die) — the last thing a note handler does
const SYS_INTERRUPTED = 64; // 1 if the caller's last interruptible wait returned -1 because of a note, else 0 (read-and-clear)
const SYS_AWAIT      = 65; // a0 = AW_* mask, a1 = timeout in time-CSR ticks (0 = none), a2 = int* pipe ids, a4 = how many (<= AW_MAX_PIPES): block until any is ready, return the ready AW_* mask — see sys_await
const SYS_SEGATTACH   = 66; // a0 = name, a1 = size (to create; 0 = attach existing): map a named shared segment, returns its vaddr or -1 — src/segment.c3
const SYS_SEGDETACH   = 67; // a0 = vaddr from SYS_SEGATTACH: unmap it and drop the reference — src/segment.c3
const SYS_WAKE        = 68; // a0 = pid, a1 = expected generation (0 = any): ring that process's doorbell (AW_WAKE) — root or same uid; 0 / -1
const SYS_WRITE       = 69; // a0 = buf, a1 = len: write to stdout (pipe or console), same routing as SYS_PUTCHAR; returns bytes written
const SYS_DEV_INFO   = 60; // a0 = out uptr[] , a1 = capacity (<= 4): the physical base of each DMA region the caller's board device (src/device.c3) declared, in declaration order. Returns how many regions the device has, or -1 for a process that owns no device. One syscall for every hardware driver — replaces SYS_DISKD/USBD/NETD/ETHD/SDD_INFO.

// Per-process SYS_MAP ceiling: the bump pointer can't grow more than this
// past USER_BASE. Board-specific (board::HEAP_MAX_BYTES): 16 MiB on the
// Duo — generous for a wasm linear memory, keeps PROCS_MAX processes all
// maxing out under its 64 MiB RAM pool; 64 MiB on QEMU/JH7110 so a Go
// process can map its heap arena (docs/go-port-plan.md).
const uptr HEAP_MAX_BYTES = board::HEAP_MAX_BYTES;

// Flipped by SYS_BOOT_QUIET (the shell, once, after a settle delay).
// While true, SYS_PUTCHAR from a process with is_boot_server set is
// dropped — keeps late server init chatter off the prompt.
bool g_boot_quiet = false;

// Cap on the image SYS_EXEC will install — board-specific
// (board::EXEC_MAX_IMAGE_SIZE). racccoon's own binaries (build/user/*.bin)
// run 70-105KB and a native TinyCC (roadmap §7) is ~640KB, so the Duo
// keeps this at 1 MiB; QEMU/JH7110 raise it to 4 MiB for the Go port
// (a GOOS=tamago static binary is 1-4 MiB — docs/go-port-plan.md). The
// staging arrays it sizes (g_exec_staged / g_exec_seg_perm, below) are
// file-scope, not on the kernel stack — see their comment. user/user.c3's
// exec() wrapper and lib/racccoon-libc's execve() take their bound from
// the caller-provided buffer size; the shell's is SYS_EXEC_MAX-driven.
const EXEC_MAX_IMAGE_SIZE  = board::EXEC_MAX_IMAGE_SIZE;
const EXEC_MAX_IMAGE_PAGES = EXEC_MAX_IMAGE_SIZE / PAGE_SIZE;

// argv blob cap (user/user.c3's exec() / the libc execve(), NUL-separated
// strings packed right after the image in the same buffer). 16 KiB — a
// compiler invocation's argv (many -I/-D/-L, a full env) is bigger than
// a shell command's, still a small fixed second staging pass.
const EXEC_MAX_ARGV_SIZE  = 16384;
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
// The child starts its own note group (src/note.c3) instead of sharing
// the parent's — so a ^C aimed at the parent's group (the console's)
// doesn't reach it. The shell uses it for `&` jobs.
const int RFNOTEG = 1 << 2;

// Wall-clock ceiling on SYS_IPC_CALL. Without it a client blocks forever
// against a server that is alive but not yet in its ipc_recv loop (a
// freshly respawned fsd/sdd still running its init), and the message it
// deposited sits unconsumed long enough for the supervisor watchdog to
// (wrongly) kill that server too. On a timeout the caller gets -1 to
// retry, and phase 2 yanks its un-consumed request back out of the
// peer's inbox so the watchdog never sees a stall. Generous — a real
// fsd op is sub-second; this only fires on a genuine wedge. Enforced by
// ipc_timeout_sweep() (entry.c3), not the call's own loop, because a
// PROC_BLOCKED caller never runs to check.
const ulong IPC_CALL_DEADLINE_TICKS = board::TIMEBASE_HZ * 15;

// The shared process-teardown body: record the exit code, wake any IPC
// partner parked on a rendezvous with this process, drop its pipe ends,
// free its address space (unless an rfork(RFPROC|RFMEM) sibling still
// shares the page_table), and mark the slot PROC_UNUSED. Extracted from
// sys_exit / sys_kill, which had byte-identical teardown bodies; also
// called by the supervisor watchdog (src/supervisor.c3) on a wedged
// server. Safe from the timer-trap context the watchdog runs in — it's
// the same page alloc/free machinery the respawn path there already uses.
fn void proc_destroy(Process* target, int exit_code) @noinline
{
	proc_record_exit(target.pid, target.generation, target.parent_pid, exit_code);

	// A target torn down mid-blocking-wait would otherwise leak its
	// blocking_depth increment (see the note this used to carry inline in
	// sys_kill). Only ever true on the kill / watchdog paths — a process
	// running SYS_EXIT is not in a blocking wait.
	if (target.in_blocking_wait) blocking_depth--;

	ipc_wake_waiters_on(target);
	// Leave any send queue the target was waiting on, and drop its own:
	// every sender queued on it was just woken with ipc_peer_died (they
	// all have ipc_wait_pid == target) and unlinks itself — a search
	// that tolerates the head being gone.
	ipc_q_remove(target);
	target.ipc_q_head = 0;
	if (target.stdout_pipe >= 0) { pipe_detach(target.stdout_pipe, true);  target.stdout_pipe = -1; }
	if (target.stdin_pipe  >= 0) { pipe_detach(target.stdin_pipe,  false); target.stdin_pipe  = -1; }

	bool table_shared = false;
	for (int i = 0; i < PROCS_MAX; i++)
	{
		if (&procs[i] == target) continue;
		if (procs[i].state == PROC_UNUSED) continue;
		if (procs[i].page_table == target.page_table) { table_shared = true; break; }
	}
	if (!table_shared)
	{
		// Shared segments (src/segment.c3) this address space had attached
		// lose a reference; their pages are PAGE_SHARED, so the walk below
		// leaves them alone.
		seg_release_table(target.page_table);
		ulong* t2 = target.page_table;
		for (uint vpn2 = 0; vpn2 < 512; vpn2++)
		{
			if ((t2[vpn2] & PAGE_V) == 0) continue;
			ulong* t1 = (ulong*)pte_to_paddr(t2[vpn2]);
			for (uint vpn1 = 0; vpn1 < 512; vpn1++)
			{
				if ((t1[vpn1] & PAGE_V) == 0) continue;
				ulong* t0 = (ulong*)pte_to_paddr(t1[vpn1]);
				for (uint vpn0 = 0; vpn0 < 512; vpn0++)
				{
					if ((t0[vpn0] & PAGE_V) == 0) continue;
					if (pte_owned_user_leaf(t0[vpn0])) { free_pages(pte_to_paddr(t0[vpn0]), 1); }
				}
				free_pages((uptr)t0, 1);
			}
			free_pages((uptr)t1, 1);
		}
		free_pages((uptr)t2, 1);
	}

	// SMP Stage B: release the slot under proc_table_lock so it
	// establishes a happens-before with the scan-and-claim in
	// create_process / sys_rfork (a plain word store on one hart, an
	// ordering point once a second hart can be scanning). Taken after all
	// the free_pages() above — never the reverse order.
	proc_table_lock.acquire();
	target.state = PROC_UNUSED;
	target.pid = 0;
	proc_table_lock.release();
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
		// Can't tear down the very page table the running code is
		// under — reject; SYS_EXIT is how a process kills itself.
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
	// A killed process counts as a failed command for the shell's
	// `&&` / `||` (code -1). Teardown is shared with sys_exit and the
	// supervisor watchdog — see proc_destroy.
	proc_destroy(kill_target, -1);
	f.a0 = 0;
}

// SYS_EXIT: tear this process down (proc_destroy — shared with sys_kill)
// and yield() into whatever runs next; the yield never returns since the
// slot is PROC_UNUSED now. (Was inlined in handle_syscall as a
// c3c-0.8.2 landmine workaround; 0.8.3 probe 2026-08-28 showed the
// extraction is safe.)
fn void sys_exit(Trap_frame* f) @noinline
{
		proc_destroy(current_proc, (int)f.a0);
		// yield() never returns here: current_proc is now PROC_UNUSED, so
		// the scan can't match itself and switch_context's `ret` jumps
		// permanently into whatever process it picks instead.
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

		// SMP Stage B: claim the slot atomically as PROC_RESERVED (see
		// process.c3's PROC_RESERVED / proc_table_lock). Any early return
		// below (the OOM bail) must hand it back with PROC_UNUSED; the
		// state only flips to PROC_RUNNABLE once the child is fully built.
		Process* child = null;
		int child_i;
		proc_table_lock.acquire();
		for (child_i = 0; child_i < PROCS_MAX; child_i++)
		{
			if (procs[child_i].state == PROC_UNUSED)
			{
				child = &procs[child_i];
				child.state = PROC_RESERVED;
				break;
			}
		}
		proc_table_lock.release();
		if (!child)
		{
			f.a0 = (ulong)(-1);
			return;
		}
		if (!proc_slot_buffers(child))
		{
			child.state = PROC_UNUSED; // OOM on a never-used slot: hand it back
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

			// Count the parent's PAGE_U leaves first, and bail with -1
			// (not a kernel OOM panic) if there isn't enough free RAM
			// for the child: 1 root table + ~35 kernel-identity-map
			// intermediate tables + one fresh page per leaf + the
			// child's own user-region intermediate tables (leaf/256 is
			// a generous ceiling). The count walk allocates nothing;
			// kernel code isn't preempted, so the count stays valid
			// through the allocations below.
			ulong* rf_pt2 = current_proc.page_table;
			uint rf_leaves = 0;
			for (uint rv2 = 0; rv2 < 512; rv2++)
			{
				if ((rf_pt2[rv2] & PAGE_V) == 0) continue;
				ulong* rf_pt1 = (ulong*)pte_to_paddr(rf_pt2[rv2]);
				for (uint rv1 = 0; rv1 < 512; rv1++)
				{
					if ((rf_pt1[rv1] & PAGE_V) == 0) continue;
					ulong* rf_pt0 = (ulong*)pte_to_paddr(rf_pt1[rv1]);
					for (uint rv0 = 0; rv0 < 512; rv0++)
					{
						if (pte_owned_user_leaf(rf_pt0[rv0])) rf_leaves++;
					}
				}
			}
			if (free_page_count() < rf_leaves + rf_leaves / 256 + kernel_map_table_pages() + 4
				|| seg_attach_free_slots() < seg_attachments_of(current_proc.page_table))
			{
				child.state = PROC_UNUSED; // hand the reserved slot back
				f.a0 = (ulong)(-1);
				return;
			}

			ulong* child_table = (ulong*)alloc_pages(1);
			for (uptr paddr = (uptr)&__kernel_map_base; paddr < (uptr)&__free_ram_end; paddr += PAGE_SIZE)
			{
				map_page(child_table, paddr, paddr, PAGE_R | PAGE_W | PAGE_X);
			}
			map_plic(child_table);
			map_console_mmio(child_table);

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
						uptr child_vaddr  = ((uptr)vpn2 << 30) | ((uptr)vpn1 << 21) | ((uptr)vpn0 << 12);
						uint parent_flags = (uint)(parent_table0[vpn0] & 0x1f); // V|R|W|X|U — see page.c3's map_page encoding

						// Not the parent's own page (PAGE_SHARED): the child
						// maps the same one, it doesn't get a private copy.
						if (!pte_owned_user_leaf(parent_table0[vpn0]))
						{
							map_page(child_table, child_vaddr, parent_leaf_paddr, parent_flags | PAGE_SHARED);
							continue;
						}

						uptr child_leaf_paddr  = alloc_pages(1);
						mem::copy((void*)child_leaf_paddr, (void*)parent_leaf_paddr, (sz)PAGE_SIZE);
						map_page(child_table, child_vaddr, child_leaf_paddr, parent_flags);
					}
				}
			}
			child.page_table = child_table;
			// The walk mapped the parent's shared-segment pages into the
			// child; give the child its own references to them.
			seg_dup_attachments(current_proc.page_table, child_table);
		}

		// Namespace: always copied, regardless of RFMEM — cheap
		// (4 x Mount), and there's no mount/unmount syscall yet to
		// make "shared" vs. "copied" observably different. The seam
		// a future RFNAMEG-equivalent would slot into.
		for (int ns_i = 0; ns_i < NS_MOUNTS_MAX; ns_i++)
		{
			child.namespace[ns_i] = current_proc.namespace[ns_i];
		}
		for (int cw = 0; cw < 100; cw++) { child.cwd[cw] = current_proc.cwd[cw]; }
		// Inherit the parent's name until the child exec()s its own image
		// (sys_exec overwrites it from argv[0]); a plain rfork'd worker
		// with no exec keeps showing the parent's name in `ps`/`top`.
		for (int nm = 0; nm < 32; nm++) { child.name[nm] = current_proc.name[nm]; }

		// Build the child's first-resume state: a copy of this
		// trap's own Trap_frame (a0 zeroed — the child's return
		// value), plus this trap's own resume address as an extra
		// 32nd word, since sepc is a single CSR fork_entry can't
		// otherwise inherit. See fork_entry's own comment in
		// process.c3 for how this block gets consumed. 32 words of
		// 8 bytes now (Sv64 port), not 4.
		uptr* child_sp = (uptr*)proc_kstack_top(child);
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
		child.ipc_progress = 0;
		child.wake_pending = false;
		child.sleep_deadline = 0;
		child.driver_irq_pending = false; // reused-slot hygiene (a driver's slot never actually gets rfork'd, but keep it clean)
		// rfork(RFPROC) copies every PAGE_U leaf, so the child's mapped
		// region — including any pages the parent SYS_MAP'd — matches the
		// parent's at fork time. Continue the bump pointer from there.
		child.heap_top = current_proc.heap_top;
		child.map_floor = current_proc.map_floor;
		// FP state: the child inherits the parent's, exactly (fork copy
		// semantics). The live f-registers still hold the parent's values
		// here — kernel_entry saves GPRs only and the handler is
		// integer-only — so snapshot them straight into the child's area
		// rather than struct-copying parent.fp_area (avoids any question
		// about how a 264-byte aggregate copy lowers).
		fp_save((uptr)&child.fp_area);
		// Same reused-slot reasoning as has_message above — a
		// previous occupant of this slot could have been killed
		// while genuinely mid a blocking wait (SYS_KILL's own
		// leak-safety check, below in this same file, only cleans up
		// blocking_depth itself, not this per-process flag). See
		// Process.in_blocking_wait's own comment (process.c3).
		child.in_blocking_wait = false;
		// Same reused-slot reasoning — don't inherit a stale IPC wait.
		child.ipc_wait_pid = 0;
		child.ipc_wait_generation = 0;
		child.ipc_peer_died = false;
		child.in_call_reply_wait = false;
		child.ipc_q_head = 0;
		child.ipc_q_next = 0;
		child.ipc_q_target = 0;
		child.ipc_call_deadline = 0;
		child.ipc_timed_out = false;
		child.is_boot_server = false; // an rfork child is user work, not a boot server
		child.device = -1;            // ...and owns no device (device.c3)
		// a2 / a4 (optional, RFPROC only): wire the child's stdout / stdin
		// to these pipe ids atomically, as part of the fork. Both the c3
		// shell (`|`, `>`, `<`) and Go's os/exec use this. A follow-up
		// SYS_PIPE_SETOUT/SETIN has a race window the caller can't close:
		// Go's runtime yields at the first safepoint after rfork, and the
		// c3 shell — despite the "cooperative, doesn't yield until the
		// pump" note it used to carry — is timer-preemptible at every
		// tick (the SCAUSE_SUPERVISOR_TIMER handler yield()s whenever
		// current_proc.pid > 0), so a tick landing between the fork and
		// the setout lets a fast child (/bin/echo) run and exit with its
		// output still on the console. Rare (a ~µs window per ~10 ms
		// tick) but real. pipe_valid rejects anything that isn't a live
		// pipe id (rfork()/rfork_io() pass -1 when unused; threadcreate
		// leaves stale values here, hence the RFMEM exclusion). -1 /
		// invalid = plain console.
		//
		// No explicit pipe (or an RFMEM thread): the child inherits the
		// parent's own stdout/stdin, holding its own reference on each pipe
		// end — fork semantics. It used to fall back to the console, so a
		// forked helper inside a pipeline stage (nc's receiving half in
		// `nc host port | wc -c`) wrote straight to the terminal.
		int rfork_stdout_pipe = (int)f.a2;
		int rfork_stdin_pipe  = (int)f.a4;
		bool explicit_out = (rfork_flags & RFMEM) == 0 && rfork_stdout_pipe >= 0 && pipe_valid(rfork_stdout_pipe);
		bool explicit_in  = (rfork_flags & RFMEM) == 0 && rfork_stdin_pipe >= 0 && pipe_valid(rfork_stdin_pipe);
		child.stdout_pipe = explicit_out ? rfork_stdout_pipe : current_proc.stdout_pipe;
		child.stdin_pipe  = explicit_in  ? rfork_stdin_pipe  : current_proc.stdin_pipe;
		if (child.stdout_pipe >= 0 && pipe_valid(child.stdout_pipe)) { pipes[child.stdout_pipe].writers++; } else { child.stdout_pipe = -1; }
		if (child.stdin_pipe >= 0 && pipe_valid(child.stdin_pipe)) { pipes[child.stdin_pipe].readers++; } else { child.stdin_pipe = -1; }
		child.pid   = child_i + 1;
		child.generation++;
		// Notes (src/note.c3): the handler is inherited (fork copies the
		// code it points at), pending notes are not; so is the note group,
		// unless RFNOTEG asks for a fresh one. A fork from inside a handler
		// carries the parked context too, so the child's noted() works.
		child.note_head = 0;
		child.note_count = 0;
		child.note_handler = current_proc.note_handler;
		child.in_note = current_proc.in_note;
		child.note_frame = current_proc.note_frame;
		child.note_sepc = current_proc.note_sepc;
		child.note_fp = current_proc.note_fp;
		child.note_intr = false;
		child.note_saved_intr = false;
		child.note_resumed = false;
		child.noteg = (rfork_flags & RFNOTEG) ? child.pid : current_proc.noteg;
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
// SYS_EXEC's per-page staging tables. File-scope, not stack locals: at
// EXEC_MAX_IMAGE_PAGES = 256 that's 3 KiB, too much for the 64 KiB
// kernel stack under sys_exec's already-deep frame. Safe as globals —
// sys_exec never yields (no blocking call between here and the commit
// point), so no second exec is ever in flight through this code. Both
// are fully re-initialised at the top of every sys_exec call.
uptr[EXEC_MAX_IMAGE_PAGES] g_exec_staged;
uint[EXEC_MAX_IMAGE_PAGES] g_exec_seg_perm;

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

		// Snapshot argv[0] NOW, while the caller's buffer is still mapped:
		// the page-table rewrite further down frees every old PAGE_U leaf
		// (the buffer among them), so `exec_image` is unreadable by the
		// time proc.name gets set at the end. The argv blob is the
		// NUL-separated strings packed right after the image content.
		char[48] exec_name_snap;
		exec_name_snap[0] = 0;
		if (exec_argc >= 1 && exec_argv_len > 0)
		{
			char* exec_a0 = (char*)(exec_image + exec_image_size);
			int ens = 0;
			while (ens < 47 && (uint)ens < exec_argv_len && exec_a0[ens] != 0)
			{
				exec_name_snap[ens] = exec_a0[ens];
				ens++;
			}
			exec_name_snap[ens] = 0;
		}

		// Stage every new page FIRST, before touching anything
		// about the process's current image — a failed allocation
		// partway through must leave the old image completely
		// intact, not half-replaced, same "fail toward not losing
		// what's already there" discipline this session's own
		// ext2 slot-reuse fix already established.
		//
		// g_exec_staged/g_exec_seg_perm are explicitly zeroed here
		// (they're persistent file-scope globals) rather than relying
		// on the flat-binary path's own
		// "every slot from 0..exec_page_count gets touched
		// sequentially" — the ELF path below fills these sparsely,
		// by segment page-range, and needs 0 to reliably mean "not
		// yet allocated" everywhere, including slots no segment ever
		// touches (a real, if rare, alignment gap between segments —
		// stays unmapped later, not silently zero-filled).
		uint exec_page_count = 0;
		for (uint zp = 0; zp < EXEC_MAX_IMAGE_PAGES; zp++)
		{
			g_exec_staged[zp] = 0;
			g_exec_seg_perm[zp] = 0;
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
					if (g_exec_staged[spi] == 0)
					{
						uptr exec_seg_page = try_alloc_pages(1);
						if (exec_seg_page == 0)
						{
							exec_stage_ok = false;
							break;
						}
						g_exec_staged[spi] = exec_seg_page;
					}
					g_exec_seg_perm[spi] |= exec_seg_flags;
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
					mem::copy((void*)(g_exec_staged[exec_dst_page] + exec_dst_in_page), exec_image + exec_p_offset + exec_copied, (sz)exec_chunk);
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
					|| g_exec_staged[(uint)((exec_e_entry - (ulong)USER_BASE) / (ulong)PAGE_SIZE)] == 0)
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
					if (g_exec_staged[fp] != 0) free_pages(g_exec_staged[fp], 1);
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
			// Bail with -1 (not an OOM panic in the map loop after the
			// old image is already gone) if the free pool can't cover
			// the image + argv + their page-table overhead. The staging
			// loops below have their own rollback for a mid-loop
			// failure; this just keeps the common case off the panic
			// path and the old image intact.
			uint exec_argv_pages_est = (exec_argv_len + PAGE_SIZE - 1) / PAGE_SIZE;
			uint exec_need = exec_page_count + exec_argv_pages_est
				+ (exec_page_count + exec_argv_pages_est) / 256 + 6;
			if (free_page_count() < exec_need)
			{
				f.a0 = (ulong)(-1);
				return;
			}
			for (uint ep = 0; ep < exec_page_count; ep++)
			{
				uptr exec_page = try_alloc_pages(1);
				if (exec_page == 0)
				{
					exec_stage_ok = false;
					for (uint fp = 0; fp < ep; fp++) free_pages(g_exec_staged[fp], 1);
					break;
				}
				uint exec_off = ep * PAGE_SIZE;
				uint exec_remaining = exec_image_size - exec_off;
				uint exec_copy_size = exec_remaining < PAGE_SIZE ? exec_remaining : PAGE_SIZE;
				mem::copy((void*)exec_page, exec_image + exec_off, (sz)exec_copy_size);
				g_exec_staged[ep] = exec_page;
				g_exec_seg_perm[ep] = PAGE_R | PAGE_W | PAGE_X;
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
			uptr argv_page = try_alloc_pages(1);
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
				if (g_exec_staged[fp] != 0) free_pages(g_exec_staged[fp], 1);
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
						if (pte_owned_user_leaf(exec_table0[evpn0])) { free_pages(pte_to_paddr(exec_table0[evpn0]), 1); }
						exec_table0[evpn0] = 0;
					}
				}
			}
		}

		// The PTE clear above also dropped every shared segment mapping —
		// release those attachments (src/segment.c3).
		seg_release_table(current_proc.page_table);

		// Map the newly staged pages at USER_BASE, with each page's
		// own accumulated permission (uniform RWX for the flat-binary
		// path, the real per-segment union for ELF — see g_exec_seg_perm's
		// own comment above). A real gap between ELF segments
		// (g_exec_staged[mp] == 0) stays unmapped, not silently
		// zero-filled.
		for (uint mp = 0; mp < exec_page_count; mp++)
		{
			if (g_exec_staged[mp] == 0) continue;
			map_page(current_proc.page_table, (uptr)USER_BASE + (uptr)(mp * PAGE_SIZE), g_exec_staged[mp], PAGE_U | g_exec_seg_perm[mp]);
		}

		// argv's own pages, right after the image's own last mapped
		// page — exec_page_count is already a whole number of pages,
		// so this is exactly contiguous, no gap.
		uptr exec_argv_base = (uptr)USER_BASE + (uptr)(exec_page_count * PAGE_SIZE);
		for (uint avp = 0; avp < argv_page_count; avp++)
		{
			map_page(current_proc.page_table, exec_argv_base + (uptr)(avp * PAGE_SIZE), argv_staged[avp], PAGE_U | PAGE_R | PAGE_W);
		}

		// Reset the SYS_MAP bump pointer to just past the new image +
		// argv. Any pages the *old* image had SYS_MAP'd were freed with
		// every other PAGE_U leaf in the page-table clear above.
		current_proc.heap_top = exec_argv_base + (uptr)(argv_page_count * PAGE_SIZE);
		// The old image's note handler is gone with its code; pending notes
		// stay (a ^C that raced the exec still applies to the new image).
		current_proc.note_handler = 0;
		current_proc.in_note = false;
		current_proc.map_floor = current_proc.heap_top; // lazy SYS_MAP region starts empty

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
		// Same class of bug one level down: the new image was just WRITTEN
		// with ordinary stores, and instruction fetch does not see those
		// without a fence.i (real cores with a separate I-cache, e.g. the
		// U74) — see sync_icache() in process.c3.
		sync_icache();

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

		// Fresh image, fresh FP state: zero the saved f-regs + fcsr and
		// the live ones. Unlike fork (copy semantics — inherit the
		// parent's fcsr), exec starts a different program, which must not
		// see the old image's rounding mode or sticky exception flags.
		// The live reset matters because sys_exec returns through the
		// normal trap tail (no switch_context / fp_restore) — the new
		// image runs immediately on whatever's in the hardware f-regs.
		for (int fk = 0; fk < 33; fk++) { current_proc.fp_area[fk] = 0; }
		fp_reset();

		// argc/argv's own base address, handed off via a0/a1 exactly
		// the way a normal syscall would hand back a return value —
		// safe to repurpose them for this instead, since control
		// never returns to the caller on success (the redirect above
		// means the syscall-wrapper code that would have read a0 as
		// a return value never executes). user/user.c3's start()
		// stashes both before ever calling main(); get_argv() reads
		// them from there. exec_argc is always >= 0 here (a real
		// error already returned -1 and broken out above), so
		// handle_trap()'s own just_execd check (entry.c3) tests
		// "(long)f.a0 >= 0" rather than "== 0" to tell this success
		// path apart from that failure one.
		// Name this process after argv[0]'s basename, for `ps` / `top`
		// (SYS_PROC_STAT) — from the snapshot taken before the remap, since
		// the caller's argv buffer is unmapped by now.
		if (exec_name_snap[0] != 0)
		{
			proc_set_name(current_proc, &exec_name_snap[0]);
		}

		f.a0 = (ulong)exec_argc;
		f.a1 = (ulong)exec_argv_base;

		// tp is otherwise left exactly as it was in the CALLING image's
		// trapframe — exec() doesn't touch it at all, so a fresh image
		// silently inherits whatever the previous program (or, further
		// back, create_process's own user_entry(), which never sets tp
		// either) last put there. Invisible as long as nothing reads tp;
		// surfaced for real once std::io's tlocal thread_allocator
		// (user/std_racccoon/, "std::io on racccoon") became the first
		// userspace code to actually use it — tp held a leftover
		// kernel-boot-time address, and thread_allocator's tp-relative
		// TLS access faulted reading through it. Same reasoning as a0/a1
		// above, just for a register nothing needed zeroed until now.
		f.tp = 0;
}

// True while this process is blocked in ipc_send/ipc_reply toward a
// peer that has since exited or been killed: either sys_exit/sys_kill's
// sweep already flagged us (ipc_peer_died), or the peer's slot is now
// empty / holds a different instance. Both send and reply poll this in
// their wait loops and bail with -1 instead of hanging forever on a
// rendezvous the dead peer can never complete. See docs/roadmap.md §5.
fn bool ipc_peer_gone() @noinline
{
	if (current_proc.ipc_wait_pid == 0) { return false; }
	if (current_proc.ipc_peer_died) { return true; }
	Process* peer = proc_by_pid(current_proc.ipc_wait_pid);
	return peer == null || peer.generation != current_proc.ipc_wait_generation;
}

// Can the current process deposit a message into `target`'s inbox right
// now? No if a message is already sitting there unconsumed, or if
// `target` is mid-SYS_IPC_CALL and has its inbox reserved for the reply
// from someone other than us. A stray sender just spins in its phase-A
// loop until the reservation lifts (rather than the old P9_STRAY bounce).
fn bool ipc_inbox_available(Process* target) @noinline
{
	if (target.has_message) { return false; }
	if (target.in_call_reply_wait
		&& !(current_proc.pid == target.ipc_wait_pid
			&& current_proc.generation == target.ipc_wait_generation))
	{
		return false;
	}
	return true;
}

// --- FIFO send queue (Process.ipc_q_*) -------------------------------
// Append the current process to `target`'s send queue.
fn void ipc_q_enqueue(Process* target) @noinline
{
	current_proc.ipc_q_next = 0;
	current_proc.ipc_q_target = target.pid;
	if (target.ipc_q_head == 0)
	{
		target.ipc_q_head = current_proc.pid;
		return;
	}
	Process* w = &procs[target.ipc_q_head - 1];
	for (int guard = 0; w.ipc_q_next != 0 && guard < PROCS_MAX; guard++)
	{
		w = &procs[w.ipc_q_next - 1];
	}
	w.ipc_q_next = current_proc.pid;
}

// Unlink `self` from whatever queue it's on, if any. Search-based, so it
// is harmless when the target slot has died and been reset (or reused)
// meanwhile: `self` just isn't found there any more.
fn void ipc_q_remove(Process* self) @noinline
{
	if (self.ipc_q_target != 0)
	{
		Process* target = &procs[self.ipc_q_target - 1];
		int* link = &target.ipc_q_head;
		for (int guard = 0; *link != 0 && guard < PROCS_MAX; guard++)
		{
			if (*link == self.pid)
			{
				*link = self.ipc_q_next;
				break;
			}
			link = &procs[*link - 1].ipc_q_next;
		}
	}
	self.ipc_q_next = 0;
	self.ipc_q_target = 0;
}

// May the current process (already on `target`'s queue) deposit now?
// The inbox must be free, and it must be the queue's head — unless
// `target` is mid-SYS_IPC_CALL waiting for *our* reply, in which case
// ipc_inbox_available has already said no to everyone but us, and the
// reply must not wait behind ordinary requests queued for the target.
fn bool ipc_can_deposit(Process* target) @noinline
{
	if (!ipc_inbox_available(target)) { return false; }
	return target.in_call_reply_wait || target.ipc_q_head == current_proc.pid;
}

// `target`'s inbox just freed up (a message consumed, a call's
// reservation lifted, a timed-out request yanked back): wake every
// queued sender so each re-checks ipc_can_deposit. Waking all of them
// rather than just the head keeps a reply-in-waiting (which may sit
// anywhere in the queue) from being missed; FIFO order is still
// enforced by the head rule.
fn void ipc_inbox_freed(Process* target) @noinline
{
	int q = target.ipc_q_head;
	for (int guard = 0; q != 0 && guard < PROCS_MAX; guard++)
	{
		Process* w = &procs[q - 1];
		if (w.state == PROC_BLOCKED) { w.state = PROC_RUNNABLE; }
		q = w.ipc_q_next;
	}
}

// Wakes every process blocked in ipc_send/ipc_reply/ipc_call toward
// `victim` (which is about to become PROC_UNUSED) so those calls return
// -1 rather than blocking forever. Call before the victim's pid is zeroed.
fn void ipc_wake_waiters_on(Process* victim) @noinline
{
	for (int iw = 0; iw < PROCS_MAX; iw++)
	{
		Process* w = &procs[iw];
		if (w == victim || w.state == PROC_UNUSED) { continue; }
		if (w.ipc_wait_pid == victim.pid && w.ipc_wait_generation == victim.generation)
		{
			w.ipc_peer_died = true;
			if (w.state == PROC_BLOCKED) { w.state = PROC_RUNNABLE; }
		}
	}
}

// ipc send: rendezvous a message into the target's single inbox slot and block until it acks.
// (was inline in handle_syscall; extracted 2026-08-29.)
fn void sys_ipc_send(Trap_frame* f) @noinline
{
		// dest_pid/type/data are a0-a2 as usual; len is a4, since a3 is
		// always the syscall number (see syscall4 in user/user.c3 —
		// this is the one syscall that needs a 4th argument).
		int ipc_dest_pid = (int)f.a0;
		uint ipc_type    = (uint)f.a1;
		char* ipc_data   = (char*)(uptr)f.a2;
		int ipc_len      = (int)f.a4;
		int ipc_copy_len = ipc_len > MSG_MAX ? MSG_MAX : ipc_len;
		if (ipc_copy_len < 0) ipc_copy_len = 0;
		if (!user_range_valid(current_proc.page_table, (uptr)ipc_data, (ulong)ipc_copy_len, false))
		{
			f.a0 = (ulong)(-1);
			return;
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
			return;
		}

		current_proc.ipc_wait_pid = ipc_dest_pid;
		current_proc.ipc_wait_generation = ipc_target.generation;
		current_proc.ipc_peer_died = false;

		// Wait for the target's inbox to actually be free — a
		// previous sender's message that hasn't been consumed yet
		// must never be silently overwritten, and if the target is
		// mid-ipc_call its inbox is reserved for the reply. Queued in
		// arrival order and asleep (Process.ipc_q_*): ipc_inbox_freed
		// wakes us when the inbox frees. If the target exits
		// meanwhile, ipc_wake_waiters_on wakes us and ipc_peer_gone()
		// bails us out.
		ipc_q_enqueue(ipc_target);
		while (!ipc_can_deposit(ipc_target))
		{
			// Interruptible while still queued: nothing was delivered.
			if (note_deliverable(current_proc))
			{
				ipc_q_remove(current_proc);
				current_proc.ipc_wait_pid = 0;
				note_interrupted(current_proc);
				f.a0 = (ulong)(-1);
				return;
			}
			if (ipc_peer_gone())
			{
				ipc_q_remove(current_proc);
				current_proc.ipc_wait_pid = 0;
				current_proc.state = PROC_RUNNABLE;
				f.a0 = (ulong)(-1);
				return;
			}
			current_proc.state = PROC_BLOCKED;
			yield();
		}
		ipc_q_remove(current_proc);

		mem::copy(ipc_target.msg_data, ipc_data, (sz)ipc_copy_len);
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
		// instead). If the target dies still holding our message,
		// sys_exit/sys_kill's sweep sets ipc_peer_died + wakes us.
		while (!current_proc.msg_acked)
		{
			if (ipc_peer_gone())
			{
				current_proc.ipc_wait_pid = 0;
				current_proc.state = PROC_RUNNABLE;
				f.a0 = (ulong)(-1);
				return;
			}
			current_proc.state = PROC_BLOCKED;
			yield();
		}
		current_proc.ipc_wait_pid = 0;
		f.a0 = 0;
}

// ipc reply: hand a reply back to a sender parked in ipc_send, unblocking it.
// (was inline in handle_syscall; extracted 2026-08-29.)
fn void sys_ipc_reply(Trap_frame* f) @noinline
{
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
			return;
		}
		Process* reply_target = proc_by_pid(reply_dest_pid);
		if (!reply_target || (reply_expected_generation != 0 && reply_target.generation != reply_expected_generation))
		{
			f.a0 = (ulong)(-1);
			return;
		}

		current_proc.ipc_wait_pid = reply_dest_pid;
		current_proc.ipc_wait_generation = reply_target.generation;
		current_proc.ipc_peer_died = false;

		ipc_q_enqueue(reply_target);
		while (!ipc_can_deposit(reply_target))
		{
			if (ipc_peer_gone())
			{
				ipc_q_remove(current_proc);
				current_proc.ipc_wait_pid = 0;
				current_proc.state = PROC_RUNNABLE;
				f.a0 = (ulong)(-1);
				return;
			}
			current_proc.state = PROC_BLOCKED;
			yield();
		}
		ipc_q_remove(current_proc);

		mem::copy(reply_target.msg_data, reply_data, (sz)reply_copy_len);
		reply_target.msg_from = current_proc.pid;
		reply_target.msg_from_generation = current_proc.generation;
		reply_target.msg_type = reply_type;
		current_proc.msg_acked = false;
		reply_target.has_message = true;
		if (reply_target.state == PROC_BLOCKED)
		{
			reply_target.state = PROC_RUNNABLE;
		}

		// A client that dies between sending its request and consuming
		// our reply would otherwise leave us here forever — the sweep
		// in sys_exit/sys_kill wakes us with ipc_peer_died instead.
		while (!current_proc.msg_acked)
		{
			if (ipc_peer_gone())
			{
				current_proc.ipc_wait_pid = 0;
				current_proc.state = PROC_RUNNABLE;
				f.a0 = (ulong)(-1);
				return;
			}
			current_proc.state = PROC_BLOCKED;
			yield();
		}
		current_proc.ipc_wait_pid = 0;
		f.a0 = 0;
}

// ipc call: the full client-side RPC round-trip in one syscall — deliver
// a request to `dest` and block for `dest`'s reply. Everything ipc_send +
// a filtered ipc_recv used to do in user space (p9_call), plus:
//  - the reply CANNOT be pre-empted by a stray sender: in_call_reply_wait
//    reserves our inbox for `dest` for the whole call, so a third party's
//    ipc_send just waits its turn (no P9_STRAY bounce needed);
//  - it aborts with -1 if `dest` exits/is killed at ANY point, including
//    while we wait for the reply — the gap the plain ipc_send peer-death
//    fix couldn't reach (that only covered the send rendezvous).
// Buffer is in-place: `buf` holds `req_len` request bytes on entry, gets
// up to `buf_cap` reply bytes written back. a4 packs (req_len<<16)|buf_cap
// (both <= MSG_MAX). a5 = optional uint* for the reply verb. Returns the
// replier's pid (== dest) on success, -1 on failure.
fn void sys_ipc_call(Trap_frame* f) @noinline
{
	int   call_dest     = (int)f.a0;
	uint  call_verb     = (uint)f.a1;
	char* call_buf      = (char*)(uptr)f.a2;
	ulong call_packed   = f.a4;
	uint* call_type_out = (uint*)(uptr)f.a5;

	int call_req_len = (int)((call_packed >> 16) & 0xFFFF);
	int call_buf_cap = (int)(call_packed & 0xFFFF);
	if (call_req_len < 0) { call_req_len = 0; }
	if (call_req_len > MSG_MAX) { call_req_len = MSG_MAX; }
	if (call_buf_cap < 0) { call_buf_cap = 0; }
	if (call_buf_cap > MSG_MAX) { call_buf_cap = MSG_MAX; }

	int call_span = call_req_len > call_buf_cap ? call_req_len : call_buf_cap;
	if (!user_range_valid(current_proc.page_table, (uptr)call_buf, (ulong)call_span, true)
		|| (call_type_out != null && !user_range_valid(current_proc.page_table, (uptr)call_type_out, 4, true)))
	{
		f.a0 = (ulong)(-1);
		return;
	}

	Process* call_target = proc_by_pid(call_dest);
	if (!call_target)
	{
		f.a0 = (ulong)(-1);
		return;
	}

	current_proc.ipc_wait_pid = call_dest;
	current_proc.ipc_wait_generation = call_target.generation;
	current_proc.ipc_peer_died = false;
	current_proc.ipc_timed_out = false;
	// Reserve our inbox for call_target's reply for the whole call —
	// from here so a stray sender is held off even during phases 1/2.
	current_proc.in_call_reply_wait = true;
	// Arm the timeout — ipc_timeout_sweep() (run ~1/s from yield() and
	// the timer) flips ipc_timed_out + wakes us if the peer never gets
	// to us. See IPC_CALL_DEADLINE_TICKS.
	current_proc.ipc_call_deadline = read_reg("time") + IPC_CALL_DEADLINE_TICKS;

	// Phase 1: deposit the request into the target's inbox — queued
	// FIFO behind earlier senders, asleep until ipc_inbox_freed.
	ipc_q_enqueue(call_target);
	while (!ipc_can_deposit(call_target))
	{
		// Interruptible while still queued (the request hasn't reached
		// the server yet); from phase 2 on, the note waits until the
		// call completes.
		bool call_intr = note_deliverable(current_proc);
		if (call_intr || ipc_peer_gone() || current_proc.ipc_timed_out)
		{
			if (call_intr) { current_proc.note_intr = true; }
			ipc_q_remove(current_proc);
			current_proc.in_call_reply_wait = false;
			ipc_inbox_freed(current_proc);
			current_proc.ipc_wait_pid = 0;
			current_proc.ipc_call_deadline = 0;
			current_proc.state = PROC_RUNNABLE;
			f.a0 = (ulong)(-1);
			return;
		}
		current_proc.state = PROC_BLOCKED;
		yield();
	}
	ipc_q_remove(current_proc);
	mem::copy(call_target.msg_data, call_buf, (sz)call_req_len);
	call_target.msg_from = current_proc.pid;
	call_target.msg_from_generation = current_proc.generation;
	call_target.msg_type = call_verb;
	current_proc.msg_acked = false;
	call_target.has_message = true;
	if (call_target.state == PROC_BLOCKED) { call_target.state = PROC_RUNNABLE; }

	// Phase 2: wait for the target to consume the request.
	while (!current_proc.msg_acked)
	{
		if (ipc_peer_gone() || current_proc.ipc_timed_out)
		{
			// On a timeout the target never picked our request up (still
			// in its own init, or wedged). Pull it back out of the
			// target's inbox — safe here because on one hart the target
			// is not running while we are, so `has_message` still true
			// and still ours means it was never consumed. Leaving it
			// there is what let the supervisor watchdog kill an
			// otherwise-fine server (see IPC_CALL_DEADLINE_TICKS).
			if (current_proc.ipc_timed_out
				&& call_target.has_message
				&& call_target.msg_from == current_proc.pid
				&& call_target.msg_from_generation == current_proc.generation)
			{
				call_target.has_message = false;
				ipc_inbox_freed(call_target);
			}
			current_proc.in_call_reply_wait = false;
			ipc_inbox_freed(current_proc);
			current_proc.ipc_wait_pid = 0;
			current_proc.ipc_call_deadline = 0;
			current_proc.state = PROC_RUNNABLE;
			f.a0 = (ulong)(-1);
			return;
		}
		current_proc.state = PROC_BLOCKED;
		yield();
	}

	// Phase 3: wait for the reply. in_call_reply_wait keeps our inbox
	// reserved, so whatever lands is call_target's reply. The target has
	// our request now and is committed to replying (or dying) — the
	// timeout still applies so a target stuck in an infinite compute
	// loop (never an ipc_call, so the watchdog is the only other hope)
	// doesn't pin us forever.
	while (!current_proc.has_message)
	{
		if (ipc_peer_gone() || current_proc.ipc_timed_out)
		{
			current_proc.in_call_reply_wait = false;
			ipc_inbox_freed(current_proc);
			current_proc.ipc_wait_pid = 0;
			current_proc.ipc_call_deadline = 0;
			current_proc.state = PROC_RUNNABLE;
			f.a0 = (ulong)(-1);
			return;
		}
		current_proc.state = PROC_BLOCKED;
		yield();
	}

	int call_reply_from = current_proc.msg_from;
	mem::copy(call_buf, current_proc.msg_data, (sz)call_buf_cap);
	if (call_type_out != null) { *call_type_out = current_proc.msg_type; }
	current_proc.has_message = false;
	current_proc.ipc_progress++;
	current_proc.in_call_reply_wait = false;
	ipc_inbox_freed(current_proc);
	current_proc.ipc_wait_pid = 0;
	current_proc.ipc_call_deadline = 0;

	// Ack the replier — it's parked in sys_ipc_reply's phase B.
	Process* call_replier = proc_by_pid(call_reply_from);
	if (call_replier != null)
	{
		call_replier.msg_acked = true;
		if (call_replier.state == PROC_BLOCKED) { call_replier.state = PROC_RUNNABLE; }
	}

	f.a0 = (ulong)call_reply_from;
}

// ipc recv: block until a message lands in this process's inbox, copy it out.
// (was inline in handle_syscall; extracted 2026-08-29.)
fn void sys_ipc_recv(Trap_frame* f) @noinline
{
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
			return;
		}
		current_proc.in_blocking_wait = true;
		blocking_depth++;
		for (;;)
		{
			if (current_proc.has_message)
			{
				int recv_copy_len = recv_len > MSG_MAX ? MSG_MAX : recv_len;
				if (recv_copy_len < 0) recv_copy_len = 0;
				mem::copy(recv_buf, current_proc.msg_data, (sz)recv_copy_len);
				if (recv_type_out != null)
				{
					*recv_type_out = current_proc.msg_type;
				}
				f.a0 = (ulong)current_proc.msg_from;
				current_proc.has_message = false;
				current_proc.ipc_progress++;
				ipc_inbox_freed(current_proc);

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
			if (note_deliverable(current_proc))
			{
				note_interrupted(current_proc);
				f.a0 = (ulong)(-1);
				break;
			}
			current_proc.state = PROC_BLOCKED;
			yield();
		}
		current_proc.in_blocking_wait = false;
		blocking_depth--;
}

// ipc recv (generation-aware): like ipc_recv but also reports the sender's generation.
// (was inline in handle_syscall; extracted 2026-08-29.)
fn void sys_ipc_recv_gen(Trap_frame* f) @noinline
{
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
			return;
		}
		current_proc.in_blocking_wait = true;
		blocking_depth++;
		for (;;)
		{
			if (current_proc.has_message)
			{
				int recv_gen_copy_len = recv_gen_len > MSG_MAX ? MSG_MAX : recv_gen_len;
				if (recv_gen_copy_len < 0) recv_gen_copy_len = 0;
				mem::copy(recv_gen_buf, current_proc.msg_data, (sz)recv_gen_copy_len);
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
				current_proc.ipc_progress++;
				ipc_inbox_freed(current_proc);

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
			if (note_deliverable(current_proc))
			{
				note_interrupted(current_proc);
				f.a0 = (ulong)(-1);
				break;
			}
			current_proc.state = PROC_BLOCKED;
			yield();
		}
		current_proc.in_blocking_wait = false;
		blocking_depth--;
}

// ipc poll: non-blocking inbox check — copy a pending message out or report empty.
// (was inline in handle_syscall; extracted 2026-08-29.)
fn void sys_ipc_poll(Trap_frame* f) @noinline
{
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
		// (on, from user_entry) is safe to leave alone.
		//
		// The interrupt still can't always fire on its own: a
		// concurrent multi-stage shell pipeline keeps several processes
		// parked in SYS_IPC_CALL's cooperative yield loops, so
		// sstatus.SIE stays globally clear and the device completion
		// this poll waits for is never taken as a trap. So this syscall
		// drains the PLIC by hand (service_pending_external_irq) and
		// reports the result through Process.driver_irq_pending — a flag
		// distinct from the IPC inbox, so it can't clobber (or be
		// clobbered by) a real client request. See docs/devlog.md.
		char* poll_buf      = (char*)(uptr)f.a0;
		int poll_len        = (int)f.a1;
		uint* poll_type_out = (uint*)(uptr)f.a2;
		if (poll_type_out != null && !user_range_valid(current_proc.page_table, (uptr)poll_type_out, 4, true))
		{
			f.a0 = (ulong)(-1);
			return;
		}

		// Deliver a pending device IRQ that couldn't be taken as a trap
		// (SIE globally off during a cooperative-blocking storm — see
		// service_pending_external_irq). Reported as a DISKD_IRQ_NOTIFY
		// with no payload and from == 0, exactly like the old
		// trap-routed version; it lives in its own flag so it can never
		// clobber a real client request in the inbox.
		service_pending_external_irq();
		if (current_proc.driver_irq_pending)
		{
			current_proc.driver_irq_pending = false;
			current_proc.ipc_progress++; // a device completion is progress — see Process.ipc_progress
			if (poll_type_out != null) { *poll_type_out = DISKD_IRQ_NOTIFY; }
			f.a0 = 0;
			return;
		}

		if (!current_proc.has_message)
		{
			f.a0 = (ulong)(-1);
			return;
		}
		int poll_copy_len = poll_len > MSG_MAX ? MSG_MAX : poll_len;
		if (poll_copy_len < 0) poll_copy_len = 0;
		if (!user_range_valid(current_proc.page_table, (uptr)poll_buf, (ulong)poll_copy_len, true))
		{
			f.a0 = (ulong)(-1);
			return;
		}
		mem::copy(poll_buf, current_proc.msg_data, (sz)poll_copy_len);
		if (poll_type_out != null)
		{
			*poll_type_out = current_proc.msg_type;
		}
		f.a0 = (ulong)current_proc.msg_from;
		current_proc.has_message = false;
		current_proc.ipc_progress++;
		ipc_inbox_freed(current_proc);

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
}

// Interrupt-driven driver completion-wait, in the kernel (docs/ipc-rings.md
// Phase 1). diskd's old completion-wait was a userspace `for(;;){
// ipc_poll_type(...) }` spin — one SYS_IPC_POLL per pass, tens to hundreds
// of passes per virtio-blk completion, ~330M syscalls over a `go build`.
// This is the same loop moved inside one syscall: the internal yield()s
// aren't syscalls, so the count collapses to one per completion.
//
// Safety is the same argument SYS_IPC_POLL's own comment makes, with one
// addition. This never enables interrupts; it hand-drains the PLIC
// (service_pending_external_irq) every pass, so it makes progress even
// while sstatus.SIE is globally clear for a cooperative-blocking storm —
// the device completion is picked up by the poll, not by a taken trap.
// The one difference from the userspace spin: this process is now parked
// mid-trap across the yield()s (the spin never was). That is safe because
// switch_context's fixed-sscratch reset only corrupts a frame if a NESTED
// TRAP builds one at that address — and nothing here enables the
// interrupts that would cause a nested trap. Every other blocking syscall
// (SYS_IPC_RECV, SYS_JOIN, ...) already yields mid-trap the same way.
//
// Stays PROC_RUNNABLE throughout: this process is the one draining its own
// PLIC source, so it must keep getting scheduled — going PROC_BLOCKED
// would need someone else to drain the PLIC and wake it, which nothing is
// guaranteed to do. Same as the old userspace spin, which was RUNNABLE too.
fn void sys_driver_irq_wait(Trap_frame* f) @noinline
{
	// Only meaningful for a process that owns a routed IRQ. A non-driver
	// caller would spin forever waiting for a notify nothing sets — fail
	// it fast instead.
	if (irq_route_by_pid(current_proc.pid) == null)
	{
		f.a0 = (ulong)(-1);
		return;
	}
	for (;;)
	{
		service_pending_external_irq();
		if (current_proc.driver_irq_pending)
		{
			current_proc.driver_irq_pending = false;
			current_proc.ipc_progress++; // a device completion is progress — see Process.ipc_progress
			f.a0 = 0;
			return;
		}
		yield();
	}
}

// namespace resolve: walk this process's mount table for the longest prefix match, return the server pid (live generation checked).
// (was inline in handle_syscall; extracted 2026-08-29.)
fn void sys_ns_resolve(Trap_frame* f) @noinline
{
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
			return;
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
}

// True if `path` sits under mount prefix `prefix`: a normal
// str_starts_with, plus the case where `prefix` ends in '/' and `path`
// is exactly `prefix` without that slash (so `ls /bin` consults a
// `bind ... /bin/` union, not just `ls /bin/x`). *rem_out gets the
// offset into `path` where the server-relative remainder begins.
fn bool ns_prefix_covers(char* path, char* prefix, int* rem_out) @noinline
{
	int plen = 0;
	while (prefix[plen] != 0) plen++;
	if (str_starts_with(path, prefix))
	{
		*rem_out = plen;
		return true;
	}
	if (plen > 0 && prefix[plen - 1] == '/')
	{
		int i = 0;
		while (i < plen - 1 && path[i] != 0 && path[i] == prefix[i]) i++;
		if (i == plen - 1 && path[i] == 0)
		{
			*rem_out = i; // remainder is ""
			return true;
		}
	}
	return false;
}

// Resolve `path` through `proc`'s namespace and write the
// server-relative path for union member `member` (0 = first/highest
// priority, higher = the `bind -a` extras in bind order; -1 = the
// member that receives creation, i.e. the MNT_CREATE one or member 0 if
// none is flagged) into `out` (capacity `out_max`). Returns the serving
// pid, or -1 if nothing matches / `member` is past the last member at
// the winning prefix / the rewrite doesn't fit. `member` 0 on an
// identity (target == "") mount reproduces the old ns_resolve()+strip
// behaviour exactly.
fn int ns_translate_core(Process* proc, char* path, int member, char* out, int out_max) @noinline
{
	// Pass 1: longest covering prefix length.
	int best_len = -1;
	for (int m = 0; m < NS_MOUNTS_MAX; m++)
	{
		if (proc.namespace[m].server_pid == 0) continue;
		Process* t = proc_by_pid(proc.namespace[m].server_pid);
		if (!t || t.generation != proc.namespace[m].server_generation) continue;
		int rem = 0;
		if (!ns_prefix_covers(path, &proc.namespace[m].prefix[0], &rem)) continue;
		int plen = 0;
		while (proc.namespace[m].prefix[plen] != 0) plen++;
		if (plen > best_len) best_len = plen;
	}
	if (best_len < 0) return -1;

	// member -1: resolve to the create member's own index. Scan the
	// best_len members in order; the MNT_CREATE one wins, else the first.
	if (member < 0)
	{
		int idx = 0;
		int scanned = 0;
		for (int m = 0; m < NS_MOUNTS_MAX; m++)
		{
			if (proc.namespace[m].server_pid == 0) continue;
			Process* ct = proc_by_pid(proc.namespace[m].server_pid);
			if (!ct || ct.generation != proc.namespace[m].server_generation) continue;
			int crem = 0;
			if (!ns_prefix_covers(path, &proc.namespace[m].prefix[0], &crem)) continue;
			int cplen = 0;
			while (proc.namespace[m].prefix[cplen] != 0) cplen++;
			if (cplen != best_len) continue;
			if ((proc.namespace[m].flags & MNT_CREATE) != 0) { idx = scanned; break; }
			scanned++;
		}
		member = idx;
	}

	// Pass 2: the `member`-th live mount whose prefix length == best_len,
	// in array order (= bind order).
	int seen = 0;
	for (int m = 0; m < NS_MOUNTS_MAX; m++)
	{
		if (proc.namespace[m].server_pid == 0) continue;
		Process* t = proc_by_pid(proc.namespace[m].server_pid);
		if (!t || t.generation != proc.namespace[m].server_generation) continue;
		int rem = 0;
		if (!ns_prefix_covers(path, &proc.namespace[m].prefix[0], &rem)) continue;
		int plen = 0;
		while (proc.namespace[m].prefix[plen] != 0) plen++;
		if (plen != best_len) continue;
		if (seen != member) { seen++; continue; }

		char* tgt = &proc.namespace[m].target[0];
		int o = 0;
		for (int k = 0; tgt[k] != 0; k++)
		{
			if (o >= out_max - 1) return -1;
			out[o++] = tgt[k];
		}
		// A rewriting bind's prefix ends in '/' (shell_ns_prefix), so `rem`
		// lands just past that slash — mid-component. Put the separator back
		// between a non-empty target and a non-empty remainder. Identity
		// mounts (target "") keep the path verbatim, slash and all, exactly
		// as the old ns_resolve()+strip did.
		if (o > 0 && out[o - 1] != '/' && path[rem] != 0 && path[rem] != '/')
		{
			if (o >= out_max - 1) return -1;
			out[o++] = '/';
		}
		for (int k = rem; path[k] != 0; k++)
		{
			if (o >= out_max - 1) return -1;
			out[o++] = path[k];
		}
		out[o] = 0;
		return proc.namespace[m].server_pid;
	}
	return -1;
}

// SYS_NS_TRANSLATE: a0 = path, a1 = union member index, a2 = out buf,
// a4 = out cap. Writes the server-relative path for that member into
// the buffer, returns the serving pid (-1 = no match / member past the
// end / doesn't fit). The union-aware successor to SYS_NS_RESOLVE +
// caller-side prefix strip — see user/user.c3's fs_* wrappers.
fn void sys_ns_translate(Trap_frame* f) @noinline
{
	char* nt_path = (char*)(uptr)f.a0;
	int   nt_member = (int)(iptr)f.a1;
	char* nt_out  = (char*)(uptr)f.a2;
	int   nt_max  = (int)(iptr)f.a4;
	if (nt_max < 0) nt_max = 0;
	if (!user_range_valid(current_proc.page_table, (uptr)nt_path, NS_PREFIX_MAX, false)
		|| !user_range_valid(current_proc.page_table, (uptr)nt_out, (ulong)nt_max, true))
	{
		f.a0 = (ulong)(-1);
		return;
	}
	f.a0 = (ulong)(iptr)ns_translate_core(current_proc, nt_path, nt_member, nt_out, nt_max);
}

// join: block until the target pid/generation is gone (exited or slot reused).
// (was inline in handle_syscall; extracted 2026-08-29.)
fn void sys_join(Trap_frame* f) @noinline
{
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
			return;
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
		bool join_intr = false;
		for (;;)
		{
			Process* join_target = proc_by_pid(join_pid);
			if (join_target == null) break;
			if (join_target.generation != join_generation) break;
			if (note_deliverable(current_proc)) { join_intr = true; break; }
			// A shell parked here while its foreground job computes is
			// the common case of nobody reading the console — keep
			// looking for a ^C (rate-limited, src/note.c3).
			console_poll_maybe();
			yield();
		}
		current_proc.in_blocking_wait = false;
		blocking_depth--;
		if (join_intr)
		{
			note_interrupted(current_proc);
			f.a0 = (ulong)(-1);
			return;
		}
		// The joined process's exit code, if one was recorded (0 for a
		// clean exit / no record) — the shell reads this for `&&`/`||`.
		f.a0 = (ulong)(long)proc_take_exit(join_pid, join_generation);
}

// SYS_AWAIT — wait for whichever of several sources is ready first: this
// process's IPC inbox, its stdin (the console, or its stdin pipe when
// redirected), up to AW_MAX_PIPES other pipes, a timeout, a note. Returns
// the mask of everything ready at that moment; never consumes a message,
// a keystroke or pipe bytes — the caller follows up with ipc_recv /
// getchar / pipe_read, which then won't block. Two sources ARE consumed
// when reported, because there is nothing to follow up with: AW_WAKE (a
// SYS_WAKE doorbell) and AW_IRQ (an interrupt-driven driver's device
// completion). A caller that owns an IRQ route also drains the PLIC
// itself on each pass, the same reason SYS_DRIVER_IRQ_WAIT does (see its
// comment). AW_TIMER and AW_NOTE are reported whenever they happen,
// asked for or not (a note also makes the wait return early, like every
// other interruptible wait). A mask of only AW_MSG sleeps (a delivery
// wakes us); anything that has to be polled (stdin, pipes, a timeout)
// spins with yield(), the same as SYS_GETCHAR.
const uint AW_MSG   = 1;
const uint AW_STDIN = 2;
const uint AW_TIMER = 4;
const uint AW_NOTE  = 8;
const uint AW_WAKE  = 16;
const uint AW_IRQ   = 32;
const uint AW_PIPE0 = 256;   // pipe i of the a2 array is bit AW_PIPE0 << i
const int  AW_MAX_PIPES = 8;

fn void sys_await(Trap_frame* f) @noinline
{
	uint aw_mask = (uint)f.a0;
	ulong aw_timeout = f.a1;
	int* aw_upipes = (int*)(uptr)f.a2;
	int aw_np = (int)f.a4;
	if (aw_np < 0 || aw_np > AW_MAX_PIPES
		|| (aw_np > 0 && !user_range_valid(current_proc.page_table, (uptr)aw_upipes, (ulong)aw_np * 4, false)))
	{
		f.a0 = (ulong)(-1);
		return;
	}
	int[AW_MAX_PIPES] aw_pipes;
	for (int i = 0; i < aw_np; i++) { aw_pipes[i] = aw_upipes[i]; }
	ulong aw_deadline = aw_timeout != 0 ? time_now() + aw_timeout : 0;
	bool aw_driver = irq_route_by_pid(current_proc.pid) != null;
	// Sources only a poll can see (console, pipes) keep us RUNNABLE and
	// yield-spinning; everything else — inbox, doorbell, note, timeout, a
	// driver's IRQ — wakes a PROC_BLOCKED sleeper: the timeout through
	// sleep_until (entry.c3), the IRQ through service_pending_external_irq
	// (taken as a trap, or drained by hand in yield()).
	bool aw_poll = (aw_mask & AW_STDIN) != 0 || aw_np > 0;

	current_proc.in_blocking_wait = true;
	blocking_depth++;
	for (;;)
	{
		uint ready = 0;
		if (aw_driver) { service_pending_external_irq(); }
		if ((aw_mask & AW_MSG) && current_proc.has_message) { ready |= AW_MSG; }
		if ((aw_mask & AW_IRQ) && current_proc.driver_irq_pending) { ready |= AW_IRQ; }
		if ((aw_mask & AW_WAKE) && current_proc.wake_pending) { ready |= AW_WAKE; }
		if (aw_mask & AW_STDIN)
		{
			if (current_proc.stdin_pipe >= 0)
			{
				if (pipe_ready(current_proc.stdin_pipe)) { ready |= AW_STDIN; }
			}
			else
			{
				console_poll();
				if (kbd_queue_nonempty()) { ready |= AW_STDIN; }
			}
		}
		for (int i = 0; i < aw_np; i++)
		{
			if (pipe_ready(aw_pipes[i])) { ready |= AW_PIPE0 << i; }
		}
		if (aw_deadline != 0 && time_now() >= aw_deadline) { ready |= AW_TIMER; }
		if (note_deliverable(current_proc)) { ready |= AW_NOTE; }
		if (ready != 0)
		{
			if (ready & AW_WAKE) { current_proc.wake_pending = false; }
			if (ready & AW_IRQ)
			{
				current_proc.driver_irq_pending = false;
				current_proc.ipc_progress++; // a device completion is progress — see Process.ipc_progress
			}
			current_proc.state = PROC_RUNNABLE;
			current_proc.sleep_deadline = 0;
			f.a0 = (ulong)ready;
			break;
		}
		if (!aw_poll)
		{
			if (aw_deadline != 0) { sleep_until(aw_deadline); }
			current_proc.state = PROC_BLOCKED;
		}
		yield();
	}
	current_proc.in_blocking_wait = false;
	blocking_depth--;
}

// futex wait: block while the user word still holds the expected value.
// (was inline in handle_syscall; extracted 2026-08-29.)
fn void sys_futex_wait(Trap_frame* f) @noinline
{
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
			return;
		}
		if (*futex_addr != futex_expected)
		{
			f.a0 = 0;
			return;
		}
		current_proc.futex_addr = (uptr)futex_addr;
		current_proc.futex_paddr = user_vaddr_to_paddr(current_proc.page_table, (uptr)futex_addr);
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
			if (note_deliverable(current_proc))
			{
				current_proc.futex_addr = 0;
				note_interrupted(current_proc);
				current_proc.in_blocking_wait = false;
				blocking_depth--;
				f.a0 = (ulong)(-1);
				return;
			}
		}
		current_proc.in_blocking_wait = false;
		blocking_depth--;
		f.a0 = 0;
}

// proc info: report another process's state / generation / uid.
// (was inline in handle_syscall; extracted 2026-08-29.)
fn void sys_proc_info(Trap_frame* f) @noinline
{
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
			return;
		}
		uint* state_out = (uint*)(uptr)f.a1;
		uint* generation_out = (uint*)(uptr)f.a2;
		int* uid_out = (int*)(uptr)f.a4;
		if ((state_out != null && !user_range_valid(current_proc.page_table, (uptr)state_out, 4, true))
			|| (generation_out != null && !user_range_valid(current_proc.page_table, (uptr)generation_out, 4, true))
			|| (uid_out != null && !user_range_valid(current_proc.page_table, (uptr)uid_out, 4, true)))
		{
			f.a0 = (ulong)(-1);
			return;
		}
		if (state_out != null) *state_out = (uint)queried.state;
		if (generation_out != null) *generation_out = queried.generation;
		if (uid_out != null) *uid_out = queried.uid;
		f.a0 = 0;
}

// srv post: bind current_proc under a short name in the global srv_table (Plan 9 post half of post+mount).
// (was inline in handle_syscall; extracted 2026-08-29.)
fn void sys_srv_post(Trap_frame* f) @noinline
{
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
			return;
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
}

// ns mount+wait: like ns_mount but retries for a bounded window if the named server hasn't posted yet.
// (was inline in handle_syscall; extracted 2026-08-29.)
fn void sys_ns_mount_wait(Trap_frame* f) @noinline
{
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
			return;
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
}

// One byte of a process's stdout: into its pipe (blocking while the pipe
// is full), or the console — with boot servers silenced into the kernel
// log once the shell has settled. SYS_PUTCHAR and SYS_WRITE both go
// through here. Returns false if a pipe wait was cut short by a note.
fn bool stdout_put(int c) @noinline
{
	if (current_proc.stdout_pipe >= 0)
	{
		// Redirected (a `|` or `>`): into the pipe, blocking while it's
		// full — interruptible by a note.
		while (!pipe_try_put(current_proc.stdout_pipe, (char)(c & 0xFF)))
		{
			if (note_deliverable(current_proc)) { note_interrupted(current_proc); return false; }
			yield();
		}
	}
	// Boot servers go silent once the shell has settled (it calls
	// SYS_BOOT_QUIET) — their init chatter otherwise keeps landing on the
	// console after the prompt is up. The shell and everything it exec()s
	// (is_boot_server == false) print normally.
	else if (g_boot_quiet && current_proc.is_boot_server)
	{
		// Silenced, not discarded: a respawned server's bring-up (or its
		// dying panic() line) stays readable with `dmesg` without the
		// serial-speed delay `loud` would add — that delay was enough to
		// hide a timing bug (docs/devlog.md).
		sbi::klog_put(c);
	}
	else if (current_proc.is_boot_server)
	{
		// Boot-server chatter (fsd/sdd/usbd/ethd init lines) is worth
		// keeping in the kernel log — tee it.
		board::console_putchar(c);
	}
	else
	{
		// A plain process's stdout is terminal output, not kernel log, so
		// it takes the raw path: without that split, `dmesg` (which prints
		// what it reads) re-feeds its own output into the ring and loops
		// forever.
		sbi::console_emit(c);
	}
	return true;
}

fn void handle_syscall(Trap_frame* f) @noinline
{
	g_prof_syscall_hist[f.a3 & 63]++; // DIAGNOSTIC — see g_prof_syscall_hist, SYS_PROF_HIST
	// "Was my last wait interrupted?" only ever describes the syscall
	// right before SYS_INTERRUPTED — see Process.note_intr.
	if (f.a3 != SYS_INTERRUPTED) { current_proc.note_intr = false; }
	switch (f.a3)
	{
		case SYS_POSTNOTE:
			sys_postnote(f);
		case SYS_NOTIFY:
			current_proc.note_handler = (uptr)f.a0;
			f.a0 = 0;
		case SYS_NOTED:
			if (note_noted(f, (int)f.a0)) { current_proc.note_resumed = true; }
		case SYS_AWAIT:
			sys_await(f);
		case SYS_WAKE:
		{
			// The doorbell: a non-blocking "look at our shared ring" from
			// one process to another (user/net/link.c3). Sticky until the
			// target's await_any reports AW_WAKE.
			Process* wt = proc_by_pid((int)f.a0);
			if (wt == null || wt == idle_proc
				|| ((uint)f.a1 != 0 && wt.generation != (uint)f.a1)
				|| (current_proc.uid != 0 && current_proc.uid != wt.uid))
			{
				f.a0 = (ulong)(-1);
				break;
			}
			wt.wake_pending = true;
			if (wt.state == PROC_BLOCKED) { wt.state = PROC_RUNNABLE; }
			f.a0 = 0;
		}
		case SYS_SEGATTACH:
			sys_segattach(f);
		case SYS_SEGDETACH:
			sys_segdetach(f);
		case SYS_INTERRUPTED:
			f.a0 = current_proc.note_intr ? 1 : 0;
			current_proc.note_intr = false;
		case SYS_PUTCHAR:
			stdout_put((int)f.a0);
		case SYS_WRITE:
		{
			// a0 = buf, a1 = len: stdout_put each byte — the whole buffer in
			// one trap instead of one SYS_PUTCHAR per byte. Returns bytes
			// written (fewer if a note interrupted a full pipe).
			char* wbuf = (char*)(uptr)f.a0;
			long wlen = (long)f.a1;
			if (wlen < 0 || !user_range_valid(current_proc.page_table, (uptr)wbuf, (ulong)wlen, false))
			{
				f.a0 = (ulong)(-1);
				break;
			}
			long wi = 0;
			for (; wi < wlen; wi++)
			{
				if (!stdout_put((int)(uint)wbuf[wi])) { break; }
			}
			f.a0 = (ulong)wi;
		}
		case SYS_BOOT_QUIET:
			// The shell calls this once, after a short settle delay, to
			// stop boot-server console output landing on the console
			// after the prompt is up. a0 == 1 turns it back ON — a
			// diagnostic escape hatch (the dev shell's `loud` builtin)
			// for watching a *respawned* boot server's own init chatter,
			// which is otherwise silenced exactly like the original's.
			g_boot_quiet = f.a0 != 1;
			f.a0 = 0;
		case SYS_GETCHAR:
			current_proc.in_blocking_wait = true;
			blocking_depth++;
			if (current_proc.stdin_pipe >= 0)
			{
				// Redirected (a `|` or `<`): from the pipe. -1 on EOF
				// (all writers gone and nothing buffered).
				for (;;)
				{
					char pc;
					int pr = pipe_try_get(current_proc.stdin_pipe, &pc);
					if (pr == 0) { f.a0 = (ulong)(uint)pc; break; }
					if (pr == 2) { f.a0 = (ulong)(-1); break; }
					if (note_deliverable(current_proc)) { note_interrupted(current_proc); f.a0 = (ulong)(-1); break; }
					yield();
				}
			}
			else
			{
				for (;;)
				{
					// The serial console drains into the same keystroke
					// queue usbd's USB keyboard feeds (src/kbd.c3, via
					// SYS_KBD_PUSH) — a caller can't tell which a byte came
					// from, and both stay live at once. console_poll turns a
					// ^C into a note on the way (src/note.c3).
					console_poll();
					int ch = kbd_queue_pop();
					if (ch >= 0)
					{
						f.a0 = (ulong)ch;
						break;
					}
					if (note_deliverable(current_proc)) { note_interrupted(current_proc); f.a0 = (ulong)(-1); break; }
					yield();
				}
			}
			current_proc.in_blocking_wait = false;
			blocking_depth--;
		case SYS_GETCHAR_NB:
			// One non-blocking poll of the same two sources SYS_GETCHAR
			// drains (USB keyboard queue, then serial console) — never
			// yields, never blocks, returns -1 the instant both are
			// empty. Console only: a redirected stdin (pipe) gets -1, so
			// a caller uses it strictly as "did the user press a key?"
			// and never as a data path.
			if (current_proc.stdin_pipe >= 0)
			{
				f.a0 = (ulong)(-1);
			}
			else
			{
				console_poll();
				f.a0 = (ulong)kbd_queue_pop();
			}
		case SYS_EXIT:
			sys_exit(f);
		case SYS_IPC_SEND:
			sys_ipc_send(f);
		case SYS_IPC_CALL:
			ulong prof_ipc_t0 = read_reg("time");
			sys_ipc_call(f);
			g_prof_ipc_calls++;
			g_prof_ipc_ticks += read_reg("time") - prof_ipc_t0;
		case SYS_IPC_REPLY:
			sys_ipc_reply(f);
		case SYS_IPC_RECV:
			sys_ipc_recv(f);
		case SYS_IPC_RECV_GEN:
			sys_ipc_recv_gen(f);
		case SYS_IPC_POLL:
			sys_ipc_poll(f);
		case SYS_DRIVER_IRQ_WAIT:
			sys_driver_irq_wait(f);
		case SYS_NS_RESOLVE:
			sys_ns_resolve(f);
		case SYS_NS_TRANSLATE:
			sys_ns_translate(f);
		case SYS_PROF:
			ulong* prof_out = (ulong*)(uptr)f.a0;
			if (!user_range_valid(current_proc.page_table, (uptr)prof_out, 32, true))
			{
				f.a0 = (ulong)(-1);
				break;
			}
			prof_out[0] = g_prof_ipc_calls;
			prof_out[1] = g_prof_ipc_ticks;
			prof_out[2] = g_prof_yields;
			prof_out[3] = g_prof_switches;
			if (f.a1 != 0)
			{
				g_prof_ipc_calls = 0;
				g_prof_ipc_ticks = 0;
				g_prof_yields = 0;
				g_prof_switches = 0;
			}
			f.a0 = 0;
		case SYS_PROF_HIST:
			ulong* hist_out = (ulong*)(uptr)f.a0;
			if (!user_range_valid(current_proc.page_table, (uptr)hist_out, 512, true))
			{
				f.a0 = (ulong)(-1);
				break;
			}
			for (int hi = 0; hi < 64; hi++)
			{
				hist_out[hi] = g_prof_syscall_hist[hi];
				if (f.a1 != 0) g_prof_syscall_hist[hi] = 0;
			}
			f.a0 = 0;
		case SYS_KLOG_READ:
			{
				char*  klog_out = (char*)(uptr)f.a0;
				int    klog_max = (int)f.a1;
				ulong* klog_cur = (ulong*)(uptr)f.a2;
				if (klog_max < 0) { klog_max = 0; }
				if (!user_range_valid(current_proc.page_table, (uptr)klog_out, (uint)klog_max, true)
					|| !user_range_valid(current_proc.page_table, (uptr)klog_cur, 8, true))
				{
					f.a0 = (ulong)(-1);
					break;
				}
				ulong cur = *klog_cur;
				int got = sbi::klog_copy(klog_out, klog_max, &cur);
				*klog_cur = cur;
				f.a0 = (ulong)got;
			}
		case SYS_PROC_STAT:
			{
				int   ps_slot = (int)f.a0;
				char* ps_out = (char*)(uptr)f.a1;
				if (!user_range_valid(current_proc.page_table, (uptr)ps_out, 52, true))
				{
					f.a0 = (ulong)(-1);
					break;
				}
				if (ps_slot < 1 || ps_slot > PROCS_MAX) { f.a0 = (ulong)(-1); break; }
				Process* ps_p = &procs[ps_slot - 1];
				if (ps_p.state == PROC_UNUSED || ps_p.state == PROC_RESERVED) { f.a0 = (ulong)(-1); break; }
				uint* ps_u = (uint*)ps_out;
				ps_u[0] = (uint)ps_p.state;
				ps_u[1] = (uint)ps_p.uid;
				ps_u[2] = ps_p.generation;
				// resident pages: eagerly-mapped image span + demand-mapped
				// heap below map_floor. Rough — the exact leaf count would
				// need a page-table walk; heap_top - USER_BASE is the
				// process's own high-water mark, close enough for `top`.
				ps_u[3] = ps_p.heap_top > (uptr)USER_BASE
					? (uint)((ps_p.heap_top - (uptr)USER_BASE) / PAGE_SIZE) : 0;
				ps_u[4] = (uint)ps_p.pid; // real pid (0 for idle), not the slot index
				for (int k = 0; k < 32; k++) { ps_out[20 + k] = ps_p.name[k]; }
				f.a0 = 0;
			}
		case SYS_DEV_INFO:
			// Hands the caller the physical base of each DMA region its
			// board device declared (device.c3's Dev_dma list, allocated by
			// device_setup at spawn) — the only way a driver can learn
			// them: it can't call alloc_pages() and its own image pages
			// have no guaranteed physical contiguity. Replaces the
			// per-driver SYS_DISKD/USBD/NETD/ETHD/SDD_INFO syscalls.
			// a0 = out array of uptr, a1 = its capacity (<= DEV_DMA_MAX).
			// Writes min(capacity, regions) entries in declaration order and
			// returns how many regions the device HAS (so a caller can check
			// it got the count it needs), or -1 for a caller that owns no
			// device / a bad buffer.
			uptr* dev_out = (uptr*)(uptr)f.a0;
			ulong dev_cap = f.a1;
			int   dev_idx = current_proc.device;
			if (dev_idx < 0 || dev_cap > (ulong)DEV_DMA_MAX
				|| !user_range_valid(current_proc.page_table, (uptr)dev_out, dev_cap * 8, true))
			{
				f.a0 = (ulong)(-1);
				break;
			}
			int dev_nregions = device_dma_count(dev_idx);
			for (int dr = 0; dr < dev_nregions && (ulong)dr < dev_cap; dr++)
			{
				dev_out[dr] = dev_dma_paddr[dev_idx * DEV_DMA_MAX + dr];
			}
			f.a0 = (ulong)dev_nregions;
		case SYS_DISK_ARENA_INFO:
			// diskd + the primary fsd only — the two processes
			// device_setup / setup_fsd_mappings identity-mapped
			// the arena into (docs/ipc-rings.md P1 step 2). a0 -> paddr
			// (uptr), a1 -> size (u32), same out-pointer convention as
			// SYS_DEV_INFO above.
			uptr* da_paddr_out = (uptr*)(uptr)f.a0;
			uint* da_size_out  = (uint*)(uptr)f.a1;
			if (disk_arena_paddr == 0
				|| (current_proc.pid != disk_arena_diskd_pid && current_proc.pid != disk_arena_fsd_pid)
				|| !user_range_valid(current_proc.page_table, (uptr)da_paddr_out, 8, true)
				|| !user_range_valid(current_proc.page_table, (uptr)da_size_out, 4, true))
			{
				f.a0 = (ulong)(-1);
				break;
			}
			*da_paddr_out = disk_arena_paddr;
			*da_size_out  = disk_arena_size;
			f.a0 = 0;
		case SYS_FS_PARTITION_INFO:
			// fsd-only, called once at its own startup — a0 is an
			// out-pointer, same convention as SYS_DEV_INFO above.
			// Reads the CALLER's own current_proc.fs_partition_start
			// (set by process.c3's setup_fsd_mappings() at spawn time),
			// not board::FS_PARTITION_START_SECTOR directly — see that
			// field's own comment for why: two fsd instances can be
			// mounted simultaneously now, so a single shared board
			// constant can't answer this the same way for both.
			uint* fs_partition_out = (uint*)(uptr)f.a0;
			bool* fs_is_secondary_out = (bool*)(uptr)f.a1;
			int*  fs_storage_pid_out = (int*)(uptr)f.a2;
			if (!user_range_valid(current_proc.page_table, (uptr)fs_partition_out, 4, true)
				|| (fs_is_secondary_out != null && !user_range_valid(current_proc.page_table, (uptr)fs_is_secondary_out, 1, true))
				|| (fs_storage_pid_out != null && !user_range_valid(current_proc.page_table, (uptr)fs_storage_pid_out, 4, true)))
			{
				f.a0 = (ulong)(-1);
				break;
			}
			*fs_partition_out = current_proc.fs_partition_start;
			// a1/a2 are optional out-pointers (same "null means the
			// caller doesn't care" convention SYS_NS_RESOLVE/SYS_RFORK
			// use). a1 -> is_secondary_fs (see its comment, process.c3).
			// a2 -> storage_pid: which pid runs the block-storage driver
			// (diskd/sdd), so fsd doesn't hardcode it. 0 = no block
			// device on this board.
			if (fs_is_secondary_out != null)
			{
				*fs_is_secondary_out = current_proc.is_secondary_fs;
			}
			if (fs_storage_pid_out != null)
			{
				*fs_storage_pid_out = storage_pid;
			}
			f.a0 = 0;
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
		case SYS_NS_LIST:
			// Copies the caller's own namespace out — one NS_LIST_REC_SIZE
			// (100) byte record per live mount: [0..31] null-padded prefix,
			// [32..35] server pid LE, [36] flags (MNT_CREATE), [37..99]
			// null-padded rewrite target. Same per-process scope as
			// SYS_NS_RESOLVE; the generation check drops dead servers.
			// Returns the record count. Union members share a prefix and
			// list as separate records, in search order.
			const int NS_LIST_REC_SIZE = 100;
			char* nl_buf = (char*)(uptr)f.a0;
			int nl_max = (int)(iptr)f.a1;
			if (nl_max < 0) nl_max = 0;
			if (nl_max > NS_MOUNTS_MAX) nl_max = NS_MOUNTS_MAX;
			if (!user_range_valid(current_proc.page_table, (uptr)nl_buf, (ulong)(nl_max * NS_LIST_REC_SIZE), true))
			{
				f.a0 = (ulong)(-1);
				break;
			}
			int nl_count = 0;
			for (int m = 0; m < NS_MOUNTS_MAX && nl_count < nl_max; m++)
			{
				if (current_proc.namespace[m].server_pid == 0) continue;
				Process* nl_t = proc_by_pid(current_proc.namespace[m].server_pid);
				if (!nl_t || nl_t.generation != current_proc.namespace[m].server_generation) continue;
				char* nl_dst = &nl_buf[nl_count * NS_LIST_REC_SIZE];
				for (int z = 0; z < NS_LIST_REC_SIZE; z++) nl_dst[z] = 0;
				char* nl_src = &current_proc.namespace[m].prefix[0];
				int nl_k = 0;
				while (nl_k < 31 && nl_src[nl_k] != 0) { nl_dst[nl_k] = nl_src[nl_k]; nl_k++; }
				int nl_pid = current_proc.namespace[m].server_pid;
				nl_dst[32] = (char)(nl_pid & 0xff);
				nl_dst[33] = (char)((nl_pid >> 8) & 0xff);
				nl_dst[34] = (char)((nl_pid >> 16) & 0xff);
				nl_dst[35] = (char)((nl_pid >> 24) & 0xff);
				nl_dst[36] = (char)(current_proc.namespace[m].flags & 0xff);
				char* nl_tgt = &current_proc.namespace[m].target[0];
				int nl_j = 0;
				while (nl_j < 62 && nl_tgt[nl_j] != 0) { nl_dst[37 + nl_j] = nl_tgt[nl_j]; nl_j++; }
				nl_count++;
			}
			f.a0 = (ulong)(iptr)nl_count;
		case SYS_NS_BIND:
			// Plan 9's `bind`: resolve a1 (a path) through the caller's
			// own namespace, longest-prefix-first exactly like
			// SYS_NS_RESOLVE, then add/replace a mount at a0 (a new
			// prefix) pointing at that same server. The difference from
			// SYS_NS_MOUNT is only where the target comes from — an
			// existing path here, a posted srv_table name there; the
			// insert half (idempotent by exact prefix, needs a free slot)
			// is identical.
			char* nb_prefix = (char*)(uptr)f.a0;
			char* nb_src    = (char*)(uptr)f.a1;
			uint  nb_flags  = (uint)f.a2; // bit0 = -a (union add), bit2 = -c (create here); 0 = replace
			if (!user_range_valid(current_proc.page_table, (uptr)nb_prefix, NS_PREFIX_MAX, false)
				|| !user_range_valid(current_proc.page_table, (uptr)nb_src, NS_PREFIX_MAX, false))
			{
				f.a0 = (ulong)(-1);
				break;
			}
			// Resolve the source through the caller's own namespace —
			// ns_translate_core hands back both the serving pid and the
			// rewritten (target-composed) path, so `bind`s compose: binding
			// onto an already-bound prefix carries its target forward.
			char[NS_TARGET_MAX] nb_target @noinit;
			int nb_pid = ns_translate_core(current_proc, nb_src, 0, &nb_target[0], NS_TARGET_MAX);
			if (nb_pid <= 0) { f.a0 = (ulong)(-1); break; }
			uint nb_gen = 0;
			{
				Process* nb_tp = proc_by_pid(nb_pid);
				if (!nb_tp) { f.a0 = (ulong)(-1); break; }
				nb_gen = nb_tp.generation;
			}

			bool nb_add    = (nb_flags & 1) != 0;   // -a: a new union member, keep the existing ones
			bool nb_create = (nb_flags & 4) != 0;   // -c: this member takes creates

			// Plain `bind` (no -a) replaces the whole union at `prefix`;
			// `bind -a` keeps it and appends. `bind -c` marks the new member
			// the create target and clears that flag on any sibling kept.
			if (!nb_add)
			{
				for (int m = 0; m < NS_MOUNTS_MAX; m++)
				{
					if (current_proc.namespace[m].server_pid == 0) continue;
					if (str_eq(&current_proc.namespace[m].prefix[0], nb_prefix))
					{
						current_proc.namespace[m].server_pid = 0;
					}
				}
			}
			else if (nb_create)
			{
				for (int m = 0; m < NS_MOUNTS_MAX; m++)
				{
					if (current_proc.namespace[m].server_pid == 0) continue;
					if (str_eq(&current_proc.namespace[m].prefix[0], nb_prefix))
					{
						current_proc.namespace[m].flags &= ~MNT_CREATE;
					}
				}
			}

			// A fresh slot. First-free scan runs low->high and successive
			// binds climb, so a union's array order == bind order == search
			// order.
			int nb_free = -1;
			for (int m = 0; m < NS_MOUNTS_MAX; m++)
			{
				if (current_proc.namespace[m].server_pid == 0) { nb_free = m; break; }
			}
			if (nb_free == -1) { f.a0 = (ulong)(-1); break; }
			str_copy(&current_proc.namespace[nb_free].prefix[0], nb_prefix, NS_PREFIX_MAX);
			current_proc.namespace[nb_free].server_pid = nb_pid;
			current_proc.namespace[nb_free].server_generation = nb_gen;
			str_copy(&current_proc.namespace[nb_free].target[0], &nb_target[0], NS_TARGET_MAX);
			current_proc.namespace[nb_free].flags = nb_create ? MNT_CREATE : 0;
			f.a0 = 0;
		case SYS_MAP:
			// a0 = byte count. Reserve that many bytes (rounded up to
			// whole pages) of RW+U address space at current_proc.heap_top,
			// bump it, return the base vaddr — or -1 on a bad size or the
			// per-process ceiling. LAZY: no physical page is allocated
			// here. A page fault in [map_floor, heap_top) demand-maps one
			// zero page (try_lazy_fault, handle_trap's exception branch);
			// running out of RAM there kills just the faulting process.
			// No unmap: proc_destroy / sys_exit walk every PAGE_U leaf and
			// free it, so whatever a SYS_MAP'd region actually touched is
			// reclaimed on exit for free. rfork copies only real leaves,
			// so forking a process with a big-but-untouched map is cheap.
			ulong map_bytes = f.a0;
			if (map_bytes == 0 || map_bytes > HEAP_MAX_BYTES)
			{
				f.a0 = (ulong)(-1);
				break;
			}
			uint map_pages_n = (uint)((map_bytes + PAGE_SIZE - 1) / PAGE_SIZE);
			uptr map_base = current_proc.heap_top;
			if (map_base == 0
				|| map_base + (uptr)map_pages_n * PAGE_SIZE - (uptr)USER_BASE > HEAP_MAX_BYTES)
			{
				f.a0 = (ulong)(-1);
				break;
			}
			current_proc.heap_top = map_base + (uptr)map_pages_n * PAGE_SIZE;
			f.a0 = (ulong)map_base;
		case SYS_JOIN:
			sys_join(f);
		case SYS_FUTEX_WAIT:
			sys_futex_wait(f);
		case SYS_FUTEX_WAKE:
			// Wakes every process blocked on the same *physical* word.
			// Same page table + same vaddr is the same physical word (RFMEM
			// threads); two unrelated processes' private pages never are,
			// so equal user addresses can't be confused; and two processes
			// sharing a segment page (segment.c3) meet on it — which is what
			// makes a Mutex inside a shared segment work across processes.
			// (It used to compare page_table pointers, which left a waiter
			// in another process sleeping forever.)
			uptr wake_addr = (uptr)f.a0;
			if (!user_range_valid(current_proc.page_table, wake_addr, 4, false))
			{
				f.a0 = (ulong)(-1);
				break;
			}
			uptr wake_paddr = user_vaddr_to_paddr(current_proc.page_table, wake_addr);
			for (int wake_i = 0; wake_i < PROCS_MAX; wake_i++)
			{
				Process* waiter = &procs[wake_i];
				if (waiter.state != PROC_BLOCKED) continue;
				if (waiter.futex_addr == 0 || waiter.futex_paddr != wake_paddr) continue;
				waiter.futex_addr = 0;
				waiter.state = PROC_RUNNABLE;
			}
			f.a0 = 0;
		case SYS_PROC_INFO:
			sys_proc_info(f);
		case SYS_KILL:
			// PROBE (2026-08-28): extracted to sys_kill() to test whether
			// c3c 0.8.3 fixed the "call a moderately-complex function from
			// handle_syscall's switch reboot-loops from the first syscall"
			// landmine that hit 3x on 0.8.2 (see SYS_EXIT + docs/devlog.md
			// 2026-08-14). Boots clean on QEMU + Duo => rest of the split
			// is safe; reboot loop => revert, landmine still live.
			sys_kill(f);
		case SYS_SRV_POST:
			sys_srv_post(f);
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
			sys_ns_mount_wait(f);
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
		case SYS_KBD_PUSH:
			// usbd-only in practice (user/usb/kbd.c3's kbd_emit): one
			// decoded keyboard byte in a0, appended to the kernel
			// keystroke queue SYS_GETCHAR drains (src/kbd.c3). Returns 0,
			// or -1 if the queue was full (byte dropped). Not pid-gated,
			// same as every other "*_INFO" syscall here — a byte in the
			// input stream is low-stakes, and usbd is the only thing that
			// ever calls this.
			if ((f.a0 & 0xFF) == 3)
			{
				console_input_byte(3); // ^C on a USB keyboard: the console's interrupt note
				f.a0 = 0;
			}
			else if (kbd_queue_push((char)(f.a0 & 0xFF)))
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
			// registered in the Irq_route table (device_setup,
			// device.c3). A non-driver caller finds no route -> no-op.
			// Idempotent (first transfer / timeout path harmlessly
			// re-sets an already-set enable bit).
			Irq_route* arm_route = irq_route_by_pid(current_proc.pid);
			if (arm_route != null)
			{
				plic_set_enabled(arm_route.irq, true);
			}
			f.a0 = 0;
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
		case SYS_GETUID:
			// The caller's own uid. Always succeeds — uid is a small
			// non-negative int, so no error value collides. Lets a
			// process (the shell's prompt, /bin/whoami) know who it is
			// without a getpid()+proc_info(self) round trip.
			f.a0 = (ulong)(uint)current_proc.uid;
		case SYS_STDIN_ISATTY:
			// 1 if the caller's stdin is the console, 0 if it's a pipe.
			// A poor-man's isatty(0): the stdin-reading filters
			// (/bin/head, /bin/cat) use it to print usage instead of
			// silently blocking on the console when run bare with no
			// pipe wired and no file argument. There's no console EOF
			// (no tty layer), so a bare `head` on the console would
			// otherwise wait for the user to hand-type `limit` lines.
			f.a0 = current_proc.stdin_pipe < 0 ? 1 : 0;
		case SYS_TIMEBASE:
			// The `time` CSR's tick rate (board::TIMEBASE_HZ). Lets a
			// caller turn an rdtime() delta into seconds without
			// hardcoding a board-specific constant — the killtests use
			// it so their respawn deadlines are the same wall-clock
			// budget on QEMU (10 MHz) and the Duo (25 MHz).
			f.a0 = board::TIMEBASE_HZ;
		case SYS_GETPID:
			// The caller's own pid. Always succeeds. A c3 program
			// learns its children's pids from rfork() but has no way
			// to ask for its own — the C libc's getpid() needs it.
			f.a0 = (ulong)(uint)current_proc.pid;
		case SYS_EXEC_MAX:
			// board::EXEC_MAX_IMAGE_SIZE — the largest image SYS_EXEC
			// will install on this board. The shell reads this to size
			// its own exec() receive buffer (1 MiB on the Duo, 4 MiB on
			// QEMU/JH7110 for the Go port) rather than baking in a
			// constant that would be wrong somewhere. Always succeeds.
			f.a0 = (ulong)EXEC_MAX_IMAGE_SIZE;
		case SYS_CHDIR:
			// a0 = the new cwd, already made absolute + normalised by
			// the caller (user.c3's cd path logic). The kernel just
			// stores it — it doesn't stat the target (a cd into a
			// non-existent dir just makes later relative paths fail,
			// same as any shell). Truncated to fit.
			char* chdir_path = (char*)(uptr)f.a0;
			if (!user_range_valid(current_proc.page_table, (uptr)chdir_path, 1, false))
			{
				f.a0 = (ulong)(-1);
				break;
			}
			int cdw = 0;
			while (cdw < 99 && chdir_path[cdw] != 0)
			{
				current_proc.cwd[cdw] = chdir_path[cdw];
				cdw++;
			}
			current_proc.cwd[cdw] = 0;
			f.a0 = 0;
		case SYS_GETCWD:
			char* getcwd_buf = (char*)(uptr)f.a0;
			int getcwd_cap = (int)f.a1;
			if (getcwd_cap < 1 || !user_range_valid(current_proc.page_table, (uptr)getcwd_buf, (ulong)getcwd_cap, true))
			{
				f.a0 = (ulong)(-1);
				break;
			}
			int gcw = 0;
			while (gcw < getcwd_cap - 1 && current_proc.cwd[gcw] != 0)
			{
				getcwd_buf[gcw] = current_proc.cwd[gcw];
				gcw++;
			}
			getcwd_buf[gcw] = 0;
			f.a0 = (ulong)gcw;
		case SYS_PIPE:
			f.a0 = (ulong)(long)pipe_alloc();
		case SYS_PIPE_SETOUT:
		case SYS_PIPE_SETIN:
		{
			// a0 = target pid (self or a direct child), a1 = pipe id
			// (-1 detaches). The shell calls this right after rfork,
			// before the child runs, so there's no race on the child's
			// first SYS_PUTCHAR.
			int spid = (int)f.a0;
			int spipe = (int)f.a1;
			Process* starget = proc_by_pid(spid);
			if (starget == null
				|| (spid != current_proc.pid && starget.parent_pid != current_proc.pid)
				|| (spipe >= 0 && !pipe_valid(spipe)))
			{
				f.a0 = (ulong)(-1);
				break;
			}
			bool as_writer = f.a3 == SYS_PIPE_SETOUT;
			int old = as_writer ? starget.stdout_pipe : starget.stdin_pipe;
			if (old >= 0) { pipe_detach(old, as_writer); }
			if (as_writer) { starget.stdout_pipe = spipe; } else { starget.stdin_pipe = spipe; }
			if (spipe >= 0)
			{
				if (as_writer) { pipes[spipe].writers++; } else { pipes[spipe].readers++; }
			}
			f.a0 = 0;
		}
		case SYS_PIPE_READ:
		{
			int rid = (int)f.a0;
			char* rbuf = (char*)(uptr)f.a1;
			int rmax = (int)f.a2;
			if (rmax < 0) { rmax = 0; }
			if (!pipe_valid(rid) || !user_range_valid(current_proc.page_table, (uptr)rbuf, (ulong)rmax, true))
			{
				f.a0 = (ulong)(-1);
				break;
			}
			// The shell reads a pipe end here to pump `>` to a file:
			// grab whatever's buffered, block only if nothing's there
			// yet and writers remain, stop at EOF.
			int rn = 0;
			for (;;)
			{
				char rc;
				int rr = pipe_try_get(rid, &rc);
				if (rr == 0) { rbuf[rn] = rc; rn++; if (rn >= rmax) { break; } continue; }
				if (rr == 2) { break; }        // EOF
				if (rn > 0) { break; }         // return what we have
				if (note_deliverable(current_proc)) { note_interrupted(current_proc); rn = -1; break; }
				yield();
			}
			f.a0 = (ulong)rn;
		}
		case SYS_PIPE_HOLD:
		{
			// The shell holds a pipe end it pumps itself: reader for
			// `cmd > file` (so the child's writes aren't dropped as
			// reader-less), writer for `cmd < file` (so the child
			// doesn't see EOF before the shell has fed the bytes in).
			// It releases the end (delta -1) once the pump is done.
			int hid = (int)f.a0;
			if (!pipe_valid(hid)) { f.a0 = (ulong)(-1); break; }
			bool h_writer = f.a1 != 0;
			if ((long)f.a2 >= 0)
			{
				if (h_writer) { pipes[hid].writers++; } else { pipes[hid].readers++; }
			}
			else
			{
				pipe_detach(hid, h_writer);
			}
			f.a0 = 0;
		}
		case SYS_PIPE_WRITE:
		{
			int wid = (int)f.a0;
			char* wbuf = (char*)(uptr)f.a1;
			int wlen = (int)f.a2;
			if (wlen < 0) { wlen = 0; }
			if (!pipe_valid(wid) || !user_range_valid(current_proc.page_table, (uptr)wbuf, (ulong)wlen, false))
			{
				f.a0 = (ulong)(-1);
				break;
			}
			int wn = 0;
			while (wn < wlen)
			{
				if (pipe_try_put(wid, wbuf[wn])) { wn++; continue; }
				if (note_deliverable(current_proc)) { note_interrupted(current_proc); break; }
				yield();
			}
			f.a0 = wn == 0 && current_proc.note_intr ? (ulong)(-1) : (ulong)wn;
		}
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
