# Racccoon roadmap

Status: **direction agreed, no code yet.** Written 2026-08-29.

The bring-up phase is largely done — scheduler, IPC, namespaces, three
filesystems, USB, SD, ethernet, a Duo port. The next phase is making
racccoon feel like a system you *use* rather than one you bring up. Four
workstreams, in dependency order:

1. Plan 9 file structure
2. Plan 9 user model
3. Hardware FPU (unblocks float) — **DONE**
4. WASM as a `/bin` program

§3 is done — §4's `f32`/`f64` opcodes are now free. 1 → 2 → (shell work)
is the spine; §5 (resiliency) is done.

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
4. **`chmod`/`chown`. DONE** — `FS_CHMOD` (29) / `FS_CHOWN` (30) verbs
   through the `Fs_ops` table; `ext2_chmod` (owner-or-root, keeps
   i_mode's format nibble) / `ext2_chown` (root-only — POSIX, and the
   uid model only drops); FAT32/exFAT reply -1. `fs_chmod`/`fs_chown`
   wrappers + `/bin/chmod` (octal) / `/bin/chown` (uid or `/adm/users`
   name). `chmodtest` — owner-chmod, non-root-chown-denied,
   non-owner-chmod-denied, and the bits chmod writes are honoured by
   `ext2_write_allowed` (0600 denies other, 0666 allows). QEMU
   ext2-verified, `e2fsck` clean.
5. **Still to do:** a boot-time `login`; `$user` in `/env`; a password
   check + `auth` server (much later).

### The Plan 9 stance to keep in mind

The **namespace is the security boundary**, not the uid. A sandboxed
process is one whose namespace doesn't contain the things it shouldn't
touch — uid is a secondary check that `fsd` applies to shared mounts.
Don't reach for Unix `setuid` bits and a `sudo`; reach for "give the
child a namespace that only has what it needs."

---

## 2.5 The shell

The through-line — where §1 and §2 become usable. An `rc`-style pass,
not bourne. Interleaved with §1/§2 rather than a phase of its own.

**Done:**
- **cwd** (`e89affb`) — `Process.cwd` (kernel), `SYS_CHDIR`/`SYS_GETCWD`,
  inherited across rfork, kept by exec. `fs_abspath()` in every `fs_*`
  wrapper + `exec()` resolves relative paths against it. `cd` (with
  `.`/`..` normalisation, `/usr/$user` home), `pwd`. Prompt shows it:
  `root /usr/glenda #`.
- **`$var` expansion** (`5fc3c69`) — `shell_expand()` before tokenising.
  `$user`/`$cwd`/`$home` synthesised; anything else is `/env/<name>`,
  empty if unset. `echo` builtin.
- **`|` pipes** and **`>` / `<` / `>>` redirection** — kernel pipe
  primitive (`src/pipe.c3`: a ring buffer with writer/reader refcounts;
  `Process.stdout_pipe`/`stdin_pipe`, -1 = console). `SYS_PUTCHAR`/
  `SYS_GETCHAR` route through it; `SYS_PIPE`/`_SETOUT`/`_SETIN`/`_READ`/
  `_WRITE`/`_HOLD` (39–44) drive it. `shell_run_pipeline()` parses one
  `|` plus `<`/`>`/`>>` (each its own space-separated token), spawns the
  stage(s) with `shell_spawn()`, wires the ends before any child runs
  (cooperative sched — no race), then pumps the file end itself. A
  pipeline stage is always an external `/bin` binary, so `echo` got a
  real `/bin/echo` and `cat` learned to read stdin. `< file` is bounded
  at one `PIPE_BUF` (4096). Builtins can't sit in a pipeline yet.
- **`;` / `&&` / `||` sequencing + exit status** — kernel gained an
  exit-status side table (`src/process.c3`: `sys_exit` / `sys_kill`
  record `(pid, gen, code)`, `sys_join` returns it); `exit()` →
  `exitcode(int)`; a failed `exec` is 127, a kill is -1.
  `shell_exec_line()` splits the raw line on ` ; ` / ` && ` / ` || `
  (space-surrounded), then expands + tokenises each pipeline right
  before it runs — so `$status` (rc's) mid-line is correct. One
  left-associative precedence level. `/bin/true`, `/bin/false`.
  `SHELL_MAX_TOKENS` 8 → 16.
- **quoting** — `shell_expand_q()` + a parallel `qmask` byte array:
  `'...'` fully literal (`''` → `'`), `"..."` literal but `$name`
  expands. The tokeniser splits only on unquoted whitespace and treats
  `|` / `<` / `>` / `>>` / `;` / `&&` / `||` as operators only when
  unquoted. Unterminated quote → status 2.
- **backslash escapes** — `\<char>` outside quotes is `<char>` literal
  (`\ ` escaped space, `\|` `\$` `\*` escaped operator/dollar/metachar);
  inside `"..."`, `\` escapes only `` $ ` " \ ``; inside `'...'` it's
  literal. Escaped bytes get `qmask = 1` so the tokeniser already does
  the right thing.
- **brace expansion** — `{a,b}c` → `ac bc`, `pre{x,y}post`,
  `{a,b}{c,d}` cartesian, nested `{a,{b,c}}`; runs per word before
  globbing (`/bin/{c,l}*` → glob of each). No-comma / unmatched /
  quoted / escaped braces stay literal. `shell_brace_split` +
  `shell_brace_rec`, bounded.
- **background jobs** — a trailing `&` (`a & b &` too) backgrounds a
  pipeline into `g_jobs`; `shell_run_pipeline`'s `bg` flag spawns
  without joining. `jobs` lists, `wait` joins all, and each prompt
  reaps finished jobs (`[N] done | exit S`) via `proc_info` polling +
  a non-blocking `join`. No `<` / `>` in a bg job; no `^Z` / `fg` /
  `bg` (no signals in this kernel).
- **`/bin/head`** — first stdin filter (`ls | head -n 3`); `head [-n N]`,
  reads stdin only, default 10 lines.
- **multi-stage pipelines (`a | b | c`)** — up to `MAX_STAGES = 6`,
  with `<` on the first stage and `>`/`>>` on the last. The kernel race
  that blocked this is fixed: `Process.driver_irq_pending` decouples a
  driver's device-completion notify from the IPC inbox,
  `sys_ipc_poll` drains the PLIC by hand so a spin-polling driver gets
  its notify with `sstatus.SIE` globally off, diskd acks the
  virtio-mmio ISR, and `DISKD_READ`/`_WRITE` moved 10/11 → 210/211 off
  the P9/FS verb range (see docs/devlog.md 2026-08-29).
- **globbing** — a pipeline word with an unquoted `*` / `?` is expanded
  against the filesystem before its stage runs (`glob_match` +
  `shell_glob_into`, user/shell_common.c3): `*` any run, `?` one char,
  last path component only; no match → literal (rc's rule). Quoted
  metachars stay literal.
- **`bind` / `mount` / `unmount` + `namespace`** — `SYS_NS_LIST` (45)
  and `SYS_NS_BIND` (46); builtins in `shell_dispatch_common` (both
  shells). `mount <srv> <dir>` binds a `srv_post`'d name;
  `bind <source> <dir>` binds whatever serves `<source>`; `namespace` /
  `ns` prints the table. Builtins not `/bin` commands — a namespace
  change only flows parent → child at spawn. A mount at `/mnt/x/` only
  resolves for paths with the trailing slash (same wart every boot
  mount has — `SYS_NS_RESOLVE` fix left for later).
- **boot-time `login`** — `shell.c3` prompts `login: <name>` against
  `/adm/users` (name only, no password field), then `setuid` + `cd
  /usr/<name>`. `root` always works; no `/adm/users` → comes up as
  root. Also a `login <user>` builtin. `shell_readline()` extracted +
  shared.
- **output-only builtins as pipeline stages** — `pwd` / `hello` /
  `namespace` / `ns` run as a forked child (via `shell_spawn_stage` →
  `shell_dispatch_common`) when they appear in a pipeline or with
  redirection (`namespace | head -n 2`, `pwd > f`). Side-effecting
  builtins (`cd`, `su`, `mount`, …) stay out — a child can't deliver
  their effect; they 127 in a pipeline.

**Still to do:**
- `#!` scripts + `if` / `for` / `while` — the big structural one, much
  later.

---

## 3. Hardware FPU — DONE (commit `675ccf8`)

Built `rv64imafdc` / `lp64d` (`c3c --riscv-abi=double` + `llc
-mattr=+f,+d`); `sstatus.FS = Initial` at boot with a read-back probe;
`f0`–`f31` + `fcsr` saved/restored **eagerly** in `yield()` around
`switch_context` (which is `@naked` and preserves no FP regs, and is
`yield()`'s only caller — so one spot covers every switch). `user_entry`
starts processes with FS on; `sys_rfork` copies FP state to the child,
`sys_exec` resets it. `softfloat_stubs.c3` gone — one `__trunctfdf2`
stub remains (std::io's lone `fptrunc fp128` in an unreached path; no Q
ext). Embedded-binary wrappers moved to `llvm-mc --target-abi=lp64d`
`.incbin` (an `objcopy -Ibinary` wrapper's soft-float e_flags no longer
link against the hard-float kernel). `fputest` (shell_test.c3) proves
f-regs survive fork + context switches. QEMU + Duo verified (plain
reflash — stock OpenSBI v0.9 hands `mstatus.FS` off usable).

<details><summary>Original problem statement (kept for reference)</summary>

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

</details>

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

1. **Integer core. DONE** — milestones 1a-1d (commits `800d313`,
   `2b86a00`, `89e18d6`, + 1d). `/bin/wasm` (~1.1k lines) built on a new
   `SYS_MAP` demand-page syscall: decode + structural validation; the
   full i32/i64 arithmetic/bitwise/comparison/`div`/`rem`/`clz`/`ctz`/
   `popcnt` set; `local`/`global`; `block`/`loop`/`if`/`else`/`br`/
   `br_if`/`br_table` via a load-time block sidetable; `call`; linear
   memory (all load/store widths + `memory.size`/`grow`); `call_indirect`
   + table + element + start sections; exported `_start`/`main`. Host
   module `racccoon` (not WASI): `print_i32`/`print_i64`/`print_str`,
   `proc_exit`, `arg_count`/`arg`, `read_file`/`write_file`, `time`.
   Fixtures `add`/`loop`/`mem`/`fac`/`start`/`echo` (hand-assembled by
   `test/mkwasm.py`), QEMU-verified via `wasmtest`.
2. **Float. DONE** — milestone 2. Every `f32`/`f64` opcode:
   `const`/`load`/`store`, arithmetic + comparison, `min`/`max`/
   `copysign`/`sqrt`/`abs`/`neg` + the four directed roundings, the full
   i32/i64 ↔ f32/f64 conversion set (trapping *and* the `0xFC`
   saturating variants), `reinterpret`/`promote`/`demote`. §3's hardware
   FP means the operators lower straight to `fadd.d` etc.; `sqrt` and
   the roundings use small `@naked` asm helpers (the block `asm{}` form
   only knows integer lw/sw). Fixtures `float` → 88, `float2` → 80.
3. **Real compiled programs. STARTED.** `test/wasm-src/{fib,upper}.zig`
   → `wasm32-freestanding` via `zig`, importing the `racccoon` host
   module directly. `wasm fib.wasm 50` → `12586269025`. The Zig output
   used nothing outside the milestone-1/2 opcode set (no bulk-memory /
   SIMD / `0xFC`) — so it ran with no interpreter changes. Next as real
   modules need it: bulk-memory (`memory.copy`/`fill`), a WASI-subset
   shim if a concrete program wants one, raising `FUNCS_MAX` / type
   limits, `env` / AssemblyScript import compat.
4. **More host imports** — deeper `fsd` / env integration as real
   programs need it.
5. Multi-module / a table of importable host modules — later.

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
- `SYS_IPC_SEND` / `SYS_IPC_REPLY` / `SYS_IPC_CALL` check the peer
  exists (+ generation) at the start **and** re-check `ipc_peer_gone()`
  on every wait iteration — a peer that dies mid-rendezvous returns −1,
  not a hang (§5.1, `262d45b` / `6879b89`).
- Kernel idle loop respawns the **shell** if nothing is `PROC_RUNNABLE`
  (prevents a total-idle lockup when the shell exits).
- **OOM is a −1, not a kernel panic.** `try_alloc_pages()` returns 0 on
  exhaustion; `SYS_MAP` / `SYS_EXEC` / `SYS_RFORK` pre-check the free
  pool (incl. page-table overhead) and fail the syscall. `alloc_pages()`
  still panics — but only the boot-time callers use it, where a failure
  means unbootable anyway. The allocator scans only the real
  `__free_ram_end − __free_ram` span (`ram_page_count()`), not the
  hardcoded 64 MiB ceiling. `oomtest`, Duo-verified.
- **A user-mode fault kills just that process.** `handle_trap` tears
  down a process that takes a page fault / illegal instruction / etc.
  from U-mode (`proc_destroy` + `yield`, like SYS_EXIT); only an
  S-mode exception still panics. `faulttest`, Duo-verified. (Swap /
  demand paging is *not* planned — storage is behind userspace servers
  the kernel can't IPC, and the board is 64 MiB.)

### The gaps

1. ~~**No supervision / respawn for servers.**~~ **Closed** — the
   supervisor (§5.2 below) covers every server and driver now.
2. ~~**Clients block forever if a server dies mid-request.**~~ **Closed**
   (`262d45b`, `6879b89` — §5.1 below). Every `sys_ipc_send` /
   `sys_ipc_reply` / `sys_ipc_call` wait loop checks `ipc_peer_gone()`
   each iteration and returns −1 if the peer's slot goes dead or the
   `sys_exit`/`sys_kill` sweep flagged it. The p9_* client wrappers
   already turn that −1 into their own −1 return; servers just loop back
   to `ipc_recv`. `ipcdeathtest`.
3. ~~**`sys_exit` doesn't unblock IPC partners.**~~ **Closed** (same
   commits) — `proc_destroy` calls `ipc_wake_waiters_on(victim)`, which
   sweeps the table and sets `ipc_peer_died` + wakes anyone whose
   `ipc_wait_pid`/`generation` matches the dying process.
4. ~~**Inbox wedge** — `while (target.has_message) yield()` spins forever
   if the target died with `has_message` still set.~~ **Closed** — that
   loop is now `while (!ipc_inbox_available(target))` with the same
   `ipc_peer_gone()` bail.
5. **A hung (not exited) server is invisible.** ~~An infinite loop looks
   alive; clients wait forever with no signal.~~ **Closed** (`§5.6`
   watchdog, commit below): the supervisor kills any supervised server
   whose inbox holds an unconsumed message for `SVC_STALL_LIMIT`
   consecutive ticks — a healthy server clears `has_message` the instant
   it calls `ipc_recv`.
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
2. **A supervisor. DONE** — commits `7b5b97c` (first pass), `e5f111d`
   (storage driver).
   `src/supervisor.c3`: a `Service` table registered from `kernel_main`,
   `supervisor_tick()` from the timer trap (~1/s) respawns any exited
   server, updates its `*_pid` global, and `reseat_namespace_mounts()`
   re-points every live process's mounts at the replacement. Restart
   cap 5. `fsdkilltest` / `storagekilltest` in `shell_test.c3`.
   Covers **every server and every device driver**: fsd, fsd2, echod,
   procd, envd, the block-storage driver (diskd / sdd), and
   usbd / ethd / netd / gpiod. `Service.kind` (SVC_KIND_*) says which
   `setup_*_mappings` to re-run after `create_process` — the MMIO + DMA
   re-mapping; PLIC routes self-heal (`irq_route_register` overwrites in
   place). No more hardcoded pids: the shell's `ping` resolves echod
   through `/srv/echo/`, fsd learns the storage pid from
   `SYS_FS_PARTITION_INFO` and re-queries on an IPC failure, and the
   `reseat` covers the dynamic `/mnt/usb/` / `/srv/gpiod/` mounts.
   - `Service.watch_hangs` splits the hang watchdog from respawn:
     usbd / ethd get **respawn-on-exit only** (their bring-up
     legitimately blocks their IPC poll for seconds — a USB bus reset,
     a PHY train — which would false-trip the stall check). gpiod moved
     to `watch_hangs = true` (3 MMIO writes, not a slow reset).
   - **Fault-tested, QEMU**: fsd (`fsdkilltest`), storage
     (`storagekilltest`, diskd), netd (`netdkilltest`), the hang
     watchdog (`hungservertest`) — all pass.
   - **Fault-tested, real Duo** (2026-08-30, `DUO_TEST_SHELL=1` kernel):
     - `usbdkilltest` — **PASS.** usbd killed, supervisor respawns it,
       `setup_usbd_mappings` re-maps the DWC2 MMIO + DMA, `/srv/usbd/`
       re-posts. (Full HID re-enum unverified — no device on the bus.)
     - `gpiodkilltest` — **PASS.** Respawned gpiod re-maps its MMIO,
       rebuilds its pin table, and services a real SET_DIR on GPIOC24.
       **Root cause** of the earlier apparent wedge: `create_process`
       didn't clear `driver_irq_pending` (a gap vs `sys_rfork`) — a
       respawned driver's first `SYS_IPC_POLL` returned the synthetic
       IRQ-notify instead of the real request. Also: gpiod now has
       `watch_hangs = true` (its bring-up is 3 MMIO writes, not a slow
       bus reset) as a net.
     - `fsdkilltest` / `storagekilltest` — the Duo "failures" were the
       tests reading `hello.txt`, a **QEMU-only fixture** (`build.sh`
       seeds it; `populate_duo_bin.sh` doesn't). `fs_read` returned −1
       for want of the file and the pass condition needs `before >= 0`.
       `loud` proved the servers were fine — a respawned fsd printed
       `fsd: ext2 mounted …`, a respawned sdd enumerated the card
       cleanly. Fixed: probe with `bin/echod` (on every image).
       Two real fixes made along the way: (a) the QEMU-10MHz killtest
       deadlines (`SYS_TIMEBASE` / `timebase_hz()`); (b) `fsd`'s
       `diskd_rw` retry was gated on `rr_pid != g_diskd_pid`, which
       never fires on a same-slot respawn — dropped that gate. **All
       four killtests (fsd/sdd/usbd/gpiod) now PASS on the real Duo.**
     - `netdkilltest` — **N/A on Duo.** netd exits before `srv_post`
       (self-test needs DHCP + a carrier the Duo link never gets — see
       "Ethernet status"), so there's nothing to kill.
   - **§5.5 CLOSED**: fsd, sdd, usbd, gpiod supervisor respawn all
     fault-verified on the real Duo (`DUO_TEST_SHELL=1` kernel, the
     four `*killtest` builtins). ethd untested — no working link.
   - Bugs fixed getting there: `create_process` didn't clear
     `driver_irq_pending` (a respawned driver's first `SYS_IPC_POLL`
     returned the synthetic IRQ-notify); `SYS_TIMEBASE` (#49) /
     `timebase_hz()` so killtest deadlines are wall-clock not
     QEMU-10MHz tick counts; `fsd` `diskd_rw` retry un-gated from
     `rr_pid != g_diskd_pid`; the tests probed a QEMU-only fixture.
     Diagnostic kept: the `loud` builtin (`SYS_BOOT_QUIET a0=1`)
     un-silences a respawned boot server's own console output.
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
   Classified:
   - `fsd` / `fsd2` — stateless-rebuildable: re-reads everything from
     disk on the next request. Nothing to do.
   - `procd` — stateless: every answer is a live `SYS_PROC_INFO` call.
   - `echod` — stateless: a synthetic in-memory tree rebuilt in `main`.
   - `envd` — **accept the loss.** `env_table` is keyed by `(pid,
     generation)`, which is meaningless after any respawn; the shell's
     `$user` / `$cwd` / `$home` / `$status` are shell-computed, not
     stored here; and nothing but the dev tests ever writes `/env` at
     all. A respawned envd coming up empty *is* the correct behaviour
     ("the env server crashed, your vars are gone") — persisting a
     pid-keyed table to disk would restore nothing usable.
5. **Device reset on driver respawn.** A respawned `usbd`/`sdd`/`ethd`
   must assume the hardware is in an unknown state and do a full
   re-init (most already do their bring-up unconditionally — verify).
   `diskd`/`sdd` verified: `diskd_init` writes `DEVICE_STATUS = 0`
   (full virtio reset) before re-negotiating, so it's idempotent — the
   supervisor's `storagekilltest` respawn-then-read passes repeatedly.
6. **Watchdog for hangs. DONE** (commit below). `SVC_STALL_LIMIT`
   consecutive ticks with the server's inbox holding an unconsumed
   message → the supervisor kills it (the next tick respawns it).
   `ever_ready` gates it so a slow-starting server (sdd on the Duo)
   isn't mistaken for wedged. `hungservertest` (shell_test.c3, echod +
   the `ECHOD_HANG` verb) proves it.

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

## 7. A C library + POSIX layer → self-hosting (in progress)

### Why

To compile racccoon's own programs *on* racccoon. The realistic path
isn't LLVM-via-wasm (a 50–200× interpreter running a 30–100 MB module —
glacial, and won't fit 64 MiB) — it's porting a **small native
compiler** (TinyCC class: ~30k lines of C, its own asm + linker + cpp,
no LLVM). That needs a C runtime + libc + POSIX-shaped surface for
real Unix C to build and run against.

### Shape

```
C programs (tcc, coreutils, …)
libc:  stdio · stdlib · string · ctype · math · time · setjmp
POSIX layer:  fd table · open/read/write/close/lseek · stat/fstat ·
              fork/execve/waitpid · dirent · mmap(anon) · errno · env
              · pipe/dup2 (limited) · signals (stubbed)
racccoon syscall stubs + crt0
```

The **POSIX layer** is the translation: racccoon is path-based
(`fs_read_at(path, buf, len, off)`), POSIX is fd-based. A userspace fd
table maps `fd → {path, offset, flags, kind}`; `read(fd)` becomes
`fs_read_at(table[fd].path, …, table[fd].offset)` + an offset bump,
`fork`→`rfork`, `waitpid`→`join`. Almost no kernel changes (env needs
an exec convention; that's it).

Built with `riscv64-unknown-elf-gcc -march=rv64imafdc -mabi=lp64d
-mcmodel=medany -ffreestanding -nostdlib -nostdinc` + our own headers,
`crt0`, `libracccoon.a` (`lib/racccoon-libc/`, `build.sh` there,
wired into `scripts/build.sh`, no-ops without a riscv64 C compiler).
Programs are flattened to a raw binary (`objcopy`) and run via the
flat-binary exec path like the c3 `/bin` commands.

### Stages

1. **C beachhead. DONE** — `crt0` + `ecall` syscall stubs + `_exit` +
   console `write`/`read`; `test/c-src/ctest.c` runs on racccoon,
   echoes its argv, sets its exit code. `argv[0]`: racccoon's exec ABI
   carries only the args (a c3 `args[0]` is the first real arg), so the
   crt0 synthesises a placeholder `argv[0]` and shifts the args to
   `argv[1..]` — a real name is deferred to §7.6.
2. **malloc + `<string.h>`. DONE** — K&R malloc (TCPL §8.7): circular
   first-fit free list, coalescing on `free`, `morecore` via `SYS_MAP`
   instead of `sbrk` (consecutive `SYS_MAP` calls are contiguous, so
   freed arenas coalesce and blocks are reused within the process).
   `calloc`/`realloc`, `exit`/`abort`. `src/string.c` covers the four
   the standard requires freestanding (`memcpy`/`memmove`/`memset`/
   `memcmp`) plus the common `str*`. `malloctest` (20 k-iteration churn
   + scrambled frees) → ok, no heap growth.
3. **freestanding core. DONE** — `<ctype.h>` (ASCII), `<errno.h>`
   (global, single-threaded), `<assert.h>`, `<setjmp.h>` +
   `src/setjmp.S` (ra/sp/s0-s11/fs0-fs11), `<stdlib.h>`: `strto*`
   family, `atoi`/`atol`/`strtod`, `abs`/`labs`, `qsort` (mo3
   quicksort), `bsearch`, `atexit` (run by `exit`), `rand`/`srand`,
   `getenv` (NULL until §7.6). `stage3test` → ok. (`limits.h`/
   `stdint.h`/`stdarg.h` resolve to gcc's freestanding headers.)
4. **POSIX fd layer. DONE** — `src/rc_fs.c` reimplements racccoon's
   path-based fs in C over `SYS_NS_RESOLVE` + `SYS_IPC_CALL` to fsd
   (linking `user.o` collides with the crt0's `main`/`exit`/`start`).
   `src/rc_posix.c`: a 64-slot userspace fd table behind `open`/`close`/
   `read`/`write`/`lseek`/`dup`/`dup2`/`fcntl`/`isatty`; `stat`/`fstat`/
   `mkdir`/`unlink`/`rmdir`/`rename`/`access`; `opendir`/`readdir`.
   `<fcntl.h>` `<sys/stat.h>` `<sys/types.h>` `<dirent.h>`. `O_CREAT` →
   empty write, `O_TRUNC` → delete+recreate (no fsd truncate),
   `O_APPEND` → seek to size. `SYS_GETPID` (#50). `stage4test` → ok.
5. **stdio. DONE** — `src/stdio.c` (buffered `FILE`: `fopen`/`fdopen`/
   `freopen`/`fclose`, `fread`/`fwrite`, `fgetc`/`fgets`/`ungetc`,
   `fputc`/`fputs`/`puts`, `fseek`/`ftell`/`fflush`/`feof`/`ferror`,
   `setvbuf`, `perror`, `tmpnam`/`tmpfile`, `getline`/`getdelim`).
   `src/printf.c` — one `vformat()` over an emit callback:
   `d i u o x X c s p % f F e E g G`, `hh/h/l/ll/j/z/t/L`, `- + # 0`,
   `*`. Floats via the hw FPU. `stage5test` → ok.
6. **process. DONE** — `src/rc_proc.c`: `fork` (→ `rfork(RFPROC)`),
   `execve`/`execv`/`execvp`/`execl`/`execlp` (read the image through
   fsd, pack the blob, one `SYS_EXEC`), `wait`/`waitpid` (→ `SYS_JOIN`
   on a `(pid,generation)` the libc records at `fork`; no any-child
   primitive — oldest first), `system`, `getppid` (`SYS_PARENT_INFO`).
   `<sys/mman.h>`: `mmap(MAP_ANONYMOUS)` → `SYS_MAP`, `munmap`/`mprotect`
   no-ops. `src/rc_env.c`: real `environ` + `getenv`/`setenv`/`putenv`/
   `unsetenv`, with `getenv` falling back to the `/env` store (envd).
   **argv[0] / env resolved with no kernel ABI change** — an
   `execve`-packed blob leads with a `0x01` marker, then argv (argv[0]
   first), then an optional `0x02` marker + env; the crt0 tells this
   apart from a c3 `exec()`'s plain blob (which still gets a synthesised
   argv[0]). `stage6test` (+ `test/c-src/exiter.c`) → ok.
7. **TinyCC cross-build. DONE** (2026-08-31) — `tcc /hello.c -o /bin/hw
   && hw world` runs on racccoon in QEMU: preprocess → riscv64 codegen →
   integrated link → static ELF to disk → the kernel ELF loader →
   correct output. `e2fsck` clean afterward. `third_party/tinycc`
   submodule (mob 0.9.28rc); `scripts/build_tcc.sh` cross-builds it
   against the libc, `scripts/seed_tcc.sh` seeds `/bin/tcc` + `/lib/tcc/`
   (headers, `crt1.o`, `libc.a`, `libtcc1.a`), `scripts/build.sh` wires
   both. `lib/tcc/config.h` + `lib/tcc/racccoon.patch` (`ELF_START_ADDR`
   → USER_BASE) + `CONFIG_TCC_SWITCHES "-static"` give a plain
   `tcc x.c -o x`. Landed along the way: stage 6.5 libc (`<math.h>`
   `<time.h>` `<strings.h>` `<inttypes.h>`, ~25 fns, `strerror`;
   `stage7test`); `EXEC_MAX_IMAGE_SIZE` 256 KiB → 1 MiB; the shell exec
   buffer `SYS_MAP`'d; `src/malloc.c` rewritten (K&R free list corrupted
   under tcc — now segregated-list + bump, no coalescing); a
   `.riscv.attributes` strip for tcc's object loader; **fsd ext2 single
   + double indirect block writes** (`ext2_ensure_block_for_write` /
   `ext2_free_data_and_indirect`; `bigwritetest`); libc `read()` loops
   for regular files; shell execs a `/`-containing command as a path.
   Duo run still pending.
8. **TinyCC self-hosts. DONE** (2026-08-31) — `tcc /src/tcc/tcc.c -o
   /bin/tcc2` on racccoon, then `tcc2 /hello.c -o /bin/hw2 && hw2` runs.
   `/bin/tcc2` is 468 KiB, self-compiled; `e2fsck` clean. Needed
   `<stdint.h>` (added to the libc — tcc ships none) and a no-op
   `__clear_cache` (`lib/tcc/rvflush.c`, into `libtcc1.a`).
   `build_tcc.sh` stages the ONE_SOURCE file subset into `build/tcc/src`
   → `/src/tcc/` on the image.

### Not doing

Full glibc/musl compatibility, threads, dynamic linking, a full
`<termios.h>`/job-control surface. Just enough POSIX for a
self-contained compiler and small Unix utilities.

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
