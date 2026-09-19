module kernel;

import board;
import panic;

// supervisor_tick() runs inside the timer trap handler, where std::io's
// formatter isn't usable (it faulted with "No method 'write_byte'" —
// the default output target isn't wired up in that context). Write
// straight to the console instead, the same primitive panic uses.
fn void svc_puts(char* s) @noinline
{
	while (*s != 0)
	{
		board::console_putchar((int)*s);
		s++;
	}
}

// Boot-server supervision (docs/roadmap.md §5.2). kernel_main starts every
// boot server through service_boot() below, which spawns it AND registers
// it here; supervisor_tick() runs once per timer tick (~1/s, from
// handle_trap's SCAUSE_SUPERVISOR_TIMER case) and re-spawns any that have
// exited. First boot and respawn share one code path (service_instantiate),
// so a restarted server is set up exactly like the original.
//
// Supervised: the pure-IPC servers (fsd, fsd2, echod, procd, envd), the
// block-storage driver (diskd on QEMU / sdd on the Duo), and the other
// hardware drivers (usbd, ethd, netd, gpiod). A driver's hardware — MMIO
// windows, PLIC route, DMA regions — comes from its board Device entry
// (device.c3) and is re-established on every respawn by device_setup(); its
// PLIC route self-heals (irq_route_register overwrites in place). fsd
// re-resolves the storage pid on an IPC failure (user/fs/fsd.c3's
// diskd_rw), so a respawn into a new slot is transparent to it.
//
// A respawned server lands in whatever slot is free, so its pid usually
// changes. supervisor_spawn() therefore (a) updates the *_pid global the
// default-namespace seeding in create_process() reads, so *new* processes
// get the right pid, and (b) walks every live process's namespace and
// re-points any mount that named the dead instance — so processes that
// already booted transparently pick up the replacement on their next
// ns_resolve(). An fid held open across the crash is still dead; a client
// that gets -1 from a p9 op is expected to re-attach (see the roadmap).

const int SVC_MAX = 10;
const int SVC_RESTART_LIMIT = 5;

// Watchdog (docs/roadmap.md §5.6): a supervised server with an
// unconsumed inbox message (has_message stuck true) for this many
// consecutive ticks is wedged — a healthy server clears has_message the
// instant it calls ipc_recv, before it even starts processing. ~1
// tick/s, so this is generous; the point is catching an infinite loop /
// deadlock, not a slow request.
const int SVC_STALL_LIMIT = 5;

struct Service
{
	char* name;
	char* bin_start;
	char* bin_end;

	int   device;          // index into board::DEVICES (device.c3) to hand this
	                       // server on every (re)spawn, or -1: it owns no hardware
	bool  is_fsd;          // an fsd instance: also run setup_fsd_mappings
	uint  fsd_partition;   // is_fsd only
	bool  fsd_secondary;   // is_fsd only

	// Hang watchdog applies? Off for usbd/ethd/gpiod: their bring-up
	// (a USB bus reset + 1s settle, an Ethernet PHY train, …) can
	// legitimately not touch their IPC poll for seconds, which would
	// false-trip the has_message stall check. They still get
	// respawn-on-exit — a driver that panic()s comes back.
	bool  watch_hangs;

	// The kernel global the default-namespace seeding reads for this
	// server (fsd_pid / fsd2_pid / echod_pid / procd_pid / envd_pid /
	// storage_pid), or null.
	int*  pid_global;

	int   pid;
	uint  generation;
	int   restarts;
	bool  given_up;
	bool  used;

	// Watchdog state. ever_ready gates it: a server that hasn't yet
	// reached its ipc_recv loop even once (slow init, e.g. sdd on the
	// Duo) is "still starting," not "wedged." stall_ticks counts
	// consecutive ticks with a stuck inbox once it is ready AND no IPC
	// progress since the last tick — last_progress is the previous
	// tick's Process.ipc_progress, so a server flying through thousands
	// of requests between ticks never trips even if the sample catches
	// one unconsumed (dirpacktest / any burst-heavy fs workload hit
	// this — see docs/devlog.md).
	bool  ever_ready;
	int   stall_ticks;
	uint  last_progress;
}

Service[SVC_MAX] services;
int service_count;

// Start `name`'s embedded binary (`bin_start`/`bin_end`) as a boot server
// and put it under supervision. Called from kernel_main for every boot
// server; the returned Process is the freshly spawned instance.
//   pid_global   the kernel global the default-namespace seeding reads for
//                this server (fsd_pid / echod_pid / storage_pid / …), or null
//   device       board::DEVICES index this server drives (device_find), -1 none
//   is_fsd       an fsd instance, with its partition / secondary flag
//   watch_hangs  hang watchdog applies (see the field's comment above)
fn Process* service_boot(char* name, char* bin_start, char* bin_end,
	int* pid_global = null, int device = -1, bool watch_hangs = true,
	bool is_fsd = false, uint fsd_partition = 0, bool fsd_secondary = false)
{
	if (service_count >= SVC_MAX) { panic::panic("service table full"); }
	Service* s = &services[service_count];
	s.name           = name;
	s.bin_start      = bin_start;
	s.bin_end        = bin_end;
	s.device         = device;
	s.is_fsd         = is_fsd;
	s.fsd_partition  = fsd_partition;
	s.fsd_secondary  = fsd_secondary;
	s.watch_hangs    = watch_hangs;
	s.pid_global     = pid_global;
	s.restarts       = 0;
	s.given_up       = false;

	Process* p = service_instantiate(s);

	// Published last: supervisor_tick() skips an entry until it is `used`,
	// and must never see one whose pid/generation aren't set yet (a timer
	// tick can land anywhere in kernel_main) — it would read as "dead" and
	// respawn a duplicate.
	s.used = true;
	service_count++;
	return p;
}

// Re-point every namespace mount that named (old_pid) at (new_pid,
// new_generation) — see this file's header comment.
fn void reseat_namespace_mounts(int old_pid, int new_pid, uint new_generation)
{
	if (old_pid == 0) { return; }
	for (int i = 0; i < PROCS_MAX; i++)
	{
		// PROC_RESERVED (SMP Stage B): a slot create_process is still
		// initialising — its namespace is the previous occupant's and is
		// about to be overwritten wholesale, so nothing to reseat.
		if (procs[i].state == PROC_UNUSED || procs[i].state == PROC_RESERVED) { continue; }
		for (int m = 0; m < NS_MOUNTS_MAX; m++)
		{
			if (procs[i].namespace[m].server_pid == old_pid)
			{
				procs[i].namespace[m].server_pid = new_pid;
				procs[i].namespace[m].server_generation = new_generation;
			}
		}
	}
}

// Create one instance of `s` and wire it up: name, hardware, fsd
// parameters, and the bookkeeping the supervisor and the default-namespace
// seeding read. Shared by first boot (service_boot) and respawn.
fn Process* service_instantiate(Service* s)
{
	// Null the global first so the new instance's own create_process()
	// namespace seeding treats this server as "not up yet" (server_pid
	// 0 — SYS_NS_RESOLVE skips it), exactly like first boot, rather than
	// inheriting a stale pid.
	if (s.pid_global != null) { *s.pid_global = 0; }

	// create_process() panics on a full table rather than returning
	// null — same contract every other call site (kernel_main's own
	// spawns, the shell respawn) already relies on.
	uint img_size = (uint)((uptr)s.bin_end - (uptr)s.bin_start);
	Process* p = create_process((void*)s.bin_start, img_size);

	p.is_boot_server = true;
	proc_set_name(p, s.name);
	if (s.device >= 0) { device_setup(p, s.device); }
	if (s.is_fsd) { setup_fsd_mappings(p, s.fsd_partition, s.fsd_secondary); }

	s.pid        = p.pid;
	s.generation = p.generation;
	s.ever_ready  = false;
	s.stall_ticks = 0;
	s.last_progress = p.ipc_progress;
	if (s.pid_global != null) { *s.pid_global = p.pid; }
	return p;
}

fn void supervisor_spawn(Service* s)
{
	int old_pid = s.pid;
	Process* p = service_instantiate(s);
	s.restarts++;

	reseat_namespace_mounts(old_pid, p.pid, p.generation);

	svc_puts("svc: respawned ");
	svc_puts(s.name);
	svc_puts("\n");
}

// One maintenance pass — cheap (SVC_MAX * O(1)) when nothing has died.
// Returns true if it tore down whatever process was running when the
// timer fired (a wedged server that happened to be `current_proc`) — the
// caller must then yield() unconditionally, since sret'ing back into a
// PROC_UNUSED context with a freed page table would fault.
fn bool supervisor_tick()
{
	bool killed_current = false;
	for (int i = 0; i < service_count; i++)
	{
		Service* s = &services[i];
		if (!s.used || s.given_up) { continue; }

		Process* live = proc_by_pid(s.pid);

		if (live != null && live.generation == s.generation)
		{
			// Alive. Hang watchdog (skipped for drivers whose bring-up
			// legitimately blocks their IPC poll for seconds): a server
			// sitting in its ipc_recv loop has has_message == false; the
			// instant it picks a message up (before processing) it clears
			// the flag again. So a stuck flag across SVC_STALL_LIMIT
			// ticks means it got a request and never returned to recv.
			if (!s.watch_hangs) { continue; }
			if (!live.has_message)
			{
				s.ever_ready  = true;
				s.stall_ticks = 0;
				s.last_progress = live.ipc_progress;
				continue;
			}
			if (!s.ever_ready) { continue; }   // still starting — not wedged
			// has_message is set, but did the server consume anything
			// since the last tick? If so it's busy, not wedged.
			if (live.ipc_progress != s.last_progress)
			{
				s.last_progress = live.ipc_progress;
				s.stall_ticks = 0;
				continue;
			}
			s.stall_ticks++;
			if (s.stall_ticks < SVC_STALL_LIMIT) { continue; }

			svc_puts("svc: ");
			svc_puts(s.name);
			svc_puts(" wedged (unconsumed IPC) — killing\n");
			if (live == current_proc) { killed_current = true; }
			proc_destroy(live, -1);
			s.stall_ticks = 0;
			// Respawn on the *next* tick, via the dead-detection below —
			// not now: create_process would reuse this same slot, and if
			// this was current_proc, the caller's yield() would then save
			// the timer-trap context into the fresh process, corrupting
			// it. One tick of extra downtime for an already-wedged server
			// is fine.
			continue;
		}

		if (s.restarts >= SVC_RESTART_LIMIT)
		{
			s.given_up = true;
			svc_puts("svc: ");
			svc_puts(s.name);
			svc_puts(" hit the restart limit, leaving it down\n");
			continue;
		}
		supervisor_spawn(s);
	}
	return killed_current;
}
