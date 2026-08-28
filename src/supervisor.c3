module kernel;

import board;

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

// Boot-server supervision (docs/roadmap.md §5.2). kernel_main registers
// each supervisable server here right after spawning it; supervisor_tick()
// runs once per timer tick (~1/s, from handle_trap's SCAUSE_SUPERVISOR_TIMER
// case) and re-spawns any that have exited.
//
// Only the pure-IPC / trivial-setup servers are supervised: fsd, fsd2,
// procd, envd. The device drivers (diskd/sdd/usbd/ethd/netd/gpiod) are
// NOT here — they'd need their MMIO/DMA mappings re-established and some
// carry hardcoded-pid conventions (user/fs/fsd.c3's DISKD_PID = 3) that
// a respawn into a different slot would break. echod is deliberately
// left unsupervised too (it's the IPC test server; user/shell.c3's
// "ping" hardcodes its pid 2).
//
// A respawned server lands in whatever slot is free, so its pid usually
// changes. supervisor_spawn() therefore (a) updates the *_pid global the
// default-namespace seeding in create_process() reads, so *new* processes
// get the right pid, and (b) walks every live process's namespace and
// re-points any mount that named the dead instance — so processes that
// already booted transparently pick up the replacement on their next
// ns_resolve(). An fid held open across the crash is still dead; a client
// that gets -1 from a p9 op is expected to re-attach (see the roadmap).

const int SVC_MAX = 6;
const int SVC_RESTART_LIMIT = 5;

struct Service
{
	char* name;
	char* bin_start;
	char* bin_end;

	// fsd needs setup_fsd_mappings(proc, partition, secondary) after
	// create_process; procd/envd need nothing.
	bool  needs_fsd_setup;
	uint  fsd_partition;
	bool  fsd_secondary;

	// The kernel global the default-namespace seeding reads for this
	// server (fsd_pid / fsd2_pid / procd_pid / envd_pid), or null.
	int*  pid_global;

	int   pid;
	uint  generation;
	int   restarts;
	bool  given_up;
	bool  used;
}

Service[SVC_MAX] services;
int service_count;

// Called from kernel_main right after a supervisable server is spawned.
fn void supervisor_register(char* name, char* bin_start, char* bin_end,
	bool needs_fsd_setup, uint fsd_partition, bool fsd_secondary,
	int* pid_global, Process* proc)
{
	if (service_count >= SVC_MAX || proc == null) { return; }
	Service* s = &services[service_count];
	service_count++;
	s.name           = name;
	s.bin_start      = bin_start;
	s.bin_end        = bin_end;
	s.needs_fsd_setup = needs_fsd_setup;
	s.fsd_partition  = fsd_partition;
	s.fsd_secondary  = fsd_secondary;
	s.pid_global     = pid_global;
	s.pid            = proc.pid;
	s.generation     = proc.generation;
	s.restarts       = 0;
	s.given_up       = false;
	s.used           = true;
}

// Re-point every namespace mount that named (old_pid) at (new_pid,
// new_generation) — see this file's header comment.
fn void reseat_namespace_mounts(int old_pid, int new_pid, uint new_generation)
{
	if (old_pid == 0) { return; }
	for (int i = 0; i < PROCS_MAX; i++)
	{
		if (procs[i].state == PROC_UNUSED) { continue; }
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

fn void supervisor_spawn(Service* s)
{
	int old_pid = s.pid;

	// Null the global first so the replacement's own create_process()
	// namespace seeding treats this server as "not up yet" (server_pid
	// 0 — SYS_NS_RESOLVE skips it), exactly like first boot, rather than
	// inheriting a stale pid.
	if (s.pid_global != null) { *s.pid_global = 0; }

	// create_process() panics on a full table rather than returning
	// null — same contract every other call site (kernel_main's own
	// spawns, the shell respawn) already relies on.
	uint img_size = (uint)((uptr)s.bin_end - (uptr)s.bin_start);
	Process* p = create_process((void*)s.bin_start, img_size);

	if (s.needs_fsd_setup)
	{
		setup_fsd_mappings(p, s.fsd_partition, s.fsd_secondary);
	}

	s.pid        = p.pid;
	s.generation = p.generation;
	s.restarts++;
	if (s.pid_global != null) { *s.pid_global = p.pid; }

	reseat_namespace_mounts(old_pid, p.pid, p.generation);

	svc_puts("svc: respawned ");
	svc_puts(s.name);
	svc_puts("\n");
}

// One maintenance pass — cheap (SVC_MAX * O(1)) when nothing has died.
fn void supervisor_tick()
{
	for (int i = 0; i < service_count; i++)
	{
		Service* s = &services[i];
		if (!s.used || s.given_up) { continue; }

		Process* live = proc_by_pid(s.pid);
		if (live != null && live.generation == s.generation) { continue; }

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
}
