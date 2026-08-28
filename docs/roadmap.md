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

- Decide the tree (above is a starting point).
- Seed it in `scripts/build.sh`'s image builder (the ext2 path — see the
  existing `disk-ext2/` fixtures) and document how to lay it down on a
  fresh Duo partition.
- A `namespace(1)`-style view: the shell should be able to print the
  current process's mount table (reads `/proc/$pid/ns` or similar — a
  new `/proc` file).
- `bind`/`mount`/`unmount` as shell builtins or `/bin` programs
  (`SYS_NS_MOUNT`/`_UNMOUNT` already exist; `bind` — remap one existing
  name to another within the namespace — may need a new verb).

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

1. `/adm/users` on the root fs + a tiny parser (shared lib, used by
   `login` and by anything that maps uid ↔ name for display).
2. `login` (`/bin/login`, or a `getty`-alike the kernel spawns on the
   console instead of the shell): prompt for a name, look it up, set
   uid via `SYS_SETUID`, `cd /usr/$name`, exec the shell. No password
   at first (single-user-ish); a password check + an `auth` server is a
   later step.
3. A `none` entry + a `newns`/`sandbox` helper that drops to `none` and
   trims the namespace (generalise `sandboxtest`).
4. Thread `requester_uid` through the **read** path in `fsd` + the FAT32
   and exFAT backends; decide the no-`i_uid` policy for those.
5. `chmod`/`chown` verbs (ext2 only initially) + `/bin` front-ends.
6. `$user` in `/env` so the shell prompt and `whoami` are cheap.

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

## Sequencing

```
§3 FPU  ─────────────────────────────┐ (any time; ~1 day)
                                     │
§1 file structure ──► §2 user model ──► shell work ──► §4 wasm
   (tree + seed)        (login, /adm/users,   (rc-style:      (needs §3
                         none, read perms)    $var, pipes,     for float)
                                              redirection,
                                              path, cd)
```

The shell is the through-line — it's where the file structure, the user
model, and eventually wasm all become visible to someone sitting at the
prompt. Each `§` should land with the shell able to *show* it.
