# Racccoon roadmap

Status: **direction agreed, no code yet.** Written 2026-08-29.

The bring-up phase is largely done — scheduler, IPC, namespaces, three
filesystems, USB, SD, ethernet, a Duo port. The next phase is making
racccoon feel like a system you *use* rather than one you bring up. Four
workstreams, in dependency order:

1. Plan 9 file structure
2. Plan 9 user model
3. Hardware FPU (unblocks float; small)
4. WASM as a `/bin` program

3 is independent and can land any time. 4 needs 3 for float. 1 → 2 →
(shell work) is the spine.

---

## 1. Plan 9 file structure

### Where we are

`/bin`, `/tmp`, `/proc`, `/srv`, `/env`, `/mnt/`, plus `lost+found` from
ext2. The Plan 9 topology is already the model: ext2 is the root, FAT32
is the boot partition, other mounts live under `/mnt/`. Per-process
mount tables (`create_process` seeds a default namespace).

The QEMU root image is rebuilt from a fixed fixture set on every
`scripts/build.sh`; the Duo root is a real 57 GB ext2 partition.

### What "done" looks like

A canonical tree, seeded identically on QEMU and Duo:

```
/            ext2 root
/bin         binaries (already there)
/lib         shared data / wasm modules / anything exec-adjacent
/env         per-process environment (already a server)
/srv         posted server connections (already a server)
/proc        process control (already a server)
/mnt         mount points for everything else
/adm         host administration — /adm/users (the user db, see §2)
/usr/$user   per-user home (Plan 9 uses /usr, not /home)
/tmp         scratch (already there)
```

No `/dev` — devices are servers (`usbd`, `sdd`, …), reached by name or
through a mount, not device nodes. No `/etc` — Plan 9 keeps host config
in `/adm` and per-user config under `/usr/$user/lib`.

### Work

- **Tree defined + seeded. DONE** (`3b044ab`) — `docs/filesystem-layout.md`
  is the reference; `scripts/build.sh` seeds it into the QEMU ext2
  images, `scripts/populate_duo_bin.sh` onto the real Duo.
  `/adm/users` starts as `0:root`.
- **Hardcoded server pids removed. DONE** (`f025db5`) — `echod` (was
  pid 2, baked into `namespace[0]`) and `fsd`'s block driver (was
  `DISKD_PID=3`) now come from `echod_pid` / a `SYS_FS_PARTITION_INFO`
  out-param. Unblocks supervising those + is general hygiene.
- Still to do: a `namespace(1)`-style view (shell prints the current
  process's mount table — a new `/proc` file), and `bind`/`mount`/
  `unmount` as shell builtins (`SYS_NS_MOUNT`/`_UNMOUNT` exist; `bind`
  may need a new verb). Deferred until §2 shapes the requirements.

### Not doing

Union mounts (`bind -a`/`-b`), the full `/dev` you'd get from `#c` etc.
— later, if ever.

---

## 2. Plan 9 user model

### Where we are

More than you'd expect:

- `Process.uid` — `int`, 0 = root, inherited across `rfork`.
- `SYS_SETUID` — sets the **caller's own** uid, and **only while still
  0**. A privilege drop is permanent. This is already Plan 9's "you can
  become `none`, you can never become the hostowner."
- `fsd` enforces per-file ownership on ext2: `fsd_requester_uid(from)`
  asks the kernel for the sender's uid, `ext2_write_allowed(inode, uid)`
  checks `i_uid` + the `S_IWUSR`/`S_IWOTH` mode bits on every
  write/create/delete/mkdir.
- `SYS_KILL` — root, or exact same uid as the target.

### What's missing

- **Identity establishment.** Every process is born root and can only
  drop. There's no `login` that sets uid *from* a database, no
  usernames (just numbers), no way to know "who is this."
- **A user database.** Plan 9's is a flat file, conventionally
  `/adm/users`: `uid:username:leadername:members`. Minimal version:
  `uid:name` lines.
- **The hostowner concept.** The process that owns the machine (uid of
  whoever `login`s at the console first, or a fixed `glenda`-equivalent).
  Some operations are hostowner-only rather than root-only.
- **`none`** — the standard sandbox identity (a high uid with no files
  and no privileges). `sandboxtest` already proves a namespace can be
  stripped; `none` is the identity half.
- **Read permission enforcement** — only write/delete is gated today.
- **FAT32/exFAT ownership** — those backends have no `i_uid` at all;
  needs a policy (everything owned by the mounter? hostowner? a mount
  option?).
- `chmod`/`chown` — no verbs yet.

### Work

1. **`/adm/users` + parser. DONE** (`d1de99d`) — `user_uid_by_name` /
   `user_name_by_uid` in `user.c3`; `uid:name` lines; uid 0 always
   resolves to `root`.
2. **Become a named user. DONE** (`d1de99d`) — `SYS_GETUID`, `su <user>`
   shell builtin (one-way, like `setuid`), `/bin/whoami`, and the
   prompt shows the user (`root#` / `glenda%`). *Not* a boot-time
   `login`/`getty` yet — the console still comes up as a root shell;
   folding `login` into shell startup (or a real `/bin/login`) is a
   follow-up, and needs a cwd/`$HOME` concept (deferred with the shell
   work).
3. **Read enforcement. DONE** (`05aa0bf`) — `ext2_read_allowed` /
   `ext2_may_read`; `fsd`'s read/list/stat/`P9_OPEN` paths pass the
   requester uid. ext2 only (FAT32/exFAT have no ownership); root
   bypasses. `65534:none` is in `/adm/users`; a `newns`/`sandbox`
   helper that does `su none` + a namespace trim (generalising
   `sandboxtest`) is still to do.
4. **Still to do:** `chmod`/`chown` verbs (ext2 only) + `/bin`
   front-ends; a boot-time `login`; `$user` in `/env`; a password
   check + `auth` server (much later).

### The Plan 9 stance to keep in mind

The **namespace is the security boundary**, not the uid. A sandboxed
process is one whose namespace doesn't contain the things it shouldn't
touch — uid is a secondary check that `fsd` applies to shared mounts.
Don't reach for Unix `setuid` bits and a `sudo`; reach for "give the
child a namespace that only has what it needs."

---

## 3. Hardware FPU / why floats panic today

### The current situation

racccoon builds for **`rv64imac`** — no `F`/`D` extension. On a
soft-float target LLVM lowers every float op into a compiler-rt runtime
call (`__adddf3`, `__muldf3`, `__fixdfsi`, …). racccoon links **no**
compiler-rt or libgcc, so `src/kernel/softfloat_stubs.c3` defines those
~25 symbols as stubs that `panic()` if called.

They are **never called today** — the only thing that references them is
C3's `std::io` printf formatter's unconditionally-compiled float path,
and racccoon's `printf` calls only ever use `%s`/`%d`/`%x`. The panic is
a tripwire, not a live failure.

### Why the toolchain doesn't provide the soft-float helpers

The installed cross-toolchain is `riscv64-gnu-toolchain-elf-bin` (AUR,
`/opt/riscv64-gnu-toolchain-elf-bin`), configured:

```
--disable-multilib --with-abi=lp64d --with-arch=rv64gc
```

i.e. **hardware-float, single-lib.** Its `libgcc.a` was built for
`rv64gc/lp64d`, where `__adddf3` & friends don't exist — the compiler
emits `fadd.d` instead. There is no `rv64imac/lp64` (soft-float)
multilib variant, so there is nothing to link racccoon's soft-float
target against.

Arch's own `compiler-rt` / `compiler-rt21` packages are **x86_64 host
builds** — no cross runtimes. There is no `clang` driver installed
(`c3c` bundles LLVM 22 libs, not the `clang` binary).

### The fix: use the FPU (recommended)

The T-HEAD C906 **has an FPU** — the QEMU boot log shows
`rv64imafdch`, and the real silicon has F+D. So the right move is to
stop pretending it's soft-float:

1. Build racccoon for **`rv64imafdc` / `lp64d`** (matches the toolchain
   default exactly — the `-march`/`-mattr` in `scripts/build.sh` and the
   `--riscv-cpu` in the `c3c build` call).
2. Enable FP in `sstatus` (`FS` field) for the kernel and for user
   processes.
3. **Save/restore `f0`–`f31` + `fcsr` on context switch.** Ideally
   *lazy*: leave `sstatus.FS = Initial`, trap the first FP instruction a
   process runs, save the previous FP owner's registers then, and only
   save on switch if `FS == Dirty`. The common no-float process pays
   nothing.
4. Delete `softfloat_stubs.c3`.

Cost: a bigger trap frame (or a separate FP save area per process) and
the lazy-switch logic — roughly a day. Then float "just works" at
hardware speed, which also matters for the eventual WASM `f32`/`f64`
opcodes (interpreted softfloat on a 1 GHz core would be painful).

### The fix if we ever genuinely need soft-float

(e.g. targeting a CV1800B variant with the FPU fused off — not our
board.)

- `pacman -Fy && pacman -Fl riscv64-elf-gcc | grep libgcc.a` — if
  Arch's official `riscv64-elf-gcc` ships an `rv64imac/lp64` multilib,
  link against
  `$(riscv64-elf-gcc -march=rv64imac -mabi=lp64 -print-libgcc-file-name)`.
- Otherwise `pacman -S clang` and cross-build `compiler-rt/lib/builtins`
  for `--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64`.
- Otherwise vendor GCC's `libgcc/soft-fp/` (or Berkeley SoftFloat) — the
  ~25 IEEE-754 ops — into `src/kernel/` and compile them for the target.

---

## 4. WASM as a `/bin` program

### Shape

Not in the kernel — a userspace `/bin/wasm` that:

- reads a `.wasm` file through `fsd`,
- decodes + minimally validates it,
- interprets it on a value/operand stack,
- bridges a small **racccoon-native host import module** (`print`,
  `read_file`, `args`, `exit`, a few more) to racccoon syscalls.

It slots into the shell's existing `/bin` exec path — `wasm foo.wasm
arg1 arg2` is just another program.

**Explicitly not WASI** — it's a large POSIX-shaped surface and racccoon
isn't POSIX. Define the minimal import module and grow it as real
programs need more.

### Staging

1. **Integer core** — decode; the i32/i64 arithmetic/bitwise/comparison
   opcodes; `local`/`global`; `block`/`loop`/`br`/`br_if`/`br_table`;
   `call`/`call_indirect`; linear memory (`load`/`store`/`memory.grow`);
   a single exported `_start` or `main`. Host imports: `print`, `args`,
   `exit`. Target: run a hand-written / hand-compiled integer program.
2. **Float** — the `f32`/`f64` opcodes, once §3 lands (hardware FP makes
   this free).
3. **More host imports** — file I/O against `fsd`, env, time.
4. Multi-module / a table of importable host modules — later.

### Why

Ecosystem and experiment: run things compiled from Rust/Zig/C/
AssemblyScript without a RISC-V toolchain. **Not** for sandboxing —
racccoon's per-process namespaces + `none` (§2) are a better and simpler
sandbox than a wasm VM.

### Size

MVP interpreter: ~2–4k lines for the integer subset. (wasm3, a fast
one, is ~10k.)

---

## 5. Resiliency — what happens when a server crashes

### Where we are

A driver "panic" is **not** a kernel panic — `panic()` in a user driver
is `print` + `exit()` (a deliberate hardening pass; `panic::panic()` is
kernel-only now). So a buggy `fsd`/`diskd`/`usbd` tears down cleanly as
an ordinary process and the kernel stays up.

Generation counters back most of the stale-reference handling:

- `proc_by_pid` validates pid **and** generation — a reused slot is
  never mistaken for the original process.
- `SYS_NS_RESOLVE` re-checks the mounted server's pid+generation are
  live before handing the pid back — a stale mount resolves to failure
  (or the `""` catch-all), never to whatever reused the slot.
- `SYS_IPC_SEND` / `SYS_IPC_REPLY` check the peer exists (+ generation
  on reply) **at the start** — sending to an already-dead server returns
  −1 immediately.
- Kernel idle loop respawns the **shell** if nothing is `PROC_RUNNABLE`
  (prevents a total-idle lockup when the shell exits).

### The gaps

1. **No supervision / respawn for servers.** If `fsd`, `diskd`, `usbd`,
   `envd`, … exit, nothing restarts them. The system limps on without
   that capability.
2. **Clients block forever if a server dies mid-request.**
   `SYS_IPC_SEND` blocks on `while (!msg_acked) yield()` with no
   timeout. If the server crashes after `has_message = true` but before
   `SYS_IPC_REPLY`, the sender is stuck permanently. Symmetric: a server
   mid-reply-rendezvous to a client that dies hangs the same way. This
   is `SYS_KILL`'s own documented "left blocked forever" gap.
3. **`sys_exit` doesn't unblock IPC partners** — it frees pages, marks
   the slot `PROC_UNUSED`, and yields. Anyone waiting on it stays
   waiting.
4. **Inbox wedge** — `while (target.has_message) yield()` spins forever
   if the target died with `has_message` still set.
5. **A hung (not exited) server is invisible.** An infinite loop looks
   alive; clients wait forever with no signal.
6. **In-flight hardware / FS state.** A driver that crashes mid-DMA or
   mid-write leaves the device (and possibly the filesystem) in an
   indeterminate state. `fsd`'s write path is ordering-careful but this
   isn't characterised.
7. **Live namespaces don't self-heal** — even after a respawn, a
   process that already resolved the old pid keeps using it until its
   next `ns_resolve`, and any fid it held is dead.

### Work (roughly in order)

1. **IPC failure propagation.**
   - **1a — rendezvous hangs. DONE** (commit `262d45b`). `sys_exit` /
     `sys_kill` sweep the table (`ipc_wake_waiters_on`) and wake anyone
     blocked in `sys_ipc_send` / `sys_ipc_reply` toward the dying
     process; those calls return −1. New `Process.ipc_wait_pid` /
     `ipc_wait_generation` / `ipc_peer_died` track the wait. Covers:
     send to a server that dies before consuming the request, reply to
     a client that died. `ipcdeathtest` in `shell_test.c3`.
   - **1b — reply-wait hang. DONE** (commit `6879b89`). `SYS_IPC_CALL`
     owns the whole send → wait-consume → wait-reply round-trip in the
     kernel; `ipc_peer_gone()` is checked in all three phases so it
     returns −1 if the target dies at any point.
     `Process.in_call_reply_wait` reserves the caller's inbox for the
     target's reply — a stray `ipc_send` from a third party waits in
     its phase-A loop, so `p9_call`'s `P9_STRAY` bounce is gone and
     `p9_call` is a 5-line shim. `exec()`'s `notify_pid` is no longer
     load-bearing for correctness.
2. **A supervisor. DONE (first pass)** — commit `7b5b97c`.
   `src/supervisor.c3`: a `Service` table registered from `kernel_main`,
   `supervisor_tick()` from the timer trap (~1/s) respawns any exited
   server, updates its `*_pid` global, and `reseat_namespace_mounts()`
   re-points every live process's mounts at the replacement. Restart
   cap 5. `fsdkilltest` in `shell_test.c3`. **Only fsd/fsd2/procd/envd**
   — the device drivers need MMIO/DMA re-mapping + carry hardcoded-pid
   conventions (`fsd.c3`'s `DISKD_PID=3`), and echod's pid 2 is
   hardcoded in the shell's `ping`. Extending to those means first
   removing the pid hardcodes (name-resolution instead) and verifying
   each driver's bring-up is idempotent on a respawn.
   - Kernel-side, not a userspace `/bin/init`: the servers' privileged
     setup (`setup_*_mappings`) is kernel-only, and the binaries are
     embedded in the kernel image, not on disk — a userspace init would
     need "servers live in the filesystem" + a "grant me device access"
     syscall first. Revisit once §1 (file structure) lands.
3. **Client re-attach contract.** Document that a `p9_*` op returning −1
   means "re-`attach` and re-`walk`"; the shell / libraries do this
   transparently. `ns_resolve` already returns the *new* pid after a
   supervised respawn (the reseat above makes it transparent for the
   simple attach-walk-read-clunk-per-call path — `fsdkilltest` proves
   it), so this only matters for a client holding a long-lived fid.
4. **State policy per server.** Respawned servers come up empty.
   `fsd`: fine, re-reads from disk. `envd`: holds per-process env —
   either persist it to a file under `/usr/$user/lib` or accept the
   loss. Classify each server stateless-rebuildable vs
   persist-on-write.
5. **Device reset on driver respawn.** A respawned `usbd`/`sdd`/`ethd`
   must assume the hardware is in an unknown state and do a full
   re-init (most already do their bring-up unconditionally — verify).
6. **Watchdog for hangs** (later). A supervisor ping, or the kernel
   noticing a process hasn't yielded in N ticks and killing it.

### Not doing

Full transactional / journalled recovery, process checkpointing,
live migration. This is "the system keeps working when a server dies,"
not "no request is ever lost."

---

## 6. Real 9P (later)

Deferred — do it once §1–§5 are solid.

Today's protocol is 9P-**inspired**, not wire-compatible: the fid model
(`attach`/`walk`/`open`/`read`/`write`/`clunk`) and the "everything is a
mounted file server" architecture are faithful, but the transport is
racccoon's own `SYS_IPC_*` message rendezvous with fixed-offset request
structs and hand-assigned verb numbers — no `size[4] type[1] tag[2]`
framing, no `qid`s, no `Tversion`/`msize`, no `tag`-based pipelining, no
multi-element `Twalk`, no `Tauth`. A Linux `v9fs` client can't mount
racccoon's `fsd`, and racccoon can't mount a remote 9P export.

**The work:** a `/bin/9p` (or a `9p` server) translator — speaks real
9P2000 on one side (over the network stack, or a pipe/serial for a
host mount) and racccoon's `P9_*` IPC verbs on the other. Needs:

- the 9P2000 wire codec (little-endian, `s[2]` strings, `qid` synthesis
  — racccoon's `fsd` fids would need a stable `path`/`version` to map to
  a qid),
- `Tversion`/`Rversion`, `Rerror`, tag tracking (even if replies stay
  in-order internally),
- multi-element `Twalk` fan-out onto the one-name-per-call `P9_WALK`,
- a transport binding (9P over the TCP/UDP the net stack will have by
  then, or over a serial line for `mount` from a dev host).

**Payoff:** mount racccoon's namespace from Linux (`mount -t 9p`), mount
remote 9P services into racccoon, and — the interesting one — expose
individual racccoon servers (`/proc`, a driver) to other machines the
way Plan 9 does.

---

## Sequencing

```
§3 FPU ──────────────────────────────────────────┐ (any time; ~1 day)
                                                 │
§5 resiliency ─┐ (IPC failure propagation first — small, high value;
               │  supervisor + the rest can follow interleaved)
               ▼
§1 file structure ──► §2 user model ──► shell work ──► §4 wasm ──► §6 real 9P
   (tree + seed)       (login, /adm/users,  (rc-style:     (needs §3   (needs the
                        none, read perms)    $var, pipes,   for float)  net stack)
                                             redirection,
                                             path, cd)
```

**Do the §5.1 IPC-failure-propagation piece early** — it's a contained
`sys_exit` change that turns "hang forever" into "get an error," and
everything built after it is more pleasant to develop against. The
supervisor and the rest of §5 can land interleaved with §1/§2.

The shell is the through-line — it's where the file structure, the user
model, and eventually wasm all become visible to someone sitting at the
prompt. Each `§` should land with the shell able to *show* it.
