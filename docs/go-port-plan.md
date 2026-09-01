# Go on racccoon (`GOOS=racccoon`) — bring-up plan

Status: **research done, no code yet.** Branch `go-port`. Written
2026-09-01.

Goal: compile Go programs on a host targeting racccoon, run the static
riscv64 binaries as racccoon userspace processes, and eventually run the
Go toolchain itself on racccoon. This is a **JH7110 / Orange Pi RV**
goal — see [[racccoon_c3c_selfhost]] and `docs/opi-rv-plan.md`. The Duo
(64 MiB, no swap) can boot the Stage-1 hello-world but the GC and the
compiler need the JH7110's gigabytes.

## Why this is tractable (it wasn't obvious)

Unlike LLVM, the Go toolchain has **no external dependency** — the `gc`
compiler, assembler and `cmd/link` are all pure Go, output is static,
`linux/riscv64` is a first-class port. The only hard part is the
**runtime ↔ OS contract**, and *someone already did that surgery*:

**tamago** (`github.com/usbarmory/tamago-go`, WithSecure) is a maintained
fork that adds `GOOS=tamago` — a freestanding runtime with the OS
assumptions stripped:

- No OS threads: `newosproc` → `goos.Task`, `nil` ⇒ single-threaded,
  `GOMAXPROCS=1`, `numCPUStartup = 1`.
- No futex: `semasleep`/`semawakeup` spin on an atomic counter with a
  `goos.Idle(deadline)` hook between checks.
- No signals: empty `sigtable`, `preemptMSupported = false` ⇒
  cooperative preemption only (safepoints / function prologues).
- No mmap: `mem_tamago.go` is a Plan 9-style `sbrk` over one flat
  `bloc`…`blocMax` region growing toward the g0 stack.
- All real OS interaction is externalised to a **`runtime/goos`
  package** (~10 hooks: `Printk`, `Nanotime`, `Exit`, `Idle`,
  `GetRandomData`, `CPUinit`, `RamStart`/`RamSize`/`Bloc`, `Task`,
  `Wake`). The `GOOSPKG` build setting points the toolchain at an
  out-of-tree module providing them.

tamago even ships `runtime/goos/linux_user*.s` — a reference provider
that runs a `GOOS=tamago` binary as an ordinary **Linux userspace
process** via raw syscalls (`write`, `clock_gettime`, `exit_group`,
`getrandom`, `mmap`, `clone`). **racccoon is just another host for that
same pattern** — swap the Linux syscall ABI for racccoon's `ecall` ABI.

racccoon's cooperative userspace scheduler is an unusually good match:
tamago's `semasleep` idle-hook loop wants exactly a `SYS_YIELD`, and
there are no threads to schedule.

## The two-step approach

**Step A — reuse `GOOS=tamago`, ship `GOOSPKG=racccoon`.** No toolchain
patching beyond building tamago-go once. `os`/`syscall`/`net` stay in
tamago's stubbed state. Fastest path to a Go binary running on racccoon
— validates the ELF loader, the heap region, and the scheduler match.

**Step B — rename to `GOOS=racccoon`.** Apply tamago's patchset to a
Go tree and `sed` `tamago`→`racccoon` across the GOOS plumbing
(`internal/goos`, `go/build`, `cmd/dist`, the `*_tamago.go` build-tag
files — ~15 substantive files, ~130 mechanical `testdata_*` renames).
Gives racccoon its own identity and lets `os`/`syscall` diverge toward
real **fsd-backed file I/O** without fighting tamago's bare-metal
assumptions.

Do A first, prove Stage 1–2, then B. Same incrementalism as the OPI RV
port and every racccoon feature.

## Known racccoon-side gaps (Stage 1 line items)

| Area | racccoon today | Needed |
|---|---|---|
| Exec size caps | ~~`EXEC_MAX_IMAGE_SIZE` 1 MiB~~ **DONE** | Now `board::EXEC_MAX_IMAGE_SIZE` — 4 MiB on QEMU/JH7110, 1 MiB on the Duo. New `SYS_EXEC_MAX` (51) so the shell sizes its exec buffer per-board (`exec_max()` / `exec_buf_max()`). `hello.go` = 1.6 MiB unstripped, 1.0 MiB with `-ldflags "-s -w"`. |
| ELF segments | `EXEC_MAX_ELF_SEGMENTS` 8 | **Fine as-is** — a `GOOS=tamago` riscv64 binary has 6 phdrs, only **3 PT_LOAD** (R-E text @ `0x10000`, R rodata, RW data with `.bss` gap). No INTERP, no PT_TLS (Go keeps `g` in a register on riscv64) |
| Entry / stack ABI | flat blob or ELF, `sepc` → `e_entry`, no auxv/argv-on-stack | tamago's `CPUinit` sets SP itself + jumps `rt0_*_tamago` — no Linux stack layout needed; `os.Args` empty until the provider fills it. Default link base is `0x10000`; relink at `USER_BASE` with `-ldflags "-T 0x1000000"` |
| Heap region | `SYS_MAP` returns contiguous zeroed anon pages from `heap_top` | `CPUinit` calls `SYS_MAP` for a big arena, sets `goos.RamStart`/`RamSize`/`Bloc` from the return (dynamic, cleaner than tamago's fixed `0x80000000`) |
| Time | `SYS_TIMEBASE` (tick Hz) + userspace `rdtime` **already works** (`user.c3`'s `rdtime()` does `csrr t0, time` — the kernel sets `scounteren.TM`) | `goos.Nanotime` = `rdtime()` scaled by `timebase_hz()` — pure userspace, no new syscall |
| Random | none | Stage 1: stub (fixed seed). Later: a `SYS_RANDOM` (JH7110 has a TRNG) |
| Console | `SYS_PUTCHAR` / `SYS_GETCHAR` (byte at a time) | `goos.Printk` = `SYS_PUTCHAR`. A batched `write` syscall would help throughput |
| Exit | `SYS_EXIT` / `exitcode` | `goos.Exit` = `SYS_EXIT` |

## Stages

### Stage 0 — scaffold — this branch

- `docs/go-port-plan.md` (this file).
- `go/` tree: the `GOOSPKG` provider module skeleton — `go.mod`,
  `runtime/goos/racccoon_user.go` + `racccoon_user_riscv64.s`
  (ported from `linux_user_riscv64.s`), a linker-flag / build wrapper
  `scripts/build_go.sh` (no-op without the tamago-go toolchain, same
  convention as `build_opi.sh`).
- No kernel changes yet. QEMU + Duo builds unaffected.

### Stage 1 — a Go program prints and exits (QEMU) — **DONE**

`go/cmd/hello` (println, int/float math, slice+`append`, `map`, `defer`,
`panic`/`recover`) builds via `scripts/build_go.sh` and **runs on
racccoon in QEMU** — correct output, clean exit 0, re-runnable. `gotest`
in `shell_test.c3`.

What it took:
- Toolchain: tamago-go `tamago1.27.0` branch, `./make.bash` once.
- Provider `go/goos/`: `CPUInit` (asm) `SYS_MAP`s a 48 MiB arena, writes
  the base to `RamStart`/`Bloc`, sets SP, jumps the tamago rt0.
  `Printk`→`SYS_PUTCHAR`, `Exit`→`SYS_EXIT`, `Idle`→`SYS_YIELD`,
  `Nanotime` = `rdtime()` split-scaled by `sys_timebase()` (cached).
  `Task` nil (single-threaded), `GetRandomData` a fixed fill.
- Link flags: `-ldflags "-T 0x1010000 -R 0x1000"` — text at
  `USER_BASE + 64 KiB` so the ELF header lands exactly at `USER_BASE`;
  `-R 0x1000` (page rounding) keeps `-T`'s file offsets non-negative.
  Result: 3 PT_LOAD, all inside `[USER_BASE, USER_BASE + 4 MiB)`,
  ET_EXEC, `e_phnum` 6 — the existing racccoon ELF loader eats it
  unchanged (`.bss` `p_memsz > p_filesz` auto-zeroed by `alloc_pages`).
- Kernel, board-gated (QEMU/JH7110, never the Duo):
  `board::EXEC_MAX_IMAGE_SIZE` 4 MiB (+ `SYS_EXEC_MAX` so the shell
  sizes its exec buffer), `board::HEAP_MAX_BYTES` 64 MiB (SYS_MAP is
  eager, and the Go arena is ~48 MiB), `src/kernel.ld` `__free_ram`
  64 → 112 MiB (QEMU virt has 128 MiB; the arena + servers need room).

Not yet exercised: GC under real pressure, goroutines, `time.Sleep`
(that's Stage 2).

### Stage 2 — GC + goroutines + timers — **DONE**

`go/cmd/gostage2` (`gostage2test` in `shell_test.c3`) — all checks pass
on racccoon in QEMU:
- **GC**: churns ~48 MiB of garbage in 24 KiB bites with forced
  `runtime.GC()`, `NumGC` climbs, `HeapAlloc` stays bounded, the ~2 MiB
  live set survives every cycle. The `sbrk`/`bloc` region behaves.
- **Goroutines**: 200-way fan-out/fan-in over a buffered channel +
  `WaitGroup`, `close`+`range`, `select` with `time.After`, a
  100-goroutine mutex-guarded counter — all correct. Cooperative on one
  M (`GOMAXPROCS=1`); `gopark`/`goready` + the `semasleep` idle loop
  yield through `SYS_YIELD`.
- **Timers**: `time.Sleep(20ms)` advances `time.Now()` in bounds,
  `time.NewTicker(10ms)` fires 2–20× in 80 ms — the `wakeG` timer path
  + `nanotime` (`rdtime`) + the spin-idle scheduler.

Slow (spin-idle scheduler + real GC on emulated hardware — tens of
seconds), but correct.

Kernel RAM raised for this (QEMU only, board-gated):
- `scripts/launch64*.sh` now pass `-m 1G`; `src/kernel.ld` `__free_ram`
  → 768 MiB.
- `board::HEAP_MAX_BYTES` → 512 MiB; provider `RamSize` → 128 MiB
  (eager, with a CPUInit 8 MiB fallback if a board refuses it).

**JH7110 2 GiB — cleared (2026-09-01).** The old "racccoon does not
boot with `-m >= 2G`" note no longer reproduces: the current kernel
boots cleanly at QEMU `-m 2G`, `-m 3G`, `-m 4G`, and `-m 8G`, runs
`gotest` and the regression sweep, and still boots + runs Go with
`__free_ram` experimentally raised to 1792 MiB under `-m 2G`. The
kernel runs bare-mode through `kernel_main` and never reads the FDT,
so the FDT-placement theory in the original note was wrong; the real
earlier failure was in the pre-Stage-2 allocator (a `RAM_SIZE` /
`__free_ram` mismatch), fixed by the Stage 2 rework + allocation rover.
What *was* still capped: `src/allocation.c3`'s `RAM_SIZE` (the page
bitmap's compile-time size) hardcoded 768 MiB — so any board's usable
pool was ceilinged there regardless of its own `kernel.ld`. Raised to
**1920 MiB** (≈ the medany code-model ceiling — every global ref must
sit within ±2 GiB of the kernel text PC, so `__free_ram_end` can't run
much past ~1.9 GiB from a kernel at DRAM_BASE + 2 MiB anyway). Bitmap
is now 60 KiB of BSS; `ram_page_count()` still caps the allocator to
each board's real linker span, so QEMU (768 MiB) and Duo (~59 MiB) are
behaviourally unchanged. The Orange Pi RV board (`opi-rv-port` branch)
can now size `boards/opi-rv/kernel.ld` up to that ceiling.

Follow-up (not blocking): `create_process` / `sys_rfork` / `sys_exec`
identity-map the whole pool at 4 KiB granularity into *every* process
page table — ~4 MiB of page tables per process and ~500 K `map_page`
calls per process at a 2 GiB pool. Boots fine (measured at 1792 MiB)
but wasteful; a 2 MiB-megapage kernel identity map, or a shared
kernel L1 sub-table referenced from every root table, is the real fix.
Touches ~5 page-table walk sites (the teardown / COW loops must skip a
megapage/shared entry rather than descend or free it).

Optional later: racccoon *has* the thread primitives — `rfork(RFPROC|
RFMEM)` + `SYS_FUTEX_WAIT`/`_WAKE` keyed on `(addr, page_table)`. A real
`goos.Task` (RFMEM rfork) + futex `semasleep` would give multi-M
cooperative scheduling on one hart. Not needed for correctness.

### Stage 3 — file I/O against fsd — **DONE** (the bridge; `os.*` wiring is 3.5)

`go/racccoon` — a package Go programs import for real, persistent I/O
against whatever racccoon has mounted, over `SYS_NS_RESOLVE` +
`SYS_IPC_CALL` and the `FS_*` verbs, mirroring
`lib/racccoon-libc/src/rc_fs.c` byte for byte:

- `ReadFile` (chunked), `WriteFile` (chunked), `Stat`, `ReadDir`
  (follows FS_LIST pagination), `Mkdir`, `Remove`/`RemoveAll`,
  `Rename`, `Getwd`, `Chdir`.
- `go/racccoon/sys_riscv64.s` — `nsResolve` / `ipcCall` (5-arg) /
  `sysGetcwd` / `sysChdir` raw ecalls.

`go/cmd/gostage3` + `gostage3test`: reads `/hello.txt`, walks `/`,
`/subdir`, and the 60-entry `/manyfiles` (pagination), writes a
4.8 KB file under `/tmp` and reads it back, renames it, makes a
directory tree, removes everything. 21/21 checks pass on racccoon in
QEMU; `e2fsck -fn` clean afterward.

### Stage 3.5 — Go's own `os` package on fsd — **DONE**

The standard library `os` operates on racccoon's filesystem, for
**every** racccoon Go binary — no import needed. `os.Open`,
`os.ReadFile`, `os.ReadDir`, `os.Create`, `os.Getwd`, `os.Args` etc.
just work (including the Stage-4 toolchain binaries).

- **The fsd backend lives in `runtime/goos`** (`go/goos/racccoon_fs.go`,
  the GOOSPKG overlay): the full FS_* protocol over `SYS_NS_RESOLVE` +
  `SYS_IPC_CALL`, plus a fixed 64-slot handle table (no `sync` — the
  package is imported by `runtime`; GOMAXPROCS=1 means nothing yields
  mid-op). Its `init()` installs itself into `goos.FS`.
- **`lib/go/racccoon.patch`** (5 files, applied to the tamago-go tree by
  `scripts/setup_tamago.sh`, carried in-repo like `lib/tcc/racccoon.patch`):
  an optional `runtime/goos.FS` `FSHook` (errno ints, not `error` — the
  package can't pull in `errors`). When set, `syscall`'s
  `Open`/`Read`/`Write`/`Seek`/`Stat`/`Mkdir`/`Unlink`/`Rename`/
  `ReadDirent`/`Getwd`/`Chdir` route to it instead of `fs_tamago.go`'s
  in-memory fs; a new `fs_racccoon.go` holds the `goosFile` `fileImpl`
  + synthesises fixed-size dirent records for `os.ReadDir` and maps the
  errno ints to `syscall.Errno` (`ENOENT` for a failed resolve so
  `os.IsNotExist` works). `nil` FS = stock tamago — inert for
  non-racccoon builds.
- **`os.Args`** — `CPUInit` (asm) stashes the exec-ABI `a0`/`a1` (argc,
  the NUL-separated argv blob); a tiny `os_tamago.go` `init()` refreshes
  the runtime's hardcoded `{"tamago"}` `argslice` from `goos.Args`
  before `os` init reads it. `os.Args[0]` is a synthetic `"go"`, real
  args at `[1:]` (racccoon's c3 exec ABI carries no argv[0]).
- **`go/racccoon`** is now a thin typed convenience layer over `os`
  (kept for `go/cmd/gostage3`).

`go/cmd/gostage35` + `gostage35test`: `os.ReadFile` / `os.Stat` /
`os.Open`+`io.ReadAll` / `Seek`+`Read` / `ReadAt`, `os.IsNotExist`,
`os.ReadDir` (incl. the 60-entry paginated dir), `os.WriteFile` /
`os.Create` / O_TRUNC, `os.Mkdir` / `os.Rename` / `os.Remove` /
`os.RemoveAll`, `os.Getwd`, `os.Args`. 26/26 checks pass on racccoon in
QEMU; `e2fsck -fn` clean.

Not done: `os/exec` (Stage 4.1), `os.Getenv`→`/env` (small, on demand).

### Stage 4 — run the Go toolchain on racccoon

The self-host milestone, mirroring §7's tcc arc — but the Go toolchain
is ~10× tcc's size, so this is a multi-session effort with real
unknowns. Staged:

- **4.0 — exec headroom.** *Done for QEMU.* `board::EXEC_MAX_IMAGE_SIZE`
  4 → **32 MiB** on QEMU (a stripped `GOOS=tamago cmd/compile` is
  **23 MiB**, ET_EXEC, 3 PT_LOAD — the existing ELF loader takes it;
  the staging arrays it sizes grow to ~96 KiB BSS). `gotest` still
  passes. Still to do: speed up `exec()`'s fsd read loop (1124
  bytes/IPC RTT → a 23 MiB binary is ~20k round trips, tens of seconds
  on QEMU); the shell exec buffer is now eagerly `SYS_MAP`'d at 32 MiB
  per exec (the rover keeps it O(n), but a right-sized map or a
  bulk-read verb would help). The JH7110 board gets the same bump.
- **4.1 — `os/exec` — DONE (first cut).** Much simpler than a Linux
  `clone`+`execve` port: `GOOS=tamago`'s `syscall` already stubs
  `StartProcess` / `Wait4` / `WaitStatus` (`syscall_tamago.go` —
  "not supported, just enough for package os"), so the patch just
  fills them in. `runtime/goos.Spawn` / `Wait` (`go/goos/racccoon_exec.go`):
  the parent reads the target binary and packs argv into one buffer
  (all allocation / fs I/O before the fork), `rfork(RFPROC)`, and the
  child does exactly one or two NOSPLIT ecalls (optional `SYS_CHDIR`,
  then `SYS_EXEC`) before its image is replaced — no Go allocation or
  scheduler interaction in the child window. `Wait` → `SYS_JOIN`.
  `/dev/null` handled in the fs backend (a reserved handle: reads EOF,
  writes discarded). `go/cmd/gostage41` + `gostage41test`: runs
  `/bin/echo`, `/bin/false` (exit code propagates), a missing command
  (clean error), and **another Go binary** (`/bin/go-hello` spawned by
  a Go program, runs correctly). Verdict bit off by one on the first
  run (`WaitStatus` used a made-up `0x100` "exited" bit instead of the
  standard `low-7-bits == 0`) — fixed.
  - **Not yet**: argv[0] — packed plain, so a spawned Go child's
    `os.Args[0]` is the synthetic `"go"`, real args at `[1:]`.
- **4.1 follow-up — `os/exec` OUTPUT CAPTURE — DONE.** `exec.Cmd.Output`
  / `CombinedOutput` / a `bytes.Buffer` `Stdout` now work.
  - `os.Pipe()` (patched `os/pipe_tamago.go` → `syscall.PipeGoos`)
    reserves a `runtime/goos` capture slot and two `goosPipeFile` fds.
    `StartProcess` reads the slot id off the write-end fd in
    `attr.Files` and passes it to `Spawn`.
  - The child's stdout is wired to a kernel pipe **atomically by
    `rfork`** — a new optional `a2` on `SYS_RFORK` (`src/entry.c3`).
    A follow-up `SYS_PIPE_SETOUT` loses the race: the Go scheduler
    parks the parent at the first safepoint after `rfork` and lets the
    child run ahead (the c3 shell's loop never yields there, so it
    keeps the two-step). The c3 `rfork()` wrapper now passes `a2 = -1`.
  - `Spawn` drains the pipe to EOF (child exit) into a byte slice,
    joins, records the exit code, returns — the whole child runs
    synchronously (fine: GOMAXPROCS=1, a blocking ecall freezes the Go
    world anyway; `Wait` becomes a lookup). The pipe's read end
    (`goosPipeFile`) serves the drained bytes to os/exec's `io.Copy`
    goroutine.
  - racccoon gives a process **one console stream** (no separate
    stderr), so captured output is combined stdout+stderr.
  - **Not done**: stdin-from-pipe (`Cmd.Stdin` as a non-`*os.File`) —
    the child inherits the console's stdin; `go` never feeds its
    subtools stdin. Truly concurrent Start-then-work-then-Wait (Start
    blocks until the child exits).
  - `go/cmd/gostage42` + `gostage42test`: `echo` via `Output()`, a Go
    binary via `CombinedOutput`, a `bytes.Buffer` `Stdout`, a 22 KiB
    capture past the 4 KiB pipe buffer (`/bin/go-spew`), and a
    console-inherit regression check. c3 shell `|` / `>` / `rfork`
    regressions all still green.
- **4.2 — `go tool compile` on racccoon — DONE**, first try, no fixes
  needed. `build_go.sh cmd/compile` cross-builds it (self-installing
  fsd backend, no wrapper needed — a stdlib command can't blank-import
  a repo module, which is exactly why the backend had to move into
  `runtime/goos`). On a one-off bigger scratch ext2 image (the
  committed QEMU image is 16 MiB; `compile` alone is 22 MiB — sizing
  the real image is a 4.3+ decision):
  - `/bin/go-compile` (no args) → the compiler's real `-h` usage text,
    ~200 flags, printed correctly. Confirms the 22 MiB binary loads,
    the Go runtime + GC + heap arena come up, `os.Args`/flag parsing
    works, bulk stdout works.
  - `/bin/go-compile -p p -o /p.o -lang=go1.24 -nolocalimports
    -complete /tp.go` on a real two-line Go source → **exit 0**, ~30–40 s
    wall (mostly fixed compiler-startup cost, not file size). `/p.o` is
    a genuine `go object tamago riscv64 go1.27.0` archive with correct
    metadata (`gclocals`, `arginfo`, `type:int`) — verified by pulling
    it off the image and inspecting it on the host. `e2fsck -fn` clean.
  - This validates the whole chain end to end: `os.Open`/`ReadFile` on
    the source, the full compiler (parser, type-checker, SSA, codegen)
    running under `GOMAXPROCS=1` on racccoon's cooperative scheduler,
    `os.Create`/`Write` on the output — with no host-assumption fixes
    needed anywhere.
- **4.3 — `go tool link` — DONE. The self-hosting loop is closed.**
  `board::EXEC_MAX_IMAGE_SIZE` was never the constraint that mattered
  here — the QEMU ext2 image was: grown 16 → **256 MiB**
  (`scripts/build.sh`; 262144×1 KiB blocks / 8192-per-group = 32
  groups, nowhere near `ext2.c3`'s `EXT2_MAX_GROUPS` 2048 ceiling).
  `scripts/build_go_toolchain.sh` cross-builds `cmd/link` and captures
  the real dependency closure a `go build` of `go/cmd/hello` needs
  (`go build -a -work`: 28 packages, `runtime` + its transitive
  `internal/*`, ~15 MiB total) — rewriting the closure's `importcfg`/
  `importcfg.link` to racccoon's on-device paths (`/lib/go/pkg/*.a`).
  This is the same bootstrapping shape as `lib/tcc`'s prebuilt
  `crt1.o`/`libtcc1.a`: cross-built support objects, not something
  racccoon's own compiler needs to produce from scratch — Stage 4.3's
  job was proving `link` itself works, not rebuilding the whole stdlib
  on-device (that's optional, later, tier-3 self-host territory).

  On racccoon, in one shell session, against `go/cmd/hello`'s **real**
  source (seeded as `/hello.go`):
  ```
  go-compile -o /tmp/hello.o -p main -complete -importcfg /lib/go/importcfg /hello.go
  go-link -o /tmp/hello.elf -importcfg /lib/go/importcfg.link -buildmode=exe -T 0x1010000 -R 0x1000 /tmp/hello.o
  /tmp/hello.elf
  ```
  All three steps exit 0. The resulting binary's output matches Stage
  1's host-cross-compiled `/bin/go-hello` **byte for byte** — println,
  hardware-FP math, slice `append`, `map`, `defer`, `panic`/`recover`
  all correct. `e2fsck -fn` clean after. Formalised as the
  `gotoolchaintest` shell builtin (slow — minutes — so not part of the
  quick regression sweep, run on demand). One shell-side fix along the
  way: the interactive line buffer is 128 bytes, so a hand-typed
  compile/link invocation with every flag overflows it — trimmed to
  the flags that actually matter (`-lang`/`-goversion`/`-c=1`/
  `-nolocalimports` are all safe to omit for this case); the builtin
  itself passes argv directly so it isn't affected.

  A racccoon binary, compiled and linked by racccoon's own toolchain,
  running on racccoon, byte-identical to the cross-compiled version.
  Nothing needed fixing to get there.
- **4.4 — the `go` command** orchestrating it (`go build`), with the
  build cache, `$GOROOT/src` stdlib reads, module handling, and 4.1's
  `os/exec` to invoke `compile`/`link` as subprocesses instead of by
  hand. The largest remaining piece; wants the JH7110's 2 GiB,
  `GOMAXPROCS=1`.

  **Spike (2026-09-01, no commit):** `build_go.sh cmd/go` →
  13.7 MiB tamago/riscv64 ELF, fits the 32 MiB cap. Loads and runs on
  racccoon; `os.Args` + flag parsing work; reaches GOROOT lookup and
  prints a real diagnostic. Two blockers, both predicted:
  1. `runtime.defaultGOROOT` is baked to the host toolchain path.
     Need `$GOROOT` → an on-device tree with
     `pkg/tool/tamago_riscv64/{compile,link,asm}`, `VERSION`, `src/`.
     Fix via `GOROOT` env through `envd` **or** re-baking
     `defaultGOROOT` in `lib/go/racccoon.patch`.
  2. `go` `os/exec`s a `tamago` telemetry helper — `Spawn` returns
     not-found, `go` continues (non-fatal). Disable with
     `GOTELEMETRY=off` / patch out the telemetry package.

  **4.4 part 1 — DONE (commit TBD): `go version` / `go env` run on
  racccoon.** `go version go1.27.0 tamago/riscv64`, exit 0.
  `goversiontest`. `scripts/build_go.sh` links `cmd/go` with
  `-X runtime.defaultGOROOT=/goroot`; `build_go_goroot.sh` +
  `scripts/build.sh` seed `/goroot/{VERSION,go.env}` (go.env carries
  `GOFLAGS`/`GOPROXY=off`/`GOTOOLCHAIN=local`/`GOCACHE=/gocache`/...,
  read by `cfg.findGOROOT` before the empty process env). Telemetry
  child spawn silenced (`x/telemetry` `DisabledOnPlatform` +=
  `tamago`). `syscall.ImplementsGetwd` flipped to a `var = goos.FS !=
  nil` so `os.Getwd()` uses the fsd cwd directly (the `..`-walk
  fallback needs real st_ino, which the fsd backend fakes as 0);
  `getcwd()` in `go/goos` now returns `/` for the empty root cwd.

  **4.4 part 2 — `go build` — groundwork, not working.** Gets through
  GOROOT / module load / build-cache / toolID probe. Fixed on the way:
  filelock → no-op on tamago; `GOOS tamago unsupported without GOOSPKG`
  fatal (`cmd/go/internal/goos` uses `$GOROOT/src/runtime/goos`
  directly on tamago — seed the racccoon overlay there, no GOOSPKG);
  `GOCACHE=off` rejected → real `/gocache` dir; `syscall.Ftruncate`
  routed to the fsd hook; `goos.FS.Truncate` generalised (shrink =
  read+rewrite, grow = zero-pad). **Open:** `compile -V=full` reports
  its name as `go` (racccoon exec ABI has no argv[0]; the goos layer
  synthesises `os.Args[0]="go"`), which `cmd/go`'s toolID parser
  rejects — needs argv[0] carried through `SYS_EXEC` (kernel + `exec()`
  + c3 callers + `start()`) or a relaxed toolID check. Plus seeding
  `$GOROOT/src` (~10 MiB closure) + `{compile,link,asm}` into
  `/goroot/pkg/tool/tamago_riscv64/`.

Likely wants the `GOOS=racccoon` rename around 4.3–4.4 (own identity,
room for `os`/`syscall` to diverge further) — apply tamago's patchset
to a Go tree, `sed` `tamago`→`racccoon` across the GOOS plumbing (~15
substantive files, ~130 mechanical `testdata_*` renames), fold in
`lib/go/racccoon.patch`.

### Stage 5 — network (later)

`net` over racccoon's `ethd`/`netd` — needs a `netpoll` shim (or
accept blocking I/O) and the net stack to actually have a carrier
(see [[racccoon_eth_status]]). Unblocks real Go servers.

## Non-goals

- SMP / real OS threads (racccoon is single-hart by design). Go runs
  `GOMAXPROCS=1` forever here.
- cgo (no C toolchain on racccoon beyond tcc; pure Go only).
- Signal-based async preemption (`asyncpreemptoff=1` — cooperative
  preemption is enough).
- The Duo as anything past a Stage-1 curiosity.
