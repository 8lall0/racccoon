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
// Supervised: the pure-IPC servers (fsd, fsd2, echod, procd, envd) plus
// the block-storage driver (diskd on QEMU / sdd on the Duo) — the one
// device driver everything else depends on. Its MMIO + DMA mappings are
// re-established on respawn via Service.kind (setup_diskd_mappings /
// setup_sdd_mappings) and its PLIC route self-heals (irq_route_register
// overwrites in place). fsd re-resolves the storage pid on an IPC
// failure (user/fs/fsd.c3's diskd_rw), so a respawn into a new slot is
// transparent to it. usbd/ethd/netd/gpiod are still unsupervised — the
// kind switch has slots for them, but each needs its bring-up verified
// idempotent and a way to fault-test it (mostly Duo-only).
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

// Post-create setup each service needs, dispatched in supervisor_spawn().
const int SVC_KIND_PLAIN = 0;  // echod / procd / envd — nothing
const int SVC_KIND_FSD   = 1;  // setup_fsd_mappings(proc, partition, secondary)
const int SVC_KIND_DISKD = 2;  // setup_diskd_mappings(proc) — QEMU virtio-blk
const int SVC_KIND_SDD   = 3;  // setup_sdd_mappings(proc)   — Duo SD
const int SVC_KIND_USBD  = 4;  // not registered yet
const int SVC_KIND_ETHD  = 5;  // not registered yet
const int SVC_KIND_NETD  = 6;  // not registered yet
const int SVC_KIND_GPIOD = 7;  // not registered yet

struct Service
{
	char* name;
	char* bin_start;
	char* bin_end;

	int   kind;            // SVC_KIND_* — which setup_*_mappings to run on respawn
	uint  fsd_partition;   // SVC_KIND_FSD only
	bool  fsd_secondary;   // SVC_KIND_FSD only

	// The kernel global the default-namespace seeding reads for this
	// server (fsd_pid / fsd2_pid / echod_pid / procd_pid / envd_pid /
	// storage_pid), or null.
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
	int kind, uint fsd_partition, bool fsd_secondary,
	int* pid_global, Process* proc)
{
	if (service_count >= SVC_MAX || proc == null) { return; }
	Service* s = &services[service_count];
	service_count++;
	s.name           = name;
	s.bin_start      = bin_start;
	s.bin_end        = bin_end;
	s.kind           = kind;
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

	p.is_boot_server = true;
	switch (s.kind)
	{
		case SVC_KIND_FSD:   setup_fsd_mappings(p, s.fsd_partition, s.fsd_secondary);
		case SVC_KIND_DISKD: setup_diskd_mappings(p);
		case SVC_KIND_SDD:   setup_sdd_mappings(p);
		case SVC_KIND_USBD:  setup_usbd_mappings(p);
		case SVC_KIND_ETHD:  setup_ethd_mappings(p);
		case SVC_KIND_NETD:  setup_netd_mappings(p);
		case SVC_KIND_GPIOD: setup_gpiod_mappings(p);
		default: break;
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
