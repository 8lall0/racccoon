# Zero-copy / batched IPC rings

Status: **design** (2026-09-03). No code yet. This is lever #5 from
[the go-build profile](../CLAUDE.md) — the "proper" fix for the IPC
round-trip cost, as opposed to the cache band-aids already tried.

## Why

`gobuildtest` (a one-file `go build`, QEMU TCG, `-m 2G`, prepopulated
`/gocache`) profiles as:

```
wall        ~1340 s  (~22 min)
ipc_calls   ~1.5 M      round trips through SYS_IPC_CALL
switches    ~5.0 M      context switches (every yield switched)
syscalls    ~348 M      one-off counter — ~330 M is diskd's poll spin
fsd cache   ~38 % hit   (4-way 8 MiB, was 32 % at 512 KiB direct-mapped)
```

Verdict from the profile work: **IPC-bound, decisively.** Not compute,
not read latency. A bigger fsd cache moved the hit rate but *not* wall
time — the toolchain binaries (`go` 13.6M, `compile` 23M, `link` 5.9M,
`asm` 4.6M) are re-exec'd and re-read whole every build, and the cost is
the round-trip machinery itself: the 3-phase cooperative rendezvous in
`sys_ipc_call`, 5 M context switches, and two `mem::copy` of up to
`MSG_MAX` (8 KiB) per call through the kernel bounce buffer.

Two structural costs to attack:

1. **The handshake.** Every `p9_call` is `SYS_IPC_CALL`: phase 1 spins
   `yield()` until the target's inbox is free and deposits the request;
   phase 2 spins `yield()` until the target acks; phase 3 spins
   `yield()` until the reply lands. Each spin iteration is a full
   `switch_context`. One logical read = 4–6+ switches.

2. **The diskd poll storm.** `user/block/diskd.c3` cannot block waiting
   for the virtio-blk completion IRQ (the `sscratch` nested-trap frame
   constraint — see `SYS_IPC_POLL`'s comment in `src/entry.c3`). It
   busy-polls `SYS_IPC_POLL`, hand-draining the PLIC, tens to hundreds
   of times per completion. Every fsd cache miss → one `SYS_IPC_CALL` to
   diskd → one poll spin. 3.3 M misses ≈ 330 M syscalls.

## What exists today (the substrate)

- **`SYS_IPC_CALL` / `SYS_IPC_RECV_GEN` / `SYS_IPC_REPLY`** — the
  9P-lite RPC. Kernel bounce buffer `Process.msg_data`, `MSG_MAX` 8 KiB.
  Four hand-synced copies of that constant (`MSG_MAX`, `FS_MSG_MAX`,
  `RC_FS_MSG_MAX`, `fsMsgMax`).
- **`SYS_MAP` (47)** — per-process anonymous zero-filled RW pages just
  past the image, demand-paged. *Not* shareable between processes.
- **`setup_diskd_mappings` / `setup_usbd_mappings` / `setup_netd_...`**
  — the kernel allocates one physically-contiguous run with
  `alloc_pages(n)`, identity-maps it (`vaddr == paddr`) into the
  driver's page table, and hands the base back via a driver-only
  `SYS_*_INFO` syscall. This is the closest thing to shared memory the
  system has, but each region has exactly one user-mode consumer and is
  shaped for device DMA, not for a second process.
- **`irq_route_register(irq, pid, level)`** — routes a device IRQ to a
  driver process; `handle_trap` posts a synthetic `DISKD_IRQ_NOTIFY`.
- **diskd ↔ virtio-blk** is already a ring (a virtqueue): descriptors,
  avail/used index, `QUEUE_NOTIFY` doorbell. diskd just doesn't *expose*
  a ring upward to fsd — it wraps each virtq round in a blocking
  `SYS_IPC_CALL` reply.

## Architecture

### Two tiers, on purpose

Keep `SYS_IPC_CALL` (9P-lite) for the **control plane**: `open`,
`stat`, `walk`, `mkdir`, `rename`, `delete`, `chattr`, `mount`, `bind`,
`clunk`, permission checks, the `namespace` list. Low frequency, small
messages, and the single-message-at-a-time discipline is what makes it
debuggable. No ring there.

Add a ring **data-plane** fast-path for exactly the two hot verbs:
`FS_READ_AT` and `FS_WRITE_AT` bulk payload. That is where the round
trips and the 8 KiB copies live.

### The kernel primitive

Three new syscalls (numbers 55–57, provisional):

- **`SYS_RING_ATTACH(peer_pid, ring_bytes, out_local_vaddr)`** — the
  client asks the kernel to establish a shared region between itself and
  `peer_pid`. The kernel `alloc_pages`es one physically-contiguous run,
  maps it RW into *both* page tables (each side gets its own vaddr, both
  returned to their respective sides — the region is self-relative, no
  absolute pointers inside it), and records the pairing in a small
  kernel table (`Ring` slot: client pid+gen, server pid+gen, paddr,
  npages, per-side vaddr, a doorbell word). Returns a ring id.
  The server learns of a new attachment either by polling a
  `SYS_RING_ACCEPT` or — simpler — the client passes the ring id over
  the existing control-plane channel in the `open` reply.

- **`SYS_RING_KICK(ring_id, flags)`** — memory-fence, mark the peer's
  doorbell, wake the peer if it is parked in `SYS_RING_WAIT`. With
  `RING_KICK_WAIT` set, then block this side until *its own* CQ has an
  entry (or the peer dies). Same `PROC_BLOCKED` + `yield()` loop as
  `sys_ipc_call` phase 3 — which is already proven safe; the unsafe
  thing is enabling interrupts mid-trap, which this does not do.

- **`SYS_RING_WAIT(ring_id, timeout)`** — park until the doorbell is
  marked or the peer dies. For a *driver* (diskd) this variant also
  calls `service_pending_external_irq()` before parking and on each
  wake, exactly like `SYS_IPC_POLL` does — so a completion IRQ that
  can't be taken as a trap during an SIE-off cooperative-blocking storm
  is still drained. The win vs. today is not "diskd now blocks" — it's
  that diskd does this **once per batch** instead of once per sector.

Teardown: when either peer exits, `cleanup_process` walks the `Ring`
table, unmaps the region from the survivor, frees the pages, and marks
the slot dead so the survivor's next `SYS_RING_KICK`/`WAIT` returns -1
(re-handshake, same shape as `ipc_peer_gone`).

### Ring region layout

```
offset  size            contents
0       64              header: sq_head, sq_tail, cq_head, cq_tail,
                        arena_bytes, entry_count, flags, doorbell
                        (each index on its own cache line to avoid
                        false sharing once SMP lands)
64      N * 64          SQ: N submission descriptors, 64 B each
...     N * 32          CQ: N completion records, 32 B each
...     arena_bytes     data arena — bulk read/write payload lives
                        here, referenced by (arena_off, len) in the
                        descriptor. This is the zero-copy part: no
                        MSG_MAX bounce.
```

Submission descriptor (64 B): `opcode` (READ_AT / WRITE_AT), `cookie`
(client-chosen, echoed in the completion), `fid` / resolved sector
base, `file_offset`, `length`, `arena_off`, reserved.

Completion record (32 B): `cookie`, `result` (bytes or -errno),
`flags`, reserved.

Producer writes entries then advances its tail with a release fence;
consumer reads up to tail, processes, advances head. Classic
single-producer/single-consumer ring — no lock, correct on a single
hart today and on SMP later with the fences already in place.

### Validation (the server's burden)

Every SQ entry crosses a trust boundary. diskd / fsd must, for each
descriptor: bound-check `arena_off + length <= arena_bytes`, clamp
`length`, reject opcodes it doesn't serve, and never follow a pointer
out of the region (there are none by construction — all offsets). A
malformed ring can waste the server's time but must not fault it or
touch another process. This is strictly more defensive code than the
single-message path needs.

## Phased plan

### Phase 0 — this doc + a bench (host)

- `docs/ipc-rings.md` (this file).
- A microbench builtin `ringbench` (like `synhist`): time N=100k
  round trips of a 4 KiB read via `SYS_IPC_CALL` vs. via a ring, print
  ns/op and switches/op. Establishes the real per-op delta before
  committing to the big refactor.

### Phase 1 — fsd ↔ diskd ring  ← start here

The hottest, simplest edge: two C3 processes, no language bindings, and
it kills the poll storm.

- `SYS_RING_ATTACH` / `KICK` / `WAIT` + the `Ring` kernel table +
  teardown in `cleanup_process`.
- diskd: on startup, accept fsd's attach. Main loop becomes: drain SQ,
  push *multiple* virtio-blk descriptors (queue depth > 1 — the
  virtqueue already supports it, diskd artificially serialises today),
  one `QUEUE_NOTIFY`, `SYS_RING_WAIT` once, drain the used ring, write
  all CQ entries, one `SYS_RING_KICK` back. Keep `DISKD_READ` /
  `DISKD_WRITE` / `DISKD_READ_MULTI` `SYS_IPC_CALL` verbs as a
  fallback for any non-fsd caller and for the first-boot handshake.
- fsd: `diskd_rw` / `fs_read_sectors` / `fs_write_sector` submit to the
  ring instead of `p9_call(g_diskd_pid, ...)`. The fsd sector cache
  sits *in front* of the ring unchanged — a ring op only happens on a
  miss, exactly as `p9_call` does now.
- Expected: the ~330 M `SYS_IPC_POLL` storm collapses to roughly one
  wait per batch; fsd↔diskd switches drop from 4–6/sector to ~2/batch.
  This does **not** by itself fix the toolchain re-read volume — that's
  lever #1 (exec image residency) — but it removes the biggest syscall
  contributor and is the necessary substrate for Phase 2.

### Phase 2 — client ↔ fsd ring (FS_READ_AT / FS_WRITE_AT)

- The `open` control-plane reply carries a ring id; the client
  `SYS_RING_ATTACH`es to fsd. One ring per open file, or one per
  client↔fsd connection with the fid in the descriptor (start with
  per-connection — fewer kernel `Ring` slots).
- Migrate the three fs clients' read/write bulk paths: `user/user.c3`
  `fs_read_at` / `fs_write_at`, libc `rc_fs.c` `__rc_fs_read*` /
  `__rc_fs_write*`, Go `racccoon_fs.go` `readAt` / `writeAt`. Control
  verbs stay on `SYS_IPC_CALL`.
- Batching: a Go `io.Copy` or a libc buffered read can submit several
  descriptors and kick once. The `go build` exec-image reads become one
  kick + one drain instead of (image_size / 8 KiB) round trips.

### Phase 3 — Go channel wrapper

- Wrap the client ring in a `chan`-shaped API in `go/goos/`: submit =
  channel send, completion = channel receive, `SYS_RING_WAIT` maps onto
  `beforeIdle` / `goos.Idle` so a goroutine blocked on a ring op parks
  and the Go scheduler runs another. This is the "goes well with
  goroutine concurrency" payoff the user asked about.

### Phase 4 — true concurrency (SMP-scheduler-gated)

- With a real SMP scheduler, fsd/diskd run on their own hart and drain
  the SQ while the client fills it — the round trip becomes zero context
  switches, pure producer/consumer. This is where the full win lands
  and it is blocked on the SMP scheduler (currently scaffold-only,
  `board::SMP_MAX_HARTS` = 1 on Duo). Do not build for this until the
  scheduler exists; just don't design it out (hence the cache-line
  separation and the release/acquire fences from Phase 1).

## Costs / risks

- **Crash recovery.** A server respawn (supervisor) invalidates every
  ring. Clients must detect the dead slot and fall back to the
  `SYS_IPC_CALL` control path to re-`open` and re-attach. More states to
  get right than the stateless-ish 9P-lite path.
- **Debuggability.** No more "one message = one traceable event". Need a
  `ringdump` diagnostic (indices + last N descriptors/completions).
- **Memory.** Each ring pins a physically-contiguous region. At, say,
  64 KiB/ring and one ring per client↔fsd connection, `PROCS_MAX` = 16
  is ~1 MiB worst case — fine, but it's non-swappable and
  `alloc_pages(n)` contiguity gets harder as uptime grows.
- **The `sscratch` constraint still stands.** Phase 1 does not fix it;
  it makes diskd's unavoidable poll rare instead of per-sector. A real
  fix (per-process SIE save/restore + a non-fixed `sscratch` on
  mid-trap resume) is a separate, deeper piece of work and would let
  `SYS_RING_WAIT` be a true sleep for drivers too.
- **Validation surface.** Every server reading an SQ is now parsing
  attacker-influenced memory on its hot path.

## Non-goals

- Replacing 9P-lite wholesale. The control plane stays.
- A generic io_uring. This is two fixed opcodes on two fixed edges.
- Anything that needs the SMP scheduler, until it exists.
