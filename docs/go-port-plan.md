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

### Stage 2 — GC + goroutines under memory pressure

- Force a GC (allocate megabytes), confirm the `sbrk`/`bloc` region +
  `memclrNoHeapPointers` behave and the arena doesn't collide with the
  g0 stack.
- Goroutines: `go func()`, channels, `sync.WaitGroup`, `select`. All
  cooperative on one M — confirm `gopark`/`goready` + the `semasleep`
  idle loop yield correctly through `SYS_YIELD`.
- Optional: racccoon *does* have the thread primitives — `rfork(RFPROC|
  RFMEM)` shares an address space and `SYS_FUTEX_WAIT`/`_WAKE` are
  keyed on `(addr, page_table)`. A real `goos.Task` (RFMEM rfork) +
  `semasleep` via futex would give multi-M cooperative scheduling on
  the one hart. Not needed for correctness; revisit if `GOMAXPROCS=1`
  latency bites.
- `time.Sleep` / `time.After` — needs the `wakeG` timer path
  (`sys_tamago_riscv64.s`) wired to racccoon's timebase.
- Real memory sizing: `goos.RamSize` from the board's RAM (JH7110
  variant) — raise `SYS_MAP`'s reach on that board.

### Stage 3 — `os` / file I/O against fsd (this is where Step B pays off)

Rename to `GOOS=racccoon`, then implement the `syscall` package's
file ops against racccoon's path-based `fsd` — mirroring what
`lib/racccoon-libc/src/rc_posix.c` already does in C (a userspace fd
table → `SYS_NS_RESOLVE` + `FS_*` IPC):

- `open`/`read`/`write`/`close`/`lseek`/`fstat`/`readdir` → `fsd`.
- `os.Open`, `os.ReadFile`, `os.Args` (provider fills from the exec
  ABI), `os.Getenv` → `/env`.
- `os/exec` → `rfork` + `SYS_EXEC` (Go can't `fork` safely; use the
  careful `syscall.forkExec` shape).
- Success = a Go program reads `/hello.txt`, walks a directory, writes
  a file; `e2fsck` clean.

### Stage 4 — run the Go toolchain on racccoon

- Cross-build `GOOS=racccoon` copies of `compile`, `asm`, `link`,
  `go`.
- `go build hello.go` **on racccoon** (JH7110, GiBs of RAM,
  `GOMAXPROCS=1`) → a runnable racccoon binary.
- The self-host milestone, mirroring §7's tcc arc.

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
