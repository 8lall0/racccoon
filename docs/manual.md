# The Racccoon manual

A complete reference for Racccoon: what it is, how it is put together, and
how to write programs that run on it.

Racccoon is a small preemptive **microkernel** for 64-bit RISC-V
(`rv64imafdc`, hardware floating point), written entirely in
[C3](https://c3-lang.org/) with no libc. The kernel does traps,
scheduling, paging, IPC and namespaces; **everything else — filesystems,
block/USB/network/GPIO drivers, the shell — is an ordinary user
process.** The design is Plan 9-flavoured: per-process namespaces,
path-based (not file-descriptor-based) filesystem IPC, a 9P-style verb
protocol, servers reached by name.

> This is an experiment, not a product. There is **no stable ABI** —
> syscall numbers, wire formats and helper signatures change whenever it
> is convenient. This manual describes the tree as of 2026-10-21 (notes,
> `SYS_AWAIT`, shared segments, the FIFO send queue, 64 processes, the
> TCP/UDP stack at `/net`). When in doubt, the source is authoritative:
> `src/syscalls.c3` for syscalls, `user/user.c3` for the userspace API.

Contents:

1. [Architecture](#1-architecture)
2. [The process & memory model](#2-the-process--memory-model)
3. [The syscall ABI](#3-the-syscall-abi)
4. [Syscall reference](#4-syscall-reference)
5. [The userspace runtime library](#5-the-userspace-runtime-library)
6. [IPC and the 9P-style protocol](#6-ipc-and-the-9p-style-protocol)
7. [Namespaces](#7-namespaces)
8. [The filesystem interface](#8-the-filesystem-interface)
9. [Writing a program](#9-writing-a-program)
10. [The shell](#10-the-shell)
11. [The servers](#11-the-servers)
12. [Board abstraction & porting](#12-board-abstraction--porting)
13. [Building, running, flashing](#13-building-running-flashing)
14. [Limitations](#14-limitations)
15. [Appendix: source map](#15-appendix-source-map)

---

## 1. Architecture

### 1.1 Layers

```
                    ┌─────────────────────────────────────────────┐
   user mode (S)    │ shell   /bin programs   fsd  diskd/sdd  usbd │
                    │ ethd/netd  gpiod  procd  envd  echod         │
                    └───────────────▲─────────────────────────────┘
                                    │  ecall  (the only entry)
                    ┌───────────────┴─────────────────────────────┐
   kernel (S)       │ traps (entry.c3) & syscalls (syscalls.c3)    │
                    │ scheduler & processes (process.c3)           │
                    │ Sv39 paging (page.c3)   page allocator       │
                    │ IPC   namespaces   pipes   PLIC   console    │
                    └───────────────▲─────────────────────────────┘
                                    │  ecall  (SBI)
   machine mode (M) │ OpenSBI  — console, timer, HSM, on the Duo the DDR/PLIC glue │
```

The kernel and all user processes run in **S-mode**. M-mode is OpenSBI,
which Racccoon treats as firmware and talks to only for the console
(legacy `putchar`/`getchar`), the timer (`sbi_set_timer`), and multi-hart
start (HSM, unused — one hart). The Duo additionally relies on a patched
OpenSBI for the T-HEAD PLIC S-mode delegate.

### 1.2 What the kernel keeps

The kernel is deliberately small. It owns:

- **Trap entry / syscall dispatch** — `src/entry.c3` (trap path) and
  `src/syscalls.c3` (`handle_syscall`, one big `switch`).
- **The scheduler** — round-robin over `PROCS_MAX` (16) slots, preemptive
  via the S-mode timer interrupt, cooperative `yield()` inside blocking
  syscalls. Single run queue, single hart.
- **Processes** — `Process[16] procs`, each with its own Sv39 page table,
  64 KiB kernel stack, IPC inbox, namespace table, cwd, uid.
- **Sv39 paging** — every process gets the kernel identity-mapped
  (RWX, no `PAGE_U`) plus its own image at `USER_BASE` (`PAGE_U`).
- **A physical page allocator** — bitmap over the free RAM pool.
- **IPC** — a single-slot synchronous inbox per process, plus `SYS_IPC_CALL`
  (one-shot RPC done entirely in the kernel).
- **Namespaces** — per-process mount table (prefix → server pid), plus a
  global `srv_table` for `post`/`mount`.
- **Pipes** — anonymous kernel pipes for the shell's `|` `<` `>`.
- **The console** — routed through `sbi::__putchar` / `__getchar`, plus a
  32 KiB in-kernel log ring (`dmesg`) and a keystroke queue that a USB
  keyboard driver feeds.
- **The supervisor** — `src/supervisor.c3`, a watchdog that respawns a
  crashed or wedged boot server.

Everything else is a user process that reaches the kernel only through
`ecall`.

### 1.3 Boot sequence

1. OpenSBI hands off in S-mode at `0x80200000` (fixed) with `a0` = boot
   hart id, `a1` = DTB address. That address **must** be `boot()`
   (`src/kernel.c3`, pinned first in `.text.boot` via a
   `.text.boot.entry` subsection — see the note in both linker scripts;
   c3c's emission order is not stable and once put `smp.c3`'s
   `secondary_entry` there instead, bricking the boot silently).
2. `boot()` (`@naked`) stashes `a0`, sets `sp`, jumps to `kernel_main()`.
3. `kernel_main()` clears BSS, installs the trap vector (`stvec` →
   `kernel_entry`), turns on the FPU, sets up the timer, initialises the
   PLIC, then spawns the boot processes with `create_process()`:
   `idle` (pid 0), `echod`, the block driver (`sdd` on the Duo /
   `diskd` on QEMU), `fsd` (+ a second `fsd` on dual-partition setups),
   `procd`, `envd`, `shell`, then `usbd` / `ethd` / `netd` / `gpiod`
   where the board has them.
4. Each server is started through `service_boot()`
   (`src/supervisor.c3`), which spawns it and registers it with the
   supervisor. A driver names its board device (`device_find("sd")` …);
   `device_setup()` (`src/device.c3`) then identity-maps that device's
   MMIO pages, allocates its DMA regions, and routes its PLIC source —
   all from the board's `DEVICES` table. A board without the device
   simply doesn't spawn the driver.
5. `kernel_main()` falls into the idle loop: schedule, and re-spawn the
   shell if nothing runnable is left.
6. The kernel prints ~13 progress lines; the servers print their own
   init chatter (SD CMD sequence, DHCP lease, USB enumeration, …). The
   shell waits out a short settle, calls `SYS_BOOT_QUIET` to stop later
   server output landing on the prompt, then prints `login:`
   (production build) or drops straight to a root prompt (QEMU test
   build). Kernel output and boot-server output are also captured in
   the 32 KiB `dmesg` ring; a plain process's stdout (the shell prompt,
   `ls` output) is not — `dmesg` is the *kernel* log, not a scrollback.

### 1.4 The two shells

- **`user/shell.c3`** — the production shell. Login, the small set of
  real builtins (`cd`, `pwd`, `exit`, `su`, `mount`, `bind`, `jobs`,
  …), `/bin` execution. This is what `scripts/build_duo.sh` embeds.
- **`user/shell_test.c3`** — the same, plus every regression-test
  builtin the project has accumulated (`runtest`, `wasmtest`,
  `killtest`, `rforktest`, `oomtest`, …), split by category into
  `shell_test_{fs,ipc,proc,drivers,lang}.c3`. `scripts/build.sh` embeds
  this in the QEMU kernel. It skips login (automated runs want a root
  shell immediately).

Both share `user/shell_common.c3` (builtins, line editing, block
parsing), `user/shell_words.c3` (`$var`, globbing, quoting) and
`user/shell_jobs.c3`.

---

## 2. The process & memory model

### 2.1 A process

`struct Process` (`src/process.c3`) — the fields a program author cares
about:

| field | meaning |
| --- | --- |
| `pid` | slot index + 1 (idle is the exception: slot 0, pid 0) |
| `state` | `PROC_UNUSED` / `PROC_RUNNABLE` / `PROC_BLOCKED` / `PROC_RESERVED` |
| `generation` | bumped every time the slot is reused — pairs with pid to detect "same slot, different process" |
| `page_table` | this process's Sv39 root |
| `uid` | 0 = root; set once by `SYS_SETUID` while still 0, then permanent |
| `parent_pid` / `parent_generation` | 0 for a `create_process()`'d server; set by `rfork` |
| `namespace[16]` | prefix → server-pid mount table |
| `cwd` | absolute, no trailing slash, `""` = root |
| `heap_top` / `map_floor` | the `SYS_MAP` bump region |
| `stdout_pipe` / `stdin_pipe` | `-1` = console, else a pipe id |
| `name` | short label for `ps` / `top` (argv[0] basename, or the server name) |
| `noteg` / `note_handler` | note group and note handler — see §2.7 |

There are **64 slots** total. `pid = slot + 1`. When a process exits its
slot is freed and the next occupant gets the same pid but an incremented
`generation`. A slot's 64 KiB kernel stack and 8 KiB IPC inbox come
from the page pool the first time the slot is used and stay with it, so
slots that are never used cost almost nothing.

### 2.2 Address space

Flat, one region. Every process's image is linked at and loaded at
**`USER_BASE = 0x1000000`** (16 MiB) — see `user/user.ld`. This is fine
even though every program uses the same base: each only ever exists in
its own page table.

```
0x1000000  ┌────────────────┐  USER_BASE
           │ .text          │
           │ .rodata        │
           │ .data / .bss   │
           │ 64 KiB stack   │  __stack_top  (grows down)
           ├────────────────┤  map_floor
           │ SYS_MAP region │  demand-paged, grows up to heap_top
           ├────────────────┤  heap_top
           │  (unmapped)    │
0x1800000  └────────────────┘  linker ASSERT ceiling (image must fit under this)
```

- The **image + a fixed 64 KiB stack** are mapped eagerly.
- **`SYS_MAP`** hands out address space above the image, page-aligned,
  bounded by `HEAP_MAX_BYTES` (16 MiB Duo / 1.5 GiB QEMU). It is
  **demand-paged**: `SYS_MAP` reserves the range, a page fault in it
  maps one zero page. This is the userspace "give me a heap" primitive —
  `/bin/wasm`'s linear memory, the real-stdlib allocator, Go's arena.
- **Shared segments** (`segattach`, §2.8) are the one way two
  processes share memory (besides a couple of driver-only identity-mapped
  DMA arenas). There is **no `mmap` of files**; file data moves over IPC.

### 2.3 rfork, exec, threads

Racccoon uses **Plan 9's `rfork`**, not `fork`:

```c3
int rfork(int flags, uint* generation_out);
```

- `RFPROC` (required) — create a new process. Returns the child pid to
  the parent, `0` to the child, `-1` on failure. **The child resumes
  from the exact `rfork()` call site**, not a fresh entry point (like
  `fork`).
- `RFMEM` — share the parent's address space instead of copying it.
  `RFPROC|RFMEM` is "spawn a thread". **Do not call `rfork(RFPROC|RFMEM)`
  bare** — the shared stack gets corrupted the moment the parent makes
  its next call. Use `threadcreate()` (below), which gives the child a
  fresh stack and entry point in `@naked` asm before any C control flow
  touches the shared stack.
- `RFNOTEG` — the child starts its own note group (§2.7) instead of
  sharing the parent's, so a `^C` aimed at the parent's group doesn't
  reach it. The shell uses it for `&` jobs.
- A child inherits its parent's stdout / stdin (console or pipe), like
  `fork` — unless `rfork_io` names explicit pipes.
- `rfork_io(flags, gen_out, stdout_pipe, stdin_pipe)` — `rfork` plus
  atomic pipe wiring, closing the race a follow-up `pipe_setout` leaves
  open. This is what the shell uses for `|` `>` `<`.

```c3
int exec(char* path, char* buf, uint buf_max, int notify_pid,
         char** argv, int argc);
```

**`exec` replaces this process's own image in place** — same pid, same
page table, same namespace, same cwd, same uid. To run a program without
becoming it, `rfork(RFPROC)` then `exec()` in the child (exactly
`fork`+`exec`). `exec` reads the whole file into the caller-provided
`buf` (looping `fs_read_at`), then installs it in one `SYS_EXEC`. It
accepts **ELF64/RISC-V** executables (the toolchain's `*.elf`) or
Racccoon's **flat binary** format (`*.bin`, loaded RWX at `USER_BASE`).
`argv` is packed into the same `buf` after the image as NUL-separated
strings. Only returns (`-1`) on failure. `exec_path("ls", …)` resolves a
bare name against `$PATH` (default `/bin`).

```c3
int threadcreate(void* func, void* arg, void* stack_top, uint* gen_out);
```

Give it a stack buffer you own; `func(arg)` runs on it. `func` must call
`exit()` itself. Returns the thread pid or `-1`, never `0`.

### 2.4 Scheduling & preemption

- Round-robin over runnable slots. The S-mode timer fires **once per
  second** (`arm_timer(board::TIMEBASE_HZ)`); its handler calls
  `yield()` if `current_proc.pid > 0`. So the preemption quantum is
  coarse — a tight non-yielding loop can hold the CPU for up to a
  second before it is forced off.
- **Blocking syscalls** (`SYS_GETCHAR`, `SYS_IPC_RECV`, `SYS_JOIN`,
  `SYS_FUTEX_WAIT`, `SYS_IPC_CALL`, `SYS_AWAIT`, `SYS_NS_MOUNT_WAIT`)
  wait inside the kernel: some sleep (`PROC_BLOCKED`, woken by whatever
  they wait for — a message delivery, a futex wake, a note), the ones
  that must poll (console, pipes, join) spin a `yield()` loop. A sender
  that finds a server's inbox busy sleeps in that server's FIFO queue
  (§6.1). Most of these waits are cut short by a note (§2.7).
- `SYS_YIELD` / `yield()` gives up the rest of the current slice once.
- There is **no priority, no nice, no real-time**. Cooperative code
  that `yield()`s in its wait loops (every server, the shell) keeps the
  system snappy; a CPU-bound program makes everything else stutter at
  ~1 s granularity until it exits or blocks.

### 2.5 Exit, join, kill

- `exit()` / `exitcode(n)` — never returns. Frees every `PAGE_U` page,
  wakes any `join()` waiter, marks the slot `PROC_UNUSED`.
- `join(pid, generation)` — block until that exact process instance no
  longer exists. Pass the `generation` you captured at `rfork` time so
  join can tell "it exited" from "its pid got reused".
- `kill(pid, expected_generation)` — root, or exact same uid as the
  target. `generation` 0 = wildcard. A peer blocked mid-IPC-rendezvous
  with the killed process is released with `-1` rather than hanging
  forever. (The gentler, catchable way to stop a process is a note,
  §2.7.)

### 2.6 Out-of-memory

The kernel survives OOM: `try_alloc_pages()` returns `-1` and the
allocating syscall fails cleanly rather than panicking. A userspace
page fault with `SPP == 0` kills just that process (the supervisor
respawns it if it was a boot server). There is **no swap** and none is
planned.

### 2.7 Notes (signals) and `^C`

Racccoon has Plan 9's **notes** (`src/note.c3`): a note is a short
string posted to a process — `postnote(pid, msg)`, `postnote_group(g,
msg)`, or the console's `^C`, which posts `"interrupt"` to the console's
note group. It is delivered the next time the process is about to return
to user mode:

- **No handler** (the default), or the note is `"kill"`: the process dies
  (exit status −1), exactly like a user fault.
- **A handler** (`notify(&h)`): the process resumes in `h(char* msg)` on
  a small stack carved below the interrupted one. `h` must finish with
  `noted(NCONT)` (resume where it was interrupted — registers, sepc and
  FP state are restored) or `noted(NDFLT)` (die). Returning from `h`
  instead faults and kills. Notes arriving while `h` runs queue (up to 5
  per process).

A process **sleeping in a wait** when a note arrives is woken and the
syscall returns −1: `getchar`, `join`, `futex_wait`, `pipe_read` /
`pipe_write`, `ipc_recv`, `await_any`, and `ipc_send` / `ipc_call` while
still queued for a busy server. `interrupted()` tells that −1 apart from
a real failure. Waits where a server already holds the request (the
rest of `ipc_call`, `ipc_reply`) aren't interrupted; the note lands as
soon as they finish (bounded by the 15 s call timeout). `join()` itself
retries after the handler ran.

**Note groups.** Every process is in one (`Process.noteg`). A
kernel-spawned process starts its own; an `rfork` child shares its
parent's unless `RFNOTEG` is given. The console's `^C` goes to the
shell's group: the shell (which has a handler — it drops the line being
typed, and stops a running loop or `;` sequence) and its foreground
children (which, without a handler, die). Background jobs and boot
servers are in other groups and don't see it. The console is checked
for `^C` on every `getchar`, while the shell waits in `join`, and on the
timer tick — so even a tight compute loop stops within about a second.

### 2.8 Shared segments

`segattach(name, size)` maps a **named** run of physical pages into the
caller's address space (`src/segment.c3`), creating it — zero-filled,
`size` rounded up to pages, at most 4 MiB — the first time the name is
used. Another process attaching the same name gets the same pages; an
`rfork` child inherits its parent's attachments (they're shared, not
copied). `segdetach(addr)` unmaps one; the memory is freed when the last
attachment goes (a detach, an `exec`, or an exit). Names are global (16
segments, 15-byte names); the creator's uid owns a segment, and only
root or that uid may attach it. Synchronise with `Mutex` / `futex_*` on
a word inside the segment.

---

## 3. The syscall ABI

One entry point: the **`ecall`** instruction from S-mode (user) into
S-mode (kernel), trap cause `SCAUSE_ECALL` (8).

### 3.1 Register convention

| register | on entry | on return |
| --- | --- | --- |
| `a3` | **syscall number** | (clobbered) |
| `a0` | arg 0 | return value |
| `a1` | arg 1 | (some calls: a second return, e.g. `SYS_EXEC` argv base) |
| `a2` | arg 2 | — |
| `a4` | arg 3 (4-arg calls) | — |
| `a5` | arg 4 (5-arg calls) | — |

`a3` holds the syscall number (not `a7`, which the SBI convention uses),
so a "4th argument" spills to `a4` and a "5th" to `a5`. The trap handler
saves the full `Trap_frame` (`src/entry.c3`), runs `handle_syscall()`
(`src/syscalls.c3`), writes the result into the frame's `a0`, and `sret`s.

The C3 wrappers in `user/user.c3`:

```c3
fn int  syscall (long n, long a0, long a1, long a2);              // → a0 truncated to int
fn long syscall_long(long n, long a0, long a1, long a2);          // → full 64-bit a0
fn int  syscall4(long n, long a0, long a1, long a2, long a3);
fn int  syscall5(long n, long a0, long a1, long a2, long a3, long a4);
```

All args are `long` (64-bit) — c3c's block-form asm requires
register-width locals on a 64-bit target. Cast pointers with `(long)`.

### 3.2 Error convention

Almost every call returns `int`: `>= 0` on success, `-1` on failure.
Blocking calls that can be aborted (peer died, etc.) also return `-1`.
There is **no `errno`** — the return value is all you get. A few calls
return a pid (`> 0`) or a count (`>= 0`); `SYS_MAP` returns a `long`
address or `-1`.

### 3.3 Pointer validation

The kernel validates every user pointer/length a syscall touches with
`user_range_valid(page_table, addr, len, need_write)` — a walk of the
caller's own page table checking `PAGE_U` and (if writing) `PAGE_W`. A
bad pointer fails the call with `-1`; it does not fault the kernel.

---

## 4. Syscall reference

Numbers are stable within a build but not across the project's history.
`4` and `5` are retired (`SYS_READFILE`/`SYS_WRITEFILE`, removed when
`fsd` took over file access).

Driver-only calls (`SYS_*_INFO`, `SYS_KBD_PUSH`, `SYS_DRIVER_IRQ_*`,
`SYS_DISK_ARENA_INFO`) check the caller's pid against the registered
driver and return `-1` to anyone else — they are listed for
completeness but only the matching server can use them.

### Process & scheduling

| # | name | args → return | notes |
| --- | --- | --- | --- |
| 3 | `SYS_EXIT` | `a0` = code → *never returns* | frees pages, wakes joiners |
| 11 | `SYS_RFORK` | `flags, gen_out*, stdout_pipe, stdin_pipe` → child pid / 0 / -1 | `RFPROC` required; `RFMEM` shares AS; `RFNOTEG` new note group |
| 13 | `SYS_JOIN` | `pid, generation` → exit code / -1 | blocks until that instance is gone; -1 + `interrupted()` on a note |
| 24 | `SYS_EXEC` | `image*, image_len, argv_len, _, argc` → -1 / *redirects* | ELF64 or flat; argv blob after image |
| 27 | `SYS_YIELD` | — → 0 | give up the rest of this slice |
| 25 | `SYS_SETUID` | `new_uid` → 0 / -1 | only while uid == 0; permanent |
| 35 | `SYS_GETUID` | — → uid | |
| 50 | `SYS_GETPID` | — → pid | |
| 17 | `SYS_PROC_INFO` | `pid, state_out*, gen_out*, uid_out*` → 0 / -1 | any caller |
| 23 | `SYS_PARENT_INFO` | `pid, parent_gen_out*` → parent pid / 0 / -1 | for envd's env inheritance |
| 18 | `SYS_KILL` | `pid, expected_generation` → 0 / -1 | root or same-uid; gen 0 = wildcard |
| 15 | `SYS_FUTEX_WAIT` | `addr*, expected` → 0 / -1 | block while `*addr == expected` |
| 16 | `SYS_FUTEX_WAKE` | `addr*` → woken count | wake all waiters on `addr` in this AS |
| 58 | `SYS_PROC_STAT` | `slot(1..64), buf*(≥52)` → 0 / -1 | state/uid/gen/pages/pid/name — `ps`, `top` |

### Notes

| # | name | args → return | notes |
| --- | --- | --- | --- |
| 61 | `SYS_POSTNOTE` | `pid_or_group, is_group, msg*` → count / -1 | root or same uid per target; §2.7 |
| 62 | `SYS_NOTIFY` | `handler` → 0 | 0 = no handler (notes kill) |
| 63 | `SYS_NOTED` | `NCONT` / `NDFLT` → *resumes* / *dies* | leave the note handler |
| 64 | `SYS_INTERRUPTED` | — → 1 / 0 | was the last wait cut short by a note? (read-and-clear) |

### Console

| # | name | args → return | notes |
| --- | --- | --- | --- |
| 1 | `SYS_PUTCHAR` | `ch` → — | to `stdout_pipe` if set, else console |
| 69 | `SYS_WRITE` | `buf*, len` → bytes | a whole buffer to stdout, same routing as `SYS_PUTCHAR` — what `print`, libc `write(1,…)` and `std::io` use |
| 2 | `SYS_GETCHAR` | — → byte / -1 | **blocks**; serial and USB keyboard share one queue; `^C` becomes a note; -1 on EOF (pipe) or a note |
| 59 | `SYS_GETCHAR_NB` | — → byte / -1 | non-blocking; -1 if nothing waiting or stdin is a pipe |
| 48 | `SYS_STDIN_ISATTY` | — → 1 / 0 | 1 = console, 0 = pipe |
| 36 | `SYS_BOOT_QUIET` | `a0` → 0 | shell calls it (a0=0) after a settle delay to drop later boot-server console output; a0=1 (`loud`) restores it |
| 57 | `SYS_KLOG_READ` | `buf*, max, cursor*` → count | kernel console log ring — `dmesg` |
| 31 | `SYS_KBD_PUSH` | `byte` → 0 / -1 | *usbd only*: inject a decoded keystroke |

### IPC

| # | name | args → return | notes |
| --- | --- | --- | --- |
| 6 | `SYS_IPC_SEND` | `dest, type, data*, len` → 0 / -1 | queues FIFO for a busy inbox; blocks until delivered **and** consumed |
| 7 | `SYS_IPC_RECV` | `buf*, len, type_out*` → sender pid / -1 | **blocks** |
| 19 | `SYS_IPC_RECV_GEN` | `buf*, len, type_out*, from_gen_out*` → sender pid / -1 | + sender generation |
| 20 | `SYS_IPC_REPLY` | `dest, type, data*, len, expected_gen` → 0 / -1 | send + stale-pid guard |
| 10 | `SYS_IPC_POLL` | `buf*, len, type_out*` → sender pid / -1 | non-blocking recv; `len < 0` drains only a pending IRQ notice, never a message |
| 34 | `SYS_IPC_CALL` | `dest, verb, buf*, packed(req_len<<16 \| cap), reply_type_out*` → replier pid / -1 | one-shot RPC, all in kernel |
| 65 | `SYS_AWAIT` | `mask, timeout_ticks, pipes*, npipes(≤8)` → ready mask / -1 | wait for the first of: inbox, stdin, pipes, doorbell, a driver's IRQ, timeout, note |
| 68 | `SYS_WAKE` | `pid, generation` → 0 / -1 | ring a process's doorbell (`AW_WAKE`); root or same uid — the network link rings use it |

### Namespaces

| # | name | args → return | notes |
| --- | --- | --- | --- |
| 8 | `SYS_NS_RESOLVE` | `path*, prefix_len_out*` → server pid / 0 | legacy; prefer `NS_TRANSLATE` |
| 52 | `SYS_NS_TRANSLATE` | `path*, member_idx, out*, out_cap` → server pid / -1 | union-aware; writes server-relative path |
| 21 | `SYS_SRV_POST` | `name*` → 0 / -1 | post `current_proc` under a short name |
| 22 | `SYS_NS_MOUNT` | `prefix*, srv_name*` → 0 / -1 | bind a posted name at a prefix (this NS) |
| 26 | `SYS_NS_MOUNT_WAIT` | `prefix*, srv_name*, max_attempts` → 0 / -1 | mount, retrying until the name is posted |
| 12 | `SYS_NS_UNMOUNT` | `prefix*` → 0 / -1 | remove a mount by exact prefix |
| 46 | `SYS_NS_BIND` | `new_prefix*, source_path*, flags` → 0 / -1 | Plan 9 `bind`; `flags` 1 = union-add, 4 = create-here |
| 45 | `SYS_NS_LIST` | `buf*, max_records` → count | copy the mount table out (36 B/record) |

### Working directory

| # | name | args → return |
| --- | --- | --- |
| 37 | `SYS_CHDIR` | `abs_path*` (normalised, <100 B) → 0 / -1 |
| 38 | `SYS_GETCWD` | `buf*, cap` → len / -1 |

### Pipes

| # | name | args → return | notes |
| --- | --- | --- | --- |
| 39 | `SYS_PIPE` | — → id / -1 | allocate an anonymous pipe |
| 40 | `SYS_PIPE_SETOUT` | `child_pid, pipe_id` (-1 detaches) → 0 / -1 | |
| 41 | `SYS_PIPE_SETIN` | `child_pid, pipe_id` → 0 / -1 | |
| 42 | `SYS_PIPE_READ` | `id, buf*, max` → bytes (0 = EOF) | |
| 43 | `SYS_PIPE_WRITE` | `id, buf*, len` → bytes | |
| 44 | `SYS_PIPE_HOLD` | `id, as_writer, delta(±1)` → 0 / -1 | the shell claims an end it pumps itself |

### Memory

| # | name | args → return | notes |
| --- | --- | --- | --- |
| 47 | `SYS_MAP` | `nbytes` → base vaddr / -1 | fresh zero-filled RW, demand-paged, past the image |
| 66 | `SYS_SEGATTACH` | `name*, size` → vaddr / -1 | map a named shared segment, creating it if new (size 0 = existing only) — §2.8 |
| 67 | `SYS_SEGDETACH` | `vaddr` → 0 / -1 | unmap it; freed at the last detach |

### Introspection / misc

| # | name | args → return | notes |
| --- | --- | --- | --- |
| 49 | `SYS_TIMEBASE` | — → Hz | `time` CSR tick rate (10 MHz QEMU / 25 MHz Duo) |
| 51 | `SYS_EXEC_MAX` | — → bytes | largest image `SYS_EXEC` will install (1 MiB Duo / 32 MiB QEMU) |
| 53 | `SYS_PROF` | `buf*(≥32), reset` → 0 / -1 | 4×u64 odometer: ipc_calls, ipc_ticks, yields, switches |
| 54 | `SYS_PROF_HIST` | `buf*(512), reset` → 0 / -1 | per-syscall-number histogram (diagnostic) |

### Driver-only

`SYS_DEV_INFO` (60), `SYS_FS_PARTITION_INFO` (14),
`SYS_DRIVER_IRQ_ARM` (32), `SYS_DRIVER_IRQ_WAIT` (55),
`SYS_DISK_ARENA_INFO` (56) — hand a driver its DMA physical addresses,
or wait on an interrupt.

`SYS_DEV_INFO(out*, cap)` is the one syscall every hardware driver uses to
learn its DMA regions: it writes the physical base of each region the
caller's board device declared (`Dev_dma` list, `src/device.c3`) into
`out[]`, in declaration order, and returns the region count — or -1 for a
process that owns no device (the shell, an `rfork` child) or a `cap` over
4. The kernel allocated and identity-mapped those regions at spawn time
(`device_setup()`), so the returned number is both the driver's pointer and
the address the device's DMA engine needs. `SYS_DISKD_INFO` (9),
`SYS_USBD_INFO` (28), `SYS_NETD_INFO` (29), `SYS_ETHD_INFO` (30) and
`SYS_SDD_INFO` (33) were folded into it and are unused numbers; `user.c3`'s
`diskd_info` / `usbd_info` / `netd_info` / `ethd_info` wrappers still
exist, now over `dev_info`.

---

## 5. The userspace runtime library

`user/user.c3` is compiled into **every** program (see §9). It provides
the syscall wrappers plus higher-level helpers. Import nothing — it's
`module user` and your program is too. Everything below is a plain
function call.

### 5.1 Process control

```c3
fn void exit() @noreturn;
fn void exitcode(int code) @noreturn;
fn int  rfork(int flags, uint* generation_out);          // RFPROC / RFMEM / RFNOTEG
fn int  rfork_io(int flags, uint* gen_out, int stdout_pipe, int stdin_pipe);
fn int  exec(char* path, char* buf, uint buf_max, int notify_pid, char** argv, int argc);
fn int  exec_path(char* name, char* buf, uint buf_max, int notify_pid, char** argv, int argc);
fn int  threadcreate(void* func, void* arg, void* stack_top, uint* gen_out);
fn int  join(int pid, uint generation);
fn int  kill(int pid, uint expected_generation);
fn int  proc_info(int pid, uint* state_out, uint* generation_out, int* uid_out);
fn int  parent_info(int pid, uint* parent_generation_out);
fn int  setuid(int new_uid);
fn int  getuid();
fn int  getpid();
fn int  proc_stat(int slot, char* out52);                // ps/top: see §4
fn void yield();
fn uint exec_max();
fn ulong rdtime();                                        // the `time` CSR
fn ulong timebase_hz();                                   // SYS_TIMEBASE
```

Notes (§2.7):

```c3
fn int  notify(void* handler);                 // handler(char* msg); 0 = none
fn void noted(int how);                        // NCONT / NDFLT — ends the handler
fn int  postnote(int pid, char* msg);          // 1 / -1
fn int  postnote_group(int group, char* msg);  // count / -1
fn bool interrupted();                         // last wait cut short by a note?
```

`rdtime()` + `timebase_hz()` is the only clock. For a delay:

```c3
ulong deadline = rdtime() + timebase_hz() * 2;   // ~2 seconds
while (rdtime() < deadline) { yield(); }
```

### 5.2 Console I/O

```c3
fn void putchar(char ch);
fn int  getchar();                 // blocks
fn int  getchar_nb();              // -1 if nothing waiting
fn int  stdin_is_console();        // 1 console / 0 pipe
fn void print(char* s);            // NUL-terminated
fn void print_uint(uint n);
fn void print_hex8(uint v);
fn void print_hex32(uint v);
fn int  klog_read(char* out, int max, ulong* cursor);   // dmesg
```

`getchar()` returns -1 on a pipe's EOF, or when a note cuts the wait
short (`interrupted()`).

To wait on more than one thing — the inbox, stdin, some pipes, a
timeout — use `await_any` (`SYS_AWAIT`):

```c3
fn int await_any(uint mask, ulong timeout_ticks, int* pipes, int npipes);
// mask: AW_MSG | AW_STDIN | AW_WAKE | AW_IRQ; pipes[i] is bit AW_PIPE0 << i;
// timeout 0 = none; returns everything ready now — AW_TIMER / AW_NOTE are
// reported unasked
fn int wake(int pid, uint generation);   // ring pid's doorbell (AW_WAKE)
fn int write_stdout(char* buf, int len); // SYS_WRITE
```

It consumes no message, keystroke or pipe bytes: follow it with
`ipc_recv`, `getchar` or `pipe_read`, which then won't block. `AW_WAKE`
(a `wake()` doorbell) and `AW_IRQ` (an interrupt-driven driver's device
completion) *are* consumed by being reported — there is nothing to follow
up with. A wait that needs no polling (no stdin or pipes in the mask)
sleeps: the timeout is a real timer deadline, not a spin. The C library's
`poll()` is built on it.

(Real-stdlib programs — see §9.2 — use `std::io::print` / `io::printfn`
instead; those route to the same console.)

### 5.3 Synchronisation

```c3
struct Mutex { int state; }
fn void Mutex.lock(&self);
fn void Mutex.unlock(&self);
fn int futex_wait(int* addr, int expected);
fn int futex_wake(int* addr);
```

`Mutex` is a futex-backed sleeping lock — safe to hold across a
`yield()` or a blocking syscall. Meaningful between threads (`RFMEM`)
and between processes sharing a segment:

```c3
fn char* segattach(char* name, ulong size);   // null on failure — §2.8
fn int   segdetach(char* addr);
```

(A futex wakes waiters in the *same address space*, so across separate
processes `Mutex` degrades to spinning with `yield()` between tries —
correct, just not asleep.)

### 5.4 Raw IPC

```c3
fn int ipc_send(int dest_pid, uint type, char* data, int len);
fn int ipc_recv(char* buf, int len);                                   // → sender pid
fn int ipc_recv_type(char* buf, int len, uint* out_type);
fn int ipc_recv_type_gen(char* buf, int len, uint* out_type, uint* out_from_generation);
fn int ipc_reply(int dest_pid, uint type, char* data, int len, uint expected_generation);
fn int ipc_poll_type(char* buf, int len, uint* out_type);              // non-blocking
fn int ipc_call(int dest_pid, uint verb, char* buf, int req_len, int buf_cap, uint* reply_type_out);
```

### 5.5 The 9P client

```c3
fn int p9_attach(int dest_pid, uint fid);
fn int p9_walk(int dest_pid, uint fid, uint newfid, char* name);
fn int p9_open(int dest_pid, uint fid);
fn int p9_read(int dest_pid, uint fid, uint offset, uint count, char* buf_out);
fn int p9_write(int dest_pid, uint fid, uint offset, char* data, uint count);
fn int p9_create(int dest_pid, uint fid, char* name, uint perm);   // P9_DMDIR in perm = dir
fn int p9_remove(int dest_pid, uint fid);
fn int p9_clunk(int dest_pid, uint fid);
```

### 5.6 Namespaces

```c3
fn int ns_resolve(char* path, uint* out_prefix_len);      // → server pid / 0
fn int ns_translate(char* path, int member, char* out, int out_max);  // union-aware
fn int srv_post(char* name);
fn int ns_mount(char* prefix, char* srv_name);
fn int ns_mount_wait(char* prefix, char* srv_name, ulong max_attempts);
fn int ns_unmount(char* prefix);
fn int ns_bind(char* new_prefix, char* source_path);
fn int ns_bind_flags(char* new_prefix, char* source_path, uint flags);
fn int ns_list(char* out_buf, int max_records);
```

### 5.7 Filesystem (the common path)

```c3
fn int fs_read(char* path, char* buf, int len);                      // whole small file
fn int fs_read_at(char* path, char* buf, int len, uint offset);
fn int fs_write(char* path, char* buf, int len);                     // create/truncate
fn int fs_write_at(char* path, char* buf, int len, uint offset);     // offset FS_OFFSET_APPEND = append
fn int fs_stat(char* path, uint* out_size, int* out_type);           // type 0 file / 1 dir
fn int fs_type_of(char* path);   // backend serving path: FS_TYPE_FAT32/EXT2/EXFAT, or -1
fn int fs_list(char* dir, char* out_buf, int max_entries);           // 36-byte records, paged
fn int fs_mkdir(char* dir);
fn int fs_delete(char* path);
fn int fs_delete_recursive(char* path);
fn int fs_rename(char* old, char* new);                              // refuses to overwrite
fn int fs_chmod(char* path, uint mode);                              // ext2 only
fn int fs_chown(char* path, uint uid);                               // ext2 only, root only
fn void fs_abspath(char* rel, char* out);                            // cwd-relative → absolute, normalised
fn int chdir(char* abs_path);
fn int getcwd(char* buf, int cap);
```

All paths are resolved through your namespace and prepended with your
cwd if not absolute. `fs_list` records: 32 bytes NUL-terminated name,
1 byte type (0 file / 1 dir), padding to 36.

### 5.8 User database

```c3
fn int user_uid_by_name(char* name);            // reads /adm/users → uid / -1
fn int user_name_by_uid(int uid, char* out, int out_cap);
```

`/adm/users` is `uid:name` lines, one per user. `0:root` always.

### 5.9 MMIO (drivers only)

```c3
fn void* map_pages(uint nbytes);      // SYS_MAP wrapper
fn uint  mmio_read32(uptr addr);
fn void  mmio_write32(uptr addr, uint v);
fn void  panic(char* prefix, char* msg);   // print + exit
```

A driver gets its device pages identity-mapped by the kernel at spawn
and learns the physical base via its `*_INFO` syscall; `mmio_*` then
work on those addresses.

---

## 6. IPC and the 9P-style protocol

### 6.1 The inbox

Every process has **one** inbox slot (`Process.msg_data`, `MSG_MAX` =
8192 bytes). `ipc_send` blocks until (a) the target's slot is free and
(b) the target has actually consumed the message — a true two-sided
rendezvous, never a silent overwrite. `ipc_recv` blocks until something
arrives.

Senders that find the slot busy **queue in arrival order** and sleep
(`Process.ipc_q_*`): only the head of the queue may deposit, and the
queue is woken each time the slot frees up. The one exception is a
server's reply to a client in `ipc_call`, which never waits behind that
client's other mail (the client's inbox is reserved for it). A server
still handles one request at a time — the queue makes the waiting fair
and cheap, not parallel.

A message carries a **type** (`uint`, application-defined) and a byte
payload. Types are just conventions; the kernel doesn't interpret them.

### 6.2 SYS_IPC_CALL — the RPC primitive

`ipc_call(dest, verb, buf, req_len, buf_cap, reply_type_out)` does the
whole request/reply in the kernel:

1. Copy `req_len` bytes of `buf` out.
2. Deliver to `dest` with type `verb`.
3. Block for `dest`'s reply, which **cannot be pre-empted** by a stray
   third-party `ipc_send` (the inbox is reserved for the reply).
4. Copy up to `buf_cap` reply bytes back into `buf` (in place).
5. Return the replier's pid, or `-1` if `dest` never existed / exited /
   was killed at any point.

This is what every `p9_*` and `fs_*` helper is built on. A server's side
is the classic loop:

```c3
char[FS_MSG_MAX] buf @noinit;
for (;;) {
    uint verb; uint from_gen;
    int from = ipc_recv_type_gen(&buf, FS_MSG_MAX, &verb, &from_gen);
    if (from <= 0) continue;
    // ... handle `verb`, fill `buf` with the reply ...
    ipc_reply(from, verb, &buf, reply_len, from_gen);
}
```

`from_gen` / `ipc_reply`'s `expected_generation` close the window where
the requester exits and its pid is reused before the reply lands.

### 6.3 The 9P verbs

Two families (`user/user.c3`):

**Toy pair** (kept for old tests): `P9_TWALK` (1), `P9_TREAD` (2).

**Real fids**: `P9_ATTACH` (3) → root fid, `P9_WALK` (4) one path
element, `P9_OPEN` (5), `P9_READ` (6) offset-based, `P9_WRITE` (9)
pwrite-style (no holes past EOF), `P9_CREATE` (8) (`P9_DMDIR =
0x80000000` in `perm` → directory), `P9_REMOVE` (10), `P9_CLUNK` (7).

`echod` (`user/sys/echod.c3`) is a minimal server that implements the
real fid set against a tiny synthetic in-memory tree — read it as the
reference for writing a server.

### 6.4 Interrupt-driven drivers

A driver registers its PLIC source in the kernel's `Irq_route` table
(via its `setup_*_mappings`). When the source fires, `handle_trap`
disables it (level-triggered) and posts `DISKD_IRQ_NOTIFY`
(`0xFFFFFFFF`) as a *separate* pending flag (not the inbox). The driver
either polls it (`ipc_poll_type`) or blocks on `SYS_DRIVER_IRQ_WAIT`,
handles the device, then re-arms with `SYS_DRIVER_IRQ_ARM`.

---

## 7. Namespaces

### 7.1 The model

Every process has a **mount table**: `namespace[16]`, each entry a
`(prefix, server_pid, generation, target, flags)`. A path is resolved by
**longest-prefix match** against this table *before* any on-disk
directory is consulted. `create_process()` seeds an identical default
namespace into every new process:

| prefix | server | purpose |
| --- | --- | --- |
| `/srv/echo/` | echod | the IPC demo server |
| `""` (catch-all) | fsd | the root filesystem — matches anything not claimed above, absolute paths included |
| `/mnt/fs2/` | fsd #2 | second partition (dual-partition setups) |
| `/proc/` | procd | process control |
| `/env/` | envd | per-process environment variables |

There is **no inheritance across `rfork`** in the sense that matters —
every process gets the same default table (there is no `fork` namespace
copy semantics yet), but the table lives on the `Process` struct, so a
sandboxed process *could* get a restricted view without a redesign.

### 7.2 post + mount

Plan 9's two-step:

1. A server calls `srv_post("name")` — registers itself in the global
   `srv_table` under a short name.
2. Anyone calls `ns_mount("/prefix/", "name")` — looks the name up and
   adds a `(/prefix/ → that pid)` entry to **its own** namespace.

`ns_mount_wait` retries until the name appears — used at boot when the
mounter races the poster (`mountusb` waits for `usbd` to post
`/srv/usb/`).

### 7.3 bind & unions

`ns_bind("/new/", "/existing/path")` binds *whatever currently serves
`/existing/path`* at `/new/` — the source-is-a-path counterpart of
mount. `ns_bind_flags` adds:

- flag `1` — **union add**: several entries share one prefix; search
  order is array order. `ls /bin` then lists all members, deduped.
- flag `4` — **create here**: in a union, this member receives file
  creation (Plan 9's `bind -c`).

At login the shell does `ns_bind_flags("/bin/", "/usr/$user/bin", 1|4)`
so a user's own compiled programs run by bare name without `/bin` itself
being writable.

### 7.4 ns_translate

The modern resolver. `ns_translate(path, member_index, out, out_max)`
writes the **server-relative** path for union member `member_index` into
`out` and returns the serving pid, or `-1` past the last member. Every
`fs_*` helper loops it:

```c3
for (int m = 0; ; m++) {
    char[FS_XLATE_MAX] sub @noinit;
    int fsd_pid = ns_translate(path, m, &sub[0], FS_XLATE_MAX);
    if (fsd_pid < 0) break;
    // p9/FS_* call fsd_pid with &sub[0]
}
```

---

## 8. The filesystem interface

`fsd` (`user/fs/fsd.c3`) is the filesystem server. It speaks **both**
the 9P verbs and a flatter **`FS_*` request/reply protocol** that the
`fs_*` helpers use. Three backends behind one dispatch table: **FAT32**
(`fat32.c3`), **ext2** (`ext2.c3`), **exFAT** (`exfat.c3`), all
read **and** write.

### 8.1 Topology

Plan 9-style, not Unix:

```
/            ext2 — the root on every board
/bin         executables (read off the fs by exec(), NOT embedded in the kernel)
/lib         wasm modules, fixtures, exec-adjacent data
/usr/$user   home directories (Plan 9 uses /usr, not /home)
/adm/users   the user database
/tmp         scratch
/mnt         where other filesystems / services mount
```

FAT32 is the **boot partition only** (the BootROM reads `fip.bin` out of
it). exFAT and extra ext2 partitions mount under `/mnt/`. There is **no
`/dev`** — devices are servers. There is **no `/etc`** — config lives in
`/adm` and `/usr/$user/lib`.

### 8.2 The FS_* wire protocol

All requests: byte `0..99` = path (`""` = root), NUL-terminated.
Replies: byte `0..3` = an `int` result (`-1` = error). `FS_MSG_MAX` =
8192.

| verb | # | request | reply |
| --- | --- | --- | --- |
| `FS_READ` | 20 | `100..103` = max len | `0..3` = length, `4..` = data |
| `FS_WRITE` | 21 | `100..103` = len, `104..` = data | `0..3` = written / -1 (create+truncate) |
| `FS_DELETE` | 22 | (recursive flag at `100`) | `0..3` = 0 / -1 |
| `FS_LIST` | 23 | `104..107` = start index | `0..3` = count, then N × 36-byte records |
| `FS_MKDIR` | 24 | — | `0..3` = 0 / -1 |
| `FS_RENAME` | 25 | `0..99` old, `100..199` new | 0 / -1 (refuses to overwrite) |
| `FS_READ_AT` | 26 | `100..103` max, `104..107` offset | as `FS_READ`; 0 = clean EOF |
| `FS_WRITE_AT` | 27 | `100..103` len, `104..107` offset, `108..` data | written / -1; `offset = 0xFFFFFFFF` = append |
| `FS_STAT` | 28 | — | `0..3` 0/-1, `4..7` size, `8` type (0 file / 1 dir), `9` backend (`FS_TYPE_*`: 1 FAT32 / 2 ext2 / 3 exFAT) |
| `FS_CHMOD` | 29 | `100..103` mode (low 12 bits) | 0 / -1 (ext2 only; owner-or-root) |
| `FS_CHOWN` | 30 | `100..103` uid | 0 / -1 (ext2 only; root only) |
| `FS_CACHE_STATS` | 31 | — | `0..7` hits, `8..15` misses (u64) |

Files bigger than one message use `FS_READ_AT` / `FS_WRITE_AT` in a
loop (`FS_MSG_MAX - 108 ≈ 8 KiB` per write call). `fs_list` pages: it
re-requests with an advancing start index until a short page returns.

### 8.3 Permissions

ext2 carries `i_uid` + mode bits and `fsd` enforces them: a write /
create / delete / mkdir checks the sender's uid (`fsd` asks the kernel)
against the inode owner and the `S_IWUSR` / `S_IWOTH` bits. FAT32 and
exFAT have no on-disk ownership, so `chmod`/`chown` return `-1` there.
`chmod` is owner-or-root; `chown` is root-only (you cannot give a file
away).

---

## 9. Writing a program

### 9.1 Anatomy

A Racccoon program is `module user`, provides `fn void main()` or
`fn void main(String[] args)`, and is linked with `user/user.c3` (the
runtime) at `USER_BASE`. There are **two build paths**, both in
`scripts/build_user.sh`.

### 9.2 Path A — nolibc (small, ~70–150 KiB)

For programs that just need syscalls and simple output. Pulls in the
freestanding `std::nolibc::{atomic,mem,fmt,main_stub}` pieces.

```c3
module user;

import std::nolibc::main_stub;   // makes plain `fn void main()` work

// hello.c3 — prints its arguments
fn void main(String[] args) {
    for (usz i = 0; i < args.len; i++) {
        if (i > 0) putchar(' ');
        for (usz k = 0; k < args[i].len; k++) putchar(args[i][k]);
    }
    putchar('\n');
}
```

`args` is a `String[]` — **`args[0]` is the first real argument**, not
the program name (the exec-time path is peeled off into
`main_stub_argv0`, exposed for the rare program that wants its own
`argv[0]`). Use `args[i][k]` / `args[i].len`. The slices point into the
exec blob and each *happens* to be followed by a NUL there, but treat
them as counted, not NUL-terminated: copy into a `char[N]` + NUL when a
`char*` API needs one, the way `user/bin/wc.c3` and friends do.

Build line (add to `build_user.sh`):

```sh
build_user_program hello user/user.c3 \
  $RACCCOON_STD_DIR/atomic.c3 $RACCCOON_STD_DIR/mem.c3 \
  $RACCCOON_STD_DIR/fmt.c3 $RACCCOON_STD_DIR/main_stub.c3 \
  user/bin/hello.c3
```

### 9.3 Path B — real stdlib (`std::io`, allocation; ~180 KiB)

For programs that want `io::printfn("%5d %s", …)`, `DString`,
`List(<T>)`, `String.to_int()`. Activates `--custom-libc=yes` and the
`user/std_racccoon/` shims (a `SimpleHeapAllocator` over `SYS_MAP`, a
hand-written `_start`, TLS + `.init_array` setup).

```c3
module user;

import std::io;

fn void main(String[] args) {
    int? n = args.len > 0 ? args[0].to_int() : 5;
    if (catch n) { io::printn("usage: countdown N"); return; }
    for (int i = n; i > 0; i--) io::printfn("%d...", i);
    io::printn("liftoff");
}
```

Build line:

```sh
build_user_program_stdio countdown $STDIO_COMMON user/bin/countdown.c3
```

`io::print` needs an explicit `(ZString)` cast for a plain `char*`
(otherwise it prints the pointer). Floats (`%f %e %g`), `DString`,
`List` all work. So do `io::stdin()` reads and `io::readline` (console
or the shell's pipe, through `SYS_GETCHAR`) and the temp allocator
(`tmem`, `@pool`). `fn int main` returns the exit code. Files go through
`user.c3`'s `fs_read_at` / `fs_write_at`: `file::open` and C `fopen`
are refused here (null / an error), and so is the libc `malloc` (use
`mem`).

### 9.4 c3 gotchas on this target

- `--safe=no` everywhere — no bounds checks, no `assert`.
- No multi-var-decl-with-init: `int a = 0, b = 0;` → split it.
- Local variables cannot start with an uppercase letter.
- `any`, `sz` are reserved type names.
- `if` / `else` around a single statement still need `{ }`.
- Switch cases don't fall through (consecutive empty `case X: case Y:`
  *do* share a body).
- `char` is **unsigned** 8-bit — no sign-extension when widening.
- Generic instantiation: `alias IntList = List{int};` (not `List(<int>)`
  in a `def`).
- `@naked` functions may return via `ret` in raw asm (`a0` by ABI).
- Big stack arrays overflow the 64 KiB stack fast — a `char[60000]`
  local will corrupt things silently. Use a file-scope global or
  `SYS_MAP`.

### 9.5 Wiring it in

1. Drop the source in `user/bin/`.
2. Add a `build_user_program[_stdio]` line to `scripts/build_user.sh`.
3. Add the name to the four `for u in …` loops in `scripts/build.sh`
   (they seed `/bin` into the QEMU images) and to `BINARIES=` in
   `scripts/populate_duo_bin.sh` (the real Duo).
4. `scripts/build.sh`, then run — the shell finds `/bin/hello` via
   `exec_path`.

Servers embedded in the kernel (not in `/bin`) instead need the name in
`KERNEL_SERVERS` (`scripts/lib_kernel.sh`, which every board's link step
uses), the `_binary_<name>_bin_*` externs + a `service_boot()` call in
`src/kernel.c3`, and — if they own hardware — a `DEVICES` entry in each
board that has it (see §12).

### 9.6 The build, end to end

`build_user_program` runs `c3c compile-only` (elf-riscv64, `rvimac`,
`--riscv-abi=double`), links with `ld.lld -T user/user.ld`, `objcopy -O
binary` to a flat image, then wraps it as a linkable `.bin.o` via
`llvm-mc` + `.incbin` (an `objcopy -Ibinary` wrapper has the wrong
soft-float `e_flags` and won't link against the hard-float kernel). The
kernel steps are shared by every board script (`scripts/lib_kernel.sh`):

1. `kernel_compile` — `c3c build <target> --emit-llvm` (LLVM IR, because
   c3c has no `--mcmodel`), then `llc -code-model=medium
   -relocation-model=static` per `.ll` — the default `small` model can't
   reach the kernel's link address on RV64.
2. `kernel_test_shell_obj` (QEMU always; boards with `DUO_TEST_SHELL=1` /
   `OPI_TEST_SHELL=1`) — re-embeds `shell_test.bin` as the shell.
3. `kernel_link` — `ld.lld` the medany objects + the shell + every
   `KERNEL_SERVERS` `*.bin.o` + the board's linker script.

---

### 9.7 Path C — WebAssembly (WASI)

`/bin/wasm` runs standard **WASI preview1** modules, so a program written
for any POSIX-ish libc runs unchanged:

```
zig cc -target wasm32-wasi -Os -Wl,-z,stack-size=262144 prog.c -o prog.wasm
wasm prog.wasm args...          # exit status = the program's exit code
```

(`zig` bundles wasi-libc. The stack flag matters: zig's 16 MiB default is
over `/bin/wasm`'s linear-memory cap of 240 × 64 KiB pages, which keeps it
under the Duo's per-process heap. clang/wasm-ld default to 64 KiB, Rust to
1 MiB, so they're fine as is.)

What the shim provides (`user/bin/wasm.c3`, "WASI preview1" block):

| WASI | racccoon |
|---|---|
| args, environ | argv (argv[0] = the module path); `/env/*` as `NAME=value` |
| fd 0/1/2 | console or pipe (`getchar`/`putchar`): `echo x \| wasm prog.wasm` works |
| preopens | fd 3 = `/`, fd 4 = `.` (the shell's cwd), so relative paths honour `cd` |
| path_open, fd_read/write/seek/tell/close, fd_readdir, *filestat_get | an fd table over `fs_read_at` / `fs_write_at` / `fs_stat` / `fs_list` |
| path_create_directory / remove_directory / unlink_file / rename | `fs_mkdir` / `fs_delete` / `fs_rename` |
| clock_time_get | time since boot (no RTC yet, so `time()` ≈ 1970) |
| random_get, sched_yield, proc_exit | xorshift64, `yield`, `exitcode` |
| poll_oneoff | clock subscriptions wait (yielding), so `sleep`/`usleep`/`nanosleep` work; fd subscriptions report ready at once |
| anything else (sockets, fd_renumber, …) | returns `ENOSYS` (only if called) |

**setjmp/longjmp.** wasi-libc's `<setjmp.h>` needs the wasm
exception-handling proposal, which `/bin/wasm` doesn't implement. Build with
`-I lib/wasm/include` instead: that `setjmp.h` maps setjmp/longjmp onto
`racccoon.setjmp` / `racccoon.longjmp`, which the interpreter implements
itself. It keeps its call frames explicitly, so `longjmp` restores the
setjmp frame's depth, operand stack, locals and the C stack pointer.
Same C semantics as usual: non-volatile locals changed after setjmp are
indeterminate.

**Lua.** `/bin/lua` (a `#!` script) runs `/lib/lua.wasm`: Lua 5.4.7 from the
`third_party/lua` submodule, unmodified, built by `scripts/build_lua.sh`
with the flags above (LUA_USE_C89, the setjmp shim, `lib/lua/racccoon_stubs.c`
for `tmpfile`/`system`). `lua` is the REPL (`os.exit()` quits), and
`lua script.lua args` runs a script. error/pcall, coroutines, string/table/math
libs and io all work. `os.execute`, `io.tmpfile` and `io.popen` don't.
`luatest` checks it. One catch: the script forwards its arguments with rc's
`$*`, which re-splits on spaces, so a quoted `lua -e "a b"` arrives as two
words. For a multi-word `-e`, call `wasm /lib/lua.wasm -e "…"` directly.

**Profiling.** `wasm -p mod.wasm …` counts every executed opcode and prints
the top 25 at exit (about 20% slower while on).

Limits: no sockets, no file holes (writing past EOF fails), paths under 100
bytes, `getcwd()` inside the program reports `/` (wasi-libc's own emulated
cwd, though opens still use the real one). It's an interpreter, running pre-decoded code (branches resolved at load): in
QEMU, Lua's recursive `fib(22)` takes ~4 s (~500× native). The dev shell's `wasitest` runs
the fixtures in `test/wasm-src/*.c`.

### 9.8 Path D — C, C++ and LLVM (racccoon-libc, libc++)

**C.** `lib/racccoon-libc/` is a libc + POSIX layer: stdio, scanf, files
over the FS protocol (with `pread`/`pwrite` and file `mmap`), fork/exec,
sockets, `poll` on `SYS_AWAIT`, signals on notes (`signal`/`sigaction`),
`clock_gettime`/`nanosleep`, the "C" locale with the POSIX-2008
`locale_t` API, wide characters, and single-thread pthreads.
`lib/racccoon-libc/build.sh` builds it with `riscv64-unknown-elf-gcc`
(rv64imafdc, lp64d, medany) into `build/libc/crt0.o`, `crt0_mapped.o` +
`libracccoon.a` (and empty `libm.a`/`libpthread.a`/`librt.a` so the usual
`-lm -lpthread -lrt` link), and every `test/c-src/*.c` into a flat
`build/libc/<name>.bin`, which `scripts/build.sh` and `populate_duo_bin.sh`
seed as `/bin/<name>`.

- `crt0` sets `sp` (a 64 KiB stack in `.bss`) and `tp`, runs
  `.preinit_array`/`.init_array` before `main`; `exit()` runs the
  `atexit`/`__cxa_atexit` handlers (one LIFO table), then `.fini_array`.
  `crt0_mapped.o` is the same with an 8 MiB demand-paged stack from
  `SYS_MAP`, for big programs (the `.bss` stack is copied into the flat
  image, so it can't be large).
- `malloc` is **dlmalloc 2.8.6** (`src/rc_malloc.c` + the verbatim
  `src/dlmalloc.inc`), growing through `SYS_MAP`; memory is reused but
  never handed back to the kernel. `alloctest` checks the reuse.
- **libm is musl's** (1.2.5, the `third_party/musl` submodule, required):
  every `src/math/*.c` is compiled into `libracccoon.a`, the riscv64
  versions (hardware sqrt/fma/fmin/…) replacing the generic ones;
  `include/math.h` is musl's declarations (tcc-safe `INFINITY`/`NAN`).
  `long double` is binary128, done in software by libgcc. Float
  formatting (`%e %f %g %a`, with `L`) is musl's `fmt_fp` and
  `strtod`/`strtof`/`strtold` musl's `floatscan`, both exact and
  correctly rounded (`src/fmt_fp.inc`, `src/floatscan.c`). `mathtest`
  checks values, edge cases, classification and printf/strtod.
- The locale is "C" only: one byte per character, ASCII classes;
  `newlocale` refuses other names (ENOENT). Threads: one per program —
  mutexes count, `pthread_once`/keys work, `pthread_create` aborts, an
  untimed `pthread_cond_wait` aborts (nobody could signal it).
- `ftruncate` really grows (zero-fill) and shrinks (rewrites the kept
  prefix — the FS protocol has no truncate). Thread-locals (`.tdata` +
  `.tbss`) form the one thread's TLS block at `tp = __tls_start`; the
  linker script reserves `.tbss` so it can't overlap `.bss`.
- Honest gaps: no symlinks or extra hard links (`symlink`/`link` fail
  EPERM, `readlink` EINVAL), no ownership changes (`chown` EPERM), no
  dynamic loading (`dlopen(NULL)` only), no password database (`getpw*`
  find nothing), `alarm` never fires, `statvfs` reports block counts 0,
  shared writable file mappings fail (ENODEV), signals can't be masked.

tcc (`/bin/tcc`) compiles C on racccoon itself against the same library.

**C++.** `lib/racccoon-libc/build_cxx.sh` cross-builds static **libc++
+ libc++abi** (LLVM's) against racccoon-libc with the host clang, from
an llvm-project checkout at the tag matching that clang (`LLVM_SRC`,
default `~/Workspace/llvm-project`; skipped without one), then every
`test/cxx-src/*.cpp` into `build/libc/<name>.bin`:

```
clang++ --target=riscv64-unknown-elf -march=rv64imafdc -mabi=lp64d -mcmodel=medany \
  -std=c++20 -Os -g -fno-exceptions -fno-rtti -nostdinc++ -nostdinc \
  -isystem build/cxx/install/include/c++/v1 -isystem lib/racccoon-libc/include …
ld.lld --gc-sections -T lib/racccoon-libc/racccoon-libc.ld \
  build/libc/crt0.o prog.o build/cxx/install/lib/libc++.a build/libc/libracccoon.a libgcc.a
```

**No exceptions, no RTTI, no `<filesystem>`** (what LLVM builds with).
Threads, locale/iostreams and wide characters are on, over the libc's
single-thread pthreads and C locale (`_LIBCPP_PROVIDES_DEFAULT_RUNE_TABLE`
in `__config_site`). `random_device` needs `/dev/urandom`, which racccoon
doesn't have. Containers, strings, algorithms, `std::function`, smart
pointers, `optional`/`variant`, static constructors and destructors,
aligned `new` all work (`cxxtest`). A failed allocation or a broken
precondition aborts the program (exit 134). A C++ "hello" with a few
containers is ~120 KiB.

**CMake.** `lib/racccoon-libc/racccoon.cmake` is a toolchain file for
CMake projects (a `racccoon` platform module in `cmake/Platform/` sets
`UNIX`); every try-compile links for real against crt0_mapped +
libc++ + racccoon-libc, so configure checks see what the libc has.

**LLVM.** `lib/racccoon-libc/build_llvm.sh` configures LLVM itself from
`LLVM_SRC/llvm` with that toolchain (MinSizeRel, no threads/zlib/zstd/
terminfo/backtraces/plugins, the RISC-V target; tablegen = the host's
`llvm-tblgen`, which must be the same version) into `build/llvm-racccoon/`, and
links **`llvm-readobj` as `/bin/llvm-readelf`** (4.6 MiB; readobj picks
readelf mode from `argv[0]`), **`llc` as `/bin/llc`** (27.8 MiB, the
RISC-V backend: IR → assembly or objects) and **`lld` as `/bin/ld.lld`**
(32.3 MiB, flavor from `argv[0]`). Their output on racccoon is
byte-identical to the host's. A tool is relinked whenever libracccoon.a /
libc++.a / crt0_mapped.o / the linker script is newer. LLVM_SRC needs
`llvm/`, `lld/` and `libunwind/` (one of its headers) besides the runtimes.

The whole pipeline runs on racccoon — the images carry `/lib/racccoon/`
(`crt0.o`, `libracccoon.a`, `libgcc.a`, `racccoon-libc.ld`):

```
llc -mattr=+m,+a,+f,+d,+c -filetype=obj /hello.ll -o /hello.o
ld.lld -T /lib/racccoon/racccoon-libc.ld /lib/racccoon/crt0.o /hello.o \
       /lib/racccoon/libracccoon.a /lib/racccoon/libgcc.a -o /hello
/hello                     # an ELF: SYS_EXEC loads it directly
```

Tests: `llvmtest` (`llvm-readelf -h /bin/echod.elf`), `llctest` (the
object for `/hello.ll`, `test/llvm-src/hello.ll`, vs `/hello.ref.o`, the
host llc's), `lldtest` (the three steps above; the ELF vs `/hello.ref.elf`,
the host ld.lld's, and the program's output). Under QEMU llc takes ~5 s,
llc + ld.lld + run ~22 s. These need QEMU's 128 MiB exec cap
(`boards/qemu/board.c3`); the Duo's 4 MiB is too small.

**c3c.** `lib/racccoon-libc/build_c3c.sh` builds the C3 compiler itself
for racccoon — the normal LLVM backend and lld linked in — as `/bin/c3c`
(56.8 MiB). Source: `C3C_SRC` (default `~/Workspace/c3c-llvm`), upstream
v0.8.5 (the version that builds racccoon) plus the racccoon commits on the
fork's `racccoon-llvm` branch: no `/proc/self/exe`, the rv64 default
target, 128 MiB vmem arenas (`C3_SMALL_ARENAS`: reservations count
against the heap cap), `C3_LLVM_NO_THREADS`, and two reproducibility
fixes (sources collected in sorted order, not readdir order; a pointer
difference no longer depends on the C compiler's argument evaluation
order). Every LLVM target but RISC-V is `*_DISABLE`d. Its standard
library is `/lib/c3/std` (c3c finds it there by itself). It needs QEMU's
1.5 GiB heap cap.

```
c3c compile-only --target elf-riscv64 --single-module=yes prog.c3 -o prog.o
```

**racccoon builds its own kernel.** The images carry `/src/racccoon/`
— `project.json`, `src/`, `boards/`, the user programs the QEMU test
kernel embeds (`embed/*.bin.o`) and `selfbuild.rc`, which is
`lib_kernel.sh`'s compile + link done on racccoon:

```
. /src/racccoon/selfbuild.rc   # c3c build racccoon … -g0 → 19 .ll; llc each; ld.lld
```

→ `/src/racccoon/build/kernel.elf`, a bootable QEMU kernel. `selfbuildtest`
runs it (~6 min under QEMU) and checks the ELF is byte-identical to
`/src/racccoon-ref/kernel.elf`: `scripts/selfbuild_ref.sh` ran the same
steps on the host with the same c3c source built natively against the
host's LLVM of the same version. `-g0` because DWARF would carry the
different absolute source paths. `c3ctest` does the same for one small
file (`test/c3-src/c3ctest.c3`).

### 9.9 Debugging with gdb (QEMU)

```
scripts/launch64.sh -s                    # terminal 1: QEMU + gdb stub on :1234 (-S: stop at reset)
scripts/gdb_qemu.sh build/libc/cxxtest.elf   # terminal 2: host gdb, attached
(gdb) ubreak main cxxtest                 # break in main() only while `cxxtest` runs
(gdb) continue                            # …then run `cxxtest` in terminal 1
(gdb) bt / next / p s / curproc
```

`gdb_qemu.sh` loads `build/kernel.elf` plus one program's ELF (every
program links at `USER_BASE`, so one at a time; build it with `-g` for
source lines). A breakpoint on a user address fires in whichever process
runs that address, so `ubreak LOCATION NAME` filters by `Process.name`
(what `ps` shows), and `curproc` prints the pid and name on the CPU.
gdb doesn't know C3: kernel *types* aren't usable in expressions, but
symbols and line numbers are. The script reads `current_proc`'s address
and `Process.name`'s offset out of `kernel.elf` on every run, and reads
the kernel through QEMU's physical-memory mode (from a user-mode stop,
supervisor pages aren't readable virtually). QEMU's TCG stub keeps
breakpoints itself, so a user breakpoint never patches another process's
memory at the same address.

## 10. The shell

`rc`-flavoured. `shell_exec_block()` splits input into statements;
`shell_exec_line()` handles `;` `&&` `||`, `$var`, `|`, `<` `>`,
globbing.

### 10.1 Builtins (both shells)

`hello`, `echo`, `cd`, `pwd`, `exit`, `su <name>`, `login`,
`sandbox`, `break` / `continue`, `.` / `source <script>`,
`jobs` / `wait`, `mountusb` / `unmountusb`,
`namespace` (alias `ns`), `mount <srv> <prefix>`,
`bind [-a] [-c] <src> <dst>`, `unmount` / `umount`.

`shell_test.c3` (+ `shell_test_*.c3`) adds ~50 `*test` builtins plus `loud` (echo boot-server
output to the console), `kbdpush`, `synhist`, and profiling helpers.

### 10.2 Control flow

`#!`-style scripts (run by `. script` or by name — the shell interprets
them itself), `if` / `else`,
`for NAME in LIST`, `while`, `break`, `continue`. Command substitution:
`` `cmd` `` or `` `{cmd} ``. Shell-local variables: `NAME=value` (no
`export`; they're per-shell). `/bin/test`, `/bin/[`, `/bin/expr` back
the conditionals.

Globs (`*`, `?` in the last path component) expand in **byte order**, as
in rc and sh. A command line, its expansion or a glob that doesn't fit
the shell's buffers (1 KiB raw, 2 KiB expanded, 64 words, a glob's
matches) is refused with an error — never silently cut.

### 10.3 Line editing

`shell_readline_p` (`shell_common.c3`): arrows, Home / End (and
`ESC[H` / `ESC[F` / `ESC[1~` / `ESC[4~`), Del, mid-line Backspace,
`^K` `^U` `^W` `^D`, insert-anywhere with redraw, a 24-entry history
ring (up/down). `^A` / `^E` are eaten by `screen` and by QEMU's
`-serial mon:stdio`; the Home/End *keys* work.

### 10.4 Path resolution

**No `$PATH` list.** A bare name (`ls`) gets `/bin/` prepended; a name
with a `/` (`./foo`, `/bin/foo`, `sub/foo`) is literal, cwd-relative
unless it starts with `/`. `/bin` *is* the namespace (a union of the
real `/bin` and `/usr/$user/bin`), not one entry in a search path.

### 10.5 `^C`

`^C` posts the `"interrupt"` note to the shell's note group (§2.7):

- at the prompt it drops the line being typed (or a half-entered
  multi-line block);
- a foreground program without a note handler dies of it (status −1),
  including one stuck in a compute loop or blocked reading the console;
- a running `for` / `while` loop or `;` / `&&` sequence stops;
- background jobs (`cmd &`) keep running — they get their own note
  groups.

`note [-g] <pid> [msg]` (`/bin/note`) posts a note by hand (default
`interrupt`; `kill` always kills). `dmesg -f` and `top` still also quit
on any keystroke.

---

## 11. The servers

All are ordinary user processes spawned by `kernel_main()` and watched
by the supervisor (respawn on crash / wedge).

| server | source | role |
| --- | --- | --- |
| `echod` | `user/sys/echod.c3` | IPC demo + 9P reference implementation; `/srv/echo/` |
| `diskd` | `user/block/diskd.c3` | virtio-blk driver (QEMU) |
| `sdd` | `user/block/sdd.c3` + `sdhci.c3` | SDHCI + SDMA driver (Duo) |
| `fsd` | `user/fs/fsd.c3` + `fat32/ext2/exfat.c3` | the filesystem server; `""` catch-all + `/mnt/fs2/` |
| `procd` | `user/sys/procd.c3` | `/proc/<pid>/status`, `/proc/<pid>/ctl` (write `kill`) |
| `envd` | `user/sys/envd.c3` | per-process environment variables; `/env/` |
| `usbd` | `user/usb/usbd.c3` + `dwc2/kbd/xpad/msc.c3` | DWC2 host stack (Duo): hubs, HID, MSC |
| `ethd` | `user/net/ethd.c3` + `dwmac/ephy.c3` | DesignWare MAC + on-chip PHY (Duo) |
| `netd` | `user/net/netd.c3` | virtio-net (QEMU) — a link driver |
| `ipd` | `user/net/ipd.c3` + `ipd_conv.c3` + `ipd_tcp.c3` | the IP stack — ARP/IPv4/ICMP/UDP/TCP/DHCP; `/net/` (§11.2) |
| `gpiod` | `user/gpio/gpiod.c3` | the on-board LED (Duo) |

`ethd` and `netd` are pure link drivers: they move Ethernet frames
between the device and a link ring (`user/net/link.c3`); everything above
that is `ipd` (§11.2).

The block driver and `fsd` are the load-bearing pair: `fsd` re-resolves
the storage pid on an IPC failure, so a supervisor respawn into a new
slot is transparent.

### 11.1 The supervisor

`src/supervisor.c3`. Once per timer tick it checks every registered
service: exited → respawn; inbox stuck with no IPC progress for
`SVC_STALL_LIMIT` (5) ticks *and* it has reached its recv loop at least
once → kill + respawn. First boot and respawn share one path
(`service_instantiate`): a respawn re-runs `device_setup()` for the
server's device (fresh DMA regions, PLIC route overwritten in place),
keeps `storage_pid` (the one pid global left, handed to fsd) pointing at the
live storage driver, and reseats every live process's matching mount entry.
Gives up after `SVC_RESTART_LIMIT` (5).

**The default namespace comes from the service table.** Each boot service
registers the prefix it is mounted at (`service_boot(..., mount: "/proc/")`:
echod `/srv/echo/`, fsd `""`, fsd2 `/mnt/fs2/`, procd `/proc/`, envd `/env/`);
`seed_default_namespace()` (`supervisor.c3`, called from `create_process`) gives
a new process one mount per registered, currently-up service, in registration
order. A service that isn't up yet (or was never registered on this board) simply
isn't listed.

---

### 11.2 Networking (`/net`)

**Links.** A link driver creates a shared segment `ether<N>` (§2.8): a
header (MAC, link state, both pids) and two single-producer /
single-consumer rings of 32 × 2 KiB frame slots, RX (driver → ipd) and TX
(ipd → driver). The producer fills a slot, bumps an index and rings the
consumer's doorbell (`wake()`); nobody ever blocks on the other, and
frames never pass through the kernel. `ipd` attaches each `ether*` that
appears (a respawned driver re-attaches the same segment).

**ipd** runs a DHCP client per link, keeps an ARP cache, answers ARP and
ping, and has a loopback interface (127.0.0.1). It is one
single-threaded loop: requests, frames and timers are handled as they
come, and a read with nothing to return is parked — answered when data
arrives, or after ~1 s with −2 ("ask again", which `net_read` loops on),
so a slow reader never stalls the stack. TCP: in-order receive, go-back-N
retransmission with an RTT-estimated RTO (200 ms floor), 8 KiB buffers
each way, MSS 1460, no SACK / window scaling / Nagle / delayed ACK. Not
done: IP fragmentation (dropped; DF set), IPv6, multicast, routing beyond
"on-link or the default gateway".

**Files** (paths below `/net/`):

| file | |
| --- | --- |
| `ipifc/<n>/status` | name, mac, ip, mask, gw, dns, link and DHCP state, counters |
| `arp` | the ARP cache |
| `<udp\|tcp\|icmp>/clone` | read: allocate a conversation, returns its number |
| `<proto>/<n>/ctl` | write `connect a.b.c.d!port`, `announce [*!]port`, `bind port`, `headers`, `own`, `close` (tcp half-close), `hangup`; read: `<n>` |
| `<proto>/<n>/data` | the payload: stream bytes (tcp), datagrams (udp, icmp echo) |
| `<proto>/<n>/local`, `remote` | `a.b.c.d!port` |
| `<proto>/<n>/status` | `<proto> <n> <State> rx … tx …` |
| `tcp/<n>/listen` | read: wait for a connection on an announced conversation, returns its number |

A conversation belongs to the process that read its `clone` (or
`listen`) file — only that uid or root may use it — and is freed when that
process is gone or writes `hangup`. `headers` makes each udp datagram
carry the peer's address (4 bytes) and port (2) in front, so one
announced conversation can talk to many peers.

**From a program** (user.c3):

```c3
fn int dial(char* addr);              // "tcp!10.0.2.2!7", "udp!host!53", "icmp!host" — names via DNS
fn int announce(char* addr);          // "tcp!*!23"
fn int net_listen(int h);             // tcp: the next connection
fn int net_read(int h, char* buf, int len);   // waits; 0 = end of stream
fn int net_read1(int h, char* buf, int len);  // one try: NET_RETRY after ~1 s
fn int net_write(int h, char* buf, int len);
fn int net_ctl(int h, char* cmd);
fn void hangup(int h);
fn bool dns_resolve(char* name, uint* ip);
```

C programs get BSD sockets (`<sys/socket.h>`, `<netinet/in.h>`,
`<arpa/inet.h>`, `<netdb.h>`; `lib/racccoon-libc/src/rc_socket.c`):
`socket`/`bind`/`listen`/`accept`/`connect`/`send`/`recv`/`sendto`/
`recvfrom`/`shutdown`/`getsockname`/`getpeername`, `inet_*`,
`getaddrinfo` (numeric, `localhost`, DNS). A socket fd is a conversation;
`close()` hangs it up — including in a `fork`ed child that inherited it,
since there are no shared fd references. `poll()` reports sockets as
always ready.

**Tools:** `ping [-c n] host`, `nc [-u] [-N] host port` / `nc [-u] -l
port` (`-N` sends the FIN at the end of stdin), `dnsq name…`, `rshd
[port]` — a remote shell (`/bin/rc`, the production shell, login prompt
included) on TCP 23; a `^C` from the client interrupts the remote
command.

## 12. Board abstraction & porting

`module board` is the **only** platform seam. Every `boards/<name>/board.c3`
(`qemu`, `duo`, `opi-rv`, `opi-rv-qemu`) exports the same set of names; the kernel and
servers `import board` and never `#ifdef`.

What a board provides:

- **PLIC** placement — three constants: `PLIC_PHYS_BASE` (physical),
  `PLIC_BASE` (the virtual address the kernel uses once paging is on;
  identity on real boards, aliased to `0x7a000000` on QEMU virt) and
  `PLIC_S_CONTEXT` (1 on QEMU virt/Duo, 2 on the JH7110/sifive_u). The driver
  itself — register formulas, `plic_init` (threshold only), `plic_arm`,
  `plic_claim`/`plic_complete`/`plic_set_enabled`, and `map_plic(page_table)` —
  is shared, in `src/plic.c3`. **Which sources get armed at boot is data**: a
  `Device` with `irq_armed` in `DEVICES` (`plic_arm_devices()`, `device.c3`).
- **PTE bits** — `PTE_DEVICE_BITS` (the Duo needs bit 63 set for
  strong-ordered MMIO; getting this wrong caused the "PLIC storm").
- **`DEVICES`** — a `Device[]` table (type in `src/device.c3`), one entry
  per piece of driver-owned hardware the board has: `name` (`"sd"`,
  `"usb"`, `"eth-mac"`, `"gpio"`, `"virtio-blk"`, `"virtio-net"`), the
  page-aligned `mmio` pages the driver needs, its PLIC `irq` and
  `irq_level`, and its `dma` regions (`pages` + `cached`; real bus masters
  must be `cached = false`). `kernel_main` spawns a driver only if
  `device_find(name)` finds its entry, so a board with no entry (the
  Orange Pi RV scaffold: an empty table) just doesn't run that driver.
  Adding hardware is a new table entry — no kernel function, no new
  syscall.
- **`HAS_SECOND_FS_PARTITION`** — whether a second `fsd` is spawned (this
  is filesystem layout, not a device).
- **`FS_PARTITION_START_SECTOR`** — where the ext2 root lives
  (`2099200` on the Duo card, `0` on the QEMU whole-disk image).
- **`TIMEBASE_HZ`** (10 MHz QEMU / 25 MHz Duo), **`SMP_MAX_HARTS`** (8),
  **`EXEC_MAX_IMAGE_SIZE`** (32 MiB QEMU / 1 MiB Duo),
  **`HEAP_MAX_BYTES`** (1.5 GiB QEMU / 16 MiB Duo).
- **`console_putchar` / `console_getchar`** — both currently route to
  the SBI legacy calls.

A third target (JH7110 / Orange Pi RV) has a Stage-0 scaffold on a
branch. The porting philosophy is: read the vendor's real Linux driver
and rootfs bring-up scripts, not just the datasheet.

Sv39, one hart. The Duo's second C906 core has no MMU and is not a
target. SMP has a scaffold (per-hart control block, spinlocks) but the
real multi-hart scheduler is parked until a 4-core board is in hand.

---

## 13. Building, running, flashing

### 13.1 Prerequisites

`c3c`, an LLVM toolchain (`llc`, `ld.lld`, `llvm-objcopy`, `llvm-mc`),
`qemu-system-riscv64`, and image tools (`dosfstools`, `mtools`,
`e2fsprogs`, `exfatprogs`). If the LLVM tools aren't under `/opt/riscv`
on `PATH`, pass them: `LLVM_LLD=… LLC=… LLVM_OBJCOPY=… scripts/build.sh`.

### 13.2 QEMU

```sh
scripts/build.sh                 # kernel + user programs + all disk images
scripts/launch64.sh              # boot, FAT32 root
scripts/launch64_ext2.sh         # ext2 root
scripts/launch64_dual.sh         # FAT32 boot + ext2 root, two partitions
scripts/launch64_exfat.sh        # exFAT
scripts/launch64_smp2.sh         # -smp 2 (scaffold only)
scripts/launch64_serialraw.sh    # -serial stdio, no monitor mux (raw control chars)
```

Each `launch*` boots a throwaway copy of the disk image so writes don't
accumulate between runs.

### 13.3 Milk-V Duo

```sh
DUO_SD_PART=/dev/sdX1 scripts/reflash_duo.sh
```

Repackages the `fip.bin` already on the SD card's `DUOBOOT` partition
(reusing its FSBL / OpenSBI via `fiptool --OLD_FIP`) and swaps in the
new kernel. **No sudo, no vendor SDK build** — needs only a
`duo-buildroot-sdk` checkout for `fiptool.py`. Keeps one rollback copy
as `fip.bin.bak-<timestamp>`. `PATCH_OPENSBI=1` also rebuilds OpenSBI
with the T-HEAD PLIC delegate fix (required for interrupt-driven
drivers).

`/bin` on the Duo's ext2 partition is seeded separately —
`sudo DUO_ROOT_PARTITION=/dev/sdX2 scripts/populate_duo_bin.sh`, or
copy the `build/user/*.bin` files onto the mounted partition by hand if
`/bin` is user-owned.

### 13.4 Testing

Correctness is a regression suite of `shell_test.c3` builtins run in
QEMU (`runtest`, `wasmtest`, `killtest`, `rforktest`, `oomtest`,
`fsdkilltest`, `hungservertest`, `maptest`, `threadtest`, …), plus the
hardware paths on a real Duo. There is no unit-test framework and no
`assert` (`--safe=no`). The [devlog](devlog.md) records every session.

---

## 14. Limitations

Deliberate or just not done — the honest list:

- **No stable ABI.** Syscall numbers and wire formats change freely.
- **Notes, not POSIX signals.** One handler per process, string
  messages, no masks, no `^Z` / `fg` / `bg` (job control is `&`, `jobs`,
  `wait`). Go programs don't install a handler, so `^C` just kills them.
- **No `mmap` of files.** All file data moves through 8 KiB IPC
  messages; shared memory is named segments only (§2.8), at most 4 MiB
  each, 16 at a time.
- **One request at a time per server.** Senders queue fairly, but a
  server still processes one message at a time, and a client has one
  request in flight (no tagged pipelining).
- **64 processes total.**
- **One hart.** SMP is a scaffold.
- **No swap, no overcommit accounting beyond the per-process
  `HEAP_MAX_BYTES` cap.**
- **`fs_read` / `p9_*` against a server that isn't serving yet** (e.g.
  mid-respawn) waits up to the 15 s `SYS_IPC_CALL` timeout, then fails
  with -1. Clients paper over boot with settle delays.
- **The filesystem backends read/write "as much as fits"** rather than
  erroring on a too-deep indirect block.
- **exFAT / FAT32 have no ownership**; `chmod`/`chown` only work on
  ext2.
- **The network stack is small** (§11.2): IPv4 only, no fragmentation,
  no SACK or window scaling, one interface route. Sockets don't share
  references across `fork` (a child's `close()` hangs up the parent's
  connection too), and `poll()` can't wait on a socket.
- **Wi-Fi is open or WPA2-Personal (CCMP) only.** The Duo's network is a
  USB RTL8192EU adapter (TP-Link TL-WN823N), driven from inside usbd
  (`user/usb/rtl8192eu.c3`, the supplicant in `rtl_wpa.c3`, firmware in
  `/lib/firmware/`).
  - Commands: `wifi scan|list|status|leave`, `wifi join SSID [PASSPHRASE]`,
    and `wifi save SSID [PASSPHRASE]`.
    - `/bin/wifi` computes the PMK itself.
    - `save` stores the SSID and the hex PMK in `/adm/wifi` (mode 0600).
      usbd joins that network after its first scan at boot.
  - Once associated, the link is `ether1`, and ipd runs DHCP on it.
  - The chip does CCMP itself, using keys from the 4-way and group-key
    handshakes.
  - Refused:
    - TKIP (incl. a WPA/WPA2 mixed-mode group cipher);
    - WPA3/SAE and required management frame protection;
    - Enterprise.
  - Fixed 1/11 Mb/s rates, no rate adaptation or power saving.

  The Duo's own Ethernet MAC can report a carrier with no cable plugged in.
  ipd then retries DHCP on `ether0` forever, which is harmless.
- **C/C++ run single-threaded, in the "C" locale** (§9.8): C++ has no
  exceptions, RTTI or `<filesystem>`; `pthread_create` aborts.
- Not audited, not hardened. "It boots on my Duo" is the bar for the
  hardware paths.

---

## 15. Appendix: source map

```
src/
  entry.c3          trap entry, Trap_frame, timer, external IRQs, lazy faults,
                    handle_trap
  syscalls.c3       SYS_* consts, handle_syscall + the sys_* layer (exec/rfork,
                    IPC, namespaces, futex, ...)
  process.c3        Process struct, scheduler, create_process, context switch,
                    fork_entry, setup_fsd_mappings
  device.c3         Device / Dev_dma types, device_setup(): a board device
                    table -> MMIO maps + DMA regions + PLIC route
  page.c3           Sv39 map_page / map_device_page / walk
  allocation.c3     physical page bitmap allocator
  kernel.c3         boot(), kernel_main(), the server spawn sequence
  supervisor.c3     service_boot() + the respawn watchdog
  pipe.c3           anonymous kernel pipes
  kbd.c3            the keystroke queue the console + a USB kbd feed SYS_GETCHAR
  note.c3           notes: post / deliver / noted, note groups, console ^C
  segment.c3        named shared segments (SYS_SEGATTACH / SEGDETACH)
  smp.c3            hart scaffold (parked)
  spinlock.c3       Stage-B locks
  virtio.c3         shared virtio-mmio helpers (kernel side, minimal)
  kernel/sbi.c3     the SBI calls + the 32 KiB dmesg log ring
  kernel/panic.c3   panic()
  libc/libc.c3      the kernel's own freestanding libc shims
  std/…             kernel's std::io / std::core::mem overrides (@feat(CUSTOM_LIBC))
  kernel.ld         kernel linker script (medany, load at 0x80200000)

boards/
  qemu/board.c3     QEMU virt: PLIC, virtio, 10 MHz timebase
  duo/board.c3      CV1800B: SDHCI/DWC2/dwmac MMIO, clock+pinmux pages, 25 MHz
  duo/kernel.ld     Duo linker script (LOADER_2ND header offset)

user/
  user.c3           THE runtime — every program links this. Syscall wrappers,
                    exec/rfork/threadcreate, ipc/p9/ns/fs helpers, print, mmio,
                    Mutex, start()
  user.ld           user linker script (load at USER_BASE = 0x1000000)
  shell.c3          production shell         shell_test.c3   dev/test shell
  shell_common.c3   builtins, line editing, block parser, login
  shell_words.c3    $var, globbing, quoting, shell-locals
  shell_jobs.c3     jobs / wait
  shell_test_*.c3   dev-shell builtins by category: fs, ipc, proc, drivers, lang
  virtio.c3         userspace virtio-mmio (diskd, netd)
  std_racccoon/     the real-stdlib shims (heap over SYS_MAP, _start, libc, io_native)
  sys/              echod, procd, envd
  block/            diskd (virtio), sdd + sdhci (SDHCI)
  fs/               fsd + fat32 + ext2 + exfat
  usb/              usbd + dwc2 + kbd + xpad + msc
  net/              ipd (+ ipd_conv, ipd_tcp, dhcp, eth_proto), link rings,
                    netd / ethd + dwmac + ephy
  gpio/             gpiod
  bin/              standalone /bin programs

lib/
  racccoon-libc/        the C library + POSIX layer; build.sh (C), build_cxx.sh
                        (libc++/libc++abi + C++ programs), build_llvm.sh (LLVM
                        tools), racccoon.cmake (CMake toolchain file)
  tcc/                  TinyCC's racccoon config, crt1, linker script

third_party/
  tinycc/, lua/, musl/  submodules: TinyCC, Lua (for /bin/wasm), musl (libm,
                        float formatting/parsing for racccoon-libc)
                        (c3c's source is outside the repo: C3C_SRC, see §9.8)

test/
  c-src/, cxx-src/      C / C++ test programs -> /bin
  llvm-src/             llctest's IR fixture
  c3-src/               c3ctest's fixture
  wasm-src/             WASI fixtures for wasitest

scripts/
  build.sh              kernel + user + QEMU disk images
  build_user.sh         the two build paths + every program's build line
  build_duo.sh          the Duo kernel (racccoon-duo target)
  build_opi.sh          the Orange Pi RV kernel (+ raw .bin for U-Boot)
  build_opi_qemu.sh     the QEMU sifive_u harness for the Orange Pi port
  lib_kernel.sh         shared kernel compile / test-shell / link steps
  reflash_duo.sh        repackage fip.bin on the SD card + flash (no sudo)
  populate_duo_bin.sh   seed /bin + the tree onto the Duo's ext2 partition
  launch64*.sh          QEMU boot variants (extra args go to QEMU, e.g. -s)
  gdb_qemu.sh           host gdb on QEMU's stub: kernel + one program, ubreak/curproc
  selfbuild_ref.sh      the self-build: stages /src/racccoon, makes the host reference
  seed_selfbuild.sh     seeds it + c3c's stdlib onto the QEMU images

docs/
  manual.md            this file
  roadmap.md           what's planned / done / not doing
  devlog.md            a running log of every work session (newest on top)
  filesystem-layout.md  the canonical tree
  bin-layout.md         how binary names resolve
  ipc-rings.md          the fsd↔diskd shared-arena IPC optimisation
  usb-*.md              USB bring-up notes
  go-port-plan.md       the Go-on-racccoon effort
```

---

*Racccoon is MIT licensed. It is a vibecoded experiment — almost all of
it written by an LLM agent under direction. Treat the code as a sketch
of the ideas, not a reference implementation of them.*
