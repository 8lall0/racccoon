# Racccoon devlog

Running log of work sessions with Claude Code. Newest entry on top.

---

## 2026-08-30 — wasm §4: SYS_MAP + /bin/wasm milestone 1a

Started the WebAssembly interpreter (roadmap §4). Two commits.

**`SYS_MAP` (`dc860c2`)** — userspace had no heap and a `/bin` image is
capped at `EXEC_MAX_IMAGE_SIZE` (256 KiB, `.bss` included). `SYS_MAP
(nbytes) → vaddr` maps page-rounded fresh zero-filled RW+U memory at a
per-process `heap_top` bump pointer. No unmap needed —
`proc_destroy`/`sys_exec` already walk every `PAGE_U` leaf. Bounded at
16 MiB/process; `free_page_count()` pre-check so the per-page
`alloc_pages(1)` can't hit the OOM panic. `heap_top` inits past the
image in `create_process`, past image+argv in `sys_exec`, copied from
the parent in `sys_rfork` (which copies every `PAGE_U` leaf anyway).
`maptest` covers zero-fill / bump / RW / a forked child's own heap / no
leak across runs. First step toward a real userspace allocator.

**`/bin/wasm` 1a (`800d313`)** — the decoder (LEB128, section walk,
type/import/func/global/export/code, every read bounds-checked against
the section end — the `sys_exec` ELF-parser discipline) + an
explicit-frame interpreter (no native recursion — the `ext2_resolve_
block` pattern) for `i32/i64.const`, `local.get/set/tee`,
`global.get/set`, `call`, `return`/`end`, `drop`, `nop`, `unreachable`,
`i32.add/sub/mul`. Host module `"racccoon"` (not WASI):
`print_i32`, `proc_exit`. All working memory `SYS_MAP`'d. `wasm.bin` is
84 KiB.

Fixtures are hand-assembled by `test/mkwasm.py` (no `wat2wasm` on the
host); `build.sh` seeds `build/wasm/*.wasm` onto every disk image next
to `/bin`. QEMU: `wasm add.wasm` prints `5` (`2 + 3` through the host
import), exits 0; `wasmtest` confirms; regression green; Duo builds
clean.

Next: 1b (full integer opcode set + linear memory), 1c (control flow +
the branch sidetable), 1d (`call_indirect` + more host imports), 2
(float ops).

---

## 2026-08-30 — hardware FPU (§3)

Floats used to `panic()` — soft-float `rv64imac`, no compiler-rt linked,
`softfloat_stubs.c3` = 23 tripwire stubs. The C906 and QEMU virt both have
F+D. Now racccoon uses the FPU. QEMU-verified end to end; Duo pending.

### Build

- `c3c build … --riscv-abi=double` **and** `llc … -mattr=+m,+a,+c,+f,+d` —
  both, because the kernel path is IR → `llc`; the c3c flag makes the module
  flag `lp64d` (and the lp64d calling convention), `llc -mattr` selects the
  hardware FP instructions. Same in `build_duo.sh` / `build_user.sh`.
- **The embedded-binary wrappers broke the link.** `objcopy -Ibinary`
  produces an ELF with `e_flags = 0` (soft-float ABI); once the kernel `.o`s
  carried the double-float ABI flag, `ld.lld` refused to link the two
  ("different floating-point ABI"). Fix: assemble the wrappers with
  `llvm-mc … --target-abi=lp64d` over a `.incbin` stub — same
  `_binary_<name>_bin_start/_end` symbols, matching `e_flags = 0x5`.
- `softfloat_stubs.c3` deleted. One symbol survives: C3's `std::io` float
  formatter has a lone `fptrunc fp128 to double` in its float-arg path, and
  the C906 has no Q extension, so `__trunctfdf2` still lowers to a soft call
  — kept as a one-line stub in `softfloat_f128_stubs.c3` (still unreachable;
  `printfn` is `%s`/`%d`/`%x` only).

### Kernel

- `sstatus.FS = Initial` at boot (`kernel.c3`), field surgery not an OR,
  with a read-back probe → clear "FPU unavailable" panic instead of a
  mysterious `scause=2` later.
- **Eager**, not lazy. `switch_context` is `@naked` (preserves no FP regs,
  including callee-saved `fs0`–`fs11`) and `yield()` is its only caller, so
  a full `f0`–`f31`+`fcsr` save/restore bracketing that one call covers
  every context switch. `Process.fp_area` (`ulong[33]`), `fp_save` /
  `fp_restore` / `fp_reset` `@naked` helpers. Cost is ~66 FP mem-ops per
  `yield()`; the timer fires ~1 Hz and the frequent `yield()` callers
  (driver poll loops) are integer-only. Lazy (trap `scause=2`, per-hart FP
  owner) would need a new case in the illegal-instruction path — the
  fragile trap-handler surface the project history says to avoid — for
  negligible gain. A conditional save (skip when `FS != Dirty`) is the
  optimisation to reach for only if a `yield()`/sec counter ever shows it.
- `user_entry` sstatus `0x40020` → `0x42020` (FS=Initial). `create_process`
  zeroes `fp_area`. `sys_rfork` snapshots the parent's live f-regs into the
  child (fork copy semantics). `sys_exec` zeroes + `fp_reset()`s (new image,
  clean rounding mode). `fork_entry` unchanged (its sstatus RMW keeps FS).

### Verification

QEMU boots clean (no FPU panic, no `scause=2`). New `fputest`: `double`
arithmetic, a live `double` held in a parent register across `fork` + an
IPC round-trip + `join` (two context switches), and FP-state inheritance to
the child — passes repeatedly. Full regression + shell smoke (globbing,
brace expansion, background jobs, pipelines) green. **Duo boots clean** on
the plain reflash — stock vendor OpenSBI v0.9 hands `mstatus.FS` off usable,
no `PATCH_OPENSBI=1` needed, no `scause=2`.

---

## 2026-08-30 — supervisor: usbd / ethd / netd / gpiod (§5)

The last four unsupervised processes join. Every server and driver in
the system is under the supervisor now.

They're all `for(;;)` poll loops, so "exit" means a `panic()` — which
now brings the driver back instead of leaving it dead. New
`Service.watch_hangs` splits the hang watchdog from plain respawn:

- **netd** — `watch_hangs = true`. Its respawn path is byte-for-byte
  diskd's (virtio `DEVICE_STATUS = 0` reset, `setup_netd_mappings`,
  PLIC self-heal), and now fault-tested: `netdkilltest` kills it,
  waits for `svc: respawned netd`, and confirms the `/net/` reseat.
  (netd gained a `srv_post("netd")` so the test has a handle — it had
  no name and no pid global.)
- **usbd / ethd / gpiod** — `watch_hangs = false`. A USB bus reset +
  1s settle, or an Ethernet PHY train, legitimately doesn't touch the
  driver's IPC poll for seconds, which would false-trip the
  has_message stall check. Respawn-on-exit only. Duo-only + the Duo
  runs the production shell, so no fault-test; re-init is idempotent
  by inspection (`usbd_init` → DWC2 `CSFTRST`, `ethd` → DMA soft
  reset).

The `reseat` in `supervisor_spawn` already covers the dynamic
`/mnt/usb/` and `/srv/gpiod/` mounts, and a respawned driver re-posts
its own srv name. `SVC_MAX` was already 10 (QEMU registers 7, Duo 9).

QEMU: `netdkilltest` + `hungservertest` + `storagekilltest` +
`fsdkilltest` + full regression green. Duo boots clean with usbd / ethd
/ gpiod registered (the boot-ordering-sensitive spawn path — usbd after
the shell — is unchanged, just three more `supervisor_register` calls).

§5 gap #1 ("no supervision for servers") is now closed outright.

---

## 2026-08-30 — supervisor: hang watchdog + envd crash policy (§5)

Two of the "smaller §5 gaps."

### Watchdog (§5.6, gap #5)

A supervised server stuck in an infinite loop / deadlock used to look
alive — clients waited on it forever. The supervisor now catches it.

Signal: a server in its `ipc_recv` loop has `has_message == false`; it
clears the flag the instant it picks a message up, *before* processing.
So `has_message` stuck true across `SVC_STALL_LIMIT` (5) consecutive
ticks == "got a request, never returned to recv." `Service.ever_ready`
gates it — a server that hasn't reached recv even once (slow init, sdd
on the Duo) is starting, not wedged.

Three supporting pieces, each a real bug found while building it:

- **`proc_destroy(Process*, code)`** — extracted the byte-identical
  teardown body out of `sys_exit` / `sys_kill` (wake IPC partners, drop
  pipes, free the address space, free the slot). `sys_exit` is 5 lines
  now. The watchdog calls it too.
- **The watchdog defers the respawn one tick.** Killing + respawning in
  the same tick reuses the just-freed slot; if the wedged server was
  `current_proc`, the timer trap's `yield()` then saves the trap
  context *into the fresh process* and corrupts it — booted straight
  into a store page fault. `supervisor_tick` now returns whether it
  killed `current_proc` so the timer case can force the yield, and the
  respawn waits for the next tick's normal dead-detection.
- **`create_process` clears `has_message` / `msg_acked` / `msg_from`**
  on a reused slot (`sys_rfork` already did). Without it, a respawned
  server "consumed" the stale request the killed instance left in the
  inbox and replied into a rendezvous nobody was in — deadlock. This
  was the second hang, after the page fault.

`hungservertest` (shell_test.c3) + a test-only `ECHOD_HANG` verb prove
it end to end. QEMU: passes; killtest / fsdkilltest / storagekilltest /
ipcdeathtest / regression all still green. Duo boots clean with the
refactored teardown + watchdog (the watchdog itself isn't reachable
from the production shell, but the `proc_destroy` / `create_process`
changes underpin every kill path).

### envd crash policy (§5.4)

Classified as **accept the loss.** `env_table` is `(pid, generation)`-
keyed — meaningless after any respawn; `$user`/`$cwd`/`$home`/`$status`
are shell-computed, not stored there; and nothing but the dev tests
ever writes `/env`. A respawned envd coming up empty *is* correct.
`fsd`/`fsd2`/`procd`/`echod` are all stateless-rebuildable. Noted in
`envd.c3` and the roadmap.

---

## 2026-08-30 — supervisor: the block-storage driver joins §5

The supervisor already covered fsd / fsd2 / echod / procd / envd — the
comment in `supervisor.c3` claiming echod was unsupervised (and that the
shell's `ping` hardcodes pid 2) was just stale; both have been through
name resolution for a while. Extended it to the one device driver
everything sits on: **diskd (QEMU) / sdd (Duo)**.

- `Service.needs_fsd_setup` (an fsd-only bool) → `Service.kind`, an
  `SVC_KIND_*` tag. `supervisor_spawn` switches on it and re-runs the
  matching `setup_*_mappings` after `create_process` — the MMIO + DMA
  mappings a driver needs re-established. The switch already has slots
  for usbd / ethd / netd / gpiod; those aren't registered yet (each
  needs its bring-up verified idempotent + a fault-test, mostly
  Duo-only). `SVC_MAX` 6 → 10.
- The storage driver's PLIC route self-heals for free —
  `irq_route_register` overwrites in place, and the re-run
  `setup_diskd_mappings` calls it.
- fsd re-resolves the storage pid on an IPC failure: `diskd_rw`, when
  `p9_call` returns ≤ 0 and this isn't the dynamic USB instance
  (`g_fsd_dynamic`), asks `SYS_FS_PARTITION_INFO` for the current
  `storage_pid` and retries once. On QEMU the respawn lands back in the
  same slot (pid unchanged) so this rarely fires, but it covers the
  general case.
- Drive-by: `SYS_FS_PARTITION_INFO` never set `f.a0 = 0` on success —
  harmless only because its one caller checked `< 0`. Fixed.

`storagekilltest` (shell_test.c3): kill the storage driver, confirm the
supervisor re-inits it and reads recover. QEMU: passes repeatedly, and
`bigreadtest` / `fsdkilltest` / full regression stay green afterwards.
Duo boots clean with sdd registered under the supervisor; a fault-test
of sdd's *respawn* on real hardware still needs a dev-shell build (the
Duo runs the production shell, which has no `storagekilltest`).

Side quest while verifying on the Duo: `shell_login()`'s one-shot
`fs_read("/adm/users")` (the "unprovisioned card → root console"
fallback) now retries for ~10 s first — a slightly larger kernel image
had started racing the SD-driver + ext2-mount bring-up. That turned out
not to be the actual problem this time, though: the SD card in use had
its ext2 partition at sector 526336, not the `FS_PARTITION_START_SECTOR`
2099200 the Duo kernel reads — so every FS read failed and login was
skipped. Re-seating the correct card (DUOBOOT at 2048/1 GiB, ext2 at
2099200) fixed it; the retry stays as cheap insurance.

---

## 2026-08-30 — refactor: split shell_common.c3

Bookkeeping after the §2.5 burst. `user/shell_common.c3` had gone from
~770 to 1391 lines this session (login, namespace builtins, globbing,
brace expansion, background jobs all landed there), mixing four
unrelated concerns. Split, pure code movement (commit `5c22687`):

- `user/shell_words.c3` (343) — text → argv words: `sh_name_*`,
  `shell_var_value`, `shell_expand`, `shell_expand_q`, `glob_match` +
  `shell_glob_into`, the four `shell_brace_*`.
- `user/shell_jobs.c3` (121) — `struct Job` + `g_jobs` + the six job
  functions.
- `user/shell_common.c3` (943) — the exec core: readline, prompt,
  `shell_dispatch_common`, `shell_spawn*`, `shell_run_pipeline`,
  `shell_exec_line`, login.

All `module user`, so cross-file calls and shared consts (`BRACE_BUF`,
`JOB_STAGES`, `g_shell_status`) just resolve; `build_user.sh`'s two
shell targets list the new files. No behaviour change — feature spot
checks + regression green, Duo builds clean and boots.

Considered but shelved (user's call): a real scripting language.
Current shell is already rc-flavoured, which fixes most of what's wrong
with bourne/bash (word splitting, quoting, list vs string). Going
further — typed values + structured pipelines (Elvish-shaped, which
would map cleanly onto the one-shell-process + separate-command-process
model) vs. rc-style `if`/`while`/`for`/`fn` on the current model — is a
design project, not an increment. Set aside.

---

## 2026-08-30 — shell: background jobs (`cmd &`, `jobs`, `wait`)

Roadmap §2.5. A trailing `&` (or ` & ` mid-line — `a & b &` works)
backgrounds a pipeline. `shell_run_pipeline` grew a `bg` flag: it spawns
and wires the stages exactly as normal, then registers the whole
pipeline in a job table (`g_jobs`, 8 slots, each holding every stage's
`(pid, generation)`) and returns 0 instead of feeding / pumping /
joining.

Reaping is lazy and never blocks. `shell_prompt` calls
`shell_jobs_reap()` once per prompt: poll each job's stages with
`proc_info`, and when all are gone `join()` them — which returns
immediately for an already-dead pid (`sys_join`'s wait loop breaks on
the first iteration) — then print `[N] done | exit S | killed  <cmd>`.
`jobs` lists the running ones (reaping first, so a just-finished job
still reports); `wait` cooperatively joins every current job.

Limits: no `<` / `>` / `>>` in a background job (the shell pumps those
itself and would block) — errors. A side-effecting builtin backgrounds
into the `/bin` path and 127s; an output-only builtin still works (runs
in its forked stage child). `sh_seq_op_at` gained kind 4 for a bare `&`,
kept distinct from `&&`. No `^Z` / `fg` / `bg` — this kernel has no
signals, so there's nothing to stop or continue.

QEMU: `ls /bin | cat &` → `[1] <pid>` then `[1] done` next prompt;
`false & wait` → `[2] exit 1`; `echo A | cat | cat & echo B | cat &
wait` (two jobs, one line); `echod &` + `jobs` → `[N] running echod`;
`echo x > /tmp/f &` rejected. Regression green (10 tests); sequencing +
multi-stage (6/6) unaffected. **Duo hardware verified** on the console.

---

## 2026-08-30 — shell: brace expansion

Roadmap §2.5. `{a,b,c}` → three words, `pre{x,y}post` →
`prexpost preypost`, `{a,b}{c,d}` cartesian, nested `{a,{b,c}}`. A group
with no top-level comma (`{a}`, a leftover `${x}`) or an unmatched `{`
stays literal; quoted (`"{a,b}"`) and escaped (`\{a,b}`) braces too.

Runs per word in `shell_run_pipeline`'s stage loop, *before* globbing:
`shell_brace_split` finds the first unquoted `{`, its match, and the
depth-1 commas; `shell_brace_rec` recurses on `prefix + alt + suffix`
for each alternative (depth/count/buffer bounded). So `/bin/{c,l}*`
brace-expands to `/bin/c* /bin/l*` and then globs each →
`/bin/cat /bin/ls`. Quoting is honoured at the token's first brace only;
deeper levels operate on the assembled string (a quoted brace nested
inside an alternative isn't re-protected — real use doesn't hit it).
Only brace-carrying tokens are copied into the 1 KB result buffer;
plain words keep pointing into `exp`.

QEMU: all cases above verified plus `{1,2,3} | cat | cat`; regression
green (bigreadtest, pathtest, mounttest, killtest, envtest, nstest,
srvtest, p9fstest, runtest); multi-stage pipelines 5/5. **Duo hardware
verified** on the console.

---

## 2026-08-30 — shell: backslash escapes

Roadmap §2.5. `\<char>` outside quotes takes `<char>` literally — `\ `
an escaped space (an argument spans it), `\|` / `\;` / `\&` an escaped
operator, `\$` a literal dollar, `\*` a literal glob metachar; a
trailing `\` is itself literal. Inside `"..."`, `\` escapes only
`` $ ` " \ `` (sh's rule — every other `\x` keeps both bytes). Inside
`'...'` the backslash stays literal, unchanged.

Nearly free to add: `shell_expand_q` emits the escaped byte with
`qmask = 1`, and the tokeniser already reads a quoted byte as ordinary
text — no split, no operator, no glob, no `$`. The only other touch is
`shell_exec_line` (which splits `;` / `&&` / `||` *before* expand_q
runs): it now skips `\x` pairs so an escaped operator or quote there
can't wrongly split the line or flip its quote tracker.

QEMU: `echo a\ b`, `echo a\|b`, `echo \$user` (vs `echo $user` →
`root`), `echo a \; b` → `a ; b`, `echo "a \" b"`, `echo "x\\y"` →
`x\y`, `echo \*`, `echo 'a\b'` → `a\b`, `echo done\` all verified;
regression green (argvtest ok on FAT32 — the disk_dual "FAILED" is the
known pre-existing ext2 case); quoting / globbing / multi-stage
unaffected. **Duo hardware verified** on the console.

---

## 2026-08-30 — shell: output-only builtins as pipeline stages

Roadmap §2.5. `pwd`, `hello`, `namespace` / `ns` now work as pipeline
stages — `namespace | head -n 2`, `pwd | cat > f`, `pwd | cat | cat`.

A pipeline stage is a forked child, so the trick is just: for a
pipeable builtin, `rfork` and let the child run `shell_dispatch_common`
(the exact same path a plain command takes) and then `exit()`. The
parent has already wired that child's stdout to the stage pipe before
it runs — same cooperative "wire before the child runs" guarantee the
external-command stages rely on. New `shell_spawn_stage()` picks builtin
vs. `/bin` spawn; the spawn loop calls it instead of `shell_spawn()`.

Gated (`shell_builtin_pipeable`) to output-only builtins with no
shell-process side effect. `cd` / `su` / `login` / `mount` / `bind` /
`exit` / `mountusb` are out — their whole point is a side effect on the
shell's own long-lived process, which a child can't deliver; in a
pipeline they fall through to the `/bin` path and 127 like any unknown
command (`cd /bin | cat` → `cd: command not found`, and `pwd` is
unchanged afterward). `echo` / `whoami` are out too — real `/bin`
binaries already cover them. The no-pipe/no-redirection path is
untouched: builtins still run in-process there, so `cd` works.

QEMU disk_dual: the cases above plus regression green (bigreadtest,
pathtest, mounttest, killtest, envtest, nstest, srvtest, p9fstest).
**Duo hardware verified** (reflash only — kernel-embedded shell):
`namespace | head`, `pwd | cat`, and the side-effecting-builtin 127
fall-through all confirmed on the console.

---

## 2026-08-29 (continued) — shell: bind/mount/namespace, login, globbing

Roadmap §2.5, three of the "still to do" items in one pass (they all
live in `user/shell_common.c3`).

### bind / mount / unmount + namespace

Two new syscalls:

- **`SYS_NS_LIST` (45)** — copies the caller's own namespace out, one
  36-byte record per live mount (32-byte prefix + 4-byte LE pid). Same
  per-process scope and generation-staleness drop as `SYS_NS_RESOLVE`.
- **`SYS_NS_BIND` (46)** — Plan 9's `bind`: resolve a path through the
  caller's namespace (longest-prefix, exactly like `SYS_NS_RESOLVE`),
  then add/replace a mount at a new prefix pointing at that same server.
  The insert half is identical to `SYS_NS_MOUNT`; only the source
  differs — an existing path vs. a posted `srv` name.

Both inlined into `handle_syscall`'s switch next to `SYS_NS_UNMOUNT`
(the c3c "complex function from the switch" landmine still means simple
inline cases are the safe choice).

Builtins in `shell_dispatch_common` (both shells): `namespace`/`ns`,
`mount <srv> <dir>`, `bind <source> <dir>`, `unmount`/`umount <dir>`.
Builtins, not `/bin` commands, for the same reason `mountusb` is — a
namespace change only ever flows parent → child at spawn, never back.
Mount points are absolutised against cwd and given a trailing slash (the
`Mount.prefix` convention).

Known wart, not new: a mount at `/mnt/x/` only resolves for paths that
*include* the trailing slash — `ls /mnt/x/` works, `ls /mnt/x` doesn't.
Every boot mount already behaves this way (`ls /proc/` vs `ls /proc`).
`SYS_NS_RESOLVE` would need to also match a path that equals a prefix
minus its trailing `/`; left for later.

### boot-time login

`shell.c3` runs `shell_login()` after the boot settle: `login: <name>`
against `/adm/users` (name only — there's no password field), then
`setuid` + `cd /usr/<name>`. `root` is always in `/adm/users` so no
lockout; a root partition with no `/adm/users` at all comes up as root
rather than looping. `exit` → the kernel respawns a fresh root shell,
same as `su` already relied on. Also a `login <user>` builtin so
`shell_test.c3` (the QEMU build, which skips the startup prompt) can
exercise it. `shell.c3`'s inline line editor extracted to
`shell_readline()` and shared.

### globbing

Any pipeline word with an unquoted `*` / `?` is expanded against the
filesystem before its stage runs (`glob_match` — linear backtracking —
plus `shell_glob_into`). `*` any run, `?` one char, last path component
only (earlier components literal). No match → the pattern stands
literally (rc's rule, not sh's). Quoted metachars stay literal.
`STAGE_WORDS_MAX` 48 → 72 for headroom; expanded strings packed into a
2 KB per-pipeline buffer that `stage_words[]` points into.

### verification

QEMU disk_dual + FAT32: full regression green (bigreadtest, pathtest,
fsneg, fspermtest, p9fstest, mounttest, envtest, killtest, ipcdeathtest,
fsdkilltest, runtest, nstest, hardentest, srvtest); multi-stage
pipelines 8/8; `namespace`, `bind / /mnt/x` then `ls /mnt/x/` (lists
root), `login glenda` (prompt → `glenda /usr/glenda %`, `$user`, cwd),
`echo /bin/*a*` → `cat false head whoami`, `echo '*'` literal, no-match
literal — all verified. **Duo hardware verified** (reflash only —
everything is in the kernel-embedded shell): `login` prompt at boot,
`login glenda` / drop / `exit`, globbing, and `namespace` / `bind` /
`unmount` all work on the console.

---

## 2026-08-29 (continued) — multi-stage pipelines: the kernel race, fixed

Roadmap §2.5. Followed up the previous entry's root-cause work with a
real fix. `a | b | c` (up to `MAX_STAGES = 6`) now works — 4-stage
hammered 15/15 at tight input spacing, mixed pipe/redirect combos
25/25, `head` mid-pipeline, full QEMU regression green on both
disk_dual and FAT32.

**The deadlock, recapped.** 3+ concurrent `exec()`s (one per pipeline
stage) each park in `SYS_IPC_CALL`'s cooperative yield loop. Those
loops `yield()` but never `sret`, so hardware-cleared `sstatus.SIE`
stays globally off and no interrupt is delivered as a trap. diskd's
disk-completion wait is a busy poll of its inbox that relies on the
virtio-blk IRQ notify; with SIE off the notify never arrives, diskd
spins forever, fsd (blocked on diskd) hangs, the pipeline stage
(blocked on fsd during `exec`) hangs, and the shell's `join()` hangs.
Plus a verb collision: `DISKD_READ == 10 == P9_REMOVE`, so a stray
unconsumed diskd reply in fsd's inbox got re-dispatched as P9_REMOVE
into a mutual fsd↔diskd reply deadlock.

**The fix (five parts):**

1. **`Process.driver_irq_pending`** — a `bool` flag *separate* from the
   IPC inbox (`has_message`/`msg_type`/`msg_from`), so routing an IRQ
   notify can never clobber, or be clobbered by, a real client request
   sitting in the inbox. The earlier attempts that poked
   `has_message = true` all failed exactly here — they ate a pending
   fsd request.
2. **`service_pending_external_irq()`** — extracted from `handle_trap`;
   claims / routes / completes one PLIC IRQ and sets the target
   driver's `driver_irq_pending`. Now called from **both** the trap
   handler **and** `sys_ipc_poll`.
3. **`sys_ipc_poll` drains the PLIC by hand** via (2) and returns a
   synthetic `DISKD_IRQ_NOTIFY` when `driver_irq_pending` is set —
   *before* it looks at the real inbox, and without touching
   `has_message`. So diskd's spin poll gets its completion notify even
   with SIE globally off.
4. **diskd acks the virtio-mmio ISR** (`INTERRUPT_STATUS` read →
   `INTERRUPT_ACK` write, new regs in `virtio.c3`) after each request,
   so the level-triggered IRQ line drops. A permanently-asserted line
   re-traps on every `sret` and storms the PLIC — which is what broke
   the earlier attempts once `sys_ipc_poll` started draining the PLIC.
5. **`DISKD_READ`/`_WRITE` moved 10/11 → 210/211**, clear of the P9
   (3–10) and FS (20–28) ranges, so a stray diskd reply in fsd's inbox
   is dropped as unknown instead of mis-dispatched. `sdd.c3` (Duo)
   tracks the same constants — fsd↔sdd is a wire protocol, reflash
   both together.

`shell_run_pipeline` reworked to N stages: flat `stage_words` argv
storage, N-1 inter-stage pipes plus optional `<` on the first stage and
`>`/`>>` on the last, spawn-all-then-wire-then-join.

Heisenbug caveat from last session still holds: any debug print shifts
timing enough to hide the original hang, so verification is by tight
hammer loops (`sleep 0.9` between pipelines), not instrumented runs.

Duo hardware verified (reflash only — `fsd`/`sdd`/`diskd` are all
embedded in `kernel_duo.elf` and respawned from the embedded copies, so
the 10/11→210/211 verb change is entirely inside the flashed image; the
card's `/bin` needed no repopulate). 3-stage `echo hi | cat | cat`,
`cat < f | cat | cat`, `cat < f | cat | head -n 1`,
`ls /bin | cat | cat > f`, and disk-heavy `ls /` / `cat` regression all
clean on the Duo console.

One reflash snag worth noting: the SD card had been reprovisioned from
scratch (empty DUOBOOT), so `reflash_duo.sh`'s `--OLD_FIP` section-reuse
had nothing to build on. Restored `build/fip_old_from_sd.bin` (the FIP
read off the card earlier, PLIC-patched OpenSBI intact) as the base
first, then reflashed.

`src/entry.c3`, `src/process.c3`, `user/block/diskd.c3`,
`user/block/sdd.c3`, `user/fs/fsd.c3`, `user/virtio.c3`,
`user/shell_common.c3`.

---

## 2026-08-29 (continued) — multi-stage pipelines: blocked on a kernel race

Roadmap §2.5. Attempted `a | b | c` (3+ stages). The shell side worked
(N-stage parser in `shell_run_pipeline`, `MAX_STAGES` inter-stage
pipes, spawn-all-then-wire-then-join), and a single 3+ stage pipeline
runs cleanly every time. But a **second** 3+ stage pipeline in the
same session hangs (~15-20%), or crashes (`scause=c` instruction
fault at a stage's `main`). 2-stage stays rock-solid (18/18 hammered).
Reverted the N-stage code; kept `/bin/head` (a genuinely useful
2-stage filter — `ls | head -n 3`).

**Root cause (found, not yet fixed).** Instrumented the hang: the
shell's `join()` waits on the last stage; that stage is parked in
`SYS_IPC_CALL` phase 3 (its `exec()` mid-`fs_read_at`); **fsd and
diskd are deadlocked replying to each other** —
`DBG fsd RECV_GEN from=3 verb=10` then `DBG fsd REPLY to pid=3`. The
chain:

1. A 3+ stage pipeline runs 3 `exec()`s concurrently. Each stage
   parks in one of `SYS_IPC_CALL`'s cooperative yield loops, which
   never `sret`, so hardware-cleared `sstatus.SIE` stays globally off
   and **no interrupt is taken** for the duration.
2. diskd's disk-completion wait (`user/block/diskd.c3`) is a
   **busy-spin poll of its inbox** that relies on its virtio-blk IRQ
   being delivered normally in between. Under (1) it can't fire.
3. diskd spins; its `DISKD_READ` reply to fsd ends up delivered but
   not consumed by fsd's `p9_call` (a duplicate, or a spin-poll that
   ate fsd's next request). It lingers in fsd's inbox.
4. fsd's next `ipc_recv_type_gen` picks the stale reply up as a
   *request* `from=3 verb=10`. **`DISKD_READ == 10 == P9_REMOVE`**, so
   fsd dispatches it as a P9_REMOVE and `ipc_reply`s to diskd — which
   is itself still mid-`ipc_reply` to fsd. Mutual deadlock.

**Fixes tried, none sufficient alone:** (a) draining the PLIC from
`yield()` when `blocking_depth > 0` — the IRQ reaches diskd but the
deadlock still forms (diskd doesn't ack the virtio-mmio ISR, so
delivery timing stays fragile); (b) moving `DISKD_READ`/`_WRITE` off
the P9/FS verb range (10/11 → 60/61) so a stray reply is dropped
instead of mis-dispatched — removes the *mutual* deadlock but the
pipeline still hangs (diskd still starved of its IRQ).

**A real fix needs** the interrupt-driven driver's completion wait to
survive "SIE globally off during a concurrent cooperative-blocking
storm" — either a PLIC drain on the exact spin path plus a proper
virtio-mmio ISR ack in diskd/sdd, or replacing the spin with a
blocking primitive (which today's kernel forbids — the sscratch
nested-trap hazard in `SYS_IPC_POLL`'s comment). Plus the verb-range
fix as defence-in-depth. Filed in roadmap §2.5.

### Second, deeper fix attempt (also filed, not landed)

Tried three combinable pieces, none of which got a clean pass:

1. **`yield()` drains the PLIC when `blocking_depth > 0`** (extracted
   `service_pending_external_irq` from handle_trap). Delivers a pending
   device IRQ cooperatively during the SIE-off window. On its own it
   didn't break the deadlock — diskd's spin loop has no `yield()`, so
   the scheduler never leaves diskd to let the drain run.
2. **`yield()` in diskd's spin loop.** Now the drain runs — but this
   alone *broke* `bigreadtest` (single-command, disk-heavy): the
   virtio-blk IRQ line stays asserted (diskd never acks the ISR), so
   `plic_claim` keeps re-delivering it and diskd breaks its spin
   *early* for the next request with a garbage `req.status`.
3. **diskd polls the used ring instead of the IRQ notify** (netd's
   self-sufficient pattern: `while (used.index != last_used_index)` +
   timeout + `yield()`), plus a virtio ISR ack (new
   `VIRTIO_REG_INTERRUPT_STATUS`/`_ACK` in `virtio.c3`), plus moving
   `DISKD_READ`/`_WRITE` (10/11) off the P9 verb range. Boot, `pathtest`
   and 2-stage pipelines pass — but **`bigreadtest` still hangs**, and
   it is *not* diskd hanging (its reads complete, no timeout fires).
   Something downstream in the ~600-request path (fsd2 → diskd on the
   `/mnt/fs2/` mount) stalls. Left unfinished here — the used-ring poll
   is the right direction; the remaining stall wants a focused debug
   pass (likely a QEMU virtio-blk sync-vs-async completion detail: the
   poll loop has no VM exit, so an async aio can't complete while diskd
   spins on guest memory).

Net: root cause is solid, the fix is a genuine multi-front kernel /
driver change (virtio-mmio interrupt model + the SIE-off blocking
model) that needs its own session. `a3d3f04` state (2-stage +
`/bin/head`) is unchanged.

---

## 2026-08-29 (continued) — shell: quoting

Roadmap §2.5. Shell-only — `'...'` and `"..."`.

`shell_expand_q(in, out, qmask, cap)` replaces the plain `shell_expand`
on the interactive path: it removes the quote characters and, in a
parallel `qmask` byte array, marks every output byte that came from
inside quotes. Single quotes are fully literal (`''` → a literal `'`,
rc's rule); double quotes are literal but `$name` still expands; an
unquoted `$name` expands and its bytes stay unquoted (so it still
word-splits, unchanged). Unterminated quote → error, status 2.

The tokeniser (now inside `shell_run_pipeline`, which takes the raw
segment text and expands + splits it itself) splits only on `qmask`-0
whitespace, and a token counts as a `|` / `<` / `>` / `>>` operator
only when its bytes are unquoted — so `echo '|'` and `echo "a ; b"`
are literal. `shell_exec_line`'s `;` / `&&` / `||` scan tracks quote
state too. `sh_seq_op_at` unchanged (operators still space-surrounded).
The old `shell_expand` stays for shell_test.c3's dev-command dispatch,
which never quotes.

**Verified QEMU** (`disk_dual` + `disk.img`): `echo "a b c"` → one
arg; `'$user'` literal vs `"$user"` expanded; `"a | b ; c && d"` all
literal; `echo '|' `/`"a ; b"` literal but bare `|` / `;` still work;
`echo 'it''s'` → `it's`; `"hello world" > /tmp/q`; `cd "/tmp" && pwd`;
unterminated quote caught. Full regression (`pathtest` / `fsneg` /
`fspermtest` / `envtest` / `bigreadtest` / `runtest` / `killtest` /
`ipcdeathtest` / `p9fstest` / `mounttest` / `argvtest` on FAT32)
unchanged.

**Duo:** verified on hardware after `reflash_duo.sh` (shell-only, no
`/bin` repopulate) — `echo '$user'` literal, `echo "a b c"` one arg,
`echo "x` caught.

---

## 2026-08-29 (continued) — shell: `;` / `&&` / `||` sequencing + exit status

Roadmap §2.5. `&&` / `||` need a real exit status, which the kernel
didn't track — so this is a small kernel change plus the shell layer.

**Kernel — exit-status side table** (`src/process.c3`). `exit()` gained
`exitcode(int)` (`SYS_EXIT` now reads `a0`). `sys_exit` / `sys_kill`
drop a `(pid, generation, code)` into a small round-robin table
(`proc_record_exit` — only non-zero codes from a process that had a
parent, so a clean exit is just the absence of a record); `sys_join`
picks it up with `proc_take_exit` once it sees the slot is gone and
returns it. No zombie state, no scheduler change. A killed process
records -1. `join()`'s wrapper now returns that status (was always 0);
the only in-tree caller that checks the value (`ipcdeathtest`) expects
0 for its cleanly-exiting child, unchanged.

**Shell** (`shell_common.c3`). `shell_exec_external` / the renamed
`shell_run_pipeline` now return a status; a failed `exec` in the child
is `exitcode(127)`; failing builtins (`cd`, `su`) set `g_shell_status`.
New `shell_exec_line(char* raw_line)` replaces the token-based entry
point: it splits the raw line on ` ; ` / ` && ` / ` || `
(space-surrounded), then **expands + tokenises each pipeline on its own,
right before it runs** — so `$status` (rc's, new in `shell_var_value`)
inside a sequenced line reflects the pipeline just before it. All three
operators are one left-associative precedence level (`a && b || c` runs
`c` only if `a && b` failed). `SHELL_MAX_TOKENS` 8 → 16. New trivial
`/bin/true` and `/bin/false`.

**Verified QEMU** (`disk_dual` + `disk.img`): `true && echo` / `false
&& echo` / `false || echo` / `true || echo` all gate correctly;
`false && a || b` → `b`; `cmd ; echo $status` shows 127 / 1 / 0 as
expected; `&&` composes with `|` and with `>`; full regression
(`killtest` / `rforktest` / `ipcdeathtest` / `fsdkilltest` /
`mutextest` / `threadtest` / `p9test` / `nstest` / `p9fstest` /
`mounttest` / `envtest` / `fsneg` / `bigreadtest` / `runtest` /
`argvtest` on FAT32 / `pathtest` / `fspermtest`) unchanged.

**Duo:** verified on hardware after a reflash + `populate_duo_bin.sh` —
`true && echo`, `false || echo`, `hello ; echo $status` all behave as
in QEMU.

---

## 2026-08-29 (continued) — fsd: trailing-slash path normalization

Follow-up to the pipes work, which surfaced it: `ls /` reported "not
found" (so did `ls /bin/`). `ext2_leaf_name("/")` is `""`, so
`ext2_list` / `ext2_stat` looked up a directory entry literally named
`""` and missed — `ls /bin` worked only because its leaf is a real
name. Fix (`user/fs/fsd.c3`): strip trailing `/` from the request
filename in the one place it's pulled off the wire (the mount prefix
is already gone by then), collapsing a lone `/` to `""` — which every
backend already reads as the root. Same for the FS_RENAME target.

Verified QEMU (ext2 / fat32 / exfat: `ls /`, `ls /bin/` now list;
`ls /mnt/fs2/` and the fs regression suite unchanged) + real Duo.

---

## 2026-08-29 (continued) — shell: pipes and redirection

Roadmap §2.5. A kernel pipe primitive + the shell wiring for `|` and
`<` / `>` / `>>`.

**Kernel** (`src/pipe.c3`, new). A `Pipe` is a fixed `PIPE_BUF` (4096)
ring buffer with `writers` / `readers` refcounts (`PIPES_MAX` = 6).
`pipe_try_put` drops silently when `readers == 0` (SIGPIPE-style);
`pipe_try_get` returns EOF once the buffer is empty *and* `writers ==
0`. `Process` grew `stdout_pipe` / `stdin_pipe` (-1 = the console).
`SYS_PUTCHAR` / `SYS_GETCHAR` route through them when set, so a piped
child needs no code changes. New syscalls 39–44: `SYS_PIPE` (alloc),
`SYS_PIPE_SETOUT` / `_SETIN` (point a child's end at a pipe, called
right after rfork before the child runs — cooperative sched means no
race), `SYS_PIPE_READ` / `_WRITE` (the shell pumps a file end), and
`SYS_PIPE_HOLD` (the shell claims the reader end of a `>` pipe / the
writer end of a `<` pipe so its own traffic isn't dropped / EOF'd
early, then releases it). `sys_exit` / `sys_kill` detach both ends.

**Shell** (`shell_common.c3`). `shell_exec_external` split into
`shell_spawn` (rfork + exec, returns the child pid without waiting) +
a join. New `shell_run_line(tokens, count)` replaces the
`shell_dispatch_common || shell_exec_external` tail of both shell
mains: it scans for one `|` and for `<` / `>` / `>>` (each must be its
own space-separated token); with none it's the old path verbatim,
builtins and all. A pipeline stage is always an external `/bin`
binary — so `echo` gained a real `/bin/echo` (`user/bin/echo.c3`) and
`cat` with no argument now copies stdin to stdout until EOF. `> file`
truncates then streams `pipe_read` → `fs_write_at`; `>> file` starts
at the current size; `< file` is read up front (bounded at one
`PIPE_BUF`) and fed in before any child runs.

**Limitations** (roadmap §2.5): builtins can't be a pipeline stage;
only one `|`; `SHELL_MAX_TOKENS` is 8 so a long pipeline overflows;
operators must be space-separated.

**Verified QEMU** (`disk_dual`): `echo hi | cat` → `hi`; `echo foo >
/tmp/t` + `cat /tmp/t` → `foo`; `echo bar >> /tmp/t` → `foo` / `bar`;
`cat < /tmp/t` → same; `ls /bin | cat` lists every binary incl. the
new `echo`. Regression (`hello` / `whoami` / `ls` / `readfile` /
`p9test` / `nstest` / `ping`) unchanged. Pre-existing, unrelated:
`ls /` (a lone-slash path) still reports "not found" — `ls` with no
arg and `ls /bin` are fine.

**Duo:** verified on hardware after a reflash + `populate_duo_bin.sh` —
`echo hi | cat`, `ls /bin > /tmp/l` + `cat /tmp/l`, `cat < /tmp/l` all
behave as in QEMU (`/bin/echo` and the stdin-aware `cat` live on the
ext2 partition, so both flashing steps were needed).

---

## 2026-08-29 (continued) — shell: boot-quiet, cwd, $var

Roadmap §2.5. Three commits, making §1/§2 usable at the prompt.

**Boot-log pollution** (`138b6ab`). Server init logs kept landing after
the prompt (usbd/ethd/gpiod spawn *after* the shell — the "usbd never
blocks so idle never makes the shell" deadlock; and ethd's link poll /
fsd2's mount finish seconds later). `Process.is_boot_server` (set for
the 10 kernel-spawned servers + respawns) + `g_boot_quiet` +
`SYS_BOOT_QUIET`: once set, `SYS_PUTCHAR` from a boot server is dropped.
The shell calls it after `shell_boot_settle(ticks)` — ~3s QEMU / ~6s
Duo (raw `rdtime` delta, per-board — no board-agnostic "seconds" in
user mode). Supervisor `svc:` lines stay (kernel-side, rare, useful).
A `dmesg` recall of the dropped lines is a later add.

**cwd** (`e89affb`). `Process.cwd` (absolute, `""` = root), inherited
across rfork, kept by exec — like uid/namespace. `SYS_CHDIR` /
`SYS_GETCWD`. `user.c3`'s `fs_abspath()` — injected into every `fs_*`
wrapper and `exec()` — resolves a relative path against cwd; absolute
passes through; empty means "the cwd" (so `ls` with no arg lists where
you are). `exec_path()`'s default PATH is now `/bin/` (absolute).
`cd` builtin (`.`/`..`/`//` normalised, home `/usr/$user` falling back
to `/`), `pwd`. Prompt: `root /usr/glenda #`.

**`$var` expansion** (`5fc3c69`). `shell_expand()` runs before
tokenising. `$user`/`$cwd`(`$PWD`)/`$home` synthesised from the shell's
cached state + `getcwd()`; anything else reads `/env/<name>`, empty if
unset (rc semantics). `$` not followed by a name char stays literal.
`echo` builtin (there was none). No braces/quotes yet.

**Verified QEMU:** `cd`/`pwd`/`..`, `ls`/`cat` resolving under cwd,
`echo hello $user` → `hello root`, `$cwd` tracks `cd`, `$user` reflects
`su`, `$5` literal; clean `root /` prompt with all boot chatter above
it. Full regression (`pathtest` / `fsneg` / `fspermtest` / `envtest` /
`bigreadtest` / `runtest` / `argvtest` / the p9/fs suite) unchanged.
**Duo:** boot-quiet confirmed on hardware (clean prompt, logs above).
The cwd/`$var` binaries in the Duo's `/bin` are stale until
`scripts/populate_duo_bin.sh` is re-run — a kernel-only reflash can't
touch the ext2 partition; builtins (`cd`/`pwd`/`echo`/`$var`) work
regardless.

---

## 2026-08-29 (continued) — §2: the Plan 9 user model (identity + read enforcement)

Roadmap §2, two commits.

**Identity** (`d1de99d`). The kernel already had `Process.uid` +
`setuid` (drop-only) + write-side fs ownership; what was missing was
*being* a named user.
- `SYS_GETUID` (35) — a process learns its own uid.
- `user_uid_by_name` / `user_name_by_uid` in `user.c3` parse
  `/adm/users` (`uid:name` lines); uid 0 → `root` even with no file.
- **`su <user>`** shell builtin — one-way (`setuid` never elevates —
  Plan 9's "become none, never come back"); `exit` for a fresh root
  shell.
- **prompt** — `<user># ` for root, `<user>% ` otherwise; cached,
  refreshed after `su`. `/bin/whoami`.
- `/adm/users` seeded `0:root` + `1000:glenda`; `/usr/glenda`.

  Not done: a boot-time `login`/`getty` — the console still comes up as
  a root shell. Folding `login` into shell startup needs a cwd/`$HOME`
  concept, deferred with the shell work.

**Read enforcement** (`05aa0bf`). Reads were open to everyone.
- `ext2_read_allowed` (`S_IRUSR`/`S_IROTH`, mirrors
  `ext2_write_allowed`) + `ext2_may_read` (name → inode → check; an
  unresolvable name stays "not found", not a denial).
- `fsd`'s `FS_READ` / `FS_READ_AT` / `FS_LIST` / `FS_STAT` and the
  `P9_OPEN` read path pass `fsd_requester_uid(from)`; the `ext2_op_*`
  read adapters gate on it. **ext2 only** — FAT32/exFAT have no
  ownership; root always passes.
- `65534:none` added; a mode-0600 `/adm/secret` fixture makes denial
  testable.

**Verified QEMU:** `root#` → `su glenda` → `glenda%`; `whoami`; `su
root` denied; `cat hello.txt` (0644) ok as glenda, `cat adm/secret`
(0600) denied; `ls` ok. Full regression — `fspermtest` / `bigreadtest`
/ `p9fstest` / `p9fswritetest` / `p9mkdirtest` / `fswriteat` /
`fsdkilltest` / `runtest` / `mounttest` / `srvtest` / `sandboxtest` /
`killtest` / `mutextest` — unchanged (the test shell runs as root).
Real Duo: clean boot, `root#` prompt, `ls` + `cat`.

---

## 2026-08-29 (continued) — §1: Plan 9 file structure + hardcoded server pids removed

Roadmap §1, two commits.

**Hardcoded pids gone** (`f025db5`). Two servers were addressed by a
literal pid that only worked because of spawn order: `echod` (created
first → pid 2, baked into `create_process`'s `namespace[0]`) and the
block driver (`fsd.c3`'s `DISKD_PID = 3`). Both blocked supervising
those servers (a respawn lands elsewhere).
- `echod_pid` global; `namespace[0]` ("/srv/echo/") seeds from it.
  `echod` is now in the supervisor table.
- `storage_pid` global; `SYS_FS_PARTITION_INFO` gains an `a2` out-param
  for it; `fsd.c3`'s `g_diskd_pid` starts 0 and boot `fsd`/`fsd2` set it
  from that syscall (the dynamic USB instance already resolved its
  backend by name).

**Canonical root tree** (`3b044ab`). `docs/filesystem-layout.md` is the
reference:

```
/bin /lib /usr /usr/root /adm /adm/users /tmp /mnt    real ext2 dirs
/proc/ /srv/ /env/ /mnt/fs2/                           namespace mounts
```

No `/dev` (devices are servers), no `/etc` (host config → `/adm`).
`scripts/build.sh` seeds it into the QEMU ext2 images via `debugfs`;
`scripts/populate_duo_bin.sh` creates it on the real Duo. `/adm/users`
starts `0:root` — §2 defines the real format.

Verified QEMU (`launch64_ext2`): `ls` → `bin/ lib/ usr/ adm/ tmp/
mnt/`, `cat adm/users` → `0:root`, `ls usr` → `root/`; full p9/ipc/fs
regression (`ping` / `p9fstest` / `p9fswritetest` / `mounttest` /
`srvtest` / `sandboxtest` / `fsdkilltest` / `runtest` / `killtest` /
`mutextest`) unchanged. Real Duo: clean boot, `ls` + `cat`.

Still in §1: a namespace view (`/proc/$pid/ns`), `bind`/`mount`
builtins — deferred until §2 (user model) shapes them.

---

## 2026-08-29 (continued) — resiliency: SYS_IPC_CALL, the client RPC round-trip as one syscall

Roadmap §5.1b — closes the last "hang forever" IPC path and retires
`p9_call`'s `P9_STRAY` bounce.

A client's request+reply used to be three user-space steps: `ipc_send`,
then an `ipc_recv` loop that bounced any non-reply sender back as
`P9_STRAY`. Problems: a server that crashed *after* consuming the
request left the client stuck in `ipc_recv` (the §5.1a fix only reached
the send rendezvous), and the bounce could starve the real reply if the
server's own round-trip ran long (`exec`'s `runtest`, historically).

**`SYS_IPC_CALL`** (`6879b89`) does the whole thing in the kernel:
- `Process.in_call_reply_wait` reserves the caller's inbox for the
  target's reply for the call's whole duration. `ipc_inbox_available()`
  makes a stray `ipc_send`/`ipc_reply` from a third party wait in its
  phase-A loop instead of landing — nothing to mistake for the reply,
  no bounce.
- `ipc_peer_gone()` checked in all three phases (deliver / wait-consume
  / wait-reply) → returns −1 if the target dies at any point.
- in-place buffer: `a4` packs `(req_len<<16)|buf_cap`, `a5` = optional
  reply-verb out. `p9_call` is now a 5-line shim (copies
  `data`→`reply_buf` only for `p9_read`, the one caller with separate
  buffers).

`exec()`'s `notify_pid` is no longer load-bearing for correctness — the
reservation closes the too-early-message race at the source. Kept for
ordering.

**Verified QEMU:** full p9 / ipc / fs / exec regression green —
`p9fstest` / `p9fswritetest` / `p9mkdirtest` / `p9realtest` / `srvtest`
/ `nstest` / `mounttest` / `hotplugtest` / **`runtest` + `runtest2`**
(the exec-does-`p9_call`-while-pinged case `P9_STRAY` existed for) /
`argvtest` / `bigreadtest` / `fsdkilltest` / `ipcdeathtest` /
`killtest` / `threadjointest` / `mutextest` / `racetest` / `envtest` /
`hardentest` / `sandboxtest`. Real Duo: clean boot, `ls` + `cat` +
exec.

---

## 2026-08-29 (continued) — resiliency: boot-server supervisor

`docs/roadmap.md` §5.2. A crashed server used to stay dead — the kernel
only ever respawned the shell, and only when nothing was runnable.

**`src/supervisor.c3`** (`7b5b97c`): a `Service` table (fsd, fsd2,
procd, envd), registered from `kernel_main` right after each server
spawns. `supervisor_tick()` runs once per timer tick (~1/s) from
`handle_trap`'s `SCAUSE_SUPERVISOR_TIMER` case — **not** the idle loop,
because idle is starved whenever any process stays permanently
`PROC_RUNNABLE` (usbd on the Duo, netd's link poll on QEMU). On a
server's death (`proc_by_pid` mismatch on pid+generation):

- `create_process()` + `setup_fsd_mappings()` for fsd/fsd2,
- update the `*_pid` global `create_process()`'s namespace seeding
  reads (so *new* processes get the right pid),
- `reseat_namespace_mounts()` — walk every live process, re-point any
  namespace mount that named the dead instance, so already-booted
  processes pick up the replacement on their next `ns_resolve()`,
- restart cap 5, then give up + log.

**Only the pure-IPC / trivial-setup servers.** Device drivers need
MMIO/DMA re-mapping and some carry hardcoded-pid conventions
(`fsd.c3`'s `DISKD_PID=3`); echod's pid 2 is baked into the shell's
`ping`. Kernel-side rather than a userspace `/bin/init` because the
privileged `setup_*_mappings` is kernel-only and the server binaries
are embedded in the kernel image, not on disk.

**Bug found:** `io::print` faults inside the timer trap (`No method
'write_byte'` — the std::io output target isn't wired up in that
context, and the panic printer then fails the same way → "Panic inside
of panic"). The supervisor writes straight to the console via
`board::console_putchar`.

**Verified QEMU:** new `fsdkilltest` — `kill` fsd outright →
`svc: respawned fsd` → `fsd: FAT32 mounted` → the shell's `fs_read`
works again *through the healed mount, without the client re-mounting
anything*. Full p9/ipc/fs regression (`ipcdeathtest` / `p9fstest` /
`p9fswritetest` / `mounttest` / `srvtest` / `hotplugtest` / `killtest` /
`threadjointest` / `mutextest` / `racetest` / `envtest` / `runtest` /
`fswriteat`) unchanged. Real Duo: clean boot, no spurious respawns,
`ls` + `cat`.

---

## 2026-08-29 (continued) — resiliency: IPC rendezvous no longer hangs on peer death

First slice of `docs/roadmap.md` §5. The IPC rendezvous had no failure
path — a process blocked in `sys_ipc_send` (waiting for its message to
be acked) or `sys_ipc_reply` (waiting for the client to consume the
reply) hung forever if the peer exited or was killed. `SYS_KILL`'s own
comment already admitted it: *"left blocked forever — nothing forcibly
unblocks a waiter."*

**Fix** (`262d45b`):
- `Process.ipc_wait_pid` / `ipc_wait_generation` / `ipc_peer_died` —
  set while a process is blocked in send/reply toward a specific peer,
  reset in `create_process` + the rfork child path (the slot isn't
  zeroed on reuse).
- `sys_exit` / `sys_kill` → `ipc_wake_waiters_on(victim)`: sweeps the
  table before the victim's pid is zeroed, sets `ipc_peer_died` +
  marks `PROC_RUNNABLE` anyone parked toward it.
- both wait loops poll `ipc_peer_gone()` (the flag, plus a direct
  `proc_by_pid` + generation check for the phase-A case where the
  waiter is still `RUNNABLE`) and return −1.
- `p9_call` already bailed on `ipc_send() < 0`, so it propagates to 9P
  clients for free.

New `ipcdeathtest` (`shell_test.c3`): child never `recv`s and
`exit()`s; parent's `ipc_send` returns −1 instead of hanging.
Deterministic. Full p9/ipc regression suite (`p9realtest` /
`p9fstest` / `p9fswritetest` / `p9mkdirtest` / `srvtest` / `nstest` /
`mounttest` / `hotplugtest` / `killtest` / `threadjointest` /
`mutextest` / `racetest` / `envtest` / `runtest`) unchanged. Real Duo:
clean boot, `ls` + `cat`.

**Still hangs** (roadmap §5.1b): a client blocked in `ipc_recv`
*awaiting a reply* from a server that crashes after receiving the
request — `ipc_recv` isn't peer-specific. Wants a kernel `ipc_call`
round-trip primitive (which would also retire `p9_call`'s `P9_STRAY`
dance).

---

## 2026-08-29 — session summary: xpad STALL → cleanup → roadmap → resiliency → §1/§2 → the shell (§2.5)

One long session (2026-08-28 into the 29th). A reported bug, then
structural cleanup, then — prompted by the user thinking about where
the project goes next — a roadmap doc, and then a sustained push down
it: resiliency (§5), the Plan 9 file structure (§1) and user model
(§2), and finally the shell (§2.5) built out from a bare `> ` prompt
to cwd + `$var` + pipes + redirection + `;`/`&&`/`||` + quoting.
Per-topic entries below; the arc:

### Bug + cleanup

1. **xpad SETUP STALL** (`581954e`) — the 8BitDo pad had stopped
   enumerating (`GET_DESCRIPTOR(18)` → `HCINT=0x0a` STALL) ever since
   interrupt-driven USB landed. Two wrong turns first (strong-order MMIO
   on the DWC2 regs; a `USBD_VERBOSE` build that "fixed" it purely
   through print latency), then the real cause: `hc_transfer_once_split`
   issued the non-periodic complete-split in the *same microframe* as
   the start-split. Fine while `hc_wait_chhltd` `yield()`-polled; the
   interrupt-driven wait tight-spins. Fix: a 150µs gap. The pad's
   interrupt-IN is still silent — the separate, long-standing
   8BitDo-specific issue.

2. **Irq_route table** (`f2f7270`) — `handle_trap`'s three hand-written
   per-device IRQ branches + the pid-switch in `SYS_DRIVER_IRQ_ARM`
   collapsed to one `{irq,pid,level}` lookup. Five write-only `*_pid`
   globals deleted; ethd's route pre-registered.

3. **Shared user helpers** (`55de499`) — `mmio_read32`/`write32`,
   `print_hex8`/`32`, `panic()` had byte-identical copies in 5–6 driver
   files each; hoisted into `user/user.c3`. −150 lines.

4. **`handle_syscall` split, 1700 → 340 lines**
   (`79e0e68` / `5c9525d` / `23bd80a`) — every case ≥40 lines
   (`SYS_EXEC` 416, `SYS_RFORK`, `SYS_KILL`, `SYS_EXIT`, + 11 medium)
   extracted to `sys_*(f)` functions. Blocked for a year by an
   undiagnosed c3c 0.8.2 codegen bug (factoring a function out of that
   switch reboot-looped the kernel from the first syscall, hit 3×).
   **Probed on 0.8.3 with `SYS_KILL` — the bug is gone.**

5. **`hardentest` fixed** (`20d88ab`) — a rotted test: it called
   `syscall(31)` as its "unrecognized number", but 31 is `SYS_KBD_PUSH`
   now. `p9fstest`/`mounttest` "failures" were just the wrong disk image
   (FAT32-only vs `disk_dual`).

### Direction

6. **`README.md` rewritten** (`6993f71`) — the old three lines still
   said "32-bit toy following the tutorial." Now describes the actual
   thing: a `rv64imac` microkernel, QEMU + Milk-V Duo, the real feature
   set, build/run/flash.

7. **`docs/roadmap.md`** (`0877437` / `a92369f` / …) — the post-bring-up
   plan, direction agreed with the user: Plan 9 file structure, Plan 9
   user model, hardware FPU (the float-panic is deferred port work —
   the C906 *has* an FPU, the toolchain is just built hardware-float so
   it ships no soft-float multilib), a `/bin/wasm` interpreter, and
   §5 resiliency + §6 a real 9P translator (later — today's protocol is
   9P-*inspired*, not wire-compatible).

### Resiliency (§5)

8. **IPC rendezvous peer-death** (`262d45b`) — `ipc_send`/`ipc_reply`
   return −1 instead of hanging forever when the peer exits mid-
   transfer. `Process.ipc_wait_pid` + `sys_exit`/`sys_kill` sweep.

9. **Boot-server supervisor** (`7b5b97c`) — `src/supervisor.c3`:
   fsd/fsd2/procd/envd respawn on exit (from the timer trap, not the
   starvable idle loop), with `reseat_namespace_mounts()` so existing
   clients transparently reconnect. `fsdkilltest` proves the full
   loop. Device drivers not yet supervised (hardcoded-pid conventions).

10. **`SYS_IPC_CALL`** (`6879b89`) — the client RPC round-trip as one
    syscall. Closes the last hang (client stuck in `ipc_recv` after a
    server dies post-request), and its inbox reservation retires
    `p9_call`'s `P9_STRAY` bounce. `p9_call` is now a 5-line shim.

**After this session there are no "hang forever" IPC paths, and a
crashed fsd recovers on its own.**

### §1 Plan 9 file structure + §2 user model

11. **Canonical tree + hardcoded-pid removal** (`f025db5` and around) —
    `/bin /lib /usr/$user /adm /tmp /mnt` seeded identically on QEMU
    (`build.sh`) and Duo (`populate_duo_bin.sh`);
    `docs/filesystem-layout.md` is the reference. `echod` (was baked as
    pid 2 in `namespace[0]`) and the block driver (`DISKD_PID=3`) now
    come from `echod_pid` / a `SYS_FS_PARTITION_INFO` out-param. An
    `Irq_route` table + `mount_generation()` fell out of the same pass.

12. **User model — identity + read enforcement** (`d1de99d` /
    `05aa0bf`) — `/adm/users` (`uid:name`), `user_uid_by_name` /
    `user_name_by_uid`, `SYS_GETUID`, `su <user>` (one-way, Plan 9's
    "become none, never come back"), `/bin/whoami`, the prompt shows
    the user (`root #` / `glenda %`). `ext2_read_allowed` / `_may_read`
    gate fsd's read/list/stat/`P9_OPEN` on the requester uid (ext2
    only, root bypasses).

### §2.5 The shell

13. **boot-quiet, cwd, `$var`** (`138b6ab` / `e89affb` / `5fc3c69`) —
    `SYS_BOOT_QUIET` silences boot-server console spam once the prompt
    settles; `Process.cwd` + `SYS_CHDIR`/`SYS_GETCWD` + `fs_abspath()`
    in every `fs_*` wrapper, `cd`/`pwd`; `shell_expand()` before
    tokenising — `$user`/`$cwd`/`$home` synthesised, else `/env/<name>`.

14. **pipes + redirection** (`0a9ccab`) — kernel pipe primitive
    (`src/pipe.c3`: ring buffer + writer/reader refcounts;
    `Process.stdout_pipe`/`stdin_pipe`); `SYS_PUTCHAR`/`GETCHAR` route
    through it; syscalls 39–44. `shell_run_pipeline` wires one `|` plus
    `<`/`>`/`>>`. `/bin/echo`, stdin-aware `cat`.

15. **`fsd` trailing-slash normalization** (`cfad305`) — `ls /` and
    `ls /bin/` reported "not found" (`ext2_leaf_name("/")` is `""`).

16. **`;` / `&&` / `||` + exit status** (`d3da7ac`) — kernel exit-status
    side table (`sys_exit`/`sys_kill` record `(pid, gen, code)`,
    `sys_join` returns it), `exit()` → `exitcode(int)`. `shell_exec_line`
    splits on ` ; ` / ` && ` / ` || `, expands + tokenises each pipeline
    just before it runs so `$status` mid-line is right. `/bin/true`,
    `/bin/false`.

17. **quoting** (`c450706`) — `shell_expand_q()` + a `qmask` byte array:
    `'...'` fully literal, `"..."` literal but `$name` expands; the
    tokeniser splits and recognises operators only on unquoted bytes.

18. **`/bin/head` + multi-stage pipelines — shelved** (`a3d3f04` /
    `83e592f`) — `head [-n N]` (first stdin filter, works in 2-stage).
    `a | b | c` (3+ stages) is **blocked on a kernel race**: 3
    concurrent `exec()`s keep `sstatus.SIE` globally off, so diskd's
    busy-spin disk-completion wait starves → fsd blocks on diskd → the
    stage blocks on fsd → the shell's `join()` hangs. Root cause fully
    pinned; two fix attempts (PLIC drain from `yield()`; diskd used-ring
    poll + virtio ISR ack) both hit a different wall (`bigreadtest`
    regressed / still hangs downstream). Filed in roadmap §2.5 for a
    focused session.

**Deferred:** timebase dedup (poor ratio — `kbd.c3` compile-time
const); interrupt-driven ethernet RX (needs a test peer); device-driver
supervision (needs the pid hardcodes gone first); multi-stage pipelines
(kernel race, above); the §1 `bind`/`mount` builtins + namespace view;
a boot-time `login`.

---

## 2026-08-28 (continued) — entry: the handle_syscall extraction landmine is gone on c3c 0.8.3

`handle_syscall` was a 1700-line function; its biggest cases (`SYS_EXEC`
416 lines, `SYS_RFORK` 160, `SYS_KILL` 132, `SYS_EXIT` 77) were kept
inline because factoring a moderately-complex function out of that
`switch` **reboot-looped the kernel from the very first syscall**, 3×,
on c3c 0.8.2 (see 2026-08-14 entry — never diagnosed, always fixed by
re-inlining).

**Probed on c3c 0.8.3** (this machine): extracted `SYS_KILL` →
`sys_kill(f)` in `entry.c3` (same file, fewest confounders). Boots
clean single-cycle on QEMU **and** real Duo; `killtest` passes
(including the page-table teardown path). **The landmine is fixed.**

So also pulled out `sys_exit()` (uses no `f` — pure `current_proc`
teardown + `yield()`) and `sys_rfork(f)`. `handle_syscall`: 1700 →
1366 lines; the three are now named, jump-to functions above it.

- **Gotcha found mid-probe:** a blanket `break;`→`return;` conversion
  is wrong — a `break` inside a `for`/`while` in the case body must
  stay. The reliable discriminator in this switch: a `break` whose
  preceding line is an `f.a0 = …;` bailout assignment is switch-level
  → `return`; anything else is a loop break → stays. (`sys_kill`'s
  shared-page-table loop break got miscompiled to `return` first;
  caught because `killtest`'s echod isn't an rfork sibling so that
  path never ran — fixed before commit.)

**Verified:** QEMU — `rforktest` / `threadtest` / `threadjointest`
(`thread_result = 99`) / `mutextest` (16/16) / `killtest` / `hello` /
`exit`. Real Duo — clean boot, USB enumerates, ext2 mounts via SDMA,
`ls` + `cat` (each fork→exec→exit).

**`SYS_EXEC` — done too** (commit `5c9525d`, later the same run):
`sys_exec(f)`, 416 lines out. 8 case-level `f.a0=-1; break;` → `return`,
5 loop breaks (PT_LOAD scan, per-page alloc, argv pages) kept, each
discriminated by its preceding line. `handle_syscall`: **1700 → 952
lines**. QEMU `argvtest` ok + the usual set; Duo clean boot, ls/cat.

**The 11 medium cases too** (commit `23bd80a`): `sys_ipc_send` /
`_reply` / `_recv` / `_recv_gen` / `_poll` / `sys_ns_resolve` /
`sys_join` / `sys_futex_wait` / `sys_proc_info` / `sys_srv_post` /
`sys_ns_mount_wait`. **`handle_syscall`: 340 lines** — a dispatch table.
Total for the run: **1700 → 340**.

Break classification for this batch used a nesting-aware pass (a
loop/switch stack, `//` comments stripped) instead of the
preceding-line heuristic — the first crude version misclassified the
`for`-loop breaks in `sys_join` / `sys_srv_post` / `sys_ns_mount_wait`
/ `sys_futex_wait` as switch-level. The corrected pass agreed with
every loop break in the already-extracted `sys_kill`/`sys_rfork`/
`sys_exec`. A clean compile then rules out the *other* direction (a
switch-break wrongly kept → "break outside loop").

Verified QEMU (`launch64_dual` — two partitions, ext2 backend):
`p9fstest` / `p9fswritetest` / `mounttest` / `srvtest` / `nstest` /
`threadjointest` (99) / `mutextest` (16/16) / `racetest` (a=1 b=1) /
`argvtest` / `killtest` / `runtest` / `envtest` / `sandboxtest` / and
`hardentest` — all ok. Real Duo: clean boot, `ls` + `cat`
(shell↔fsd is IPC + ns_resolve per command).

The p9/mount tests had looked like failures earlier only because they
were run against the plain FAT32-only `disk.img` (`launch64.sh`) —
`p9fstest` needs ext2, `mounttest` needs `/mnt/fs2/`. Not bugs, not
regressions: wrong disk image.

**`hardentest` was a genuinely rotted test**, fixed (`20d88ab`): it
called `syscall(31, …)` as its "unrecognized number" (picked when 30
was the max), but 31/32/33 (`SYS_KBD_PUSH` etc.) were added since — so
that was a valid `SYS_KBD_PUSH` (push a NUL keystroke) returning 0. The
`default:` case denied unknown syscalls correctly all along. Now `999`.

---

## 2026-08-28 (continued) — user: shared mmio/hex/panic helpers

Cleanup. Every device-register driver had its own byte-identical copy
of `mmio_read32`/`mmio_write32` (dwc2, sdhci, dwmac, gpiod, virtio),
`print_hex8`/`print_hex32` + a `HEX_DIGITS` const (dwc2, sdhci, ethd,
netd), and a `<prefix>_panic(char*)` that differed only in the log
prefix (diskd, sdd, ethd, usbd, netd, fsd). `user/user.c3` is linked
into every user program, so all of it moved there:

- `mmio_read32` / `mmio_write32` — `mmio_read64` stays in `virtio.c3`,
  the only caller, and its signed-`lw` masking is the reason it's
  special
- `print_hex8` / `print_hex32` / `HEX_DIGITS`
- `panic(char* prefix, char* msg)` — callers pass `"diskd: "` etc.; the
  UB/optimizer rationale for `exit()` over an empty `for(;;){}` (it got
  dropped under -O2 once) is documented in the one place now

Net −150 lines, no behaviour change. Verified: QEMU (diskd, netd `mac=`
via the shared `print_hex8`, fsd) and real Duo (sdd SDMA + ext2, ethd
bring-up with `print_hex32` register dumps, gpiod, USB hub + keyboard +
pad).

Not done — **the per-driver `*_TIMEBASE_HZ` / `*_us_to_ticks`
duplication** (5 identical `25000000` consts on the Duo side, plus
netd's genuinely-different `10000000` for QEMU). A `timebase_info()`
syscall (precedent: `fs_partition_info`) is the clean fix but
`kbd.c3` bakes `USB_TIMEBASE_HZ` into a compile-time `const`
(`KBD_REPEAT_DELAY_TICKS`) that would have to become runtime, and it's
~49 call sites. Deferred as a poor effort/payoff ratio for now.

---

## 2026-08-28 (continued) — kernel: device IRQs go through an Irq_route table

Consolidation, not a feature. Three interrupt-driven drivers (diskd,
sdd, usbd) had each landed their PLIC routing ad-hoc, and it showed:
`handle_trap`'s external-interrupt branch was three near-identical
`if (irq == board::IRQ_X && X_pid != 0) { wake X }` blocks plus a
hand-maintained disable-on-fire condition, and `SYS_DRIVER_IRQ_ARM` was
a pid-switch (`usbd_pid → IRQ_USB`, `sdd_pid → IRQ_SDHCI`). Adding
interrupt-driven ethernet RX would have meant editing both spots again.

**Now:** a fixed `Irq_route` table (`{irq, pid, level, used}`, 8 slots)
in `process.c3`. Each driver registers one route from its
`setup_*_mappings` — where it already has its pid and its `board::IRQ_*`
constant in hand. `handle_trap` does one `irq_route_by_irq()` lookup,
posts `DISKD_IRQ_NOTIFY` to `route.pid`, `plic_complete`s, then disables
the source iff `route == null || route.level`. A `level=false` route
(virtio-mmio — diskd acks it via the virtio ISR register) stays
enabled; that replaces the old `handled_irq` special case exactly.
`SYS_DRIVER_IRQ_ARM` → `irq_route_by_pid(current_proc.pid)`.

- `diskd_pid` / `sdd_pid` / `usbd_pid` / `ethd_pid` / `netd_pid` are
  gone — grep confirmed they were read *only* in those two IRQ spots.
  The `*_dma_paddr` / `*_vq_paddr` globals the `SYS_*_INFO` syscalls
  hand back are untouched.
- ethd registers `{IRQ_ETH, level=true}` now, inert until
  `board::plic_init` arms source 31. Interrupt-driven ethernet RX is
  then: arm the source + unmask the dwmac interrupt + wait on the
  notify — no kernel routing edit.
- `irq == 0` is the "device absent on this board" sentinel
  (`board::IRQ_USB` etc. are 0 on QEMU) and `plic_claim`'s spurious
  return; `irq_route_register(0, …)` and `irq_route_by_irq(0)` both
  no-op, so QEMU (only virtio-blk real) and Duo (USB/SDHCI/ETH real,
  virtio 0) both stay correct.

**Verified.** QEMU: boots, `fsd: FAT32 mounted` (diskd served reads
through its `DISKD_IRQ_NOTIFY` wait, whose only source is the new
lookup). Real Duo: ext2 mounts via SDMA, USB hub + keyboard + pad
enumerate, shell responsive, no storm — both `level=true` routes and
the re-arm path exercised.

---

## 2026-08-28 (continued) — xpad SETUP STALL: a non-periodic complete-split issued in the same microframe as the start-split; the interrupt-driven wait removed the slack that hid it

The 8BitDo SN30 Pro (full-speed, hub port 4) had been failing
`GET_DESCRIPTOR(18)` with `HCINT=0x0000000a` (CHHLTD|STALL) on the
split SETUP stage every boot since the strong-order MMIO / interrupt-
driven USB change (`aa86a49`). The earlier entry called it "the
pre-existing 8BitDo split quirk, unrelated" — **wrong**. Timeline from
the devlog itself: before `aa86a49` the pad enumerated fully, took the
EP0 vendor "magic message" with no STALL, and drove its rumble motors
over interrupt-OUT; only its interrupt-IN was ever silent. After
`aa86a49` it couldn't get past `GET_DESC(18)`. A regression, not the
quirk.

**Root cause: the non-periodic (control/bulk) complete-split went out
in the same microframe as the start-split.** USB 2.0 §11.18.4 has the
host schedule a CSPLIT in the microframe(s) *following* its SSPLIT; a
fast full-speed hub TT polled too early can return STALL instead of
NYET. `hc_transfer_once_split`'s non-periodic path never gated the
CSPLIT on the frame counter (the interrupt path does), it just looped
`hc_wait_chhltd` → issue CSPLIT. That was fine as long as
`hc_wait_chhltd` `yield()`-polled — a `yield()` round-trip reliably
burned more than a 125µs microframe. `aa86a49`'s interrupt-driven
`hc_wait_chhltd` tight-spins, so the CSPLIT started firing immediately.
The low-speed keyboard on port 1 is ~8× slower on the downstream bus,
so its TT was still busy when the CSPLIT landed — it never raced, which
is why `aa86a49` looked clean.

Diagnosed by accident: a `USBD_VERBOSE` build enumerated the pad fine,
verbose-off didn't. The only per-transfer difference was a ~2.6ms UART
`print` before each SETUP stage — an artificial delay. That plus the
`np-split` trace (every SSPLIT cleanly ACKed, `HCINT=0x22`; failure
purely on the complete-split) pointed straight at CSPLIT timing.

**Fix** (`user/usb/dwc2.c3`): a ~150µs busy-wait (>1 microframe) before
the non-periodic complete-split loop. Well inside that loop's existing
4-frame retry budget. One line of actual code. Bisected on hardware:
this alone fixes it — `addr_settle` stays 10ms, no MMIO changes.

Also added: `g_split_np_diag_count` + a `USBD_VERBOSE`-gated
non-periodic-split trace in `hc_transfer_once_split` (parallels the
existing `g_split_intr_diag_count`).

**Verified on real Duo:** `usbd: hub port 4: enumerated device
vid=0x045e pid=0x028e`, `xpad: controller found ... interrupt IN
endpoint 0x81`, `xpad: LED command sent`. Keyboard on port 1 and the
hub still enumerate. The pad's interrupt-IN then returns
`complete-split NAK` forever again — back to the *original*,
documented, device-specific 8BitDo silence that needs a bus analyzer
(`racccoon-xpad-input`). Not a regression; not this fix's problem.

**Considered and dropped:** reverting Strong Order on the DWC2 register
block (a `PTE_NONCACHED_BITS` / `map_noncached_page` split, SO reserved
for the PLIC claim register). Plausible on its own merits — SO on a DMA
scribble-buffer is genuinely wrong, and it's just a perf tax on
side-effect-free registers — but it is NOT what fixed the STALL
(verbose-off + weak-NC still STALLed), so it's left for a separate
change if ever wanted.

### Session arc (the dead-ends, so a future session doesn't re-walk them)

1. **Timeline analysis first.** The devlog's own earlier entries proved
   the pad enumerated + took EP0 vendor requests + drove rumble before
   `aa86a49` and STALLed `GET_DESC(18)` after — so a regression in that
   commit, which bundled *two* changes: strong-order MMIO and
   interrupt-driven USB.
2. **Wrong hypothesis: strong-order MMIO.** Reasoned that SO's
   per-access round-trip cost slowed split-channel arming enough to
   race the TT. Two flashes chasing it:
   - `map_dma_page` (weak-NC) for the USB DMA buffer only → no change,
     still STALL. (Correctly predicted neutral — kept as a candidate
     cleanup, later dropped.)
   - weak-NC for the DWC2 register pages too, **with `USBD_VERBOSE=on`**
     → pad enumerated. Looked like the fix.
3. **The verbose build was lying.** Verbose-off with the same weak-NC
   mapping → STALL again. The variable was `USBD_VERBOSE`, not the
   mapping: each control transfer prints a ~2.6ms UART line right before
   its SETUP stage, and port 4 emitted no `np-split` lines (counter
   already spent on the keyboard), so that pre-SETUP print was the only
   added delay.
4. **Right hypothesis: CSPLIT timing.** The pre-SETUP delay pointed at
   the interrupt-driven `hc_wait_chhltd` (tight-spin vs the old
   `yield()`) firing the non-periodic complete-split in the
   start-split's own microframe. Added a 150µs gap + bumped
   `addr_settle` 10→50ms in one flash → worked.
5. **Bisected to the minimum.** `addr_settle` back to 10ms, keep only
   the 150µs gap → still works. Dropped the weak-NC mapping (not the
   cause) and the `addr_settle` bump. Committed just the gap.

Lesson: `USBD_VERBOSE` changes timing enough to mask/unmask timing bugs
— A/B with it fixed in one state, and prefer the `g_split_*_diag_count`
counters (bounded, cheap) over blanket verbose for split work.

---

## 2026-08-28 (continued) — sdd: SDMA + interrupt-driven completion

With the strong-order MMIO fix (entry below) the PLIC is usable, so
sdd's block I/O moved off PIO onto the SDHCI SDMA engine + an
interrupt-driven completion wait.

- **`sdhci.c3`**: new `sdd_block_rw_dma()` — writes the physical
  staging-buffer address to `SD_DMA_ADDRESS` (0x00), sets
  `SD_TRNS_DMA` in the transfer mode (`sd_send_cmd` does this when
  `g_sd_dma_addr_pending` is set), clears HOST_CONTROL's DMA-select
  field to SDMA and forces HC2 "Host Version 4 Enable" off (both were
  needed — without the HOST_CONTROL clear the transfer stalled with
  `int=0x1`, command-complete but no `DATA_END`), then waits for
  `SD_INT_DATA_END`. No PIO FIFO, so the shallow-FIFO timing discipline
  the old path lives under doesn't apply — `ipc_poll_type` + `yield()`
  during the wait are fine, and the CPU is genuinely free while the
  DMA runs. `SDD_USE_DMA` gates it (checks `SD_CAPABILITIES` bit 22 at
  init); PIO stays as the fallback. `SDD_DMA_INTERRUPT` gates the
  interrupt wait vs a tight poll.
- **`board::IRQ_SDHCI`** (36) is now armed in `plic_init` (second
  enable word, `INTERRUPT_DRIVEN_SD`). `handle_trap`'s existing
  `IRQ_SDHCI` branch wakes sdd; the disable-on-fire logic (shared with
  USB) now covers it too.
- **New kernel plumbing**: `sdd_dma_paddr` (one identity-mapped
  uncached page, `setup_sdd_mappings`) handed back via `SYS_SDD_INFO`
  (33). `SYS_USB_IRQ_ARM` generalized to `SYS_DRIVER_IRQ_ARM` (still
  32) — re-arms `IRQ_USB` or `IRQ_SDHCI` by caller pid.

**Verified on real Duo:** `sdd: SDMA enabled`, `fsd: ext2 mounted`,
`ls` / `ls bin` (full binary list) / `cat bin/cat` all read via SDMA
under load, no storm, responsive shell. For a fast 512-byte transfer
`DATA_END` is already set by the time the wait loop first checks, so it
short-circuits — the IRQ still fires async, `handle_trap` disables
source 36, the next transfer re-arms it. No storm in any ordering
(confirmed: the card's SDHCI IRQ line drops when sdd clears
`SD_INT_STATUS`, before or after `handle_trap` runs).

Not done, deferred: interrupt-driven ethernet RX (same pattern,
`IRQ_ETH` = 31) — needs a live link + a peer to test against, which
isn't available right now. The strong-order fix and the `handle_trap`
disable-on-fire path already cover it; it's a short conversion when the
test rig is back.

---

## 2026-08-28 (continued) — interrupt-driven USB WORKS. Root cause: MMIO was weakly-ordered, not strong-ordered.

**Solved, hardware-verified.** The whole "PLIC storm" saga — every
attempt to arm a PLIC source ending in a permanent storm with
`plic_claim()` returning 0 while `sip.SEIP` stayed asserted (2026-08-17
SDHCI, and all of this session) — was **`map_device_page()` mapping
device MMIO as weakly-ordered non-cacheable instead of strong-ordered.**

On the MAEE-enabled T-HEAD C906, PTE bits [63:59] encode the memory
type. `map_device_page` set them all to 0 → SO=0 (weak order), C=0, B=0
= "Normal Non-cacheable, weakly ordered". An old comment here claimed
that was "Strong-Order/non-cacheable" — **wrong**. Strong Order is bit
63. Under weak ordering the C906 reorders / merges / speculates MMIO
reads, and the PLIC claim register — whose value tracks live PLIC state
and whose *read has a side effect* — comes back as a stale 0.

**The fix** (`boards/duo/board.c3` + `src/page.c3`):
`const ulong PTE_DEVICE_BITS = (1UL << 63) | (1UL << 60)` (SO | SH) on
the Duo, `0` on QEMU; `map_device_page` ORs it at the leaf. Matches the
working **RVSPOC xv6 CV1800B port**
(`xhackerustc/rvspoc-p2308-xv6-riscv`), whose `PTE_THEAD_DEVICE` is
exactly `(1<<63)|(1<<60)` — that port runs S-mode under OpenSBI (loads
at 0x80200000 via FIP, no `CONFIG_RISCV_M_MODE`) with working UART /
GPIO / I2C / SPI interrupts, i.e. proof S-mode PLIC claim *does* work
on this SoC — racccoon was just corrupting the read.

Everything else that was "ruled out" this session (delegate bit,
priority quirk, register addresses, stuck-claim drain) genuinely
wasn't the cause — the addresses etc. were right all along. The
priority "25-31 only" thing (Opus, community.milkv.io/t/cv1800b-baremetal)
is real (write 31, read back 7) but priority 1 works fine once ordering
is correct — RVSPOC uses 1.

**Interrupt-driven USB, now live** (docs/usb-interrupt-plan.md):
- `boards/duo/board.c3`: `INTERRUPT_DRIVEN_USB`; `plic_init` arms PLIC
  source 30 (priority 1, threshold 0); `plic_set_enabled()` helper.
- `src/entry.c3` `handle_trap`: on `IRQ_USB` wake usbd via
  `DISKD_IRQ_NOTIFY` (mirrors diskd/sdd), then `plic_complete`, THEN
  `plic_set_enabled(IRQ_USB, false)` — the DWC2 line is level-high and
  can't be cleared from the trap handler, and this SoC re-traps before
  the returned-to context runs an instruction, so the source must be
  disabled on the way out. Also disables any unrecognized non-zero
  source (storm insurance). New syscall `SYS_USB_IRQ_ARM` (32) re-enables
  it, called from `hc_wait_chhltd`.
- `user/usb/dwc2.c3`: `USBD_INTERRUPT_DRIVEN`; `usbd_init` unmasks
  `GINTMSK.HCHINT` + `HAINTMSK[0]` + `HCINTMSK.CHHLTD`; `hc_wait_chhltd`
  spins on `ipc_poll_type` (no `yield()`) instead of polling, clears
  HCINT on CHHLTD (drops the line). HCINT stays the source of truth so
  a missed/late notify only costs latency.
- `create_process` already maps the PLIC pages; `usb_msc_ipc_poll`
  already drains-and-ignores non-MSC verbs, so a stray notify in usbd's
  inbox is harmless. No process.c3 change.

**Verified:** `ext-irq claim=30` on every USB transfer, hub enumerates
fully (device + config descriptors, `SET_ADDRESS`, hub descriptor,
multi-TT, 4-port scan) via interrupts, no storm, sdd/fsd/ethd all still
come up (the strong-order change touches every device mapping — no
regression). *(Correction, later the same day: the port-4 STALL was NOT
the pre-existing quirk — it was a real regression, but from the
interrupt-driven `hc_wait_chhltd` in this same change, not the MMIO
ordering. It tight-spins where the old one `yield()`-polled, so a
non-periodic complete-split started firing in the start-split's own
microframe. See the "xpad SETUP STALL" entry above.)*

**Latency:** `hc_wait_chhltd` tight-spins on `ipc_poll_type` only for
the first ~300us of a wait (a control/interrupt transfer or NAK cycle
finishes well under that); past that it `yield()`-paces so a slow
transfer — a big multi-packet MSC read, a stalling device — doesn't
hold the CPU. The IRQ notify still lands and re-runs usbd promptly.

**Now also unblocked:** interrupt-driven sdd and ethernet RX — same
strong-order fix, same `handle_trap` pattern. sdd additionally needs
its level-triggered `SD_INT_STATUS` acked before trap return.

**The OpenSBI patch** (`scripts/opensbi-thead-plic-delegate.patch`,
`build_opensbi_duo.sh`, `reflash_duo.sh PATCH_OPENSBI=1`) turned out
**not** to be needed — FSBL already sets the delegate bit. Kept as
inert infrastructure; the card carries the patched OpenSBI harmlessly.
A plain reflash works.

---

## 2026-08-28 (continued) — PLIC storm: the T-HEAD delegate rabbit-hole *(all wrong — see the strong-order MMIO entry above)*

Before finding the real cause (weak-ordered MMIO, entry above), a long
detour chasing the T-HEAD C900 PLIC's S-mode-access "delegate" bit at
`PLIC_BASE + 0x1FFFFC`. Collapsed here from three entries; the useful
facts, since they're still true:

- **Register addresses were right all along.** Confirmed against
  `StealthBadger747/xv6-riscv` and `ParkerTenBroeck/milkv-duos-rs`:
  S-enable `0x70002080`, S-threshold `0x70201000`, S-claim `0x70201004`,
  delegate/perms `0x701FFFFC`. `PLIC_S_CONTEXT = 1` is correct.
- **The FSBL already writes `[0x701FFFFC] = 1`** (`fsbl/lib/cpu/riscv/
  bl2_entrypoint.S`). So the delegate was never missing. The OpenSBI
  patch that re-asserts it (`scripts/opensbi-thead-plic-delegate.patch`
  + `build_opensbi_duo.sh` + `reflash_duo.sh PATCH_OPENSBI=1`) is inert
  — kept only for the GCC-16 build fixes / FDT-extraction tooling, in
  case a future M-mode change ever needs it. A plain reflash works.
- **S-mode access to `0x701FFFFC` hard-hangs the CV1800B** (no trap) —
  so racccoon can't poke it directly anyway.
- The priority "only 25-31 works, wraps mod-8" quirk (Opus,
  community.milkv.io/t/cv1800b-baremetal) is real — write 31, read
  back 7 — but priority 1 is fine once ordering is correct.
- Threads that helped narrow it: `community.milkv.io/t/cv1800b-baremetal/2445`,
  `.../cv1800b-plic-exception/3295`.

The "SOLVED via OpenSBI delegate, hardware-verified" claim that briefly
lived here (and in commit `21485d0`'s message) was a false positive —
it "worked" only because that test armed a *silent* PLIC source
(GINTMSK masked), so `claim()` was never actually exercised.

---

## 2026-08-28 (continued) — interrupt-driven USB: investigated, planned, deferred

Autonomous session ("go full auto on #3" — moving USB off transfer-
completion polling onto the DWC2 core interrupt). Outcome: full
implementation plan in `docs/usb-interrupt-plan.md`, no code.

What the investigation turned up:

- **CV1800B USB IRQ = 30** (level-high, plic0), from duo-buildroot-sdk
  `cv180x_base_riscv.dtsi`. IRQ 30 < 32 → first PLIC enable word (the
  simple case; `IRQ_SDHCI` 36 needs the second word).
- The racccoon "interrupt-driven" pattern is **user-mode-poll for a
  synthetic notify**, not park-and-wake: `handle_trap` posts
  `DISKD_IRQ_NOTIFY` into the driver's inbox and marks it runnable; the
  driver spins on `ipc_poll_type` (diskd/sdd template). A blocking
  `ipc_recv` mid-trap corrupts the trap frame (sscratch/SIE have no
  per-process save) — confirmed empirically per `SYS_IPC_POLL`'s
  comment.
- So the benefit vs. today is **modest**: `hc_wait_chhltd()` already
  `yield()`s between `HCINT` reads. The wins are less AHB traffic, less
  scheduler churn with several idle HID devices polling, and the idle
  `wfi` actually parking. Polish, not a correctness fix.
- **Blocker: the Duo PLIC path is unproven.** `PLIC_BASE`/context
  formulas are UNVERIFIED (carried from QEMU), and `plic_init()` has a
  live isolation experiment — the `IRQ_SDHCI` enable-bit write is
  commented out over an unsolved interrupt storm whose own comment says
  "the PLIC enable bit itself" is still a suspect. sdd runs polled PIO
  because of this. Interrupt-driven USB rides the same untrusted path.
- No QEMU DWC2 (`HAS_USB` is Duo-only), so nothing is verifiable
  without hardware — and the change touches `handle_trap` + `plic_init`,
  exactly the files the "verify on hardware, confirm before commit"
  rule protects.

Stopped at planning by design. The plan is fully specified (5 stages,
all flag-gated behind `INTERRUPT_DRIVEN_USB` / `USBD_INTERRUPT_DRIVEN`,
defaulting off) — a short session once the SDHCI PLIC storm is solved
and that path is trusted. Recommend doing the storm + the ethernet
real-hardware carrier work first; both are higher value.

---

## 2026-08-28 (continued) — xpad input: the Linux capture didn't unlock it either; all reverted

Got a `usbmon` capture of the 8BitDo SN30 Pro (X-input mode, clones
`045e:028e`) on a working Linux host. The device-side sequence right
before its interrupt-IN starts streaming:

1. `SET_CONFIGURATION(1)`
2. interrupt-OUT (ep2): LED command `{01 03 02}` — racccoon already does this
3. **vendor "magic message" on EP0**: `bmRequestType=0xC1, bRequest=0x01,
   wValue=0x0100, wIndex=0x0000, wLength=20` → pad replies 2 bytes
   `00 00`.
4. Linux also reads the manufacturer/product/serial **string
   descriptors** (langid 0x0409) before `SET_CONFIGURATION`.
5. submit interrupt-IN on ep1 (0x81) → first report `00 14 00 00…`
   arrives on the next 4ms poll.

**Checked mainline `drivers/input/joystick/xpad.c`** (vendor 5.10 is
too old to have this): `xpad_start_input()` for `XTYPE_XBOX360` does
`usb_submit_urb(irq_in)` **first**, *then* sends exactly that magic
message —
`usb_control_msg_recv(udev, 0, 0x01, USB_TYPE_VENDOR|USB_DIR_IN|USB_RECIP_INTERFACE, 0x100, 0x00, dummy, 20, 25)`
— with the comment "Some third-party Xbox 360-style controllers
require this message to finish initialization." A short/failed reply
is expected (kernel just `dev_warn`s). So the magic message is
legit-from-the-driver, and the IN endpoint is already being polled
when it lands.

**Tried on real hardware, all reverted:**
- Magic message *after* starting the session: completes cleanly
  (`c1 01 00 01 00 00 14 00`, no STALL), IN endpoint still clean
  complete-split NAK on every poll (verified to poll #2750). No change.
- Magic message *mid-poll-burst*, matching mainline's submit-IN-first
  order — 48 tight IN polls with the magic message fired at poll 2:
  `IN still silent after magic message + 48 polls`. No change.
- String-descriptor reads before `SET_CONFIGURATION`. **Regression:**
  langid (idx 0) succeeds but `GET_DESCRIPTOR(STRING, idx 1, langid
  0x0409)` throws `XACTERR` (HCINT 0x82) on the start-split, wedges the
  hub TT → endless `CLEAR_TT_BUFFER` / re-enumerate storm, all USB dies.
  Reading string descriptors over racccoon's split/TT path is itself
  broken (latent, nothing else needs it — do NOT re-add here).

Also observed: after the TT wedged, the pad re-enumerated as
`057e:2009` (Switch Pro Controller IDs) — the SN30 Pro mode-switching,
or garbage from the wedged TT.

**State: still open. Software guessing is genuinely exhausted now** —
we've faithfully replicated both the mainline `xpad_start_input()`
sequence and the working usbmon capture's bytes, and the IN endpoint
still returns a clean complete-split NAK forever. That points at a
racccoon split-interrupt-IN bug specific to this endpoint geometry
(vendor class, 32-byte MPS, 4ms interval) rather than a missing init
step. Real next step: a hardware USB analyzer on racccoon's own bus, a
dwc2 split-IN trace mode, or — cheapest discriminator — retest a
**genuine** Xbox 360 pad's input (not just enumeration) to confirm
whether this NAK is 8BitDo-specific or affects all xpads. Nothing
kept; tree clean.

---

## 2026-08-28 (continued) — xpad input: exhausted the guesses, needs a bus capture

Long session on the 8BitDo SN30 Pro (USB, X-input mode, clones
0x045e:0x028e). All on a throwaway branch, reverted — nothing kept.
Findings, so a future session doesn't repeat them:

- **OUT works end to end.** A rumble command `{00 08 00 FF FF 00 00 00}`
  on the interrupt-OUT endpoint physically spins the motors. Multi-packet
  OUT works too once `usb_interrupt_transfer_out()` carries the DATA
  toggle (it hardcoded DATA0 before — a real latent bug for any
  >1-packet OUT, but nothing needs it yet, so not kept).
- **The IN endpoint returns a clean NAK forever.** HCINT `0x12`
  (CHHLTD|NAK), no error bits, on every one of 90+ polls — including 80
  polled in a tight 4ms burst *immediately* after SET_CONFIGURATION,
  and including with buttons held. So: not a timing / continuity issue,
  not a transaction error, not the split mechanism (keyboard + mouse
  stream IN through the identical code). The pad's firmware simply
  never enters reporting mode.
- **This pad ignores LED commands.** `{01 03 xx}` for xx ∈ {01, 02, 06}
  — all complete (XFERCOMP) but produce zero visible LED change, while
  the same-endpoint rumble works. So the popular "the LED / player-ID
  assignment unlocks the IN stream" theory can't apply here.
- Also tried, no effect: 100ms post-SET_CONFIGURATION settle, 32-byte
  zero-padded packets, `{05 20 00 01 00}`, a 300ms settle between a
  "blink" LED and a "solid" LED.

Linux drives this exact pad (buzz on connect + working input). The
difference is something the generic web advice doesn't name. **Next
step is a `usbmon` capture of the working Linux exchange** — the bytes
between enumeration and the first IN report. Everything short of that
is guessing, and the guessing is done. See `racccoon-xpad-input`
memory.

---

## 2026-08-28 (continued) — xpad folded into the cooperative HID session model

Cleanup, not a feature. `usbd_xpad_read_loop()` was the last `for(;;)`
in usbd — an Xbox pad plugged in still froze `usb_msc_ipc_poll()` /
`usb_poll_hub_ports()` / the keyboard / the mouse, exactly the problem
stages 1-2 of the keyboard work fixed for everything else.

- `Hid_session` grew a `kind` field (`HID_KIND_GENERIC` / `_KEYBOARD` /
  `_XPAD`) in place of the `bool is_keyboard`; the slot array went from
  2 to 3, one slot per kind (slot index == kind value). Keyboard, mouse
  and gamepad now all work at once.
- `usb_hid_begin_session()` takes `kind` as its first arg; the four
  dispatch branches pass the right one.
- `usb_hid_poll_slot()` routes reports by `s.kind` — kbd.c3, xpad.c3, or
  the raw hex dump. Its report buffer went 16 → 32 bytes (the Xbox pad
  report is 20).
- New in `xpad.c3`: `g_xpad_last`, `xpad_reset_state()`,
  `xpad_handle_report()` (parse + per-change print), and
  `xpad_print_button_change()` — moved out of usbd.c3 along with the
  button/stick decode, so xpad.c3 owns the whole "what the pad's bytes
  mean" layer, matching its own header comment. `print_int` stays in
  usbd.c3 (dwc2.c3 uses it too).

Net −9 lines. Builds clean (Duo + QEMU); no QEMU path for USB.

**Hardware-verified**: keyboard (p1), a **genuine** Xbox 360 controller
(0x045e:0x028e, p2) and a mouse (p3) all enumerated, the hub walk ran
to completion past the pad (on the old build it dead-ended right after
`LED command sent`), `ethd` came up afterward, and keyboard + mouse
both stream while the pad is plugged. The pad still produces **no input reports** — pre-existing issue from
2026-08-25, now with a sharper picture. The pad is an **8BitDo SN30 Pro
(USB) in XInput mode** (clones 0x045e:0x028e). Under Linux it buzzes on
plug-in; under racccoon it does not. Its player-1 LED is lit from the
moment it's powered (the pad's own default, not racccoon's LED
command), it enumerates fully, and the LED command returns success —
but it never reaches active state (no rumble, no reports), and its
mode-switch button combos are unresponsive too. So it has power for the
LED + control transfers but never completes the XInput host handshake:
either racccoon's LED/init bytes aren't actually landing over the split
interrupt-OUT (the "confirmed working" note from 2026-08-25 may have
been a false positive — that was against the clone's own logo LED), or
the rumble motor browns it out through the bus-powered hub. Separate
multi-round investigation, not part of this refactor. The coexistence
fix this entry is about is done and working.

---

## 2026-08-28 — session summary: camera scoped out, USB keyboard shipped

Two things this session. Detail in the per-topic entries below.

**MIPI CSI camera (GC2083) — evaluated, planned, deferred.** Full
sourcing pass against `~/Workspace/duo-buildroot-sdk`: the sensor layer
and the CIF / D-PHY / CSI-2 RX layer are in source (the FreeRTOS
cv1835 CIF HAL's base addresses match CV1800B), but the `vi` block —
the only path from CSI-MAC to DRAM — is a closed `.ko` blob. Wrote
`docs/camera-plan.md` (staged plan, go/no-go gate on a blob-RE spike,
`i2cd` as a useful first step). User chose to set it aside as the big
item and do USB keyboard instead. GC2083 module ordered; nothing built.

**USB keyboard — done, all four stages verified on the real Duo, merged
to master** (`bfccd6f..bd3cef1`, branch `usb-keyboard`, now deleted).

- Stage 1: replaced usbd's infinite HID read-loop with a cooperative
  session model (`usb_hid_poll` from main's loop), so a plugged-in
  mouse no longer freezes MSC IPC / hub polling.
- Stage 2: `user/usb/kbd.c3` — HID boot-report decode, US layout,
  `SET_PROTOCOL(0)` / `SET_IDLE(0)`.
- Stage 3: `src/kbd.c3` kernel keystroke queue + `SYS_KBD_PUSH` (31);
  `SYS_GETCHAR` drains it alongside the serial console. Keys reach the
  shell, everything else unchanged.
- Stage 4: Caps Lock (state + LED) and software auto-repeat.

Four hardware bugs surfaced and fixed along the way, in rough order of
how nasty they'd have been left alone:

1. **CSPLIT OUT transfer-size** (`hc_transfer_once_split`): the
   control/bulk complete-split path never zeroed HCTSIZ size for an OUT,
   so the driver's first-ever OUT-data control transfer (the LED
   SET_REPORT) silently mis-shaped over a split. This hub Hi-Speeds, so
   **every device behind it splits** — and this same bug meant USB
   mass-storage *writes* through this hub were latently broken too.
2. **Split-context leak**: an HID session keeps dwc2.c3's global
   `g_split_*` pointed at its device for `usb_hid_poll` to re-assert;
   the hub-walk loops then STALLed their next GET_PORT_STATUS. Fixed by
   asserting non-split before every hub-directed transfer.
3. **Single HID slot**: keyboard and mouse couldn't coexist. Now
   `Hid_session[2]`.
4. **Gaming-mouse misclassification**: a mouse with a boot-keyboard
   companion interface was treated as a keyboard. Added a `3/1/2` mouse
   dispatch branch before `3/1/1`.

Known limits (see `docs/usb-keyboard-plan.md`): US QWERTY only, one
keyboard + one mouse, combo receivers match as mouse, no SIGINT so
Ctrl-C is just a byte.

---

## 2026-08-28 (continued) — USB keyboard stage 4: Caps Lock + software auto-repeat

`user/usb/{kbd,dwc2,usbd}.c3`. No QEMU path (no DWC2).

**Hardware result:** auto-repeat works (hold a key → repeats), Caps Lock
letter-case toggle works, Shift + Caps+Shift correct.

**Caps Lock LED** — first hardware round it didn't light. `SET_REPORT`
has an OUT data stage, and this driver had never done an OUT-data
control transfer over a USB 2.0 split transaction (every prior one —
GET_DESCRIPTOR, SET_CONFIGURATION, … — was no-data or IN-data). This
hub goes Hi-Speed and *everything* behind it splits (the low-speed
keyboard, the full-speed mouse), so the LED transfer was silently
mis-shaped.

Fix applied (`hc_transfer_once_split`, control/bulk complete-split
path): force HCTSIZ transfer-size 0 on a CSPLIT OUT — the OUT payload
already went out with the start-split, so the complete-split only polls
"done yet?" and must not expect FIFO data. This is exactly the rule the
interrupt complete-split path already followed (`csplit_xfer_len =
is_in ? xfer_len : 0`), and vendor Linux 5.10's own
`dwc2_hc_start_transfer()` applies it to both. `*actual_len_out` still
comes out right (remaining stays 0 → `xfer_len - 0`). Also corrects
split *bulk* OUT (MSC writes) for free, though nothing exercises that
over this hub yet. `usb_hid_poll_slot` attempts the SET_REPORT
unconditionally again. **Confirmed on hardware: the LED lights.**

- **Caps Lock**: press of usage `0x39` toggles `g_kbd_caps_lock`;
  `kbd_usage_to_bytes` XORs it with Shift for letters only (digits /
  symbols untouched). The LED follows: `kbd.c3` sets `g_kbd_led_dirty`
  on each toggle, `usb_hid_poll_slot` then SET_REPORTs the 1-byte LED
  bitmap (`usb_hid_set_report_leds`, new in `dwc2.c3` — `bmRequestType
  0x21`, `bRequest 0x09`, Output report). `Hid_session` gained
  `ctrl_max_packet` + `iface_num` (keyboard-only) for that request.
- **Software auto-repeat**: `SET_IDLE(0)` means a held key sends no new
  reports, so `kbd_tick()` (called every keyboard poll, report or not)
  drives it. `kbd_handle_report` picks the repeat target — the last
  held key that maps to real bytes — restarting a ~500 ms delay when
  the target changes; `kbd_tick()` then re-emits it every ~40 ms
  (~25/s). Modifiers stay live: adding Shift mid-hold makes the repeat
  switch to the uppercase byte. Ticks derived from `USB_TIMEBASE_HZ`
  (25 MHz).

`usb_hid_poll_slot` restructured so the keyboard branch runs
`kbd_tick()` + the LED flush on every poll including a NAK (the mouse /
generic branch still early-returns on NAK).

**Hardware-verified:** held key repeats; Caps Lock toggles letter case;
Shift and Caps+Shift correct; and after the CSPLIT-OUT-size-0 fix the
physical Caps Lock **LED lights** on toggle. USB keyboard is done —
all four stages confirmed on the real Milk-V Duo.

---

## 2026-08-28 (continued) — USB keyboard stage 3: keystrokes reach the shell

Committed stages 1-2 on branch `usb-keyboard` (bfccd6f) first, then
stage 3.

The last gap: `kbd_emit()` only printed decoded keys to serial — they
never reached `getchar()`. Now there's a kernel keystroke queue.

- **`src/kbd.c3`** (new, `module kernel`): a 64-byte ring buffer,
  `kbd_queue_push()` / `kbd_queue_pop()`. Single producer (usbd),
  single consumer (the shell) — no locking needed on a single-hart
  cooperative kernel where a syscall runs to completion. A full queue
  drops the newest byte.
- **`SYS_KBD_PUSH` (= 31)** in `src/entry.c3` / `user/user.c3`: a0 = one
  byte, appended to the queue. Not pid-gated (same as the `*_INFO`
  syscalls — a byte in the input stream is low-stakes, usbd is the only
  caller).
- **`SYS_GETCHAR`** now drains the keystroke queue first, then falls
  back to `board::console_getchar()`. The shell and every other
  `getchar()` caller are untouched — a USB-keyboard byte and a
  serial byte are indistinguishable, and both stay live at once.
- **`user/usb/kbd.c3`**: `kbd_emit()` now `syscall(SYS_KBD_PUSH, …)`
  instead of printing; logs only on a full-queue drop.
- **`user/shell_test.c3`**: `kbdpush` builtin — pushes
  `"kbd-queue-works"` through `SYS_KBD_PUSH` so the QEMU test shell can
  prove the queue → `getchar` → shell path with no USB hardware.

Verified in QEMU: `> kbdpush` → `kbdpush: queued 15 bytes` →
`> kbd-queue-works` appears on the next prompt line untyped →
`kbd-queue-works: command not found`.

**Confirmed on the real Duo:** typing works at the `>` prompt, `ls`
runs (Enter → CR). Ctrl-C produces no visible effect — correct:
racccoon has no SIGINT / job control, so `0x03` just lands in the line
buffer, exactly as it does from the serial console. Nothing to fix;
the earlier "Ctrl-C interrupts" note in the plan was an over-assumption.

---

## 2026-08-28 (continued) — USB keyboard stage 2: boot-report decode — WORKING ON REAL HARDWARE

**Confirmed on the real Milk-V Duo** (low-speed keyboard vid=0x1a2c
pid=0x0b2a, on the IO-board hub, split transactions). SET_PROTOCOL(0) +
SET_IDLE(0) both accepted; `usbd: kbd: keyboard on interface 0,
interrupt IN 0x81, bInterval=10ms`; then every keystroke decoded
correctly on serial — letters, Shift→uppercase, Shift+digits→`!@#$%`,
Enter→`<0x0d>`. Cooperative `usb_hid_poll()` (stage 1) kept the shell
prompt and `ethd` running alongside it.

One real bug surfaced and fixed the same session (see the split-context
note below). New `user/usb/kbd.c3` + `dwc2.c3`/`usbd.c3` glue; QEMU +
Duo both build clean — there's no QEMU path for any of this (no DWC2 in
`virt`).

### Split-context leak (stage 1 latent bug, exposed here)

First boot showed `usbd: hub port 4: GET_PORT_STATUS failed` (a
complete-split STALL) right after the keyboard enumerated. Cause:
`usb_hid_begin_session()` deliberately keeps dwc2.c3's global
`g_split_*` pointing at the (low-speed) keyboard so `usb_hid_poll()`
can re-assert it — but the enclosing hub-walk loop in
`usb_enumerate_device()` then did its *next* `usb_get_port_status()`
(a transfer straight to the hub) with that stale low-speed split
context still set → STALL. The old infinite read-loop had masked this
by never letting the walk continue. `msc.c3` avoids it by clearing the
context on the way out; HID can't, because it needs it.

Fix: `usb_set_split_context(false, …)` is now asserted right before
every hub-directed transfer — first statement of the port loop in
`usb_enumerate_device()`, first statement of the port loop in
`usb_poll_hub_ports()` (was once-before-the-loop, now per-iteration so
a hot-plug enum on an earlier port can't poison a later one), and at
the top of `usb_enumerate_hub_port_device()` before `usb_reset_hub_port()`.
Per-device paths still set their own context after; `usb_hid_poll()`
re-asserts the keyboard's on its next pass.

Re-flashed and confirmed: `usbd: hub port 4: empty` (clean, no STALL),
keyboard still decodes every key.

### Second hardware round: mouse misclassified, single HID slot

Plugged a keyboard **and** a gaming mouse (Kingston/HyperX, vid 0x0951
pid 0x1729). Two problems:

1. The mouse is a composite HID device — a boot-mouse interface *and* a
   boot-keyboard companion interface for its programmable buttons. The
   `usb_find_interface(3, 1, 1)` keyboard match grabbed the companion,
   so usbd treated the mouse as a keyboard and polled the wrong
   interface — no mouse data at all.
2. Only one HID session slot (`g_hid_*` singleton), so the real
   keyboard's session then overwrote the mouse's. Keyboard + mouse
   could never coexist.

Fixes:

- **`Hid_session[2] g_hid`** — `HID_SLOT_KEYBOARD` + `HID_SLOT_OTHER`
  (mouse/generic). `usb_hid_begin_session()` writes the slot for its
  kind; `usb_hid_poll()` loops both; `usb_hid_clear_session()` clears
  by port across both. A keyboard and a mouse now work at once; a
  second device of the same kind still overwrites its slot (rare).
- **Dispatch order**: a new boot-mouse branch (`3/1/2`) is checked
  *before* the keyboard branch (`3/1/2` → raw hex-dump session on the
  mouse interface, `is_keyboard = false`), so a gaming mouse with a
  keyboard companion is treated as the mouse it is. HID class/subclass/
  protocol constants moved to `dwc2.c3` (`USB_CLASS_HID`,
  `USB_HID_SUBCLASS_BOOT`, `USB_HID_PROTOCOL_KEYBOARD/MOUSE`).
- Known limitation kept: a true keyboard+mouse *combo receiver* would
  now match the mouse branch and its keyboard would go unpolled —
  acceptable, combos were already out of scope; the real fix is
  binding both interfaces of one device to their own slots.

**Third round confirmed:** keyboard (port 3) + gaming mouse (port 2) at
once — `usbd: mouse: boot mouse on interface 0, interrupt IN 0x81`,
6-byte reports (16-bit deltas) streaming on movement, `usbd: kbd: '7'`
… decoding correctly at the same time. Clean hub walk, `port 4: empty`.
The mouse now works *better* than in stage 1 (its own interface, not a
misgrabbed keyboard companion, and it coexists with the keyboard).

`mountusb` (MSC + a HID device attached) not separately re-run, but MSC
dispatch order is unchanged and `usb_msc_ipc_poll` still runs with
split cleared — the risk from these changes is low.

- **`user/usb/kbd.c3`** (new, ~185 lines, xpad.c3-style device layer):
  - `kbd_handle_report(report, len)` — takes one 8-byte boot report
    from `usb_hid_poll()`, diffs `[2..7]` against `g_kbd_prev` for
    newly-held keys, ignores an ErrorRollOver (`[2] == 0x01`) report
    without disturbing `g_kbd_prev`.
  - `kbd_usage_to_bytes(usage, mods, out) -> n` — US-QWERTY HID-usage →
    ASCII: letters (Shift = upper, Ctrl = `0x01..0x1A` so Ctrl-C etc.
    match the serial console), number row + shifted symbols, the
    `-=[]\;',./` cluster + shifted forms, Enter→`\r`, Backspace→`0x08`,
    Tab, Space, Esc, and arrows → ANSI `ESC [ A/B/C/D`. Unmapped keys
    (F-keys, keypad, Caps/Num/Scroll Lock) return 0.
  - `kbd_emit(c)` — stage 2 just prints `usbd: kbd: 'x'` /
    `usbd: kbd: <0xNN>`; stage 3 swaps this body for the `SYS_KBD_PUSH`
    kernel-queue push that actually feeds the shell.
- **`dwc2.c3`**: `usb_hid_set_protocol()` (SET_PROTOCOL, `bmRequestType
  0x21`, `bRequest 0x0B`) + `usb_hid_set_idle()` (SET_IDLE, `0x0A`),
  and `usb_iface_first_interrupt_in()` — an interface-scoped endpoint
  finder (vs. `usb_find_any_interrupt_in`'s whole-config scan) so a
  composite keyboard's keyboard interface is the one that's picked.
- **`usbd.c3`**: `usb_hid_begin_session()` gains an `is_keyboard` flag
  (`g_hid_is_keyboard`); `usb_hid_poll()` routes a keyboard session's
  reports to `kbd_handle_report()` and everything else to the existing
  raw hex dump. New dispatch branch in `usb_enumerate_hub_port_device`
  matches HID `3/1/1` *before* the generic fallback: SET_CONFIGURATION
  → find the interrupt-IN endpoint → SET_PROTOCOL(0) + SET_IDLE(0)
  (both non-fatal, logged) → `kbd_reset_state()` → begin session.
- **`scripts/build_user.sh`**: `kbd.c3` added to the `usbd` link line.

Scope kept tight: US layout only, no auto-repeat (SET_IDLE(0) kills the
hardware one; software repeat is stage 4), no shell wiring yet — a
keystroke prints to serial, it doesn't reach `getchar()`. Caps Lock
ignored until stage 4.

**Hardware result:** keyboard decode confirmed working (see the stage 2
entry above, same session). Mouse + `mountusb` regression from stage 1
still needs a dedicated check.

---

## 2026-08-28 (continued) — USB keyboard stage 1: cooperative HID polling

Built, not yet hardware-verified (needs a reflash + a real USB
mouse/keyboard). `user/usb/usbd.c3` only; QEMU + Duo builds both clean.

The problem: `usb_enumerate_hub_port_device()`'s generic-HID branch
called `usbd_generic_interrupt_read_loop()`, a `for (;;)` that never
returned. Once any mouse/keyboard enumerated, usbd was stuck in it —
`usb_msc_ipc_poll()` and `usb_poll_hub_ports()` never ran again, so a
USB stick plugged after a mouse was invisible and `mountusb` couldn't
work.

The fix — mirror `msc.c3`'s session model:

- **`g_hid_*` module state** (`present`, `hub_port`, `dev_addr`,
  `ep_num`, `max_packet`, `pid_toggle`, `interval_ticks`, `next_due`,
  `report_count`) + a captured copy of this device's split-transaction
  context (`g_hid_split_*`).
- **`usb_hid_begin_session()`** replaces the read-loop call: stores the
  endpoint, snapshots `dwc2.c3`'s current `g_split_*` (set by the
  enclosing enumerate path), sets `g_hid_present`. Deliberately does
  *not* `usb_set_split_context(false, …)` on the way out, unlike the
  xpad/msc branches — the HID session needs that context kept.
- **`usb_hid_poll()`** — one non-blocking `usb_interrupt_poll`, paced by
  `g_hid_next_due` against the endpoint's bInterval, re-asserting the
  HID split context first (since `usb_msc_ipc_poll` / hub polling
  clobber the global in between). Still just prints the raw report
  bytes — same diagnostic output the old loop produced; the keyboard
  decode layer slots in here next stage.
- **`usb_hid_clear_session(port)`** — mirror of `usb_msc_clear_session`,
  called from the hub-port disconnect branch.
- **`main()` loop**: `usb_hid_poll()` runs at the top *and* throughout
  the ~100 ms idle tail (was a bare `while (…) { yield(); }`) — a
  keyboard's ~8 ms bInterval would otherwise be quantized to 100 ms and
  drop keystrokes. `usb_hid_poll()` early-returns until due / when
  nothing's attached, so the idle spin stays cheap.
- **`usb_poll_hub_ports()`**: now asserts `usb_set_split_context(false,
  …)` up front (it always talks straight to the hub). No-op in the
  full-speed-hub config this project runs, but makes the ownership
  explicit now that an active HID session leaves the global pointing at
  a downstream device.

`usbd_xpad_read_loop()` still has its own `for (;;)` — left alone, xpad
isn't the keyboard target and folding it in would widen the diff.
Whole-hub-unplug (root-port disconnect) still doesn't clear the HID/MSC
sessions — matches MSC's existing behaviour; a stale session just
fails its transfers harmlessly.

**To verify on hardware:** reflash, plug the known-good USB mouse
through the hub — `usbd: generic-hid: report #N …` lines should still
appear on motion — then plug a USB stick and confirm `mountusb` now
works with the mouse still attached.

---

## 2026-08-28 (continued) — planning: USB keyboard support

Camera set aside as the big item; USB keyboard picked as the next actual
feature — much smaller, because the whole USB stack + interrupt-IN reads
are already proven on real hardware (mouse). Plan written up as
`docs/usb-keyboard-plan.md`.

Shape of the work (no code yet):

- **Structural refactor**: usbd's HID read path is an infinite `for(;;)`
  loop today (`usbd_generic_interrupt_read_loop`) — it takes over the
  process, killing MSC IPC + hub polling. Replace with stored endpoint
  state + a single-shot `usb_hid_poll()` in `main()`'s loop, on a split
  cadence (~16 ms for HID, existing ~100 ms–1 s for MSC/hub).
- **`user/usb/kbd.c3`** (new, xpad.c3-style): 8-byte HID boot report
  (modifier byte + 6 keycodes), diff prev vs cur for newly-pressed keys,
  US-layout HID-usage→ASCII table incl. Shift / Ctrl / Enter / Backspace
  / arrows-as-escape-sequences.
- **HID init**: `SET_PROTOCOL(0)` + `SET_IDLE(0)` via the existing
  `usb_control_transfer`.
- **Delivery**: new `SYS_KBD_PUSH` (= 31) syscall → small kernel ring
  buffer → drained by `SYS_GETCHAR` alongside `board::console_getchar()`.
  Shell and all consumers unchanged; serial + USB feed one stream.
- **Dispatch**: match HID class 3 / subclass 1 / protocol 1 before the
  generic interrupt-IN fallback in `usb_enumerate_hub_device`.

Stages: (1) cooperative-poll refactor, verify mouse + MSC still coexist;
(2) kbd.c3 parse/decode, print to serial; (3) kernel queue + real shell
input; (4) Caps Lock, software auto-repeat, commit.

Real-Duo-only (no DWC2 in QEMU), same as the rest of USB. US layout only,
no auto-repeat before stage 4 — documented, not bugs.

---

## 2026-08-28 (continued) — planning: MIPI CSI camera (GC2083) bring-up

No code this session — a survey + feasibility pass + staged plan for the
camera, written up in full as `docs/camera-plan.md`.

Sensor decision: **CAM-GC2083** (Milk-V's own 16-pin module, ships with
the right 0.5 mm FPC) rather than adapting the Freenove/OV5647 the user
already bought — its RPi 15-pin 1.0 mm 3.3 V connector needs an active
adapter board (Platima "Duo Cam Board", clearance/limited stock) and the
mechanical/electrical unknown isn't worth carrying when there's no QEMU
model to fall back on. The OV5647 camera goes unused for now.

Key findings from `~/Workspace/duo-buildroot-sdk`:

- **Pipeline map** (CV1800B, from `cv180x_base.dtsi`): `csi_mac0`
  @ `0x0A0C2000`, `csi_wrap0` @ `0x0A0D0000`, `pad_ctrl` @ `0x03001C30`,
  VIP `base` @ `0x0A0C8000`, `vi` (ISP-FE + RAW + DMA-to-DRAM)
  @ `0x0A000000` (512 KB), `vpss`/`sc` @ `0x0A080000`. SENSOR_RSTN =
  GPIOA2 active-low. MCLK 24 MHz off the CAM0 PLL.
- **GC2083**: I²C `0x37`, 16-bit reg / 8-bit data, chip-ID `0x2083` at
  `0x03f0`/`0x03f1`, single fixed mode `1920x1080p30` RAW10 2-lane
  (2.59 MB/frame packed), no sub-res mode — crop in the receiver.
- **Sourcing split** (this is the whole risk):
  - open — `gc2083_sensor_ctl.c` / `gc2083_cmos.c` (sensor control, in
    source); the FreeRTOS **cv1835** CIF HAL (`cif_drv.c` +
    register-field headers), whose base addresses *match* the CV1800B
    DTS, covering D-PHY RX + CSI-2 decode;
  - closed — `cv180x_vi.ko` / `cvi_mipi_rx.ko` are prebuilt blobs; the
    `vi` block (the only path from CSI-MAC to DRAM — the CSI wrap has no
    DMA-address register) has no source. Rosetta stone is the cv1835 VIP
    HAL (`isp_drv.c`: `ISP_DUMP_PRERAW`, `ispblk_dma_setaddr`,
    `ispblk_crop_config`), but cv1835→cv1800b ISP-register parity is
    unverified.

Staged plan (see `docs/camera-plan.md` for detail):

0. sourcing spike (go/no-go gate for stages 4–5) + `i2cd`, a new
   DesignWare I²C1 master driver — *both doable before the camera
   arrives*
1. sensor power/clock/reset + read chip-ID over I²C — first real
   milestone
2. full GC2083 mode register script (streaming blind)
3. CIF / D-PHY RX / CSI-2 RX — link + error counters clean (the fallback
   finish line if the gate says no)
4. `vi` raw dump → one RAW10 frame to a file → host debayer (the risky
   stage)
5. `camd` service + `capture` tool + double-buffered continuous capture

New infra the plan needs: `HAS_CAMERA` board flag + constants, a large
**contiguous uncached** DMA frame buffer (~633 pages, with a cache flush
the 1-page usb/eth buffers never needed), `i2cd` as its own driver
process, GPIOA2 added to `gpiod`'s allowlist for SENSOR_RSTN. No QEMU
camera model — real-Duo-only from stage 1 on, which breaks the usual
verify-on-both cadence.

---

## 2026-08-28 (continued) — real Milk-V Duo confirmation: FS_WRITE_AT / FS_STAT / hardening / dispatch table

The whole arc from this session — `FS_WRITE_AT` + `FS_STAT`, the
empty-leaf / null-termination hardening, and the `Fs_ops` dispatch
table — booted and passed on the real CV1800B, against its ext2 root
(`HAS_SECOND_FS_PARTITION = false`, so ext2 is the only backend the Duo
mounts; the exFAT multi-cluster path stays QEMU + `fsck`-only, no Duo
role).

Packaging note for the future: the `$DUO_SDK` checkout had lost its
built FSBL/OpenSBI binaries, but `fiptool.py genfip --OLD_FIP <the
fip.bin already on the card> --LOADER_2ND <new kernel>` rebuilds the
image reusing every non-kernel section (BL2, MONITOR, DDR_PARAM,
CHIP_CONF) from the existing fip — no SDK rebuild, no Docker. Parsed
back clean (`RUNADDR 0x80200000`, param1 byte-identical, zero trailing
bytes). This kernel embeds `shell_test` (swapped in for the run, same
trick `build.sh` uses for QEMU) so the board had the test builtins.
`DUOBOOT/fip.bin.bak-preFSWRITEAT` is the pre-flash image.

Serial, at the `>` prompt:

```
> cycletest
cycletest: ok
> p9fswritetest
p9fswritetest: ok
> fsneg
fsneg: ok
> fswriteat
fswriteat: ok
> fswriteatfrag
fswriteatfrag: ok
```

`cycletest` / `p9fswritetest` first to prove fsd + the ext2 write path
were alive; then the three new builtins — `fsneg` (17 negative-case
assertions: empty path, wrong node type, past-EOF, name collisions),
`fswriteat` (9 KB chunked write + read-back byte-compare, `fs_stat`
size/type, non-aligned mid-file overwrite, append via
`FS_OFFSET_APPEND`, no-holes rejection, write-to-directory rejection),
`fswriteatfrag` (two files grown interleaved, read back verified). All
`ok` on real silicon.

Reflashing the production-shell kernel afterward is now
`scripts/reflash_duo.sh` (`DUO_SD_PART=/dev/sdX1 bash
scripts/reflash_duo.sh`): `build_duo.sh` → `llvm-objcopy` →
`make_loader2nd.py` → `fiptool.py genfip --OLD_FIP <card's fip.bin>
--LOADER_2ND` → parse-back sanity check → udisksctl-mount DUOBOOT,
prune older `fip.bin.bak-*`, keep one timestamped backup of the
outgoing `fip.bin`, copy the new one in. No
sudo (DUOBOOT is FAT32), no `build_fsbl` (only fiptool.py itself is
needed from `$DUO_SDK`). Pipeline verified end-to-end minus the flash
this session; `fiptool.py` auto-located under `$DUO_SDK` or
`~/Workspace/duo-buildroot-sdk`.

---

## 2026-08-28 — fsd: FS_* verb dispatch table

The nine path-based `FS_*` verbs (`FS_READ` / `FS_READ_AT` / `FS_WRITE` /
`FS_WRITE_AT` / `FS_STAT` / `FS_DELETE` / `FS_LIST` / `FS_MKDIR` /
`FS_RENAME`) each carried its own `if (fs_type == FAT32) … else if
(EXT2) … else if (EXFAT) …` triple inline in `fsd`'s main loop — ~295
lines of near-identical branch, and exactly the shape that shipped the
empty-leaf bug the day before (the guard existed on exFAT, not the other
two, because they're hand-maintained copies).

Replaced with **one `Fs_ops` function-pointer table per backend**
(`fsd.c3`). `main()`'s loop parses the request into an `Fs_req` once,
then a `switch (verb)` does the small per-verb glue that genuinely isn't
uniform — which wire bytes the payload sits at (`buf[104]` vs `buf[108]`),
which gate applies (protected-name for the writes, `fs_write_disabled`
for mkdir/rename), and the `FS_OFFSET_APPEND` sentinel — and calls
`fs_ops.<verb>(&r)`. Each backend gets nine trivial adapter functions
(`fat32_op_read`, …) that unpack `Fs_req` into its real entry point;
`fs_ops` is set next to `fs_type` in `fs_mount()`.

This is the **first vtable in the codebase**, and the file header comment
that used to say "no function-pointer indirection … two backends through
a couple of `if`s don't need it" now explains why nine verbs × three
backends crossed that line. The `P9_*` block (separate protocol,
ext2-only) is untouched.

`ext2`-only detail folded in: the `requester_uid` for the five write
verbs now lives in the `ext2_op_*` adapters (`r.uid`), set by the
switch from the existing `fsd_requester_uid(from)` helper.

Net `fsd.c3`: −54 lines, and the only fs-type branch left in the whole
FS_* path is the mount-time `fs_ops =` assignment. Adding a fourth
backend is one `Fs_ops` literal + its adapters.

**Verification:** full regression on all four `launch64*.sh` —
`fsneg`, `fswriteat`, `fswriteatfrag`, `lfntest`, `cycletest`,
`p9fstest`, `p9fswritetest`, `p9mkdirtest`, `fspermtest`, `hardentest`,
`exfatgrow`, `bigreadtest`, `mounttest`, and the `/bin`
`write`/`cat`/`mkdir`/`mv`/`rm -r` sequence — all pass. `fsck.fat` /
`e2fsck -fn` / `fsck.exfat` clean on every run image. Behaviourally
identical to the inline dispatch.

**Files changed:** `user/fs/fsd.c3`.

---

## 2026-08-27 (continued) — fs ecosystem hardening pass (Phase 5)

Follow-on to the FS_WRITE_AT / FS_STAT checkpoint. The plan's Phase 5 was
"broad de-duplication refactor of the three backends' near-identical
resolve/create/dispatch shapes." On a closer look that's mostly a vtable
waiting to happen — the shared *structure* is thin (FAT32 does 8.3-name
mangling, ext2 uses names directly, exFAT transcodes to UTF-16), and
collapsing it means touching the heavily-exercised offset-0 read/write
paths for a marginal line count win, against this codebase's clear
preference for explicit code. Scoped it down to the parts that actually
pay off:

**Real bug found by the new negative-case test.** `fs_write("")` and
`fs_delete("")` *succeeded* on FAT32 and ext2 — exFAT rejects an empty
leaf name (`leaf[0] == 0`, added during the directory-extension work),
but `fat32_write` / `fat32_delete` / `fat32_delete_recursive` /
`fat32_mkdir` / `fat32_rename` and their ext2 twins never got the same
guard. `fs_write("")` was creating a real, bogus, un-nameable directory
entry. Added the `leaf[0] == 0` guard to all ten entry points, bringing
FAT32/ext2 in line with exFAT — an empty path or a trailing slash is now
`-1` everywhere.

**`fsd` request hardening.** `filename` / `new_filename` are `mem::copy`'d
100 bytes out of the wire buffer — the `user.c3` wrappers null-terminate
at ≤ 99, but a buggy or hostile client could send 100 non-null bytes and
every backend's string walk would run off the end. Force `[99] = 0` after
each copy.

**`fsd` dedup.** The `uint requester_uid = 0xFFFFFFFF; proc_info(from,
null, null, (int*)&requester_uid);` pair (+ a paragraph of comment
explaining the fail-closed reasoning) was copy-pasted at 8 dispatch
sites. Replaced with one `fsd_requester_uid(from)` helper carrying the
canonical comment; call sites are one line each now.

**New regression:** `fsneg` shell_test builtin — 17 negative-case
assertions (empty path on write/write_at/delete; missing file on
read/read_at/stat; `mkdir` collision; write / write_at to a directory;
`list` of a file; `rename` onto an existing name), each of which must
return `-1` on all three backends. Runs against whatever is mounted, so
the four `launch64*.sh` scripts cover FAT32 / ext2 / dual / exFAT.

**Verification:** `fsneg: ok` on all four. Full regression re-run clean:
`fswriteat`, `fswriteatfrag`, `lfntest`, `cycletest`, `p9fswritetest`,
`fspermtest`, `exfatgrow`, `bigreadtest`, `/bin`
`write`/`cat`/`mkdir`/`mv`/`rm -r`. `fsck.fat` / `e2fsck -fn` /
`fsck.exfat` clean on every run image.

**Files changed:** `user/fs/fsd.c3`, `user/fs/fat32.c3`, `user/fs/ext2.c3`,
`user/shell_test.c3`.

---

## 2026-08-27 (continued) — FS_WRITE_AT + FS_STAT across all three backends; exFAT multi-cluster files

`fsd`'s thin `FS_*` verb family had no offset/append write and no way to
learn a file's size. `FS_WRITE` is whole-file-replace capped at
`FS_MSG_MAX-104` = 1024 bytes, so the biggest file creatable through the
normal path API — on *any* backend — was 1 KB. (The stateful `P9_*`
family had offset-aware `Twrite`, but ext2-only.) exFAT additionally
still capped a file at one cluster.

**New verbs** (`user/user.c3`, `user/fs/fsd.c3`):

- `FS_WRITE_AT` (27) — path / len / uint offset / data at byte 108 (so
  offset and data don't collide; ≤ 1020 B/call, chunked like
  `FS_READ_AT`). Overwrite anywhere, or append at the end. **No holes** —
  a backend rejects `offset > the file's size` (`-1`), same rule the
  `P9_WRITE` path already followed. `offset == FS_OFFSET_APPEND`
  (`0xFFFFFFFF`) is resolved by `fsd` to the file's current size via the
  same stat hook below, so a caller can append with no prior lookup.
- `FS_STAT` (28) — path in, `{size, type}` out (type 0 file / 1 dir; `""`
  = the root). `fs_stat(name, *size, *type)` wrapper.

Each backend got a `*_stat` and a `*_write_at`:

- **exFAT** — the real work. `exfat_grow_file_chain` / `exfat_file_nth_
  cluster` / `exfat_write_cluster_at`: a file grows a cluster at a time,
  staying contiguous (NoFatChain, FAT untouched) while each new cluster
  lands after the last, converting the whole run to a real FAT chain the
  first time one doesn't — the same machinery `exfat_extend_dir` uses for
  directories. `exfat_write` was rebuilt on it too (per the plan), though
  `fsd`'s 1 KB payload cap means its `want` is only ever 0 or 1 in
  practice. `exfat_rewrite_stream` gained a `no_fat_chain` param (it used
  to force the flag on whenever there was data — wrong for a chained
  file). The "one cluster per file" scope limit is gone from the file
  header.
- **FAT32** — `fat32_write_file_at` alongside `fat32_write_file` (which
  was already multi-cluster + chain-extending, just offset-0-only), same
  "keep the offset-0 path untouched" split `fat32_read_file_at` made.
  `fat32_write_at` wraps it with resolve / create / `max(old, offset+n)`
  size update.
- **ext2** — `ext2_write_file_at` already existed (built for `P9_WRITE`);
  `ext2_write_at` just factors the path-level glue (resolve / create /
  `ext2_write_allowed` / grow `inode.size`) out of the `P9_WRITE`
  dispatch. Keeps the existing 12-direct-block cap.

**Hardening pass** (bounded): audited the `FS_*` surface across the three
backends for divergence — empty path, write-to-directory, past-EOF,
offset overflow, create-with-a-hole. Added a `leaf[0] == 0` guard to the
new `*_write_at` (exFAT already had one; FAT32/ext2 didn't on the
write path — pre-existing, fixed for the new functions). `/bin/write`
gained `write -a <path> <text>` (append via the sentinel).

**Verification** — two new `shell_test` builtins, run against whatever's
mounted so the four `launch64*.sh` scripts cover FAT32 / ext2 / dual /
exFAT:

- `fswriteat` — chunked write of a 9000-byte file, read back and
  byte-compared; `fs_stat` size/type; non-aligned mid-file overwrite
  (bytes outside the range untouched); append via `FS_OFFSET_APPEND` (new
  size checked); no-holes rejection; write-to-directory rejection.
- `fswriteatfrag` — two files grown 1000 bytes at a time, alternating, so
  on exFAT each file's clusters interleave and `exfat_grow_file_chain`
  has to do the NoFatChain→FAT-chain conversion; both read back and
  verified. 10000 bytes each stays under ext2's 12-direct cap.

Both `ok` on all four scripts; `fsck.fat` / `e2fsck -fn` / `fsck.exfat`
clean on every run image. `write -a` round-trip confirmed on FAT32 /
ext2 / exFAT. Full regression clean: `bigreadtest`, `p9fswritetest`,
`fspermtest`, `cycletest`, `lfntest`, `exfatgrow`/`exfatgrowkeep`, and
the `/bin` `write`/`cat`/`mkdir`/`mv`/`rm -r` sequence.

Not done this session: real Milk-V Duo hardware check (ext2 root +
FAT32 boot), and Phase 5 — the broad de-duplication refactor of the
three backends' near-identical resolve/create/dispatch shapes (the plan
sequences it after this checkpoint).

**Files changed:** `user/user.c3`, `user/fs/fsd.c3`, `user/fs/exfat.c3`,
`user/fs/fat32.c3`, `user/fs/ext2.c3`, `user/bin/write.c3`,
`user/shell_test.c3`.

---

## 2026-08-27 (continued) — exFAT: directory extension (grow past one cluster)

Closes the last deliberate exFAT write-path limit: a directory this
driver creates used to be one `NoFatChain` cluster forever (~42 short-
named entry sets), and once full it rejected every `create` / `mkdir` /
`mv`-into-it with `-1`. Now `exfat_place_set`, when none of a directory's
current clusters has a free slot run, grows it a cluster
(`exfat_extend_dir`) and retries.

**Three directory shapes, one grow path:**

- **root** — always FAT-chained, no entry set of its own: walk the chain
  to its end, link a fresh cluster, done. `exfat_resolve_dir_located`
  reports `is_root`, and the entry fixup below is skipped.
- **FAT-chained subdirectory** (root's shape, or one a previous grow
  already converted) — same chain link, plus bump `DataLength` /
  `ValidDataLength` in its own entry set so the on-disk size stays honest
  for `fsck` / Windows.
- **`NoFatChain` (contiguous) subdirectory** — convert to a real FAT
  chain: write links across every existing cluster and the new one, then
  clear the `NoFatChain` flag and bump `DataLength` in its entry set
  (`exfat_grow_dir_entry`, SetChecksum recomputed over the whole set). It
  can't revert to contiguous, which is fine — nothing here needs a
  directory to be `NoFatChain`.

To reach a non-root directory's own entry set (it lives in the *parent*),
`exfat_resolve_dir` grew a sibling `exfat_resolve_dir_located` that also
hands back that entry's `Exfat_set_locs` and an `is_root` flag; the plain
form is now a one-line wrapper, and only the three write-placement
callers (`exfat_write` new-file branch, `exfat_mkdir`, `exfat_rename`
destination) use the fuller one.

**The bug the first test run caught.** `made=64` (all 64 `mkdir`s into one
directory succeeded — a non-growing directory would have stopped at ~42),
but writing *into* the 64th child failed, and so did a nested `mkdir`
there. Cause: a 4KB cluster is 128 slots, entry sets are 3+ slots, so the
last set never lands flush — the first cluster keeps 1-2 trailing
`0x00` slots. exFAT's `0x00` means "end of this directory, and every
later cluster too", so every reader's cursor walk stopped at that gap and
never reached the second cluster. Deleted entries (`0x05` / `0x40` /
`0x41`) don't have this problem — only never-used `0x00` does. Fix:
`exfat_seal_dir_cluster` rewrites the trailing `0x00` slots of the
cluster being extended as `EXFAT_ENTRY_FILLER` (`0x41`, a deleted File
Name entry — still "free" to every slot scan, no longer the end marker)
before the new cluster is linked; the freshly-zeroed new cluster becomes
the directory's one real end marker. This also fixed a silent cluster
leak in `rm -r` of a grown directory (`exfat_free_tree`'s own walk hit
the same wall).

**Verification** — two new `shell_test` builtins, exFAT root only
(`scripts/launch64_exfat.sh`):

- `exfatgrow` — `mkdir` 64 subdirectories in a fresh directory (forces
  ≥1 grow + the `NoFatChain`→chain conversion), write a marker into the
  last-created child and read it back (proves the cursor follows the new
  chain link), nested `mkdir` into that child, `fs_list` returns a full
  reply, then `fs_delete_recursive` the whole thing (walks the multi-
  cluster directory). `exfatgrow: ok`. `fsck.exfat` on the booted
  `disk_exfat.run.img` afterwards: clean, back to the fixture's 4 dirs /
  15 files.
- `exfatgrowkeep` — same fill, no cleanup, so a host `fsck.exfat` sees a
  real on-disk multi-cluster directory: **clean, directories 69, files
  16** (the chain, `DataLength`, sealed tail slots all spec-valid).
- Pre-existing exFAT ops (`cat`, `write`+`cat`, `mkdir`+nested `write`,
  file `mv`, directory `mv`, `rm -r`) via `/bin/*` still clean, `fsck`
  clean.

**Full regression, all four launch scripts** (fresh `scripts/build.sh`,
each `launch64*.sh` once — `mtools` installed mid-session so the FAT32
fixture builds again):

- **`launch64.sh` (FAT32)** — `write`+`cat` round-trip, `mkdir`+nested
  `write`, file `mv`, directory `mv`, `rm -r`; `fsck.fat` clean.
- **`launch64_ext2.sh`** — same sequence, `e2fsck -f` clean.
- **`launch64_dual.sh`** — both ext2 filesystems mount, `bigreadtest:
  ok`, `write`/`mv`/`rm` on `/mnt/fs2/`; `e2fsck -f` clean.
- **`launch64_exfat.sh`** — `exfatgrow: ok`, `exfatgrowkeep: ok`, plus
  the standard write/`mv`/`rm -r` sequence; `fsck.exfat` clean (69 dirs
  with the grown directory kept, back to 4 after cleanup).

Build note unchanged: `scripts/build.sh` still hardcodes
`/opt/riscv/bin/ld.lld`, so this host needs `LLVM_LLD=/usr/bin/ld.lld
LLC=/usr/bin/llc LLVM_OBJCOPY=/usr/bin/llvm-objcopy` in front of it.

**Files changed:** `user/fs/exfat.c3`, `user/shell_test.c3`.

---

## 2026-08-27 (continued) — launch64*.sh boot a throwaway disk copy

Full-`build.sh` + boot-test pass turned up a false alarm: `mv /wtest.txt
/wtest2.txt` on the ext2 image printed `mv: failed` while the file
appeared to move. Root cause was **not** `ext2_rename` (byte-identical to
before the exFAT work, and correct — it deliberately refuses an existing
destination, same as `fat32_rename`). It was the test harness: the boot
run reused a `build/disk_ext2.img` that a *previous* boot had already
written `/wtest2.txt` into (the boot's own opening `ls` showed it), so
the rename correctly refused, and the leftover file happened to hold the
same content the test expected.

The real gap: every filesystem now has a write path, so a guest mutates
its disk image in place, and `scripts/launch64*.sh` booted
`build/disk_*.img` directly — so run N+1 inherited run N's writes.

Fix: each `launch64*.sh` now `cp`s its image to a `build/*.run.img`
throwaway and boots that. `build/disk_*.img` stays exactly as
`build.sh` produced it; every launch starts from a clean image with no
extra step. `build.sh` `rm -f build/*.run.img` at the top so a fresh
build never leaves a stale one, and its images were already fully
rm-and-rebuilt each run (re-running `build.sh` is itself a reset). Also
added `cd "$(dirname "$0")"` to the launch scripts so they work from the
repo root too, not only from `scripts/`.

Isolation check: `launch64_exfat.sh` run twice — run 1 writes a marker
file, run 2's `ls`/`cat` don't see it; pristine `disk_exfat.img` mtime
unchanged. Full `build.sh` (FAT32 via mtools, ext2/dual via debugfs,
exFAT via mk_exfat_image.sh) completes clean.

**Full boot-test pass, re-run through the updated launch scripts** (fresh
`build.sh`, then each `launch64*.sh` once, `\r`-terminated piped input):

- **`launch64.sh` (FAT32)** — mounts; `cat hello.txt`; `write` + `cat`
  round-trip; `mkdir /dtest` + write-into-it; `mv /wtest.txt
  /wtest2.txt` → new name reads back, old name gone, **no `mv: failed`**;
  `rm -r /dtest` → gone.
- **`launch64_ext2.sh`** — same sequence, all clean. The `mv` that
  triggered this whole investigation now succeeds outright, because the
  run starts from a pristine image.
- **`launch64_dual.sh`** — both ext2 filesystems mount (fsd + fsd2);
  reads/writes on root *and* `/mnt/fs2/`; `bigreadtest: ok` (the
  double-indirect-block fixture at `/mnt/fs2/bigfile.bin`); same-dir
  `mv` clean.
- **`launch64_exfat.sh`** — mounts `writes=on`; reads incl. the
  Up-case-fold and the fragmented-`ls_frag` exec; `write`/`cat`;
  `mkdir` + nested write; file `mv`; directory `mv /dtest /dmoved`
  (children still reachable); `rm -r /dmoved` → gone. `fsck.exfat` on
  the booted `disk_exfat.run.img` afterwards: **clean** (16 files); the
  master `disk_exfat.img` still `fsck`-clean at 15 files, mtime = build
  time (never booted).

**Files changed:** `scripts/launch64.sh`, `scripts/launch64_ext2.sh`,
`scripts/launch64_dual.sh`, `scripts/launch64_exfat.sh`,
`scripts/build.sh`.

---

## 2026-08-27 (continued) — exFAT: rename/move + recursive delete

Third exFAT session, closing the last two write verbs. `exfat_rename`
(handles both a pure rename and a move to a different directory) and
`exfat_delete_recursive` (`rm -r`); `fsd.c3` gets the two matching
dispatch branches. `user/fs/exfat.c3` is now a full read+write backend.

**Recursive delete** — `exfat_free_tree` walks the target directory with
a cursor and, for every entry set, frees the data (recursing into
subdirectories first, then freeing the subdirectory's own cluster).
Unlike `fat32_delete_dir_contents` it doesn't bother clearing individual
child entries: the whole subtree's directory clusters get freed
wholesale anyway, so unlinking children first is just wasted writes (the
FAT32 version marks them only because a dir cluster it *isn't* about to
free could hold the entry). Then the top entry set is unlinked from its
parent and its cluster freed. A protected entry anywhere in the subtree
aborts before any free — all-or-nothing, same guarantee the FAT32/ext2
recursive deletes give. Depth-capped at 32 (`EXFAT_MAX_DELETE_DEPTH`,
the sibling of `FAT32_MAX_DELETE_DEPTH`).

**Rename/move** — build a fresh entry set at the destination pointing at
the *same* clusters (no data copy), place it, then clear the source
entry set: destination safely in place before the source goes away,
"fail toward a duplicate name, never toward a lost file," same order
`fat32_rename` uses. Refuses an existing destination (no silent
overwrite) and — for a directory — refuses a move into its own subtree.

The one place exFAT is genuinely *simpler* than FAT32 here: **exFAT
directories have no `.`/`..` entries**, so moving a directory to a new
parent needs no `..` fixup at all (`fat32_rename` has a whole block for
that) and the cycle check can't walk *up* through `..` — so
`exfat_subtree_contains` walks *down* from the source directory instead,
looking for the destination parent's cluster among its descendants.

`exfat_build_set` gained a `no_fat_chain` parameter: everything this
driver allocates itself is one contiguous cluster (pass `true`), but a
rename has to carry through whatever flag the moved file/directory
already had — a Windows-written fragmented file keeps its FAT chain, the
entry just moves.

**Verification** — QEMU (`scripts/launch64_exfat.sh`), `fsck.exfat`
clean after each, host exFAT driver readback:
- `rm` a non-empty dir → refused; `rm -r` the same → gone, every
  descendant unresolvable afterwards; `rm -r` a directory holding the
  deliberately-fragmented `bin/ls_frag` (exercises the FAT-chain free
  inside the tree walk) → `fsck` clean.
- pure rename (`mv /r1 /r2`), move to a subdirectory
  (`mv /r2 /d/moved`), move a directory with contents (children still
  reachable at the new path — no `..` to fix), move a mkfs-created
  subdirectory.
- `mv /parent /parent/child/parent` (into its own subtree) → refused;
  move onto an existing name → refused.
- ext2's own write regression (`write`/`mkdir`/`mv`/`rm -r` + `fsck.ext2`)
  still clean — the shared `fsd.c3` changes are additive.

Not tested on real Milk-V Duo hardware (exFAT has no role in its
ext2-root + FAT32-boot layout).

**Files changed:** `user/fs/exfat.c3`, `user/fs/fsd.c3`.

---

## 2026-08-27 (continued) — exFAT write support: create/overwrite, delete, mkdir

Second exFAT session, following the same read-then-write split FAT32 and
ext2 both took. `user/fs/exfat.c3` gains `exfat_write` (create or
overwrite), `exfat_delete` (file or *empty* directory) and `exfat_mkdir`;
`fsd.c3` flips `fs_write_disabled` off for an exFAT mount and gets the
three matching dispatch branches. Rename/move and recursive delete stay
unimplemented (no exFAT branch in `fsd.c3`, still return -1).

**How exFAT allocation actually works, and why that made this small.**
An exFAT file's clusters are tracked in the **Allocation Bitmap** (a
system file, root-dir entry type `0x81`), *not* the FAT — the FAT only
describes fragmented chains, and a contiguous file's `NoFatChain` flag
says "ignore the FAT entirely, my clusters are consecutive." `mkfs.exfat`
leaves a `NoFatChain` file's FAT entries at 0. Combined with the fact
that `fsd.c3` caps a single `FS_WRITE` at ~1 KB and there's no
append/offset write verb, **every file this driver writes fits in one
cluster** (≥ 4 KB everywhere) — so every allocation is exactly one
contiguous `NoFatChain` cluster and the FAT is never touched for file
data. The allocator is just "find a 0 bit in the bitmap, set it"; free is
"clear the bit." The FAT-walk path exists only for *freeing* a
pre-existing fragmented file on `rm`.

**The parts that needed real care:**
- **Entry-set construction.** An exFAT file is a *set* of 32-byte slots
  (File + Stream Extension + ⌈name/15⌉ File Name entries) carrying two
  checksums: a **SetChecksum** over the whole set (rotate-right-then-add,
  skipping its own 2 bytes) in the primary entry, and a **NameHash** over
  the up-cased name in the Stream entry. Both had to be computed
  correctly for anything else to read the file back — got them right
  first try, confirmed by the Linux kernel exFAT driver mounting and
  reading every file this wrote.
- **In-place overwrite.** Repointing an existing file's Stream Extension
  entry at new data means recomputing the SetChecksum across every slot
  of the set, then writing back the (possibly multi-sector-spanning)
  primary + stream slots. Slot locations come straight from the
  directory cursor (`Exfat_set_locs`), not arithmetic, so a set split
  across sectors is handled.
- **Ordering.** Allocate + write the new data first, *then* repoint the
  entry, *then* free the old clusters — "fail toward a leak, never toward
  losing the file," same rule `fat32_write`/`fat32_rename` follow.

**Deliberate scope limits (all documented in the file):** one cluster per
file; **no directory extension** — a directory that fills its initial
cluster (128 slots, ~40 entries) can't grow, the create just fails; no
rename; no recursive delete; delete of a directory only if empty. exFAT
directories have no `.`/`..` entries, so `mkdir` is just "allocate a
cluster, zero it (that's a valid empty directory), add the entry set."

**Verification** — `scripts/launch64_exfat.sh` on QEMU, then
`fsck.exfat` on the host, then re-mounting the image with the host's own
exFAT driver to read back what racccoon wrote:
- create, `cat`-verify; overwrite (shorter *and* longer content);
  create-in-subdirectory; a 58-character filename (4 File Name entries)
  including overwriting it; case-insensitive overwrite (`ALPHA.TXT` then
  `alpha.txt` → one file); empty-file write.
- `mkdir`, nested `mkdir`, write into the nested dir, `ls` it.
- `rm` a file; `rm` a contiguous 18-cluster binary (`bin/ls` — multi-bit
  bitmap free); `rm` the deliberately-fragmented `bin/ls_frag` (real
  FAT-chain walk + per-cluster FAT clear); `rm` a non-empty directory →
  correctly refused; bottom-up delete of a nested tree.
- allocator bitmap reuse (write → rm → write again).
- **`fsck.exfat` reported the volume clean after every one of these**, and
  ext2's own write regression (`cat`/`write`/`mkdir` + `fsck.ext2`) still
  passes — the shared `fsd.c3` dispatch changes are purely additive.

`mk_exfat_image.sh` / `launch64_exfat.sh` headers updated to note the
image is now written in place (rerun `mk_exfat_image.sh` to reset it).
Not tested on real Milk-V Duo hardware — exFAT has no role in the Duo's
ext2-root + FAT32-boot layout; it'd only matter for a hot-plugged exFAT
USB stick via `mountusb`, a later concern.

**Files changed:** `user/fs/exfat.c3`, `user/fs/fsd.c3`,
`scripts/mk_exfat_image.sh`, `scripts/launch64_exfat.sh`.

---

## 2026-08-27 — exFAT read-only: real c3c build + QEMU boot verification

Follow-up to the previous entry, which landed `user/fs/exfat.c3` from a
sandboxed session with **no c3c toolchain and no way to populate an
exFAT image** — the code had never been compiled or booted. This
session had both, so it closed items 1–3 of that entry's "Next up":
real build, real test image, real QEMU boot.

**1. c3c build.** `exfat.c3` needed three fixes to compile — all
type-system, no logic changes:
- It leaned on C3's stdlib `Char16`/`WString` names, unreachable under
  this project's `--use-stdlib=no` build (the previous entry flagged
  this as the single biggest unknown). Replaced with a local
  `alias Char16 = ushort` — `fat32.c3` already uses a bare `ushort` for
  its own LFN code units, so this just keeps the exFAT name-handling
  code reading as the UTF-16 it is.
- `EXFAT_NAME_CHARS_PER_ENTRY` was `const uint` but is only ever used in
  `int`-typed name-offset arithmetic (`base = (i - 1) * ...`). Made it
  `const int`, matching `EXFAT_NAME_MAX`.
- One `(Char16*)&entry[EXFAT_NAME_CHARS + k * 2]` mixed `uint` +
  `int` in the index; added an explicit `(int)` cast.
After these, `bash scripts/build.sh` compiles and links `fsd` (with
`exfat.c3`) clean. (This host also needed `LLVM_LLD=/usr/bin/ld.lld` —
the scripts default to `/opt/riscv/bin/ld.lld`; unrelated to exFAT.)

**2. Test image.** New `scripts/mk_exfat_image.sh` +
`scripts/launch64_exfat.sh` + `disk-exfat/` fixtures, mirroring the
ext2 (`launch64_ext2.sh` / `disk-ext2/`) and dual setups. exFAT is the
awkward one: exfatprogs ships only `mkfs`/`fsck`/`dump`/`label` — none
write file data, and no `mtools`/`debugfs` equivalent for exFAT exists
anywhere. So the image has to be populated through a real exFAT mount.
The script uses `udisksctl` (no root — same reasoning as the "Flash Duo
without sudo" note) with a passwordless-`sudo mount` fallback, and
`scripts/build.sh` calls it best-effort: a host with neither just
doesn't get `build/disk_exfat.img`, exactly like the other opt-in boot
targets.

The image carries a deliberately **maximally fragmented** file:
`bin/ls_frag`, a copy of `ls.bin` written 4KB-at-a-time interleaved
with a filler file that's then deleted, so no two data clusters end up
adjacent — exFAT marks it `NoFatChain=0` and every cluster boundary
forces a real `exfat_next_cluster` FAT-table lookup. A parser
(`python3`, walking the on-disk dir tree + FAT) confirmed it: 18
clusters, 18 fragments. Every other file on a fresh volume lands
contiguous, so without this the FAT-chain read path never runs on QEMU.

**3. QEMU boot.** `qemu-system-riscv64 ... -drive
file=build/disk_exfat.img` (`-serial stdio -monitor none`, `\r`-
terminated piped input — the test shell breaks lines on CR only).
Everything passed:
- `fsd: exFAT mounted, partition_start=0 root_cluster=5
  sectors_per_cluster=8`
- `ls` — full root listing, including `My Long File Name.txt` (a
  non-8.3 name, stored directly in `0xC1` entries — no short/long split
  like FAT32) and directories flagged with `/`
- `ls subdir` / `ls /subdir` — subdirectory listing
- `ls emptydir` — zero-entry success, not an error
- `cat hello.txt`, `cat subdir/nested.txt` — file reads, root and nested
- `cat MIXEDCASE.TXT` / `mixedcase.txt` / `MixedCase.txt` all resolve to
  the same file — case-insensitive matching via the volume's real
  decompressed Up-case Table
- `cat nope.txt` — correctly "not found"
- **`ls_frag subdir` execs and prints `nested.txt`** — the 18-fragment
  binary loaded correctly through `exec()`'s chunked `FS_READ_AT`, i.e.
  `exfat_read_chain_at`'s FAT-chain traversal, end to end. The
  contiguous multi-cluster path is covered too (every other `/bin/*`
  exec).

Known non-issue: `ls /` (leading slash, empty leaf) returns "not found"
— but it does the same on the ext2 backend (verified this session) and
on FAT32; all three special-case only the empty path string. Project-
wide, bare paths are the convention (see earlier entries). Not touched.

**Still deferred** (previous entry's item 4): exFAT write support —
same separate-session precedent FAT32 and ext2 both followed.

**Not tested this session:** real Milk-V Duo hardware. The Duo boots
ext2-root + FAT32-boot-partition (see the filesystem-topology notes);
exFAT has no role in that boot path, and there's no exFAT partition on
the Duo's card. exFAT on real hardware would only matter for a
hot-plugged exFAT USB stick via `mountusb`, which is a later concern.

**Files changed:** `user/fs/exfat.c3`, `scripts/build.sh` (new exFAT
image step), `scripts/mk_exfat_image.sh` (new), `scripts/launch64_exfat.sh`
(new), `disk-exfat/` (new fixtures).

---

## 2026-08-26 (continued) — exFAT read-only support: a third fsd backend

Started exFAT as fsd's third filesystem backend, alongside FAT32 and
ext2, with the same probe-and-dispatch shape (`fs_mount()`,
`user/fs/fsd.c3`) both of those already use. **Read-only in this pass**
(`FS_READ`/`FS_READ_AT`/`FS_LIST`) — deliberately, same incremental
precedent FAT32 and ext2 both followed (read support first, write
support — the riskier code — as a separate later session).

New file `user/fs/exfat.c3`: boot sector parsing, FAT chain walking
(with exFAT's own no-mask 32-bit entries), and a real, spec-correct
directory entry-set reader — exFAT names live in `0x85`+`0xC0`+`0xC1`
entry triples (File Directory Entry + Stream Extension + File Name),
not a single self-contained dirent the way FAT32's short/LFN entries
are, and a file's data can be either a real FAT chain OR fully
contiguous (`NoFatChain`, the Stream Extension entry's own flag) — every
cluster-chain walk in this file threads that flag through, including
subdirectory resolution (unlike FAT32, an exFAT subdirectory can itself
be contiguous). Case-insensitive matching parses the volume's *real*
Up-case Table (a hidden root-directory system file) rather than a fixed
ASCII fold — decompressed per its own run-length-escape format, but
only codepoints < 256 are actually cached (`exfat_upcase_low`,
512 bytes) — full 65536-entry materialization would be 128KB, wildly
out of scale with every other fixed buffer in this codebase. `fsd.c3`
gained `FS_TYPE_EXFAT`, an `exfat_probe()` branch in `fs_mount()`
(tried before FAT32's own weak `0xAA55` fallback, same reasoning
ext2's magic-first probe already documents), and one new dispatch
branch each for `FS_LIST`/`FS_READ_AT`/`FS_READ`. `FS_WRITE`/
`FS_DELETE`/`FS_MKDIR`/`FS_RENAME` needed **no changes at all** — their
existing `if fs_type == ...`/`else if` chains already default to
"unsupported" for any `fs_type` with no branch, and `fs_write_disabled`
already defaults `true` and is simply never flipped for this backend —
the honest, do-nothing-extra way to express "this backend can't write."

**This was a background/sandboxed session with no working build or test
loop** — worth recording plainly rather than glossing over. The real
`c3c` fork this project builds with (`RACCCOON_STD_DIR`, normally at
`~/Workspace/c3c`) isn't present in this sandbox, so **none of this new
code has actually been compiled**, and `mtools`/a loop-mountable kernel
exFAT driver/`fuse-exfat` weren't available either, so no QEMU boot test
happened. In their place: `mkfs.exfat` (exfatprogs) *was* available, so
every boot-sector field offset this file reads was cross-checked byte-
for-byte against a real exfatprogs-formatted image (all matched
exactly, including a surprising, undocumented `0x20`-type padding entry
this driver's own "skip anything that isn't a recognized primary/File
Directory Entry type" logic already handled correctly without any
special-casing). The full read path — mount, Up-case Table
decompression, entry-set parsing, contiguous *and* FAT-chained cluster
walking, subdirectory resolution, case-insensitive matching, and
offset reads — was then validated by hand-crafting real on-disk file/
subdirectory/fragmented-file structures into that same image and
running a faithful line-by-line Python port of `exfat.c3`'s own algorithm
against it; every case passed (contiguous file, a genuinely fragmented
2-cluster file crossing a cluster boundary mid-read, a subdirectory with
its own contiguous file inside it, case-insensitive lookup via the real
decompressed Up-case Table, and a correctly-failing lookup for a
nonexistent name). That's real confidence in the *logic*, but zero
confidence yet in raw C3 syntax/type-system correctness (in particular,
this is the first file in the codebase to use C3's `Char16`/`WString`
type family at all) — **`bash scripts/build.sh` needs to actually run,
and the exFAT branch needs a real QEMU boot, before this is trusted the
way FAT32/ext2 are.**

**Next up:** run the real build, fix whatever `c3c` objects to, build a
real `mkfs.exfat`-formatted test image populated with actual files (this
session's sandbox couldn't populate one — no loop-mount, no
`fuse-exfat`), wire it into `scripts/build.sh` alongside `disk.img`/
`disk-ext2.img`, and only then write support, following the same
later-session precedent FAT32 and ext2 both set.

**Files changed:** `user/fs/exfat.c3` (new), `user/fs/fsd.c3`,
`scripts/build_user.sh`.

---

## 2026-08-26 (continued) — Real VFAT long-filename (LFN) support for fat32.c3, read and write

`fat32.c3`'s own header comment already admitted the gap: "filename /
LFN directory entries are skipped, not parsed" — every real file with
a name that wasn't already valid 8.3 short form was only ever reachable
through an auto-generated alias this driver never even round-tripped
correctly against what a real Windows/Linux/macOS write would have put
on disk.

Added real, standard Microsoft VFAT LFN support — read and write —
additively, deliberately not touching any of the ~6 existing directory-
scan loops (`fat32_find_in_dir`/`_find_in_root`/`_find_free_dirent`/
`_delete_dir_contents`) at all, to keep the whole, already-proven
short-name fast path provably unchanged in outcome:
- `fat32_resolve_name11()` (new): scans a directory reconstructing each
  entry's real long name (if a valid, checksum-matching LFN chain
  precedes it) or its short-name-derived display form, matching a
  caller's raw name case-insensitively against either. Every existing
  lookup (`fat32_read`/`_write`/`_delete`/`_delete_recursive`/`_rename`/
  `_mkdir`/`_list`/`_resolve_dir`) now tries this first, falling back to
  the original `fat32_name_to_8_3()` conversion only when nothing
  matches (the "does this exist yet" case before creating something).
- `fat32_prepare_new_entry()` (new): a name already exactly valid 8.3
  form still gets a plain, LFN-free short entry exactly as before. A
  name needing case-folding/truncation/invalid-character stripping
  gets a generated short-name alias (the standard MS "numeric tail"
  scheme, real collisions checked for) plus a real, spec-correct LFN
  chain written immediately before it — found via a new
  `fat32_find_free_dirent_range()`, generalizing the existing
  single-slot finder to a *consecutive* run (deliberately never allowed
  to span a cluster boundary, even though clusters aren't necessarily
  physically adjacent on disk — a real correctness hazard sidestepped
  outright rather than reasoned about).
- Deletion (`fat32_delete`/`_delete_recursive`/`_rename`'s own source
  cleanup) now removes the *whole* LFN chain, not just the trailing
  short entry — leaving one behind would look like real corruption to
  any other real FAT32 reader.
- `fat32_list()` shows the real long name, truncated to 31 characters
  for display (`FS_LIST_NAME_MAX`, shared with `ext2.c3`/`envd.c3`'s
  own wire format — already truncates the same way for a real ext2
  name longer than that; zero blast radius into either from this
  change) — the real, full name stays reachable via `fs_read`/`_write`/
  etc directly regardless.

**Explicitly flagged, not fixed**: the interactive shell's own
tokenizer (`user/shell.c3`) splits on spaces with no quoting support at
all — a real long name containing a space still can't be typed as one
argument at the shell prompt. The filesystem layer is now fully
capable of storing/matching such names regardless (proven via a
regression test using hardcoded strings, not the shell's own parsing —
see below); making the shell itself handle quoting is a separate,
smaller feature.

**Verified in QEMU**: a real, externally-authored LFN fixture
("My Long File Name.txt", written into `build/disk.img` by `mtools`'
own `mcopy` — a genuine, independent VFAT implementation, not this
driver — see `scripts/build.sh`) now shows its real name in `ls`
instead of `MYLONG~1.TXT`. A new `lfntest` builtin
(`user/shell_test.c3`) proves the full round trip using hardcoded,
real space-containing names throughout (bypassing the shell's own
tokenizer limitation): reads that fixture, writes a brand-new long
name from inside racccoon itself, confirms it shows up correctly in a
real directory listing, renames it to a different long name, and
deletes it — all passing, on both the FAT32 and ext2 disk images (ext2
needed no code changes at all, having never needed LFN support to
begin with). Full existing regression suite re-run clean across all
three QEMU disk-image variants afterward — no change in outcome for
any short-name path.

**Confirmed on real Milk-V Duo hardware**, via `mountusb`: writing a
new 30-character name (`ARealLongFileNameForTesting.txt` — no space,
the shell's own tokenizer limitation, but well past 8.3 either way)
created it correctly, `ls /mnt/usb/` showed the real name, and `cat`
read the real content back. A genuine bonus surfaced immediately: the
real drive's own `pippo.txt` — referenced constantly earlier this same
session, always shown as `PIPPO.TXT` before this feature — turned out
to already carry a real, pre-existing LFN chain for its actual
lowercase name (lowercase isn't valid 8.3 form, so any real OS that
wrote it would have needed one), which this driver had been silently
discarding until now. It displays as `pippo.txt` immediately, with no
code written specifically for that case — the general mechanism just
correctly reads whatever a real LFN chain says.

**Files changed:** `user/fs/fat32.c3`, `user/shell_test.c3` (new
`lfntest`), `scripts/build.sh` (the new LFN fixture).

---

## 2026-08-26 (continued) — USB Mass Storage write-through confirmed working on real hardware, zero new code

Last open item from this session's own USB storage work: prove writes
actually go through `mountusb`'s mounted filesystem, not just reads
(`ls`/`cat`, already proven earlier today). Checked first whether this
was even architecturally possible before testing anything — FAT32
write support genuinely exists in `user/fs/fat32.c3`
(`fat32_write`/`fat32_create_file`/`fat32_write_file`, extended
deliberately from an original read-only implementation), and the USB
write path (`user/usb/msc.c3`'s `msc_write10()`, `USB_MSC_IPC_WRITE`)
was already implemented — just never actually exercised on real
hardware until now.

Tried the obvious thing directly, no new code: `mountusb` →
`write /mnt/usb/testfile.txt hello` → `cat /mnt/usb/testfile.txt`.
Worked end to end on the first attempt — the full stack (`write` →
`fs_write()` → `fsd`'s dynamic `usbd` backend → `diskd_rw()` →
`usbd`'s `USB_MSC_IPC_WRITE` responder → `msc_write10()` → a real USB
Bulk-Only Transport OUT data stage → `fat32_create_file`/
`fat32_write_file` on the real drive) round-tripped correctly with
nothing to fix. This closes out the two-tier USB storage work
(`usbrw` for raw sector I/O, `mountusb` for a real mounted
filesystem) with both read and write proven on both tiers.

**Files changed:** none — pure verification.

---

## 2026-08-26 (continued) — GPIO interrupts investigated and explicitly deferred: real PLIC IRQ number found, but no reassurance it's safe on this silicon

Considered next after `mountusb`/`unmountusb`: real interrupt support
for `gpiod` (currently poll-only). Found a real, specific candidate —
GPIO bank A's own PLIC IRQ is 60 (`peripheral_number + 16`, from an
upstream, in-progress Linux mainline devicetree patch for this exact
SoC — not present anywhere in this project's own local vendor SDK
checkout, which has zero `interrupts =` property on any of the 5 GPIO
devicetree nodes at all) — a real interrupt-control register block
also exists on this same IP block (`INTEN`/`INTMASK`/`INTTYPE_LEVEL`/
`INT_POLARITY`/`INTSTATUS`/`PORTA_DEBOUNCE`/`PORTA_EOI` at `+0x30`
through `+0x4c`, confirmed via `linux_5.10/drivers/gpio/gpio-dwapb.c`).

Before touching any code, re-read this project's own real history with
non-timer PLIC interrupts first — and the picture was much more
serious than a passing mention suggested. The one real attempt
(`IRQ_SDHCI`, `boards/duo/board.c3`/`docs/devlog.md`'s own entry) found
that setting that one PLIC enable-bit alone — independent of whether
the SD controller itself ever asserted anything — put the CPU into a
**permanent** `SCAUSE_SUPERVISOR_EXTERNAL` trap storm, `plic_claim()`
returning 0 on every single sample, forever, requiring a reflash to
escape rather than anything recoverable at runtime. Four other
explanations (PLIC context number, the IRQ number itself, stale device
status bits, completion sequencing) were carefully ruled out first;
the conclusion was "a real, undocumented silicon/PLIC erratum for this
source (or possibly this whole context)" — genuinely never resolved
which. USB and Ethernet's own interrupts were never even attempted for
exactly this reason.

Checked for reassurance before deciding: does the vendor's own
shipping Linux get GPIO (or any real peripheral) interrupt working
reliably on this exact RISC-V chip? Found none, either direction. No
real Linux devicetree exists for the actual RISC-V CV1800B in the
vendor SDK at all — only for its ARM sibling (CV1835), which uses GIC,
not this PLIC. The Linux PLIC driver in use here is explicitly named
`"T-Head PLIC"` (`linux_5.10/drivers/irqchip/irq-sifive-plic.c`) — a
vendor-specific variant, consistent with the T-Head-silicon `PAGE_A`/
`PAGE_D` erratum this project already hit once before (Sv39 bring-up),
making a T-Head interrupt-delivery erratum entirely plausible, not far
-fetched. Its claim/complete sequence is functionally identical to
`board.c3`'s own `plic_claim()`/`plic_complete()` — no hidden extra
init step found that would explain the storm. And the SD controller's
own devicetree node — the one whose real-hardware interrupt attempt
caused it — has no `interrupts =` property in the vendor's own shared
devicetree either, mild evidence the vendor doesn't rely on it
either.

**Decision**: stay poll-only, matching USB/Ethernet's own already-
deliberate choice for the identical reason. A demonstrated, permanent,
reflash-requiring failure mode plus zero positive evidence the
underlying mechanism is safe on this exact silicon is not a good trade
for "a client can be woken by an edge instead of polling on demand."
Documented directly in `user/gpio/gpiod.c3`'s own header comment (the
real PLIC IRQ number included) so a future revisit — ideally with real
hardware debug tooling (logic analyzer, vendor engineering support)
able to actually resolve the open erratum question — doesn't have to
re-derive any of this from scratch.

**Files changed:** `user/gpio/gpiod.c3` (comment only, no functional
change).

---

## 2026-08-26 (continued) — USB hotplug robustness: mountusb made idempotent, unmountusb added

`mountusb` (`user/shell_common.c3`) worked end to end but had no
lifecycle management: every call unconditionally `rfork()`'d a *new*
dynamically-configured `fsd` with no memory of any it had spawned
before. Two real gaps followed directly: no way to explicitly detach
`/mnt/usb/` short of power-cycling, and — more seriously — every
re-run (success or failure) leaked the previous `fsd` process forever.
With `PROCS_MAX` this small, a handful of re-runs (e.g. after
physically swapping the USB drive) would exhaust the process table
entirely.

First cut tracked the currently-live dynamic `fsd` in two new globals
(`g_usbfs_fsd_pid`/`g_usbfs_fsd_gen`). Working, but flagged (correctly)
as the wrong architecture: a side-channel copy of state the namespace
table already records, one more thing to keep in sync by hand.
Redesigned to be fully stateless instead — `usbfs_teardown()` now
reads the live binding straight out of `ns_resolve("/mnt/usb/", &len)`
+ `proc_info()` at the moment it's needed, rather than trusting a
separately-maintained pid/generation pair that could drift (e.g. if
the fsd ever died on its own for an unrelated reason). Designing this
surfaced a real, would-have-been-serious bug before it ever shipped:
`ns_resolve()`'s own longest-prefix match (`src/entry.c3`'s
`SYS_NS_RESOLVE`) falls through to the `""` catch-all — the *root*
filesystem server — for any path with nothing more specific bound,
including `/mnt/usb/` itself whenever it isn't actually mounted. A
naive "if `ns_resolve` returns a live pid, kill it" would have killed
the root fsd every time `unmountusb` ran with nothing mounted. Fixed
by also checking the matched-prefix length
(`ns_resolve`'s own optional out-param) equals `strlen("/mnt/usb/")`
— confirming an exact match, not the fallback — before ever touching
the resolved pid. `mountusb` now calls this same `usbfs_teardown()`
before probing again (closing the leak, including on its own failure
path, where the just-spawned `fsd` that never found anything used to
idle forever); `unmountusb` calls it on request, checking the same
exact-match condition itself first to report "nothing mounted"
correctly.

Confirmed one thing was *already* correct and needed no fix along the
way: a physical unplug mid-use was already handled safely by `usbd.c3`
own hub-port polling (`usb_msc_clear_session()`, `user/usb/msc.c3`) —
this was purely a shell-side lifecycle gap, not a disconnect-detection
one.

Verified fully on real Milk-V Duo hardware: `mountusb` twice in a row
with the same drive attached reused the *exact same pid* (8) for the
replacement `fsd` — direct proof the old one was actually killed, not
leaked, and `/mnt/usb/` kept working across both mounts. Then a real
physical unplug made `cat /mnt/usb/PIPPO.txt` fail cleanly
("not found", no hang), and a real replug + `mountusb` again fully
recovered (`asd` read back correctly), reusing pid 8 a second time.
`unmountusb` was separately confirmed correct in both QEMU (crucially,
confirmed `ls`/`cat` on the *root* filesystem still worked immediately
after calling `unmountusb` with nothing mounted — the exact scenario
the exact-match fix above protects) and again on real hardware after
the stateless redesign: `mountusb` → `ls /mnt/usb/` → `unmountusb` →
`ls /mnt/usb/` now correctly reports "not found" → `mountusb` again →
`cat /mnt/usb/PIPPO.txt` reads real content back, full round trip.

Explicitly descoped: automatic background re-mounting the instant a
new drive is plugged in. The shell is normally blocked in
`SYS_GETCHAR` waiting for a keystroke with no way to be woken by a hub
event; doing this for real would need a separate always-running
process somehow pushing a mount into the *interactive shell's own*
namespace — a real design problem (namespaces are per-process by
design), not a small addition here. `mountusb`/`unmountusb` stay
explicit, user-invoked commands.

**Files changed:** `user/shell_common.c3` only — no kernel changes, no
new syscalls.

---

## 2026-08-26 (continued) — Real GPIO: a driver for the CV1800B's DW-APB controller, the onboard LED blinking, and a real scheduling-starvation bug found and fixed on real hardware

Next feature after the cleanup/hardening pass: real GPIO on the Duo.
Researched the same way this project always does real hardware — the
local `duo-buildroot-sdk` checkout's actual Linux driver and
devicetree, not the datasheet alone — plus the Milk-V community's own
published header pinout (no Milk-V-specific devicetree exists in the
vendor SDK itself).

**Hardware, confirmed from source**: Synopsys DesignWare APB GPIO
(`snps,dw-apb-gpio`), 5 independent single-port banks, each its own
4KB region (`porta`@`0x03020000` .. `porte`@`0x05021000`). Identical
per-bank layout: `+0x00` data-output, `+0x04` direction (1=out, 0=in),
`+0x50` external-pin-state (the real input value — not `+0x00`).
Pinmux: same `PINMUX_BASE` (`0x03001000`) this project's boards/duo/
board.c3 already maps for USB/SD/ETH-LED — each pad has its own
funcsel register, no formula from bank/bit to offset, a genuine
per-pad lookup table.

**Pin selection took several real research rounds, each one finding a
real blocker the previous round couldn't see**: header pin 19
(GPIOA14) looked clean until cross-referencing `user/block/sdhci.c3`'s
own `PAD_SDIO0_PWR_EN_REG = 0x01C` — the exact same funcsel offset,
already claimed for the SD card's real power-enable pin. Header pins
16/17 (GPIOA16/17) looked *even* cleaner (nothing in this project's own
code touches them) until realizing they're the live UART0 console
pins, configured by U-Boot before racccoon's kernel ever runs —
repurposing either would have silenced every boot message and every
test result this project has ever produced. A full sweep of every
bank-A/B `XGPIO*` pad against both this project's own claims *and*
U-Boot's actual `board_init()` (gated correctly against this board's
real `.config`, since some of its pinmux calls are conditionally
compiled) settled on three genuinely clear pins: the onboard status
LED (GPIOC24, pad `AUD_AOUTR`, funcsel `+0x12c` — its own GPIO number,
440, confirmed directly by the user/board-owner, not found
independently in the vendor SDK since this board variant's own board
files never name a status LED) and two general-purpose header pins,
GPIOA28 (pad `IIC0_SCL`, header pin 1) and GPIOA22 (pad `SPINOR_SCK`,
header pin 24) — each with its own caveat (a standard I2C pin; a pin
named for SPI-NOR flash this board variant doesn't populate) but
neither claimed by anything in this project or by U-Boot's default
boot on this exact board.

**Design**: `user/gpio/gpiod.c3`, following this project's established
"one owning process per real device" pattern (diskd/sdd/usbd/ethd)
rather than mapping raw MMIO into arbitrary processes — concretely
important here, since `PINMUX_BASE` is the exact same physical page
multiple other drivers already map for their own pads; unrestricted
access to it could let an unrelated process reconfigure e.g. the SD
card's own pin by accident. A small compiled-in allowlist (the 3 pins
above, each with its own `(bank, bit, funcsel_offset, funcsel_value)`)
is both the safety boundary and the whole feature surface — there's no
safe formula to fall back to for an unlisted pin. Exposes 3 IPC verbs
(`GPIO_SET_DIR`/`GPIO_WRITE`/`GPIO_READ`) checked against the
allowlist; `user/bin/gpio.c3` is the interactive CLI (`gpio A28 dir
out`/`write 1`/`read`), resolving `gpiod` via the same dynamic
`srv_post()`/`ns_mount_wait()` mechanism `usbrw.c3` established for
`usbd`. `boards/duo/board.c3` gets `HAS_GPIO`/`GPIO_BANK_A_BASE`/
`GPIO_BANK_C_BASE`/`GPIO_PINMUX_PAGE`; `boards/qemu/board.c3` sets
`HAS_GPIO = false` (no meaningful QEMU equivalent) but still needs the
placeholder constants and `gpiod.bin.o` linked into the QEMU kernel
too — same "linker needs both binaries present regardless of which
board's `if` ever actually runs them" reasoning `scripts/build_duo.sh`
already documents for diskd/sdd.

**A real bug, found only on real hardware**: the first cut's own main
loop called `gpiod_ipc_poll()` (built on `ipc_poll_type()`/
`SYS_IPC_POLL`) in a tight `for(;;)` with no `yield()` at all.
`SYS_IPC_POLL`'s own case comment in `src/entry.c3` says outright it
"never yields" — this loop was exactly the "syscall-free spin that
nothing can ever switch away from" `SYS_YIELD` exists to prevent
(that syscall's own header comment, written earlier this same day
during the hardening pass). Both `usbd.c3` and `ethd.c3` already call
`yield()` throughout their own busy-poll loops for this exact reason —
missed writing gpiod's first cut. Real, concrete symptom on real
hardware: with `usbd`/`ethd` already busy-polling from their own real
enumeration/link-negotiation work, adding one more non-yielding
process was enough contention that the shell's own `exec()` of
`/bin/ls` failed outright (`ls: command not found`) — initially,
reasonably, suspected as a regression in the same day's earlier
`SYS_EXEC` pointer-validation hardening, until re-confirming that
exact mechanism had already been proven working on real hardware
*after* that hardening pass landed (the `mountusb`/`ls`/`cat` round),
narrowing it to something introduced since — this driver, the only
genuinely new code path on that boot. Fixed with a single `yield()`
call once per loop iteration; re-flashed, and `ls` — plus the full
GPIO command set — worked immediately.

Confirmed fully end to end on real Milk-V Duo hardware: the onboard
LED blinks once per second from boot with zero commands needed, and
`gpio A28 dir out` / `write 1` / `write 0` / `gpio A22 dir in` /
`read` all work correctly from the shell.

**Follow-up cleanup, same day**: `src/process.c3` had grown seven
`setup_xxx_mappings()` functions (diskd/sdd/usbd/ethd/gpiod/netd/fsd),
several of them (`sdd`/`usbd`/`gpiod`/`ethd`) just repeating one
`map_device_page(proc.page_table, X, X, PAGE_U|PAGE_R|PAGE_W)` line per
device-register page — the exact same three-argument shape and flags
every time, only the address changing. Added `map_device_pages(Process*
proc, uptr* addrs, int count)` (kernel-internal only — an explicit
decision: a real syscall letting a *running* service request its own
mappings at will was considered and rejected, since it would let any
process ask to map any physical address, undoing this same day's own
"one owning process, no raw shared MMIO access" hardening work) and
switched those four functions to build a small fixed-size array
(`uptr[N] foo_pages = { ... };`, confirmed real C3 array-literal syntax
works on this toolchain) and call it once. `diskd`/`netd`'s own single
`VIRTIO_*_PADDR` mapping (before their own separate multi-page DMA
buffer loops, which still allocate and `map_page()` by hand — a
different shape this helper isn't for) wasn't worth converting — no
repetition to remove there. Re-verified end to end on real hardware
after the refactor (`ls`, `gpio A28 dir out`, `gpio A22 read` all still
correct) — purely mechanical, same addresses and flags, just less
repetition to keep in sync by hand next time a driver's own mapping
list changes.

**Files changed:** `boards/duo/board.c3`, `boards/qemu/board.c3`,
`src/process.c3` (`setup_gpiod_mappings`, `map_device_pages`), `src/kernel.c3` (spawn +
extern symbols), `user/gpio/gpiod.c3` (new), `user/bin/gpio.c3` (new),
`scripts/build_user.sh`/`scripts/build.sh`/`scripts/build_duo.sh`/
`scripts/populate_duo_bin.sh`.

---

## 2026-08-26 (continued) — Cleanup + hardening pass: shell split (test builtins out of the shipped binary), syscall-boundary pointer validation, and dead-code removal

Direct continuation of the same day's USB Mass Storage work (Tier 1 +
Tier 2, both committed). Before picking up a new feature, a step back:
"remove stuff that is not needed, some major cleanups, harden the
system." Three parallel research passes surveyed the repo first
(shell.c3's own structure, `src/entry.c3`'s syscall boundary, dead code/
resource limits repo-wide) before any code changed.

**Shell split.** `user/shell.c3` was 1771 lines; only `hello`/`exit`/
`mountusb`/the `/bin/<cmd>` fallback (4 of 37 command branches) are
real end-user features — the other 33 are one-off `*test` commands
accumulated across this project's whole tutorial/bring-up history
(`p9test`, `killtest`, `permtest`, `mounttest`, `threadtest`, ...), all
shipping identically embedded in every kernel image including the real
Duo hardware build. Split into three files:
- `user/shell_common.c3` — the shared/real pieces: `run_exec_buf`/
  `RUN_EXEC_BUF_MAX` (needed by both shells' `mountusb`/`/bin/`
  fallback AND 8 of the test builtins), `shell_dispatch_common()`
  (hello/exit/mountusb), `shell_exec_external()` (the `/bin/` fallback).
- `user/shell.c3` — trimmed to just the read/tokenize loop + a call
  into `shell_common.c3`. This is now what `scripts/build_duo.sh`
  embeds for real hardware: 336KB (was 685KB), most of the drop being
  `bigread_buf`'s 300KB test-only fixture buffer and the race/mutex
  test stacks, none of which real hardware ever needs.
- `user/shell_test.c3` — every dev/regression-test builtin, falling
  back to `shell_common.c3` for anything it doesn't itself handle. This
  is what `scripts/build.sh` (QEMU) embeds — full regression coverage
  unchanged.

One real build-system wrinkle: `objcopy -Ibinary` derives the embedded
`_binary_*_start/_end` symbol names from the input file's own
basename, and `src/kernel.c3` references `_binary_shell_bin_start`
unconditionally (board-agnostic). Simply linking `shell_test.bin.o`
for QEMU would have produced `_binary_shell_test_bin_*` instead,
silently failing to link against what `kernel.c3` expects. Fixed by
having `scripts/build.sh` re-embed `shell_test.bin` under the literal
name `shell.bin` in its own separate directory (`build/user_qemu_shell/`,
not `build/user/`, which still holds the real production
`shell.bin.o` for `build_duo.sh`) right before the kernel link step —
no change needed to `build_user.sh`'s one-name-per-binary convention or
to `kernel.c3` itself.

Verified full regression parity across all three QEMU disk-image
variants (`disk.img`, `disk_ext2.img`, `disk_dual.img`) before and after
the split — every test builtin behaves identically, including the ones
needing the correct non-default disk image (`mounttest`/`runtest2`/etc.
need `disk_dual.img`, `fspermtest`/`p9fstest`/etc. need `disk_ext2.img`
— confirmed against the wrong image first, which is expected FAT32-vs-
ext2/single-vs-dual-mount behavior, not a regression).

**Security-boundary hardening.** `src/entry.c3`'s syscall dispatch had
no user-pointer validation anywhere — every raw pointer/out-pointer
argument (`(T*)(uptr)f.aN`) was dereferenced directly, relying on
`sstatus.SUM` (permanently set, `process.c3`'s `user_entry`) to let
S-mode touch `PAGE_U` pages unconditionally. Worst two: `SYS_FUTEX_WAIT`
dereferenced its argument with zero checks (`*futex_addr`, no null
check even), and an unrecognized syscall number hit
`default: panic::panic("unexpected syscall")` — both a one-line,
unprivileged, whole-kernel crash reachable from any process.

Added `user_range_valid(table2, vaddr, len, want_write)` to
`src/page.c3`, alongside `walk_to_leaf_table`/`map_page`/
`map_device_page` (reusing `pte_to_paddr`, the `PAGE_*` flags):
non-allocating page-table walk validating every page in `[vaddr,
vaddr+len)` is present, `PAGE_U`, and has the requested permission —
returns false (rather than allocating, unlike `walk_to_leaf_table`) on
the first gap, with an overflow check on `vaddr+len`. Applied at every
unvalidated raw-pointer syscall site the audit found — `SYS_FUTEX_WAIT`,
`SYS_IPC_SEND`/`REPLY`/`RECV`/`RECV_GEN`/`POLL`, `SYS_NS_RESOLVE`,
`SYS_NS_UNMOUNT`, `SYS_NS_MOUNT`/`_WAIT`, `SYS_SRV_POST`, `SYS_RFORK`'s
generation out-pointer, `SYS_PROC_INFO`, `SYS_PARENT_INFO`,
`SYS_DISKD_INFO`/`SYS_FS_PARTITION_INFO`/`SYS_USBD_INFO`/
`SYS_NETD_INFO`/`SYS_ETHD_INFO`'s out-pointers, and `SYS_EXEC`'s own
`exec_image` root pointer (previously the *only* completely
unvalidated part of an otherwise carefully bounds-checked syscall — a
bad `exec_image` pointing at kernel memory could have leaked up to
`EXEC_MAX_IMAGE_SIZE + EXEC_MAX_ARGV_SIZE` bytes of it into a process's
own executable pages). Each failure denies with the same
`f.a0 = (ulong)(-1); break;` convention this file already used for
`SYS_SETUID`'s non-root case, instead of proceeding. The `default:`
case got the same fix — deny, don't panic. `SYS_NS_MOUNT_WAIT`'s own
caller-supplied attempt count (a plain `ulong`, no cap) is now clamped
to a new `NS_MOUNT_WAIT_MAX_ATTEMPTS` (50,000,000 — comfortably above
`mountusb`'s own 2,000,000, the largest real caller today).

Explicitly not done, flagged rather than fixed: restricting the
`*_INFO` syscalls to their intended driver process only (several
comments say "diskd-only"/"usbd-only" but it's unenforced) — `fsd` can
now be dynamically `exec()`'d against arbitrary backends with a
non-fixed pid (this same day's `mountusb` work), so a naive
caller-pid-must-match check would break that; and IPC send/reply's
unbounded wait on the destination process draining its inbox, inherent
to this project's cooperative, timeout-free Plan-9-style IPC design.

Added a kept regression test, `hardentest` (`user/shell_test.c3`):
issues a real `SYS_FUTEX_WAIT` on a null pointer and a real,
genuinely-unrecognized syscall number (31 — one past `SYS_ETHD_INFO`),
confirms both come back denied rather than hanging the whole suite (a
panic halts every process) or never returning. Passes in QEMU; the
full existing regression suite re-run clean afterward too, including
every syscall path the new checks touch (IPC round trips, `ns_mount`/
`_wait`, `exec`/`exec_path`, `/proc` reads, `rfork`) — no false
positives found.

**Dead code removed**: `disable_interrupts()`/`enable_interrupts()`
(`src/entry.c3` — never called, superseded by
`enable_external_interrupts()`); `top_reg_read()`
(`user/block/sdhci.c3` — never called); the `PLIC_PENDING_PAGE`
mapping (`board::PLIC_PENDING_BASE`/`PLIC_PENDING_PAGE` in both
`boards/qemu/board.c3` and `boards/duo/board.c3`, plus its two
`map_device_page()` call sites in `src/process.c3` and `src/entry.c3`'s
own `SYS_RFORK` child-table setup — confirmed never read anywhere,
leftover from the reverted Slave/PIO investigation; caught the second
call site only via a compile error after removing the board constant,
first grep missed it). `scripts/launch.sh`/`scripts/stress_test.sh`
deleted — both target `build/disk.tar` on `qemu-system-riscv32`, long
superseded by the RV64/FAT32-image build and `scripts/launch64*.sh`.
Not touched: `src/libc/libc.c3`'s unused-but-`@nostrip` functions
(deliberate ABI-completeness marker) and `test/xpad_parse_test.c3` (a
real test with its own dedicated script, just outside the four build
scripts searched).

Confirmed end to end on real Milk-V Duo hardware after all three parts
landed: normal boot, `mountusb` → `ls /mnt/usb/` → `cat` still work
exactly as before against the real USB drive — the trimmed production
shell and the new syscall-boundary checks don't interfere with any real
driver's own legitimate use of the hardened syscalls (`usbd`'s
`SYS_USBD_INFO`, the dynamically-spawned `fsd`'s namespace/exec calls,
etc.). Real hardware's own `fip.bin` shrank from ~1.72MB to ~1.37MB,
reflecting the production shell's size drop.

**Files changed:** `user/shell.c3` (trimmed), `user/shell_common.c3`
(new), `user/shell_test.c3` (new, `hardentest` added), `src/page.c3`
(`user_range_valid`), `src/entry.c3` (validation call sites, `default:`
fix, `NS_MOUNT_WAIT_MAX_ATTEMPTS`, dead-code removal),
`user/block/sdhci.c3`, `src/process.c3`, `boards/qemu/board.c3`,
`boards/duo/board.c3`, `scripts/build_user.sh`, `scripts/build.sh`;
`scripts/launch.sh`/`scripts/stress_test.sh` deleted.

---

## 2026-08-26 (continued) — Tier 2: mounting a real USB Mass Storage drive as a browsable filesystem (`mountusb`), plus real GPT support and a real namespace-scoping bug found on real hardware

Direct continuation of the same day's Tier 1 work (raw sector read/write
via `usbrw`, previous entry). Tier 2's goal: make the drive's own
filesystem mountable and browsable (`/mnt/usb/`), not just raw-sector
accessible.

**Unified the wire protocol first**: `usb_msc_ipc_poll()`'s verb
constants (`user/usb/msc.c3`) changed from 100/101 to 10/11, exactly
matching `DISKD_READ`/`DISKD_WRITE` (`user/block/diskd.c3`). This makes
`usbd` a genuine drop-in diskd-compatible block server — `fsd.c3`'s own
`diskd_rw()` needed zero wire-protocol changes, only a different target
pid. `usbrw.c3`'s duplicated copy of the constants updated to match.

**`fsd.c3` gained a dynamic-backend mode**: `fn void main()` became
`fn void main(String[] args)`. `args.len == 0` (the boot-time
`create_process`'d fsd/fsd2) is byte-for-byte the original path,
untouched. `args.len == 1` (a `srv_post()`-ed backend name, e.g.
`"usbd"`) resolves it via `ns_mount_wait("/srv/<name>/", name, 200)` +
`ns_resolve()`, stores the result in a new mutable `g_diskd_pid`
(replacing the old `const DISKD_PID`), then reads and parses LBA 0's
MBR itself before running the same `ext2_probe()`/`fat32_probe()` logic
already used for the static path.

**Real drive forced real, unplanned scope**: the original plan
explicitly called GPT parsing out of scope ("a partition-table-less
superfloppy still works" was the fallback). The real 32GB Transcend
drive's actual boot sector turned out to be a GPT protective MBR
(`33 c0 fa 8e d8 8e ...`, the standard MS-DOS bootstrap stub, with
partition entry 0's type byte = `0xEE`) — real GPT, not raw FAT32 nor
a normal MBR. Added `fs_parse_gpt_partition_start()` to `fsd.c3`: reads
LBA 1's `"EFI PART"` header, follows `PartitionEntryLBA` (header offset
72) to the first real entry, reads its `StartingLBA` (entry offset 32).
Small, well-justified, done without stopping to ask first since it was
the user's actual real test drive — correctly found `fs_partition_start
= 2048`, and the drive's real FAT32 filesystem mounted correctly on
the very next real-hardware round.

**First cut of `mountusb` was wrong, and only real hardware caught it.**
Built as a standalone `/bin/mountusb` command (`rfork(RFPROC)`+
`exec_path("fsd", ...)` for the dynamic fsd child, then its own
`ns_mount_wait("/mnt/usb/", "usbfs", ...)` call to bind the mount and
report success). On real hardware this printed `mountusb: mounted at
/mnt/usb/` correctly every time — genuine success, real GPT parse, real
FAT32 mount — but the very next `ls /mnt/usb/` at the same shell prompt
reported "not found" regardless. Root cause, found by re-reading
`SYS_NS_MOUNT`/`SYS_RFORK` (`src/entry.c3`): `ns_mount()` binds a prefix
into whichever process calls it, and `rfork()` only ever copies a
namespace from parent to child at the moment of the call — never the
reverse, and never retroactively. `mountusb` as a separate command is
itself just another `rfork()`'d+`exec()`'d child of the interactive
shell (same as `ls`/`cat`): it mounted `/mnt/usb/` into its *own*,
already-doomed namespace, then exited, taking the mount with it. The
shell's own namespace — and everything the shell `rfork()`s afterward,
including every subsequent `ls`/`cat` — never saw it.

Fixed by turning `mountusb` into a real shell builtin (`user/shell.c3`),
following the exact pattern its own pre-existing `mounttest`/
`hotplugtest` builtins already established (call `ns_mount`/
`ns_mount_wait` directly in the shell's own long-lived process, not a
throwaway child). The dynamic-fsd-spawning half is unchanged; only the
final `ns_mount_wait("/mnt/usb/", "usbfs", ...)` call moved from the
now-deleted `user/bin/mountusb.c3` into `shell.c3` itself, reusing its
existing `run_exec_buf`/`RUN_EXEC_BUF_MAX` (already sized for any
binary this project ships, including `fsd.bin`) instead of a second,
separately-sized buffer. Confirmed the fix on real hardware immediately
after: `mountusb` → `ls /mnt/usb/` → real `TMP/`/`PIPPO.TXT` listing →
`cat /mnt/usb/PIPPO.TXT` → real file content (`asd`), end to end.

Also hit, along the way, a smaller real gotcha worth recording: this
system's namespace-prefix matching (`SYS_NS_RESOLVE`, `src/entry.c3`)
is an exact `str_starts_with` against the *literal* registered prefix
string, including its trailing slash — `ls /mnt/usb` (no trailing `/`)
genuinely fails to resolve at all (the path is shorter than the
prefix), same as it would for any other mount (`/srv/`, `/proc/`,
`/mnt/fs2/`). Not a bug, just this project's existing convention
applied to a fresh mount point for the first time.

**Files changed:** `user/usb/msc.c3` (verb constants), `user/bin/usbrw.c3`
(matching constants), `user/fs/fsd.c3` (`main(String[] args)`,
`g_diskd_pid`, MBR + GPT parsing, `fs_mount()` dynamic-mode params),
`user/shell.c3` (new `mountusb` builtin, replacing the deleted
`user/bin/mountusb.c3`), `scripts/build_user.sh`/`scripts/build.sh`/
`scripts/populate_duo_bin.sh` (build/deploy wiring, `mountusb` binary
entry removed, `fsd` binary entry kept — the shell `exec_path()`s it by
name at runtime).

---

## 2026-08-26 (continued) — RESOLVED: the "USB 3.0 flash drive won't enumerate" mystery was a swapped LOW_SPEED/HIGH_SPEED bit in GetPortStatus decoding, not a cable/hub/device problem at all

Direct continuation of the same day's earlier entries. The user pushed
back hard on the previous session's "device/cable-specific, not a
driver bug" conclusion about the USB 3.0 drive that kept failing
enumeration with an implausible low-speed report — correctly.

Re-verified a foundational assumption instead of defending the earlier
conclusion: `USB_PORT_STATUS_HIGH_SPEED_B1`/`_LOW_SPEED_B1`
(dwc2.c3) were inherited from before this session's own rewrite,
never independently re-checked. Checked real vendor Linux 5.10's own
`include/uapi/linux/usb/ch11.h` directly:
`USB_PORT_STAT_LOW_SPEED = 0x0200` (wPortStatus bit 9),
`USB_PORT_STAT_HIGH_SPEED = 0x0400` (bit 10). `port_status[1]` is byte
1 of the 4-byte GetPortStatus reply (bits 8-15), so the local bit
position is (global_bit - 8): LOW_SPEED -> local bit 1, HIGH_SPEED ->
local bit 2. **This project's own constants had them backwards** —
`HIGH_SPEED_B1 = 1<<1` and `LOW_SPEED_B1 = 1<<2`, exactly swapped.

**Why this was so hard to catch**: it's silently harmless for a
genuinely full-speed device (neither bit set, correctly falls through
to the FULL branch regardless of the swap) — which is exactly why the
mouse tested two sessions ago worked perfectly and gave zero signal
that anything was wrong. It only misfires for a genuinely low-speed OR
high-speed device, and every such device this project had tried before
today was the one specific 8BitDo pad (whose own real problem is
unrelated/device-specific, so it never produced a clean enough signal
to notice). The USB 3.0 flash drive was the first genuinely Hi-Speed-
capable device ever tested here — and got immediately misclassified as
low-speed, which then made this driver wrongly force split-transaction
handling (SSPLIT/CSPLIT via the hub's own TT) onto a device that should
have been addressed directly at Hi-Speed with no splitting at all —
producing exactly the observed start-split-not-ACKed/STALL failures,
identically, regardless of every cable/port/timing variable tried.

Fixed by swapping the two constants' values (names were already
correct). **Confirmed on real hardware, immediately, completely**: same
raw `GetPortStatus` bytes as every previous attempt (`03 05`), now
correctly decoded as `device speed=high, no split needed` — and the
drive enumerated fully: `INQUIRY vendor="JetFlash" product="Transcend
32GB"`, `capacity: 59725824 blocks x 512 bytes`, and a real `READ(10)`
of LBA 0 returning genuine data (`33 c0 fa 8e d8 8e d0 bc 00 7c 89 e6 06
57 8e c0` — an authentic x86 boot sector signature). This is the first
successful real USB Mass Storage read in this project's history, and
it needed zero split-transaction machinery at all — the drive was
always meant to talk directly.

**The lesson, stated plainly**: the user's skepticism ("I think our usb
driver implementation is fundamentally wrong on something") was
correct, and the fix was in re-verifying a foundational, never-
independently-checked assumption directly against source, not in more
hardware experimentation. Every other USB investigation this project
ran on this exact symptom (MULTICNT, yield() removal, multi-TT vs
shared-TT, reset-recovery timing, CLEAR_TT_BUFFER) was real, correct,
and worth keeping — but none of them could have found this, because the
actual bug was upstream of all of them: the driver never even knew
this was a Hi-Speed device in the first place.

---

## 2026-08-26 (continued) — Added a standalone usbrw tool + usbd IPC responder for raw USB-drive sector I/O; surfaced and fixed a real EXT2_MAX_GROUPS bug along the way (the real root fs is 57.3GB, not ~1GB)

Direct continuation of the same day's earlier entry, chasing "verify USB
Mass Storage on real hardware" (Tier 1 of the two-tier plan from the
previous session: raw read/write first, real fsd/mount integration
later — see that entry).

**Implemented**: `msc_write10()` (SCSI WRITE(10), mirrors the existing
`msc_read10()`); a small IPC responder in `usb/msc.c3`
(`usb_msc_ipc_poll()`, non-blocking, called from usbd's own main loop)
exposing whatever MSC device is currently attached over the same
516-byte wire shape as diskd's own `DISKD_READ`/`DISKD_WRITE`; and a new
standalone command, `user/bin/usbrw.c3` (`usbrw read/write <lba>
<path>`), talking to it via the project's own existing Plan-9-style
`srv_post()`/`ns_mount_wait()` mechanism (the same pattern `fsd2`
already uses) — usbd's own pid isn't fixed (spawned last at boot, after
the shell itself) and `rfork()` copies the parent's namespace verbatim
(confirmed by reading `src/entry.c3`'s own `SYS_RFORK` case), so a
static namespace default would've been permanently stale for every
shell-spawned command; briefly considered and reverted that approach
before landing on the dynamic one. Fixed the same endpoint-descriptor-
walk bug in `msc.c3`'s own endpoint scan that the earlier xpad session
found, defensively (no real device has shown it there yet). Zero kernel
changes — this is fully user-space. New `scripts/populate_duo_bin.sh`
(mirrors `flash_duo.sh`'s own style) to copy `build/user/*.bin` onto the
real Duo's root ext2 filesystem's `bin/`, needed because — a genuinely
new discovery — no exec()'d command had ever actually been tested
against the real Duo's SD card before, only QEMU's disk images.

**That discovery led somewhere real.** Once `usbrw`/`ls`/`cat` were all
copied onto the real root filesystem and the board rebooted, *every*
command failed with "command not found" — not specific to `usbrw` at
all. `fsd` still reported a clean mount (`fsd: ext2 mounted...`), and
root-level lookups already worked (the protected-file check ran
normally) — so this wasn't a mount failure, just something about the
newly-created `bin/` directory and its contents specifically.

Root cause, found by re-reading `ext2.c3`'s own comments: an earlier
session already found and fixed a real bug here — real Linux tools
spread new files/directories across ext2 block groups, and this driver
used to only ever know group 0's own inode table, silently treating
anything in another group as not-found. That fix added `EXT2_MAX_GROUPS
= 64`, reasoned as "generous... a 1GB partition needs about 8." That
reasoning was built on a wrong assumption about the actual hardware:
the real Duo's root ext2 partition is **57.3GB** (the SD card's second
partition, everything after the 1GB DUOBOOT FAT32 one — confirmed by
the exact arithmetic: `board::FS_PARTITION_START_SECTOR` = 2099200
sectors = exactly 1GiB), needing roughly **459** groups at this card's
own density — seven times over the old cap. Every group-indexed lookup
in this file already "fails closed" (treated as not-found) for
anything beyond what the arrays actually cover, by design — so this
never crashed anything, it just made the *entire* newly-created `bin/`
directory (and anything else ever written to this real filesystem from
outside this driver) silently invisible the moment its inode or data
landed in group 64 or beyond, which is overwhelmingly likely for any
new allocation on a huge, mostly-empty real filesystem.

**Fix**: bumped `EXT2_MAX_GROUPS` from 64 to 2048 (covers up to ~256GiB
at this same density — real headroom for a bigger card later, at a
trivial cost: three `uint[2048]` arrays, 24KB total static memory).
Corrected the old comment's wrong "~1GB partition" assumption with the
real, verified number. Confirmed no regression on QEMU's own (tiny,
single-group) ext2 test image.

**Confirmed on real hardware**: `ls` now runs and correctly lists the
real filesystem's actual root contents (`lost+found/ bin/ tmp/`) — no
more "command not found." `usbrw read 0 test.bin` also now runs
end-to-end, correctly reaching usbd via `ns_mount_wait`/`p9_call_path`
and getting a real, honest reply: "no MSC device attached" — because
the specific USB drive plugged in at the time failed enumeration for
the same still-unresolved low-speed/STALL reason from the previous
entry (now on a different hub port, same symptom — still looks like a
device/cable issue, not something new or something either of today's
fixes could touch). Both the ext2 fix and the usbrw/usbd IPC path are
genuinely proven working on real hardware, independent of whether a
cooperating USB drive is available to test full read/write against.

This is a good example of the same pattern the whole USB investigation
kept running into: a limit or assumption that was completely reasonable
and correctly reasoned about *the hardware as understood at the time*,
silently wrong once a real, larger/different piece of hardware
(here: how big the actual SD card partition really is) got involved —
found only by actually trying something real on it, not by more code
review alone.

---

## 2026-08-26 — First real-hardware USB Mass Storage test surfaces a genuine LSPDDEV gap (fixed); a USB 3.0 flash drive still won't enumerate, reporting a implausible low-speed

Follow-on session, continuing the previous day's USB work with a fresh
"what's next" survey. `msc.c3` (SCSI TEST UNIT READY/INQUIRY/READ
CAPACITY/READ10 over Bulk-Only Transport) had existed since commit
`b05e602` but had never once been tested against a real device — a
natural next step now that the split engine is proven correct. Plugged
in a real USB 3.0 flash drive (using hot-plug detection, no reboot
needed) for the first-ever real test.

**Real bug found and fixed**: the device enumerated at `device
speed=low` — and `HCCHAR.LSPDDEV` ("low-speed device"), needed
whenever the channel talks to a genuinely low-speed device, had a
comment saying "never set, this driver only ever talks to full-speed
devices" — true until this exact test, since every device tried before
(the hub, the Xbox pad, the mouse) was full-speed. Fixed: threaded
device speed through the same global single-device-context mechanism
`g_split_active`/`g_split_hub_addr`/`g_split_hub_port` already use
(`g_device_is_low_speed`, set in `usb_set_split_context()`), consulted
in both `hc_transfer_once` and `hc_transfer_once_split` when building
HCCHAR. Verified against real vendor Linux 5.10's own `dwc2_hc_init()`
(duo-buildroot-sdk's linux_5.10/drivers/usb/dwc2/hcd.c): sets
`HCCHAR_LSPDDEV` under the exact same condition
(`chan->speed == USB_SPEED_LOW`), unconditionally regardless of
split — byte-for-byte match, not a guess.

**Still doesn't enumerate**, even with the fix. Added a raw
`GetPortStatus` byte dump before trusting the speed reading at all
(`03 05`) — byte1's bit2 (USB_PORT_STAT_LOW_SPEED, USB 2.0 spec table
11-15) is genuinely set, confirming this driver's own speed decoding is
correct and the hub itself is honestly reporting low-speed, not a
parsing bug. But a genuine USB 3.0 drive reporting 1.5 Mbps low-speed
is implausible on its face — even in USB2 fallback these almost always
negotiate full or high-speed. With LSPDDEV now correctly set, the
device still fails enumeration (`start-split not ACKed` twice, then a
genuine `STALL` on the third attempt's complete-split). The combination
— implausible-but-honestly-reported low speed, plus continued failure
even once handled per spec — points at an electrical/negotiation issue
specific to this exact drive, cable, or connector (a marginal D+/D-
connection, e.g. through a USB-C-to-A adapter, is a known real-world
cause of misdetected speed class), not something more driver code can
fix. Suggested the user try a different cable/adapter or a more
ordinary USB2 flash drive next. `USBD_VERBOSE` back to `false`.

---

## 2026-08-25 (continued) — CONCLUSIVE: split-interrupt IN proven working with a real device (a plain USB mouse); the Xbox 360-clone pad's own silence is device-specific, not a driver bug

Direct continuation of the same day's four earlier entries. Two more
real experiments, one of them decisive.

**A/B'd the multi-TT hub switch against the current scheduler**
(`USBD_MULTI_TT_SWITCH`, usbd.c3, new toggle) — the switch was added
and kept in an earlier session ("switch multi-TT-capable hubs into
per-port TT mode... doesn't resolve interrupt-split"), but that verdict
was only ever tested against the OLD frame-granularity scheduler, never
the current microframe-precise one. Real-hardware round: shared-TT mode
produced the exact byte-identical complete-split-NAK result as multi-TT.
Ruled out; restored to multi-TT (the spec-correct default for a
multi-TT-capable hub either way).

**The decisive experiment**: at the user's own suggestion ("maybe the
xbox driver has problems too... I have a mouse"), added a generic
fallback (`usb_find_any_interrupt_in()`, dwc2.c3;
`usbd_generic_interrupt_read_loop()`, usbd.c3) that finds and polls the
first interrupt IN endpoint on ANY device, regardless of class — no
xpad-specific assumptions at all. Plugged a plain USB mouse into the
same hub port. Real hardware result: **the mouse's interrupt IN
endpoint returned genuine `XFERCOMP` reports with real movement data**
(`usbd: generic-hid: report #1043 len=6: 00 ff ff 00 00 00`, etc.) —
after ~1000 polls of NAK while sitting still, exactly the correct
behavior for a device with nothing new to report, then real data the
moment it moved.

**This is conclusive, not just another data point.** It proves, with a
real device on real hardware, that this project's entire split-
interrupt IN stack — the microframe-precise scheduler ported from
circle-stdlib, the hub/TT addressing, the DMA/channel programming, all
of it — is genuinely correct end to end. Every session's worth of NAK-
forever on the Xbox-360-clone pad was never a "this driver can't do
split interrupt IN at all" problem; a plain mouse proves that channel
works. The pad's own silence — even under sustained button holds and
full stick deflection, tested one more time after this confirmation —
is specific to that one device's own firmware. It's an 8BitDo SN30 Pro
spoofing Microsoft's own 045e:028e VID/PID (confirmed by the user), and
it does work under the user's own Linux desktop with the same generic
xpad.ko and no special quirk handling — but that path almost certainly
never exercises a split transaction at all (a direct root-port or
same-speed-hub connection needs no TT relay), while this project's own
setup always does (Hi-Speed root port, full-speed pad, mandatory
split). The most likely real explanation is a genuine compatibility
limitation in this specific budget controller's own USB silicon when
addressed via a hub's TT — a known category of real-world issue for
cheap USB device controllers, not something fixable in this driver.

**Where this actually leaves the project**: solved, in the sense that
mattered architecturally. The DWC2 host controller now has a real,
working, sourced split-transaction engine for control, bulk, AND
interrupt transfers, in both directions, confirmed on real hardware —
something no prior session in this project's history achieved. Any
standards-compliant interrupt-IN device (mouse, keyboard, most real
gamepads) behind this exact hub will work. This specific pad is a real,
separate, hardware-compatibility question outside what a driver rewrite
can resolve — closed out, not left open, for this project's purposes.
`USBD_VERBOSE` back to `false`; `USBD_MULTI_TT_SWITCH` back to `true`.

---

## 2026-08-25 (continued) — Hub-downstream hot-plug detection added; a real, sticky XACTERR captured once and CLEAR_TT_BUFFER recovery implemented for it; IN direction still never returns real data

Direct continuation of the same day's three earlier entries, pushed
further at the user's own request ("push it!").

**Real, sourced correctness fixes to the split engine**, cross-checked
against real vendor Linux 5.10's own `dwc2_hc_start_transfer()`
(duo-buildroot-sdk's linux_5.10/drivers/usb/dwc2/hcd.c — the
authoritative reference for *this exact silicon*, as opposed to
circle-stdlib which targets a different SoC's own DWC2 integration):
- A complete-split OUT transaction should program `HCTSIZ.xfersize = 0`
  ("so the core doesn't expect any data written to the FIFO" — the
  payload already went out during the start-split); this driver was
  reusing the original xfer_len instead. Fixed in
  `hc_transfer_once_split`'s periodic branch.
- `HCCHAR.MULTICNT` for split INT/ISOC is `3` in real Linux's own
  driver (`ec_mc = 3`, its own comment: "for immediate retries"),
  matching what U-Boot independently already does — not `1`, which is
  circle-stdlib's own value for a different SoC. Restored to 3 (a
  same-day A/B round already found zero observable difference between
  1 and 3, but 3 is the value the actually-correct reference for this
  chip uses).

**Real feature added**: hub-downstream hot-plug detection
(`usb_poll_hub_ports()`, usbd.c3), polled every ~1s from main()'s own
loop. Gap this driver always had: the hub's own downstream ports were
only ever checked *once*, immediately after the hub itself finished
enumerating — a device plugged in any time after that was silently
never noticed, regardless of how long the system kept running. This
also let a genuinely different test run for the first time all day:
booting with only the hub attached (no pad) and hot-plugging the pad
into an already-idling, fully-stable bus, instead of every previous
round's cold-boot-with-pad-already-attached. Confirmed working end to
end: `usbd: hub port 3: hot-plug detected` → clean enumeration, LED
XFERCOMP again.

**New failure mode captured, once**: during that hot-plug round, after
~10-15 clean complete-split NAKs, the interrupt IN channel escalated
into a persistent, *never self-recovering* `XACTERR`
(`HCINT=0x00000082`) — every subsequent poll, forever, not a transient
blip. This is a different, real signature from the plain-NAK baseline,
and matches the textbook case for USB 2.0 spec section 11.24.2.3's
`CLEAR_TT_BUFFER` hub class request: a Hi-Speed hub's Transaction
Translator can get its own internal per-endpoint buffer wedged after a
split transaction error, in a state a plain host-side channel
reset/reprogram can't clear — only this explicit request, sent to the
hub itself, resets it. Sourced directly from real Linux's own
`hub_clear_tt_buffer()` (same hub.c). Implemented
`usb_clear_tt_buffer()` (dwc2.c3) and wired it into the periodic
complete-split's hard-error path (XACTERR/BBLERR/FRMOVRUN, not STALL —
a STALL is the device's own deliberate refusal, not a TT-buffer state,
and real Linux doesn't clear the TT for that case either).

**Not yet confirmed working**: a subsequent 5000-poll cold-boot run
(pad already attached, no hot-plug) never reproduced the XACTERR at
all — clean NAK the entire time, same as every previous round — so
`CLEAR_TT_BUFFER`'s own recovery path has real, sourced justification
but hasn't actually been exercised and confirmed successful yet. The
XACTERR looks tied to the hot-plug connection transient specifically,
not a steady-state condition.

**Where this stands**: the split-interrupt engine is now real-hardware
confirmed correct for the OUT direction, cross-checked against the
correct SoC-matched reference in two more places, has spec-correct
error recovery for the one new failure mode observed, and gained a
real, independently useful feature (hot-plug) along the way. The IN
direction has still never once returned real device data across
thousands of polls, several completely different scheduling algorithms
faithfully replicated from four real reference drivers over many
sessions, and now confirmed-non-quirky pad hardware (rumble works fine
under the user's own Linux desktop). Every avenue this project's own
source-reading approach can reach has now been tried at least once.
What's left needs to actually see the SSPLIT/CSPLIT/hub-relay exchange
on the wire — a protocol or logic analyzer — not another round of
driver comparison. Paused here, with real, durable progress banked
regardless of the open question.

---

## 2026-08-25 (continued) — First-ever confirmed-working split interrupt transaction (LED command, OUT direction); two real bugs fixed along the way; IN direction still silent, now looks device-specific rather than a driver bug

Direct continuation of the same day's two earlier entries. Pushed back
on my own conclusion from the previous entry (that this needed a
multimeter to rule out power delivery) — real Linux demonstrably powers
this exact pad through this exact hub and gets both the buzz and
working data, so the wiring is proven capable and the gap has to be
software, not hardware. That correction led somewhere real.

**Re-read real vendor Linux 5.10's own `drivers/input/joystick/xpad.c`
directly** (duo-buildroot-sdk's own tree, the exact kernel that produced
the working reference behavior — not upstream mainline) rather than
assuming. Two concrete, sourced gaps found:

1. **`hub_port_reset()`** (drivers/usb/core/hub.c): after the port
   reports enabled, real Linux does an *additional* `msleep(10 + 40)` =
   50ms "TRSTRCY plus some extra" reset-recovery settle — a real delay
   this driver never had at all, going straight from "port enabled"
   into SET_ADDRESS/GET_DESCRIPTOR. Rewrote `usb_reset_hub_port()`
   (dwc2.c3) to poll for RESET-clear+CONNECTION (like real Linux's
   `hub_port_wait_reset()`, simplified) with up to 3 reset attempts, and
   added the missing 50ms post-enable settle.
2. **`xpad_led_probe()` → `xpad_identify_controller()`** (xpad.c): sends
   an unconditional 3-byte LED-set command (`01 03 <pattern>`) over the
   interrupt OUT endpoint right after enumeration, called directly from
   `xpad_probe()` — NOT gated behind any application ever opening the
   input device. This overturns an assumption held since an earlier
   session ("pure firmware behavior, independent of any host driver")
   — the pad's power-on behavior is host-triggered, and this driver had
   never sent it anything at all, read-only the whole time. Added
   `usb_interrupt_transfer_out()` (dwc2.c3) and wired it into
   `usb_enumerate_hub_port_device()`'s own xpad branch (usbd.c3).

**Real bug found and fixed while wiring in the LED command**: the
endpoint-descriptor walk in `usb_enumerate_hub_port_device()` looped
exactly `num_endpoints` (2) raw iterations by *position*, not by real
endpoint count. A genuine Xbox 360-protocol pad's own vendor-specific
interface has a proprietary 0x21 ("XInput") descriptor sitting between
the interface descriptor and its two real endpoints — that descriptor
consumed one loop iteration, so the walk found endpoint #1 (IN) and
stopped one iteration short of ever reaching endpoint #2 (OUT). Real
hardware confirmed this exactly: "no interrupt OUT endpoint found" even
though the device unquestionably has one (real xpad.c requires exactly
2 to even probe the device). Fixed to count only real ENDPOINT-type
descriptors, and to stop early at the next INTERFACE descriptor.

**Real hardware result — this is the milestone**: with both fixes in,
the LED command's own split OUT transaction completed with a clean
`XFERCOMP` — `usbd: split intr diag #1: XFERCOMP` — the first split
*interrupt* transaction, in either direction, this project has ever
gotten to complete. This proves the periodic scheduler ported from
circle-stdlib (previous entries) is mechanically sound: correct hub/
port addressing, correct microframe scheduling, the whole split
mechanism genuinely works on this real hardware. The pad's own LED
did not visibly change state (the user reports it was already lit
solid before this command — plausibly this exact 8BitDo pad's own
default "connected, unassigned" state looks the same as pattern 2), but
the transaction itself completing at the protocol level is the real
signal, independent of what it visibly did to the LED.

**Still open**: the interrupt IN endpoint (the actual input reports)
still NAKs every single poll, even immediately after the LED command's
own confirmed success and with active button presses. Checked one more
real Linux code path before concluding: `xpad_inquiry_pad_presence()`
(an extra 12-byte init packet) exists in xpad.c but is wireless-
receiver-only (`xpad360w_start_input`), never sent for a wired pad —
so there's no missing Linux-side sequence step left to find; the LED
command really is everything real Linux sends before polling IN. The
user confirmed this exact device is an 8BitDo SN30 Pro VID/PID-cloned
into Xbox 360 compatibility mode, not a genuine Microsoft pad — first
suspected an 8BitDo-specific firmware quirk, but the user then shared
their own Linux desktop's `lsmod`: `xpad`+`ff_memless` loaded, rumble
genuinely works, on this same physical pad. That's a fully compliant,
non-quirky pad under a normal host stack, which weakens the firmware-
quirk theory — though that desktop is a full xHCI host with no hub-
mediated USB2 split transaction in the picture at all, so it isn't
directly comparable to this project's own DWC2-host-through-hub path.
With the split mechanism now proven correct end-to-end for OUT, the
most likely remaining explanation shifts to something specific to how
this DWC2 core/hub combination schedules or buffers the IN direction of
a split periodic transaction differently from OUT — not obviously
resolvable by more source comparison; back to needing wire-level
visibility for this specific asymmetry, same conclusion this bug has
reached before, but from much closer in now that OUT is confirmed
working. Real, substantive progress banked regardless: two genuine bugs
fixed (endpoint walk, missing LED init) and the split-interrupt
mechanism itself finally confirmed working on real hardware for the
first time. `USBD_VERBOSE` back to `false`.

---

## 2026-08-25 (continued) — Two targeted, sourced fixes for the new complete-split-NAK signature, both cleanly negative — rules out scheduling jitter and MULTICNT, not timing precision itself

Continuation of the same day's dwc2.c3 rewrite (previous entry). The
rewrite's new failure signature — immediate, 100%-reproducible NAK on
the very first complete-split attempt, no variance across ~1500+ real
polls including active button presses — is different enough from the
old NYET-forever signature to be worth chasing with two concrete,
sourced hypotheses before pausing again.

**Hypothesis 1: HCCHAR.MULTICNT.** For a split *periodic* transaction,
this field isn't "packets per microframe" the way it is for a plain
periodic transfer — real Linux's own driver comments describe it as the
number of complete-splits the DWC2 core retries *autonomously in
hardware* before ever signaling CHHLTD back to software. U-Boot sets it
to 3 ("for immediate retries"), which this rewrite had carried over
unchanged from the old driver. But circle-stdlib's own `StartChannel()`
always uses `MULTICNT=1`, unconditionally, for everything — because its
own scheduler owns retry pacing entirely in software and never wants the
hardware racing its own internal, differently-timed retries underneath
that. Real-hardware round: MULTICNT=1 for interrupt splits produced the
exact byte-identical result as MULTICNT=3. Negative, but MULTICNT=1 is
kept anyway (real reference value, no reason to prefer 3).

**Hypothesis 2: yield() inside the microframe busy-wait.** Read this
project's own kernel scheduler (`src/process.c3`'s `fn yield()`) directly
rather than assuming: it's not a lightweight "let something else run if
it wants to" — it unconditionally round-robins to the next RUNNABLE
process and full-context-switches to it, only returning once every other
runnable process (ethd, fsd, the shell — always present) has had its own
turn. A single call can easily cost far more than one 125us microframe,
which would make the new scheduler's own busy-wait-to-a-specific-
microframe (`usb_wait_for_microframe()`) land at an effectively
arbitrary microframe instead — a real, plausible explanation for a
signature this deterministic. Removed yield() from that one loop
specifically (kept bounded via a real-time rdtime() budget, no syscall,
so it can't reintroduce the SIE/SYS_GETCHAR deadlock SYS_YIELD's own
comment documents — see the code comment for the full reasoning).
Real-hardware round: byte-identical result again, same NAK, same poll
counts. Negative. Kept anyway — it's still the architecturally correct
way to hit a 125us target regardless of this specific bug.

**What this rules out**: two real, independent, plausible causes, both
cleanly negative, and — notably — *identical* results regardless of
timing precision (yield-paced vs. bare-spin) or hardware retry count
(MULTICNT 1 vs. 3). That invariance is itself informative: if this were
a scheduling-jitter or hardware-auto-retry problem, changing either of
those should have changed the outcome, and neither did. Combined with
the old algorithm's own equally invariant NYET-forever signature across
many different retry-shape changes in earlier sessions, the emerging
picture is that this bug doesn't live in the software retry/scheduling
logic at all. The strongest remaining, still-unresolved lead is one this
project has flagged before and never chased down: the pad's own real
power-on self-test buzz (pure firmware behavior, confirmed happening
under real Linux on this exact hardware every time) has never once
happened under this driver, across every session and every algorithm
tried — consistent with the device not actually being fully powered/
booted, in which case an immediate, always-NAK complete-split (the hub
correctly reporting "nothing new from downstream") would be the
*correct* protocol-level response to a device that genuinely has nothing
to report, not a driver bug at all. Not confirmed — would need a
powered hub/multimeter check on the port's actual VBUS delivery under
load, not more source or scheduling changes. `USBD_VERBOSE` back to
`false`. Paused here.

---

## 2026-08-25 — dwc2.c3 rewritten from zero against circle-stdlib's real DWC2 driver; interrupt-split still not completing, but a new and different failure signature

`user/usb/dwc2.c3` (1762 lines) had accumulated so much session-by-session
narrative in its own comments — every hypothesis tried and reverted for
the still-open interrupt-split bug — that it had become hard to reason
about on its own terms. Rewrote it from a clean slate this session,
using circle-stdlib's real DWC2 ("dwhci") host driver
(github.com/rsta2/circle, fetched and read directly — lib/usb/dwhci*.cpp,
include/circle/usb/dwhci.h, not from memory) as the primary structural
and algorithmic reference, cross-checked against Linux where relevant.

**What's unchanged in substance**: every CV1800B/Milk-V Duo TOP-block
register fact, the core-reset sequence, the real vendor-debugfs-sourced
FIFO sizing values, and non-split control/bulk transfer mechanics —
these are real-hardware-proven facts orthogonal to Circle (which targets
different SoC glue), just retyped clean with terser, fact-only comments
instead of session archaeology.

**What materially changed**: the split-transaction (SSPLIT/CSPLIT)
engine. Reading Circle's real periodic-split state machine end to end
(`CDWHCIFrameSchedulerPeriodic` in dwhciframeschedper.cpp, driven by the
`StageStateStartSplit`/`StageStateCompleteSplit` handling in
dwhcidevice.cpp) surfaced a genuinely new, sourced algorithm this driver
had never tried — every prior attempt (mainline Linux, U-Boot, TinyUSB,
all faithfully replicated in earlier sessions) scheduled at *frame*
granularity and treated complete-split NAK the same as NYET (retry both).
Circle's real, working algorithm is microframe-precise: busy-wait to a
specific target microframe before the start-split (current+1, skip
microframe 6), first complete-split poll at start_mf+2, each NYET/ACK
retry advances by exactly 1 microframe (budget 3 tries, 2 if
start_mf==5), and — the key semantic difference — a complete-split NAK
is *not* retried at all, only NYET/ACK are, since NAK and NYET mean
different things for a periodic split (NAK: hub has nothing new; NYET:
still relaying, ask again). Implemented faithfully; control/bulk splits
were deliberately left exactly as before (already proven working, and
Circle's own non-periodic scheduler for that path is a smaller,
lower-risk change not needed to fix the open bug).

**Real hardware result**: full non-regression on every previously-working
path — HPRT0 bring-up, full enumeration through the IO board's hub,
multi-TT `SET_INTERFACE`, config descriptor fetch, xpad enumeration all
clean, byte-identical in shape to before. Interrupt-split itself is
still not completing, but the failure signature genuinely changed: every
prior version got ACK on start-split, then NYET forever on complete-split
across many retries. This version gets ACK on start-split, then an
*immediate NAK* on the very first complete-split (at start_mf+2), 100%
of ~1500+ polls, zero variance even while actively pressing buttons on
the controller (also: no power-on self-test buzz from the pad itself,
same as every previous session — still points at a power-delivery
question independent of this bug). An immediate, invariant NAK this
early is hard to explain as "hub has nothing to relay yet" — it looks
more like the hub isn't treating our complete-split as continuing a
pending transaction at all, which could mean the microframe-timing
constants (skip-6, +2, ODDFRM polarity) don't transfer 1:1 from a
Raspberry Pi's dwhci integration to this SoC's, or that something
upstream of the scheduler itself (FIFO/channel state between the
start-split's ACK and the complete-split's issue) isn't matching what
real hardware expects. Not root-caused further this session — same
conclusion as every previous round: resolving this needs to see the
actual wire-level SSPLIT/CSPLIT exchange, not more source comparison.
`USBD_VERBOSE` back to `false`. Paused, not abandoned.

---

## 2026-08-23 (continued) — Interrupt-split: four real reference drivers' retry logic tried, all fail; investigation paused

After the hub multi-TT fix (previous entry) also didn't resolve the
interrupt-split bug, went looking for real reference implementations
of the actual SSPLIT/CSPLIT retry logic itself, not just register
field names — the thing this project had been guessing at rather than
sourcing directly for most of its history. Found and faithfully
replicated the real, working logic of **four independent DWC2 host
driver implementations**, each tested on real hardware:

1. **Mainline Linux**, re-read in full (`dwc2_hc_nyet_intr()`,
   `drivers/usb/dwc2/hcd_intr.c`): `qtd->complete_split` only resets
   to 0 if `past_end` (the scheduling window was genuinely missed) —
   otherwise the SAME complete-split is retried within that window.
   This corrects an earlier misreading this project had held since
   the previous session: periodic endpoints do *not* always get a
   fresh start-split on NYET.
2. **U-Boot's own `chunk_msg()`** (`drivers/usb/host/dwc2.c`): treats
   every endpoint type identically — full register re-arm each
   attempt, retry the same complete-split for up to 4 elapsed frames.
   No eptype branching at all. This is what the driver now keeps.
3. **TinyUSB's `hcd_dwc2.c`** (github.com/hathach/tinyusb) — a real,
   shipping embedded stack, not a heavy OS abstraction: retries the
   same complete-split up to 3 times on NYET, but touches only
   `HCSPLT.split_compl` and `HCCHAR.odd_frame`/`CHENA` via read-modify-
   write; `HCTSIZ`/`HCDMA` are programmed once, for the start-split,
   and never touched again. Materially different register-touch
   pattern from anything this driver had done before.
4. **Circle** (github.com/rsta2/circle, `lib/usb/dwhciframeschedper.cpp`)
   — a mature bare-metal stack for Raspberry Pi's own DWC2-family
   "dwhci" core, with a proven-working Xbox 360-behind-a-hub driver
   (`usbgamepadxbox360.cpp`) — busy-waits for a specific, computed
   target microframe before issuing the *start-split itself* (current
   microframe + 1, skipping microframe 6 entirely), not just before
   the complete-split.

**Real hardware result for all four**: (1)-(3), faithfully replicated,
all produced the exact same deterministic outcome as this driver's
own original logic — `ACK` on every start-split, `NYET` on every
complete-split, never once `XFERCOMP`, regardless of retry count or
register-touch pattern. (4) was genuinely different and informative:
adding Circle's own microframe-alignment delay before the start-split
shifted the hub's response from `NYET` to `NAK` — a real behavior
change, the *only* one all session — but `NAK` (semantically "the hub
no longer considers this split pending at all") is a worse outcome
than `NYET`, not a step toward success. Removing the extra gap before
the complete-split while keeping just the start-split alignment still
produced `NAK`, meaning the alignment delay itself, not the gap after
it, is what pushes the hub past whatever window it was tracking the
pending split in.

**Conclusion**: four independent, real, working implementations of
this exact protocol layer all fail identically or worse on this
specific hardware/hub/device combination when faithfully replicated.
That is about as strong a negative result as source-only investigation
can produce — this is very unlikely to be a driver logic bug at the
SSPLIT/CSPLIT retry-shape level, and is now more likely either a
genuine CV1800B-specific silicon quirk (plausible — this exact chip
already needed its own DMA-disable quirk entry in mainline, see the
Slave/PIO entry above) or something in this driver's own surrounding
register/bring-up state that no amount of retry-logic comparison can
surface. Resolving it further needs to see the actual wire-level
SSPLIT/CSPLIT exchange — a protocol or logic analyzer, still not
available.

**Kept**: U-Boot's unified retry logic (no eptype branching) as the
current implementation — the cleanest, most defensible state, matching
two of the four real references exactly. `USBD_VERBOSE` back to
`false`. Real hardware re-confirmed after cleanup: enumeration and
xpad detection through the hub both still work exactly as before.
Interrupt-split transfers remain paused — genuinely paused this time,
not just deferred; further progress needs different tooling, not more
source comparison.

---

## 2026-08-23 (continued) — Hub multi-TT mode: a real, correct fix, but not the interrupt-split bug either

One more real lead chased down on the still-paused interrupt-split
bug, after reverting the Slave/PIO detour (previous entry) back to
the known-good DMA-mode baseline.

**The gap**: real mainline Linux's `hub_configure()`
(`drivers/usb/core/hub.c`) checks a Hi-Speed hub's own
`bDeviceProtocol` (device descriptor byte 6): if it's `2`
(`USB_HUB_PR_HS_MULTI_TT`, one Transaction Translator per port), Linux
explicitly sends `SET_INTERFACE(hub, altsetting=1)` to switch it out
of its default shared-TT behavior. This driver never checked that
byte or sent that request at all — a real, previously-unexamined gap,
not a guess (confirmed by reading `hub_configure()` directly, not
assumed).

**Implemented**: `usb_set_interface()` (`dwc2.c3`, standard
SET_INTERFACE control request) and a check in `usbd.c3`'s root-hub
enumeration — read `bDeviceProtocol`, and if it's multi-TT-capable,
send the switch.

**Result on real hardware**: the IO board's hub genuinely does report
`bDeviceProtocol=2`, and the `SET_INTERFACE` genuinely succeeds
("hub switched to multi-TT (one TT per port)") — a real, verified fix,
kept regardless of the outcome below since it's correct per spec. But
the interrupt-split symptom is completely unchanged: still "gave up
after 1 fresh start-split attempt" on every single poll, byte-identical
to every previous round.

**Where the investigation stands now**: this closes out the last
well-grounded, source-derived hypothesis available without deeper
tooling. Ruled out across this and the previous sessions, all with
real hardware evidence: microframe start-split/complete-split timing
and gap, complete-split retry budget and shape, `HCCHAR.ODDFRM`,
`xfer_len` clamping to `max_packet` for split IN, the DMA-vs-Slave/PIO
transfer mechanism itself, and now hub TT mode. What's left almost
certainly requires seeing the actual wire-level SSPLIT/CSPLIT exchange
between the host, hub, and device — a protocol or logic analyzer, not
available this session. Paused here, not abandoned; revisit if that
tooling becomes available, or if a genuinely new hypothesis turns up
from a source this project hasn't already read carefully.

---

## 2026-08-23 (continued) — Slave/PIO mode rewrite attempted and reverted; interrupt-split investigation still paused

Continuation of the same day's USB work. Real lead followed all the
way through to a dead end — reverted cleanly back to the known-good
DMA-mode baseline, no net change to `dwc2.c3`'s transfer mechanics
versus commit `275dfc0`.

**The lead**: mainline Linux's own `drivers/usb/dwc2/params.c` has an
explicit parameter table for this exact chip —
`dwc2_set_cv1800_params()`, matched via the `"sophgo,cv1800b-usb"`
devicetree compatible string — and it sets `p->host_dma = false`.
Real, current mainline deliberately disables DMA mode for this SoC
and runs Slave/PIO mode instead (manual FIFO push/pop) — a genuine,
sourced fact, not a guess. Given the interrupt-split bug's own
signature (short/infrequent DMA transfers fine, sustained/periodic
ones never once completing across an exhaustive, source-verified
round of fixes — see the previous entry) matched the shape of a real
DMA-engine defect, rewriting the transfer mechanism to match mainline's
own choice for this chip was a reasonable, well-motivated thing to try.

**What the rewrite involved**: `usbd_init()` stopped setting
`GAHBCFG.DMAEN`; `hc_transfer_once()`/`hc_transfer_once_split()` no
longer touched `HCDMA` at all, instead pushing OUT data into the TX
FIFO by hand (polling `GNPTXSTS`/`HPTXSTS` for space) and draining IN
data from the shared RX FIFO by polling `GINTSTS.RXFLVL` + popping
`GRXSTSP`, through the same `usb_dma_paddr` scratch buffer every
caller already used. Needed a second MMIO page mapped
(`board::USB_MMIO_FIFO_PAGE`, `+0x1000` — the host-channel FIFO port
was a whole page past everything this driver used to touch).

**Real bugs found and fixed along the way** (useful groundwork if this
gets revisited):
- DWC2 Slave mode does not auto-halt a channel the way DMA mode does —
  confirmed against mainline's own `dwc2_hc_halt()`. This part of the
  port was straightforward and correct.
- `HCCHAR.CHENA` self-clears faster than a polling loop (as opposed to
  a real interrupt handler) can react to `XFERCOMP` — re-asserting it
  to request a halt at that point just re-arms an already-idle
  channel. `CHHLTD` turned out not to be a usable completion signal at
  polling granularity at all; every real caller only ever checks
  specific `HCINT` bits anyway (`XFERCOMP`/`NAK`/`STALL`/...), so the
  fix was to stop waiting for `CHHLTD` entirely.
- Bare `ACK` (`HCINT` bit 5) can be observed on its own, one polling
  iteration before `XFERCOMP`/the real RX data actually lands — a
  real, narrow ordering gap between the wire-level ACK handshake and
  the core finishing packet validation. Only a split start-split
  legitimately completes on bare ACK alone; every other transfer needs
  to keep polling past it.
- `HCTSIZ`'s post-transfer remaining-count field doesn't reliably
  track what Slave mode actually moved — the driver's own real
  pushed/popped byte counts are a better source of truth than
  rederiving it from that field.

**Where it stopped**: after all of the above, a real 8-byte
`GET_DESCRIPTOR` response popped 2 words from the RX FIFO — the first
word was byte-exact correct (`bLength`/`bDescriptorType`/`bcdUSB`
verified against the real values), but the second word exactly
matched the value of the *next*, still-unread `GRXSTSP` status-queue
entry, every single time, 100% reproducible. Tested and ruled out:

- A memory-ordering hazard (`asm("fence")` between the two FIFO
  reads) — zero effect.
- A real physical timing gap between consecutive reads (a 2µs busy-spin
  delay between them, reasoned from mainline's own `dwc2_rx_fifo_level_intr()`
  only ever running from inside a genuine hardware interrupt, with
  real IRQ-dispatch latency this driver's tight polling loop doesn't
  have) — also zero effect, byte-identical output either way.

Both being ruled out, byte-identical regardless of timing, means this
is deterministic — not a race. A careful re-read of mainline's actual
call chain (`dwc2_rx_fifo_level_intr`, `dwc2_read_packet`,
`dwc2_hc_intr`'s dispatch order, `dwc2_get_actual_xfer_length`)
confirmed this driver's own implementation is a faithful, line-for-line
port of what mainline actually does — there was no difference in
*approach* left to find by reading more of that source. Whatever's
wrong is either a genuine CV1800B-specific FIFO erratum invisible to
generic mainline source (plausible, given this exact chip already
needed its own quirk table entry just to disable DMA) or something
about this driver's own surrounding register state not yet
cross-checked — resolving either would need the vendor's own register
errata (not available) or a real protocol/logic analyzer (the same
tooling gap the original interrupt-split investigation hit).

**Reverted**: `boards/duo/board.c3`, `boards/qemu/board.c3`,
`src/process.c3` back to `HEAD` in full (pure Slave/PIO artifacts).
`user/usb/dwc2.c3` rebuilt from `HEAD` with only the (unrelated) USB
Mass Storage prep changes reapplied on top — confirmed via `git diff
--stat` showing pure insertions, zero deletions, versus `275dfc0`.
Real hardware re-tested after reverting: enumeration through the hub
and xpad detection both work exactly as before this detour started.
Interrupt-split transfers remain paused, exactly where the previous
entry left them — this whole detour neither fixed nor further
diagnosed that original bug, since it never got past re-establishing
basic control-transfer reliability under Slave mode. If revisited
again, start from real tooling (protocol/logic analyzer) rather than
more source-comparison guessing — this session's experience is real
evidence that avenue is exhausted for now.

---

## 2026-08-23 (continued) — Interrupt-split investigation paused; USB Phase 4 prep: Mass Storage Bulk-Only Transport

Continuation of the same day's USB Phase 3 session (previous entry
below). Two parts: closing out the interrupt-transfer investigation
for now, and starting fresh on a different USB target that doesn't
share its root cause.

**Interrupt-split investigation — paused, not resolved:**

- Found and fixed a real bug on a fresh re-read of
  `hc_transfer_once_split` (`dwc2.c3`): `HCCHAR.ODDFRM` was computed
  once, before the start-split, then reused unchanged for the
  complete-split. Real Linux (`dwc2_hc_set_even_odd_frame`)
  recomputes it separately per sub-transaction, since frame parity
  flips every 1ms and real wall-clock time passes between SSPLIT and
  CSPLIT. Fixed by adding a separately-computed `csplit_oddfrm`. Did
  **not** resolve the underlying bug — CSPLIT still comes back
  NYET/NAK forever for the pad's interrupt endpoint.
- Attached the same controller directly to the host laptop and used
  `usbmon` to capture real, known-good USB traffic for comparison —
  confirmed the working case is xHCI (hardware handles the hub
  TT/relay invisibly), which is architecturally why it can't show
  DWC2's own SSPLIT/CSPLIT detail. Tried `dynamic_debug` for
  kernel-side DWC2 tracing on the Duo itself — no compiled-in
  `pr_debug` calls in the relevant path, dead end.
- **Hazard found and documented**: reading
  `/sys/kernel/debug/usb/4340000.usb/regdump` concurrently with a live
  USB transfer hung the entire Linux system on the Duo (recovered
  clean via power cycle, no data loss). Never race `regdump` against
  a live transfer again.
- Chased a power-delivery hypothesis (real pad does a firmware
  self-test buzz on power-up under Linux, never once under this
  driver) — bumped `bPwrOn2PwrGood` floor from 20ms to 200ms and added
  a 200ms post-reset settle as a real-data probe (`dwc2.c3`,
  `usbd.c3`, both still in the tree, harmless to keep). Inconclusive:
  the "no vibration" comparison wasn't actually a controlled test, so
  this shouldn't be read as ruling the hypothesis in or out.
- Formally paused, not abandoned: no protocol analyzer or logic
  analyzer available to see the actual wire-level SSPLIT/CSPLIT
  exchange, which is what's needed to make further progress. Revisit
  if the tooling situation changes or the user raises it again.
  `USBD_VERBOSE` flipped back to `false`.

**USB Phase 4 prep — Mass Storage (Bulk-Only Transport), build-verified only:**

Chosen specifically because bulk transfers don't carry interrupt
transfers' periodic-scheduling complexity (ODDFRM, MULTICNT,
per-microframe NYET handling) — the existing split-transaction
infrastructure proven working for control transfers (chunking, PID
toggle tracking) should be directly reusable without hitting the same
wall.

- `user/usb/dwc2.c3`: new generic `usb_bulk_transfer()` — same
  split-aware chunking/PID-toggle shape as `usb_control_transfer()`'s
  own DATA stage, but standalone (no SETUP/STATUS) and with a
  persistent toggle across calls, same contract as
  `usb_interrupt_poll()`. Added `USB_HCCHAR_EPTYPE_BULK`,
  `USB_EP_XFERTYPE_BULK`, `USB_CLASS_MASS_STORAGE`,
  `USB_MSC_SUBCLASS_SCSI`, `USB_MSC_PROTOCOL_BULK_ONLY` constants.
- `user/usb/msc.c3` (new): CBW/CSW builders (BOT spec) and SCSI
  command builders for TEST UNIT READY, INQUIRY, READ CAPACITY(10),
  READ(10) — cross-checked the wire format against a real `usbmon`
  capture of a live card reader's CBW/CSW exchange from the interrupt
  investigation above. `usb_enumerate_msc_device()` is a one-shot
  proof-of-transport probe (not a persistent read loop, not a block
  device driver yet): TEST UNIT READY → INQUIRY (prints vendor/product
  strings) → READ CAPACITY(10) (prints block count/size) → READ(10) of
  LBA 0 (prints first 16 bytes). No WRITE support yet — deliberately
  deferred until read-only access is confirmed working on real
  hardware.
- `user/usb/usbd.c3`: generalized `usb_enumerate_hub_port_device()`'s
  device recognition from a hard XPAD-vendor-ID gate to real class
  dispatch — fetches the config descriptor once, then tries
  `usb_find_interface()` against XPAD's class/subclass/protocol first,
  then MSC's (0x08/0x06/0x50), same pattern a real USB-core stack
  uses.
- `scripts/build_user.sh` updated to include `msc.c3` in the `usbd`
  build line.
- Both `scripts/build.sh` (QEMU) and `scripts/build_duo.sh` (real Duo)
  compile clean. **Not yet tested on real hardware** — no USB mass
  storage device tried against it this session; deferred to a future
  session per explicit request ("make some preparation for usb mass
  storage, then we can test it later").

---

## 2026-08-23 — USB Phase 3: xpad driver, hub-downstream enumeration, real split transactions — control works, interrupt transfers still don't

Long session, mixed outcome. Real, working progress landed; the
original goal (an Xbox 360 wired pad's buttons/sticks working end to
end) did not.

**What actually works, confirmed on real hardware:**

- `user/usb/xpad.c3` — Xbox 360 wired pad report parsing (vendor-
  specific XInput protocol, sourced from duo-buildroot-sdk's real
  Linux `xpad.c` driver, not guessed). `test/xpad_parse_test.c3`
  (`scripts/test_xpad.sh`) is a real host-native unit test using c3c's
  built-in `@test` framework — verified it actually catches bugs by
  deliberately breaking the Y-axis bitwise-NOT and watching it fail on
  the right field.
- Hub-downstream device enumeration (`usb_enumerate_hub_port_device`,
  `usbd.c3`) — the missing piece Phase 2 never did (port reset,
  SET_ADDRESS, full descriptor walk) — works.
- Real USB 2.0 split transactions (`hc_transfer_once_split`,
  `g_split_active`, `dwc2.c3`) for **control** transfers — full
  enumeration of the pad behind the IO board's real Hi-Speed hub
  (device descriptor, multi-packet 139-byte config descriptor via a
  per-packet SSPLIT/CSPLIT chunking loop with correct DATA0/DATA1
  toggle tracking, `SET_CONFIGURATION`) succeeds every time. This
  replaces an earlier `HCFG.FSLSSUPP` workaround (forcing the whole
  host to Full-Speed-only to sidestep needing splits at all) once that
  workaround turned out to only fix control transfers, not interrupt.
- `scripts/provision_duo_sd.sh` — recreates the `DUOBOOT`/`EXT2TEST`
  partition layout from scratch (sourced from `board.c3`'s own
  `FS_PARTITION_START_SECTOR`). Needed after the real-Linux-comparison
  detour below required repeatedly overwriting the SD card's partition
  table with the vendor's own official image and back.

**What doesn't work: interrupt-type (periodic) transfers to that same
endpoint, via the same split-transaction machinery, never once
complete on real hardware** — `HCINT` shows a clean ACK on every
start-split, but every complete-split comes back NYET (or, in one
configuration, NAK) forever. Confirmed NOT the explanation, each with
real hardware evidence, not just reasoning:

- `HCCHAR.ODDFRM` frame parity — implemented, matches U-Boot's
  `!(hfnum & 1)` formula exactly.
- `bInterval`-based poll pacing (`usb_ep_desc_interval()` was defined
  but never called before this session).
- `GRXFSIZ`/`GNPTXFSIZ`/`HPTXFSIZ` FIFO sizing — tried three times:
  first trusting reset-time register defaults (like real Linux's own
  `dwc2_config_fifos()` does — disproven, this core's reset-time
  values summed past its real 3072-word budget); then a naive even
  3-way split; then finally the *exact real values Linux itself uses*
  on this exact chip, read live from
  `/sys/kernel/debug/usb/4340000.usb/params` after booting the real
  vendor Linux 5.10 on this same board (`host_rx_fifo_size=530`,
  `host_nperio_tx_fifo_size=256`, `host_perio_tx_fifo_size=768`). None
  of the three changed the failure signature at all.
- `GDFIFOCFG.EPINFOBASE` ("dedicated/multiple Tx FIFO" mode,
  confirmed active: `en_multiple_tx_fifo=1` in that same real params
  dump) — implemented, including the corrected real-value EPINFOBASE.
- `GAHBCFG.GLBL_INTR_EN` — Linux sets this unconditionally even though
  neither driver actually uses real CPU interrupts (both poll).
- HCTSIZ.PID toggle tracking across complete-split retries (U-Boot's
  `wait_for_chhltd()` re-reads and reuses it every sub-attempt; an
  earlier version of this function didn't).
- NAK-vs-NYET retry semantics for periodic splits, matched exactly to
  real Linux's own `dwc2_hc_nyet_intr()` (`hcd_intr.c`): periodic types
  don't retry a stale complete-split at all, unlike control/bulk —
  implemented, no change.
- Retry timing/shape in general — tried single-attempt-per-poll,
  100-frame same-split retry, and 160-fresh-start-split-per-poll (the
  last of which got **zero** completions across ~20 genuinely
  independent frames, and correlated with the host controller wedging
  entirely afterward — `hc_transfer_once` timing out with `HCINT=0`
  even on plain control transfers. Reverted immediately; this is
  filed as a real, if not fully understood, hazard of hammering this
  core's complete-split path too hard.)

**Real Linux, on this exact board/hub/pad, does not have this
problem** — booted the vendor's stock `milkv-duo-sd-v1.1.4.img`
(`official-image/` in the SDK checkout) three separate times this
session (each requiring a full SD card partition-table round-trip via
the new `provision_duo_sd.sh` to get back to `racccoon` afterward) and
drove it entirely over the serial console via `screen`'s
`readreg`/`paste`/`hardcopy` (no keyboard access needed — a real,
reusable technique for unattended real-hardware testing going
forward). A raw `usbfs` interrupt-transfer probe (`USBDEVFS_BULK`
ioctl, bypassing `xpad`/`usbhid` entirely — this vendor image doesn't
even have those compiled in) against the pad's interrupt endpoint got
50/50 successes, immediately, every time. That's the strongest
evidence available that this is a real, fixable driver gap, not a
hardware/board quirk — but attempts to get *why* out of the real
kernel came up empty: no `ftrace`/`kprobes` in this kernel build, no
per-transfer `dev_dbg`/`dwc2_sch_dbg` tracing compiled in (only
error-path prints exist in `dynamic_debug`'s control file), and its
`regdump` debugfs tool appears to **hang the whole system** if read
concurrently with a live transfer (recovered clean via power-cycle,
no lasting harm — but noted here as a real hazard, not something to
retry carelessly). A safe, standalone `regdump` read afterward showed
only the hub's own always-full-speed background status-endpoint
polling (`devaddr=2`, matching the hub not the pad), not anything
about the pad's own split transfer.

**Where this leaves things:** the interrupt-transfer gap is real,
unresolved, and — importantly — not evidence this is unfixable. Every
symptom (clean start-split ACKs, precise real NYET/NAK responses,
control transfers working perfectly on the identical wire path)
points at a real, working protocol mechanism missing one detail, not
a fundamentally broken approach. Likely next steps if this gets picked
back up: a real USB protocol analyzer between the hub and the pad
(the one kind of ground truth nothing software-side could substitute
for today), or comparison against a second, different real hub.

`USBD_VERBOSE` back to `false`; the `hc_transfer_once_split`/
`usb_interrupt_poll` diagnostic prints from this investigation are
still there, just quiet by default — flip it back on to pick this up
again.

## 2026-08-22 (74) — Quiet ethd's bring-up-era diagnostics: `ETHD_VERBOSE`

Small follow-up to entry 72's real-hardware debugging round (the
missing DMA page mapping, MII_PORTSELECT, write-ordering bugs): the
diagnostic prints added to chase those bugs (TX descriptor/DMA_STATUS
dumps, auto-negotiation detail) never got quieted back down once the
underlying issues were actually found and fixed. Noticed because the
shell's own `"> "` prompt — printed once, early in boot, with no
trailing newline (`user/shell.c3`) — got easy to miss glued onto the
front of an early `ethd:` diagnostic line, now that there's simply a
lot more real console output than there used to be.

Added `ETHD_VERBOSE` (`user/net/ethd.c3`, default off), same
established convention as `USBD_VERBOSE`/`SDD_VERBOSE`: gates the
self-test's own diagnostic-only prints and the auto-negotiation detail
dump; meaningful, non-repeating status (link up/down, self-test pass/
fail, DHCP bound) stays visible regardless. Pure print-gating, no
logic changes — QEMU regression clean (ethd itself is Duo-only, never
exercised in QEMU); real-hardware confirmation deferred, SD card
reader disconnected again mid-session (a known recurring flaky-
connection issue, not a code problem).

## 2026-08-22 (73) — Minimal DHCP client: real ping to the Duo confirmed working end to end

Direct follow-on to entry 72's real-hardware finding: a `tcpdump`
capture proved the Duo's own ARP requests reach the wire perfectly
formed, but the user's router silently never replied to them — the
classic signature of IP-MAC-binding/ARP-defense dropping traffic from
a device using a static IP it never itself assigned. A real DHCP
client sidesteps this class of problem entirely, on top of being
generally more useful than a hand-picked address.

Scope, deliberately narrow (same phased approach every earlier feature
here used): DHCPDISCOVER → DHCPOFFER → DHCPREQUEST → DHCPACK, once at
startup, no lease renewal, no DHCPRELEASE/DECLINE, no RFC-5227 ARP
probe of the offered address before use. Falls back to the existing
static IP on failure/timeout (3 DISCOVER attempts, 2s each) — zero
regression for a network without a DHCP server.

New `user/net/dhcp.c3`: DHCP message build/parse (RFC 2131),
transport-agnostic — same shape as `user/net/eth_proto.c3` itself,
which gained the generic UDP support this needed (`build_udp_header`/
`udp_checksum`, plus a refactor of the existing `ip_checksum` into a
`checksum_partial_sum`/`checksum_finalize` split so the UDP checksum
can sum a synthetic 12-byte pseudo-header and the real segment as two
separate spans without a physical concatenation copy). `ethd.c3`/
`netd.c3` each get their own DHCP client loop (same duplication
pattern the self-test itself already established — no callback/
dependency-injection mechanism is idiomatic to this codebase, so each
backend's own orchestration calls into the shared build/parse
functions directly), inserted before the existing self-test, which
now runs against whatever `our_ip`/`gateway_ip` DHCP resolved (or the
static fallback).

**Verified end to end, not just "it compiles":**
- QEMU: real interop with SLIRP's own embedded DHCP server on the
  first attempt — `netd: DHCP: bound, ip=10.0.2.15 gateway=10.0.2.2`,
  then the self-test passing against those dynamic values.
- Real Duo hardware: `ethd: DHCP: bound, ip=192.168.1.5
  gateway=192.168.1.1` — a real lease from the user's own router,
  confirming the whole point of this feature (the router that
  silently ignored the static IP now hands out a real, recognized
  address). The self-test's own ARP-resolve-then-ping now succeeds
  too, for the same reason. And, closing the loop entirely: a genuine
  `ping 192.168.1.5` from another device on the same LAN got real
  replies — `64 bytes from 192.168.1.5: icmp_seq=1 ttl=64 time=927
  ms`. The Duo answers real pings from a real external device now.
  Round-trip times are high (several hundred ms) — expected, not a
  bug: the main loop's own poll interval is 500ms, busy-polled rather
  than interrupt-driven, same convention every device driver in this
  codebase already uses; nothing here is latency-tuned yet.

## 2026-08-22 (72) — Ethernet Phase 2: real packet TX/RX + ARP/ICMP, confirmed transmitting on real hardware

Direct follow-on to Ethernet Phase 1 (entries 67-71): link sensing
worked, but neither `ethd` (real Duo) nor `netd` (QEMU virtio-net)
ever moved an actual packet. This phase adds real bidirectional TX/RX
on both targets plus a minimal hand-rolled ARP + ICMP echo layer, so
an external device can ping the board — no DHCP, no TCP/UDP, no
routing, same narrow phased scoping every earlier phase used. Static
config: Duo `192.168.1.70/24` gateway `192.168.1.1` (no DHCP client
exists yet); QEMU `10.0.2.15/24` gateway `10.0.2.2` (SLIRP's own
default virtual subnet for `-netdev user`).

**New shared layer**: `user/net/eth_proto.c3` — transport-agnostic
ARP request/reply and ICMP echo request/reply, working on raw
Ethernet frame bytes only (no virtio/DMA knowledge), used by both
`netd.c3` and `ethd.c3`. Every multi-byte field goes through explicit
big-endian byte helpers, never a wide-integer cast through a `char*` —
this CPU is little-endian, the wire isn't.

**QEMU (`netd.c3`)**: populates the RX/TX virtqueues Phase 1 already
configured but never used — one RX buffer permanently posted and
re-armed after each frame, one TX buffer reused per send, completion
detected by directly polling `used.index` (no interrupt reliance, same
busy-polled convention every other driver here already uses).
`SYS_NETD_INFO` widened (2 out-params to 3) for the new packet-buffer
page.

**Real Duo (`dwmac.c3` + `ethd.c3`)**: a genuine DW MAC DMA descriptor
ring, sourced from `duo-buildroot-sdk`'s own
`u-boot-2021.10/drivers/net/designware.c/.h` — deliberately simplified
to one self-chained TX descriptor and one self-chained RX descriptor
(a valid degenerate one-entry ring) rather than the real driver's
16-entry chain, matching this codebase's own one-outstanding-transfer
discipline everywhere else (USB's single host channel, diskd/sdd's one
request at a time). New syscall `SYS_ETHD_INFO` hands back a single
uncached (`map_device_page`) DMA region — same real-DMA-cache-
incoherency fix USB Phase 2 already established, this being only the
second driver (after usbd) doing genuine DMA against real hardware.

**Real hardware bring-up, several real bugs found in order**:
1. A genuine store page fault at `0x04071000` — `setup_ethd_mappings`
   only ever mapped `ETH_MMIO_BASE` (the MAC's own registers), never
   the DMA register block at `+0x1000`, a completely separate page.
   New `board::ETH_DMA_PAGE` constant, mapped alongside.
2. The self-test's own ARP request went out before the link had
   actually come up — auto-negotiation (just restarted a few steps
   earlier) needs real time, and the self-test used to run
   immediately after DMA init with no wait at all. Fixed with a
   bounded (5s) wait-for-link-up before attempting it.
3. `MII_PORTSELECT` (MAC_CONF bit 15) was never touched — the real
   driver's own comment is explicit: "When a MII PHY is used, we must
   set the PS bit for the DMA reset to succeed" (the converse holds
   for RMII, this board's own real interface). Left at whatever it
   powered up as, this can silently break the whole datapath under an
   otherwise-correct-looking register sequence. Now explicitly cleared
   right before the DMA soft reset, matching the real driver exactly.
4. RX/TX enable (`MAC_CONF |= RXENABLE|TXENABLE`) was happening
   *before* `eth_dma_init()`, backwards from the real driver's own
   ordering (`designware_eth_init()`, then a separate, later
   `designware_eth_enable()`). Reordered.
5. `FLUSHTXFIFO|STOREFORWARD` and `RXSTART|TXSTART` were combined into
   one `DMA_CONTROL` write; the real driver does two genuinely separate
   writes. Split, even though both reach the same final register value
   — the flush needs a little real wall-clock time to at least begin
   settling before TXSTART is asserted, which a single combined write
   gives it none of.
6. The MAC address was being written *before* `eth_dma_init()`'s own
   DMA soft reset — but "Soft reset above clears HW address
   registers. So we have to set it here once again," per the real
   driver's own comment; the DMA block's reset genuinely does clear
   the MAC's own ADDR0HI/LO filter registers on this IP. Moved to
   after.

**Verified**: QEMU's own startup self-test (ARP + ping to the SLIRP
gateway) passes cleanly — `ARP resolve of gateway ok`, `ping to
gateway ok` — full round trip, checksums included, confirming the
whole mechanism (frame building, virtqueue TX/RX, checksum
computation, ARP/ICMP parsing) is correct. On real Duo hardware, the
self-test's own ARP-to-gateway still times out, but a live `tcpdump`
capture on another machine on the same LAN caught the real frame:
`02:00:00:00:00:01 > ff:ff:ff:ff:ff:ff, ARP, Request who-has
192.168.1.1 tell 192.168.1.70` — well-formed, reaching the wire.
The router itself never replies to it (visibly alive and doing ARP
fine with other devices moments later), the classic signature of a
consumer router's IP-MAC-binding/ARP-defense feature silently
dropping traffic from a device using a static IP it never DHCP-
assigned — a router-configuration question, not a driver bug. Real
end-to-end validation (a genuine ping from another device on the same
LAN, which doesn't need the router's own IP stack at all — same
subnet, pure L2) is still pending the user's own follow-up test.

## 2026-08-22 (71) — Directory refactor step 5 (last one): `sdd.c3` split into `sdhci.c3`/`sdd.c3`

Final step of the refactor plan started in entry 68. `sdd.c3` (894
lines) mixed the standard SDHCI register/PIO layer (pad/power/clock
bring-up, SD command issuing, block PIO transfer — genuinely spec-
level, not Duo-specific except for the base addresses and the vendor
pad/PHY registers) with the driver's own orchestration (`main()`'s IPC
request loop). Split, same shape as the `usbd.c3`/`ethd.c3` splits
before it:

- `user/block/sdhci.c3`: every `SD_*` SDHCI register/bit constant,
  `mmio_read32`/`write32`, `sd_reg_read`/`write` and friends
  (`top_reg_*`/`pinmux_reg_*`/`clock_reg_*`), `sdd_pad_power_clock_init()`,
  `sd_send_cmd()`, `sdd_raise_clock()`, `sdd_enumerate()`,
  `sdd_block_rw()`. Also `SDD_VERBOSE` and `print_hex32` — moved here
  rather than staying in `sdd.c3`, matching the precedent the `usbd.c3`
  split already set (`USBD_VERBOSE` lives in `dwc2.c3`, not `usbd.c3`).
- `user/block/sdd.c3`: `main()`, `sdd_init()`, `sdd_panic()`, and the
  DISKD_READ/WRITE wire-protocol constants only.

Pure code motion, no logic changes. Real hardware verification: the
full `sdd` boot sequence (`clock_stable=1`, CMD0/CMD8/ACMD41/CMD2/
CMD3/CMD7 all succeeding, `raised clock`, `card ready`) came back
byte-identical to pre-split, and `fsd: ext2 mounted, block_size=4096
inode_table_block=67` already proves real block reads work end to end
through the new `sdhci.c3` (mounting requires reading the superblock/
inode table via `sdd_block_rw`) — `usbd`/`ethd` (same shared kernel
image) unaffected too.

This closes out the user-space directory refactor started in entry
68: `user/` is now `bin/`/`sys/`/`fs/`/`block/`/`net/`/`usb/`, every
driver that had grown large enough to blur "talks to the wire" vs.
"decides what to do next" (`usbd`, `ethd`, `sdd`) has been split
accordingly, and the shared `virtio.c3`/`main_stub.c3` pieces are
factored out where real duplication existed. No further steps planned
from that original plan.

## 2026-08-22 (70) — Directory refactor step 4: `ethd.c3` split into `dwmac.c3`/`ephy.c3`/`ethd.c3`

Continuation of entry 68's refactor plan. `ethd.c3` (673 lines) had
three genuinely distinct layers tangled into one file: generic DW
MAC/MDIO register access, this board's own Cvitek embedded-PHY analog
bring-up, and the orchestration deciding when to call either. Split
into three, same shape as the earlier `usbd.c3` → `dwc2.c3`/`usbd.c3`
split (entry 68):

- `user/net/dwmac.c3`: `ETH_MAC_*`/`ETH_MII_*`/standard IEEE 802.3
  `MII_*` constants, `mmio_read32`/`write32`, `mac_reg_read`/`write`,
  `mdio_read`/`write`/`wait_ready`, `eth_us_to_ticks`. The layer any
  other real DW-MAC board could reuse unchanged.
- `user/net/ephy.c3`: everything Cvitek-embedded-PHY-specific —
  `ETH_PHY_*`/`ETH_CLK_*`/`ETH_LED_*`/`ETH_SD1_*`/`ETH_EFUSE_*`
  constants, `phy_reg_read`/`write`/`clk_reg_*`/`led_pinmux_write`/
  `sd1_selphy_write`/`efuse0_read`/`efuse1_read`, `eth_phy_init()`,
  `eth_phy_led_pinmux()`, and the ~200-line `eth_phy_analog_init()`
  (the faithful `cv182xa_ephy_init()` translation).
- `user/net/ethd.c3`: `main()` and `ethd_init()`'s own sequencing
  only.

One real lesson from this split specifically (didn't come up in the
USB split, since `dwc2.c3` was the only register-level file there):
`dwmac.c3` and `ephy.c3` are both `module user;` — same module, no
import needed for cross-file visibility — which means a raw
`mmio_read32`/`write32` genuinely can't be duplicated in both files
the way `usb_us_to_ticks`-style helpers safely are duplicated across
*different* modules elsewhere in this codebase (e.g. `virtio.c3` vs.
`dwc2.c3` each having their own copy) — same-module duplicate function
*definitions* are a real compile error ("would shadow a previous
declaration"), not just untidy. Fixed by defining `mmio_read32`/
`write32` once in `dwmac.c3` and having `ephy.c3` call them directly,
same as `eth_us_to_ticks` already had to.

Pure code motion, no logic changes — verified byte-identical real-
hardware behavior before and after: full PHY bring-up sequence, MDIO
scan finding the PHY at address 0, BMCR fixup, and live link-up/
link-down sensing, plus `usbd`'s own hub enumeration (same shared
kernel image) unaffected.

Step 5 (`sdd.c3` → `sdhci.c3`/`sdd.c3`) is the last one in the
original refactor plan, still pending.

## 2026-08-22 (69) — Idiomatic argc/argv, following on from `main()` (entry 68)

Direct follow-up to entry 68's `@main_no_args` addition: the c3 spec's
own entry-point section also defines `fn void main(String[] args)` as
the idiomatic args-taking form (`MAIN_TYPE_ARGS` in the compiler's own
`sema_decls.c`), backed by a second forwarding macro, `@main_args`.

Every real stdlib version of that macro heap-allocates its `String[]`
(`mem::alloc_array`/`free`) — no allocator exists in this freestanding
build, so `lib/std/_nolibc/main_stub.c3` (8lall0/c3c fork) gets a
fixed-size static-array version instead (32 entries, matching the
convention the old `argv_storage` mechanism it replaces already used).

One real bug caught before it shipped, not just a mechanical
translation: the compiler's synthetic wrapper declares `argv` as a
genuine `char**` (the standard C-ABI type), but racccoon's own
`SYS_EXEC` doesn't actually hand off a real pointer array — `user.c3`'s
own `exec()` packs argv as a single NUL-separated blob ("foo\0bar\0"),
the only encoding that survives being copied as flat bytes into a
freshly exec'd process's address space. `@main_args` reinterprets the
`char**` as that blob's raw base address and walks it sequentially,
not `argv[i]`-indexes it — verified by first testing the naive
(wrong) `argv[i]` version in isolation, confirming it does NOT match
this project's own wire format on inspection, before it ever touched
a real racccoon file.

Converted every real consumer (`cat`/`ls`/`mv`/`mkdir`/`write`/`rm`/
`echod` — 7 files) from the old `char** argv; int argc = get_argv(&argv);`
pattern to plain `fn void main(String[] args)`. Two of them got
genuinely simpler in the process: `write.c3` and `echod.c3` both used
to hand-scan for a NUL terminator to get a string's length; `args[i].len`
replaces that outright. With every consumer converted, the old
`exec_argc`/`exec_argv_blob`/`argv_storage`/`get_argv()` machinery in
`user.c3` was genuinely dead — removed, and `start()` simplified
(`a0`/`a1` now pass straight through as `main()`'s real parameters,
instead of being stashed into globals first).

Verified end to end, not just "it compiles": a `write`→`cat` round
trip on real content, `ls` before/after `mv`/`rm`, and `argvtest`'s
own IPC-reply check — first scripted against QEMU (a real bug in the
test harness itself surfaced here too: `shell.c3`'s own input loop
only recognizes `\r` as line-end, not `\n` — a `\n`-only test harness
just accumulates characters silently forever instead of ever
dispatching a command), then the identical sequence on real Duo
hardware against ext2 (case-preserving, unlike FAT32 — `f.txt`/`g.txt`
stayed lowercase there, a nice independent confirmation the real
argv content survived intact).

## 2026-08-22 (68) — User-space directory refactor (steps 1-3), and an idiomatic `main()`

Two related pieces of housekeeping, both pure behavior-preserving
changes verified on real Duo hardware, not new features.

### Directory refactor: splitting drivers from orchestration

`user/` had grown to 17 files flat in one directory, and two drivers
in particular — `usbd.c3` (1209 lines) and (a later step) `ethd.c3`
(671 lines) — mixed hardware-register-level code with process-level
orchestration so thoroughly that finding "the part that talks to the
wire" versus "the part that decides what to do next" required reading
the whole file.

Rather than reach for C3's real `interface`+`@dynamic` support (C3
does have it — confirmed in the stdlib's own `logging.c3`/`alloc.c3`
— a struct declares `(InterfaceName)` and marks methods `@dynamic`),
this replicates `fsd.c3`'s own already-proven "generic core / backend
split": plain files in subdirectories, all still `module user;` (no
nested submodules, no import needed for same-module cross-file
visibility — just the directory as a human-navigation aid, matching
`user/fs/fat32.c3`/`ext2.c3`'s own precedent exactly). Introducing
dynamic dispatch would be designing for a hypothetical second USB/
Ethernet backend that doesn't exist yet; the seam is clean to
formalize into a real interface later if one ever does.

New layout: `user/bin/` (cat/ls/mkdir/mv/rm/write), `user/sys/`
(echod/procd/envd), `user/fs/` (fsd joins fat32/ext2), `user/block/`
(diskd/sdd), `user/net/` (netd/ethd), `user/usb/` (usbd). `user.c3`/
`shell.c3`/the new `virtio.c3` stay top-level.

New shared file `user/virtio.c3`: `diskd.c3` and `netd.c3` had already
near-verbatim duplicated the legacy virtio-mmio (version 1) transport
layer — magic/version/status/queue-setup register offsets, the
virtqueue struct shapes, raw MMIO read/write helpers — from `netd.c3`
being written by copying `diskd.c3`'s own pattern earlier this
session. Real, already-existing duplication, not speculative DRY.
Extracted the generic parts (base-address-parameterized
`virtio_reg_read32`/`write32`/etc.); each driver keeps its own
device-specific pieces (`VIRTIO_BLK_PADDR`/`Virtio_blk_req` for
diskd, `VIRTIO_NET_PADDR`/`VIRTIO_NET_F_STATUS` for netd).

`usbd.c3` split into `user/usb/dwc2.c3` (every `USB_*` register/bit
constant, the host-channel transfer engine, the USB/hub-class request
builders — the "how") and a much smaller `user/usb/usbd.c3` (just
`main()` and `usb_enumerate_device()` — the "what"). Pure code
motion, no logic changes.

Verified: QEMU regression clean at every step (all processes created,
`netd: link up`, FAT32 mounted). Since QEMU has no DWC2 equivalent at
all, `usbd` itself is only ever exercised on real hardware — flashed
the Duo and confirmed the exact same enumeration as before the split
(hub `vid=0x05e3 pid=0x0610`, 4 ports, correct per-port status).

Steps 4 (`ethd.c3` → `dwmac.c3`/`ephy.c3`/`ethd.c3`) and 5 (`sdd.c3`
→ `sdhci.c3`/`sdd.c3`) are planned but not yet done.

### An idiomatic `main()`, via a small addition to the c3c fork's stdlib

Every user-mode binary's `main()` was declared `fn void main()
@export("main")`, needed because `scripts/build_user.sh` compiles with
`--no-entry` (required since `--use-stdlib=no` means the compiler's
own standard main-wrapping has no forwarding macro to find). Under
`--no-entry`, the compiler registers whatever function is literally
named `main` without ever auto-exporting it under an unmangled linker
name the way it does in the normal (non-`--no-entry`) path — so every
single program needed the `@export("main")` boilerplate repeated by
hand, purely to satisfy `user.c3`'s own hand-written `_start`
(`call main`).

Traced this down to `sema_analyse_main_function()` in the compiler's
own `sema_decls.c` (8lall0/c3c fork) — genuinely fixable there, but a
compiler-internals patch felt like the wrong tool for what's really a
missing library piece: the real stdlib already solves this exact
problem for hosted builds via `std::core::main_stub`'s `@main_no_args`
macro (`lib/std/core/private/main_stub.c3`) — the compiler looks this
up *by name* when it sees a plain `fn void main()`, and generates a
real, standard, properly-exported `int main(int, char**)` wrapper
around it automatically. Racccoon's `--use-stdlib=no` build just never
had that macro anywhere reachable.

Added `lib/std/_nolibc/main_stub.c3` to the fork (sibling to the
existing `mem.c3`/`atomic.c3`/`fmt.c3`, same `@feat(RACCCOON)` gating)
providing a minimal freestanding `@main_no_args` — just `#m(); return
0;`, no args-forwarding machinery a freestanding target has no use
for. Removed `--no-entry` from `build_user.sh`, added the new file to
every binary's source list, and every `fn void main()` across all 16
racccoon files now just `import std::nolibc::main_stub;` and drops
`@export("main")` entirely — the compiler generates and exports the
real `main` symbol itself, confirmed via `nm` (`T main`, calling into
the mangled `user.main`), exactly like any standard hosted C3 program.

Verified: QEMU regression byte-for-byte identical to the pre-change
baseline. Real Duo hardware: full boot sequence clean across all 7
processes (sdd/fsd/procd/envd/shell/usbd/ethd), `usbd` enumeration
still exactly correct, and `ethd` showed `link up` this round —
possibly the first real external-carrier confirmation since the
`cv182xa_ephy_init()` fix (entry 67); worth an explicit `ip link`
check on the peer side to confirm.

## 2026-08-22 (67) — Ethernet Phase 1: MAC+PHY bring-up, real analog link sensing confirmed live

New feature area, mirroring USB's own Phase 1 scope: bring the MAC and
its PHY up, confirm link status, no packet TX/RX yet. Two targets,
mutually exclusive like diskd/sdd: `user/netd.c3` (QEMU, virtio-net on
the same virtio-mmio bus virtio-blk already uses) and `user/ethd.c3`
(Duo, the real on-chip Ethernet MAC — a genuinely standard, widely-
documented Synopsys DesignWare/"stmmac" core wrapped by the vendor's
own `cvitek,ethernet` devicetree compatible string, confirmed via the
real devicetree's own `snps,*`/`clock-names="stmmaceth"` properties,
not proprietary despite the vendor string).

### netd (QEMU) — worked first try

Legacy virtio-mmio (version 1), same register layout `diskd.c3`
already established. Real feature negotiation this time (unlike
diskd's own simplified skip-it-entirely approach): reads
`HostFeatures`, negotiates `VIRTIO_NET_F_STATUS` specifically, since
the device-config `status` field is only meaningful once that bit is
actually accepted. Configures both RX and TX virtqueues (virtio-net's
own spec requires both before `DRIVER_OK`, even though Phase 1 doesn't
push anything through them yet). First real hardware round: correct
MAC (`52:54:00:12:34:56`, QEMU's own well-known default), feature
negotiated, link up — no debugging needed at all.

### ethd (Duo) — a long chase, resolved

The MAC itself (register offsets/DMA descriptor format from U-Boot's
own `drivers/net/designware.c/.h`) needed no debugging — Phase 1 never
touches its DMA engine at all (MDIO is plain register access through
`miiaddr`/`miidata`, independent of the datapath). The embedded PHY
was the real chase: U-Boot's own `board_init()` calls
`cv180x_ephy_id_init()` unconditionally on real ASIC hardware
(previously read during USB Phase 1 research and dismissed as
irrelevant then), and this driver initially replicated exactly that —
clock enables (`REG_CLK_EN_0` bits 25/26, same clock-controller page
USB already maps), the exact register sequence, byte-for-byte.

Result: PLL genuinely locked, `BMCR` read back completely healthy
(auto-negotiation enabled, no power-down, no isolate), MDIO fully
functional, MAC address/RX/TX configured — and **zero link ever
detected by three independent peer devices** (two separate ports on
the user's own machine, plus a router) across many real-hardware
rounds. Ruled out, in order: cable (swapped), port (swapped), Linux-
side config (`enp2s0` already administratively up — `NO-CARRIER` is a
passive hardware report, nothing to "activate"), `BMCR` power-down/
isolate (already clear), PLL lock (read back directly, genuinely
locked). Every register-level fact available from `cv180x_ephy_id_init()`
checked out healthy; the symptom pattern (working digital control
plane, zero real analog output) pointed toward something the partial
sequence never covered at all.

**Root cause**: `cv180x_ephy_id_init()` was only ever a *subset* of
this exact PHY's real bring-up. U-Boot ships a genuinely separate,
dedicated PHY driver, `drivers/net/phy/cvitek.c`
(`cv182xa_ephy_init()`, called from the real PHY framework's own
`.config` callback) — found only by finally reading a file that had
shown up in an initial directory listing early in this session's own
Ethernet research but was never actually opened. Its own source
comments mark the parts overlapping `cv180x_ephy_id_init()` as
`/* do this in board.c */` and skip them — confirming the two were
always meant to run together, board.c first. Everything else in that
file had never been touched by this driver at all: efuse-based analog
trim (TX bias current, echo cancellation, TX/RX termination), MLT-3
line-coding phase tables (the actual 100BASE-TX signal encoding),
**link-pulse waveform shape** (the literal analog signal a peer PHY
recognizes as "something is connected" — the leading hypothesis for
the whole symptom), TP_IDLE and 10BaseT tables, LPF/HPF filter
coefficients (CV180X/"phobos" branch specifically — the source also
has a separate CV181X branch this board doesn't need), and two
registers never written before at all: a genuine "start auto-
negotiation" trigger (`0x03009800=0x090e`, distinct from board.c's own
`0x0906`) and a force-full-duplex bit. Replicated faithfully as
`eth_phy_analog_init()` — including a real redundant re-run of the
ANA_PD/ANA_EN release the source itself repeats, not "cleaned up" away
even though it looks unnecessary on paper, since matching the proven
flow exactly mattered more here than tidiness.

**Result**: genuine, live, physically-responsive link sensing —
confirmed by unplugging the cable mid-run and watching `ethd` print
`link down`, then `link up` again on replugging. Not a stuck false
positive; real analog activity. **Still open**: no peer device has yet
confirmed carrier from the Duo's side (the user's own laptop still
shows `NO-CARRIER` on both cable and port swaps) — a router test,
which may be more tolerant of whatever's still not fully spec-
compliant about the generated signal, is planned but not yet run.
Genuine, meaningful progress either way: from "completely inert,
unclear why" to "sourced from the real, complete vendor PHY driver,
demonstrably responding to real physical state" — worth committing
even with the peer-link question still open, rather than sitting on
uncommitted work indefinitely.

### Verification

QEMU: `netd` correct end to end, shell/diskd/fsd unaffected. Duo:
`ethd`'s own diagnostics all confirm healthy state (PLL locked, BMCR
clean, clocks enabled with readback verification, MAC address set),
live link-up/link-down transitions confirmed via physical unplug/
replug. `usbd` (Phase 1+2) continues working unaffected alongside it —
confirmed hub port detection still correct in the same boot.

**Files changed:** `src/entry.c3` (`SYS_NETD_INFO`), `src/process.c3`
(`ethd_pid`/`netd_pid`/`netd_rxq_paddr`/`netd_txq_paddr`,
`setup_ethd_mappings`, `setup_netd_mappings`), `src/kernel.c3` (spawn
logic), `boards/duo/board.c3` / `boards/qemu/board.c3` (`ETH_*`/
`VIRTIO_NET_*` constants), `user/user.c3` (`netd_info()`),
`user/ethd.c3` (new), `user/netd.c3` (new), `scripts/launch64*.sh`
(virtio-net device), `scripts/build_user.sh`/`build.sh`/`build_duo.sh`.

Also, separately: quieted `usbd`'s own logging (`USBD_VERBOSE`, off by
default) — the periodic raw `HPRT0` dumps and per-transfer `SETUP`
byte prints were necessary while actively debugging DWC2 bring-up and
enumeration, not useful day to day, and were making Ethernet's own
console output hard to read during this session's testing.

---

## 2026-08-22 (66) — USB Phase 2 confirmed working: real device detected on a real hub port

Entry 65's own Phase 2 code got its first real hardware test this
morning — it did not work on the first try, or the second, or the
third, but four real bugs found and fixed in sequence got it all the
way to a genuine, physical confirmation: `hub port 2: connected`, a
real USB device correctly identified on the exact downstream port of
the Duo IO board's own hub it was actually plugged into. Full chain
now verified real: DWC2 host-mode bring-up (entry 64) -> control
transfers over host channel 0 -> device enumeration -> hub
configuration -> per-port power-on -> per-port connect status,
end to end, no simulation, no assumption left unverified.

### The four bugs, in the order they were found

**1. Cache-incoherent DMA buffer** (the big one). `usbd`'s own DMA
buffer (entry 65's `setup_usbd_mappings`) used `map_page()` — the same
call `diskd`'s virtqueue uses — which marks the mapping cacheable
(`board::PTE_EXTRA_BITS`, `SHARE|CACHE|BUF`). Correct for ordinary RAM
the CPU alone touches; wrong for a buffer a *separate bus master* (the
DWC2 core's own DMA engine) also reads directly, since a CPU write can
sit in a cache line indefinitely without ever reaching real RAM.
`diskd`'s own precedent turned out to be a false one: it only ever
runs against QEMU's software-emulated virtio-mmio, which just reads
the guest's memory buffer directly — no real incoherency exists to hit
there at all. `usbd` is the first driver in this project's history
doing genuine DMA against real hardware, and it hit this immediately:
every control transfer's SETUP stage reported success, but the
following DATA stage STALLed, byte-identical (`HCINT=0x0000000a`),
completely unaffected by every other real, well-reasoned fix tried
first (bootstrap MPS0 switched to the USB-2.0-spec-mandated 64 for
high-speed devices, an explicit `HCSPLT=0` write, a 2ms inter-stage
settle delay) — the signature of the actually-transmitted bytes
silently differing from what this driver's own debug prints, reading
the original stack buffer rather than the DMA buffer, had been
trusted as confirming correct. Fixed by switching to
`map_device_page()` (uncached) for this one allocation — everything
else about the DMA-buffer pattern (identity-mapped, physical address
handed back via `SYS_USBD_INFO`) stayed exactly as entry 65 built it.

**2. Missing `SET_CONFIGURATION`**. Device and hub-class descriptor
reads both succeeded even in the unconfigured "Address" state (USB 2.0
spec allows `GetHubDescriptor` there), but `GetPortStatus` doesn't —
STALLed identically on all 4 ports until a `SET_CONFIGURATION(1)`
request was added between the hub descriptor fetch and the per-port
status loop. Hardcoded to configuration 1 (this driver never fetches
the configuration descriptor at all — basic hubs essentially always
have exactly one).

**3. Missing per-port `PORT_POWER`**. With enumeration otherwise fully
working, every port reported "empty" despite a real device being
plugged in before boot — an unpowered port does no connect detection
at all, regardless of what's attached, until the host explicitly
issues `SetPortFeature(PORT_POWER)` for it (a real, spec-mandated step
for hubs with per-port power switching, which this Genesys Logic
GL850/852-family hub — real vendor ID `0x05e3`, confirmed via its own
correctly-decoded device descriptor — implements). Fixed by powering
every port before querying status, then waiting the hub's own
specified `bPwrOn2PwrGood` settle time (hub descriptor byte 5, 2ms
units, floored at 20ms) before trusting any port status read.

**4. (Non-bug, confirmed along the way)** `HPRT0.PRTSPD` read 0
(high-speed) once a real reset actually ran against a real device —
this hub genuinely negotiates HS. Tried switching the bootstrap MPS0
from the traditional "always 8, full/low-speed only" trick to the
USB-2.0-spec-mandated fixed 64 for high-speed devices; didn't change
the outcome on its own (bug #1 was still blocking everything at that
point) but is spec-correct and stayed in.

### Verification

Real Duo hardware, IO board attached, a real USB device plugged into
one of the hub's 4 downstream ports before power-on: full enumeration
trace clean end to end — `bMaxPacketSize0=64`, `SET_ADDRESS`,
`vid=0x05e3 pid=0x0610` (correct, real Genesys Logic hub IDs),
`SET_CONFIGURATION`, hub descriptor (`4 ports`), all 4 `PORT_POWER`
requests, and finally `hub port 2: connected` — the exact port the
device was actually plugged into, the other three correctly reporting
empty. QEMU unaffected (`HAS_USB=false`, this code never runs there).

**Files changed this entry:** `src/process.c3` (`map_device_page()`
for the DMA buffer instead of `map_page()`), `user/usbd.c3`
(`usb_set_configuration()`, `usb_set_port_feature()`, the per-port
power-on step, the high-speed bootstrap-MPS0 fix, and the diagnostic
prints — SETUP byte dump, per-stage failure labels, raw `HCINT` on
error — that made finding all of the above possible).

Not yet committed, alongside entry 65's own work — both land together
once the user reviews the full diff.

---

## 2026-08-22 (65) — USB Phase 2: device enumeration over host channel 0 (implemented, NOT yet hardware-verified)

Written and built (QEMU + Duo, both clean) autonomously overnight,
after entry 64's own Phase 1 confirmed real hot-plug detection but
also confirmed the user's physical test rig (the Duo's official
USB&Ethernet IO board) has an onboard hub, meaning `HPRT0` can only
ever see that hub's own connection — never a downstream device — until
this driver can actually enumerate the hub itself and poll its
individual ports. **This entry's own code has not been run against
real hardware at all** — every other USB entry this session needed a
human to physically power-cycle the Duo and paste back the console log
each round, and that loop wasn't available while writing this. Treat
everything below as a well-reasoned first attempt, not a verified
result — the honest, first real test is whatever happens the next time
someone boots this and a connect event reaches `usb_enumerate_device()`.

### Design

Control transfers over DWC2 host channel 0 only (no split
transactions — every device this driver enumerates directly, the
IO board's own hub included, is full-speed and directly on the root
port from the DWC2 core's own point of view). Sourced from U-Boot's
own `chunk_msg()`/`_submit_control_msg()`/`wait_for_chhltd()`
(`duo-buildroot-sdk`'s `u-boot-2021.10/drivers/usb/host/dwc2.c`) —
register offsets for `struct dwc2_hc_regs` (channel 0 base `0x500`,
`HCCHAR`/`HCSPLT`/`HCINT`/`HCINTMSK`/`HCTSIZ`/`HCDMA`), not guessed.

**DMA buffer**: the DWC2 core (already configured for `DMAENABLE` in
Phase 1's `GAHBCFG` write) needs a real physical address for transfer
data — `usbd`, like any user-mode process, has no way to learn its own
virtual pages' physical backing. Solved with the exact same pattern
`diskd`'s virtqueue already established: `setup_usbd_mappings`
(`process.c3`) allocates one page via `alloc_pages(1)`, identity-maps
it into `usbd`'s own page table, and hands the physical address back
via a new syscall (`SYS_USBD_INFO`, 28 — same shape as
`SYS_DISKD_INFO`).

**Transfer engine** (`user/usbd.c3`): `hc_transfer_once()` programs
`HCTSIZ`/`HCDMA`/`HCCHAR`, sets `CHEN`, and polls `HCINT` for
`CHHLTD` (yield()-paced, 2s timeout) — returns 0 (`XFERCOMP`), 1
(`NAK`/`FRMOVRUN` — completely normal, caller retries), or -1 (real
error). `usb_control_transfer()` builds the standard 3-stage SETUP ->
DATA -> STATUS sequence on top of it, with a 3-second wall-clock NAK-retry
budget per stage (this driver's own established `rdtime()`-based
budget idiom, not a raw iteration count). Control endpoints always
restart their data toggle at DATA1 after a SETUP stage regardless of
any previous transfer's own final state, so no per-endpoint toggle
tracking was needed — a real simplification bulk/interrupt transfers
won't get to keep.

**Enumeration flow** (`usb_enumerate_device()`, called from `main()`'s
own polling loop the moment a real connect event fires — not at init
time, matching entry 64's own lesson about false-positive latches from
an unconditional reset against noise): 50ms bus-reset pulse + a full
1-second settle (matching U-Boot's `dwc2_init_common()` own comment
about "problematic USB keys" exactly, rather than trimming an untested
value) -> `GET_DESCRIPTOR(8)` at the default address to learn
`bMaxPacketSize0` -> `SET_ADDRESS(1)` -> `GET_DESCRIPTOR(18)` at the
new address for the full device descriptor -> if `bDeviceClass ==
0x09` (hub, the expected case here), `GET_DESCRIPTOR` for the
class-specific hub descriptor, then `GET_PORT_STATUS` on every
downstream port, printing connected/empty per port.

**Verification**: QEMU (`HAS_USB=false`, this code never runs there,
confirms only that the kernel-side additions — `SYS_USBD_INFO`,
`usbd_dma_paddr`, the new `setup_usbd_mappings` allocation — don't
disturb anything else) and Duo both build clean. No real-hardware run
yet at all — this is the pending work for whenever the user is back at
the physical board.

**Files changed:** `src/entry.c3` (`SYS_USBD_INFO`), `src/process.c3`
(`usbd_dma_paddr`, DMA page allocation in `setup_usbd_mappings`),
`user/user.c3` (`usbd_info()`), `user/usbd.c3` (the transfer engine
and enumeration flow).

Not committed — same standing rule as always, and doubly so here:
this is real, untested protocol-level code, not just a register tweak.

---

## 2026-08-22 (64) — USB Phase 1: DWC2 host-mode bring-up, real on the Duo

Goal: bring the Duo's actual USB host controller (Synopsys DesignWare
USB2 OTG, "DWC2", at `0x04340000`) into host mode and get
`HPRT0.PRTCONNSTS` to genuinely react to a device plugging in — Phase 1
of the USB mass-storage roadmap (entry 63's `SYS_NS_MOUNT_WAIT` was
Phase 0). Real-hardware-only; QEMU's `virt` machine has no DWC2
equivalent, so there's no dev-loop here — every iteration is a full
build+flash+power-cycle round trip on the real Duo. This ended up being
by far the longest single bring-up in this project's history —
somewhere north of twenty real-hardware round trips — and the final
root causes were genuinely subtle enough that no amount of *reading*
the register reference tables would have found them; it took finding
and diffing against the actual vendor kernel driver.

### The other bug this surfaced: `usbd` breaks the boot-time shell

Before any USB register work mattered at all, the shell stopped
appearing at boot the moment `usbd` was spawned — a real scheduler bug,
not a USB bug. `kernel_main` runs as `idle_proc` itself and creates
every boot-time server sequentially without ever yielding; the shell
has always been created lazily, inside `idle_proc`'s own final
`for(;;)` loop, only once nothing else is `PROC_RUNNABLE`. Every prior
boot-time server eventually reaches a genuine `SYS_IPC_RECV`-driven
`PROC_BLOCKED` state, and each one's own blocking call hands control to
the next-created server in the chain — a "cascading yield()" that,
once the last server blocks, falls back to `idle_proc`, which then
notices nothing is runnable and creates the shell. `usbd` is the first
process in this project's history that never genuinely blocks — it
only polls hardware and calls `yield()`, staying `PROC_RUNNABLE`
forever — which permanently breaks the cascade once it's scheduled,
since `idle_proc` (where shell-creation lives) can never be reached
again via the round-robin scan. Fixed by moving shell creation to be
explicit in `kernel.c3`, right after `envd` and before `usbd`'s own
spawn, instead of relying on the lazy fallback. Also added `SYS_YIELD`
(syscall 27, a plain unconditional `yield()`) for `usbd`'s own
busy-wait loops — not the actual fix, but a real correctness
improvement kept anyway.

### Register facts confirmed, in the order that mattered

Every fix below is sourced from real files in the local
`duo-buildroot-sdk` checkout, not guessed — but the session's own
research process is worth recording, because several plausible-looking
leads turned out to be dead ends, and the two fixes that actually
mattered were found only by escalating from "read the datasheet" to
"read U-Boot" to "read the real vendor Linux driver and its own
shipped rootfs scripts."

**Baseline bring-up** (all correct, none of this was the bug): PHY
reference clocks `clk_125m_usb`/`clk_33k_usb`/`clk_12m_usb`
(`REG_CLK_EN_1` bits 30/31, `REG_CLK_EN_2` bit 0 — sourced from the
Linux clock driver, since the datasheet's own table lists those bits
as "Reserved"); `RST_USB` toggle (`REG_TOP_SOFT_RST` bit 11);
`PAD_USB_VBUS_DET` pinmux (`PINMUX_BASE+0xac`, function 0); the ECO
`RX_FLUSH` errata bit (`REG_TOP_USB_ECO` @ `TOP_BASE+0xB4`, bit 7,
found in U-Boot's `board_usb_init()`); `GAHBCFG` programming
(`HBURSTLEN_INCR4` + `DMAENABLE`, matching the devicetree's own
`g-use-dma;` property — never written by this driver before this
session); `PCGCCTL` cleared to 0 ("Restart the Phy Clock," U-Boot's own
`dwc_otg_core_host_init()`'s first step, never touched before either).

**Dead ends, explicitly ruled out** (so a future session doesn't
re-chase them): `GOTGCTL.CONIDSTS` — spent a full round flipping the
TOP-block `usb_phy_ctrl_reg`'s ID-value bit in both directions to try
to make this DWC2-core status bit read "host"; it never budged either
way, and it turned out the real vendor driver never reads it at all —
host mode there comes entirely from `GUSBCFG.FORCEHOSTMODE`. The
devicetree's second `reg` range (`0x03006000`, "USB 2.0 PHY") —
confirmed via the actual vendor Linux `dwc2/platform.c` glue
(`cviusb_dev.phy_regs`) that this block is real and genuinely mapped,
but only ever touched by BC1.2 charger-detection code, which is
explicitly gated to device mode (`if (!id_override) return -EPERM;`)
— irrelevant to host mode. An external hub-reset GPIO mechanism
(`GPIO_HUBPORT_EN`/`ROLESEL`/`HUBRST`, found in `/etc/uhubon.sh`) —
real, but only wired up in that script's `case` statement for *other*
Cvitek chip variants (cv1821/cv1826/cv1835/cv1838); the plain
`cv180x`/Duo version of that same script defines the functions but
never calls them, confirming the Duo itself has no such external
switch to worry about.

**The actual TOP-block fix**: the exact register value to write for
host mode was always available straight from
`/mnt/system/usb-host.sh` (the vendor rootfs's own one-liner,
`echo host > /proc/cviusb/otg_role`) and its real kernel-side handler,
`dwc2_set_hw_id()` (`linux_5.10/drivers/usb/dwc2/platform.c`) — which
writes `(read & ~0xC0) | 0x40` to `usb_phy_ctrl_reg`: clear bits 6-7,
set bit 6 only. This driver's own earlier value (`0x43`, also setting
`EXTERNAL_VBUSVALID`/`DRIVE_VBUS`, bits 0-1) was this project's own
inference from the datasheet's field table, never confirmed by any
real driver, and wrong — replaced with the vendor's exact byte value.

**The actual core-reset fix**: this driver's own `GSNPSID` reads back
as exactly `0x4f54420a` — which is bit-for-bit
`DWC2_CORE_REV_4_20a`, the real Linux driver's own named constant for
this exact silicon revision (`linux_5.10/drivers/usb/dwc2/core.h`).
For cores at or above that revision, the real `dwc2_core_reset()`
does something this driver never did: after seeing
`GRSTCTL_CSFTRST_DONE` set, it performs an explicit **write-back** —
read `GRSTCTL`, clear `CSFTRST`, set `CSFTRST_DONE`, write it back —
before polling `AHBIDLE` (which Linux also polls *after* the reset
completes, not before, the reverse of this driver's original
ordering). Rewrote `usb_core_reset()` to match this exactly. This was
the fix that took `HPRT0` from permanently frozen at `0x00000000`
(regardless of any other register written, TOP-block or DWC2-core) to
genuinely live and responsive.

**Two more real-hardware-only findings, after `HPRT0` came alive**:
the `GOTGCTL` VBUS-valid override (`VbvalidOvEn`/`VbvalidOvVal`,
another of this driver's own datasheet-only inferences, never in the
vendor driver) turned out to force the port into a permanent false
"connected" latch — removed. So did an unconditional port-reset pulse
performed immediately after port-power, before any real settle time —
Phase 1's own stated scope (connect/disconnect polling only, no
enumeration) never actually needed a reset here at all; replaced with
a plain 100ms settle delay and a W1C-bit clear before the polling loop
starts.

### The final, real confirmation

With the above, a genuinely clean two-state result across separate
boots: SD-card-only boot (no USB IO board attached) shows
`HPRT0=0x00001000`, `prtconnsts=0`, `prtlnsts=0` (SE0 — correctly
disconnected); boot with the Duo's official USB&Ethernet IO board
attached shows `prtconnsts=1`, `prtlnsts=1` (idle full-speed J-state),
consistent and unchanging across multiple boots. That "unchanging"
property was itself briefly alarming — plugging/unplugging a USB drive
into the IO board's own downstream ports never changed anything — until
realizing the IO board's "4x USB" spec implies an onboard hub, and
`HPRT0` can only ever see the single device on the Duo's own root
port: the hub itself, not whatever's plugged into its downstream side.
Seeing the hub connect is a completely valid, real connect-detection
event (a hub is a real, standard-compliant USB device) — the
two-boot-state comparison above is that confirmation, since a live
attach/detach test wasn't physically possible (the IO board's header
also carries the serial console's own UART3 TX/RX, pins 6/7).

Detecting an actual downstream *device* behind that hub — as opposed
to the hub's own connection — needs real hub-class enumeration
(`SET_CONFIGURATION` on the hub, then `GET_PORT_STATUS` class requests
per downstream port), which is out of scope for Phase 1's bare
`HPRT0`-polling design. That's real, necessary Phase 2+ work, not a
bug in what's here.

**Verification**: QEMU regression clean (`HAS_USB=false` there,
`usbd` correctly never spawns, shell/diskd/fsd/fsd2/procd/envd all
create normally). Real Duo hardware: `usbd`'s own diagnostic prints
confirm `GSNPSID`/`GHWCFG2` sane, `GINTSTS.CURMODE`/`GOTGCTL.CONIDSTS`
both correctly report host mode, `HPRT0` genuinely tracks real
connect/disconnect state across the two-boot-state comparison above.
`hotplugtest`/`lsproc` both still clean alongside `usbd`'s own polling
loop (confirms the shell-creation-reorder fix holds).

**Files changed:** `src/entry.c3` (`SYS_YIELD`), `src/process.c3`
(`setup_usbd_mappings`, `usbd_pid`), `src/kernel.c3` (explicit shell
creation before `usbd`'s spawn), `boards/duo/board.c3` /
`boards/qemu/board.c3` (`USB_*` constants), `user/user.c3` (`yield()`
wrapper), `user/usbd.c3` (new — the driver itself), `scripts/
build_user.sh`, `scripts/build.sh`, `scripts/build_duo.sh`.

Not yet committed — working tree has all of the above, pending review.

---

## 2026-08-21 (63) — Hot-plug plumbing (`SYS_NS_MOUNT_WAIT`), and a real kernel interrupt-safety bug found along the way

USB support (goal: mass storage with real hot-plug) needs a way for a
driver spawned *after* boot to announce itself and have some other
process wait until it's actually ready to bind — something this kernel
had no mechanism for at all. `fsd.c3`'s own binding to its disk driver
is a hardcoded, boot-time-only constant (`DISKD_PID = 3`); `SYS_NS_MOUNT`
binds a namespace prefix to whatever's *currently* posted, with no
retry; `mounttest` (the one existing proof `srv_post`/`ns_mount` work
post-boot) deliberately only ever mounts something *already* posted
well before the command runs, avoiding exactly this race. There's also
no user-mode `yield()`/`sleep()` syscall, so a client-side retry loop
has no safe way to wait.

**`SYS_NS_MOUNT_WAIT`** (`src/entry.c3`, syscall 26): same
`(prefix, srv_name)` as `SYS_NS_MOUNT`, plus a `max_attempts` retry
count. Blocks — same `PROC_RUNNABLE`-throughout polling shape as
`SYS_JOIN` (never `PROC_BLOCKED`: nothing would ever clear that for
this condition) — retrying a new shared `ns_mount_try()` helper
(`src/process.c3`, extracted from `SYS_NS_MOUNT`'s own previously-inline
lookup+bind logic, zero behavior change for its existing caller) until
it succeeds or the attempts run out. `user/user.c3` gets the
`ns_mount_wait()` wrapper; `user/shell.c3` gets `hotplugtest`, which
spawns a "late driver" child that posts itself only after a real,
unpredictable delay, and races a real `ns_mount_wait()` call against it
— proving the wait genuinely blocks and retries, not just checks once,
plus a second call against a name nothing ever posts, proving it gives
up rather than hanging forever.

**A real, previously-undiscovered kernel bug, found building this**:
`hotplugtest` reproducibly corrupted the parent's own execution —
not a crash, the parent appeared to silently re-execute its own code
from an earlier point. Root-caused, by elimination across five isolated
variants, to a fresh `rfork()` child getting its first scheduling turn
while the parent is still open inside a *different* blocking syscall.
`sstatus`'s `SPIE` bit (what every `sret` restores the live `SIE`/
interrupt-enable bit from) is a single, unbanked hardware register;
`switch_context()` (the cooperative stack-swap `yield()` uses) never
touches it, only a genuine trap-entry/`sret` pair does. `fork_entry()`
(`src/process.c3`) — a brand-new child's synthetic "first ever" resume
path, entirely separate from the shared `kernel_entry` trap-exit tail —
never touched `sstatus` at all: its `sret` fired using whatever the
*most recent real trap entry anywhere in the system* happened to leave
in that shared register, which, with the parent mid-syscall, was still
the parent's own "interrupts were on" snapshot from *before* it entered
that syscall — globally re-enabling interrupts while the parent's own
wait still assumed they were off, letting a timer interrupt land
mid-syscall (exactly what this kernel's whole preemption-safety design,
`enable_timer_interrupts()`'s own comment, says should be impossible).
Latent until now because nothing before combined "spawn a new process"
with "immediately enter a *different* blocking syscall."

**Fix**: a new `blocking_depth` counter (`src/process.c3`) plus
`Process.in_blocking_wait`, incremented/decremented around all six
blocking syscalls' own poll loops (`SYS_JOIN`, `SYS_GETCHAR`,
`SYS_IPC_RECV`/`_GEN`, `SYS_FUTEX_WAIT`, `SYS_NS_MOUNT_WAIT`).
`fork_entry()` consults it live, at the exact moment its own `sret` is
about to fire, forcing `SPIE` off whenever it's nonzero — checked live,
not baked in at `SYS_RFORK` time (seriously considered and rejected:
`blocking_depth` can change *after* `rfork()` returns but *before* the
child's first real turn, exactly hotplugtest's own scenario). `SYS_KILL`
decrements the counter if it kills a target that was genuinely mid a
counted wait, closing a real leak risk (a killed process's own
increment would otherwise never come back down).

**A wrong first attempt, corrected before shipping**: the first version
also forced `SPIE` off at `handle_trap()`'s own end (the *shared*
trap-exit tail every ordinary syscall returns through), reasoning that
*any* process's eventual natural `sret` could equally use a stale
`sstatus` snapshot if another process was still blocked elsewhere.
Wrong in practice: `blocking_depth` is *effectively always* nonzero
during normal operation — every idle server (`echod`/`fsd`/`procd`/
`envd`) sits *permanently* blocked in `SYS_IPC_RECV` waiting for its
next client, which is its normal steady state, not a transient window.
Gating the shared tail on it disabled real timer-interrupt preemption
for the *entire system*, forever, from early in boot onward — found
directly when `hotplugtest` itself started reproducibly hanging with
that version in place (a syscall-free spinning child, once nothing
could ever forcibly preempt it, simply never gave the CPU back).
Reverted that part: the shared tail's own `sret` already correctly
restores `SIE` from *that specific process's own* `sstatus` snapshot,
captured at *that same trap's* own entry — already safe by the
existing, proven invariant. Forcing `SPIE` off is only ever needed for
a *synthetic* `sret` with no real corresponding trap-entry of its own,
which only happens in `fork_entry()`.

**Also fixed in `hotplugtest` itself**: the "late driver" child
originally spun in a bare `for(;;){}` after posting — a design bug in
its own right, independent of the kernel fix: a real driver would
eventually make *some* syscall (an actual I/O wait), never spin
forever with zero syscalls at all. Once the kernel correctly stopped
letting a mid-syscall parent get preempted by an unrelated process's
stale interrupt state, a truly syscall-free child had no way to ever
give the CPU back. Changed to block on a real `ipc_recv()` for a
message nobody sends — a realistic idle-wait, and one that yields
through the same safe, `blocking_depth`-covered mechanism every other
blocking wait already uses.

**Verification**: `hotplugtest: ok` repeatedly (12+ consecutive
invocations across fresh boots, no failures) on all three QEMU images.
Full regression clean: `mounttest` (confirms `ns_mount_try`'s extraction
is a no-op), `rforktest`, `threadtest`/`threadjointest`, `killtest`,
`permtest`, `srvtest`, `racetest`/`mutextest` (`SYS_FUTEX_WAIT`/`WAKE`),
`ping`/`p9test` (`SYS_IPC_RECV`), `p9fstest`/`p9fswritetest`/
`p9mkdirtest`/`fspermtest`, `runtest2`/`argvtest2`/`pathtest2`/
`bigreadtest`/`elftest2`, full shell suite. Explicitly re-verified the
leak-safety path (a throwaway diagnostic command, not committed): killed
a process genuinely mid-`SYS_JOIN`, confirmed `blocking_depth`
decremented correctly rather than leaking. Three-boot stress batch,
`e2fsck -n -f` clean on both `disk_dual.img` halves.

**Real Milk-V Duo hardware confirmation**: `hotplugtest: ok`,
`killtest`/`permtest`/`p9fswritetest` all still `ok`, `lsproc` clean
(`2/` through `7/`, no leaked children). `mounttest: FAILED` on real
hardware is expected and unrelated — real hardware has never spawned a
second `fsd` (entry 53), so `mounttest`'s own `/mnt/fs2/` cycle has
never been reachable there; not a regression from this entry.

**Files changed:** `src/entry.c3`, `src/process.c3`, `user/user.c3`,
`user/shell.c3`.

---

## 2026-08-21 (62) — mkdir via real 9P: `P9_CREATE` gains a `DMDIR` perm bit

Closes entry 59's other explicit deferral: `P9_CREATE` only ever made
regular files. Real 9P's own `Tcreate` takes a `perm` argument with a
`DMDIR` bit that tells the server to create a directory instead —
closed that gap the same way rather than inventing a separate verb.

**`ext2_mkdir_resolved()`** (`user/fs/ext2.c3`), extracted from
`ext2_mkdir()`'s own tail — same pattern as `ext2_read_inode_at`
(entry 56) and `ext2_delete_resolved` (entry 59): everything past path
resolution (the "already exists" check, inode/block allocation,
`.`/`..` entries, linking into the parent) operates purely on a
directory inode and a name, never touching a path string. `ext2_mkdir`
itself keeps its path-resolution prefix and delegates — zero behavior
change for its existing caller (`/bin/mkdir`).

**`fsd.c3`'s `P9_CREATE` dispatch**: wire format gains a `perm` field
(`fid(4) + perm(4) + name(32)`, was `fid(4) + name(32)` — `name` shifts
from byte 4 to byte 8). `perm & P9_DMDIR` (new constant, `0x80000000`
— the real Plan9 value) selects `ext2_mkdir_resolved()` instead of
`ext2_create_file()`; the fid transform sets `is_dir`/`opened` from
`want_dir` instead of hardcoding them — a directory fid comes back
*not* opened (`P9_OPEN` already rejects directories, and only
`P9_WALK`/`P9_REMOVE` ever touch a directory fid, neither checks
`opened`), matching `P9_ATTACH`'s own root-fid convention.

**`P9_REMOVE` needed zero changes** — the actual payoff of entry 59's
own extraction being generic rather than filename-tied:
`ext2_delete_resolved()` already branches on `mode & EXT2_S_IFDIR`
(non-empty-directory refusal, parent `links_count` fixup,
`ext2_dec_used_dirs()`), regardless of whether the directory came from
a path or a fid.

**A real test-design bug found and fixed while writing `p9mkdirtest`,
not a dispatch bug**: the test's first draft tried to remove a
non-empty directory (expecting `-1`), then remove the file inside it,
then retry removing the directory *using the same fid*. That retry
kept failing. Root cause, found via targeted debug prints (temporarily
added to `ext2_delete_resolved` and the `P9_REMOVE` dispatch, removed
once diagnosed): entry 59's own `P9_REMOVE` design deliberately
consumes the fid on *any* genuine attempt, success or failure — matching
real `Tremove`'s own contract exactly, already relied on by
`p9fswritetest`'s own dangling-fid check. The first (failed, "not
empty") removal attempt had already consumed the fid; the second call
found an unused fid and never reached the dispatch at all. Fixed in
the test, not the driver: the final successful removal walks a *fresh*
fid to the same directory (`p9_walk` again from the still-live root
fid) rather than reusing the one already spent on the earlier
rejection.

**Verification**: `p9mkdirtest: ok` on both images — real directory
create, an independent walk into it (proving a genuine directory
entry, not just local fid state), a nested file created/written/read
inside it, the non-empty-directory rejection, and eventual successful
removal once empty. Full regression clean (`p9fstest`,
`p9fswritetest`, `fspermtest`, `/bin/mkdir`/`/bin/rm` — confirms
`ext2_mkdir_resolved`'s extraction is a no-op for its path-based
caller — `mounttest`, `runtest2`/`argvtest2`/`bigreadtest`). Three-boot
stress batch, `e2fsck -n -f` clean on `disk_ext2.img` and both
`disk_dual.img` halves — no errors or warnings, despite directory
linking/bookkeeping being more structurally sensitive than a plain
file write.

**Real Milk-V Duo hardware confirmation**: `p9mkdirtest: ok`,
`p9fswritetest: ok`, `p9fstest: ok`, `lsproc` clean (`2/` through
`7/`).

**Files changed:** `user/fs/ext2.c3`, `user/fsd.c3`, `user/user.c3`,
`user/shell.c3`.

---

## 2026-08-21 (61) — Genuine offset-aware `Twrite`

Follow-up to entry 59, closing its own explicitly-deferred restriction:
`P9_WRITE` only ever accepted offset 0, because `ext2_write_file()`
(the helper it reused) has no offset parameter at all — it always
replaces a file's content starting from block 0. Real `pwrite()`-style
writes needed a genuinely new primitive, not just relaxing a check.

**New**: `ext2_write_file_at(inode, src, len, offset)` in
`user/fs/ext2.c3`, alongside — not replacing — `ext2_write_file`
(still used unchanged by path-based `ext2_write()`, unrelated "replace
the whole file" semantics). Same per-block allocation loop shape,
generalized with a starting block index and in-block byte offset.

**No holes, by design.** Every read path in this driver
(`ext2_read_at`/`ext2_read_inode_at`) treats `inode.block[i] == 0` as
"past the end of the file", not "a sparse hole" — letting a write
leave a gap of unallocated blocks before new data, while `inode.size`
claims they're valid content, would silently corrupt every future read
of that file. So `offset > inode.size` is rejected outright (`-1`),
same as `offset` already being at/past this driver's own
12-direct-block cap. That still covers what actually matters:
overwriting existing bytes anywhere in the file, and appending exactly
at the current end to grow it.

One correctness improvement made possible by building this fresh
rather than generalizing the old function in place: a partial write
into a block this call just freshly allocated now zero-fills the
buffer first, rather than reading whatever stale content happens to
already be on disk at that block number (`ext2_write_file`'s own
existing behavior in that same situation, left untouched — a
pre-existing quirk, not part of this fix, and not worth the regression
risk of touching a well-exercised path-based write to fix it there
too).

`fsd.c3`'s `P9_WRITE` dispatch dropped the `offset == 0` check, calls
the new function, and grows `inode.size` only if the write actually
extended past the old end — never shrinks it.

`p9fswritetest` extended (not replaced): a mid-file overwrite at byte
6, an append exactly at the current end (26 → 32 bytes), and the old
"any nonzero offset fails" check replaced with a real hole-rejection
check (offset far past the new 32-byte end). Verifying the append case
needed byte-range comparison instead of `strcmp`: the file's content
has a stray trailing-null byte baked in mid-buffer, an artifact of
entry 59's own write call passing a C string literal's length
including its trailing null (harmless there — strcmp naturally stopped
at the same point either side — but it would make a plain strcmp
report a false match for the newly appended tail too).

**Verification**: `p9fswritetest: ok` on both images with all three
new checks passing. Full regression clean (`p9fstest`, `fspermtest`,
`/bin/rm` and existing delete tests, `mounttest`, `runtest2`/
`argvtest2`/`bigreadtest`) — confirms `ext2_write_file`/`ext2_write()`'s
own path-based behavior is completely unaffected, a new function, not
a modified one. Three-boot stress batch, `e2fsck -n -f` clean on
`disk_ext2.img` and both `disk_dual.img` halves — no errors or
warnings, despite the new partial-block-write-at-arbitrary-offset and
append-time-allocation logic being genuinely new on-disk write paths.

**Real Milk-V Duo hardware confirmation**: `p9fswritetest: ok`,
`p9fstest: ok`, `lsproc` clean (`2/` through `7/`) — mid-file
overwrite, append-growth, and hole-rejection all confirmed working for
real, not just on QEMU.

**Files changed:** `user/fs/ext2.c3`, `user/fsd.c3`, `user/user.c3`,
`user/shell.c3`.

---

## 2026-08-21 (60) — Fix `fspermtest`'s real-hardware gap: retarget to root

Closes entry 58's own documented gap. `fspermtest` always targeted
`/mnt/fs2/`, for a real historical reason: the old topology could have
FAT32 and ext2 mounted simultaneously, and an unprefixed path
resolving through the `""` catch-all might land on whichever `fsd` was
created first — FAT32 has no uid concept, so a bare path could
silently bypass ext2's own checks entirely. Entry 53's Plan9-style
reorganization already removed that ambiguity structurally (`""` is
ext2-exclusive on real hardware, and the first partition on every
QEMU image that has one), but `fspermtest` itself was never updated to
take advantage of it — so entry 58 found the opposite problem instead:
real hardware, since entry 53, never spawns a second `fsd` at all,
meaning every `/mnt/fs2/`-prefixed call in this test failed at
`ns_resolve()` *before ever reaching ext2's own permission checks*. The
"correctly denied" results this produced on real hardware were a false
positive from an unreachable namespace, not genuine confirmation of
anything.

**Fix**: every path in `fspermtest` (`user/shell.c3`) switched from
`/mnt/fs2/`-prefixed to bare (root-mount). Same reasoning
`p9fstest`/`p9fswritetest` already rely on — `""` unambiguously means
ext2 wherever this project's real 9P work targets it now. No `ext2.c3`
or `fsd.c3` changes needed — this was a test-targeting gap, not an
enforcement gap; the permission checks themselves (`ext2_write_allowed`
and friends) were already correct, just unreachable from where the
test poked at them.

**Verification**: `fspermtest: ok` on QEMU's dual-mount image (now
against partition 1, the root mount, instead of partition 2) and,
notably, on the single-partition ext2-only image too — the topology
closest to real hardware's own single-`fsd` layout, which this test
literally could not exercise meaningfully before. Full regression
(`runtest2`, `argvtest2`, `mounttest`, `bigreadtest` — all still
`/mnt/fs2/`-targeted, untouched, still `ok`) confirms the retarget
didn't disturb anything relying on the second mount. Three-boot stress
batch, `e2fsck -n -f` clean on both partitions.

**Real Milk-V Duo hardware confirmation**: `fspermtest: ok`, every
individual check line showing genuine allow/deny behavior (not a
namespace-resolution short-circuit) — the first real confirmation that
ext2's own permission enforcement, including entry 58's own rename fix,
actually works on real hardware. `lsproc` clean (`2/` through `7/`).

**Files changed:** `user/shell.c3`.

---

## 2026-08-21 (59) — Real 9P writes against fsd: Tcreate, Tremove, Twrite (offset-0 only)

Follow-up to entry 56 (real 9P read-only against `fsd`). Three new
verbs, same wire discipline as `P9_ATTACH`/`P9_WALK`/`P9_OPEN`/
`P9_READ`/`P9_CLUNK`: `P9_CREATE`, `P9_WRITE`, `P9_REMOVE` (verbs 8-10,
`user/user.c3`), with matching `p9_create`/`p9_write`/`p9_remove`
client wrappers and `fsd.c3` dispatch, ext2 only.

`P9_WRITE` is deliberately narrow: `ext2_write_file()` (the existing
helper both this and the path-based `ext2_write()` use) has no offset
parameter at all — it always replaces a file's entire content from the
start. Rather than build genuine offset-aware partial writes (real
future work), `P9_WRITE` just exposes that same existing capability
through a fid: **offset must be exactly 0**, anything else is rejected
outright rather than silently writing the wrong bytes.

`P9_CREATE` reuses `ext2_create_file()` directly (already takes a
directory inode, not a path) and transforms the fid in place — real
9P's own actual `Tcreate` semantics: no separate `newfid`, and the fid
comes back already open, matching `Tcreate`'s own "no `Topen` needed
after" contract. Files only — a `DMDIR`-style bit for directory
creation stays out of scope.

`P9_REMOVE` needed one real design decision entry 56 never had to
face: fids resolve to a stable inode number (deliberately, so they
survive a rename elsewhere) rather than a path. Removing a file while
*another* fid still holds the same inode open would let that fid keep
reading/writing freed-and-possibly-reallocated blocks — real
corruption, not just a stale error. Fixed with an explicit scan of
`fs9_fids[]` before any removal proceeds: if any other slot is `used`
with the same `inode_num`, the request is rejected outright and the
fid stays open (no on-disk removal was even attempted, so unlike a
genuine attempt this doesn't consume it — confirmed with
`p9fswritetest` itself, which retries the same `p9_remove` call again
after clunking the blocking fid and expects it to then succeed). A
*genuinely attempted* removal, by contrast, consumes the fid
regardless of whether `ext2_delete_resolved()` itself succeeds —
matching real 9P's own `Tremove` contract exactly.

`Fs9_fid_entry` gained `parent_inode`/`entry_sector`/`entry_offset`/
`has_entry` — `P9_WALK` already computed a new entry's directory
position via `ext2_find_in_dir()` but discarded it; now captured so
`P9_REMOVE` never needs to re-walk a path at removal time. `has_entry`
is false only for a bare root fid (`P9_ATTACH` never sets it) — root
has no entry of its own to remove.

`ext2_delete()`'s own tail (everything past path resolution) is
extracted into `ext2_delete_resolved(dir_inode, inode_num,
entry_sector, entry_offset, mode, requester_uid)`, mirroring entry 56's
own `ext2_read_at` → `ext2_read_inode_at` split exactly. `ext2_delete()`
itself keeps its path-resolution prefix and delegates — zero behavior
change for its existing caller (`/bin/rm`).

New `p9fswritetest` (`user/shell.c3`): create-then-immediately-write-
then-read, the offset-0-only rejection, and the dangling-fid safety
check with two real, independently-attached fids on the same inode
(walk fails before create, create-and-write-and-read round-trips,
non-zero-offset write rejected, a second fid opens the file, remove is
rejected while that fid is open, remove succeeds once it's clunked).

**Verification**: `p9fswritetest: ok` on both the ext2-only and
dual-mount images. Full regression clean: `p9fstest`, `/bin/rm` (path-
based delete unaffected by the `ext2_delete_resolved` extraction),
`fspermtest`, `mounttest`, `pathtest`/`pathtest2`, `permtest`,
`elftest`/`elftest2`, `sandboxtest`, `p9realtest`, `p9test`, `nstest`,
`pstest`, `bigreadtest`, `runtest2`, `argvtest`/`argvtest2`. Three
consecutive boots against the same persistent `disk_dual.img` (running
`p9fswritetest`/`p9fstest`/`fspermtest` each time) all `ok` — confirms
create+write+remove leaves the filesystem in a stable, re-testable
state, not accumulating drift. `e2fsck -n -f` clean on `disk_ext2.img`
and both halves of `disk_dual.img` after the stress run, no errors or
warnings.

**Real Milk-V Duo hardware confirmation**: `p9fswritetest: ok`,
`p9fstest: ok`, `lsproc` clean (`2/` through `7/`, no leaked
processes). Unlike entry 58's own `fspermtest` gap, both new test
commands target the root mount (`ns_resolve("")`) exclusively — real
hardware's only mount post-entry-53 — so this is the first write-path
9P work in this series confirmed genuinely working on real hardware,
not just QEMU's dual-mount image.

**Files changed:** `user/fs/ext2.c3`, `user/fsd.c3`, `user/user.c3`,
`user/shell.c3`.

---

## 2026-08-21 (58) — Fix `ext2_rename`'s missing ownership check

Surfaced during entry 56's own research: every other mutating ext2 verb
(`ext2_write`'s overwrite case, `ext2_delete`, `ext2_delete_recursive`)
gates on `requester_uid` via `ext2_write_allowed()` — `ext2_rename`
never looked up `requester_uid` at all. Any non-root process could
rename (including moving into a different directory) any file
regardless of ownership.

Same treatment `ext2_delete`'s own comment already establishes for
exactly this situation: real Unix gates rename by the *directory's*
write permission, not the target's own — this driver doesn't model
directory permissions at all, so the target's (source file's) own
write bit is the stand-in, checked before any of rename's own
destination-side work (cycle check, existing-destination check,
directory-slot allocation, actual writes). `fsd.c3`'s `FS_RENAME`
dispatch gained the same `proc_info()` uid lookup `FS_WRITE`/
`FS_DELETE`/`FS_MKDIR` already have. FAT32 untouched — no uid concept
there at all, same scoping every other permission feature in this
project already has.

`fspermtest` extended with two rename sub-checks (root-owned file,
non-root rename attempt correctly denied; the attacker's own file,
rename succeeds) — the existing parent-side readback check already
doubles as an implicit denial confirmation (a wrongly-succeeded rename
would make the original path unreadable, which the existing check
already catches).

**Verification**: `fspermtest: ok` with both new sub-checks, on the
dual-mount image (single-mount `fspermtest` failure is the same
pre-existing, expected "/mnt/fs2/ inactive there" limitation this test
has always had). `/bin/mv` (root) unaffected. Three-boot stress batch,
`e2fsck -n -f` clean.

**A real, structural gap found while trying to confirm this on real
hardware, not fixed here**: `fspermtest` targets `/mnt/fs2/`
unconditionally — but since entry 53, real Duo hardware no longer spawns
a second `fsd` at all, so `/mnt/fs2/` doesn't resolve to anything there.
`fs_rename("/mnt/fs2/...")` (and every other `fspermtest` call) now
fails at `ns_resolve()`, *before it ever reaches `fsd`/`ext2.c3` at
all* — the "correctly denied" results this produces on real hardware
are a false positive from the namespace not resolving, not genuine
confirmation of any permission check. This means **ext2's own
permission enforcement — including this entry's own new rename check —
has not actually been exercised on real hardware since entry 53
shipped**, only on QEMU's dual-mount image. Confirmed with the user:
left as a known gap for now rather than retargeting `fspermtest` to
root (real hardware's only, writable mount) in this entry — a real
follow-up worth doing, not a silent limitation.

**Files changed:** `user/fs/ext2.c3`, `user/fsd.c3`, `user/shell.c3`.

---

## 2026-08-21 (57) — Quiet sdd's per-sector debug output

`sdd.c3` (the real Duo SD driver) printed two full lines per sector
I/O unconditionally — `"sdd: rw sector=..."` before every command,
`"sdd: CMDxx ok resp0=... ready after ..."` after every successful
transfer. Real, useful bringup-era diagnostics (found real bugs this
way), but with a real ext2 read path routinely touching dozens of
sectors per `exec()`/9P read, it had become pure noise now that the
driver's own timing has been extensively verified this session.

New `SDD_VERBOSE` const, off by default, gates both blocks. Confirmed
safe to toggle without risk: both prints already sit outside the
timing-sensitive window this file's own comments warn about (the
FIFO-shallow bug that window's discipline exists to prevent) — one runs
before the command is even sent, the other after the transfer has
already fully completed.

**Real Milk-V Duo hardware confirmation**: ran the next full real-
hardware test round with `SDD_VERBOSE` off — the serial output is
completely clean of `sdd:` lines, a direct, visible before/after
contrast against every prior real-hardware round this session.

**Files changed:** `user/sdd.c3`.

---

## 2026-08-21 (56) — Real 9P (read-only) against fsd — the real file server, ext2 only

Follow-up to entries 54/55 (real 9P against `echod`'s toy sandbox) —
lands the same protocol against `fsd`, the real file server backed by
ext2, scoped to read-only (`Twalk`/`Topen`/`Tread`/`Tclunk`) and ext2
only. `Twrite`/`Tcreate`/`Tremove`/`Trename` raise real semantic
questions (what does an open fid mean across a rename/delete of its own
target — a scenario that can't occur in today's stateless-per-call
`FS_*` model, so there's no existing behavior to preserve, only a new
one to design) deliberately left for a later entry. FAT32 excluded —
it's boot-partition-only now (entry 53), not part of this project's own
real deployment topology.

**The actual payoff of building the protocol generically against
`echod` first**: no new verb constants, no new client wrapper functions
needed at all. `P9_ATTACH`/`P9_WALK`/`P9_OPEN`/`P9_READ`/`P9_CLUNK`
(`user/user.c3`) and their client wrappers already exist and already
work against *any* pid — real 9P's own "same protocol, any server"
property, for real. `fsd.c3` just needed its own dispatch for these
already-defined verbs, addressed to `fsd`'s own pid instead of
`echod`'s.

`fsd.c3` gains an 8-slot FID table (`Fs9_fid_entry`: `used`/`opened`/
`is_dir`/`inode_num`) — an ext2 inode number is a genuinely stable
identity, unlike a path string (survives a rename elsewhere, unlike
`ext2_cache_path`). `P9_WALK` calls the *existing* `ext2_find_in_dir`,
which already takes an arbitrary directory inode, not just root — so
this is hierarchical for free, no separate "add subdirectories" phase
needed the way `echod`'s own from-scratch synthetic tree required.
Every one of the five verbs returns `-1` when `fs_type != FS_TYPE_EXT2`
(FAT32, or an unmounted second instance) — same graceful-degrade shape
every existing `FS_*` verb already has.

`ext2_read_at`'s own tail (offset/EOF handling, the indirect-block
resolution loop) is extracted into a new `ext2_read_inode_at(inode_num,
...)`, taking an inode number directly — `ext2_read_at` itself (path-
based, still used unchanged by `exec()`'s own chunked read loop and
everything downstream) keeps its own cache/resolve logic and just
delegates once it has `inode_num`; `fsd.c3`'s new `P9_READ` dispatch
calls the same shared helper directly, skipping path resolution
entirely since it already has `fid.inode_num` from the walk. Pure
extraction, zero behavior change for existing callers — confirmed by
the full regression suite passing unchanged.

New shell command `p9fstest` walks real, on-disk data — a root-level
file, then a real subdirectory, then a file inside it (genuine two-level
descent against the actual filesystem, not a synthetic tree) — and a
negative walk against a nonexistent name.

Surfaced, unrelated, not fixed here: `ext2_rename` never looks up
`requester_uid` at all, unlike every other mutating verb (write/delete/
mkdir) — a real, pre-existing permission gap, flagged to the user,
left alone for this entry.

**Verification**: `p9fstest: ok` on the ext2-only and dual-mount
(ext2 root) images; correctly `FAILED` on the FAT32-only image (every
verb returns `-1`, confirms the gate works, nothing crashes). Full
regression — `exec()`-dependent tests, every `/bin/` utility, the
entire existing shell suite, `mounttest`, `p9realtest` — all
unaffected, confirming the `ext2_read_at` extraction is a genuine
no-op. Three-boot stress batch, `e2fsck -n -f` clean.

**Real Milk-V Duo hardware confirmation**: `p9fstest: ok` against the
real, single, ext2-exclusive `fsd` (entry 53's own topology), full
regression (`runtest`/`elftest`) unaffected, `lsproc` clean.

**Files changed:** `user/fs/ext2.c3`, `user/fsd.c3`, `user/shell.c3`.

---

## 2026-08-21 (55) — Real subdirectories in echod's 9P sandbox

Follow-up to the previous entry: `echod`'s own synthetic 9P tree was
flat — only the root had children, enforced directly in `P9_WALK`'s
own dispatch (`fid must be root`), and `P9_OPEN` rejected opening
`P9_NODE_ROOT` specifically. Real 9P's own `Twalk` is inherently
hierarchical — a client walks one path element at a time, composing
calls to descend arbitrarily deep — a flat tree never exercised that.

`P9_node` (`user/echod.c3`) gains `parent`/`is_dir`; the tree grows
from 3 nodes to 5 — `hello`/`motd` unchanged under root, plus a new
`docs` subdirectory containing its own `readme` file, reachable only by
walking `root → docs → readme`. `P9_WALK`'s own dispatch generalizes
from "fid must be root" to "fid must point at a directory," and the
child search from "any node under root" to "any node whose own parent
matches fid's current node" — the exact same code path that already
found `hello`/`motd` under root now also finds `readme` under `docs`,
parameterized instead of hardcoded. `P9_OPEN` generalizes the same way
(reject any directory, not just root specifically).

`p9realtest` (`user/shell.c3`) extended, not a new command — two more
`p9_walk()` calls composed in sequence (`root → docs`, then `docs →
readme`), confirming opening `docs` directly fails (it's a directory)
and the final read reaches genuinely nested content.

**Verification**: `p9realtest: ok` on all three QEMU images with the
new two-level walk included, full regression of `ping`/`runtest`/
`argvtest`/`p9test` unchanged, three-boot stress batch clean.

**Real Milk-V Duo hardware confirmation**: `p9realtest: ok` (including
the new two-level walk), full regression of `ping`/`runtest`/
`argvtest`/`p9test` unchanged, `lsproc` clean.

**Files changed:** `user/echod.c3`, `user/shell.c3`.

---

## 2026-08-21 (54) — Real 9P semantics (FID/Twalk/Topen/Tread/Tclunk), against echod's own sandbox

Today's "9P-lite" (`P9_TWALK`/`P9_TREAD`, introduced 2026-08-15) was
never real 9P — confirmed by research this round: `echod`, the only
server that speaks these verbs, has no backing store at all.
`P9_TWALK` never walks anything (echod just echoes the raw path bytes
straight back); `P9_TREAD` returns a hardcoded canned string, ignoring
offset entirely. No FID exists anywhere in the codebase (every
operation re-sends a full path or uses a bare pid, no persistent open
handle). The real file server (`fsd`, backed by FAT32/ext2) was built
later on an entirely separate, non-9P verb set (`FS_READ`/`FS_WRITE`/
etc.) that never got folded back into 9P. The original 2026-08-15 entry
explicitly deferred "real path resolution" to a later phase — this
entry is that phase, 2026-08-15's own unfinished "next up."

**Lands in `echod`'s own sandbox, not a migration of `fsd`**, confirmed
with the user — a small, in-memory, read-only synthetic tree (`hello`/
`motd`, distinct known content), genuinely exercising real FID/walk/
open/read/clunk semantics, without the much larger risk of migrating
the real file server. Uses racccoon's own existing IPC framing
(`msg_type` carries the verb, structured C3 fields at fixed byte
offsets in `msg_data` — same convention `FS_*` verbs already use), not
real 9P's own byte-level wire encoding (size/type/tag header) — nothing
outside this kernel could ever speak real 9P over an actual byte
stream, so reinventing that framing here would be pure ceremony with no
interoperability benefit.

**New verbs, not a change to `P9_TWALK`/`P9_TREAD`'s own behavior**:
`P9_ATTACH`/`P9_WALK`/`P9_OPEN`/`P9_READ`/`P9_CLUNK` (`user/user.c3`)
sit alongside the existing two, completely untouched — `runtest`/
`argvtest` specifically use `P9_TREAD` to verify `exec()`'s own
argv-passing plumbing, an unrelated use case that would have broken had
`P9_TREAD` suddenly required a walked-and-opened FID.

`echod`'s own new state (`user/echod.c3`): a 3-node flat tree (root +
`hello` + `motd`) and an 8-slot FID table, both populated/reset the way
every other struct in this codebase is — explicit field assignment, not
a struct-array literal (confirmed by grep: no precedent for that syntax
anywhere in this project). `P9_WALK` does a real name lookup against the
tree; `P9_OPEN` marks a FID ready; `P9_READ` does a genuine
offset-based slice into the matched node's own content (proven with a
real mid-string read, not just "always from position 0" — the exact
thing the old `P9_TREAD` could never do); `P9_CLUNK` frees the slot.

New shell command `p9realtest` (not `p9test2` — this session's own `2`
suffix already means "targets the non-default mount," an unrelated
concept) exercises the whole set: two simultaneously-open FIDs, a real
negative walk (`"nope"`, must fail), and two independent offset reads
against two different nodes.

**Verification**: `p9realtest: ok` on all three QEMU images. Full
regression of every existing 9P-lite user (`ping`/`runtest`/
`argvtest`/`p9test`) unchanged. Three-boot stress batch clean (no
filesystem state involved at all — echod's own tree/FID table are
purely in-memory, reset fresh every boot).

**Real Milk-V Duo hardware confirmation**: `p9realtest: ok`, full
regression of `ping`/`runtest`/`argvtest`/`p9test` unchanged, `lsproc`
clean.

**Files changed:** `user/user.c3`, `user/echod.c3`, `user/shell.c3`.

---

## 2026-08-21 (53) — ext2 becomes root everywhere; FAT32 becomes boot-only; real `/mnt` binding

Plan9-style filesystem reorganization. Root is ext2 now, both on real
Milk-V Duo hardware and in QEMU's own dual-mount test topology —
previously FAT32 was "root" purely because it happened to be whichever
fsd got created first (`create_process()`'s own `""` catch-all binding
to `fsd_pid`), the exact bug-prone pattern this whole session kept
working around (`/2/`-prefix requirements, real-hardware bare paths
defaulting to the wrong filesystem, etc.). FAT32 becomes boot-partition-
only everywhere: on real hardware `DUOBOOT` stays physically on the SD
card (the SoC's own boot ROM reads `fip.bin` from it via its own
independent FAT32 walk, already fully decoupled from racccoon's kernel
— confirmed via `scripts/flash_duo.sh`'s own header comment) but
`fsd` never mounts it anymore; on QEMU it has no structural role to
mirror at all (QEMU loads the kernel ELF directly via `-kernel`, no
boot-ROM-reads-a-partition step exists there), so `disk.img`
(FAT32-only) stays purely as ongoing regression coverage for the
backend itself, never anyone's root or dual-mount partner.

**Real Duo hardware**: `boards/duo/board.c3` now points
`FS_PARTITION_START_SECTOR` at `EXT2TEST` (was `DUOBOOT`), and
`HAS_SECOND_FS_PARTITION` is `false` — only one `fsd` process exists.
Since filesystem type is auto-probed by content (`ext2_probe()` first),
not partition position, that one `fsd` correctly mounts ext2 with zero
`fsd.c3`/`ext2.c3` changes. This retires the single biggest source of
real-hardware pain this session kept hitting: with only one fsd, every
bare path now reaches ext2 directly, no more "which fsd was created
first" ambiguity to work around.

**`/mnt/fs2/`, not `/2/`**: matches Plan9's own convention — `/mnt` is
just an ordinary directory (root's own `bin/` now has a real, sibling
`mnt/` directory too, initially empty) that other services get mounted
onto, nothing structurally special about it, same as this project's own
`/srv`/`/proc`/`/env` are already name-keyed IPC-backed namespace
prefixes mirroring Plan9 already. `create_process()`'s default namespace
still statically binds this at boot (slot 2, renamed from `"/2/"`) —
deliberately not raced against `fsd2`'s own boot-time mount via a real
`ns_mount()` call instead: there's no `yield()`/`sleep()` syscall in
this kernel to wait on safely, and trading a small, already-safe
hardcoded default for a real chance of an intermittent missing mount
isn't a good trade for a cosmetic rename. (This isn't actually in
tension with "real Plan9-style" — even a real Plan9 `init` establishes
its own starting namespace directly, not via a race against its own
children.)

**Proving `srv_post()`/`ns_mount()`/`ns_unmount()` work for real, not
just as boot-time plumbing**: these syscalls already existed (this
session's own earlier work) but were never genuinely exercised
end-to-end. `fsd.c3` now calls `srv_post("fs2")` right after mounting,
*only* when it's the second instance — `fsd.c3` is user-space and can't
see `board::` (kernel-only module) to know that about itself, so this
required extending the existing `SYS_FS_PARTITION_INFO`/
`fs_partition_info()` mechanism with a second optional out-pointer
(same convention `SYS_NS_RESOLVE`/`SYS_RFORK` already use), fed by a new
`Process.is_secondary_fs` field `kernel.c3` sets unambiguously at each
of its own two `setup_fsd_mappings()` call sites — it already knows
which is which, since its own code is what conditionally creates the
second instance at all. New shell command `mounttest`: reads through
the default mount, `ns_unmount("/mnt/fs2/")`, confirms the read now
fails, `ns_mount("/mnt/fs2/", "fs2")` re-adds it by name through the
exact syscalls any user process could call itself, confirms the read
works again. Entirely post-boot, manually triggered — no race with
`fsd2`'s own startup, since by the time anything types a shell command
it's had many scheduler rounds to finish.

**QEMU's `disk_dual.img`** is rebuilt as two ext2 partitions instead of
FAT32+ext2 — partition 1 (root) gets the same fixture set
`disk_ext2.img`'s own root already has plus the new `mnt/` directory;
partition 2 (bound at `/mnt/fs2/`) reuses the existing ext2-half
construction essentially unchanged (it was already ext2, only partition
1 was what changed). Every remaining `"/2/"` reference in
`user/shell.c3` becomes `"/mnt/fs2/"` — command *names* stay unchanged
(`runtest2`, `argvtest2`, `pathtest2`, `elftest2`, `fspermtest`,
`bigreadtest` — the `2` still means "targets the non-default mount,"
regardless of that mount's prefix string). Found two stale comments
citing the old real-hardware "DUOBOOT/FAT32 wins by creation order"
bug (now structurally impossible there) and one referencing
already-removed `readfile2`/`newfile2` commands from an earlier entry
— fixed in place; historical devlog entries themselves are not
retroactively edited (same discipline already established).

**Verification**: on the new dual-ext2 image, `runtest`/`argvtest`/
`pathtest`/`elftest` (root, now ext2 instead of FAT32) and
`runtest2`/`argvtest2`/`pathtest2`/`elftest2`/`fspermtest`/`bigreadtest`
(now via `/mnt/fs2/`) all `ok`, new `mounttest: ok`, full regression of
every process/IPC-mechanism builtin and the `/bin/` utilities against
both mounts (confirming `cat`/`ls`/`write`/`rm`/`mkdir`/`mv` work
against ext2-as-root now, lowercase filenames preserved as expected,
unlike FAT32's uppercase 8.3 names). Single-mount images unaffected —
confirms the conditional `srv_post()` correctly never fires when there's
no real second mount (`fs_type` stays `FS_TYPE_NONE`). Three-boot stress
batch, `e2fsck -n -f` clean on every ext2 image, `fsck.vfat -n` clean on
the untouched FAT32-only image.

**Real Milk-V Duo hardware confirmation**: `cat hello.txt` (bare, no
prefix) now correctly reaches ext2 directly — the long-standing "bare
path hits whichever fsd was created first" issue is structurally gone
on this board, not just avoided. `lsproc` shows `2/`-`7/` only (one
fewer than QEMU's `2/`-`8/`, exactly the expected shift from no longer
spawning a second `fsd`) — clean, no leaked slots. `ls mnt` correctly
shows nothing (a genuinely empty directory).

**Files changed:** `boards/duo/board.c3`, `src/process.c3`,
`src/kernel.c3`, `src/entry.c3`, `user/user.c3`, `user/fsd.c3`,
`user/shell.c3`, `scripts/build.sh`, `scripts/launch64_dual.sh`.

---

## 2026-08-21 (52) — Shell backspace/line-editing support

Follow-up to the previous entry: now that the shell takes real typed
paths and arguments instead of fixed test commands, a typo had no way
to be corrected — `main()`'s own input loop (`user/shell.c3`) echoed
and appended every byte literally, including whatever a Backspace
keypress produced.

**Fix**: both `0x7F` (DEL) and `0x08` (BS) are treated as backspace —
different terminal emulators/serial console tools send different
bytes for the same key, no way to know which in advance, so both are
handled rather than guessing one. Checked as the very first thing in
the loop, before the existing echo/full-buffer logic — which means a
user can now also backspace their way back from a genuinely full
127-character line instead of it being unconditionally abandoned the
moment the old `i == 127` check fired; a side effect of the ordering,
not extra logic. The raw backspace byte is never echoed as-is — `"\b
\b"` (cursor back, blank the character, cursor back again) is the
actual on-screen erasure; a real terminal renders this as the
character disappearing.

**Verification**: no shell command can assert on terminal echo
behavior, so this was verified by real typed interaction through the
paced-input QEMU harness with literal `0x7F` bytes embedded in the
input stream — typo-then-correct (`x`, backspace, `cat hello.txt` →
correctly executes as `cat hello.txt`, confirmed by its real output
appearing, not a mangled command), backspace on an empty line (safely
a no-op), and filling the line to its 127-character limit then
backspacing all the way back to empty before typing a real command
(proves recovery from a full line, not just a partially-full one) —
each case's *actually-executed* command was correct in every scenario
(confirmed by its real output), the only artifact being that raw
`\b`/space bytes render as literal characters when a captured byte log
is viewed as plain text outside a real terminal emulator, not a bug in
the logic itself. Full regression (existing builtins and the previous
entry's own `/bin/` utilities) unaffected, three-boot stress batch
clean.

**Real Milk-V Duo hardware confirmation**: typed a typo, backspaced,
retyped correctly, in a real terminal against the real board —
characters visibly erased on screen as expected (the one thing QEMU's
raw-byte-log verification couldn't directly confirm), and the corrected
command executed correctly (reached `cat`'s own real "not found" path
for a file that was never seeded onto the real `DUOBOOT` — expected,
not a bug). `lsproc` clean afterward.

**Files changed:** `user/shell.c3`.

---

## 2026-08-21 (51) — Real argv-parsing shell + fs-operation tests become `/bin/` utilities

Every one of the shell's 54 commands (`user/shell.c3`) was dispatched by
comparing the *entire* input line against a fixed string — no
tokenization, so no command could take real user-supplied arguments;
`readfile` always read the same hardcoded path, `mkdirtest` always
created the same hardcoded directory. Every filesystem primitive these
commands exercised (`fs_read`/`fs_write`/`fs_delete`/
`fs_delete_recursive`/`fs_mkdir`/`fs_rename`/`fs_list`) was already a
real, tested, path-taking function — the hardcoding was purely in the
shell's own dispatch layer.

**Tokenization**: the command-line-reading preamble now splits on
spaces in place (mutating the line buffer itself, same "no separate
storage" approach `exec()`'s own NUL-separated argv blob already uses)
into up to 8 tokens. Every *kept* builtin's own `strcmp(cmd, "...")`
dispatch line is completely unchanged — `cmd` still means "the command
name," just sourced from the first token instead of the whole line.

**Twenty-three commands removed**, replaced by six real `/bin/`
utilities (`user/cat.c3`, `ls.c3`, `write.c3`, `rm.c3`, `mkdir.c3`,
`mv.c3` — same minimal skeleton every exec() target already uses,
`get_argv()` for arguments, thin wrappers around already-tested
primitives, no new syscalls or primitives needed anywhere):
`readfile`/`readfile2`/`readsubfile`/`readsubfile2` → `cat <path>`;
`ls`/`lssub` → `ls [path]`; `writefile`/`newfile`/`newfile2`/
`newsubfile`/`newsubfile2` → `write <path> <text>` (`fs_write` already
creates-or-overwrites transparently, so one utility covers both old
scenarios); `deletetest`/`deletetest2`/`rmdirtest`/`rmdirtest2`/
`rmdirnonempty`/`rmdirnonempty2`/`rmrtest` → `rm <path>` / `rm -r
<path>`; `mkdirtest` → `mkdir <path>`; `renametest`/`movetest` → `mv
<old> <new>` (`fs_rename` already handles same-dir rename and
cross-dir move identically); `deleteprotected`/`protectedwrite` → no
longer separate commands — `rm fip.bin`/`write fip.bin ...` against the
new generic utilities exercise the identical scenario.

Deliberately scoped out (confirmed with the user before starting): the
~30 remaining commands are process/IPC mechanics (`permtest`,
`fspermtest`, `rforktest`, `threadtest`, `mutextest`, `racetest`,
`killtest`, `srvtest`, `nstest`, `p9test`, `sandboxtest`, ...) or
meta-tests of exec() itself (`runtest`/`argvtest`/`pathtest`/`elftest`
and their `2` variants) — converting a test *of* exec() into something
exec() has to load would be architecturally awkward for no real
benefit, and these aren't "commands with arguments" the way a
filesystem operation is. They stay exactly as they were.

**Shell's new fallback**: anything not a builtin gets `rfork()`+`exec()`
against a bare `"/bin/<cmd>"` (not `$PATH`-resolved — matches how
`bin/echod` is referenced everywhere else in this file, keeps this
orthogonal to `pathtest`'s own separately-tested `exec_path` feature),
passing the remaining tokens through as the new process's own argv. The
shell `join()`s (already used elsewhere in this file, e.g.
`fspermtest`) before printing its next prompt — ordinary blocking-shell
behavior.

**Found and fixed a real, previously-flagged-but-not-fixed gap while
verifying this**: the dual-mount QEMU image's FAT32 half has *never*
had a `bin/` directory at all (entries 45 and 49 both flagged this —
every un-suffixed exec()-family test correctly `FAILED` there — without
fixing it, since nothing forced the issue until now). Since the
shell's own fallback always execs a bare `/bin/<cmd>` for the *command
name itself* regardless of what its arguments target, the new utilities
were completely unreachable on that image even when invoked as `cat
/2/hello.txt` — the argument correctly targets ext2, but `cat` itself
could never be found. Fixed by seeding `bin/echod`, `bin/echod.elf`,
and the six new utilities onto the dual image's FAT32 half too — as a
side effect, `runtest`/`argvtest`/`pathtest`/`elftest` (previously
always `FAILED` there) now pass on that image for the first time.

**Verification**: no self-checking "ok"/"FAILED" test commands exist
for these six anymore — by design, they're real utilities now, not
tests. Verified the way an actual user would: scripted interactive
command sequences through the paced-input QEMU harness — each
utility's happy path (`mkdir`→`write`→`cat`→`ls`→`mv`→`cat`→`rm`→`rm
-r`), cross-directory `mv`, protected-file refusal (`rm fip.bin`/`write
fip.bin x`), error paths (missing arguments, nonexistent files) —
across all three QEMU images including `/2/`-prefixed invocations on
the dual image, plus the full ~30-command kept-builtin regression suite
(unaffected by the tokenization change). Three-boot stress batch,
`fsck.vfat -n`/`e2fsck -n -f` clean on every image (including no
free-cluster-count regression from entry 50's own fix).

**Real Milk-V Duo hardware confirmation**: seeded all six new utilities
onto real `DUOBOOT` and `EXT2TEST` (confirmed via `debugfs` directly
against the device, same discipline established earlier this session).
Full scripted sequence against both — `mkdir`/`write`/`cat`/`ls`/`mv`/
`rm`/`rm -r` on `DUOBOOT`, `cat`/`mkdir`/`write`/`rm -r` via `/2/` on
`EXT2TEST` — every output matched exactly, `lsproc` clean afterward.

**Files changed:** `user/shell.c3`, `user/cat.c3`, `user/ls.c3`,
`user/write.c3`, `user/rm.c3`, `user/mkdir.c3`, `user/mv.c3`,
`scripts/build_user.sh`, `scripts/build.sh`.

---

## 2026-08-21 (50) — FAT32 free-cluster-count bookkeeping (FSInfo sector)

`fsck.vfat -n` flagged "Free cluster summary wrong... Auto-correcting"
after essentially every write/delete test all session, on every FAT32
image. Root cause: `user/fs/fat32.c3` never touched the FAT32 FSInfo
sector at all — `fat32_mount()` never even parsed `BPB_FSInfo` (the BPB
field naming that sector), and neither `fat32_alloc_cluster()` nor
`fat32_free_cluster_chain()` updated it. Purely cosmetic — FSInfo's own
`free_count` is a *hint*, not authoritative data, which is exactly why
`fsck.vfat` silently recomputes and corrects it rather than erroring —
but this project has treated a clean fsck as a real correctness bar all
along (same class of gap already fixed for ext2's own
`bg_used_dirs_count`/`links_count`).

**Fix**: a new `fat32_free_count` global, established at mount time
(trusted from FSInfo if its three signatures check out and it isn't the
explicit `0xFFFFFFFF` "unknown" sentinel, otherwise recomputed once via
the same linear-scan shape `fat32_alloc_cluster` already uses to find
one free entry — not every real-world FAT32 volume populates FSInfo
correctly, so this fallback matters for more than defensiveness), kept
in sync by `fat32_alloc_cluster`/`fat32_free_cluster_chain` and written
back via a new `fat32_write_free_count()` helper.

Deliberately **not** the same failure-propagation discipline
`bg_used_dirs_count` (ext2's own equivalent) uses: by the time either
call site writes the count back, the *authoritative* state — the FAT
table entry itself — has already changed successfully. Failing the
whole alloc/free because this secondary, hint-only write failed would
be strictly worse than a stale hint: the caller would believe the
operation itself never happened while the real FAT entry already did,
exactly the inconsistency this driver otherwise works to avoid. Written
back best-effort instead.

**Verification**: no functional/shell-visible behavior change — this is
pure on-disk bookkeeping, so the actual test is `fsck.vfat -n` itself.
Full regression suite unaffected on `disk.img` and the dual image's own
FAT32 half; after a batch of writes/deletes/mkdir/rename/move, `fsck.vfat
-n` reports the free-cluster count *matching* what it independently
computes on both — no more "Free cluster summary wrong." Three-boot
stress batch (`runtest`/`elftest`/`newfile`/`deletetest`, the same
repeatable set every earlier stress batch this session used — a
`mkdirtest`/`renametest`/`movetest`/`rmdirtest` sequence isn't
idempotent when repeated back-to-back on an already-mutated persistent
image across separate boots, unrelated to this fix, confirmed by the
single earlier run succeeding cleanly) stayed clean throughout. The
mount-time "recompute via full scan" fallback path has no exercising
fixture (every QEMU image here is built via `mkfs.vfat`, which does
populate FSInfo correctly) — verified by code review, stated plainly as
an accepted gap rather than silently skipped.

**Real Milk-V Duo hardware confirmation**: `newfile`/`deletetest`/
`lsproc` all behave identically on the board (no functional change
expected or found). Pulled the SD card back to the host afterward —
`sudo fsck.vfat -n /dev/sdc1` reports no "Free cluster summary wrong"
at all (two unrelated, pre-existing notes: a harmless boot-sector-vs-
backup byte difference, and the dirty bit — set because this project's
own workflow always power-cycles without a clean unmount, not something
this entry touches).

**Files changed:** `user/fs/fat32.c3`.

---

## 2026-08-21 (49) — FAT32 chunked-read caching (exec() over FAT32)

Entry 46 fixed this exact bug class for `ext2_read_at`, flagging
FAT32's own `fat32_read_at`/`fat32_read_file_at` (`user/fs/fat32.c3`) as
having the same problem — arguably worse. On every `exec()` chunk call,
`fat32_read_at` redid the directory walk from root (same cost class
ext2 had), and `fat32_read_file_at` *also* re-walked the FAT cluster
chain from `first_cluster` every single call — `offset / cluster_size`
clusters walked from scratch each time. Unlike ext2's old bug (roughly
constant per-chunk overhead), this one grows *with* offset: chunk K
walks ~K times further than chunk 1, so total cost across one file read
was quadratic in chunk count. On real Duo hardware `DUOBOOT` (FAT32) is
the *default* mount, so every `exec()` there paid this.

**Fix**: a `fat32_cache_*` single-slot cache, same path/identity shape
entry 46 already established for ext2 (`fat32_cache_path`/
`fat32_cache_first_cluster`/`fat32_cache_file_size`), plus a second
piece FAT32 specifically needs — `fat32_cache_resume_offset`/
`fat32_cache_resume_cluster`, a live cluster-walk cursor, since FAT32
has no O(1) "index → block" math the way ext2's `i_block[]` gives for
free; reaching cluster N always means following N links from a known
start. `fat32_read_file_at` resumes from the cached cluster instead of
`first_cluster` when `offset` is at or past it, falling back to a full
walk otherwise (a backward seek, never a pattern `exec()` produces, but
kept correct regardless).

Found a real bug in-flight while implementing this, before it ever
reached a test: the natural-looking version — advance the cache in
lockstep with the existing loop's own unconditional `cluster =
fat32_next_cluster(cluster)` — silently defeats itself. That line runs
one cluster *past* wherever a call actually needed to stop, as a pure
structural side effect of the original loop shape (harmless there,
since `cluster` was just a discarded local); caching that same
one-cluster-ahead value would mean every call's own cache write
overshoots past where the *next* call's own offset lands, turning
every subsequent call into a cache miss — defeating the entire
optimization for the common case (many small chunks inside one larger
cluster). Fixed by checking `bytes_read >= len` *before* advancing/
caching, not after. Caught by tracing through the design during
planning, not by a failing test.

**Invalidation**: same 5-site unconditional pattern entries 46/47
already established for ext2 — `fat32_write`/`fat32_delete`/
`fat32_delete_recursive`/`fat32_mkdir`/`fat32_rename` each invalidate
as their first statement.

Also updated this file's own header comment, which flatly claimed "no
caching" — now scoped to say what's actually true: no *general*
whole-filesystem cache, but this one narrow exec()-loop exception.

**Verification**: `runtest`/`argvtest`/`pathtest`/`elftest` (the
un-suffixed variants, hitting FAT32 by default) all `ok` on QEMU's
`disk.img`; a FAT32 mutation immediately followed by `runtest`/`elftest`
in the same boot confirms no stale cache. Full regression suite on all
three QEMU images — the dual-mount image's own FAT32-default tests
correctly `FAILED (exec load failed)` there, the same pre-existing
fixture gap entry 45 already documented (that image's FAT32 half was
never seeded with `bin/echod`), not a regression. Three-boot stress
batch, `fsck.vfat -n` clean (same pre-existing free-cluster-count
cosmetic warning this project has always had, untouched by this entry),
`e2fsck -n -f` clean on the unaffected ext2 images.

**Real Milk-V Duo hardware confirmation**: `runtest`/`argvtest`/
`pathtest`/`elftest` all `ok` against real `DUOBOOT` — each completed
immediately, without the long multi-second burst of repeated sector
reads entry 46 had to explain away for ext2 before its own fix; visible
confirmation this fixes the same real slowness for FAT32, which is the
*default* mount on this board. `lsproc` clean afterward.

**Files changed:** `user/fs/fat32.c3`.

---

## 2026-08-21 (48) — ext2: double- and triple-indirect block support (read-only)

Extends `ext2_resolve_block` (`user/fs/ext2.c3`) past its previous
direct-blocks-plus-single-indirect reach (`i_block[0..11]` +
`i_block[12]`, capped at `12 + block_size/4` blocks — 268KB at QEMU's
1024-byte blocks) to walk all three levels the ext2 spec actually
defines: `i_block[13]` (double-indirect) and `i_block[14]`
(triple-indirect). Read-only, matching this file's own existing v1
write scope (`ext2_write` stays direct-blocks-only, unaffected) —
confirmed before writing any code that `ext2_write_inode` already
preserves `i_block[12..14]` untouched across any existing write path
(it patches specific fields into a block read fresh from disk each
time, never reconstructing the record from scratch), so this needed no
write-side changes at all to stay correct.

**Design**: `Ext2_inode_info` gains `double_indirect_block`/
`triple_indirect_block`. The old two-param cache (`char*`+`bool*`,
good for exactly one indirect block) is replaced by a new
`Ext2_block_cache` struct with independently-tracked slots for the
leaf level (shared by single/double/triple — whichever leaf a given
read is currently walking), the double/triple "top" pointer blocks
(loaded once, constant for a file), and triple-indirect's own middle
level. Identity-tracked by physical block number (`0xFFFFFFFF` sentinel
for "not loaded yet," matching this project's own established
fail-closed-sentinel convention) rather than a bare loaded bool,
because — unlike the old single-indirect case — a read walking
double/triple indirect crosses into genuinely different leaf/mid
blocks as it advances, and `0` is itself a legitimate cached value (a
sparse hole's all-zero leaf), so a bool alone couldn't tell "nothing
loaded" from "loaded, and it's the hole." A shared `ext2_resolve_leaf`
helper does the actual "load or reuse, zero-fill on a hole" work for
every level. Stack cost checked, not assumed: 4 buffers × 4096 bytes =
16KB, comfortably inside `fsd`'s own 64KB process stack alongside the
caller's existing 4KB block buffer.

In practice this driver's own 32-bit `i_size` (no `i_size_high`) already
caps any representable file at 4GB, well below what triple-indirect
alone can address — the new ceiling is a completeness property of the
implementation, not something any real file on this project could ever
approach.

**Test coverage**: no existing fixture was big enough to exercise this
(`echod` is ~70KB, well within the old single-indirect reach). Added
`bigfile.bin` — a 300000-byte, deterministically-generated
(`byte[i] = i % 256`) fixture seeded into both ext2 QEMU images
(`scripts/build.sh`, via a small `python3` one-liner rather than a
committed binary), genuinely past single-indirect reach at 1024-byte
blocks. New `bigreadtest` (`user/shell.c3`) reads it via `fs_read_at` in
1024-byte chunks (same shape `exec()`'s own loop uses) into a new
global buffer (300KB — too big for a stack local, same reasoning
`run_exec_buf` already established), then verifies *every byte*
against the known pattern rather than just checking the read
"succeeded" — a wrong block resolution would still return real,
on-disk bytes, just the wrong ones, so only a full content check
actually proves correctness. Targets `/2/bigfile.bin` unconditionally
(same reasoning `fspermtest`'s own header comment already established
for why an unprefixed path can't be trusted).

Triple-indirect's own arithmetic has no dedicated fixture — a file that
size isn't practical to generate or store for this project. Verified by
code review and by sharing the exact same `ext2_resolve_leaf`/cache
machinery double-indirect's own fixture exercises, rather than an
end-to-end test — a real, accepted verification gap, stated plainly
rather than silently assumed away.

**Verification**: `bigreadtest: ok` on the dual-mount QEMU image (where
`/2/` genuinely reaches ext2); correctly `FAILED` on the single-mount
ext2 image (mount 2 is inactive there, same pre-existing precedent
`fspermtest` already established, not a regression). Full regression
suite on all three QEMU images unaffected by the signature change
(`ext2_resolve_block`'s callers both updated), three-boot stress batch,
`e2fsck -n -f` clean on both ext2 images.

`bigreadtest` also gained better failure diagnostics along the way
(reports whether the read itself failed vs. returned the wrong byte
count vs. a specific mismatched offset, instead of a bare "FAILED") —
needed for real: the first real-hardware run failed, and it turned out
to be the exact same class of issue found twice already this session
(entries 45/46's own `seed_ext2test_bin.sh` story) — `bigfile.bin`
wasn't actually on the device, this time because the SD card's mount
had simply dropped between seeding and testing, not a mountpoint-naming
issue. The better diagnostics didn't end up needed to *find* that (a
`findmnt`/`debugfs` check from the host caught it directly), but stay in
the test now that they exist.

**Real Milk-V Duo hardware confirmation**: `bigreadtest: ok` against
real `EXT2TEST` (4096-byte blocks — genuinely different `N` than either
QEMU image, confirming the arithmetic generalizes for real, not just on
paper), `lsproc` clean afterward. At this block size the 300KB fixture
actually stays within single-indirect reach (`12 + 1024 = 1036` blocks
≈ 4.2MB) — this run exercises the refactored single-indirect path
(now going through the shared `ext2_resolve_leaf` helper) for real, not
double-indirect specifically; double-indirect itself was confirmed on
QEMU's 1024-byte-block images, where the same 300KB fixture genuinely
exceeds single-indirect's much smaller reach there.

**Files changed:** `user/fs/ext2.c3`, `user/shell.c3`, `scripts/build.sh`.

---

## 2026-08-21 (47) — ext2 recursive-delete ownership enforcement

Closes a gap the real ext2 permissions feature (entry 43) deliberately
left open: `ext2_write`/`ext2_delete` both gate overwriting/deleting an
*existing* file on `requester_uid` vs. the target's own `i_uid`/`IWUSR`/
`IWOTH` bits, but `ext2_delete_recursive` (and its own helper
`ext2_delete_dir_contents`) took no `requester_uid` at all — a non-root,
non-owner process could `rm -r` an entire subtree it didn't own,
including files it individually couldn't touch via plain `deletetest`.

**Fix**: both now take `requester_uid`. `ext2_delete_recursive` checks it
against the top-level target the same way `ext2_delete` already does;
`ext2_delete_dir_contents` checks it against *every child it walks*,
right after that child's own inode read and before anything destructive
happens to it — same placement discipline the existing protected-entry
check right above it already uses. Same caveat that existing check
already has, not a new one introduced here: entries encountered earlier
in the same directory, or already recursed into, may already be gone by
the time a denied entry is hit deeper in the tree.

The root/owner/other check itself was about to be duplicated a 3rd and
4th time on top of the two copies already in `ext2_write`/`ext2_delete`
— factored into one shared `ext2_write_allowed(inode, requester_uid)`
helper, with those two existing call sites refactored to use it too (no
behavior change there, same bits, same semantics).

`user/fsd.c3`'s `FS_DELETE` dispatch now looks up `requester_uid` once
and passes it to either `ext2_delete`/`ext2_delete_recursive`, instead of
only the non-recursive branch doing the lookup.

**Test coverage**: `fspermtest` (`user/shell.c3`) extended with two more
sub-checks in the same setuid(42) child — real two-entry trees via
`fs_mkdir`+`fs_write` (a bare empty dir wouldn't exercise the child walk
at all): recursive-deleting a root-owned tree as non-owner (must fail),
then creating, writing into, and recursive-deleting its *own* tree (must
all succeed) — same "denied on someone else's, works on your own" shape
the existing non-recursive sub-checks already establish. Root's own
cleanup at the end uses `fs_delete_recursive` too, confirming
`requester_uid == 0` still works unchanged through the new checks.

**Verification**: full regression suite on all three QEMU images —
`rmrtest` (existing plain recursive-delete test, run as root) unaffected
on the single-mount images; it fails on the dual-mount image, but that's
a pre-existing fixture gap (`nestdir` was never seeded onto that image's
ext2 half, same class of gap entry 45 already flagged for that image's
FAT32 half), not a regression. Three-boot stress batch, `e2fsck -n -f`
clean on both ext2 images.

**Real Milk-V Duo hardware confirmation**: `fspermtest: ok` against real
`EXT2TEST`, including both new recursive-delete sub-checks, `lsproc`
clean afterward.

**Files changed:** `user/fs/ext2.c3`, `user/fsd.c3`, `user/shell.c3`.

---

## 2026-08-21 (46) — exec() ext2 chunked-read caching

Follow-up to the previous entry's own flagged issue: `exec()`
(`user/user.c3`) loops calling `fs_read_at()` in ~1124-byte chunks
(`FS_MSG_MAX-4`), and `ext2_read_at` (`user/fs/ext2.c3`) was redoing a
completely fresh path walk from the filesystem root — `ext2_resolve_dir`
+ `ext2_find_in_dir` — on *every single chunk*, even though every call in
one `exec()`'s loop targets the exact same path. Loading the 71648-byte
`echod` on real hardware took ~64 chunk calls, each repeating the full
walk instead of reusing the previous one, ~1900 total sector reads for
one binary load — the "is this actually stuck?" scare from the previous
entry.

**Fix**: a single-slot cache in `ext2.c3` — `ext2_cache_valid`/
`ext2_cache_path`/`ext2_cache_inode_num` — remembers the last path
`ext2_read_at` resolved. A hit skips straight to `ext2_read_inode`
(still re-read fresh from disk every call — cheap, one block read, and
correctness-safe even if something else mutated the file between two
chunk calls of the same `exec()` loop, rather than assuming nothing else
writes during exec()). One slot, not a table: one `exec()` read loop only
ever re-reads one path. Every ext2 mutation (`ext2_write`/`ext2_delete`/
`ext2_delete_recursive`/`ext2_mkdir`/`ext2_rename`) invalidates the cache
unconditionally as its first statement, rather than checking whether it
actually touched the cached path — simpler, and `ext2_delete_recursive`
in particular never reconstructs path strings for what it removes, so
there's nothing to compare against there anyway. Cost of the
unconditional approach is only ever a hit-rate one (an unrelated
mutation mid-`exec()`-loop costs one extra resolve on the next chunk,
then it's a hit again), never a correctness one.

`ext2_read` (the non-chunked, single-call read path) is untouched —
never called in a loop, so there's no repeated-resolve cost to remove,
and leaving it out of the cache avoids a plain `fs_read()` from one
process evicting another process's mid-`exec()` cache slot for no
benefit.

**FAT32 has the identical bug, arguably worse** (`fat32_read_file_at`
re-walks the cluster chain from the start every chunk call too — an
O(offset/cluster_size) walk that gets *more* expensive each successive
chunk, unlike ext2's flat O(depth)). Flagged, not fixed here — the right
shape is different (resume from a remembered cluster+offset, not an
inode number) and deserves its own entry.

**Verification**: full regression suite on all three QEMU images
(single-mount ext2, single-mount FAT32, dual-mount) — every existing
test still passes, including `fspermtest` run *between* two `runtest2`/
`elftest2` calls on the dual-mount image specifically to prove
invalidation works (fspermtest's own writes/deletes invalidate the
cache mid-suite; the following `runtest2`/`elftest2` still correctly
re-resolve `/2/bin/echod` from scratch and pass). Three-boot stress
batch, `e2fsck -n -f` clean on both the single-mount and dual-mount
ext2 images, `fsck.vfat -n` clean on the dual image's FAT32 half (same
pre-existing free-cluster-count cosmetic warning this project has always
had there, untouched by this entry).

**Real Milk-V Duo hardware confirmation**, against the real `EXT2TEST`
partition — `runtest2`/`argvtest2`/`pathtest2`/`elftest2` all `ok`,
`lsproc` clean afterward. Noticeably but not dramatically faster than
the previous entry's "is this actually stuck?" run — expected, not a
red flag: `ext2_read_inode` still re-reads fresh from disk on every
single chunk by deliberate design (the correctness tradeoff described
above), so this cache only removes the directory-walk portion of each
chunk's cost, roughly halving the block reads per chunk rather than
eliminating almost all of them. The walk itself (the part that scaled
with path depth and was the actual source of the near-1900-sector-read
total) is gone.

**Files changed:** `user/fs/ext2.c3`.

---

## 2026-08-21 (45) — `runtest2`/`argvtest2`/`pathtest2`/`elftest2`: proper mount-2 re-verification

Follow-up to the previous entry's own discovery: `runtest`/`argvtest`/
`pathtest`/`elftest` all use bare, unprefixed paths (`"bin/echod"`,
etc.), exactly the same class of bug `fspermtest` just had — so every
earlier "confirmed against real `EXT2TEST`" claim for this test family,
and the single-indirect-block feature's own hardware confirmation two
entries back, almost certainly exercised `DUOBOOT`/FAT32 instead
whenever both are mounted, which is always true on real hardware.
Closes that out properly instead of leaving it flagged.

**New `/2/`-prefixed variants**, not edits to the originals:
`runtest2`/`argvtest2`/`pathtest2`/`elftest2` (`shell.c3`) are
near-identical copies of `runtest`/`argvtest`/`pathtest`/`elftest`,
differing only in the path(s) they target — `"/2/bin/echod"` instead of
`"bin/echod"`, `/env/PATH` set to `"/2/nonexistent/:/2/bin/"` instead of
`"nonexistent/:bin/"` for `pathtest2`. The originals stay exactly as
they were, still useful for testing whichever filesystem is the
*default* mount (which is genuinely FAT32 on real hardware, genuinely
ext2 on QEMU's own single-mount ext2 image) — this isn't a case where
the old versions were simply wrong and got replaced, they test a real,
different thing (mount 1) than the new ones (mount 2, unambiguously).

**`scripts/build.sh`'s dual-mount image** (`disk_dual.img`, backing
`scripts/launch64_dual.sh` — the one QEMU config that actually matches
real hardware's own topology, both filesystems mounted at once) never
seeded `bin/echod`/`bin/echod.elf` onto either half at all; the new "2"
variants needed them reachable at `/2/bin/echod`/`/2/bin/echod.elf`
specifically. Added to the ext2 half's own scratch-image seeding step,
alongside its existing `hello.txt`/`subdir`/`emptydir` fixtures.

**Verification**: all four new tests on QEMU's dual-mount image, full
regression suite there too (mount-1 tests correctly report
`FAILED (exec load failed)` on this image — its own FAT32 half was
never seeded with `bin/echod`, a pre-existing gap unrelated to this
entry, not a regression), the single-mount images' own original tests
reconfirmed unaffected, a three-boot stress batch, `fsck.vfat -n`/
`e2fsck -n -f` clean on the dual image's own two halves.

**Real Milk-V Duo hardware confirmation**, against the real `EXT2TEST`
partition — `runtest2: ok`, `argvtest2: ok`, `pathtest2: ok`,
`elftest2: ok`, `lsproc` clean afterward (no leaked slots). Two real
things surfaced getting there, neither a bug in this entry's own code,
both worth recording:

- **The seeding round-trip itself silently missed the real device
  once.** The scratch script that copies `bin/echod`/`bin/echod.elf`
  onto `EXT2TEST` addressed it by a guessed mountpoint path
  (`/run/media/$USER/EXT2TEST`) — `udisksctl mount` doesn't always
  reuse that exact path; a stale mount/label already claiming it makes
  udisks pick `EXT2TEST1` instead. `mkdir -p`/`cp` against the stale,
  now-wrong path silently succeeded (created a directory on the *host's
  own root filesystem*, not the device), and `ls -la` "confirmed" files
  that were never on the SD card at all. First re-verification attempt
  failed with the exact same `FAILED (exec load failed)` shape this
  whole entry exists to properly test, for a completely mundane reason.
  Fixed by resolving the mountpoint from the device (`findmnt -n -o
  TARGET /dev/sdc2`) instead of a guessed label path, refusing to
  proceed if it isn't actually mounted, and verifying the write
  independently afterward via `debugfs -R "ls -l /bin"` straight
  against the block device — bypasses the mount entirely, so it can't
  be fooled the same way twice.
- **Reading a real multi-chunk file over `/2/` on real hardware is
  legitimately slow, easy to mistake for a hang.** `ext2_read_at`
  (entry 41) does a completely uncached walk from root on *every*
  `fs_read_at()` call — re-resolving `/2/bin/echod`'s directory chain
  and both inodes from scratch each time — and each call only carries
  ~1124 bytes (`FS_MSG_MAX-4`). Loading `echod` (71648 bytes) took
  ~64 chunk calls, each doing ~5 block reads instead of 1, ~1900 sector
  reads total just for one binary — visibly the same handful of
  physical block addresses cycling on the serial console, easy to
  mistake for an infinite loop. It wasn't one — `runtest2: ok` arrived
  after waiting it out. Never surfaced before because every prior
  real-hardware exec test used files well under one chunk. Not fixed
  here (out of scope for a re-verification entry), but worth a real
  entry later: caching the resolved dir/leaf inode across one exec()'s
  own read loop instead of re-walking the path on every chunk would
  turn this from O(chunks × depth) block reads into O(chunks + depth).

**Files changed:** `user/shell.c3`, `scripts/build.sh`.

---

## 2026-08-21 (44) — `fspermtest` confirmed on real hardware — after finding it was never really testing ext2 at all

Follow-up to the previous entry, but a real bug-hunt, not a clean
confirmation. First hardware run: `fspermtest: FAILED` — both denial
checks ("overwrite root-owned file as non-owner", "delete...")
**wrongly succeeded**. Added debug prints inside `ext2_write`/
`ext2_delete`'s own enforcement branch and in `fsd.c3`'s
`proc_info()` lookup; rebuilt, reflashed, reran — and *none of the new
prints appeared at all*, even though the code they're inside of must
have run for the write/delete to return success in the first place.
That was the actual clue: the ext2 branch was never being reached.

Root cause, confirmed by reading `src/process.c3`'s own default
namespace setup and `SYS_NS_RESOLVE`'s longest-prefix match
(`src/entry.c3`): the unprefixed catch-all mount (`""`) binds to
whichever `fsd` was created *first* — `DUOBOOT`/FAT32 on this board,
not `EXT2TEST`/ext2 — any time both are mounted, which is always true
on real hardware (confirmed from this exact board's own boot log:
`fsd: FAT32 mounted...` then later `fsd: ext2 mounted...`). `fspermtest`'s
own `fs_write("owner_only.txt", ...)` (no `/2/` prefix) was resolving
straight to FAT32 the whole time — which has no uid concept to enforce
by design, so every write/delete just succeeded unconditionally. Not a
bug in the enforcement logic itself (which the debug prints, once
`/2/`-prefixed, showed working exactly as designed) — the test was
just never reaching the code being tested. QEMU's own single-mount
ext2 test image (`scripts/launch64_ext2.sh`) made the bare-path version
look correct purely by accident: ext2 happens to be the *only*, and
therefore default, mount there, so the same bare path that silently
hit FAT32 on real hardware correctly hit ext2 on that specific QEMU
image. Fixed by prefixing every path in `fspermtest` with `/2/` — the
same convention `readfile2`/`newfile2`/etc. already established for
exactly this reason — and re-verifying against QEMU's own dual-mount
image (`scripts/launch64_dual.sh`), which matches real hardware's own
topology, not the single-mount one.

**A real, unresolved implication this surfaces**: `runtest`/`argvtest`/
`pathtest`/`elftest` (and the previous entry's own "confirmed... against
real `EXT2TEST`" claim) all use bare, unprefixed paths too
(`"bin/echod"`, etc.) — meaning those real-hardware confirmations were
almost certainly *also* silently hitting `DUOBOOT`/FAT32 instead of
`EXT2TEST`, the same way `fspermtest` just was. FAT32 has no
12-direct-block limit at all, so those runs passing proves nothing
about whether the single-indirect-block work (two entries back) was
ever actually exercised on real ext2 hardware. Flagged directly to the
user rather than silently corrected — deciding whether/how to
re-verify those four tests and that claim against real `EXT2TEST`
(most likely via new `/2/`-prefixed `...2` variants, matching this same
fix) is a separate decision, not made unilaterally here.

**Verification**: `fspermtest` on QEMU's dual-mount image, repeated
across a three-boot stress batch, `lsproc` clean, `e2fsck -n -f` clean
on the ext2 half; the single-mount ext2 image's own full regression
suite reconfirmed unaffected; real Duo hardware, against the actual
`EXT2TEST` partition this time, confirmed via the same debug prints
that proved the original failure — removed once the fix was confirmed
end to end.

**Files changed:** `user/shell.c3`.

---

## 2026-08-20 (43) — Real ext2 file permissions (`i_uid` + owner/other write bits)

Closes the other gap the process-ownership permission-model entry
explicitly deferred: ext2 has real on-disk `i_uid`/permission bits
`Ext2_inode_info` never read — `mode`'s *type* bits (`EXT2_S_IFREG`/
`EXT2_S_IFDIR`) were always parsed, but its *permission* bits weren't,
and `i_uid` wasn't read at all. `ext2_create_file` already writes a
sensible default (`EXT2_S_IFREG | 0x1A4`, 0644) into every new file's
own `mode` — the permission bits were already being written correctly,
just never enforced coming back.

**Scope, matching this session's own established discipline**: gate
*overwriting an existing file* and *deleting a file* (non-recursive) by
ownership — root or the file's own owner (subject to `EXT2_S_IWUSR`),
or anyone else if `EXT2_S_IWOTH` allows it. No group concept
(racccoon's own process-uid model has none), no directory-permission
modeling (creating a file isn't gated by its directory's own
permissions, unlike real Unix), no recursive-delete enforcement (would
need checking every file it touches) — all explicit, not silently
dropped. Creating a new file (or an empty directory) stays
unrestricted, but gets stamped with its creator's real uid, so
*subsequent* writes to it are correctly gated.

**The same backdoor shape `procd` already had**: `fsd.c3` (always
root) is what actually calls `ext2_write`/`ext2_delete`/`ext2_mkdir` on
a caller's behalf — enforcing against `fsd`'s own uid would enforce
nothing. Closed the same way the `/proc/ctl` "kill" backdoor was:
`fsd.c3` already captures `from` (the real requester, via
`ipc_recv_type_gen`); before dispatching to the ext2 backend
specifically, it looks up the requester's uid via `proc_info(from, null, null, &requester_uid)`
(the 4-out-param version the permission-model entry added) and passes
it through. A failed lookup (the requester's own process already gone,
a real if rare race) fails closed to a sentinel (`0xFFFFFFFF`) that
never matches a real uid and is never root. FAT32's own write/delete
paths are untouched — its on-disk format has no uid concept at all to
enforce against.

**Found during implementation, not anticipated in planning**:
`ext2_delete` (non-recursive) already handled both a regular file *and*
an empty directory — meaning `ext2_mkdir`'s own newly-created
directories needed the same creator-uid stamp `ext2_create_file` gets,
or a directory's own creator could never `rmdir` it again once this
landed. Threaded through the same way.

**Test**: new shell command `fspermtest` — the shell (root) creates a
file directly, `rfork()`s a child that drops to uid 42 and must fail at
both overwriting and deleting it, then must fully succeed at creating,
overwriting, and deleting a file of its own (proving owner access
works and that creation really stamps the right uid, not just that
denial works). No IPC handshake needed this time: `fs_write()`/
`fs_delete()` are already synchronous, and `join()` (real Plan-9-style
— blocks until the joined process is actually gone) is exactly the
"wait for the child to be genuinely done" this needs, simpler than
`permtest`'s own IPC-based signal.

**Verification**: full regression suite unaffected (every existing
process is uid 0 by inheritance, so every existing ext2 write/delete
test keeps hitting the root-bypass path unchanged) plus `fspermtest`,
run repeatedly with `lsproc` showing no leaked slots, a three-boot
stress batch, `e2fsck -n -f` clean.

**Files changed:** `user/fs/ext2.c3`, `user/fsd.c3`, `user/shell.c3`.

---

## 2026-08-20 (42) — ext2 single-indirect blocks confirmed on real Milk-V Duo hardware, against real `EXT2TEST`

Follow-up to the previous entry: `runtest`/`argvtest`/`pathtest`/
`elftest` all pass against the real `EXT2TEST` partition on the real
C906 core, `lsproc` clean afterward — the first time any of these four
tests has run against real ext2 hardware at all (earlier real-hardware
sessions this session only ever exercised them against `DUOBOOT`/FAT32,
`EXT2TEST` staying untested for this family since seeding its `bin/`
fixtures needs root). Seeded via a one-off `sudo` script copying
`build/user/echod.bin`/`echod.elf` onto `EXT2TEST/bin/`, the same
fixtures `scripts/build.sh` already seeds onto the QEMU ext2 image.

**Files changed:** none (hardware verification only).

---

## 2026-08-20 (41) — ext2: single-indirect block support (read-only)

`ext2.c3`'s own header comment has always been explicit: "Direct block
pointers only (i_block[0..11])... single/double/triple indirect blocks
are NOT walked." That gap had, by this point in the session, blocked
four different tests — `runtest`/`argvtest`/`pathtest`/`elftest` — from
working on the ext2 test image, each failing cleanly rather than
crashing (a real, correct fix from earlier this session), but a real,
recurring limitation rather than a one-off. Closed for reads.

With this project's own `ext2_block_size=1024` (confirmed from its own
boot logs), 12 direct blocks cover 12KB; one single-indirect block adds
`1024/4=256` more block pointers — 268 blocks total, 268KB, comfortably
past racccoon's own ~70KB binaries (`echod.bin`/`echod.elf`).
Single-indirect alone is enough; double/triple stay out of scope, same
as before.

**One resolver, shared by both read paths**: `Ext2_inode_info` gained
an `indirect_block` field (`i_block[12]`, the 13th on-disk pointer
`ext2_read_inode` used to stop copying before), and a new
`ext2_resolve_block(inode, b, indirect_cache, indirect_loaded)` —
direct for `b < 12` unchanged, lazily reads the indirect block (once
per read, cached across the loop) and indexes into it for
`12 <= b < 12 + ext2_block_size/4`. Both `ext2_read` and
`ext2_read_at`'s own block loops now call this instead of indexing
`inode.block[b]` directly, with their upper bound raised from `12` to
`12 + ext2_block_size/4` to match. A `0` result within that range stays
unambiguous — a genuine ext2 sparse hole, zero-filled exactly like a
direct block always has been, including when `indirect_block` itself
is unset (every pointer within it reads as 0, same as an
entirely-unallocated indirect block would). Beyond that range, the
loop simply stops — the same "short read, not an error" discipline the
old 12-block limit already had, just at a higher boundary.

**Read-only, matching what's actually motivated**: nothing in the
current test suite writes a file bigger than 12 blocks, so
`ext2_write`/`ext2_write_inode` keep their own existing 12-direct-block
limit unchanged — explicitly scoped out, not silently dropped, noted
in the file's own header comment.

**Verification**: `runtest`/`argvtest`/`pathtest`/`elftest` all flip
from `FAILED (exec load failed)` to passing on ext2 — the direct,
motivating proof. Full regression suite (ext2-backed reads included)
unaffected — direct-block behavior is unchanged. All four newly-passing
tests run repeatedly across a three-boot stress batch, `lsproc` clean
throughout, `e2fsck -n -f` clean.

**Files changed:** `user/fs/ext2.c3`.

---

## 2026-08-20 (40) — ELF loading confirmed on real Milk-V Duo hardware

Follow-up to the previous entry: `elftest: ok` on the real C906 core
(`DUOBOOT`/FAT32) alongside `runtest` re-confirmed, `lsproc` clean
afterward. The multi-segment, per-segment-permission-union staging and
the real `e_entry` redirect both hold outside QEMU's emulation.

**Files changed:** none (hardware verification only).

---

## 2026-08-20 (39) — ELF loading for `SYS_EXEC`

Closes the last item flagged in the original exec() plan: "no ELF
loading... a real ELF loader is a substantially bigger, separate
project." `SYS_EXEC` can now load real ELF64/RISC-V executables, not
just racccoon's own flat-binary format.

**Confirmed via `llvm-readelf` before writing any code** that this
would be a genuinely non-trivial loader, not a hand-wave: racccoon's
own toolchain output (`build/user/echod.elf`, before `objcopy` strips
it to the flat binary the rest of this session's `exec()` work used)
has 3 `PT_LOAD` segments with 3 different permission combinations
(`.text` R-E, `.rodata` R, `.data`+`.bss` RW), and the last segment's
`memsz` (0x10150) far exceeds its `filesz` (0x30) — a real `.bss` gap
that must be zero-filled, not read from the file. Segments 0 and 1 are
even adjacent enough to share one physical page
(`0x1001000-0x1001fff`) with *different* permissions each — a real
case a hand-crafted test fixture would have had to specifically
manufacture, and this one didn't need to.

**Detection**: `SYS_EXEC` (`src/entry.c3`) sniffs the magic bytes
(`\x7FELF`) at the top of its case; `exec()`'s own user-mode wrapper
(`user.c3`) is completely unchanged — it already just reads bytes and
hands them over, no format opinion of its own. Both the ELF and
flat-binary paths converge on the same shared tail this session
already built (argv staging, old-image teardown, TLB flush,
`saved_sepc` redirect). Kept inlined in the switch like every other
case here, not factored into a helper — a documented, proven
constraint of this codebase (an unexplained c3c compiler bug: "a call
out to a moderately complex function from inside this switch has
reproducibly broken boot before"), so this makes the case long but
consistent with the existing pattern rather than a deviation from it.

**Validation before trusting anything**: `ELFCLASS64`, little-endian,
`ET_EXEC` only (rejects `ET_DYN`/PIE — would need real relocation
processing, out of scope), `EM_RISCV`, segment count bounded, program
headers bounds-checked against the real buffer size before a single
byte of any header is trusted. Per `PT_LOAD` segment: `filesz <= memsz`,
`vaddr`/`memsz` bounded without risking overflow, source range checked
against the actual file size — any failure aborts before any
staging/teardown, same "fail toward not losing what's already there"
discipline the image/argv staging already established.

**Staging, one real wrinkle**: a page-table entry can't grant
partial-page permissions, but `echod.elf`'s own segments 0/1 genuinely
share a page with different flags — confirmed above, not hypothetical.
Fixed by unioning every touching segment's own permission flags into
that page rather than letting the last one silently win, tracked in a
new parallel `exec_seg_perm[]` array alongside the existing
`exec_staged[]`. `alloc_pages()` already zero-fills every page it hands
back (confirmed in `src/allocation.c3`) — the `.bss` gap and any
inter-segment page padding come out correctly zeroed for free.
`exec_page_count` became "highest touched page index + 1" rather than
a plain size-derived count, so a genuine gap between segments stays
unmapped, not silently zero-filled — the mapping loop now skips any
untouched slot.

**Entry point**: `e_entry`, not an assumed `USER_BASE` — validated to
land on a page a real segment actually staged, then used for the
redirect. For racccoon's own binaries this happens to equal `USER_BASE`
anyway (confirmed via `llvm-readelf -h`), but a real loader shouldn't
assume that.

**Test**: `elftest` (`shell.c3`) — same `rfork`+sync+`exec`+"ready"
handshake `runtest` already established, execs `bin/echod.elf` (the
real ELF, seeded by `scripts/build.sh` alongside the existing flat
`bin/echod`) instead of the flat binary, same "hi echod" echo check.
One naming wrinkle found immediately: the fixture was first seeded as
`bin/echod_elf`, which doesn't fit FAT32's 8.3 short-name format —
mtools generated an `ECHOD_~1` alias this driver's simple 8.3
converter (`fat32_name_to_8_3`, a plain 8-character truncation, no LFN
support) can't reproduce, so the lookup failed before `SYS_EXEC` ever
ran. Renamed to `bin/echod.elf` (5+3 characters, fits 8.3 exactly, no
alias needed).

**Verification**: full regression suite (through `permtest`)
unaffected — the flat-binary path is untouched code, only reached when
the magic-byte check fails — plus `elftest` on both filesystems
(`FAILED (exec load failed)` on ext2, the same pre-existing
12-direct-block limit `runtest`/`argvtest`/`pathtest` already hit
there), run repeatedly with `lsproc` showing no leaked slots, a
three-boot stress batch, `fsck.vfat -n`/`e2fsck -n -f` clean.

**Files changed:** `src/entry.c3`, `scripts/build.sh`, `user/shell.c3`.

---

## 2026-08-20 (38) — `permtest` confirmed on real Milk-V Duo hardware

Follow-up to the previous entry: every `permtest` sub-check (`setuid()`
drop, then the four denied attempts: direct `kill()`, re-`setuid(0)`,
`srv_post()` hijack, and the `/proc/ctl` path) passes on the real C906
core, alongside `killtest` re-confirmed (root killing root through the
now-permission-checked procd path), `lsproc` clean afterward.

**Files changed:** none (hardware verification only).

---

## 2026-08-20 (37) — A real permission model: process ownership (`uid`)

Closes a gap flagged in this kernel's own code, not just a plan
document: `SYS_KILL` and `SYS_SRV_POST` (`src/entry.c3`) both carried
comments explicitly saying "no permission check... this kernel has no
user/permission concept at all, so restricting *which* caller can act
on *which* target would be security theater, not a real boundary."
This closes that gap for exactly the two places it was flagged.

**`Process.uid`** (`src/process.c3`): every boot-time server
(`create_process()`) is explicitly root (uid 0), the same "explicit,
not relied-on zero-init" reasoning already used for `parent_pid`.
`SYS_RFORK` copies it into the child unchanged, same as
`parent_pid`/`parent_generation`; `SYS_EXEC` doesn't touch it at all —
same pid, same namespace, same uid, matching everything else that
already survives `exec()` unchanged.

**`setuid()`** (new `SYS_SETUID`) is the *only* privilege primitive
added, deliberately minimal: sets the caller's own uid, and only while
still root — once dropped, permanent, no way back up. No login, no
credentials, just the standard `fork()` + child-calls-`setuid()`
idiom. Without it every process would stay root forever by
inheritance and the new checks below would never actually deny
anything.

**`SYS_KILL`** now requires root or the same uid as the target.
**`SYS_SRV_POST`** now requires root or the same uid as the *current,
live* holder of a name — but only when reclaiming one; a first-time
claim (free slot) stays unrestricted, nothing to protect yet, and a
name whose old holder is actually dead is still the "server restart"
case, also unrestricted.

**The backdoor this would otherwise leave wide open**: found while
tracing `killtest`'s own existing test — it kills through
`user/procd.c3`'s `/proc/<pid>/ctl` `FS_WRITE` handler, which calls the
raw `kill()` syscall *as procd itself*, and procd is a boot-time
server, always root. Gating only the raw syscall would leave
`/proc/<pid>/ctl` as a complete, ungated root-kill-as-a-service
backdoor around the entire model: any process, any uid, writes "kill"
and it always succeeds, since the kernel only ever sees procd's own
uid, never the real requester's. Fixed in `procd.c3` itself, not the
kernel — matching this codebase's existing split between mechanical
kernel syscalls and policy living in user-mode servers (e.g. `fsd.c3`'s
own `FS_READ_AT` wire-format handling). `proc_info()` gained a 4th
out-param, `uid_out` (switching its wrapper from the plain 3-arg
`syscall()` to `syscall4`, same shape `fs_read_at` already uses for its
own 4th argument — safe to widen this one directly rather than adding
a new syscall number the way `SYS_IPC_RECV_GEN` did, since `proc_info()`
has exactly one real caller-set, updated in this same change, not an
ABI with independent consumers). procd's "kill" handler now looks up
both the real requester's uid (`from`, already captured by
`ipc_recv_type_gen`) and the target's before ever calling `kill()`, and
refuses the write otherwise.

**Test**: new shell command `permtest` — three processes: the shell
(root), a "victim" child (inherits root, posts itself as `"victim"`,
then spins forever, same shape `killtest`'s own spin-child already
uses), and an "attacker" child that drops to uid 42 then tries, and
must fail at, every angle: `kill()` directly, `setuid(0)` again
(re-escalation), `srv_post("victim")` (hijacking its name), and the
`/proc/<pid>/ctl` "kill" path — the one that would silently succeed
without the procd-side fix above. The parent confirms the victim
genuinely survived every attempt (`proc_info()`, not just trusting the
attacker's own error codes) before killing it itself, root's own
legitimate path.

**Explicitly out of scope, and why**: `SYS_IPC_SEND`/`SYS_IPC_REPLY` —
servers must stay reachable by any caller, gating message delivery
would break this kernel's whole "everything is a server anyone can
talk to" model, not fix a real gap. `SYS_NS_MOUNT`/`SYS_NS_UNMOUNT` —
already correctly self-scoped (only ever touches the caller's own
namespace). Real filesystem permission bits — ext2 actually has
on-disk `i_uid`/`i_gid` that this driver has always deliberately never
read (confirmed via direct survey of `Ext2_inode_info`); wiring real
per-file ownership through fsd's wire protocol is a separate, much
larger project. Any login/user-database concept — this kernel has
none, `uid` stays an opaque identity, not a name, matching Plan 9's
own minimal approach.

**Verification**: full regression suite (`killtest` included — still
root killing root through the now-checked procd path) plus `permtest`,
both filesystems, `permtest` run repeatedly with `lsproc` showing no
leaked slots; a three-boot stress batch; `fsck.vfat -n`/`e2fsck -n -f`
clean.

**Files changed:** `src/process.c3`, `src/entry.c3`, `user/user.c3`,
`user/procd.c3`, `user/envd.c3`, `user/shell.c3`.

---

## 2026-08-20 (36) — `exec_path()`/`pathtest` confirmed on real Milk-V Duo hardware

Follow-up to the previous entry: `pathtest: ok` on the real C906 core
(`DUOBOOT`/FAT32), alongside `runtest`/`argvtest` re-confirmed in the
same boot, `lsproc` clean afterward. The deliberately-wrong-first-
prefix search (`"nonexistent/:bin/"`) genuinely exercises multi-prefix
resolution on real hardware, not just QEMU's own timing.

**Files changed:** none (hardware verification only).

---

## 2026-08-20 (35) — `$PATH`-style `/bin` lookup for `exec()`

Closes the last item the exec() plan flagged explicitly out of scope:
`runtest`/`argvtest` both hardcode `"bin/echod"` — there was no way to
name a program by its bare filename and have it resolved against a
real search list.

**`exec_path()`** (`user.c3`) is a separate function, not a mode of
`exec()` itself — matching Unix's own split between `execve()` (exact
path) and `execvp()` (`$PATH`-searched); `exec()` keeps its current,
unambiguous "run exactly this file" meaning. It tries a colon-separated
search list of directory prefixes in order, building each full
candidate path and calling the existing `exec()` with it — since
`exec()` only ever returns on failure, the loop naturally moves to the
next prefix.

**The search list is `/env/PATH`**, not a new mechanism: real Plan 9
doesn't have `$PATH` at all (it uses namespace binds/union directories,
which this kernel's filesystem backends don't support), but `$PATH`-
style search is what was actually asked for, and this session already
built exactly the right per-process configuration mechanism for it
(`/env`, `user/envd.c3` — including lazy inheritance across `rfork()`).
Reusing it beats inventing a second one. No `/env/PATH` set falls back
to a single hardcoded default, `"bin/"` — matching every existing test
fixture's own path exactly, so callers that never touch `/env/PATH` see
identical behavior for free. (One small wrinkle: `envd.c3`'s own
`ENV_VALUE_MAX` isn't actually reachable from `user.c3` — each server
is its own separate `c3c` compilation, scripts/build_user.sh builds
each from its own source list, and `user.c3` is the only file they all
share. `exec_path()` has to carry its own matching constant,
`PATH_VAR_MAX`, rather than importing the real one.)

**Test**: new shell command `pathtest` sets `/env/PATH` to
`"nonexistent/:bin/"` — a deliberately wrong first prefix — before
`rfork()`, so the child inherits it, then calls
`exec_path("echod", ...)`. Success is only possible if `exec_path()`
genuinely tried the first prefix, failed, and moved to the second, not
just that the correct-by-default fallback still works.

**Verification**: full regression suite plus `pathtest`/`runtest`/
`argvtest`, `pathtest` run repeatedly with `lsproc` showing no leaked
slots; a three-boot stress batch; `fsck.vfat -n`/`e2fsck -n -f` clean;
`pathtest` fails the same clean way on ext2 that `runtest`/`argvtest`
already do there (the driver's pre-existing 12-direct-block limit, not
a new gap).

**Files changed:** `user/user.c3`, `user/shell.c3`.

---

## 2026-08-20 (34) — `argv` confirmed on real Milk-V Duo hardware

Follow-up to the previous entry: `argvtest: ok` and `runtest: ok` on
the real C906 core (`DUOBOOT`/FAT32), `lsproc` clean afterward (only
the six always-on servers plus the shell, no leaked slots from either
test's own child). The register-repurposing (`a0`/`a1` as `argc`/argv
base instead of a syscall return value), the `just_execd` check's
`>= 0` adjustment, and `user_entry()`'s explicit zeroing all hold
outside QEMU's emulation, not just on it.

**Files changed:** none (hardware verification only).

---

## 2026-08-20 (33) — `argv` at exec() time

Closes a gap the exec() plan flagged explicitly out of scope: a
freshly-exec'd process previously had no way to learn what it was
supposed to do beyond `/env` — no `argc`/`argv` at all.

**Wire format**: `exec()`'s caller already owns a buffer the image gets
read into (`user.c3`) — argv strings get packed right after the image
content, in that same buffer, NUL-separated (`"foo\0bar\0"` for
`argc=2`). Real pointers wouldn't survive being copied into a brand new
address space, so a flat, self-describing blob is the only thing that
can cross that boundary. `exec()` gained two parameters (`char** argv`,
`int argc`); the one existing caller (`runtest`, `shell.c3`) now passes
`null, 0`, unchanged behavior.

**`SYS_EXEC`** (`src/entry.c3`) stages the argv blob as a second,
smaller pass of the same page-staging loop already used for the image
(new `EXEC_MAX_ARGV_SIZE`, 4096 bytes — plenty for real CLI args), maps
it right after the image's own last page (`ARGV_BASE`), and hands the
new process `argc`/`ARGV_BASE` via `a0`/`a1` — repurposing the same
registers a normal syscall would use for its return value, safe here
because control never returns to the caller on success (the
`saved_sepc` redirect from last session's own fix means that
return-value-reading code never executes). This needed one adjustment
to that same fix: `handle_trap()`'s `just_execd` check used to test
`f.a0 == 0` to detect a successful `SYS_EXEC`; now that `f.a0` carries
`argc` (which can legitimately be nonzero), the check became
`(long)f.a0 >= 0` — a real failure still sets `-1`, so the distinction
still holds.

**Getting it into a real `main()`**: existing binaries' `main()`
signatures stay untouched — most don't care about argv, and this
codebase has no default-parameter syntax to make an extra param free.
`start()` (`user.c3`, naked asm, already confirmed to leave `a0`/`a1`
untouched from `sret` through to `call main`) stashes both into two new
globals before calling `main()`. A new, opt-in `get_argv()` lazily
parses that blob into a small static pointer array on demand — only a
caller that actually wants its own argv reaches for it.

**Boot-time processes needed a real fix, not just an omission**:
`user_entry()` (`src/process.c3` — the trampoline `create_process()`
uses for a never-yet-run process) never touched `a0`/`a1` before its own
`sret`, leaving whatever the kernel's own boot-time code last put there
in the physical registers. Every `create_process()`'d server would have
read that leftover garbage as if it were a real argv blob pointer.
Fixed by explicitly zeroing both there, so every boot-time process
(echod, diskd, fsd, procd, envd, shell) gets a deterministic `argc=0`.

**Test**: `echod.c3` now calls `get_argv()` at startup; if `argc > 0`,
`argv[0]` replaces its hardcoded `P9_TREAD` canned reply (its raw-echo
behavior, what `runtest` checks, is unchanged either way). New shell
command `argvtest` — same `rfork`+sync+`exec`+"ready" handshake
`runtest` already established, reused rather than duplicated in spirit
(each is its own small copy, this codebase's own established pattern
for inline `rfork()` test children) — execs `bin/echod` with one real
argument, then confirms it actually arrived via a `P9_TREAD` round trip
matching that argument, not just that `exec()` returned success.
`p9test` (the existing command exercising `P9_TREAD` against boot-time
echod, pid 2, argc=0) still gets the original hardcoded reply,
confirming `user_entry()`'s zeroing holds.

**Verification**: full regression suite plus `argvtest`/`runtest`, both
run repeatedly in the same boot with `lsproc` showing no leaked slots
afterward; a three-boot stress batch; `fsck.vfat -n`/`e2fsck -n -f`
clean on both test images; `argvtest` on ext2 fails the same clean way
`runtest` already does there (the driver's own 12-direct-block limit,
`echod.bin` exceeds it — a pre-existing, documented limitation, not new
here).

**Files changed:** `user/user.c3`, `src/entry.c3`, `src/process.c3`,
`user/echod.c3`, `user/shell.c3`.

---

## 2026-08-20 (32) — `exec()`/`runtest` confirmed on real Milk-V Duo hardware

Follow-up to the previous entry: built `kernel_duo.elf`, packaged
`fip_duo.bin`, seeded `bin/echod` onto the real `DUOBOOT` FAT32
partition (same file `build/user/echod.bin` QEMU's own test images use),
flashed via the existing `scripts/flash_duo.sh` convention (`fip.bin` as
a literal file on `DUOBOOT`, not a raw `dd`). `runtest` on real hardware:
`runtest: ok` — the `saved_sepc`-clobber fix, the TLB flush, and the
IPC-race fix from the previous entry all hold on the real C906 core, not
just QEMU's emulation. Didn't seed `EXT2TEST` this round — writing there
needs root (the partition's owned by `root` on this machine) and the
outcome is already known from QEMU: `echod.bin` exceeds ext2's own
12-direct-block limit, so it would just fail the same documented way.

**Files changed:** none (hardware verification only).

---

## 2026-08-20 (31) — `/bin`: a real `exec()` syscall, and three real bugs found chasing it

The first real `/bin` support: a Plan-9/Unix-style `exec()` that replaces
the *calling* process's own image in place — same pid, same page table,
same namespace (so `/env`'s own vars survive it unchanged, matching real
`exec()` semantics) — composing with `rfork()` exactly the way Unix
`fork()`+`exec()` do. Getting the feature itself in place was the easy
part; getting it to actually *work* took three separate, genuinely
different bugs, each hiding the next one.

**The feature, in shape:**
- **`FS_READ_AT`** (`user.c3`, wire verb 26): a new, distinct verb rather
  than widening `FS_READ` — same reasoning as `SYS_IPC_RECV_GEN` over a
  widened `SYS_IPC_RECV` earlier this session. Real binaries are
  70-105KB; `FS_READ`'s one-message-per-call shape (`FS_MSG_MAX`=1128
  bytes) can't load one at all. `fat32_read_at`/`fat32_read_file_at` and
  `ext2_read_at` (`user/fs/*.c3`) add offset-aware reads alongside the
  existing offset-0 versions, left untouched; `fsd.c3` dispatches the
  new verb the same shape as the old one, plus the offset field.
- **`SYS_EXEC`** (`src/entry.c3`, syscall 24): takes an already-fully-read
  image + size (the read happens user-side, in `user.c3`'s own `exec()`,
  before this syscall ever runs — a failed read never risks the calling
  process's *existing* image). Stages every new page first (a failed
  allocation leaves the old image untouched), only then frees the old
  image's `PAGE_U` leaves and maps the new ones, then redirects
  execution by setting `saved_sepc = USER_BASE`.
- **`exec()`** (`user.c3`): loops `fs_read_at()` until EOF or the
  caller's buffer is exhausted, then calls `SYS_EXEC`. Buffer is
  caller-owned (a large static buffer in `user.c3` itself would bloat
  every binary that links it, whether or not it ever calls `exec()`).
- **`runtest`** (`shell.c3`): `rfork(RFPROC)`s a child that execs
  `bin/echod` — a real, already-built binary (`build/user/echod.bin`,
  known behavior, already exercised at boot as pid 2), seeded onto both
  test images by `scripts/build.sh` from the already-built binary rather
  than writing a new one just for this.

**Bug 1 — `saved_sepc` clobbered right after being set.** First real
symptom: `runtest` panicked with an illegal-instruction trap inside what
should have been the new image, at an offset that was legitimately
zero-filled `.bss` in the real file on disk — meaning execution was
landing somewhere it should never reach via normal control flow. Ruled
out data corruption directly: a checksum of the full chunked read,
mirroring `exec()`'s own read loop exactly, matched the real file
byte-for-byte. The actual cause was one layer up, in `handle_trap()`
(`src/entry.c3`): every syscall unconditionally sets
`current_proc.saved_sepc = user_pc + 4` *after* the syscall's own switch
case returns, to resume right past the `ecall` that made it — correct
for every syscall except this one, where the whole point is to resume
somewhere else entirely. `SYS_EXEC`'s own case was setting
`saved_sepc = USER_BASE` correctly; this line ran right after and
silently overwrote it back to the old image's own address, so execution
kept resuming inside the *old* code (in this case the old image's own
`.bss`, past the point that old code ever legitimately jumped to)
instead of the new one. Fixed by capturing the syscall number before
`handle_syscall()` runs and skipping the `+4` specifically when it was a
successful `SYS_EXEC` — a one-line, syscall-specific exception is the
whole fix, but it took a full checksum-verification pass to rule out
*where it wasn't* before finding it.

**Bug 2 — a real IPC race, exposed for the first time by this feature.**
Once `exec()` correctly replaced the image, `runtest`'s own
synchronization hung. Root cause: `SYS_IPC_RECV`'s single inbox slot per
process has no per-sender filtering (`src/entry.c3`) — delivery happens
the instant the slot is free, regardless of which conversation the
receiver thinks it's in. Every earlier test's child does exactly one
IPC conversation before reaching a stable state (`srvtest`'s child posts
and goes straight into its serve loop); `runtest`'s child is the first
to have a *second* conversation of its own (the `FS_READ_AT` round trips
to `fsd`, inside `exec()`) still in flight while an outside process
might message it. The test's own initial "ping immediately after
rfork" could land mid-round-trip and get misread as `fsd`'s reply,
corrupting `exec()`'s own read loop.

Two-part fix. `p9_call()` (`user.c3`, the client-side request/reply
helper every 9P-lite caller funnels through) now checks the reply's
actual sender against `dest_pid`; a message from anyone else gets
bounced back to *its own* sender as a new reserved verb, `P9_STRAY`,
rather than being misread as the real reply — this protects every
existing `p9_call` user, not just this one. A retry-with-backoff version
of `runtest` built on top of that bounce was tried and rejected: `fsd`'s
own round trip through `diskd` for a deep offset (this driver's
offset-skip walks clusters/blocks one at a time — see `FS_READ_AT`'s own
comment) can run longer than any fixed backoff, so the retries just kept
re-winning the race against `fsd`'s real reply, forever. Fixed properly
instead by removing the race altogether: `exec()` gained an optional
`notify_pid` parameter — right after its last `fs_read_at()` and before
the point of no return, it sends that pid one message. `runtest`'s
parent does a `srvtest`-style initial sync (proving the child is alive
before sending anything else), then blocks on exactly that one
notification before ever messaging the child again — by the time it
arrives, the child is guaranteed to never talk to `fsd` again, so no
race is possible. (The child also has to report an *unsuccessful*
`exec()` this same way — found by testing the ext2 case below: a failed
load never sends "ready" on its own, and the parent was blocking on it
forever.)

**Bug 3 — ext2's own real scope limit, now actually reachable.**
`runtest` against the ext2 test image (`scripts/launch64_ext2.sh`)
didn't hang — it panicked with a store page fault, `sepc` right at the
top of the new image's own `user.syscall` stub. `ext2_read_at`
(`user/fs/ext2.c3`) only ever reads this driver's 12 direct blocks (no
indirect-block chain — the same limit `ext2_read()` has always had); for
an offset past block 11 it returned `0` (clean EOF) instead of an error,
since nothing had ever asked it to read that far before — every existing
fixture is well under 12KB. `echod.bin` (70KB) is the first file this
driver was ever asked to read past that point. `exec()`'s own read loop
trusts `0` completely and stops there, so it installed a genuinely
truncated image — the copy itself wasn't corrupted, but `__stack_top`
(a link-time constant baked into the binary regardless of how much of
it actually got loaded) pointed past the pages `SYS_EXEC` had mapped.
Fixed by having `ext2_read_at` return `-1` when the offset is genuinely
within the file but past what this driver can reach, so `exec()` fails
cleanly instead of installing a truncated image. `runtest` now correctly
reports `FAILED (exec load failed)` on ext2 rather than crashing the
kernel — a real, standing limitation of this driver (no indirect-block
support), not something worth building out for this feature alone.

**Verification:** full regression suite plus `runtest`, both filesystems
— clean on FAT32 (`runtest: ok`, `lsproc` shows no leaked slots even run
repeatedly in the same boot), clean *failure* on ext2 for the reason
above. Three-boot stress batch. `fsck.vfat -n`/`e2fsck -n -f` both clean
(FAT32's lone "free cluster summary" mismatch is the pre-existing,
already-documented FSInfo-caching quirk this driver has always had, not
new).

**Files changed:** `user/user.c3`, `user/fsd.c3`, `user/fs/fat32.c3`,
`user/fs/ext2.c3`, `src/entry.c3`, `src/process.c3` (`flush_tlb()` —
`SYS_EXEC` remaps this process's own live virtual addresses without a
`satp` write, so `switch_context`'s own TLB flush never fires for it;
needed regardless of the three bugs above, since a stale mapping would
otherwise let the CPU keep serving the *old* image's translations),
`scripts/build.sh`, `user/shell.c3`.

---

## 2026-08-20 (30) — EXT2TEST fixtures restored, closing out the flashing-incident recovery

Follow-up to the previous entry: the full repartition there left
`EXT2TEST` freshly formatted but empty — the standard fixture set
(`hello.txt`, `subdir/nested.txt`, `emptydir/`, `nestdir/inner.txt`,
`nestdir/innerdir/inner2.txt`) needed restoring before the `"/2/"`-
targeting regression commands (`readfile2`/`readsubfile2`/`newfile2`/
`newsubfile2`/`deletetest2`/`rmdirtest2`) had anything real to exercise.
Restored via `debugfs -w` directly on the block device — the exact
same technique, and the exact same source files (`disk-ext2/hello.txt`,
`disk-ext2/subdir/nested.txt`), `scripts/build.sh` already uses to seed
`build/disk_ext2.img` for QEMU.

**Confirmed on real hardware afterward**: `fsd`'s own idempotent `/tmp`
auto-create had already fired on first mount against the freshly-seeded
filesystem (a `tmp/` directory present with an epoch timestamp, seen in
the post-seed directory listing, before any test explicitly touched
it) — real, independent confirmation that mount-time write logic runs
correctly against a genuinely fresh filesystem, not just the QEMU test
images this codebase has run it against so far. Then the full `"/2/"`
suite itself: all six commands correct, content byte-matching what was
seeded (`"Hello from ext2!"`, `"Hello from an ext2 subdirectory!"`),
dynamic write/read/delete/rmdir all clean.

This closes out the recovery from the previous entry's flashing
mistake — `EXT2TEST` is back to full parity with what a from-scratch
`scripts/build.sh` run produces for QEMU, confirmed by direct
real-hardware exercise rather than assumed from the seed step alone.

---

## 2026-08-20 (29) — Real Duo hardware: everything since /srv confirmed, and a real flashing lesson

Every feature from this session — `/srv`/`/tmp`/`/proc` (read + write),
`SYS_KILL`, the reply-side stale-pid IPC fix, rename-cycle detection,
real `SYS_SRV_POST`/`SYS_NS_MOUNT` dynamic namespace binding, `/env`
(including lazy inheritance), and the `std::nolibc` stdlib port — run
on the real Milk-V Duo now, not just QEMU. `envtest`/`srvtest`/
`killtest`/`mkdirtest`/`renametest`/`movetest`/`cycletest`/`racetest`/
`mutextest` all match QEMU exactly, including edge cases (`killtest`'s
re-kill-of-a-dead-pid and bogus-ctl-command checks). `mutextest`
specifically is the first real-hardware run of `std::nolibc::atomic`'s
actual RV64 `lr.w`/`sc.w`/`amoadd.w` instructions, not just QEMU's own
emulation of them — real hardware confirmed the same 16/16 result.

**A real flashing mistake, corrected**: got this board's own flashing
convention wrong on the first attempt — assumed a generic "raw `dd` to
disk offset 0" convention without checking this project's own
documented history first. The actual, already-established convention
(confirmed back in the `2026-08-17 (6)` entry, from this exact board's
own real-hardware bring-up) is different: BootROM reads `fip.bin` as a
literal *file* inside the `DUOBOOT` FAT32 partition's own filesystem,
not a raw region before it. `DUOBOOT` itself starts at sector 2048
(`board::FS_PARTITION_START_SECTOR`), not sector 0 — a raw
`dd if=fip.bin of=/dev/sdX bs=1M` starting at offset 0 overwrites the
MBR/partition table instead, which is exactly what happened
(`lsblk` afterward showed zero partitions where `DUOBOOT`/`EXT2TEST`
used to be). Recovered with a full repartition (`sfdisk` recreating
both partitions at their exact original sectors/sizes, `mkfs.vfat`/
`mke2fs`, then copying `fip.bin` onto `DUOBOOT` the correct way) — full
data loss on the card's test fixtures, but the board itself was never
at risk (the corrupted region was purely the SD card's own partition
table, nothing written to the chip's own boot ROM/flash).

**New `scripts/flash_duo.sh`**: the correct, safe, repeatable flash
step (mount `DUOBOOT`, copy `fip.bin` onto it as a file, unmount) —
doesn't touch partitioning or existing filesystem content, safe to run
after every rebuild. Doesn't attempt to fix a missing partition table;
that needs the same manual `sfdisk`/`mkfs.vfat`/`mke2fs` recovery this
entry describes, and it's destructive enough (wipes whatever's
currently on the card) that it isn't worth automating into a script
that runs unattended.

**Files changed:** `scripts/flash_duo.sh` (new).

---

## 2026-08-20 (28) — std::racccoon -> std::nolibc, gated by a real opt-in feature

Two refinements to the previous entry's `std::racccoon::*` module,
both in the c3c fork (`~/Workspace/c3c`, still uncommitted there —
deliberately, same as before), prompted by wanting something less
project-branded and more genuinely reusable.

**Location**: tried moving `mem.c3`/`atomic.c3`/`fmt.c3` to live inside
the *real* canonical files (`lib/std/core/mem.c3`, `lib/std/atomic.c3`)
as additional `@feat`-gated blocks, matching how `core/mem.c3` already
keeps its `FREESTANDING_WASM`/`NO_LIBC` variants in one file. Tested
directly and it doesn't work: those real files have *unconditional*
top-level imports (`std::core::mem::allocators`, `std::os::posix`,
`std::math`, `std::io`) that fail immediately when the file is passed
as a standalone source argument under `--use-stdlib=no`, regardless of
any `@feat` gate further down — confirmed by literally trying it, not
assumed. This is exactly *why* the real stdlib's own freestanding
pieces (`_nolibc/nolibc.c3`, `_nolibc/math_nolibc/`) are separate,
self-contained files rather than gated blocks in the main ones — same
constraint, same answer. So: renamed the *module path* instead —
`std::racccoon::{mem,atomic,fmt}` -> `std::nolibc::{mem,atomic,fmt}`,
staying physically in `lib/std/_nolibc/` (not nested under a
project-branded subdirectory anymore).

**Gating**: switched from the ambient `@feat(NO_LIBC)` (automatically
active for *any* freestanding build, not just racccoon's) to an
explicit `@feat(RACCCOON)`, activated only via a new `-D RACCCOON` flag
in `scripts/build_user.sh`'s own `c3c compile-only` call. Verified both
directions directly: compiles and produces the expected
`std.nolibc.mem.o`/`std.nolibc.fmt.o` (atomic's generics inline into
the caller, as before) with `-D RACCCOON` present; every symbol from
all three modules is completely unreachable (`'mem::copy' could not be
found`) without it. This means the module can sit in the fork's shared
stdlib tree without silently activating for some *other* freestanding
project built against the same fork that never opted in — dormant by
default, not by convention.

**Verified**: full regression suite clean on both filesystems
(`mutextest` again exercising the real hardware atomics through the
renamed/re-gated module), a 10-boot stress batch clean, `e2fsck -n -f`/
`fsck.vfat -n` clean after.

**Files changed:** `scripts/build_user.sh` (`-D RACCCOON`,
`RACCCOON_STD_DIR` default path updated), `user/user.c3`/`procd.c3`/
`shell.c3`/`envd.c3`/`fsd.c3`/`diskd.c3`/`fs/ext2.c3` (imports and
qualified call sites updated to `std::nolibc::*`). Outside this repo:
`~/Workspace/c3c`'s `lib/std/_nolibc/{mem,atomic,fmt}.c3` renamed from
`std::racccoon::*` and re-gated (still uncommitted there).

---

## 2026-08-20 (27) — Moving the stdlib adaptation into std::racccoon, in a real c3c fork

Took the previous entry's `user/mem.c3`/`user/atomic.c3`/`user/fmt.c3`
one step further: instead of vendoring copies per-project, they now
live as `std::racccoon::mem`/`std::racccoon::atomic`/`std::racccoon::fmt`
in a real c3c stdlib tree — the user's own fork
(github.com/8lall0/c3c) — reachable via a plain `import` like any other
stdlib module, no more per-binary file-list copying.

**The fork was stale first**: `origin/master` had zero commits of its
own (a plain mirror that fell behind, not a real divergent fork) —
turned out to be a clean ancestor of upstream's own `v0.8.3` tag, so
fast-forwarding it was risk-free and landed on the *exact* commit
racccoon's system-installed `c3c` already builds with (confirmed by
git hash, not just version string). Rebuilt natively (`cmake`+`ninja`,
already available — no need for the fork's own Docker-based
`build.sh`) after fixing a stale `CMakeCache` (wrong compiler paths)
and an LLVM version conflict (auto-detected LLVM 20 instead of the
system's actual 22.1.8, explicit `-DLLVM_DIR` fixed it) — confirmed
byte-identical version/hash/LLVM-version parity with the system binary
before touching anything else.

**New module, `lib/std/_nolibc/racccoon/`**: same content as the three
vendored files, moved under `std::racccoon::*` names (couldn't reuse
`std::atomic::types`/`std::core::mem` — those names are already taken
by the real modules in the same tree), gated `@feat(NO_LIBC)` matching
`std::nolibc`/`std::core::mem`'s own convention — confirmed empirically
(not assumed) that `NO_LIBC` is exactly the feature racccoon's user-mode
binaries already activate under their existing `--link-libc=no` flag.

**A real trap avoided**: the first instinct was "enable `--use-stdlib`
for user-mode binaries" — testing that directly showed it pulls in far
more of the real stdlib than expected (`std::io`, `libc.os`,
`std::math`, a dozen other modules), none of which this freestanding
link step can handle. The actual fix needed no flag change at all:
passing the new files as explicit source arguments — exactly how
`user/user.c3` has always been included — works under the *existing*
`--use-stdlib=no`, producing only the object files actually needed.
Verified the compiled output directly: real RV64 atomic instructions
(`lr.w.aqrl`/`sc.w.rl`/`amoadd.w.aqrl`), correctly exported
`memcpy`/`memset`/`memcmp` symbols.

**Wired in**: `scripts/build_user.sh` gained a `RACCCOON_STD_DIR`
variable (overridable, defaulting to the fork's checkout path — a real,
disclosed machine-specific dependency, not portable elsewhere without
setting it) pointing at the new module; every `build_user_program` call
now sources `atomic.c3`/`mem.c3`/`fmt.c3` from there instead of `user/`.
`user/atomic.c3`/`mem.c3`/`fmt.c3` deleted. Every consuming file needed
an explicit `import std::racccoon::...` (unlike `std::core::mem`,
`std::racccoon` isn't implicitly visible) and its call sites qualified
(`fmt::format_uint`, not bare `format_uint` — `mem::copy`/`mem::set`
were already qualified).

**Verified**: full regression suite clean on both filesystems
(`mutextest` specifically exercises the real hardware atomics through
the new module), a 10-boot stress batch clean, `e2fsck -n -f`/
`fsck.vfat -n` clean after.

**Scope note**: the c3c fork itself is left with these new files
uncommitted, deliberately — that's the user's own repository and their
call when to commit there, not something to do automatically alongside
a racccoon commit.

**Files changed:** `scripts/build_user.sh` (`RACCCOON_STD_DIR`, source
lists updated), `user/atomic.c3`/`mem.c3`/`fmt.c3` (deleted),
`user/user.c3`/`procd.c3`/`shell.c3`/`envd.c3`/`fsd.c3`/`diskd.c3`/
`fs/ext2.c3` (imports added, call sites qualified). Outside this repo:
`~/Workspace/c3c` fast-forwarded to `v0.8.3`, new
`lib/std/_nolibc/racccoon/{mem,atomic,fmt}.c3` (uncommitted there).

---

## 2026-08-20 (26) — Revisiting the c3 stdlib adaptation: mem::copy/set, and consolidating format_uint

Returned to an early-session goal (adapting the real c3 stdlib into
this project) that had only gotten as far as `user/atomic.c3`
(`std::atomic::types`, for the futex/`Mutex` work). User-mode binaries
build with `--use-stdlib=no` (`scripts/build_user.sh`) — the real
stdlib isn't reachable from them at all, so "adapting" means the same
thing `atomic.c3` already established: port a small, self-contained
piece under the real module name, so it's a drop-in as far as any code
using it is concerned.

### `user/mem.c3`: `mem::copy`/`mem::set`, ported not reinvented

The real stdlib already has exactly the right piece to copy from:
`std::core::mem`'s own `@feat(NO_LIBC)` block
(`/usr/lib/c3c/lib/std/core/mem.c3`) — plain C-style `__memcpy`/
`__memset`/`__memcmp`, no allocator, no OS dependency, already written
for exactly this situation. Copied over near-verbatim (only real change:
`CInt` isn't reachable under `--use-stdlib=no` either, swapped for
plain `int`), plus `copy()`/`set()` as ordinary functions rather than
the real stdlib's macro-based `mem::copy()`/`mem::set()` (those lower
through `$$memcpy`/`$$memset` compiler builtins tied to stdlib
machinery this build doesn't have reachable) — giving user-mode code
the exact same `mem::copy(dst, src, len)` call shape the kernel side
already uses everywhere via the real module.

Replaced seven scattered hand-rolled fixed-length byte-copy loops with
it: two near-identical 100-byte path-buffer copies (`procd.c3`,
`envd.c3`), one in `fsd.c3`, two `SECTOR_SIZE` sector-data copies
(`diskd.c3`), one 64-byte env-var-value copy (`envd.c3`'s own
inheritance code, entry (25) above), and two 48-byte (12×`uint`)
inode-block-pointer copies (`ext2.c3`'s `ext2_read_inode`/
`write_inode`) — left every loop that does more than a pure fixed-
length copy (null-terminator early exit, case transformation) alone,
those aren't the same operation.

### String/format helpers: a real mismatch, handled honestly

Went looking for the same treatment for `strcmp`/`str_copy`-shaped
helpers and integer formatting — found it doesn't fit. The real
stdlib's string utilities (`std::core::string`) are built entirely
around `String`/`ZString` value types (length-tracked, allocator-
aware), and this codebase is plain-`char*` C-strings throughout;
porting `String.compare_to`/`starts_with` would mean dragging in
supporting infrastructure just to reach `strcmp`-shaped functionality
— a worse trade than what's already there. Same story for integer
formatting: the real stdlib's number-to-string logic lives inside
`std::io`'s `Formatter`, an allocator/stream-based subsystem, not a
small standalone function. Reported this rather than forcing a bad-fit
port.

**What *was* real**: `print_uint()` (`user.c3`), `procd_format_uint()`
(`procd.c3`), and `killtest_format_pid()` (`shell.c3`) were three
near-identical copies of the same decimal-digit-extraction loop, each
hand-copied because every binary is a separate build unit with nothing
shared. Consolidated into one `format_uint()` (new `user/fmt.c3`,
explicitly *not* claimed as a stdlib port — this is racccoon's own
logic, just finally written once). Net effect across the affected
files: 94 lines removed, 22 added.

**Verified**: full regression suite clean on both filesystems
(including `readsubfile`/`newsubfile` specifically exercising the
`ext2_read_inode`/`write_inode` block-pointer copy, content confirmed
byte-identical to the old loop), a 10-boot stress batch clean,
`e2fsck -n -f`/`fsck.vfat -n` clean after.

**Files changed:** `user/mem.c3` (new), `user/fmt.c3` (new),
`scripts/build_user.sh` (both added to every binary), `user/procd.c3`/
`envd.c3`/`fsd.c3`/`diskd.c3`/`fs/ext2.c3`/`user.c3`/`shell.c3`
(hand-rolled loops replaced).

---

## 2026-08-20 (25) — /env inheritance across rfork, lazily

The one gap `/env` shipped with, closed the same session: a forked
child used to start with a completely empty environment. Real
inheritance would need the kernel to notify `envd` when a fork happens
— no precedent anywhere in this codebase for the kernel initiating an
IPC send to a server from inside another process's syscall handling,
and genuinely a much bigger, riskier mechanism than the actual problem
needs. Didn't need it: `envd` inherits **lazily**, the first time it
ever sees a request from a given `(pid, generation)`, by asking who
that process's parent is and copying that parent's *current* vars once.

**One small kernel addition**: `Process.parent_pid`/`parent_generation`
(`src/process.c3`) — 0 means no parent, the state every
`create_process()`'d process starts in (explicitly zeroed there on
every call, same "a reused slot must never leak a previous occupant's
data" discipline this session restored for ext2's directory slots and
`Mount`/`Srv_entry`'s generation checks, applied here before it could
bite). `SYS_RFORK`'s existing child-population block sets both, right
alongside where it already sets `child.pid`/`child.generation`. New
read-only `SYS_PARENT_INFO` syscall (next free number, 23) exposes it —
same no-permission-check shape as `SYS_PROC_INFO`.

**`envd.c3`: a real reserved-name convention**. `".inherited"` — a
leading `.`, mirroring Unix dotfiles — records "already handled this
process instance" so `env_maybe_inherit()` never re-runs, without a
second parallel tracking table. `FS_READ`/`FS_WRITE`/`FS_DELETE` now
all refuse any `.`-prefixed name outright, and `FS_LIST` filters it out
of what it shows the caller — a real mechanism now exists for future
internal markers, not just this one. Inheritance itself is a one-time
snapshot at first `/env` touch, not a live link, matching real Plan 9's
own copy-on-fork semantics: neither side's later writes propagate to
the other.

**Extended `envtest` in place** rather than adding a new command: the
child now reads `"GREETING"` *first*, before overwriting it, and checks
it already reads back the parent's pre-fork value — proving inheritance
actually ran — then proceeds exactly as before (overwrite with its own
value, parent's own copy unaffected afterward).

**Verified**: full regression suite (`envtest`'s extended check
included) clean on both filesystems, run repeatedly back-to-back
confirming no leaked process/env slots, a 10-boot stress batch clean,
`e2fsck -n -f`/`fsck.vfat -n` clean after.

**Files changed:** `src/process.c3` (`Process.parent_pid`/
`parent_generation`, `create_process()`'s explicit reset), `src/entry.c3`
(`SYS_RFORK`'s child-population, new `SYS_PARENT_INFO`), `user/user.c3`
(`parent_info()`), `user/envd.c3` (`.`-prefix reserved-name guard,
`env_maybe_inherit()`), `user/shell.c3` (`envtest` extended).

---

## 2026-08-20 (24) — /env: per-process environment variables, zero new syscalls

The last item on the original `/srv`/`/tmp`/`/proc` plan's explicitly-
out-of-scope list: "genuinely separate, much larger subsystems... with
no existing racccoon mechanism to build on." With `/proc`'s read-only
core, `/proc/<pid>/ctl` (the first `FS_WRITE` reuse), and real dynamic
namespace binding all landed since then, `/env` turned out to need
**no new syscalls at all** — a complete read/write/list/delete
filesystem-shaped feature built entirely out of verbs
(`FS_READ`/`FS_WRITE`/`FS_LIST`/`FS_DELETE`) this codebase already had,
on a synthetic server exactly like `procd`.

### Per-process privacy via the sender's own verified pid

Real Plan 9's `/env` is a private per-process kernel device (`#e`) —
racccoon has no per-process device concept and doesn't need one here:
every request `envd` (new file, `user/envd.c3`) receives already
carries the sender's kernel-verified `(pid, generation)` via
`ipc_recv_type_gen()` (`SYS_IPC_RECV_GEN`, two entries back),
unforgeable by the requester. Keying `env_table` by `(pid, generation,
name)` and only ever matching a request's own `(from, from_gen)` gives
genuine per-process isolation for free — no new kernel mechanism, just
the same generation-safety discipline `Mount.server_generation`/
`Srv_entry.generation` already established elsewhere. A pid reused by
an unrelated process simply never matches its predecessor's leftover
vars again; they become permanently inert clutter under a stale
generation, exactly the same shape `Mount`/`Srv_entry` already treat a
stale binding.

**Slot reclamation, learned from the ext2 investigation rather than
repeated**: a bounded table that only ever reclaims on exact-name-match
(fine for `srv_table`'s handful of long-lived named services) would
leak real capacity here, since env vars churn per-process. `FS_WRITE`
needing a fresh slot on a full table scans for one whose owner is no
longer live (`proc_info()` — already used by `procd.c3` — returning
`-1`, or a live generation that no longer matches) before ever
reporting "full" — the same "don't silently degrade after N
operations" bar the ext2 directory-slot-reuse fix set, applied here
before it could bite instead of after.

### Wiring

Same shape as `procd`'s own integration: `envd_pid` global
(`src/process.c3`), a 5th static default-namespace slot (`"/env/"`),
spawned unconditionally right after `procd` in `kernel.c3` (no storage-
hardware dependency, same reasoning). `NS_MOUNTS_MAX` stayed at 8 — 5
static entries now, still 3 spare for `SYS_NS_MOUNT`.

### `envtest`'s isolation proof

Round-tripping a var (write/read/list/delete) is the easy half; the
part that actually matters is proving two processes' vars under the
*same name* don't collide. `rfork(RFPROC)`s a child that sets its own
`"GREETING"` to a different value than the parent's; the parent's own
var, re-read afterward, must come back exactly what the parent itself
wrote. Used the same direct-message-to-the-child's-own-known-pid
handshake `srvtest` had to learn the hard way two entries back (not a
busy-retry — the timer only fires once per real second) to synchronize
before checking.

**Verified**: full regression suite (`envtest` included) clean on both
filesystems, `envtest` run repeatedly back-to-back confirming
idempotent overwrite-in-place and no leaked process/env slots
(`lsproc` after), a 10-boot stress batch (`envtest` twice per boot plus
the rest of the suite) clean on both filesystems, `e2fsck -n -f`/
`fsck.vfat -n` clean after.

### Explicitly out of scope

**No inheritance across `rfork`** — a forked child starts with a
completely empty env, unlike real Plan 9 where children typically
inherit their parent's. Would need `envd` to observe fork events,
which nothing currently notifies it of — a real, separate mechanism
change, not attempted here. The most Plan-9-surprising limitation of
this slice. Also no env groups/`bind`-able sub-namespaces (a single
flat namespace per process, same "not the full `ctl`/`mem`/`fd`/`ns`
set" scoping `/proc` already accepted) and no cross-process env
access by design (that's what makes it private, not another
`srv_table`).

**Files changed:** `user/envd.c3` (new), `src/process.c3` (`envd_pid`,
5th namespace slot), `src/kernel.c3` (spawn `envd`), `scripts/
build_user.sh`/`build.sh`/`build_duo.sh` (`envd` added to the build),
`user/shell.c3` (`envtest`).

---

## 2026-08-20 (23) — Real srv-post + mount: dynamic namespace binding

The last piece explicitly deferred when `/srv`/`/tmp`/`/proc` were built:
the namespace has always been populated exactly once, identically for
every process, at `create_process()` time — no way for a server to
register itself at runtime, no way for a client to bind it afterward.
`SYS_NS_UNMOUNT` already existed (remove one of the *caller's own*
mounts by exact prefix), but there was never an add-a-new-binding
counterpart.

### The two-step

A new, small **kernel-global** registry (`src/process.c3`) — deliberately
separate from `Mount`/namespace, which is per-process and path-keyed:
posted servers are discoverable *by name*, globally.

```c3
struct Srv_entry { char[SRV_NAME_MAX] name; int pid; uint generation; }
Srv_entry[SRV_MAX] srv_table;
```

**`SYS_SRV_POST`** (next free syscall number, 21) posts `current_proc`
under a short name — always self, no pid argument, matching Plan 9's
"you post your own connection" semantics. Idempotent by name, same
"already exists is fine" shape as `fat32_mkdir`'s own `/tmp` auto-create:
posting the same name again just rebinds the entry in place.

**`SYS_NS_MOUNT`** (22) looks the name up, validates it's still live
(the exact same `proc_by_pid` + generation-match check `SYS_NS_RESOLVE`
already does for existing mounts — a stale/dead post is treated as "not
found," never silently handed back), and adds `prefix -> (pid,
generation)` into the *calling* process's own namespace. Idempotent by
exact prefix, same convention `SYS_NS_UNMOUNT` already uses.
`NS_MOUNTS_MAX` grew 5->8: the 4 static mounts left only 1 spare slot,
not enough real headroom for dynamically-added ones.

### A real bug in the first version of the test, not the feature

`srvtest` (new shell command) `rfork(RFPROC)`s a child that posts itself
as `"echo2"` and serves like echod. The first version had the parent
busy-retry `ns_mount()` up to 100000 times, betting on real preemption
(the same reasoning `killtest`'s spin-child relies on) to eventually let
the child run and post. It silently never worked: `srv_mounted` stayed
`-1` every time, `ns_resolve` fell through to the `""` catch-all (fsd),
the parent's `ipc_send`/`ipc_recv` round-trip against the *wrong* pid
left it permanently blocked — and because a permanently-blocked parent
plus its still-serving-nothing child left zero runnable non-idle
processes, `kernel_main`'s own respawn loop silently spun up a *fresh*
shell, which is what kept accepting the next typed command with no
visible hang or crash at all.

Root cause, found by adding checkpoint prints: the timer interrupt only
fires once per full real *second* (`arm_timer(board::TIMEBASE_HZ)`,
`src/entry.c3`) — a tight loop of nothing but fast, non-blocking
`ns_mount()` syscalls can easily finish well under that, so the child
never got a single scheduling opportunity. `killtest`'s own spin-child
gets away with a bare loop only because the *parent* side there makes
several real blocking `fs_read`/`fs_write` calls to fsd in between,
which is what actually drives scheduling — not the timer, and not
`killtest`'s spin loop itself.

**Fixed** by replacing the retry loop with a direct message to the
child's own already-known pid (`srv_r`, straight from `rfork`'s return
value — no namespace involved) before ever touching `ns_mount`.
`SYS_IPC_SEND`'s blocking rendezvous wait calls the kernel's internal
`yield()` on every failed check — the same mechanism every other
blocking-IPC test in this suite already relies on for real scheduling.
Since `srv_post()` is the child's very first statement, by the time it
reaches its own `ipc_recv_type_gen()` to consume this sync message, the
post has already happened — `ns_mount` then succeeds on the very first
try, no retry needed at all.

**Verified**: full regression suite (`srvtest` included) clean on both
filesystems, `srvtest` run repeatedly back-to-back with `lsproc`
confirming no leaked process slots (the `kill()` cleanup at the end
genuinely works), a 10-boot stress batch (`srvtest` twice per boot plus
the rest of the self-cleaning suite) clean, `e2fsck -n -f`/`fsck.vfat -n`
clean after.

**Files changed:** `src/process.c3` (`Srv_entry`/`srv_table`,
`NS_MOUNTS_MAX` 5->8), `src/entry.c3` (`SYS_SRV_POST`, `SYS_NS_MOUNT`),
`user/user.c3` (`srv_post()`, `ns_mount()`), `user/shell.c3` (`srvtest`).

---

## 2026-08-20 (22) — Rename-cycle detection, both backends

The last confirmed, still-open gap on the list from the last few
entries: `fat32_rename`/`ext2_rename` (introduced when directory
listing/mkdir/rename landed) never detected "moving a directory into
its own subtree" — a real cycle in the directory tree. Nothing
refused it outright; only a recursion-depth cap in delete kept a
resulting cycle from causing an unbounded walk, not from being created
in the first place.

**Design, same shape on both backends**: a directory's own `".."`
entry, read directly rather than through the normal named-lookup path
— `fat32_name_to_8_3("..")`/ext2's own leaf-name handling would mangle
or mis-walk a literal `".."` (see `fat32_get_parent_cluster`'s own
comment for the FAT32-specific reason: the leading dot is treated as
the start of a file extension). Both drivers already write `".."` at a
fixed, known location when creating a directory (FAT32: the second
32-byte entry of the first cluster's first sector; ext2: `block[0]`,
offset 12 — both already read/written by rename's own existing
same-parent-vs-different-parent fixup), so the new
`fat32_get_parent_cluster()`/`ext2_get_parent_inode()` helpers just
read that fixed offset directly. A new `fat32_would_create_cycle()`/
`ext2_would_create_cycle()` walks from the destination's parent
directory up through `".."` entries — a plain bounded iteration, not
recursion — until it either reaches the root (safe) or finds the
directory being moved among its own ancestors, including itself
(a cycle: refuse). Bounded by the same `FAT32_MAX_DELETE_DEPTH`/
`EXT2_MAX_DELETE_DEPTH` constants delete's own recursion cap already
uses — reused rather than duplicated, since both express the same
"how deep a directory tree this driver is willing to trust" bound.
Only checked when the source is actually a directory — a file being
renamed/moved can never create a cycle, having no children to contain
anything.

**New shell command, `cycletest`**: builds a real 2-level nested
directory (`tmp/cyc_a/cyc_b`), then tries two ways to break it —
renaming `tmp/cyc_a` directly into itself (depth-0: the new parent
*is* the directory being moved) and into its own grandchild
`tmp/cyc_a/cyc_b` (depth-1). Both must be refused, and — the part that
actually proves the tree wasn't left half-mutated by a refused
rename, not just that `fs_rename` returned -1 — a write and read-back
against `tmp/cyc_a/cyc_b/marker.txt` afterward must still work. A
real, non-cyclic move (`tmp/cyc_a/cyc_b` out to a sibling) proves the
fix didn't just start refusing every directory rename outright.

**Verified**: full regression suite (`cycletest`/`mkdirtest`/
`renametest`/`movetest`/`deletetest`/`newfile`/`racetest`, plus a
manual pass including `rmrtest`/`writefile`/`readfile`) clean on both
filesystems, `e2fsck -n -f`/`fsck.vfat -n` clean after (FAT32's own
free-cluster-summary field stays a pre-existing, unrelated cosmetic
mismatch — confirmed by checking the driver never writes that field at
all, on either side of this change, not something this fix touched).
A 10-boot stress batch of the self-cleaning subset of the suite (not
`rmrtest`, which consumes a one-shot build-time fixture and isn't
meant to repeat across boots on the same image — a test-harness fact
rediscovered this entry, not a regression) clean on both filesystems.

**Files changed:** `user/fs/fat32.c3` (`fat32_get_parent_cluster`,
`fat32_would_create_cycle`, the check in `fat32_rename`), `user/fs/
ext2.c3` (`ext2_get_parent_inode`, `ext2_would_create_cycle`, the
check in `ext2_rename`), `user/shell.c3` (`cycletest`).

---

## 2026-08-20 (21) — Closing the reply-side stale-pid window: SYS_IPC_REPLY/SYS_IPC_RECV_GEN

`Mount.server_generation`/`SYS_JOIN` (2026-08-18 (3), and now `SYS_KILL`
too) all close the same shape of hazard on the *sending* side — a pid
number getting silently reused by an unrelated process between "I
learned this pid" and "I acted on it." One instance of that shape was
still open: a server (fsd/procd/diskd/sdd/echod) receives a request via
`SYS_IPC_RECV`, learns `msg_from`, and later replies via plain
`ipc_send(msg_from, ...)` — but `SYS_IPC_SEND`'s rendezvous completes
for the *client* the moment the server's `SYS_IPC_RECV` consumes the
message, before the server has computed or sent any reply. If the
client somehow exited (or got killed — `SYS_KILL` from the entry above
made this newly reachable, not just theoretical) in the narrow window
before its own follow-up `ipc_recv`, a server's later reply could
silently misdeliver to whatever unrelated process now occupies that
reused pid.

**Design**: two new syscalls, kept fully separate from
`SYS_IPC_SEND`/`SYS_IPC_RECV` rather than widening either — the same
"new syscall number, not a repurposed one" choice `SYS_KILL` made over
extending `SYS_EXIT`. `SYS_IPC_SEND` captures the sender's own
`Process.generation` into a new `Process.msg_from_generation` field
(`src/process.c3`) alongside the existing `msg_from`, unconditionally,
every send — free, no new call convention needed on the sending side.
`SYS_IPC_RECV_GEN` is `SYS_IPC_RECV` plus that captured generation
handed back through a new optional out-pointer; `SYS_IPC_REPLY` is
`SYS_IPC_SEND` plus an optional `expected_generation` (wildcard 0,
`SYS_KILL`'s own convention) checked against the target before
delivery. A server that wants to reply safely calls
`ipc_recv_type_gen()` instead of `ipc_recv_type()`, then
`ipc_reply(dest, ..., from_gen)` instead of `ipc_send()` — the captured
generation travels the shortest possible path, receive to reply,
closing the window down to just those two syscalls.

**Why not just widen `SYS_IPC_RECV`/`SYS_IPC_SEND` in place**: every
existing `SYS_IPC_RECV` caller only ever sets `a0`-`a2` (`user.c3`'s
plain 3-arg `syscall()` wrapper) — reading `a4` as a live out-pointer
on that *same* syscall number would mean writing through whatever
garbage register value was left over from unrelated prior code, for
every caller not yet updated to know about it. A distinct syscall
number sidesteps this entirely: the only wrapper that ever emits
`SYS_IPC_RECV_GEN` is the new one, which always sets `a4` correctly by
construction. `SYS_IPC_REPLY` needed a genuinely new argument slot
anyway (`expected_generation`, a 5th real argument) — `syscall4`'s
existing `a0`-`a2`+`a4` layout was already full (`dest_pid`/`type`/
`data`/`len`), so this is also where `syscall5` (`user.c3`, `a0`-`a2`+
`a4`+`a5`) was added.

**Migrated every server** (`fsd`/`procd`/`diskd`/`sdd`/`echod`) to
`ipc_recv_type_gen()`/`ipc_reply()` — mechanical, same shape in each:
one new `from_gen` local, `ipc_recv_type` -> `ipc_recv_type_gen`,
every `ipc_send(from, ...)` reply -> `ipc_reply(from, ..., from_gen)`.
Found two more stale comments along the way (`diskd.c3`/`sdd.c3`, both
claiming a legitimate sender could be a synthetic `KERNEL_PID` (-1)
"via `fs.c3`'s kernel-internal client" — `fs.c3` doesn't exist anymore,
removed when the filesystem moved into user-mode `fsd` — see `fsd.c3`'s
own header comment) — fixed in passing, same as the ext2 comment two
entries back.

**Known, accepted limitation, same as `SYS_KILL`'s own**: this closes
the specific *reply-misdelivery* shape, not every possible IPC-related
consequence of a pid dying mid-conversation — a process genuinely
blocked mid-rendezvous waiting on a target that then dies is still
left blocked forever either way.

**Verified**: full regression suite (`ping`/`p9test`/`nstest`/`pstest`/
`sandboxtest`/`killtest`/`rforktest`/`threadjointest`/`racetest`/
`mutextest`/`writefile`/`readfile`/`newfile`/`deletetest`/`mkdirtest`/
`renametest`/`movetest`) clean on both filesystems, a 10-boot stress
batch of the same suite all clean.

**Files changed:** `src/process.c3` (`Process.msg_from_generation`),
`src/entry.c3` (`SYS_IPC_RECV_GEN`, `SYS_IPC_REPLY`), `user/user.c3`
(`syscall5`, `ipc_recv_type_gen()`, `ipc_reply()`), `user/fsd.c3`,
`user/procd.c3`, `user/diskd.c3`, `user/sdd.c3`, `user/echod.c3`
(migrated to the generation-checked reply path).

---

## 2026-08-20 (20) — /proc/<pid>/ctl: the first write path /proc has, and a real SYS_KILL

Checking what to build next turned up three already-closed gaps before
finding real work: the `SYS_IPC_SEND` "KNOWN GAP" and the `racetest`
`a=1 b=0` race were both already fixed in the 2026-08-18 (3) entry
below (closing the stale-namespace-pid gap turned out to also explain
`racetest` was `PROCS_MAX` exhaustion, not IPC, all along); and ext2
multi-group support (flagged as a genuine gap in the 2026-08-19 (4)
entry) turned out to already be fully implemented and verified in
entries (5)/(6) the very next day — every allocation/read/write path
is group-aware. Only a stale comment survived
(`ext2_write_inode` claiming "new allocations stay group-0-only,"
contradicted by `ext2_zero_inode`'s own correct comment three lines
below) — fixed in passing.

### /proc/<pid>/ctl

The real remaining gap: procd (`user/procd.c3`) was read-only, so a
future kill-via-ctl was explicitly deferred at the time `/proc` was
built (entry (19) below). Closed now, reusing the same design insight
as `FS_READ`/`FS_LIST`: `FS_WRITE` (verb 21) is just as generic as the
other two — `user.c3`'s existing `fs_write()` reaches procd with zero
client-side changes, the same way `fs_read()`/`fs_list()` already did.

**New `SYS_KILL` syscall** (`src/entry.c3`, next free number 18):
kills an arbitrary target pid, no permission check (same reasoning as
`SYS_PROC_INFO` — this kernel has no user/permission concept at all).
Takes an optional `expected_generation` (0 = wildcard), mirroring
`SYS_JOIN`'s own `join_generation` — closes the same stale-pid race
`Mount.server_generation`/`SYS_JOIN` already close elsewhere. Inlined
in the switch, same page-table-teardown-if-not-shared logic as
`SYS_EXIT`, just targeting an arbitrary `Process*` instead of
`current_proc` (and, unlike `SYS_EXIT`, returning normally to the
caller rather than yielding away permanently). Rejects killing
yourself — `SYS_EXIT` already exists for that, and tearing down your
own running page table from inside this code path is a different,
unsafe shape. **Known, accepted limitation, documented in the case
itself**: any other process blocked mid-rendezvous waiting
specifically on the killed target (`SYS_IPC_SEND`'s own `msg_acked`
wait) is left blocked forever — nothing forcibly unblocks a waiter
when its counterpart is killed out from under it.

**procd's ctl handler** (`user/procd.c3`): `"<pid>"` now lists two
files (`status`, `ctl`) instead of one. Writing to `"<pid>/ctl"` only
recognizes one command, `"kill"` — fetches the target's live
generation via `proc_info()` immediately before calling the new
`kill()` wrapper (`user.c3`) with it, keeping the check-then-act
window as narrow as possible. Any other command, or a path whose
suffix isn't exactly `"/ctl"`, is rejected cleanly (-1), not silently
accepted.

**New shell command, `killtest`**: `rfork(RFPROC)`s a throwaway child
that spins forever (real preemptive scheduling means this doesn't
starve anything else), confirms it's alive via `/proc/<pid>/status`,
kills it via `fs_write("/proc/<pid>/ctl", "kill", 4)`, confirms the
pid is now gone. Also checks two edge cases: re-killing an
already-dead pid fails cleanly, and a bogus ctl command against echod
(pid 2) is rejected without harming it.

**Verified**: full regression suite (`ping`/`p9test`/`nstest`/
`pstest`/`lsproc`/`rforktest`/`threadjointest`/`racetest`) unaffected
on both filesystems, an 8-boot stress batch of `killtest` plus the
suite all clean, and — the real proof the page-table teardown works,
not just the state flip — `lsproc`'s own listing and `rforktest`'s
next child both confirm the killed pid's slot is genuinely reusable
afterward (`rforktest` lands its own child at the exact pid `killtest`
just freed).

**Files changed:** `src/entry.c3` (`SYS_KILL`), `user/user.c3`
(`kill()`), `user/procd.c3` (`FS_WRITE` handling, `ctl` file in
listings, `procd_skip_pid`), `user/shell.c3` (`killtest`),
`user/fs/ext2.c3` (stale comment fix, unrelated).

---

## 2026-08-20 (19) — A Plan-9-style structure: /srv, /tmp, /proc

Verifying this work is what actually turned up the previous entry's
ext2 bug: moving `mkdirtest`/`renametest`/`movetest` under the new
`/tmp` and running them repeatedly is exactly the kind of sustained
create/delete churn against one directory that had never been
exercised before.

### /srv, /tmp, /proc

**`/srv/echo/` replaces bare `"/"` for echod** (`process.c3`'s default
namespace, slot 0). The old `"/" -> echod` mount was confirmed, from
the phase-3 devlog entry, to be a pure artifact — it existed only
because `ping`/`p9test` already hardcoded pid 2 before the namespace
system existed, not from any "echod owns the root" design. `/srv` is
the real Plan 9 convention for where server processes get *named*.
Pure data + call-site change (`ping`, `p9test`, `nstest` in
`shell.c3`) — confirmed via `p9_call_path()` that a mount's prefix is
only ever used to resolve the pid, never sent over the wire. The `""`
catch-all needed no change: once nothing claims bare `/`, it
transparently catches absolute paths too.

**`/tmp`, self-created by fsd** (`fs_mount()`, both backends) rather
than baked into a disk image — `fat32_mkdir("tmp")`/`ext2_mkdir("tmp")`
right after mount, idempotent (already-exists is silently fine).
Works identically on the real Duo with zero SD card changes. Existing
dynamic test fixtures (`newfile`, `deletetest`, `mkdirtest`,
`renametest`, `movetest`) moved under `tmp/` instead of littering root.

**`/proc`, a synthetic process-info server** (`user/procd.c3`, new
process, spawned unconditionally on every board after
diskd/sdd/fsd/fsd2 so it never disturbs their existing hardcoded pid
conventions). The actual interesting design point: it speaks the
*same* `FS_READ`/`FS_LIST` wire verbs fsd already does, just
synthesizing content from a new `SYS_PROC_INFO` syscall
(`src/entry.c3`, read-only, no permission check) instead of reading
disk sectors — `user.c3`'s `fs_read()`/`fs_list()` needed zero changes
to work against it. `ls /proc` lists live pids by scanning
1..PROCD_SCAN_MAX (a generous local bound, not the kernel-only
`PROCS_MAX`) calling `proc_info()` for each; `/proc/<pid>/status`
formats a short text reply. `NS_MOUNTS_MAX` grew 4->5 for the new
`"/proc/"` mount.

**Real bug found via `lsproc` failing**: `fs_list("/proc", ...)` (no
trailing slash) doesn't contain the full `"/proc/"` mount prefix, so
it silently fell through to the `""` catch-all (fsd) instead of
reaching procd, and failed there since `/proc` isn't a real fsd
directory — both servers just return -1, so the wrong-server routing
was invisible until traced. Fixed by using `"/proc/"` in the client
call, matching `"/2/"`'s own established trailing-slash convention.

**Verified**: full regression suite on both filesystems (including
`ping`/`p9test`/`nstest`/`pstest`/`lsproc`), a 10-boot multi-boot
stress batch (2 full mkdir/rename/move cycles under `/tmp` plus the
rest of the suite each boot — see the previous entry for why that
specific combination matters), all clean.

**Files changed:** `user/procd.c3` (new), `src/entry.c3`
(`SYS_PROC_INFO`), `src/process.c3` (namespace slot 0 rename, new
`/proc/` slot, `NS_MOUNTS_MAX` 4->5, `procd_pid`), `src/kernel.c3`
(spawn procd), `user/user.c3` (`SYS_PROC_INFO`/`proc_info()`),
`user/fsd.c3` (`/tmp` auto-create), `user/shell.c3`
(`ping`/`p9test`/`nstest` namespace updates, fixtures moved under
`tmp/`, `pstest`/`lsproc`),
`scripts/build_user.sh`/`scripts/build.sh`/`scripts/build_duo.sh`
(procd added to the build).

---

## 2026-08-20 (18) — A real ext2 bug found chasing what looked like a preemption race

Running `mkdirtest`/`renametest`/`movetest` repeatedly in one boot
(real create/delete churn against the same directory) turned up ext2
corruption: orphaned, unlinked inodes, confirmed via `debugfs`. It
looked exactly like a real preemption race at first — reproduced only
when a test ran long enough to span actual timer ticks, cleared up
when debug `print()`s were added (which seemed to "fix" it by slowing
things down), and FAT32 stayed 100% clean under identical stress. All
three observations turned out to have the same, non-preemption
explanation.

**Actual root cause, found by instrumenting `diskd_rw` and
`ext2_delete_recursive`'s own return sites directly**: `diskd_rw`
never failed a single time across the entire investigation — ruling
out an I/O race outright. The real failure was
`ext2_delete_recursive`'s own `ext2_find_in_dir` call returning "not
found" — because the entry genuinely never existed. `ext2_mkdir`/
`ext2_create_file`/`ext2_rename` never reused a parent directory's own
freed block slot after a delete — clearing a directory entry only
zeroes that one dirent's `entry_inode` field, never reclaims the
*block* it lives in from the parent's `block[]` array. With only 12
direct-block slots and ~5 slots consumed per mkdir+rename+move cycle,
the test directory's own slot list is permanently exhausted after ~2-3
cycles — every later create silently fails (a clean "directory full"
refusal), and the failure never recovers because nothing ever frees a
slot.

This explains every earlier observation without preemption at all:
"more real time" just meant "more completed cycles" (more slots
consumed, hits the wall sooner); debug prints "fixing" it just meant
fewer cycles fit in the same wall-clock test duration; FAT32's own
`fat32_find_free_dirent` already scans for *either* a free *or*
`FAT32_DIRENT_DELETED` slot, so it never has this limit at all.
Confirmed directly: `ext2_create_file`/`ext2_mkdir` allocate the
child's own inode (and, for mkdir, its own "."/".." block) *before*
checking whether the parent has a free slot — so a slot-exhaustion
failure orphaned an already-fully-built child. Matches the two
corrupted-inode shapes found via `debugfs` exactly: a leaked
zero-size regular file (mode/links_count set, no blocks — exactly
what `ext2_create_file` leaves when its parent-slot check fails right
after writing the child's own empty inode) and an orphaned directory
with real content (mode/links_count/blocks all intact, matching
`ext2_mkdir` failing at the same point after fully building the
child's own directory block).

**Fix**: new `ext2_find_or_reuse_dir_slot()` helper (`ext2.c3`) —
scans a parent's existing blocks for one whose single entry was
deleted (`entry_inode == 0`) before allocating a new one, only
returning "genuinely full" once no free *or* reusable slot exists.
Used by `ext2_create_file`, `ext2_mkdir`, `ext2_rename`. Combined
with rollback (`ext2_free_inode`/`ext2_free_block` on the child) when
the parent genuinely has no room, so even a real "directory full"
never leaks — matches the `fs_write`/`fs_delete_recursive` invariant
this driver already keeps everywhere else (fail cleanly, never
partially).

**Verified**: the exact 20- and 40-cycle stress sequences that
reliably corrupted before (failing by cycle ~3 every time) now pass
100% clean — 60/60 and 120/120 test results, `e2fsck -n -f` clean at
both sizes. Full regression suite on both filesystems, all clean.

**Files changed:** `user/fs/ext2.c3` (`ext2_find_or_reuse_dir_slot`
and its three callers: `ext2_create_file`, `ext2_mkdir`,
`ext2_rename`).

---

## 2026-08-19 (17) — Directory listing, mkdir, and rename/move

Three features, all made meaningfully cheaper by infrastructure this
session already built for recursive delete (raw-entry directory
walking, the cluster/inode-zero-vs-root ".." convention, the
allocate-block-and-link-a-dirent shape `ext2_mkdir` and `ext2_rename`
both reuse). No real c3 stdlib code to adapt here the way `std::atomic`
was for the futex work — `std::io::path`'s own `ls`/`mkdir` are thin
OS-native wrappers (`os::native_*`), not portable algorithms, and there
is no `rename` in the stdlib above `libc::rename`'s raw extern
binding — so these are built idiomatically for this environment, only
borrowing the stdlib's API *shape* (an `ls` that lists, an `mkdir`
that refuses if the parent doesn't exist) as naming inspiration.

**`fat32_list`/`ext2_list`** (`FS_LIST`, new verb 23): single-reply, no
pagination (same v1-scope limit as everything else in this protocol) —
up to 31 fixed 36-byte records (32-byte name + 1-byte type + padding)
fit in one `FS_MSG_MAX` reply. FAT32's own version converts each raw
8.3 on-disk name back into a normal "NAME.EXT" display string — the
one place this driver ever hands a name back to a caller instead of
just matching against one.

**`fat32_mkdir`/`ext2_mkdir`** (`FS_MKDIR`, verb 24): creates an empty
directory, refusing if anything already exists there. Self-contained
rather than sharing `fat32_create_file`/`ext2_create_file`'s own
entry-linking logic — close in shape, but a directory needs its own
"."/".." seeded (ext2's own inode also needs `links_count = 2`, not 1,
and the *parent's* `links_count` needs its own +1 for the new
subdirectory's ".." — real extra work a plain file never needs), and
forcing that into the existing functions via a flag felt like the
wrong trade against just duplicating the shape once more, the same
choice `fat32_delete_recursive`/`ext2_delete_recursive` already made
for the same reason. ".." on FAT32 points at cluster 0 when the parent
is root — the real on-disk convention every reader expects, not
something invented here.

**`fat32_rename`/`ext2_rename`** (`FS_RENAME`, verb 25, the one verb
with two paths on the wire — old at byte 0..99, new at 100..199):
handles same-directory rename and cross-directory move uniformly by
always adding a fresh entry at the destination (reusing the source's
existing cluster/size/attr on FAT32, or just the same inode number on
ext2 — genuinely cheap there, a dirent is only ever a name -> inode
link, so a move never touches file data or the inode at all) and then
removing the source entry, new-before-old so a failure partway through
leans toward "briefly visible under both names," never "lost
entirely." Moving a directory across parents fixes up its own ".."
(both backends) and adjusts both parents' `links_count` (ext2 only).
Refuses if the destination already exists (no silent overwrite, unlike
POSIX `rename(2)`) and refuses a cross-filesystem move outright (no
copy-then-delete fallback to silently turn an atomic-looking rename
into a non-atomic one). Does not detect "moving a directory into its
own subtree" (a real cycle) — a known, documented gap, not silently
worked around; the existing recursion-depth cap on
`fat32_delete_dir_contents`/`ext2_delete_dir_contents` is the backstop
that keeps a resulting cycle from ever causing an unbounded walk, just
not from being created.

**Real bug found while testing, not by inspection**: `renametest`'s
first fixture names, `rentest_a.txt`/`rentest_b.txt` (9 characters
before the extension), silently collided under FAT32's 8.3 short-name
truncation — both truncate to the identical `RENTEST_.TXT`, so the
"destination already exists" check correctly refused every single
run. Same root cause as `nestdir`/`nesteddir` two entries ago
(`fat32_name_to_8_3`'s naive 8-character cutoff, no numeric-tail
scheme), made again here before this test's own failure caught it —
isolated via temporary checkpoint prints inside `fat32_rename` itself
(dispatched from a real `print()` call in the fsd process, not a
kernel debug path) rather than guessing. Fixed by shortening to
`ren_a.txt`/`ren_b.txt`/`mv_a`/`mv_b` (all ≤8 characters, matching
`emptydir`/`subdir`/`nestdir`'s own already-established discipline).

**Verified**: full regression suite on both `disk.img` (FAT32) and
`disk_ext2.img` (ext2) — `ls`/`lssub`, `mkdirtest`, `renametest`,
`movetest` alongside every existing command. `fsck.vfat -n`/
`e2fsck -n -f` clean on both after each new test. Unlike `rmrtest`
(previous-previous entry), `mkdirtest`/`renametest`/`movetest` all
create and clean up their own fixtures — confirmed safe to run
repeatedly against the same image, including a 10-boot stress batch
(`mkdirtest`/`renametest`/`movetest`/`ls`/`lssub`/`mutextest`/
`racetest` in sequence each boot) with zero failures. One false
alarm along the way — 8 of an initial 10 stress-batch boots came up
"kernel.elf: No such file or directory" — traced to a race in the
test harness itself (a second, separately-launched `build.sh`
deleting `build/kernel.elf` mid-loop, not a kernel bug); a clean rerun
without the concurrent rebuild passed 10/10.

**Files changed:** `user/fs/fat32.c3` (`fat32_list`, `fat32_mkdir`,
`fat32_rename`), `user/fs/ext2.c3` (`ext2_list`, `ext2_mkdir`,
`ext2_rename`, `ext2_inc_used_dirs`), `user/fsd.c3` (dispatches for
all three new verbs), `user/user.c3` (`FS_LIST`/`FS_MKDIR`/
`FS_RENAME`, `fs_list`/`fs_mkdir`/`fs_rename`), `user/shell.c3`
(`ls`, `lssub`, `mkdirtest`, `renametest`, `movetest`).

---

## 2026-08-19 (16) — Recursive delete

The other half of this session's work (see the previous entry for the
synchronization primitive) — independent of it, just landed in the
same session.

`fat32_delete_recursive`/`ext2_delete_recursive` (`user/fs/*.c3`): the
non-empty-directory case `fat32_delete`/`ext2_delete` always refused,
now actually handled instead of deferred, reusing the existing
`FS_DELETE` wire verb rather than a new one — byte 100 (already sent,
previously unused/ignored by `FS_DELETE`) is now a `recursive` flag,
so plain `fs_delete()` stays byte-for-byte non-recursive and only
`fs_delete_recursive()` opts in. Both backends walk raw directory
entries directly (cluster/sector/offset, same as their own
`*_dir_is_empty`) rather than reconstructing names into path strings
and going back through the normal lookup path for each child — FAT32
has no long-filename support to round-trip through, and ext2's dirents
don't carry a file-type byte at all (its own `ext2_find_in_dir` already
reads each child's inode to get `mode`, same thing this does). Both
cap recursion depth at 32 — not reachable through any well-formed tree
on either filesystem, but nothing on-disk actually prevents a corrupted
or adversarial image from containing a cycle, and a real one would
otherwise recurse forever and blow this process's own stack instead of
failing cleanly.

A protected entry anywhere in the subtree aborts the whole operation
before anything is freed (checked for every child during the walk, and
for the target itself) — never a partial delete that silently skips
just the protected part.

**Test fixture found the hard way**: `scripts/build.sh` seeds a new
`nestdir/` (a file plus a nested `innerdir/` with its own file) on both
the FAT32 and ext2 test images. First attempt named it `nesteddir` —
worked on ext2, silently failed to even be *found* on FAT32. Root
cause: `fat32_name_to_8_3()` does a naive 8-character truncation with
no numeric-tail scheme, while `mtools`' `mmd` generates a real
Windows-style short name (`NESTED~1`) for anything over 8 characters —
confirmed directly via a hex dump of the image. Not a bug introduced
here, a pre-existing limitation of a driver with no long-filename
support at all; the fix for this specific fixture was simply picking a
name (`nestdir`, matching `emptydir`/`subdir`'s own already-short
names) that never needs truncating in the first place.

**Also found while verifying**: `rmrtest` genuinely deletes
`nestdir` — running it more than once against the *same*, un-rebuilt
`disk.img` (e.g. in a multi-boot stress loop over one image file, the
way this session's own stress scripts drive QEMU) fails from the
second boot on, correctly — the fixture is really gone, same as any
real filesystem delete would behave. Not a bug; just means this
specific test isn't safe to include in a same-image repeat-boot stress
loop the way `racetest`/`mutextest` (neither of which touch persistent
state) are.

**Verified**: full regression suite on both `disk.img` (FAT32) and
`disk_ext2.img` (ext2), `rmrtest` (delete refused non-recursively,
succeeds recursively, second call correctly fails "not found") on
both, confirmed repeatable across several fresh rebuilds of each
image, `fsck.vfat -n`/`e2fsck -n -f` afterward as the established
correctness oracle for each backend — ext2 fully clean; FAT32's own
"free cluster summary" mismatch confirmed pre-existing (reproduces
identically from a plain `newfile` on a completely fresh image,
unrelated to this session's changes — this driver has never maintained
the FSInfo sector's cached free-count).

**Files changed:** `user/fs/fat32.c3` (`fat32_delete_recursive`),
`user/fs/ext2.c3` (`ext2_delete_recursive`), `user/fsd.c3` (dispatches
on the new recursive flag), `user/user.c3` (`fs_delete_recursive`, the
wire-format comment), `user/shell.c3` (`rmrtest`), `scripts/build.sh`
(`nestdir/` test fixture on both test images).

---

## 2026-08-19 (15) — A real synchronization primitive: futex + Mutex

Explicitly enabled by real preemption existing now (previous-previous
entry): user code can genuinely race on shared memory for the first
time, so it needs a real way to protect it.

**Adapted, not reinvented, from the real c3 stdlib's `std::atomic`** —
`user/atomic.c3` is a trimmed, self-contained port of
`/usr/lib/c3c/lib/std/atomic.c3`'s `Atomic<Type>` (`load`/`store`/
`compare_exchange`/`add`), same module names, same API shape, same
`AtomicOrdering` enum copied verbatim so `.ordinal` still matches what
the `$$atomic_*` compiler builtins expect. Necessarily a port rather
than a straight `import`: user-mode binaries build with
`--use-stdlib=no` (`scripts/build_user.sh`), so the real module — and
what it itself depends on (`std::core::mem`'s atomic support,
`std::core::types`, `std::math`) — isn't reachable at all. Confirmed by
direct `llvm-objdump` inspection that this still lowers to real RV64
`A`-extension instructions (`lr.w.aqrl`/`sc.w.rl` for compare_exchange,
`amoadd.w.aqrl` for add), not a libcall this freestanding build has
nothing to link against.

**Kernel side**: two new syscalls, `SYS_FUTEX_WAIT`/`SYS_FUTEX_WAKE`
(15/16, `src/entry.c3`). WAIT checks `*addr == expected` and, if still
true, sets `PROC_BLOCKED` and yields; the check-then-block sequence is
atomic with respect to any concurrent WAKE for free, because kernel-mode
code is never preempted (see the previous entry) — no wake can land in
the gap between the read and the block. WAKE scans for blocked waiters
matching both the address *and* `page_table` — page_table equality is
the same "genuinely shares memory" test `SYS_EXIT`'s own table-teardown
skip already uses (RFMEM siblings share the literal pointer, never a
copy), so two unrelated processes' coincidentally-equal user-space
addresses can't cross-wake each other. `Process` gained `futex_addr`
to track this — 0 unless genuinely blocked inside `SYS_FUTEX_WAIT`,
cleared the instant `SYS_FUTEX_WAKE` wakes it.

**User side** (`user/user.c3`): `Mutex` — `lock()` is a single
uncontended `compare_exchange` (0→1), falling back to `futex_wait` only
when actually contended; `unlock()` stores 0 and `futex_wake`s. Also
added `print_uint()` (decimal, no leading zeros) since mutextest's own
counter needed more than the two-digit `'0'+n/10` unrolling every
existing test command uses — and de-duplicated three near-identical
private copies of exactly this helper already sitting in `diskd.c3`/
`fsd.c3`/`sdd.c3`, now all calling the one in `user.c3` instead.

**mutextest, and a real methodology finding while building it**: two
threads increment a shared counter through `Mutex`. First attempt used
a tight loop for a fixed iteration count — and passed identically
whether or not the lock/unlock calls were even present, which is wrong:
confirmed by deliberately checking, the two threads simply never
overlapped in time at all (nothing forces an interleave without a
blocking syscall or a lucky preemption landing in a 1-2 instruction
window out of thousands). Fixed using the standard "read, sleep,
write" technique for reliably demonstrating this class of race: each
iteration reads the counter into a local, spins for a real, fixed
slice of wall-clock time (`rdtime()`-based, not a raw instruction
count — holds for comparable real time on both boards despite their
10MHz/25MHz difference), *then* writes back. Confirmed the test is now
meaningful in both directions: with the lock removed, the count came
up short (12-13 of an expected 16) every time; with it restored, 16/16
every time, repeated 5 times in a row plus 30 more calls across a
10-boot stress batch (alongside `racetest`/`rforktest`/`sandboxtest`/
`threadjointest`, none of which touch persistent state, so safe to
repeat across the same boot loop unlike the next entry's `rmrtest`).

**Files changed:** `user/atomic.c3` (new), `user/user.c3` (futex
syscalls, `Mutex`, `print_uint`), `src/entry.c3` (`SYS_FUTEX_WAIT`/
`SYS_FUTEX_WAKE`), `src/process.c3` (`Process.futex_addr`),
`user/diskd.c3`/`user/fsd.c3`/`user/sdd.c3` (local `print_uint` copies
removed in favor of `user.c3`'s), `user/shell.c3` (`mutextest`),
`scripts/build_user.sh` (`atomic.c3` added to every binary's sources).

## 2026-08-19 (14) — Real preemptive scheduling

Built directly on the `sepc`-per-process fix (previous entry): the
timer interrupt now actually forces a reschedule instead of only
firing and returning to whatever was running.

**The change**: in `handle_trap`'s `SCAUSE_SUPERVISOR_TIMER` case, after
rearming, call `yield()` — but only when `current_proc.pid > 0`.

**Why the `pid > 0` guard, specifically**: `enable_timer_interrupts()`
runs early in `kernel_main`, so the timer is live for the rest of boot
— including `kernel_main`'s own sequence of `create_process()` calls
for echod/diskd/sdd/fsd/fsd2, all of which run as `current_proc ==
idle_proc` (pid 0) and are not reentrant (interleaving two
`create_process()`/`alloc_pages()` calls has no protection against
corrupting shared allocator/process-table state). Excluding pid 0
sidesteps that hazard entirely, and costs nothing: idle's own post-boot
loop already calls `yield()` every iteration on its own, so forcing
another one on top adds no benefit.

**Why real processes (pid > 0) need no equivalent guard**: established
directly by this session's own interrupt-latency finding (previous
entry, and the comment above `enable_timer_interrupts()`) — a timer
interrupt can only ever land during genuine, uninterrupted user-mode
execution, never inside a trap's own kernel-mode handling (`sstatus.SIE`
stays hardware-cleared for a trap's entire duration, regardless of how
many `yield()`-driven `switch_context()` calls happen inside it while
waiting on a blocking syscall). So `SYS_IPC_SEND`'s multi-step
bookkeeping, mid-page-table-edit code, and every other piece of kernel
state this codebase has never needed to guard against concurrent
access — none of it is ever what gets preempted. What's actually being
interrupted is always plain, isolated user-mode execution, which
`yield()` was already safe to call from at any point.

**Verified deliberately harder than a single boot**: full QEMU
regression suite once (`hello`/`readfile`/`writefile`/`newfile`/
`deletetest`/`rmdirtest`/`protectedwrite`/`ping`/`nstest`/`rforktest`/
`sandboxtest`/`threadjointest`/`racetest` x4 — all correct), then 30
additional full boots under randomized real preemption timing (each
running `racetest` x5, `rforktest`, `sandboxtest`, `threadjointest`,
`writefile`+`readfile`), checked for `unexpected trap`/`PANIC`, hangs,
and specifically race corruption (`racetest` reporting anything other
than `a=1 b=1`) — 30/30 clean. Real Duo hardware: clean boot through
disk/fs mount, then `racetest` x4, `rforktest`, `sandboxtest` all
correct, matching QEMU exactly.

**Files changed:** `src/entry.c3` (`handle_trap`'s
`SCAUSE_SUPERVISOR_TIMER` case gains the `yield()` call; the comment
block above `enable_timer_interrupts()` rewritten to describe the now-
real preemption instead of the deliberately-deferred slice from the
previous session).

## 2026-08-19 (13) — Real preemption's first prerequisite: sepc needed to become per-process state

First real design step toward actual preemptive scheduling (the
deliberately-deferred half of the timer-interrupt work). Found by
reading the existing trap-return path closely rather than assuming it
would just work: a genuine, foundational correctness bug that
preemption would trigger on its very first tick, not a rare race.

**The invariant that made the old code correct without a per-process
`sepc`**: `sepc` is a single, non-banked hardware CSR. `write_sepc()`
(or, for interrupts, hardware's own already-correct value) was always
set *immediately before* an uninterrupted `sret` — no `yield()` ever
happened in between, for any existing code path. `Process`/
`switch_context()` never needed a `sepc` field because nothing ever
relied on the hardware register surviving across a context switch —
every blocking-syscall loop (`SYS_GETCHAR`, `SYS_IPC_RECV`, `SYS_JOIN`)
only writes `sepc` *after* its own loop finishes, right before
returning.

**Why preemption breaks it**: calling `yield()` from inside the timer
interrupt means some *other* process's own `write_sepc()`+`sret`
sequence can run before the preempted process resumes — overwriting
`sepc` in between. By the time the preempted process is rescheduled,
`sepc` holds someone else's return address, not its own.

**Fix**: `Process` gained `saved_sepc`. `handle_trap` now captures it
once at entry (correct as-is for interrupts, overwritten with the
post-ecall address for ecalls, unaffected by any `yield()`s that
happen via `switch_context`'s own stack-swap, which — confirmed by
reading it — always resumes a process's own call chain exactly where
it left off) and writes the real `sepc` CSR exactly once, always, right
before `handle_trap` returns — restoring the same "write immediately
before an uninterrupted `sret`" invariant, just sourced from
per-process state instead of assuming the shared register survived
untouched. `fork_entry()` (the `rfork` child's own first resume) needed
no change — it's a separate, fully self-contained naked-asm sequence
(its own `csrw sepc` immediately followed by `sret`, no C3 call, no
`yield()` possible in between) that was never subject to this hazard.
`sstatus`/`SPIE` didn't need the same treatment: every process always
runs with interrupts enabled, so that saved value is the same constant
regardless of which process's trap entry most recently wrote it.

**Verified as rigorously as the concern warranted**: full regression
suite (both QEMU images), `racetest` specifically run 4 times in a row
(the test most likely to expose exactly this class of bug, since it
genuinely interleaves two threads via real concurrent `yield()`s) —
`a=1 b=1` every time. `threadjointest` (properly `join()`-synchronized)
also correct. No context switch happens from the timer interrupt yet —
this is groundwork, not preemption itself.

**Files changed:** `src/process.c3` (`Process.saved_sepc`),
`src/entry.c3` (`handle_trap` captures/restores it instead of writing
`sepc` directly mid-function).

---

## 2026-08-19 (12) — Real timer interrupts, actually working on real hardware now

Fixes the previous entry's real-hardware regression: switched
`arm_timer()` (`entry.c3`) from a direct `stimecmp` CSR write to the
SBI legacy `set_timer` ecall (new `sbi::__set_timer()`, same shape as
the existing `__putchar`/`__getchar` bindings) — M-mode firmware
programs the actual timer comparator on the kernel's behalf, needing
no `menvcfg.STCE` permission for direct S-mode CSR access at all.
`enable_timer_interrupts()` re-enabled in `src/kernel.c3`.

**Verified properly this time**, same discipline as the failed
attempt: temporary debug print, confirmed on QEMU first (fired
correctly, ~1s intervals with the shell kept busy), *then* a real
hardware round trip — and this time, real confirmation: `DBG timer
tick (SBI)` appeared twice in the real console log, correctly
interleaved with ongoing, unrelated `sdd` sector-read traffic, boot
completing normally all the way to the shell prompt both times (with
the debug print, and again on the final clean rebuild). No hang, no
regression. Full QEMU regression suite (both images) unaffected,
`racetest` still `a=1 b=1`.

The narrow-scope boundary from two entries ago stands unchanged: this
still only proves the interrupt mechanism itself (fires, rearms,
returns cleanly) — no context switch happens on a tick yet. Actual
preemption remains real, separate, higher-risk work, and the earlier
interrupt-latency finding (blocking syscalls hold `sstatus.SIE`
globally disabled for their own duration) is unaffected by this
arming-mechanism change — same characteristic either way.

**Files changed:** `src/kernel/sbi.c3` (`__set_timer`), `src/entry.c3`
(`arm_timer` uses it instead of direct CSR access), `src/kernel.c3`
(`enable_timer_interrupts()` re-enabled).

---

## 2026-08-19 (11) — Real hardware correction: stimecmp hangs the real Duo, QEMU only proved half the story

The previous entry's QEMU verification wasn't wrong, but it wasn't the
whole story either — flashing `enable_timer_interrupts()` to the real
board hung it silently, right at boot, before even reaching "2: Trap
handler set". Immediately disabled the call (commit right after) to
get the board back to a known-working boot, then investigated properly
rather than just leaving it off.

**Isolated with two narrow, single-variable real-hardware tests**
(temporary debug prints, each confirmed working on QEMU first before
spending a real-hardware round trip): `read_reg("time")` alone —
boots cleanly all the way to the shell prompt, no issue. Adding
`write_csr("stimecmp", ...)` right after — boot stops *exactly* at the
print immediately before that write, every time. Confirmed
definitively: reading `time` works fine on the real T-Head C906 core;
writing `stimecmp` is what hangs it, silently, with no trap or panic
message reaching this kernel's own handler at all — meaning the trap
either isn't being delivered to S-mode the way QEMU's OpenSBI delivers
it, or something worse is happening at the M-mode/firmware level.
Most likely explanation, not yet confirmed: `menvcfg.STCE` (the
M-mode-only bit that permits S-mode `stimecmp` access at all) isn't
set by the real Duo's own FSBL/OpenSBI build, unlike QEMU's — but this
wasn't chased further once the real, actionable fix path was clear.

**Path forward, not yet implemented**: switch to the SBI legacy timer
extension (`sbi_set_timer()`, an ecall trapping straight to M-mode
firmware — no S-mode CSR access, no menvcfg.STCE dependency at all)
instead of direct `stimecmp` CSR access. Both platforms' own boot
banners already confirm the SBI "time" extension is present
(`Standard SBI Extensions: ...,time,...`), and this project already
has real precedent for SBI ecall bindings (`sbi::__putchar`/
`sbi::__getchar` in `boards/*/board.c3`). `enable_timer_interrupts()`
stays disabled (commented out in `src/kernel.c3`, real hardware
confirmed back to a normal boot) until that switch is made.

**Files changed:** `src/kernel.c3` (updated comment with the confirmed
root cause and the real fix direction).

---

## 2026-08-19 (10) — Real timer interrupts: the mechanism itself, and a real interrupt-latency finding

Deliberately narrow first slice of preemptive-scheduling support,
scoped down from the full feature on purpose: this kernel has been
fully cooperative until now (every context switch happens at a
caller-chosen `yield()`), so kernel state has never needed to guard
against concurrent access — SYS_IPC_SEND's own multi-step bookkeeping,
page-table edits, none of it. Forcing a `yield()` from inside a timer
interrupt (real preemption) means that state could now get touched
mid-update by whatever gets switched to, a whole new class of bug this
codebase has never had to defend against. This session proves the
*mechanism* — the interrupt fires, gets correctly re-armed, and
returns cleanly to whatever was running — without yet taking that
step.

**Design**: `board::TIMEBASE_HZ` (real, confirmed values — 25MHz Duo,
10MHz QEMU, same sourcing as the earlier real-timer-primitive work)
added to both boards, the proper seam for a kernel-reachable
board-specific fact (unlike `user/sdd.c3`'s own duplicate, needed only
because `board` is kernel-only). `entry.c3` gained `arm_timer()`
(writes `time + delta` to `stimecmp`, the sstc extension's own CSR —
confirmed present in this hart's boot banner) and
`enable_timer_interrupts()` (arms *before* enabling `sie.STIE`, not
after — `stimecmp`'s reset value is implementation-defined and could
easily be 0, which would make the interrupt already-pending the
instant the source goes live). `handle_trap` gained a
`SCAUSE_SUPERVISOR_TIMER` case: re-arms immediately (the only thing
that actually clears the pending interrupt — leaving the elapsed value
in place would refire it the instant interrupts are next enabled, a
storm not a tick) and bumps an inert `timer_tick_count` counter. No
context switch — that's the explicitly-deferred half.

**A real finding, not a bug in this mechanism**: verified via a
temporary debug print, the first armed tick (~1s out) didn't actually
fire until several seconds later — once, coinciding almost exactly
with whenever the next keystroke arrived at the idle shell, not on
schedule. Traced to `SYS_GETCHAR`'s own handler: a `for(;;) { ...;
yield(); }` loop running *entirely inside its own still-open trap*,
never reaching `sret` until a character shows up — and the exact same
shape is used by `SYS_IPC_RECV`'s blocking wait and `SYS_JOIN`'s poll
loop. Hardware auto-clears `sstatus.SIE` on trap entry and only
restores it on `sret`; since `switch_context()` is a plain software
stack swap (not a trap return) and `sstatus.SIE` is one shared,
un-banked hardware bit, every process `yield()` switches to *while*
one of these loops is still open inherits that same globally-disabled
state — not just the blocked process itself. Confirmed directly: shell
left idle, the timer only fired once a keystroke finally arrived;
shell kept continuously busy (repeated commands, never idly parked in
`SYS_GETCHAR`), the same timer fired reliably every ~1s as armed
(measured intervals: ~10.3M, 10.26M, 10.26M, 10.33M ticks against a
10M-tick target). Documented directly in `enable_timer_interrupts()`'s
own comment — genuinely relevant to whoever builds real preemption
later: a timer-interrupt-based preemptive scheduler built on this same
mechanism would *not* actually preempt a process stuck in any of these
blocking syscalls, for the identical reason the timer itself was
delayed.

**Verified**: full regression suite (both QEMU images) unaffected,
`racetest` still `a=1 b=1`, 30 rapid commands with the timer firing
repeatedly throughout showed no instability.

**Files changed:** `boards/duo/board.c3`/`boards/qemu/board.c3`
(`TIMEBASE_HZ`), `src/entry.c3` (`SCAUSE_SUPERVISOR_TIMER`, `SIE_STIE`,
`arm_timer`, `timer_tick_count`, `enable_timer_interrupts`,
`handle_trap`'s new case), `src/kernel.c3` (calls
`enable_timer_interrupts()` at boot).

---

## 2026-08-19 (9) — Directory deletion (rmdir), both backends

The natural follow-up to file delete, whose own comments explicitly
deferred this: `fat32_delete()`/`ext2_delete()` now also handle an
*empty* directory, reusing the same `FS_DELETE` verb rather than
adding a new one — no wire protocol change needed. Matches real
`rmdir()` semantics deliberately: refuses a non-empty directory,
no recursive auto-delete (that's real, separate, genuinely dangerous
work not attempted here).

**FAT32**: new `fat32_dir_is_empty()` walks a directory's cluster
chain checking for anything besides `.`/`..`. Those two don't 8.3-
convert correctly through the existing `fat32_name_to_8_3()` (it treats
a leading dot as "start of the extension", producing an all-spaces
name for either) — matched directly against their real, fixed byte
patterns instead of going through that path. Once confirmed empty, an
empty directory deletes exactly like a file (mark the entry
`FAT32_DIRENT_DELETED`, free its cluster chain) — FAT32 has no
link-count concept, so nothing else to unwind.

**ext2**: same shape (`ext2_dir_is_empty()`, matching by exact
`name_len` since ext2 entries aren't space-padded) plus real,
ext2-specific bookkeeping FAT32 doesn't have: the deleted directory's
own `..` entry was a link to its parent, so the parent's `links_count`
needs decrementing (the same field this session's earlier corruption
fix taught was genuinely load-bearing, not cosmetic). **Found a second
real bookkeeping gap the same way**: the very first rmdir test against
`e2fsck` flagged "directory count wrong for group N" — `bg_used_dirs_
count`, a per-group directory counter with no superblock-level twin,
never touched before because this driver has no `mkdir` of its own to
have ever incremented it. New `ext2_dec_used_dirs()` fixes it, using
the *deleted directory's own* group (not the parent's).

**A real test-construction problem, solved properly**: this driver has
no `mkdir`, so testing the positive case (successfully removing an
empty directory) needed a genuinely empty directory to exist first —
added `emptydir/` to all three QEMU test images (`scripts/build.sh`,
`mmd`/`debugfs mkdir`, no files inside). New `rmdirtest`/`rmdirtest2`
delete it and confirm it's really gone by deleting it again (which
should now fail) — the same "before, action, after" shape `deletetest`
uses, just via a second delete instead of a read, since a directory
isn't readable as file content. New `rmdirnonempty`/`rmdirnonempty2`
confirm the existing, genuinely non-empty `subdir/` fixture is
correctly refused.

**Verified as rigorously as every other write-path change this
session**: `e2fsck -n -f` caught the `bg_used_dirs_count` gap on the
very first real test (not just trusted the code), came back completely
clean once fixed. FAT32's own deletion cross-checked with `mdir`
independently — `emptydir/` genuinely gone, `subdir/` genuinely still
there after the correctly-refused non-empty attempt. Full regression
suite (both QEMU images) unaffected, `racetest` still `a=1 b=1`.

**Files changed:** `user/fs/fat32.c3` (`fat32_dir_is_empty`,
`fat32_delete` branches on directory vs file), `user/fs/ext2.c3`
(`EXT2_BGD_USED_DIRS_COUNT`, `ext2_dec_used_dirs`, `ext2_dir_is_empty`,
`ext2_delete` handles directories: empty-check, parent link-count,
used-dirs count), `user/shell.c3` (`rmdirtest`/`rmdirtest2`/
`rmdirnonempty`/`rmdirnonempty2`), `scripts/build.sh` (`emptydir/`
fixture in all three test images).

---

## 2026-08-19 (8) — File delete/unlink, both backends

fsd had no way to remove a file at all — the FS_READ/FS_WRITE wire
protocol had no verb for it, and the shell had no equivalent command.
Real, contained feature, built on top of everything else this session
already put in place (subdirectory resolution, the protected-entry
check, correct free-count bookkeeping).

**Wire protocol**: `user/user.c3` gained `FS_DELETE` (verb 22) and
`fs_delete(filename)` — filename-only request, reply reuses byte 0..3
for a plain 0/-1 result (no length concept for a delete). `fsd.c3`'s
dispatch gained a third branch alongside FS_READ/FS_WRITE, with the
same protected-name fast-gate FS_WRITE already has before either
backend even runs.

**FAT32**: `fat32_delete()` resolves the containing directory (reusing
`fat32_resolve_dir`, so subdirectory files delete correctly too),
refuses a directory or the protected entry, then — order matters —
marks the directory entry `FAT32_DIRENT_DELETED` *before* freeing its
cluster chain (`fat32_free_cluster_chain()`, new). Marking first means
a failure partway through just leaks space (safe); freeing first and
then failing to mark the entry deleted would leave a still-visible
file pointing at clusters that could already be reused elsewhere — a
real corruption risk, not just a leak.

**ext2**: `ext2_delete()` same shape, same ordering principle taken
further given ext2 has more state to unwind: clear the directory
entry, zero the inode's own record (`ext2_zero_inode`, reused),
free each of its data blocks (new `ext2_free_block()`, the inverse of
`ext2_alloc_block()` — same group-aware bitmap math in reverse), then
free the inode itself (new `ext2_free_inode()`) — never marking
something reusable while anything upstream of it might still
reference it. New `ext2_inc_free_blocks()`/`ext2_inc_free_inodes()`
mirror this session's earlier `ext2_dec_free_*` functions, keeping
both free-count copies correct on the way back up too — the same
bookkeeping that turned out to matter for real (auto-remount-read-only)
consequences earlier this session.

**Verified rigorously**: new `deletetest`/`deletetest2` shell commands
(create, confirm present, delete, confirm genuinely gone) on both
mounts, `deleteprotected` confirms `fip.bin` is still refused. `e2fsck
-n -f` on the ext2 image after a delete: completely clean, no errors
of any kind — the free-count/bitmap bookkeeping unwound correctly, not
just the visible file. FAT32's deletion cross-checked with `mdir`
(mtools, not `fsd`'s own read-back) — the file is genuinely gone from
the directory listing. Full regression suite (both QEMU images)
unaffected, `racetest` still `a=1 b=1`.

**Files changed:** `user/user.c3` (`FS_DELETE`, `fs_delete()`),
`user/fsd.c3` (dispatch), `user/fs/fat32.c3` (`fat32_free_cluster_
chain`, `fat32_delete`), `user/fs/ext2.c3` (`ext2_inc_free_blocks`/
`ext2_inc_free_inodes`, `ext2_free_block`/`ext2_free_inode`,
`ext2_delete`), `user/shell.c3` (`deletetest`/`deletetest2`/
`deleteprotected`).

---

## 2026-08-19 (7) — Closing the last documented gap: directory-vs-file confusion in the protected-file lookup

`ext2.c3`'s own header comment still listed "no directory-entry
file-type filtering" as a known gap — checking turned out it was
already closed for the parts that actually matter: `ext2_read`/
`ext2_write` route through `ext2_find_in_dir` (added earlier this
session for subdirectory support), which already reads the matched
entry's real inode and refuses to treat a directory as file content,
using the inode's own authoritative `mode` field rather than the
optional, sometimes-absent on-disk `file_type` byte the old comment
worried about — actually more robust than what was originally asked
for.

The one place this genuinely wasn't checked: `ext2_reserve_protected()`
(mount-time lookup of `fip.bin`), whose only remaining caller of the
now-narrowly-scoped `ext2_find_in_root` never looked at type at all. A
directory happening to share the protected name would have had its
own cluster chain reserved as if it were "the protected file"'s data —
a category error, though a safe-direction one (over-protective, never
under-protective or data-exposing). Fixed the same way in both
backends for consistency: `ext2_reserve_protected` now checks the
inode it already reads anyway; `fat32_find_in_root` (FAT32's own
now-single-purpose equivalent, same "only `fat32_reserve_protected`
still calls it" situation) gained an `out_attr` param so
`fat32_reserve_protected` can check `FAT32_DIRENT_ATTR_DIRECTORY`
directly from the dirent, no extra read needed there. Both fail the
same way a genuinely-missing file already did: print, don't reserve.

Verified via full regression suite (both single- and dual-mount QEMU
images), `protectedwrite`/`racetest` unaffected. The real, hardware-
relevant case (a real `fip.bin`, not a same-named directory) is
unchanged — this only adds a new, narrow refusal path that was never
exercised before.

**Files changed:** `user/fs/ext2.c3` (`ext2_reserve_protected` checks
`inode.mode & EXT2_S_IFDIR`, header comment updated), `user/fs/fat32.c3`
(`fat32_find_in_root` gained `out_attr`, `fat32_reserve_protected`
checks it).

---

## 2026-08-19 (6) — ext2 multi-group allocation: this driver's own writes aren't confined to group 0 anymore

Closes the last piece of the "block group 0 only" limitation — the
entry below deliberately stopped at reads/updates, leaving
`ext2_alloc_block()`/`ext2_alloc_inode()` group-0-only since that's
the higher-risk half (this session already found two real corruption
bugs in the allocator's own neighborhood). Extended carefully, on top
of the mount-time per-group bitmap locations the previous entry
already added.

**Design**: `ext2_mount()`'s block-group-descriptor read now also
caches every group's own block/inode bitmap block (not just the inode
table, which the read-side fix already needed) into two more
`[EXT2_MAX_GROUPS]` arrays. `ext2_alloc_block()`/`ext2_alloc_inode()`
now loop over every group in turn — group 0 first, so existing
single-group volumes see zero behavior change — computing the real
absolute block/inode number from `(group, index-within-group)`.
`ext2_dec_free_blocks()`/`ext2_dec_free_inodes()` gained a `group`
parameter and now locate that specific group's own descriptor within
the (possibly multi-block) BGDT instead of always assuming block 0's
own 32-byte entry — the exact bug class this session's earlier
free-count fix would have reintroduced if left group-0-only.
`ext2_zero_inode()` also needed the same group-aware lookup, since it
runs on whatever `ext2_alloc_inode()` just handed it, no longer
guaranteed to be group 0. The old flat, group-0-only globals (`ext2_
inode_table_block` etc.) were removed entirely rather than left
dangling once nothing referenced them anymore.

**Verified as rigorously as the read-side fix, maybe more so given the
stakes**: baseline regression suite (including `e2fsck -n -f` on a
fresh, untouched image) confirmed no behavior change for the normal,
single-group case. Then actually forced the allocator's hand: built a
small-group scratch image (`mke2fs -g 512`, 128 inodes/group), filled
group 0's inodes completely via `debugfs` (confirmed via `stat` that
the *next* file would land at inode 129, group 1), then had the
*kernel's own* `newfile2` create a genuinely new file through the
exhausted volume — landed at inode 130 (group 1), confirmed via
`debugfs stat`, not just trusted. `e2fsck -n -f` on the result: fully
clean, no errors of any kind, including group 1's own free-count
bookkeeping. Re-ran the same stressed image with `readfile2`/
`racetest` afterward — nothing else broke.

**Files changed:** `user/fs/ext2.c3` (`ext2_block_bitmap_blocks[]`/
`ext2_inode_bitmap_blocks[]`, `ext2_mount()`'s BGDT scan extended,
`ext2_dec_free_blocks`/`ext2_dec_free_inodes` gained a `group`
parameter, `ext2_alloc_block`/`ext2_alloc_inode`/`ext2_zero_inode`
made group-aware, dead flat group-0 globals removed, header comments
updated).

---

## 2026-08-19 (5) — ext2 multi-group reads: closing the gap the real hardware exposed twice now

The "block group 0 only" limitation bit twice in one session (see the
entry below): a real Linux `mkdir` on the actual boot card put a new
directory in group 1, which this driver refused entirely. Scoped
carefully rather than a full rewrite: extending *reading and updating*
an existing inode to work across any group is a bounded, low-risk
index-math change; extending *allocation* (new inodes/blocks) to scan
and update other groups' bitmaps and free-counts is real, separate,
higher-risk work — this session already found two real corruption bugs
in the allocator's neighborhood, so it stayed untouched.

**Design**: `ext2_mount()` now computes `ext2_group_count` (from the
superblock's total inode count) and reads the *entire* block group
descriptor table — not just group 0's own 32-byte entry — into a new
`ext2_inode_table_blocks[]` array (looping over however many BGDT
blocks that actually takes, not assuming one block is always enough).
`ext2_read_inode`/`ext2_write_inode` now compute `group = (inode_num -
1) / ext2_inodes_per_group` and index into that array instead of
always using the flat, group-0-only `ext2_inode_table_block` global —
which `ext2_alloc_inode()`/`ext2_zero_inode()` still use unchanged,
since new inodes are still only ever allocated in group 0.

**Verified properly, not just trusted**: debugfs alone doesn't
naturally scatter files across groups on a small test image (its own
allocator stays in group 0 for anything this project's test fixtures
need), so confirming this needed *actually* forcing a multi-group
scenario — built a scratch ext2 image with `mke2fs -g 512` (small
groups on purpose), filled group 0's inodes with 130 dummy files via
`debugfs`, then created `subdir` — landed at inode 143, genuinely in
group 1 (`(143-1)/128 = 1`). `readsubfile2` against it initially
worked (confirming the read side), but `newsubfile2` initially failed
— traced with temporary debug prints to `ext2_alloc_inode()` itself
returning "no free inode", which turned out to be a test-setup
artifact (the 130 dummy files had exhausted group 0's own inode pool,
not a bug) — freed some of them back up and the write succeeded
cleanly. `e2fsck -n -f` on the result: completely clean, no errors of
any kind. Full regression suite (both QEMU images) unaffected,
`racetest` still `a=1 b=1`.

**Files changed:** `user/fs/ext2.c3` (`EXT2_SB_INODES_COUNT`,
`EXT2_MAX_GROUPS`/`EXT2_BGD_SIZE`, `ext2_group_count`/
`ext2_inode_table_blocks[]`, `ext2_mount()`'s BGDT-table read,
`ext2_read_inode`/`ext2_write_inode` made group-aware, header comment
updated).

---

## 2026-08-19 (4) — ext2 subdirectory support on real hardware: a real trigger for the documented "block group 0 only" limit

Testing write-into-subdirectory support on the real card's `EXT2TEST`
partition hit a wall: `sudo mkdir subdir` there, then `newsubfile2`/
`readsubfile2` both failed with "not found" — even reading the
already-seeded `nested.txt`. Not a new bug: `ext2.c3`'s own header
comment has always scoped this driver to "block group 0 only," and
`sudo debugfs -R "stat subdir" /dev/sdc2` showed exactly why it fired —
the real kernel's `mkdir` allocated `subdir` as inode **16385**, but
`sudo debugfs -R "show_super_stats -h"` showed this filesystem has only
**8192 inodes per group**, putting that inode in group 1.
`ext2_read_inode()` correctly refused it (`inode_num > ext2_inodes_per_
group`) exactly as documented.

Confirmed this was specifically about *how* the directory was created,
not a filesystem-wide problem: real Linux `mkdir` uses a modern
allocator that deliberately spreads new directories across groups for
locality, which QEMU's own test fixtures (seeded via `debugfs`'s
simpler first-fit allocator) never exercised — every previous
real-hardware write went through either this driver's own group-0-only
`ext2_alloc_inode()` or `debugfs`, neither of which had ever landed
outside group 0 before.

**Resolution, not a fix**: removed the kernel-created `subdir` (`sudo
rm`/`rmdir` the contents first — debugfs has no clean recursive
directory removal) and recreated it via `debugfs -w -R "mkdir subdir"`
instead, landing at inode 14 this time — comfortably in group 0.
`readsubfile2`/`newsubfile2` both then worked correctly on real
hardware, confirming write-into-subdirectory support end to end on the
ext2 backend. Multi-group support (real group-index math, reading
additional block group descriptors) remains a genuine, understood gap
— not attempted here, noted as real future work if this driver ever
needs to interoperate with directories real Linux tools create instead
of ones it creates itself.

---

## 2026-08-19 (3) — ext2 free-count bookkeeping: not just cosmetic after all

`user/fs/ext2.c3`'s own header comment had accepted, since the original
write-support work, that `s_free_blocks_count`/`s_free_inodes_count`
(and their group-0 `bg_free_*` copies) going stale after a write was a
harmless, e2fsck-only cosmetic gap. Trying to `mkdir` a test directory
on the real card's `EXT2TEST` partition (to test write-into-
subdirectory on real hardware) showed that's wrong: Linux's own ext2
driver checks this at *mount* time and, seeing the volume "has errors"
(the exact same mismatch `e2fsck` flags), auto-remounts it read-only
(`errors=remount-ro`) — a real, practical consequence blocking any
further write access from the Linux side after a single kernel-driven
write, not just a dry-run complaint.

**Fix**: `ext2_alloc_block()`/`ext2_alloc_inode()` now each call a new
`ext2_dec_free_blocks()`/`ext2_dec_free_inodes()` right after
successfully marking their own bitmap bit — decrements both the
superblock's copy (fixed sector 2, alongside every other superblock
field this driver already reads) and group 0's own copy in the block
group descriptor (same block `ext2_mount()` already reads at
`ext2_first_data_block + 1`). No corresponding increment path exists
because there's no delete/unlink in this driver at all (v1 scope) —
allocation is the only direction free counts ever need to move.

**Verified**: `e2fsck -n -f` on a fresh `disk_ext2.img` after
`writefile`+`newfile` (2 new allocations) came back completely clean —
no errors of *any* kind, not even the previously-accepted mismatch.
Repeated with `newsubfile`/`newsubfile2`/`newfile2` together on
`disk_dual.img`'s ext2 half (4 allocations across two directories):
same, fully clean result. Full regression suite unaffected, `racetest`
still `a=1 b=1`.

**Files changed:** `user/fs/ext2.c3` (`EXT2_SB_FREE_BLOCKS_COUNT`/
`EXT2_SB_FREE_INODES_COUNT`/`EXT2_BGD_FREE_BLOCKS_COUNT`/
`EXT2_BGD_FREE_INODES_COUNT` offsets, `ext2_dec_free_blocks`/
`ext2_dec_free_inodes`, wired into `ext2_alloc_block`/
`ext2_alloc_inode`; removed the now-inaccurate "accepted gap" comment).

---

## 2026-08-19 (2) — Write-into-subdirectory support for both fsd backends

The deliberately-deferred half of subdirectory support (see the
read-only entry below) — create/overwrite/grow a file inside a
subdirectory, not just the root. Higher-stakes than the read side (a
write bug can corrupt real data, per every other write-path entry in
this log), so built and verified carefully, right after fixing a real
write-path corruption bug in the same files.

**Design, same shape in both backends, mirroring the read-only
generalization**: every write-path function that was hardcoded to the
root now takes the containing directory (cluster/inode) as a
parameter, resolved once via the existing `fat32_resolve_dir`/
`ext2_resolve_dir` — no new directory-walking logic, reusing exactly
what the read path already proved.

- `user/fs/fat32.c3`: `fat32_find_in_dir` gained entry_sector/
  entry_offset out-params (needed for the protected-entry check and
  size updates, which the read-only version never needed);
  `fat32_find_free_dirent`/`fat32_create_file` both gained a
  `dir_cluster` parameter; `fat32_write` resolves the directory first,
  then does everything else the same way it always did, just against
  that cluster instead of always the root.
- `user/fs/ext2.c3`: same shape — `ext2_find_in_dir` gained entry_
  sector/entry_offset, `ext2_create_file` gained a `dir_inode_num`
  parameter (its body's `root` local simply renamed `dir`, no logic
  change), `ext2_write` resolves the directory first. Reuses the exact
  same, already-fixed inode-creation code from this session's earlier
  corruption fix (`links_count = 1`, `i_blocks` maintained) — nothing
  new to get wrong there.

`fat32_find_in_root`/`ext2_find_in_root` and their own root-only
caller (`*_reserve_protected`, looking up `fip.bin`) are completely
untouched — that file only ever lives in the root regardless of what
this feature does.

**Verified rigorously**: new `newsubfile`/`newsubfile2` shell commands
(create-then-readback inside `subdir/`, mirroring `newfile`/`newfile2`'s
own pattern) on both single- and dual-mount QEMU images. For ext2
specifically, ran the same `e2fsck -n -f` oracle this session's
corruption fix introduced on the resulting image — only the
pre-existing, already-accepted free-count cosmetic mismatch showed up,
confirming the subdirectory write path doesn't reintroduce that bug
(expected, since it reuses the already-fixed code, but confirmed
rather than assumed). For FAT32, independently confirmed via `mdir`
(mtools, not `fsd`'s own read-back) that the new directory entry is
real and correct. Also confirmed: overwriting an already-created
subdirectory file reuses its entry correctly (doesn't duplicate or
corrupt), and a write into a nonexistent directory fails cleanly (the
identical `resolve_dir` the read path already relies on, not new logic
to break). Full regression suite otherwise unaffected, `racetest`
still `a=1 b=1`.

**Confirmed on real Duo hardware** too (FAT32 side — `subdir/nested.txt`
seeded onto the real `DUOBOOT` partition for this; the ext2 side's own
subdirectory support stays QEMU-only for now, same call made for the
read-only entry below, reasonable here too since its write logic is
identical to `newfile2`'s already hardware-confirmed-fixed path):
`readsubfile` correctly read `nested.txt`, and `newsubfile` correctly
wrote and read back a new file inside `subdir/` — a real `CMD00000018`
(write) visible in the console trace, not just a successful-looking
readback.

**Files changed:** `user/fs/fat32.c3` (`fat32_find_in_dir`'s new
out-params, `fat32_find_free_dirent`/`fat32_create_file`'s
`dir_cluster` parameter, `fat32_write` updated), `user/fs/ext2.c3`
(same shape: `ext2_find_in_dir`'s new out-params, `ext2_create_file`'s
`dir_inode_num` parameter, `ext2_write` updated), `user/shell.c3`
(`newsubfile`/`newsubfile2`).

---

## 2026-08-19 — Real ext2 write-path corruption, found by looking at the card from Linux's own side

Flashing the previous session's fip.bin surfaced something none of this
project's own ext2 write-path testing had ever caught: `ls -la` on the
real card's `EXT2TEST` partition showed `newtest.txt`/`newtest2.txt`
(created earlier via `fsd`'s `newfile`/`newfile2` commands) as
`???????????`, unreadable, "structure needs cleaning" — even though
`fsd`'s own read-back had reported them correct at the time. First
time this session's testing looked at a real-hardware write from
Linux's own side rather than trusting `fsd`'s self-consistency check.

`sudo e2fsck -n -f /dev/sdc2` (read-only, no repairs — run by hand in a
real terminal, `sudo` needs an interactive password this session can't
supply) found two real, distinct bugs in `user/fs/ext2.c3`'s write
path, both pre-existing from last week's "ext2 write support" work, not
introduced by anything since:

1. **`i_links_count` never set.** `ext2_create_file()` calls
   `ext2_zero_inode()` (zeroes the whole raw inode record) then
   `ext2_write_inode()`, which only ever wrote `mode`/`size`/`block[]`
   — `i_links_count` stayed 0 forever. A real ext2 reader treats
   link-count 0 + dtime 0 as "not actually a live file", regardless of
   a directory entry pointing at it with real content — exactly
   `e2fsck`'s "deleted inode has dtime zero" / "directory element
   references deleted/unused inode" findings. Not a bitmap-allocation
   bug (initially suspected, then ruled out by reading `ext2_alloc_
   inode()`'s code directly — it does set its bitmap bit correctly).
2. **`i_blocks` never maintained.** Separate from `i_size` (which
   *was* kept correct, per the file's own existing header comment) —
   `Ext2_inode_info` didn't even model this field, so it stayed at
   whatever `mke2fs` initially wrote regardless of how many blocks a
   file or directory actually gained afterward. Caught as "i_blocks is
   8, should be 24" on the root directory (grew by 2 blocks from the
   two `newfile`/`newfile2` real-hardware tests, count never updated).

**Fix**: `Ext2_inode_info` gained `links_count`/`blocks` fields;
`ext2_read_inode`/`ext2_write_inode` now round-trip both (offsets 26/28
in the standard inode layout, alongside the already-read `mode`/`size`).
`ext2_create_file()` sets `links_count = 1` on every newly created
inode and bumps `root.blocks` when appending a directory block;
`ext2_write_file()` bumps the file's own `.blocks` when allocating a
genuinely new block (not a partial rewrite of an existing one). The
free-block/inode *count* fields (`s_free_blocks_count` etc.) remain
deliberately unmaintained — that's the file's own pre-existing,
documented scope decision, not part of this bug, and `e2fsck` still
correctly (harmlessly) flags that mismatch alone after the fix.

**Verified rigorously**, differently from every previous ext2 session:
QEMU's `disk_ext2.img`/`disk_dual.img` are plain files, so `e2fsck -n
-f` could run directly on them (and on a `dd`-extracted copy of
`disk_dual.img`'s ext2 half) with no root needed — a real correctness
oracle this project's ext2 work never had before. Before the fix:
`writefile`+`newfile` on a fresh `disk_ext2.img` reproduced the exact
same "deleted inode" / "i_blocks wrong" errors seen on the real card.
After the fix: those are gone entirely, only the pre-existing
free-count cosmetic mismatch remains, on both `disk_ext2.img` and
`disk_dual.img`. Full regression suite (both single- and dual-mount
images) otherwise unaffected, `racetest` still `a=1 b=1`. Reflashed
`build/fip_duo.bin` with the fix and confirmed on real hardware
(`newfile2` created and read back correctly through fsd2's own ext2
write path). The two already-corrupted legacy files on the real card
predated this fix; cleaned up separately via `sudo e2fsck -y -f
/dev/sdc2` (run by hand), confirmed clean afterward.

**Files changed:** `user/fs/ext2.c3` (`EXT2_INODE_LINKS_COUNT`/
`EXT2_INODE_BLOCKS` offsets, `Ext2_inode_info.links_count`/`.blocks`,
`ext2_read_inode`/`ext2_write_inode` round-trip both,
`ext2_create_file`/`ext2_write_file` maintain them correctly).

---

## 2026-08-18 (4) — Read-only subdirectory support for both fsd backends

Third of three requested follow-ups from the multi-mount work. Both
FAT32 and ext2 were deliberately root-directory-only in v1 (each
backend's own header comment). Scoped this pass to reads only — write
support (create/overwrite/grow *inside* a subdirectory, as opposed to
the existing root-only write path) is real, separate work with real
data-corruption stakes on a live boot partition, and wasn't attempted
unsupervised.

**Design, same shape in both backends**: a subdirectory is just an
ordinary directory entry/inode whose own data holds more directory
entries — the same layout the root directory already uses — so the new
code is the existing root-walking function generalized to take any
starting point, not new logic. `fat32_find_in_root`/`ext2_find_in_root`
and every write-path caller of either are completely untouched.

- `user/fs/fat32.c3`: `fat32_find_in_dir(dir_cluster, ...)` (generalizes
  `fat32_find_in_root`, also reports the matched entry's attribute byte
  so a caller can tell a subdirectory from a file via the newly-added
  `FAT32_DIRENT_ATTR_DIRECTORY` bit), `fat32_resolve_dir()` (splits a
  path on `/`, walks each directory component, requiring
  `ATTR_DIRECTORY` at each step), `fat32_leaf_name()`. `fat32_read`
  resolves the containing directory first, then looks up the leaf there
  instead of always in the root, and refuses to "read" a directory as
  file content.
- `user/fs/ext2.c3`: `ext2_find_in_dir(dir_inode_num, ...)` (same
  generalization, reports the matched entry's inode mode —
  `EXT2_S_IFDIR` already existed as a format constant, unused until
  now), `ext2_resolve_dir()`, `ext2_leaf_name()`. `ext2_read` updated
  the same way.

Both resolve functions support arbitrary nesting depth (not just one
level) for free — the path-splitting loop doesn't care how many `/`s it
crosses — and skip empty segments (a leading `/`, a doubled `//`)
rather than failing on them.

**Verified on QEMU**, both single- and dual-mount images: new
`disk/subdir/nested.txt` and `disk-ext2/subdir/nested.txt` test fixtures
(`scripts/build.sh`, seeded via `mmd`/`mcopy` for FAT32 and `debugfs`'s
own `mkdir` for ext2), new `readsubfile`/`readsubfile2` shell commands.
Both backends correctly resolve into their subdirectory and return the
right, distinct content through both mounts simultaneously; full
existing regression suite (including `racetest`, now consistently
`a=1 b=1` after this session's `PROCS_MAX` fix above) unaffected.

**Files changed:** `user/fs/fat32.c3` (`FAT32_DIRENT_ATTR_DIRECTORY`,
`fat32_find_in_dir`/`fat32_resolve_dir`/`fat32_leaf_name`, `fat32_read`
updated), `user/fs/ext2.c3` (`ext2_find_in_dir`/`ext2_resolve_dir`/
`ext2_leaf_name`, `ext2_read` updated), `user/shell.c3`
(`readsubfile`/`readsubfile2`), `scripts/build.sh` (subdirectory test
fixtures in all three QEMU test images), new `disk/subdir/nested.txt` /
`disk-ext2/subdir/nested.txt`.

---

## 2026-08-18 (3) — Closing the stale-namespace-pid gap, and the real racetest culprit: PROCS_MAX, not IPC

Two follow-ups from the multi-mount entry below, both requested
explicitly rather than found by accident this time.

**1. The documented `SYS_IPC_SEND` "KNOWN GAP"**: a namespace entry
(`Mount.server_pid`) was a plain pid snapshot taken once at the
resolving process's own creation time, never refreshed — if the
original target exited and its slot got reused, the entry could
silently start resolving to an unrelated process. Fixed the way the
gap comment itself suggested: `Mount` gained a `server_generation`
field, populated via a new `mount_generation()` helper (`proc_by_pid`
+ `.generation`, 0 if the target doesn't currently exist) at the exact
three call sites `create_process()` already populates `server_pid` at.
`SYS_NS_RESOLVE` (`src/entry.c3`) now requires a live match on *both*
pid and generation before handing a mount's `server_pid` back — the
same "this exact instance, not a reused slot" distinction `SYS_JOIN`
already relies on for its own purpose. Fixed one layer up from where
the old comment sat (`SYS_IPC_SEND`'s `proc_by_pid` check): a caller
can now never *obtain* a hijacked pid through namespace resolution in
the first place, so `SYS_IPC_SEND` itself needs no new logic — its
existing `proc_by_pid` null-check still does its original, narrower
job (guarding against a genuinely dead/never-existed pid). The exact
original trigger (fsd2 panicking and freeing its slot) no longer
exists to re-run live, since that path was already made non-fatal in
the multi-mount work — verified instead by full QEMU regression
(single- and dual-mount images), confirming no behavior change in any
working case, and by code-level comparison against `SYS_JOIN`'s
already-proven pattern.

**2. `racetest`'s `a=0 b=0`**, chased for real this time instead of
being logged as a known-orthogonal issue. Static tracing of the
send/recv rendezvous mechanism through several interleavings turned up
nothing — the mechanism is genuinely serialized, no clobbering possible
by construction. Added temporary debug prints (raw reply bytes, sender
pid, `threadcreate()`'s own return values) rather than keep
speculating. The very first data point broke the case open:
`threadcreate()` was returning `-1` for *both* racing threads — never
even creating them, let alone corrupting a reply. Root cause:
`process.c3`'s `PROCS_MAX` was 8, and by the time `racetest` runs in
the full regression sequence, all 8 slots are already spoken for (idle,
echod, diskd-or-sdd, fsd, fsd2, shell, rforktest's child, sandboxtest's
child) — zero left for racetest's own two `threadcreate()` calls.
`join()` on a pid that was never actually created returns immediately
(`proc_by_pid` correctly says "gone"), so `race_ok_a`/`race_ok_b` are
read back at their reset value of 0 before the (nonexistent) threads
ever run. This also fully explains the *original* `a=1 b=0` baseline,
long before any of this week's changes: even at 7 permanent+child
processes, only one spare slot existed — thread A got it, thread B's
`threadcreate()` failed the same way. Never an IPC bug at any point.

Fixed by raising `PROCS_MAX` to 16 (real headroom over the 6 permanent
boot processes plus concurrent test children/threads; costs an extra
512KB of static kernel memory, negligible against the 64MB DRAM budget
on both QEMU and the Duo — confirmed via each board's own `kernel.ld`
that the free-RAM pool either has fixed generous headroom already
(QEMU) or self-sizes against whatever's left (Duo), not a fixed window
that could overflow). Also hardened `racetest` itself
(`user/shell.c3`) to check `threadcreate()`'s return value and report
"threadcreate failed (no free process slot) — inconclusive" distinctly,
so a future `PROCS_MAX`-exhaustion regression can never again be
mistaken for IPC/rendezvous corruption. Verified: `racetest: a=1 b=1`,
reproducible across repeated runs on both the single- and dual-mount
QEMU images, full regression suite otherwise unaffected.

**Files changed:** `src/process.c3` (`Mount.server_generation`,
`mount_generation()`, `PROCS_MAX` 8→16), `src/entry.c3`
(`SYS_NS_RESOLVE`'s generation check, `SYS_IPC_SEND`'s comment
updated), `user/shell.c3` (`racetest`'s `threadcreate()` failure
check and updated comment).

---

## 2026-08-18 (2) — Two simultaneous fsd mounts, and a real self-deadlock bug found along the way

Until now, switching filesystems on the Duo meant editing
`board::FS_PARTITION_START_SECTOR`, rebuilding, and reflashing — done
twice already this week for the ext2 work. This adds a second, parallel
`fsd` instance (`fsd2`) so both the FAT32 and ext2 partitions already on
the card are mounted at once, at boot, permanently.

**Design**: `src/kernel.c3` spawns `fsd2` right after `fsd`, gated on a
new `board::HAS_SECOND_FS_PARTITION` (plus `FS_PARTITION_2_START_SECTOR`)
— false on the Duo's original config and on QEMU's default `disk.img`,
so this is additive, not a behavior change for anything not opted in.
`src/process.c3`'s `Process.namespace` gets a second, fixed entry:
`"/2/" -> fsd2_pid`, populated at `create_process()` time exactly like
the existing `"" -> fsd_pid` entry. `SYS_FS_PARTITION_INFO` now reads a
new per-process `Process.fs_partition_start` field (set via
`setup_fsd_mappings()`) instead of `board::FS_PARTITION_START_SECTOR`
directly, so `fsd`/`fsd2` — two copies of the exact same binary — each
learn their own partition's start sector at boot despite being
identical code. `SYS_NS_RESOLVE` gained a second out-parameter (matched
prefix length), so `fs_read`/`fs_write` (`user/user.c3`) can strip
`"/2/"` before building the wire-format request — `fsd.c3`/`fs/fat32.c3`
/`fs/ext2.c3` needed zero changes, they already only ever see bare
filenames.

**Real bug found**: `readfile2` (a new shell command targeting `/2/`)
produced no output at all on QEMU's default single-partition `disk.img`
— not even the coded fallback message. Root cause: `fsd2` finds no
filesystem on that image and, at the time, called `fs_panic()` (fatal,
`exit()`s) on "no recognized filesystem found". `SYS_EXIT` frees the
process's slot; the very next process created (the shell) reuses that
same freed pid via `create_process()`'s first-free-slot scan; the
shell's own `"/2/"` namespace entry — populated from the stale
`fsd2_pid` global — now points at the shell's *own* pid. `ipc_send` to
yourself deadlocks (parked waiting for a receive you can't issue until
the send call itself returns). Fixed narrowly: `fsd.c3`'s `fs_mount()`
no longer panics on "no recognized filesystem" — it prints and returns,
leaving `fs_type = FS_TYPE_NONE`, which `main()`'s existing dispatch
already handles cleanly (a `-1` reply for every verb, the same shape as
the already-proven "ext2 rejects writes" path). This is a narrow fix for
one trigger, not the underlying hazard class: any namespace entry is a
plain pid snapshot taken once at the *resolving* process's own creation
time, never refreshed, so a *target* that later exits and whose slot
gets reused by something else would silently misroute too — `proc_by_pid`
correctly rejects a fully-dead, unreused pid, but has no way to detect
"same pid, different instance". `SYS_JOIN`'s existing `Process.generation`
field is the right building block for a real fix (documented as a
"KNOWN GAP, not fixed here" comment at `SYS_IPC_SEND` in `src/entry.c3`);
not implemented this session.

**A red herring, chased down properly rather than waved off**: after
the deadlock fix, the QEMU regression suite started showing
`racetest: a=0 b=0` instead of the historical `a=1 b=0`. Compared
directly against the pre-multi-mount build (git stash, rebuild, same
exact command sequence) — that build reproduced `a=1 b=0` every time,
confirming the shift was real, not noise. But reading `race_thread_a`/
`race_thread_b`/`echod.c3` shows each racing thread is a full `RFPROC`
child with its own distinct pid and echod's reply path is fully
serialized by IPC's own rendezvous — there's no code path where one
thread's reply lands in the other's mailbox by design. Since the
baseline was *already* `a=1 b=0` (not `a=1 b=1`) before any of today's
changes, this is a pre-existing, narrow race in the IPC/threading path
that predates this session; the extra `fsd2` process just shifts
pids/scheduling enough to flip which manifestation shows (one-loses to
both-lose). Logged here as a known separate issue, not fixed — it's
orthogonal to this feature and every other test passes correctly.

**Verified on QEMU**: a new `build/disk_dual.img` (FAT32 at sector 0 —
matching the same fixed `FS_PARTITION_START_SECTOR` the default
`disk.img` uses, an earlier attempt at sector 2048 just meant the first
`fsd` found nothing — and ext2 at sector 18432, `scripts/build.sh`) via
new `scripts/launch64_dual.sh`: both `fsd: FAT32 mounted...` and
`fsd: ext2 mounted...` appear at boot, `readfile`/`readfile2` return
correct, distinct content in the same boot, and the full regression
suite passes otherwise unchanged.

**Verified on real Duo hardware**, both partitions already on the card
from earlier sessions, no board.c3 edits needed: `readfile` (mount 1,
FAT32) returned `Hello from disk!`; `readfile2` (mount 2, ext2) returned
`Hello from shell!` — surprising at first (not the `Hello from ext2!`
recorded in the ext2-verification entry above), until traced to the
`ext2 write support` entry's own real-hardware `writefile` test, which
overwrote that exact file and was never reverted (only the temporary
`FS_PARTITION_START_SECTOR` swap was). Confirmed this was real,
correctly-routed ext2 data and not a routing bug by checking the
console's own `sdd: rw sector=...` lines: mount 2's reads land at
absolute sector ≈2,103,884, well inside the ext2 partition (starting at
2,099,200) and nowhere near mount 1's much lower sector range — two
distinct mounts, two distinct real files, same boot. Added a `newfile2`
shell command (mirrors `newfile`, routed through `/2/`) for an
unambiguous write-path check independent of that stale-data question:
creates a new file on the ext2 mount and reads it back —
`Created by newfile2 test`, correct, with I/O sectors again confirmed
inside the ext2 partition range.

**Files changed:** `src/process.c3` (`fsd2_pid`, `Process.fs_partition_start`,
`setup_fsd_mappings()`, second namespace entry), `src/entry.c3`
(`SYS_FS_PARTITION_INFO` reads the per-process field, `SYS_NS_RESOLVE`'s
prefix-length out-param, the IPC hazard comment), `src/kernel.c3`
(conditional `fsd2` spawn), `boards/duo/board.c3` /
`boards/qemu/board.c3` (`HAS_SECOND_FS_PARTITION`,
`FS_PARTITION_2_START_SECTOR`), `user/user.c3` (`ns_resolve()`'s new
out-param, prefix-stripping in `fs_read`/`fs_write`), `user/shell.c3`
(`readfile2`, `newfile2`), `user/fsd.c3` (non-fatal `fs_mount()` on no
filesystem found), `scripts/build.sh`/new `scripts/launch64_dual.sh`
(`disk_dual.img`).

---

## 2026-08-18 — A real timer primitive, replacing sdd.c3's guessed busy-wait counts

`user/sdd.c3` had a standing, self-documented gap: no `rdtime` access
from user mode (`scounteren.TM` never enabled), so every wait loop —
command-complete, data-ready, transfer-complete, the one-time clock/
reset waits — was a raw iteration count (`SD_WAIT_MAX`/
`SD_SETUP_WAIT_MAX`) with no real correspondence to wall-clock time.

**Real values confirmed, not guessed**, same discipline as this
project's SDHCI register maps: Duo's real `timebase-frequency` (25MHz)
read directly from the real devicetree in `duo-buildroot-sdk`; QEMU
`virt`'s (10MHz) extracted directly from the actual
`qemu-system-riscv64` binary via `-machine virt,dumpdtb=...` + `dtc`,
not assumed from general RISC-V/QEMU folklore. Real per-wait timeout
budgets (100ms command-inhibit, 1000ms command-complete, 20ms clock-
stable, 1000ms each for data-ready/transfer-complete) sourced from the
real U-Boot generic SDHCI driver, the same file already read once
earlier this session for the SDHCI_TRNS_READ bug.

**Kernel**: `enable_user_timer_access()` (`src/entry.c3`) sets
`scounteren.TM`, called once at boot next to the existing
`enable_external_interrupts()`. **User-mode**: `rdtime()`
(`user/user.c3`) — direct CSR read via the opaque-string `asm()` form
bridged through a memory temp, not the structured `asm {}` block (which
doesn't recognize `rdtime`/`csrr` at all) and not raw a0 (a real hazard
already found once in this exact codebase, in `entry.c3`'s own
`read_reg` macro — the compiler can silently clobber a value it still
thinks is live in a0). Every one of `sdd.c3`'s five wait loops converted
to `rdtime()`-bounded real time; `SD_WAIT_MAX`/`SD_SETUP_WAIT_MAX`
removed entirely.

Verified on QEMU (full regression suite — `sdd.c3` isn't even spawned
there, confirms the kernel-side change doesn't regress anything else)
and real Duo hardware: every wait now reports genuine, sensible
microsecond figures (`ready after 251us`, not a meaningless iteration
count) with `readfile`/`newfile`/`writefile` all still correct.

Also noticed, while reading the real-hardware output, that
`fip.bin`'s write-protected cluster count had jumped from ~19 to 150 —
initially concerning, but the real, benign explanation: the FAT32
partition was resized much smaller during yesterday's ext2 work, and
`mkfs.vfat` auto-selects cluster size by volume size (4KB clusters on
the new 1GiB partition vs. the original 32KB on the 58GB card) — same
file, proportionally more (smaller) clusters. Confirmed via
`610816 ÷ 150 ≈ 4072 bytes`, essentially exactly 4096, and independently
by `readfile`/`newfile` both still returning correct real content — not
a regression from this session's own changes.

**Explicitly out of scope**: `sstc`/`stimecmp` timer *interrupts* (real
preemptive sleep/scheduling) — `sdd.c3`'s actual problem was an
inaccurate busy-wait bound, not a need to yield the CPU while waiting; a
plain elapsed-ticks read solves that completely. Timer interrupts are a
separate, larger feature (touches the scheduler, not just one driver).

**Files changed:** `src/entry.c3` (`enable_user_timer_access()`),
`src/kernel.c3` (call it), `user/user.c3` (`rdtime()`), `user/sdd.c3`
(`SD_TIMEBASE_HZ`, real per-wait timeout constants, every wait loop
converted, `print_uint()` added, `SD_WAIT_MAX`/`SD_SETUP_WAIT_MAX`
removed).

---

## 2026-08-17 (7) — ext2 write support

**Continuing from this same day's ext2-verification entry.** Brought
`user/fs/ext2.c3` up to the same level FAT32 has: create, overwrite,
grow. Reused `fsd.c3`'s generic write-protection machinery verbatim —
`fs_reserve_sector_range()`, `fs_set_protected_entry()`/
`fs_is_protected_entry()`, enforcement in `fs_write_sector()` — nothing
new needed there, which was the actual point of building the
abstraction earlier today.

What's structurally different from FAT32's write path, and where all
the new code went: ext2 allocates space via **bitmaps** (one bit per
block/inode in a group — `ext2_alloc_block()`/`ext2_alloc_inode()`), not
a linked list like the FAT table, and needs a genuinely separate
allocation step for **inodes** (a fixed-size, pre-allocated table —
FAT32 has no equivalent; creating a file there only ever needed a free
cluster + a free directory slot). Directory entries are variable-length
records, but v1 sidesteps splitting an existing entry's trailing
`rec_len` (a real ext2 allocator technique) — creating a file always
appends a fresh directory block containing just that one entry, a
documented inefficiency parallel to FAT32 write's own "shrinking doesn't
free the now-excess clusters" gap. Free-space bookkeeping
(`bg_free_blocks_count`/`s_free_blocks_count` and their inode
counterparts) is deliberately not maintained — a real `e2fsck` would
flag the mismatch and offer to fix it, but nothing about it corrupts
data or blocks a real ext2 driver from reading the volume; accepted,
documented gap. Directory `i_size` *is* kept correct when a directory
gains a block, since real ext2 readers use it to know how far to scan —
unlike the free-count fields, getting this wrong could make a real
Linux box's `ls` misbehave.

**Worked correctly on the very first real-hardware attempt** — no bugs
found this time, unlike `newfile`'s first real-hardware run during
FAT32 write support (the shared-root-directory-cluster reservation bug)
or the SD read-data-loss bug earlier today. Verified in order, on both
QEMU (`scripts/launch64_ext2.sh`) and real hardware (the same temporary
`FS_PARTITION_START_SECTOR`-swap procedure used for read verification,
reverted afterward): `writefile` (overwrite), `readfile` (confirms it),
`newfile` (genuinely new inode + directory entry, confirmed via its own
readback), `protectedwrite` (correctly rejected — exercises the generic
filename check same as FAT32's does). Full existing FAT32 regression
suite re-run on QEMU too, unaffected.

**Files changed:** `user/fs/ext2.c3` (bitmap allocation, inode read-
modify-write, directory-entry creation, `ext2_write()`,
`ext2_reserve_protected()`), `user/fsd.c3` (`fs_mount()`'s
`FS_TYPE_EXT2` branch gains write-protection setup via a new shared
`fs_reserve_protection_summary()` helper; `main()`'s `FS_WRITE` dispatch
gains an `ext2_write()` branch). No shell/wire-protocol changes needed —
`writefile`/`newfile`/`protectedwrite` already worked against whichever
backend was mounted.

---

## 2026-08-17 (6) — ext2 verified on real Duo hardware

**Continuing from this same day's filesystem-abstraction entry.**
`user/fs/ext2.c3` had only ever run on QEMU; this confirmed it on the
real board. The catch: the Duo's only SD card is also what boots it —
BootROM reads `fip.bin` directly off the FAT32 `DUOBOOT` partition (the
whole session's own flashing workflow already proved this: mount FAT32,
copy a file literally named `fip.bin` onto it, unmount, boot), so a
card without that file findable on a FAT32 partition can't boot this
board at all. Swapping in a second, dedicated SD card was ruled out for
exactly that reason — the board only has one slot.

**Repartitioned the boot card** instead: shrunk the FAT32 partition (a
full reformat, not a resize — `fatresize` isn't installed, and shrinking
only the MBR table entry without also shrinking the FAT32 filesystem's
own internal structures would leave it believing it's larger than its
new boundary, a real corruption risk; only 736K was actually in use, so
reformat-and-restore was both simpler and safer) to 1GiB at its
original start sector (2048, unchanged — so
`board::FS_PARTITION_START_SECTOR` needed no permanent code change), and
added a second 1GiB ext2 partition right after it. The user ran the
actual `sfdisk`/`mkfs.vfat`/`mke2fs` commands (root-only, and this
session's sandbox has no root at all — confirmed, `sudo` needs a
password); everything else — restoring `fip.bin`/`hello.txt` onto the
reformatted boot partition, seeding the ext2 partition via `debugfs -w`
directly on the block device (the mounted ext2 filesystem itself is
root-owned by default, unlike FAT's no-real-ownership model, so a
regular mount + copy hit a permission error; writing straight to the
device — the same approach already used for the QEMU test image —
sidesteps that) — needed no elevated privileges.

Temporarily pointed `board::FS_PARTITION_START_SECTOR` at the new ext2
partition's start sector, rebuilt, reflashed `fip.bin` (still onto the
FAT32 partition — that's what BootROM reads regardless of which
partition `fsd` itself mounts), and confirmed on the real console:
`fsd: ext2 mounted, block_size=4096 inode_table_block=67` (4096, not the
1024 QEMU's smaller test image used — a genuinely different block size,
still within `EXT2_MAX_BLOCK_SIZE`), and `readfile` returned the real,
correct `Hello from ext2!` content. Reverted the constant back to
`2048`, rebuilt, reflashed, and confirmed the board returned to its
normal FAT32-mounted state — the same `Hello from disk!` content as
always. The ext2 test partition is left in place on the card afterward,
inert and harmless.

**Files changed:** none permanently — `boards/duo/board.c3`'s
`FS_PARTITION_START_SECTOR` edit was temporary and reverted to its
committed value before this entry was written.

---

## 2026-08-17 (5) — fsd: filesystem backend abstraction, plus a real ext2 read-only backend

**Continuing from this same day's FAT32 write-support entry.** The ask:
real ext2 support, with "a good file structure, interface and
abstraction" prepared first — `fsd` only ever spoke one on-disk format,
and `user/fsd.c3` mixed the IPC/wire protocol, the filesystem-agnostic
sector-I/O + write-protection machinery, and FAT32-specific structure
parsing all in one file. Adding ext2 the way FAT32 was added would have
either duplicated the generic parts or tangled two unrelated formats
together.

**Split into three files**, all still `module user;` (matching every
other user-mode file — `c3c compile-only` already takes an explicit
source-file list per binary, so this needed no new build machinery,
just adding files to `scripts/build_user.sh`'s existing `fsd` line):
`user/fsd.c3` (generic core — IPC loop, sector I/O, write protection,
mount-time backend dispatch), `user/fs/fat32.c3` (the existing FAT32
logic, moved and renamed to a consistent interface —
`fat32_probe`/`fat32_mount`/`fat32_read`/`fat32_write`/
`fat32_reserve_protected` — otherwise unchanged), `user/fs/ext2.c3`
(new). No function-pointer/vtable dispatch — checked this codebase for
precedent first (structs here are plain data: `Process`/`Mount` in
`src/process.c3`, `@packed` wire layouts like `Virtio_blk_req`) and
found none, so `fsd.c3` just holds an `fs_type` global and dispatches
through a couple of `if`s.

**Write protection generalized** from FAT32-specific clusters to plain
absolute sector ranges (`fs_reserve_sector_range()`/
`fs_sector_is_reserved()`, replacing the old cluster-number allowlist) —
each backend now computes its own protected file's ranges in whatever
unit is natural to it and hands `fsd.c3` sector numbers; `fsd.c3` itself
never needs to know what a "cluster" or "block" is. The exact-entry
protected-slot check was already sector+offset based, so it moved over
unchanged, just via a new `fs_set_protected_entry()` setter instead of
backends touching `fsd.c3`'s globals directly.

**ext2 backend, read-only, root directory only** (matching FAT32's own
first pass): superblock at the fixed byte offset 1024 (magic `0xEF53`),
block group 0's descriptor for the inode table location, direct block
pointers only (`i_block[0..11]` — no indirect blocks in this pass), and
variable-length directory-entry records (unlike FAT32's fixed 32-byte
entries, ext2 names aren't padded/fixed-width, so no 8.3-style
conversion is needed at all — matching by exact length + bytes instead).
Probed first in `fs_mount()`'s dispatch, ahead of FAT32: its magic is a
specific 16-bit value at a fixed offset, a much more unambiguous
signal than FAT32's `0xAA55` (shared with plain MBRs and every other
x86-bootable format).

**Verified on QEMU**: the full existing regression suite
(`readfile`/`writefile`/`newfile`/`protectedwrite`/`hello`/`ping`/
`p9test`/`nstest`/`rforktest`/`sandboxtest`/`racetest`) against the
refactored FAT32 path — byte-for-byte identical output to before the
split. A new, additional test image (`build/disk_ext2.img`, built via
`mke2fs`/seeded via `debugfs -w` — no root needed, same spirit as how
`mtools` seeded the FAT32 image) and `scripts/launch64_ext2.sh` (a
near-duplicate of `launch64.sh` pointing at the ext2 image instead)
confirm `ext2_probe()` picks the right backend and `readfile` returns
the real, correct content of a file seeded directly into the ext2 image.
Also confirmed the Duo cross-build (`build_duo.sh`/`build_duo_fip.sh`)
compiles cleanly against the new multi-file layout — **not yet flashed
or verified on real hardware**, since that needs someone physically
power-cycling the board and reading back the console.

**Files changed:** `user/fsd.c3` (rewritten as the generic core),
`user/fs/fat32.c3` (new — moved from the old `fsd.c3`),
`user/fs/ext2.c3` (new), `scripts/build_user.sh` (new source files for
the `fsd` binary), `scripts/build.sh` (additional `disk_ext2.img` build
step), `scripts/launch64_ext2.sh` (new), `disk-ext2/hello.txt` (new
ext2 test-image seed file).

---

## 2026-08-17 (4) — fsd: full FAT32 write support, structurally blocked from ever touching fip.bin

**Continuing from this same day's read-only FAT32 entry.** The ask:
real write support (create new files, grow existing ones — not just
overwrite-in-place), with a guarantee stronger than "don't write to
fip.bin by name" — a bug in the new allocator/directory code shouldn't
be able to reach the file that boots this board either.

**Design**: `fs_init()` looks up `fip.bin`'s real directory entry and
walks its entire cluster chain once at mount time, recording every data
cluster it occupies in a small reserved-cluster allowlist. `diskd_rw()`
— the one function every write in `fsd.c3` funnels through, whether it's
file data, a FAT-table update, or a directory entry — refuses any write
landing on a reserved cluster; `fs_write_disabled` starts `true` and
fails the whole write path closed if the reservation ever can't be built
completely (list overflow, a read failure mid-chain-walk), rather than
risk protecting only part of the file. A separate, fast filename check
(`fs_is_protected_name`) rejects `fip.bin` by name before any lookup at
all — belt-and-suspenders, not the only line of defense.

**Real bug found on the very first real-hardware write attempt**: `newfile`
(a new shell command added specifically to exercise directory-entry
creation, since `writefile` only ever overwrote the pre-existing
`hello.txt`) failed silently — no error, no console output, nothing.
Root cause: the first version reserved fip.bin's directory-entry
*cluster*, not just its exact 32-byte entry — but in FAT32 the root
directory is itself just an ordinary cluster chain, shared by *every*
file's entry. Reserving "the cluster containing fip.bin's entry"
reserved the whole shared root-directory cluster, silently blocking any
new file's directory entry from ever being written there too — a subtle
but real design bug caught immediately by testing on the real card, not
by review. Fixed by tracking the protected entry's exact
`(sector, offset)` separately from the coarser cluster-level allowlist
(safe at that granularity precisely because file *data* clusters, unlike
the directory, are never shared between files), checked explicitly by
the two functions that ever write directory-entry bytes.

**`sdd.c3`**: implemented the write half of `sdd_block_rw` (CMD24,
symmetric to the already-working CMD17 read path) — same "no `print()`
calls between the ready-check and the buffer loop" fix that resolved the
read-side data-loss bug earlier today, applied here on the same
reasoning before it could bite on the write side too.

**Verified on real hardware, in order**: boot-time reservation confirms
fip.bin's real cluster count gets found and reserved; `newfile` creates
a genuinely new file and reads its exact content back; `writefile` still
round-trips against `hello.txt`; `protectedwrite` (new shell command)
deliberately attempts `fs_write("fip.bin", ...)` and gets rejected; a
full power-cycle afterward boots cleanly end to end — the strongest
proof available that `fip.bin` survived every step of this session's
testing completely intact.

**Files changed:** `user/fsd.c3` (reserved-cluster tracking and
enforcement, cluster allocation, FAT-entry writes mirrored across both
copies, directory-entry creation/update, `fs_do_write()`), `user/sdd.c3`
(`sdd_block_rw`'s write path), `user/shell.c3` (`newfile`,
`protectedwrite` test commands).

---

## 2026-08-17 (3) — fsd: real, read-only FAT32 support, and a shallow-FIFO PIO timing bug

**Continuing from this same day's earlier entries.** After a short
hardening pass (a sector-bounds check in `sdd_block_rw`, a negative-
length clamp on `fsd`'s untrusted request length), the bigger decision:
replace `fsd`'s original tar-based backend — always a placeholder, capped
at `FILES_MAX=2`, full-disk rewrite on every write — with a real FAT32
reader. Read-only first: on the Duo, `fsd` now points directly at the
*same* `DUOBOOT` partition that boots the board (`board::
FS_PARTITION_START_SECTOR = 2048`, `0` on QEMU's whole-disk test image),
which is only safe because a read-only driver can misparse data but can't
corrupt it. `user/fsd.c3` was rewritten around real BPB/directory-entry/
FAT-chain parsing (root directory only, 8.3 names only, no boot-time
caching — see the file's own header comment for the full v1 scope). A new
syscall, `SYS_FS_PARTITION_INFO`, mirrors the existing `SYS_DISKD_INFO`
pattern so `fsd` — one board-agnostic binary — can learn the board-only
`board::FS_PARTITION_START_SECTOR` constant at runtime. `sdd_block_rw`
lost its old `DATA_SECTOR_OFFSET`/bounds-check pair (sized for the old
fsd's small reserved region, and actively wrong once fsd started
addressing real absolute sectors) in favor of unconditionally rejecting
writes — there's no longer a well-defined "safe to write" region at this
layer. QEMU's disk image moved from a hand-rolled tar to a real
`mkfs.vfat`-built FAT32 image (`scripts/build.sh`, `mtools`/`dosfstools`,
no root needed).

Confirmed correct on QEMU immediately: byte-for-byte match against a real
`mkfs.vfat` image, `readfile` returns real file content, `writefile`
cleanly no-ops. Real hardware was a different story: `fsd: bad FAT32 boot
sector signature`, even though the SD read itself reported clean success.
First fix attempt (a wait-budget increase, on a "maybe it just needs more
polling time" theory) was flagged directly — right call, since the next
real-hardware run showed the *identical* failure, proving the guess
wrong. Real diagnosis after that: stage-by-stage prints in
`sdd_block_rw` caught the actual, first concrete bug — `sd_send_cmd`
defined `SD_TRNS_READ` (Transfer Mode's read/write direction bit) but
never set it, so every data command left the controller configured for a
*write*-direction transfer regardless of which command was issued; CMD17
(read) was getting a card response but no data. Fixed by inferring
direction from the command index. That took the SD-protocol layer from
timing out to completing cleanly — but the *data itself* still wasn't a
valid boot sector.

What followed was a careful, non-guessing elimination hunt (canary bytes
pre-filled before every read to rule out a no-op copy loop; a raw read of
absolute sector 0 to separate "PIO path untrustworthy" from "wrong
sector"; a same-sector re-read to check determinism; a full 512-byte hex
dump diffed byte-for-byte against the known-good QEMU reference). That
diff nailed it precisely: every real-hardware PIO read was losing exactly
its first 16 bytes and padding the last 16 with zero — confirmed via two
independent landmarks landing exactly 16 bytes off (the `hidden_sectors`
BPB field reading back as the real partition's own LBA start, and the
`0xAA55` signature appearing 16 bytes early). A background research pass
into the real vendor driver source (`duo-buildroot-sdk`) ruled out the
PHY RX delay-line registers (`CVI_SDHCI_PHY_TX_RX_DLY` etc. — byte-
identical to the real driver's own fixed values for this speed mode) and
pointed at `sd_send_cmd`'s blanket `SD_INT_STATUS` clear, which for a
data command could wipe the data-ready bits before the data phase ever
saw them. Narrowing that clear cut the loss from 16 bytes to 8 — real
progress, but a further experiment (removing the clear entirely, one
combined write vs. two, different orderings) kept producing a *byte-for-
byte identical* 8-byte loss no matter what was tried, which ruled out
register-write sequencing as the actual variable.

What was constant across every still-broken version: several
`print()`/`print_hex32()` calls — slow, one-character-at-a-time UART
writes — sitting between CMD17 completing and the first
`sd_reg_read(SD_BUFFER)`. The card's DAT lines start pushing data almost
immediately after command acceptance, and this SDHCI clone's PIO FIFO is
shallow enough that those prints cost real, already-arrived words before
the host ever looked — deterministically, since the same code path costs
the same wall-clock time every run. Moving every diagnostic print to
*after* the full 128-word read loop fixed it outright: real hardware now
reports genuine wait counts (thousands of iterations, not the "0 iters"
that had actually meant "already too late") and the boot sector parses
correctly — `partition_start=2048 root_cluster=2 sectors_per_cluster=64`.
`readfile` against the real, externally-placed `hello.txt` on the
physical `DUOBOOT` partition returns its exact real content end to end.

**Files changed:** `user/fsd.c3` (full FAT32 rewrite, replacing the tar
backend), `user/sdd.c3` (`SD_TRNS_READ` fix, `sd_send_cmd`'s `INT_STATUS`
clear narrowed and made data-command-aware, `sdd_block_rw`'s data-ready
wait moved to `INT_STATUS`'s own ready bit, all per-request diagnostics
deferred until after the buffer is fully drained), `user/user.c3`
(`fs_partition_info()`), `src/entry.c3` (`SYS_FS_PARTITION_INFO`),
`boards/duo/board.c3` / `boards/qemu/board.c3`
(`FS_PARTITION_START_SECTOR`), `scripts/build.sh` /
`scripts/launch64.sh` (FAT32 test image via `mkfs.vfat`/`mtools`,
replacing the old tar disk image).

---

## 2026-08-17 (2) — sdd: real operating-speed clock, confirmed on hardware

**Continuing straight from this same day's earlier entry** (sdd cleanup
+ the PLIC interrupt-storm investigation/revert). Last remaining
follow-up: `sdd` had been running the whole time — enumeration and
actual block I/O alike — on whatever slow clock BootROM happened to
leave active, since raising it was previously disabled after an earlier
version broke a working clock via a full-word register clobber (see the
PLIC-storm entry above and the original bring-up entries for that
history).

Re-added `sdd_raise_clock()`, called once after `CMD7`/`SELECT_CARD`,
targeting ~23.4MHz (375MHz source / (2×8)) — SD default-speed's own
25MHz ceiling, appropriate since this driver never sends `CMD6` to
negotiate high-speed mode. Every step is read-modify-write this time,
never a full-word write to `SD_CLOCK_SWRESET`: disable the card clock
(clear only that bit), change the divisor (RMW, preserving the
timeout-control/reset bytes), wait for internal-clock-stable, re-enable
the card clock. Confirmed via readback on real hardware:
`clock_reg=0x000e0807` — divider field `8` (exactly the target),
`INT_STABLE=1`, `CARD_EN=1` — and `writefile`/`readfile` both still
round-trip correctly at the new speed.

**Files changed:** `user/sdd.c3` (`sdd_raise_clock()`, called from
`sdd_enumerate()` after `CMD7`).

---

## 2026-08-17 — sdd cleanup, and a real PLIC hardware quirk found chasing interrupt-driven SD I/O

**Continuing from this same week's SD-storage entries.** Two follow-ups
requested after the first working `writefile`/`readfile` round trip:
trim `sdd.c3`'s bring-up-era diagnostics now that the driver works, and
convert its block I/O from busy-polling to interrupt-driven completion
(PLIC `IRQ_SDHCI`), matching `diskd`'s existing pattern. The first
landed cleanly. The second uncovered a genuine, undocumented hardware
quirk in this board's PLIC and had to be reverted.

**Trim:** removed one-off bring-up diagnostics that had done their job
(`0xDEADBEEF` MMIO write test, clock-gate/PLL/power-control readback
dumps, `HOST_CONTROL2` dump, a dead disabled `sdd_raise_clock`
function), condensed the enumeration stage markers to single lines,
kept `clock_stable` and the per-command markers — still genuinely
useful if this ever needs revisiting on a different card.

**Interrupt-driven I/O attempt:** added `board::IRQ_SDHCI` routing
through `entry.c3`'s `handle_trap` (mirroring `diskd`'s existing
`IRQ_VIRTIO_BLK` handling exactly) and enabled it in the Duo's own
`plic_init()` (a second priority + a second enable-word, since IRQ 36
falls outside `IRQ_VIRTIO_BLK`'s first 32). `sdd_block_rw`'s two
polling waits (buffer-ready, transfer-complete) became a shared
`sdd_wait_for_irq()` blocking on `SYS_IPC_POLL`, same shape as
`diskd`'s own interrupt wait. QEMU regression stayed fully clean
throughout (`IRQ_SDHCI=0` there, a dead sentinel like `IRQ_VIRTIO_BLK`
was on the Duo before this).

**Real hardware result: a total, permanent external-interrupt storm.**
The moment `sdd` turned on its own `SIGNAL_ENABLE`, the CPU started
taking `SCAUSE_SUPERVISOR_EXTERNAL` traps continuously, forever — but
PLIC `claim()` at context 1 returned 0 (nothing pending) on every
single sample, every time, across the whole investigation. Chased
through several well-reasoned but ultimately wrong theories before
finding the real cause:

- Ruled out **PLIC context number / register-offset formulas** —
  independently confirmed correct via three sources: the real
  devicetree's `interrupts-extended` property, OpenSBI's own parsed
  `s_cntx_id` (the actual M-mode firmware running on this board), and
  Linux's `irq-sifive-plic.c`. `PLIC_S_CONTEXT=1` was right all along;
  this PLIC has exactly two contexts for hart0 (context 0 = M-mode,
  explicitly marked invalid via the DT's `0xffffffff` sentinel; context
  1 = S-mode, the real one) — no hidden alternate context, no
  cvitek-specific offset override anywhere in the SDK.
- Ruled out **the IRQ number itself** — found and read the official
  CV1800B/CV1801B preliminary datasheet
  (github.com/milkv-duo/duo-files), which confirms IRQ 36 = "SD0
  interrupt" in the real interrupt-source table. Not a typo, not an
  off-by-one.
- Ruled out **stale/uncleared `SD_INT_STATUS` bits** two different
  ways — first by explicitly clearing the whole status register before
  ever enabling `SIGNAL_ENABLE`, then by widening every status-clear
  write from "just the bits this call consumed" to the entire register
  (reasoning: `SD_INT_ERROR` is a summary bit over eleven separate
  detail bits at bits 16-25 that the narrower mask never touched, a
  real and independently-worth-fixing bug — just not *this* bug).
  Neither changed the storm's signature at all.
- Ruled out **PLIC completion sequencing** — tried unconditionally
  completing `IRQ_SDHCI` at the PLIC level even on a spurious (0)
  claim, on the theory this silicon might need it. No change.
- **Found via direct isolation, not another guess:** every test so far
  had changed the PLIC's own enable-bit for source 36 and the SDHCI
  device's own interrupt-enable registers *together*, every time — so
  every failure was equally consistent with either being the cause.
  Split them apart: left the device's `SIGNAL_ENABLE`/`INT_ENABLE`
  writes untouched, but commented out only the PLIC enable-bit write
  for source 36. Result: enumeration completed perfectly end-to-end
  (`CMD0` through `CMD7`, "card ready"), zero storm, zero spurious
  traps. Conclusive: setting this one specific PLIC enable bit alone —
  independent of whether the device it's associated with ever actually
  asserts anything — reliably wedges this exact PLIC into a permanent
  storm. A real, undocumented silicon/PLIC erratum for this source (or
  possibly this whole context), not anything in this driver's own
  logic, and not something any of the three independently-checked
  software sources (DT, OpenSBI, Linux driver) predicted or would
  likely have caught, since none of them exercise every one of this
  chip's 101 interrupt sources in practice.

**Reverted:** `sdd_block_rw` back to busy-polling (`SD_PRESENT_STATE`
for buffer-ready, `SD_INT_STATUS` for transfer-complete) — the exact
design already proven working end-to-end on real hardware before this
attempt. `sdd_wait_for_irq()` removed. The Duo's `plic_init()` keeps
the IRQ_SDHCI enable-bit write in place but commented out, with the
full reasoning, so a future attempt doesn't have to rediscover this
from scratch. `entry.c3`'s `IRQ_SDHCI` trap-handler routing and the new
`board::PLIC_PENDING_BASE`/`PLIC_PENDING_PAGE` infrastructure (added
for this investigation's own diagnostics) are left in place, unused but
ready, in case this gets revisited with real hardware debug tooling
(logic analyzer on the physical IRQ line, or vendor engineering
support) rather than source-reading alone.

**Files changed:** `user/sdd.c3` (trim, revert to polling, wider
status-clear kept as a real independent fix), `boards/duo/board.c3` /
`boards/qemu/board.c3` (`PLIC_PENDING_BASE`/`PAGE`, IRQ_SDHCI enable
commented out), `src/entry.c3` (`IRQ_SDHCI` routing added and kept,
temporary diagnostic prints added and removed), `src/process.c3`
(`PLIC_PENDING_PAGE` mapping).

---

## 2026-08-16 (7) — Real SD-card storage for the Duo: Stage 4, full working round trip

**Continuing straight from this same day's "(6)" entry.** Stages 1-3
(kernel plumbing, `sdd`'s driver skeleton, build wiring) were done and
QEMU-verified; this entry is Stage 4 — real hardware bring-up — which
took roughly a dozen flash/power-cycle round trips and turned up four
real driver bugs, one serious pre-existing kernel bug, and one real
safety hazard, before ending in a genuine, confirmed `writefile`/
`readfile` round trip through `fsd` -> `sdd` -> physical SD card on real
Milk-V Duo hardware.

**The chase, in order:**

1. **Wrong pad drive-strength values.** `sdd_pad_power_clock_init` had
   CLK/CMD/DAT0-3 all at value 2 and PWR_EN at 1 — backwards versus
   `duo-buildroot-sdk/u-boot-2021.10/board/cvitek/cv180x/sdhci_reg.h`'s
   actual `REG_SDIO0_*_PAD_VALUE` constants (only CLK and PWR_EN should
   be 2; everything else is 1). Read from memory instead of the real
   header the first time; fixed by actually reading it.
2. **Clock-divisor field overflow.** The initial ~400kHz enumeration
   clock computed `256 << 8` for the divider field, which needs 9 bits
   and silently overflowed into the adjacent timeout-control byte.
3. **Missing vendor PHY TX/RX delay-line reset.** `cv180x_base.dtsi`'s
   `sd:` node sets `reset_tx_rx_phy`, which `cvi_sdhci_probe()` acts on
   with three extra register writes (`CVI_SDHCI_VENDOR_OFFSET`,
   `CVI_SDHCI_PHY_TX_RX_DLY`, `CVI_SDHCI_PHY_CONFIG`) this driver
   entirely omitted the first time through — ported from general SDHCI
   spec knowledge only, never having actually read the vendor driver.
4. **Self-inflicted clock clobbering.** A real, hard-won piece of
   evidence: raw register readback showed the clock-control field
   already had `INT_STABLE=1` *before* this driver's own software-reset
   attempt — meaning BootROM (which has to read this exact card to load
   FSBL at all, on this SD-boot board) had already left the SDHCI IP
   correctly clocked and running. `SDHCI_SOFTWARE_RESET.RST_ALL` then
   got stuck permanently asserted (confirmed: still asserted after a
   20-million-iteration busy-wait, ruling out "just need a bigger
   timeout" first), and this driver's *subsequent* full-word write to
   set the clock divisor was silently force-clearing that stuck reset
   bit as a side effect — without the hardware's own reset FSM having
   actually finished, plausibly the reason the clock could never
   re-stabilize afterward. Fix: stopped asking for a reset this exact IP
   apparently can't cleanly complete, and stopped clobbering a clock
   config that was already demonstrably working — `sdd_init` now skips
   `SDHCI_SOFTWARE_RESET` and its own clock-divisor reconfiguration
   entirely, just uses BootROM's pre-existing clock. Confirmed via
   readback: `clock_stable` went from 0 to 1 the moment this stopped.

5. **The real root cause, once the clock was confirmed stable and
   commands *still* silently did nothing:** every register this driver
   could inspect looked correct — writes to the SDHCI MMIO block
   genuinely landed and persisted (confirmed with an unambiguous
   `0xDEADBEEF` write/read-back test, and later with a real command word
   reading back exactly as written) — yet `PRESENT_STATE` never moved a
   single bit and `INT_STATUS` never showed one flicker of activity, no
   matter what command was issued. Ruled out, in order: the clock-gate
   register (`REG_CLK_EN_0`, already reading `0xFFFFFFFF` before any
   write of ours — not the blocker), the dedicated SD0 reset line
   (`RST_SD0`, confirmed unused by any boot stage, DT never wires it
   up), `SD_SIGNAL_ENABLE` (added, no effect), UHS/preset-value state
   (misread `HOST_CONTROL2`'s bit layout at first and had to correct
   course — real bits: `PRESET_VAL_ENABLE`=0, `VDD_180`=0, `UHS_MODE_SEL`
   =SDR12; no exotic state active at all), and `SDHCI_POWER_CONTROL`
   (already `0x0F`/bus-power-on, confirmed by readback — this driver had
   already gotten it right, just never verified). **Actual cause:**
   `map_page()` (`src/page.c3`) applies `board::PTE_EXTRA_BITS`
   (T-Head's SHARE|CACHE|BUF memory-attribute encoding — see this same
   day's earlier entries on the Sv39 bring-up) to *every* mapping it
   creates, unconditionally — including genuine device MMIO, not just
   RAM. A cached write to a hardware register can sit in the CPU's own
   cache line and never actually reach the device at all (until that
   line happens to get evicted), and a cached read just as easily
   returns a stale value instead of live device state — exactly
   explaining "writes read back correctly (cache hit) while the actual
   hardware shows zero sign of ever having received them." This is a
   real, pre-existing bug that predates this session — it affected the
   PLIC mapping too, from the very first Duo board-abstraction work —
   just never surfaced before, because nothing had done tight MMIO
   polling against real hardware on this board until `sdd`. **Fix:**
   added `map_device_page()` (`src/page.c3`) alongside `map_page()` —
   identical intermediate-table walk (still needs `PTE_EXTRA_BITS` at
   that level, a genuine table-walker requirement, unrelated to the
   leaf's own memory type), but the leaf entry omits `PTE_EXTRA_BITS`
   entirely, landing at Strong-Order/non-cacheable (`docs/devlog.md`
   already noted in passing, during the original Sv39 hang chase, that
   an all-zero SO/C/B/SH/SEC field reads as exactly that). Switched
   every genuine device-MMIO `map_page()` call site to
   `map_device_page()`: PLIC (`process.c3`, and `entry.c3`'s rfork
   child-table setup), `diskd`'s `VIRTIO_BLK_PADDR` mapping, and all
   four of `sdd`'s new MMIO mappings. Left RAM-backed mappings (kernel
   identity map, user image pages, `diskd`'s DMA vq/req buffers) on
   `map_page()`, unchanged. Full QEMU regression re-verified unchanged
   (`board::PTE_EXTRA_BITS=0` there regardless, so this cache-attribute
   distinction is structurally a no-op on that board — real proof this
   was a Duo-only latent bug, not something QEMU's regression suite
   could ever have caught).

   Once this landed: full enumeration succeeded on the very next boot —
   `CMD0` -> `CMD8` (echoed the check pattern correctly) -> `ACMD41`
   ready after 154 tries, `ocr` showing a high-capacity card -> `CMD2`/
   `CMD3` (RCA assigned) -> `CMD7` SELECT_CARD -> "sdd: card ready".

6. **A real safety hazard, caught before it did any damage.**
   `writefile`/`readfile` both printed nothing on first try — not a bug
   in the new addressing, but two separate things. First,
   `fsd.c3`'s `FS_WRITE` handler only ever *updated* a file already
   present in its in-memory table (built once at boot by tar-parsing the
   disk) — no create path existed at all, so a write to a name never
   seen at boot silently no-op'd. Harmless on QEMU (its `disk.tar`
   always pre-seeds `hello.txt`) but meant nothing could ever be written
   to a genuinely blank disk — exactly what a real SD card is on first
   use. Second, and more serious: `fsd`/`sdd` address the SD card as raw
   sectors starting at absolute LBA 0 — the *same* region as this card's
   actual MBR/partition table (confirmed via `lsblk`/`sfdisk`: the
   `DUOBOOT` FAT partition holding this board's own bootable `fip.bin`
   starts at sector 2048, meaning sector 0 is the live MBR). Had
   `writefile` succeeded before this was caught, `fs_flush()` would have
   overwritten the partition table BootROM needs to find that partition
   at all — data would likely survive physically, but the board would
   probably stop booting until the MBR got manually reconstructed.
   `fsd`'s own write-requires-existing-file limitation had been
   accidentally protecting against this the whole time. Fixed both,
   with the user's explicit sign-off before touching addressing at all
   given the real-hardware stakes: added `DATA_SECTOR_OFFSET=64`
   (`user/sdd.c3`), shifting every logical sector fsd addresses into the
   unused ~1MB gap between the MBR and the first partition, comfortably
   clear of both; and added a real create-on-write path to `fsd.c3`
   (first unused slot in `files[]`, `FS_READ` still correctly fails for
   a name that was never written). Full QEMU regression re-verified
   unchanged (its own disk always has `hello.txt` pre-seeded, so the new
   create path never actually triggers there).

**Result: genuine `writefile`/`readfile` round trip on real Milk-V Duo
hardware**, first time this whole project — `fsd: wrote 2560 bytes to
disk` followed by `readfile` correctly printing back `Hello from
shell!`, matching QEMU's own output exactly. Storage is no longer a
QEMU-only feature.

**Left as diagnostic instrumentation, on purpose, not cleaned up yet:**
`sdd.c3` still prints a fair amount of one-time bring-up state
(`clk_en_0`, the `0xDEADBEEF` write-test, `pll_reg`/`bypass_reg`,
`power_control`, `clock_stable`, `host_control2`) and per-stage
enumeration markers. Genuinely useful if this needs revisiting on a
different physical card (drive-strength/timing margins are real
per-card variables), consistent with this project's established
practice of keeping this class of diagnostic (see `entry.c3`'s
`current_pid` trap-print, kept since the original Sv39 chase) rather
than stripping it the moment things work. A later pass could trim the
noisiest of it once this has proven itself across more than one card
and boot.

**Files changed:** `user/sdd.c3` (all of the above: PHY reset writes,
clock-clobber removal, `DATA_SECTOR_OFFSET`, drive-strength/divisor
fixes, diagnostics), `src/page.c3` (`map_device_page()`, refactored
`walk_to_leaf_table()` shared by both), `src/process.c3` and
`src/entry.c3` (PLIC/`diskd`/`sdd` MMIO mappings switched to
`map_device_page()`), `user/fsd.c3` (create-on-write path).

---

## 2026-08-16 (6) — Real SD-card storage for the Duo: sdd, Stages 1-3 done

**Continuing straight from this same day's "(5)" entry.** With boot fully
proven on real hardware, storage (the one explicitly-deferred gap —
`writefile`/`readfile` correctly refused on the Duo since it has no
virtio-mmio) was next. Plan file:
`~/.claude/plans/wise-wobbling-music.md`.

**Design:** a new, separate userland driver, `user/sdd.c3` — the Duo's
SD controller (`cvitek,cv180x-sd`, MMIO `0x04310000`, PLIC IRQ 36) is a
standard SDHCI-compliant controller (sourced from
`duo-buildroot-sdk/u-boot-2021.10/drivers/mmc/cvitek/sdhci-cv180x.c` and
`arch/riscv/dts/cv180x_base.dtsi`'s `sd:` node — real register values,
not reverse-engineered), structurally unrelated to `diskd.c3`'s
virtio-mmio protocol. PIO, not DMA — SDHCI's buffer-data-port register
lets `sdd` read/write one 32-bit word at a time straight into its own
process image, so unlike `diskd` it needs no kernel-allocated physically
contiguous buffer and no `SYS_DISKD_INFO`-style syscall at all. No PLIC
interrupt handling in v1 either — busy-polling `PRESENT_STATE`/
`INT_STATUS` directly, since SDHCI commands complete in microseconds to
low milliseconds and this sidesteps the sscratch-across-blocking-syscall
hazard `diskd`'s own interrupt wait had to solve.

**`board::HAS_SD_BLOCK`/`HAS_VIRTIO_BLOCK`** (both boards define both,
mutually exclusive today) tell `kernel.c3`'s spawn gate which driver
process + kernel-side mapping helper to use for the block device
`HAS_BLOCK_DEVICE` promises exists. Duo: `HAS_BLOCK_DEVICE` flipped from
`false` to `true`, `HAS_SD_BLOCK=true`. QEMU: unchanged behavior,
`HAS_VIRTIO_BLOCK=true`. Either driver lands in the same third boot
slot (pid 3, right after idle/echod), so `fsd.c3`'s hardcoded
`DISKD_PID=3` needed zero changes — confirmed by reading `fsd.c3` in
full first: it only ever speaks the sector-number/512-byte wire protocol
to whatever answers at that pid, no virtio awareness anywhere in it.

**Kernel-side plumbing** (`src/process.c3`): `setup_sdd_mappings`
mirrors `setup_diskd_mappings` but simpler — no virtqueue/request-buffer
`alloc_pages()` call, since PIO needs none. Maps `board::SD_MMIO_BASE`
(the SDHCI block itself) plus three more separate pages the one-time
pad/power/clock bring-up sequence needs: `SD_TOP_PAGE` (`0x03000000`,
holds `REG_TOP_SD_PWRSW_CTRL`), `SD_PINMUX_PAGE` (`0x03001000`, pad
function-select + drive-strength registers), `SD_CLOCK_PAGE`
(`0x03002000`, the SD PLL divider + clock-bypass-select register) — all
sourced from the same vendor headers as the SDHCI base address itself,
not guessed.

**`user/sdd.c3` itself:** `sdd_init` — pad mux, drive strength, power
switch, PLL clock setup, SDHCI software reset, initial ~400kHz
enumeration clock (spec-required: talk to a freshly powered card slowly
before its real speed is negotiated). Then the standard SD Physical
Layer command sequence (CMD0/CMD8/ACMD41/CMD2/CMD3/CMD9/CMD7, raise
clock to ~25MHz, CMD16) — identical for any SDHCI controller, not
chip-specific. Block read/write: CMD17/CMD24, poll the present-state
ready bit, 128×32-bit words through the buffer port, poll transfer-
complete. Main loop is `diskd.c3`'s shape verbatim (`ipc_recv_type` ->
dispatch -> `ipc_send`), so `fsd` genuinely can't tell the two apart.

**Verified this session:** both `bash scripts/build.sh` (QEMU) and
`bash scripts/build_duo.sh` + `bash scripts/build_duo_fip.sh` (Duo, using
the existing `$DUO_SDK` checkout at
`~/Workspace/duo-buildroot-sdk-build/duo-buildroot-sdk`) build clean —
`sdd.c3` compiles under the same `--use-stdlib=no` user-mode constraints
`diskd.c3`/`fsd.c3` already do. Full QEMU regression
(hello/ping/p9test/nstest/writefile/readfile/rforktest/sandboxtest/
racetest) re-run and confirmed byte-for-byte unchanged from the "(5)"
entry's baseline — `sdd` never spawns there (`HAS_SD_BLOCK=false`), so
this is a real regression check, not just "it still compiles." (Along
the way, discovered the test harness itself — piping `\n`-terminated
commands into QEMU's stdin — was silently no-op'ing every command: the
shell's read loop only ever breaks on `\r`, not `\n`, so bare-`\n` input
just accumulates into one never-terminated line forever. Not a kernel
bug; fixed by feeding `\r`-terminated lines instead.)

**Not yet done — genuinely needs the user's hands (Stage 4):** real
hardware bring-up. Register offsets and the command sequence are a
careful, direct port of sourced values, but none of it has touched real
silicon yet; expect iteration, same as the original Sv39 bring-up.
Verification ladder, cheapest signal first: `sdd_init` completes and
prints without hanging -> `CMD0`/`CMD8` get a response at all ->
enumeration reaches `CMD7`/`SELECT_CARD` -> `writefile`/`readfile`
round-trip correctly through `fsd`, matching QEMU's existing behavior.

**Files changed:** `boards/duo/board.c3` (`SD_MMIO_BASE`, `IRQ_SDHCI`,
`SD_TOP_PAGE`/`SD_PINMUX_PAGE`/`SD_CLOCK_PAGE`, `HAS_BLOCK_DEVICE` ->
`true`, `HAS_SD_BLOCK`/`HAS_VIRTIO_BLOCK`), `boards/qemu/board.c3`
(mirror `HAS_SD_BLOCK`/`HAS_VIRTIO_BLOCK` + dummy SD constants, needed
since `process.c3` references them unconditionally regardless of board),
`src/process.c3` (`sdd_pid`, `setup_sdd_mappings`), `src/kernel.c3`
(spawn gate now picks `sdd` vs `diskd` by board flag), `user/sdd.c3`
(new), `scripts/build_user.sh`/`build.sh`/`build_duo.sh` (build + link
`sdd` alongside the other user binaries on both targets).

---

## 2026-08-16 (5) — Milk-V Duo: full interactive shell, real hardware

**Continuing straight from this same day's "(4)" entry.** Sv39 paging
worked for the first time (the Accessed/Dirty bit fix), but boot still
died with a clean, caught page fault inside `map_page()` right after
"Idle process started" — a second, different bug, `current_pid=0`
(idle).

**Root cause, found by re-deriving the faulting address by hand from
disassembly rather than trusting an earlier, unrelated diagnostic dump's
numbers:** `map_page()`'s own pointer-recovery arithmetic —
`(table2[vpn2] >> 10) * PAGE_SIZE` to get `table1`'s address, same
pattern for `table0` — never masked the result down to Sv39's real
44-bit PPN field. Once `board::PTE_EXTRA_BITS` (bits 60-62, added this
same day's "(3)"/"(4)" entries) started getting set on *every* level,
not just leaves, those extra bits survive the `>>10`/`<<12` round trip
(bit 62 shifts out past bit 63 and is lost, but 60/61 land at 62/63) and
corrupt every intermediate table pointer computed from a parent entry.
QEMU never has this problem (`PTE_EXTRA_BITS=0` there), so full
regression passing there the whole time never caught it. Added
`PPN_MASK = (1UL<<44)-1` and applied it everywhere a table pointer gets
recovered from a stored entry — `page.c3`'s own two sites, plus two more
in `entry.c3` that turned out to duplicate the identical unmasked
pattern: the process-exit page-table free loop, and the `SYS_RFORK`
copy-on-write table-copy loop (`grep`ped the whole tree afterward for
any other `>> 10` occurrences to confirm no fourth copy existed).

**Result: full interactive shell on real Milk-V Duo hardware**, first
time this whole project. `hello`, `ping`, `p9test`, `nstest`,
`rforktest`, `sandboxtest`, `racetest` all pass with output matching
QEMU exactly, module one cosmetic-only exception: `nstest`'s catch-all
resolve prints `pid /` instead of a number, because `server_pid=0`
(`fsd` doesn't exist on this board — `HAS_BLOCK_DEVICE` is false, no
storage driver) is a value QEMU's regression run has literally never
exercised (QEMU always has a real, nonzero `fsd` pid), so whatever
quirk existing print-formatting code has for pid 0 has just never been
seen before. `writefile`/`readfile` still correctly refuse (no block
device on this board at all — an intentional, already-documented scope
cut, not a bug).

**Kept from this session's debugging, on purpose:** `current_pid` in
`entry.c3`'s fatal-trap print (`src/entry.c3`) — genuinely useful,
essentially free, and it's exactly what pinpointed the second bug's
context. Everything else debug-only (the lettered `switch_context`
markers, the CPU-ID SBI query, the nested page-table-walk diagnostic
that itself triggered a cascading fault) stayed reverted from the "(4)"
entry.

**Files changed:** `src/page.c3` (`PPN_MASK`, applied at its own two
pointer-recovery sites), `src/entry.c3` (same mask, two more sites —
exit free loop, rfork COW copy).

---

## 2026-08-16 (4) — First real Sv39 activation on hardware: the Accessed/Dirty bit hang

**Context:** continuing straight from this same day's "(3)" entry —
`build/fip_duo.bin` existed and flashed, but the very first hardware
boot hung completely silently right after "Idle process started",
with no panic, no trap message, nothing. This entry is the full chase:
seven wrong turns and the one real fix, run entirely over a live serial
console with the user physically swapping the SD card between the
reader and the board for every single test.

**First real signal:** page.c3's `map_page()` was panicking
(`"unaligned vaddr"`) on the very first hardware boot — `create_process`
and the rfork COW-copy path both looped `map_page()` from
`__kernel_base` to `__free_ram_end`, and on Duo `__kernel_base` sits 32
bytes past the fiptool `LOADER_2ND` header (`RUNADDR + 32`), not
page-aligned the way QEMU's identical symbol is. Fixed by introducing a
separate `__kernel_map_base` symbol (page-aligned, equal to
`__kernel_base` on QEMU, equal to `RUNADDR` on Duo) — see
`src/kernel.ld`, `boards/duo/kernel.ld`, and the two call sites in
`process.c3`/`entry.c3`. This got the boot past that panic and to "Idle
process started" — then straight into a silent hang with **zero**
further output, not even from the kernel's own direct-SBI console
prints that had worked perfectly up to that exact point.

**Bisection tool: raw SBI-ecall debug markers inside `@naked` asm,
since this predates any working syscall path.** Instrumented
`switch_context` (`process.c3`) with lettered checkpoints (A–E) around
every instruction — stack save, `sfence.vma`, `csrw satp`, `sfence.vma`,
`csrw sscratch`, register restore, `ret` — each one a raw
`li a0,'X'; li a6,0; li a7,1; ecall` sequence (legacy SBI console
putchar), carefully avoiding clobbering registers still needed later in
the function. Also added one to the very top of `user_entry` (before
`sret`). Each round trip: edit → `bash scripts/build.sh` (QEMU
regression) → `bash scripts/build_duo.sh` →
`bash scripts/build_duo_fip.sh` → user flashes `build/fip_duo.bin`,
power-cycles, pastes back the serial log. This bisection was decisive:
**A and B printed every single time; C never did, in any test this
whole session.** C sits right after `csrw satp`. Later, stripping
`switch_context` down to `csrw satp` followed by a bare `nop` before C
still didn't print — the very *next* instruction fetch after enabling
Sv39, regardless of what it is, never completes.

**Seven hypotheses, six wrong:**
1. **PTE attribute bits on leaf entries only** (T-Head C906's MAEE —
   memory-attribute extended encoding, enabled via the M-mode-only
   `mxstatus` CSR that FSBL sets to `0xc0638000` before OpenSBI even
   runs — repurposes Sv39's normally-reserved PTE bits 63:59 as
   SO/C/B/SH/SEC memory-type fields; leaving them zero reads as
   Strong-Order/non-cacheable). Added `board::PTE_EXTRA_BITS`
   (SHARE|CACHE|BUF, bits 60-62, matching this exact SDK's own Linux
   fork's `pgtable-bits.h`/`PAGE_KERNEL`) to leaf PTEs. **No change.**
2. **Same bits on intermediate table-pointer entries too** (leaf-only
   made no observable difference, meaning if this were the mechanism
   the walk would have to be failing before ever reaching the leaf).
   **No change.**
3. **`fence.i`** after the `satp` write, on the theory that real
   hardware can have stale instruction-cache content across a
   translation-mode change that QEMU's emulation never models.
   **No change** — confirmed via disassembly that even a bare `nop`
   immediately after `csrw satp` never executes, regardless of what
   follows it.
4. **Clearing `mxstatus` entirely** from OpenSBI's own M-mode
   `generic_early_init` (`opensbi/platform/generic/platform.c`, patched
   directly in the external SDK checkout) — undoing whatever FSBL
   configured, rather than guessing the right bits to accommodate it.
   Confirmed via disassembly that `csrw mxstatus,a5` (a5=0) really was
   the first thing `generic_early_init` did. **No change.**
5. **The official prebuilt firmware.** The user recalled testing a
   *pre-built* Milk-V release successfully with real Linux in the past
   — not anything built from this SDK checkout. Downloaded
   `milkv-duo-sd-v1.1.4.img.zip` (a URL the user supplied), extracted
   `fip.bin` from its boot partition, and pulled `BL2`/`MONITOR` back
   out of it with fiptool.py's own `read_fip()` (confirming, along the
   way, that this checkout's Kconfig-fixed build already produces
   byte-identical `MONITOR_RUNADDR`/`BLCP_2ND_RUNADDR`/`RUNADDR` values
   to the official release). Repackaged racccoon's kernel as
   `LOADER_2ND` against the *official* BL2+MONITOR. **No change** —
   ruled out a build regression in this checkout as the cause entirely.
6. **Explicit D-cache flush of the page table** before pointing `satp`
   at it, via T-Head's custom `dcache.cipa` instruction (`.long
   0x02b5000b`, the same one `u-boot-2021.10/arch/riscv/cpu/generic/
   cache.c` uses) — on the theory that the MMU table walker reads
   physical memory via a path that doesn't snoop the D-cache, and that
   FSBL's own `flush_dcache_range()` call for the *loaded kernel image*
   (`bl2_opt.c`'s `load_loader_2nd`) doesn't cover page tables built at
   runtime. Verified the raw instruction encoding decoded correctly
   (`rs1=a0`) before ruling it out. **No change.**
7. **A full U-Boot-mediated boot**, instead of racccoon replacing
   U-Boot as `LOADER_2ND` — on the theory that U-Boot's own hardware
   bring-up (DRAM/MMC/Ethernet init, all visible in its own boot log)
   established some prerequisite state Linux implicitly relies on that
   FSBL's minimal init skips. This needed real infrastructure since
   this exact U-Boot build has almost no shell commands compiled in
   (`CONFIG_CMD_GO`, `_BOOTI`, `_ELF`, `_SOURCE`, `_LOADB` all
   `# ... is not set` — only `mmc`/`part`/`fat`/`fs generic`): `go`
   doesn't exist, `bootm` needs `CONFIG_LEGACY_IMAGE_FORMAT` (also
   unset, FIT-only) so a legacy `mkimage -T kernel` uImage was rejected
   outright, and `bootm` itself hard-requires an FDT subimage even
   though the kernel never reads it (blank placeholder DTS compiled
   with `dtc` and added to the FIT) — and the first working FIT attempt
   still needed a non-overlapping staging load address, since loading
   the container at the same address as its own embedded kernel payload
   trips U-Boot's "new format image overwritten" self-protection.
   Ended up with a real, reusable path: `build/racccoon.its`/
   `mkimage -f` → `.itb` → `fatload mmc 0:1 0x80500000 racccoon.itb` →
   `bootm 0x80500000`. Booted clean, full U-Boot init included.
   **Still the exact same hang.** This eliminated *every* environmental/
   firmware-state theory outright — the bug had to be in racccoon's own
   Sv39-enable code, independent of how or by what it gets loaded.

**The real fix: Accessed and Dirty bits.** Diffing the leaf PTE
construction against this exact SDK's own Linux fork's
`arch/riscv/include/asm/pgtable.h` one more time, bit by bit rather than
by shape, turned up `_PAGE_KERNEL`/`PAGE_KERNEL_EXEC` always including
`_PAGE_ACCESSED | _PAGE_DIRTY` (bits 6/7) — which racccoon's `map_page()`
had never set, on any board, ever. Per the RISC-V privileged spec, a
core without hardware auto-setting of the A/D bits (no Svade-equivalent)
is required to fault on any access through a PTE with A=0. This T-Head
C906 apparently doesn't just fault cleanly on that condition the way the
spec's normal page-fault path would suggest — it hard-locks the hart on
the very first instruction fetch through the newly-enabled mapping, no
trap, nothing recoverable. Added `PAGE_A`/`PAGE_D` (page.c3) to every
leaf PTE `map_page()` creates. Tested first against a throwaway 1GB
superpage identity map (bypassing the real ~15,000-entry process page
table entirely, to isolate content/complexity from the actual
mechanism) — **A, B, C, D, E, and the `user_entry` marker all printed,
`sret` into U-mode succeeded, and it cleanly page-faulted at the
deliberately-unmapped `USER_BASE` with a proper trap message.** Sv39
paging works on this hardware, for the first time this whole
investigation.

**Cleaned up for production**: stripped every debug marker/ecall out of
`switch_context`/`user_entry`/`yield`, removed the CPU-ID SBI query
(`sbi_get_mvendorid`/`marchid`/`mimpid` — turned up `mvendorid=0x1`,
`marchid=0x5b7` i.e. `THEAD_VENDOR_ID`, `mimpid=0`; interesting that
this exact SDK's own Linux fork checks `mvendorid` for its T-Head DMA
cache-workaround gate, which would never fire on this exact chip
variant), reverted the `mxstatus`-clear OpenSBI patch (confirmed
unnecessary), and moved `PAGE_A|PAGE_D` into the real `map_page()` leaf
construction. Re-verified: full QEMU regression suite
(hello/ping/p9test/nstest/writefile/readfile/rforktest/sandboxtest/
racetest, all correct) still passes unchanged, and the *original*
direct FSBL→racccoon boot path (no U-Boot detour, our own
`scripts/build_duo_fip.sh`, our own from-source-built OpenSBI/FSBL) —
the actual production target — was rebuilt clean.

**A second, real bug surfaced immediately after:** once Sv39 actually
works, boot now gets past "Idle process started" into a *clean, caught*
page fault (`scause=0xd`, Load Page Fault) inside `map_page()` itself,
`current_pid=0` (idle). A quick nested diagnostic (walking idle's own
page table for the fault address from inside the trap handler) itself
triggered a second fault and a confusing cascading-panic loop — reverted
that back out rather than chase a re-entrant-fault situation blind.
Working theory, not yet confirmed: `create_process()`'s kernel-range
identity-map loop has never been exercised while a page table is
*already active* — every prior board/timing combination happened to
finish creating the shell process while `kernel_main` (which *is* the
idle process's own execution) was still running bare-metal, before its
first `yield()`. Duo's smaller pre-existing process count (`echod` only,
no `diskd`/`fsd` — `HAS_BLOCK_DEVICE` is false) apparently changes when
`shell_running` first goes false relative to `kernel_main`'s own
yield/resume cycle, so this is plausibly the *first ever* time
`create_process()` has run under an already-active satp, on any board,
this entire project. Not yet root-caused.

**Files changed:** `src/kernel.ld`, `boards/duo/kernel.ld` (the
`__kernel_map_base` alignment fix), `src/page.c3` (`PAGE_A`/`PAGE_D`/
`PAGE_G` consts, the actual fix), `boards/duo/board.c3`/
`boards/qemu/board.c3` (`PTE_EXTRA_BITS`), `src/process.c3` (clean
`switch_context`/`user_entry`/`yield`, no debug residue), `src/kernel.c3`
(no debug residue), `src/entry.c3` (`current_pid` added to the fatal-trap
print, kept — genuinely useful, low-risk). Externally, in the
`duo-buildroot-sdk` checkout (not part of this repo): the Kconfig fix
from the "(3)" entry remains; the `mxstatus`-clear OpenSBI patch was
added and then reverted this session.

---

## 2026-08-16 (3) — A real, flashable `fip.bin` — plus two vendor-toolchain bugs that had to die first

**Goal, continuing straight from this same day's "(2)" entry:** actually
build the SDK components racccoon's own `fip.bin` needs (OpenSBI, FSBL)
and package `build/kernel_duo.elf` into a real image. Ended up spending
most of this session on two unrelated toolchain bugs blocking that,
neither of which had anything to do with racccoon's own code.

**Bug 1 — the vendor SDK's top-level Kconfig has drifted ahead of its
own bundled kconfig-frontend.** `u-boot-2021.10/Kconfig`'s `CC_IS_GCC`/
`CC_IS_CLANG` use `def_bool $(success, ...)` — confirmed two separate,
real problems, not host-toolchain skew (reproduced identically against
both the system's own gcc 16.2.1 *and* the vendor's own documented
`milkvtech/milkv-duo` Docker image, gcc 11.4.0/Ubuntu 22.04):
1. `success` wasn't in `scripts/kconfig/preprocess.c`'s function table
   at all (only `shell`, `error-if`, `info`, etc.) — added it (runs the
   command via `popen`, returns "y"/"n" from its exit status, mirroring
   `do_shell`'s plumbing).
2. Even patched in, `$(success, ...)` never actually got invoked when
   used as a `def_bool`'s value — confirmed by instrumenting
   `do_success()` with a debug `fprintf` that never fired. `default
   $(shell, ...)` (used a few lines down for `GCC_VERSION`) *does* get
   invoked. This is a real, narrower gap in this old kconfig-frontend:
   `default`'s value gets macro-expanded, `def_bool`'s doesn't. Not
   worth patching the flex/bison grammar for a vendor build script three
   layers removed from racccoon's own code — instead hardcoded
   `CC_IS_GCC`/`CC_IS_CLANG`/`GCC_VERSION`/`CLANG_VERSION` to the known-
   correct values for racccoon's toolchain (GCC only, cross-compiler is
   `host-tools`' `riscv64-unknown-linux-musl-gcc-10.2.0`).

**Bug 2 — the actual blocker, and much bigger: `host-tools`' entire
cross-toolchain was 0 bytes.** After the Kconfig fix, u-boot's build got
much further, then failed with `cc1: unknown register name: gp` (no
`CROSS_COMPILE`) in manual repros, and separately with silent, no-output,
exit-0 "successes" from `riscv64-unknown-linux-musl-gcc` in the real
recipe — no compiler error, no output file, nothing. `file` on the
binary said `empty`. Checked: **every single binary** in `host-tools/gcc/`
was 0 bytes (17508 of 31578 tracked files) — `git status` inside that
checkout showed tens of thousands of files as locally modified/deleted
relative to its own index. Root cause: that `host-tools` clone was made
in the *previous* (pre-reboot) session directly into `/tmp`, which is
RAM-backed `tmpfs` — this session found it still there post-reboot but
sitting in a tmpfs that was already 6.1GB/7.7GB full (see this same
day's "(2)" entry, which moved the whole checkout to real disk for that
reason). The checkout must have hit ENOSPC or gotten OOM-killed mid-
write, silently leaving thousands of truncated 0-byte files while git's
own object database (already fully received over the network before
checkout started) stayed intact. Fixed with `git checkout HEAD -- .`
inside `host-tools` (re-materializes the working tree from the already-
valid object database — no re-clone needed); confirmed via `file` that
`riscv64-unknown-linux-musl-gcc` is now a real 16MB ELF binary.

**Once both were fixed, the real vendor build (OpenSBI + FSBL + U-Boot,
via `milkvtech/milkv-duo` Docker, `source build/envsetup_milkv.sh
milkv-duo-sd && build_fsbl`) succeeded outright** and produced a real,
complete vendor `fip.bin` (317952 bytes, U-Boot as `LOADER_2ND`) — a
good validation image to flash first and confirm the physical setup
(SD card, UART adapter, board) works at all, independent of any
racccoon code. Its packaged header **independently confirmed two
numbers from this same day's earlier "(2)" entry**, straight from the
real build rather than static reading: `LOADER_2ND`'s `RUNADDR` really
is `0x80200000`, and `BLCP_2ND_RUNADDR` (the top-of-DRAM boundary
reserved for the second C906 core) really is `0x83f40000` — exactly
matching `boards/duo/kernel.ld`'s `__dram_end` computation.

**Packaged racccoon's own image.** `opensbi/build/platform/generic/
firmware/fw_dynamic.bin` (OpenSBI, dynamic mode) and `fsbl/build/
cv1800b_milkv_duo_sd/bl2.bin` (FSBL) from that same build are reusable
as-is — they're generic, not U-Boot-specific. Wrote
`scripts/make_loader2nd.py` (prepends fiptool's 32-byte `LOADER_2ND`
header — `JUMP0`/`MAGIC="BL33"`/`CKSUM`/`SIZE`/`RUNADDR=0x80200000`/
`RESERVED1`/`RESERVED2` — to a raw kernel binary; `CKSUM`/`SIZE` get
recomputed by `fiptool.py` itself, only `MAGIC`/`RUNADDR` need to be
right going in) and `scripts/build_duo_fip.sh` (extracts
`build/kernel_duo.elf`'s raw binary via `llvm-objcopy`, runs the header
script, then invokes `fiptool.py genfip` directly with racccoon's
kernel as `--LOADER_2ND`, the real `--MONITOR`/`--BL2` from the SDK
build, `--BLCP`/`--BLCP_2ND` pointed at FSBL's own `test/empty.bin`
skip-file since racccoon doesn't use the fast-image or second-core
slots, and `--BLCP_2ND_RUNADDR=0` so FSBL's own `if
(!blcp_2nd_runaddr) skip` cleanly no-ops the second core). Ran it end to
end: `build/fip_duo.bin`, 528384 bytes, `RUNADDR=0x80200000` confirmed
in the packaged header. Uncompressed (`--compress` omitted, i.e. plain
`None`) deliberately, for the first hardware attempt — one less moving
part (FSBL's LZMA/LZ4 decompress path) to debug blind without a way to
see real UART output myself if something goes wrong.

**End state:** `DUO_SDK=<path> bash scripts/build_duo_fip.sh` (after
`bash scripts/build_duo.sh`) reproducibly builds a real
`build/fip_duo.bin` from current `master`... er, `riscv64` HEAD.
Not yet tested on real silicon — that's the next step, and needs the
user (flashing an SD card, watching the UART). `boards/duo/kernel.ld`'s
`__loader2nd_runaddr` comment and the plan file should get one more
pass to point at this entry instead of "still needs confirming."

**Files changed this session:** `boards/duo/kernel.ld` (RUNADDR fix,
carried over from the "(2)" entry), `scripts/make_loader2nd.py` (new),
`scripts/build_duo_fip.sh` (new). The Kconfig/preprocess.c/host-tools
fixes all live in the external `duo-buildroot-sdk`/`host-tools`
checkouts, not in this repo.

---

## 2026-08-16 (2) — Real `RUNADDR`, and the actual fiptool/FSBL packaging chain

**Context:** picked back up after a PC reboot. The previous session's
plan (Stage 0.1) assumed the next step was booting the *stock* Milk-V
image first, to validate the physical setup before touching racccoon.
The user corrected that: the actual prior effort was going straight for
packaging **racccoon's own kernel** as the board's payload — a
`duo-buildroot-sdk` checkout already existed at
`/tmp/duo-fsbl-only/duo-buildroot-sdk` (plus a prebuilt toolchain at
`/tmp/duo-fsbl-only/host-tools`) from that attempt, survived the reboot
since `/tmp` wasn't wiped. No fip.bin had been produced yet and no
Docker container was running — nothing was lost, just not yet acted on.

**Resolved the previously-unconfirmed `RUNADDR`.** The prior session's
devlog entry assumed the real board-config header was "generated during
the SDK's own build, not committed." That was wrong — traced it to
`duo-buildroot-sdk/build/boards/cv180x/cv1800b_milkv_duo_sd/memmap.py`,
a real committed Python constants file the SDK's own build reads
(not RTL-generated), with `CONFIG_SYS_TEXT_BASE = DRAM_BASE + 2*SIZE_1M`
— this is where the vendor's own U-Boot runs as the `LOADER_2ND`/"BL33"
payload, i.e. exactly the slot racccoon's kernel replaces. `0x80200000`
(`DRAM_BASE + 2MiB`) is a real, sourced value, not a guess: OpenSBI's
own `MONITOR` slot is only 512KB (ends at `0x80080000`), leaving ~1.5MB
of headroom, and FSBL's own bounds check (`IN_RANGE(runaddr, DRAM_BASE,
DRAM_SIZE)` in `bl2_opt.c`) only requires landing inside the 64MB DRAM
window at all.

**Traced the full packaging chain through the real build scripts**
(`duo-buildroot-sdk/build/scripts/fip_v2.mk`,
`fsbl/make_helpers/fip.mk`, `fsbl/plat/cv180x/fiptool.py`), not just the
FSBL C source read last session:
- OpenSBI is built in **dynamic** firmware mode (`fw_dynamic.bin`),
  *not* `fw_payload.bin` — it does not statically embed the next stage.
  It's loaded into FIP as the `MONITOR` slot.
- `LOADER_2ND` (u-boot-raw.bin, in the vendor build) is a **separate**
  FIP slot, given to `fiptool.py genfip` via `--LOADER_2ND=<path>`.
  Confirmed by reading `add_loader_2nd()`: it requires the input file's
  bytes at offset 0 to already carry the `ldr_2nd_hdr` — `JUMP0`(4) +
  `MAGIC`(4, must literally be `b"BL33"` going in) + `CKSUM`(4) +
  `SIZE`(4) + `RUNADDR`(8) + `RESERVED1`(4) + `RESERVED2`(4) = 32
  bytes, matching `boards/duo/kernel.ld`'s existing 32-byte reservation
  exactly. `CKSUM`/`SIZE` are recomputed by `fiptool.py`'s
  `_update_ldr_2nd_hdr()` — only `MAGIC` and `RUNADDR` need to be
  correct going in. There is deliberately no `--LOADER_2ND_RUNADDR` CLI
  flag; the tool reads `RUNADDR` out of the header we provide, exactly
  as `load_loader_2nd()` in `bl2_opt.c` does at boot
  (`loader_2nd_entry = loader_2nd_header->runaddr + sizeof(header)`).
- No `--BLCP`/`--BLCP_2ND` needed (that's the second C906 core's
  firmware slot, out of scope per the plan).

**Fixed a real bug this surfaced, not just documentation:**
`boards/duo/kernel.ld`'s `__free_ram` reserved a flat `64MB` after the
stack — copied from `src/kernel.ld`'s QEMU version, where it's safe
because QEMU virt is handed far more RAM than it needs. CV1800B only
has 64MB of DDR *total* (`0x80000000`-`0x84000000`), and the kernel
already loads 2MB+ into that window before `__free_ram` even starts —
the flat-64MB copy would have overrun the real DRAM window by
whatever the load offset + image + stack consumed. Fixed to size
`__free_ram_end` against a real `__dram_end` (`DRAM_BASE + 64MB -
768KB`, the last term reserving the same top-of-DRAM region the
vendor's own firmware treats as the second core's, matching
`memmap.py`'s `FREERTOS_SIZE` — racccoon never touches that core, but
there's no reason to depend on RAM that isn't confirmed free).
Verified via `llvm-nm`/`llvm-readelf` post-rebuild:
`__kernel_base = 0x80200020` (= `RUNADDR + 32`, matching the header-skip
math), `__free_ram` spans `0x802fc000`-`0x83f40000`, safely inside the
real window.

**Updated `boards/duo/kernel.ld`**: `__loader2nd_runaddr` is now
`0x80200000` (previously an explicitly-flagged placeholder,
`0x80400000`), with the sourcing above in-line as a comment.
`bash scripts/build_duo.sh` builds clean after the change.

**Not done yet — the actual build:** haven't run `opensbi`/`fsbl-build`
against the real SDK checkout, haven't written the header-prepending
step for `kernel_duo.elf`'s raw binary, haven't run `fiptool.py genfip`
for real, no `fip.bin` exists. That's the next concrete step, pending
the user's go-ahead given it's a real (if scoped-down: just
opensbi+fsbl+u-boot, not the full Buildroot rootfs/Linux kernel) SDK
build.

**Files changed this session:** `boards/duo/kernel.ld`.

---

## 2026-08-16 — Milk-V Duo bring-up, part 1: a `board` abstraction layer

**Goal:** the user has the actual Milk-V Duo board, an SD card, and a
USB-UART adapter in hand now and wants to move past QEMU. Planned this
as its own effort (`~/.claude/plans/giggly-prancing-iverson.md`,
separate from the RV64/Sv39 port's own plan) — real hardware is a
fundamentally different kind of work: I can build/boot/iterate on QEMU
myself in a loop, but I have no way to flash an SD card or watch a
physical UART, so every hardware-touching step needs the user
physically present. This entry covers the software-only first stage,
done autonomously; flashing and first boot are next, and need the user.

**Research, before writing any code:** pulled the real CV1800B/CV1801B
datasheet and cross-referenced two independent bring-up reports rather
than guessing addresses. Confirmed: DDR at `0x80000000` (same base as
QEMU, good), UART0 at `0x04140000` (16550-compatible), PLIC at
`0x70000000` (confirmed from an actual upstream Linux devicetree patch
for `cv1800b.dtsi`, not inferred from a sibling chip), boot chain is
BootROM → FSBL → OpenSBI (S-mode handoff, same shape as QEMU). One
finding corrected an earlier assumption from a secondary source: a
third-party Zephyr bring-up report used fiptool's `BLCP_2ND` payload
slot, but reading the actual FSBL C source
(`fsbl/plat/cv180x/bl2/bl2_opt.c` in `duo-buildroot-sdk`) showed
`load_blcp_2nd()` calls `reset_c906l()` directly — that slot is
explicitly the *second* C906 core's firmware, not what racccoon wants.
The correct slot is `LOADER_2ND` (ATF's standard "BL33" stage — what
OpenSBI jumps to on the *main* core after its own init), which needs a
small synthesizable 32-byte header prepended to the raw kernel binary,
and whose real jump entry is `RUNADDR + 32` (past the header), not
`RUNADDR` itself — traced directly through `load_loader_2nd()`'s
`loader_2nd_entry = loader_2nd_header->runaddr + sizeof(header)`. The
exact safe `RUNADDR` value is still unconfirmed — the real board-config
header (`cvi_board_memmap.h`) is generated during the SDK's own build,
not committed to the repo, so this needs the user's actual build output
to nail down, not more static reading.

**Asked for the design before building it.** Drafted a plan that just
edited `plic.c3`'s constants in place for the Duo — the user rejected
it: "auto mode, but make it with the right abstraction so porting to
other platforms will be easier." Redesigned Stage 1 around a `board`
module contract (data *and* behavior — `plic_init`/`plic_claim`/
`plic_complete`/`console_putchar`/`console_getchar`, not just address
constants, since it's genuinely unconfirmed whether `thead,c900-plic`'s
register layout matches QEMU virt's SiFive-style PLIC closely enough
for a base-address swap alone to be correct) with one implementation
per platform, so a third board later means one new file, not another
pass through `plic.c3`/`process.c3`/`kernel.c3`.

**Implementation:** `boards/qemu/board.c3` and `boards/duo/board.c3` —
new top-level `boards/` directory (not under `src/`) specifically to
use `c3c`'s per-target additive `sources` property cleanly
(`c3c --list-project-properties` confirmed this exists:
`sources`/`sources-override` are real per-target overrides, not just a
global list) rather than needing glob-exclusion syntax. `project.json`
now defines two targets, `racccoon` (existing, QEMU) and `racccoon-duo`
(new), each pulling in only its own board directory on top of the
shared `src/**`. `src/plic.c3` is gone — its logic split into both
`board.c3` files; call sites in `entry.c3`/`process.c3`/`kernel.c3` now
go through `board::` instead of bare `plic_*`/`sbi::__*` calls.
`kernel.c3`'s diskd/fsd spawn is gated on `board::HAS_BLOCK_DEVICE`
(false on Duo — no virtio-mmio equivalent, no storage driver yet;
`fsd_pid` staying 0 already made every later namespace's `"" -> fsd`
mount resolve to nothing, so this fails cleanly, not silently).
`boards/duo/kernel.ld` reserves the 32-byte `LOADER_2ND` header space
ahead of `.text.boot`, with `RUNADDR` written as an explicit,
impossible-to-miss placeholder (`0x80400000`, clearly commented
UNCONFIRMED) pending Stage 0.1's real build output.

**Verification, not just "it compiles":** the QEMU board file is a
straight refactor of already-working code, so rebuilding the `racccoon`
target and rerunning the full manual regression (`hello`, `ping`,
`p9test`, `nstest`, `writefile`/`readfile`, `rforktest`, `sandboxtest`,
`racetest`) doubled as the regression check for the abstraction itself
— identical output to before the refactor, confirming the refactor
didn't silently change QEMU behavior while adding the new platform.
`bash scripts/build_duo.sh` (new) also builds `racccoon-duo` clean;
`llvm-readelf`/`llvm-nm` on the result confirm `__kernel_base`/`boot()`
land exactly at `0x80400020` (`RUNADDR + 32`, matching the header-offset
math above) — can't boot-test this one myself, but the address math
checks out.

**End state:** both targets build clean; QEMU path fully regression-
tested and unchanged. Duo path is real code, not a stub, but genuinely
untested past "the linker is happy" — first real test is Stage 2, once
Stage 0.1 (confirm the physical setup with a stock vendor image) and
0.2 (the real `fiptool`/`RUNADDR` values from an actual SDK build) are
done, which need the user's hands.

**Next up:** Stage 0.1 (user, hardware) — boot the stock `milkv-duo`
image, confirm serial works. Stage 0.2 (mine, once 0.1's SDK checkout
exists) — resolve the real `LOADER_2ND` `RUNADDR` and the exact
`fiptool.py` packaging command. Then Stage 2: first real boot.

**Files changed this session:** `project.json`, `boards/qemu/board.c3`
(new), `boards/duo/board.c3` (new), `boards/duo/kernel.ld` (new),
`scripts/build.sh`, `scripts/build_duo.sh` (new), `src/plic.c3`
(removed), `src/entry.c3`, `src/process.c3`, `src/kernel.c3`.

## 2026-08-15 (12) — RV64/Sv39 port: paging, trap frame, and a real 2GB
code-model wall

**Goal:** the user confirmed via community research that the target
hardware (Milk-V Duo, CV1800B) is RV64-only — no RV32 hardware mode.
Racccoon was RV32/Sv32 throughout. Planned and executed the full port
to RV64/Sv39, scoped to booting and passing the complete existing
regression suite under `qemu-system-riscv64 -machine virt` (real
hardware bring-up is a separate, later effort — different boot chain,
needs the physical board). Done autonomously on the `riscv64` branch
while the user was away; see `~/.claude/plans/giggly-prancing-iverson.md`
for the staged plan this followed.

**Sv32 → Sv39 is a structural change, not a width bump.** Sv32 is
2-level (10/10/12-bit split, 4-byte PTEs); Sv39 is 3-level (9/9/9/12,
8-byte PTEs). The PTE flag bits (V/R/W/X/U, bits 0-4) are identical
between the two — only the PPN field width and per-table entry count
differ — which meant `page.c3`'s `map_page()` could gain a third level
without changing its actual encoding formula. `satp`'s MODE field is a
real encoding change though: Sv32 used a single bit at position 31;
Sv39 needs `8ul << 60` in a 64-bit register.

**Every hand-written asm block needed the same mechanical rewrite:**
`sw`/`lw` → `sd`/`ld`, every `4 * N` stack offset → `8 * N`. Hit in
`switch_context`/`fork_entry`/`user_entry` (`process.c3`), the main trap
vector `kernel_entry` and `Trap_frame`'s 31 fields (`entry.c3`),
`threadcreate` (`user/user.c3`), and `rforkmemtest`'s inline ecall block
(`user/shell.c3`). A second, easy-to-miss RV64-specific bug living in
the same code: `SCAUSE_INTERRUPT_BIT` was `0x80000000` (bit 31, correct
for RV32) — on RV64 the interrupt/exception bit is bit 63 of a 64-bit
register. Wrong would have meant every interrupt silently misclassified
as an exception (or vice versa) — fixed to `1ul << 63` before ever
booting, not found by trial and error.

**c3c's own type checker did most of the "which `uint`s are secretly
addresses" audit for free.** Building against `--target elf-riscv64`
turns every `(uint)pointer` or `(pointer)uint` cast that used to be
silently lossless on RV32 into a hard compile error ("uint is smaller
than a pointer, use (uint)(iptr) if you want this lossy cast"). Worked
through `allocation.c3`, `page.c3`, `process.c3`, `plic.c3`, `kernel.c3`,
`entry.c3`, and every `user/*.c3` file this way — fix what the compiler
flags, rebuild, repeat — rather than trying to manually grep for every
address-shaped `uint` ahead of time.

**A second, less obvious category of RV64 break: block-form inline asm
register binding requires native register width.** `sbi_call`'s params
were `int`; on RV64 that's rejected outright ("'int' is not supported in
this position, convert it to a valid type, like 'long'") because a
32-bit local can't bind into a 64-bit register position in c3c's
`asm { mv $a0, arg0; }` block form. Same restriction hit `user.c3`'s
`syscall`/`syscall4` (widened to `long` throughout — which conveniently
also fixed every pointer-argument truncation in the same pass, since a
`long` argument is exactly pointer-width) and `diskd.c3`'s MMIO helpers
(widened to `uptr`/`ulong`). `diskd_info`'s out-pointers also had a real
latent corruption bug once this pattern is understood: the kernel writes
a full 8-byte `uptr` into them now, but `user.c3`/`diskd.c3` were still
declaring the receiving locals as 4-byte `uint` — an 8-byte kernel-side
store into a 4-byte user-side stack slot. Fixed by widening the
out-pointers to `uptr*` on both sides.

**`lwu` doesn't exist in c3c's block-form asm instruction set** ("Unknown
instruction for the current target") — `diskd.c3`'s `mmio_read64` needed
a zero-extending 32-bit load (combining two register halves into one
unsigned 64-bit value), but `lw` sign-extends on RV64. Worked around by
keeping `lw` and masking each half with `& 0xffffffff` before combining
— `mmio_read32` didn't need this at all, since its `(uint)` truncation
back down to 32 bits discards the sign-extended upper bits regardless of
how they got there.

**No riscv64 soft-float builtins anywhere on this machine, and no root
to install a cross toolchain that ships them.** `bash scripts/build.sh`
first failed at link time with ~20 undefined symbols (`__adddf3`,
`__floatsidf`, `__gtdf2`, ...) — LLVM lowers every float/double operation
to a compiler-rt runtime call on `rvimac` (no F/D extension), and
`std::io`'s generic printf formatter has a float-formatting path compiled
in unconditionally, reachable in principle from `vprintf`'s runtime
format-specifier dispatch even though this kernel's own `io::printfn`
calls (all `%s`/`%d`/`%x`) never actually take it. `--gc-sections`
couldn't drop it either — the reachability is real (a runtime dispatch,
not dead code), just never *taken*. Wrote
`src/kernel/softfloat_stubs.c3`: ~20 tiny functions, each exporting one
missing symbol name and panicking with that name if ever actually
called. If a future change starts passing a float to `io::printfn`, this
turns a silent miscompute into a loud, immediate, self-identifying
panic instead.

**The big one: c3c has no `--mcmodel` flag, and RV64's default code
model can't address this kernel's own load address.** Once the
undefined-symbol errors were gone, linking failed differently —
`R_RISCV_HI20 out of range: 524811 is not in [-524288, 524287]` — from
`compiler_rt.o`'s internal constant pools at first, then (once
`--gc-sections` was tried) from this kernel's *own* code too, including
trivial functions just referencing a string literal. Root cause, worked
out from first principles since c3c has no flag to ask about this
directly: RISC-V's default "medlow" code model materializes every
absolute address via a 2-instruction `lui`+`addi` sequence that only
works for addresses fitting a **signed 32-bit range** — i.e. below 2GiB.
This kernel boots at `0x80200000` (OpenSBI's fixed RV64 payload address,
confirmed via QEMU's own boot log: `Domain0 Next Address: 0x80200000`)
— just past that line. Under RV32 the exact same address was fine,
because RV32 has no signedness ambiguity to begin with (the whole
address space *is* 32 bits). Every real RV64 kernel (Linux, OpenSBI
itself) sidesteps this with `-mcmodel=medany` (PC-relative `auipc`-based
addressing, valid across the full 64-bit space) — but c3c doesn't expose
that flag, and `--reloc=pic` (the one adjacent flag it does have) turned
out to change TLS codegen to a model needing a runtime `__tls_get_addr`
call this freestanding kernel has no dynamic linker to provide.

The actual fix uses `--emit-llvm` as an escape hatch: let c3c emit its
own LLVM IR (still architecture-generic, no code-model baked in — verified
by grepping for `Code Model` module flags, which weren't there), then
recompile every `.ll` file directly with `llc -code-model=medium
-relocation-model=static` (LLVM's name for RV64 "medany") before handing
the resulting `.o` files to `ld.lld` for the real link. Confirmed via
`llvm-readobj -r` that this actually changes the emitted relocation type
from `R_RISCV_HI20` (absolute) to `R_RISCV_PCREL_HI20` (auipc-based).
`scripts/build.sh` now runs this two-stage pipeline instead of a single
`c3c build`.

**One genuinely new bug this surfaced, not a porting mechanical fix:**
even after the code-model fix, `kernel.c3`'s `(uint)&_binary_X_bin_size`
idiom (the classic objcopy trick — the symbol's "address" *is* the
byte count, never actually dereferenced) still overflowed the same
`R_RISCV_PCREL_HI20` range check, because it's fundamentally
incompatible with *any* PC-relative addressing scheme: the "address" is
a small integer with no real relationship to the code referencing it,
so the computed PC-relative delta is nonsense (real kernel PC minus a
tiny fake value ≈ the full 2GB delta, landing right at the edge of what
a signed 32-bit delta can hold). Fixed properly rather than worked
around: objcopy also emits a real `_binary_X_bin_end` symbol (an actual
address, right after `_binary_X_bin_start`'s real data) — switched to
computing the size as `(uptr)&_binary_X_bin_end - (uptr)&_binary_X_bin_start`,
two genuine nearby addresses, no fake symbol involved.

**A real, pre-existing bug this port happened to expose:**
`user/diskd.c3`'s `diskd_panic` ended in a bare `for (;;) {}` — an empty
infinite loop with no side effects, which is UB under C/LLVM's rules and
a real optimizer target, not just theoretical. Under `-O2` this
apparently got eliminated on RV64, falling straight through back into
`diskd_init()`'s caller with diskd half-initialized instead of actually
halting — the visible symptom was "diskd: invalid device id" printed
dozens of times (from a supposedly-single-shot panic) followed by an
illegal-instruction crash. This bug likely existed on RV32 too but was
never exercised there, since RV32 QEMU's virtio-blk device apparently
never failed diskd's init checks. Fixed by replacing the loop with
`exit()` — genuinely fatal, and immune to the same class of elimination
since it's a real syscall.

**Full manual regression, all green, first try after the fixes above:**
`hello`, `ping`, `p9test`, `nstest`, `writefile`/`readfile` (through
fsd/diskd/virtio-blk), `rforktest`, `rforkmemtest`, `sandboxtest`,
`threadtest`/`threadjointest` (with real generation-counter joins),
`racetest` (concurrent IPC rendezvous) — every one produced identical
output to the RV32 baseline. `scripts/stress_test.sh` (adapted to
`qemu-system-riscv64`, 15 runs/scenario) confirmed the interrupt-driven
disk I/O path — the most timing-sensitive part of this kernel, and the
one most likely to hide a subtle Sv39/PLIC regression — is still solid.

**End state:** `bash scripts/build.sh` builds clean end-to-end (two-stage
`c3c`+`llc` pipeline). `build/kernel.elf` boots under
`qemu-system-riscv64 -machine virt -bios default` (`scripts/launch64.sh`)
through the complete existing feature set with no regressions. RV32
support is not preserved — `project.json`/`build.sh`/`build_user.sh` now
target `elf-riscv64` exclusively, matching the target hardware.

**Explicitly out of scope, not started:** real Milk-V Duo hardware
bring-up — different boot chain (FSBL, not a direct `-kernel` load),
needs the physical board, and the CV1800B's PLIC reportedly has only 8
priority levels at addresses that need confirming against real chip
documentation rather than assumed from QEMU's virt board.

**Files changed this session:** `project.json`, `scripts/build.sh`,
`scripts/build_user.sh`, `scripts/launch64.sh` (new),
`scripts/stress_test.sh`, `src/kernel.c3`, `src/kernel/sbi.c3`,
`src/kernel/softfloat_stubs.c3` (new), `src/allocation.c3`, `src/page.c3`,
`src/process.c3`, `src/plic.c3`, `src/entry.c3`, `user/user.c3`,
`user/diskd.c3`, `user/shell.c3`.

## 2026-08-15 (11) — IPC hardened into a true rendezvous, and proof the
old race was real

**Goal:** IPC's single-slot inbox always carried a documented but
*unenforced* assumption — "sender never blocks, safe only if callers
keep to one outstanding request at a time." That was true by accident
for most of this project's history (nothing sent concurrently). It
stopped being accidental the moment `rfork`/`threadcreate` made genuine
concurrent senders possible — two threads sharing memory can now
legitimately both want to message the same server at once. Hardened
`SYS_IPC_SEND`/`RECV`/`POLL` (`src/entry.c3`) into a real two-sided
rendezvous, the standard fix for exactly this class of problem.

**Highest blast radius of anything changed this session** — every
existing feature goes through this code path (echod, diskd, fsd, ping,
p9test, sandboxing) — so this got the most scrutiny of any change so
far, including something the earlier entries didn't do: proving the bug
being fixed was real, not just plausible.

**The mechanism, no new low-level plumbing needed:** `Process` gained
one field, `msg_acked` (`src/process.c3`). `SYS_IPC_SEND` now does two
things the old version didn't — waits (busy-poll, like `SYS_GETCHAR`)
for the target's inbox to actually be empty before depositing anything,
so a second sender can never silently overwrite a message the receiver
hasn't consumed yet; and, after depositing, blocks (`PROC_BLOCKED`,
genuinely woken this time) until the receiver has actually consumed
*this* specific message. `SYS_IPC_RECV`/`POLL` both now explicitly wake
the specific sender (via `msg_from`) on consume, mirroring exactly how
`SYS_IPC_SEND` already woke a blocked receiver — the missing symmetric
half. Deliberately *not* a queue: still one slot, just genuinely safe to
treat as one now that the protocol guarantees at most one message is
ever in flight to a given target.

**Proved the fix actually fixes something, not just "seems safer."**
Built `racetest` (`user/shell.c3`): two `threadcreate`'d threads — true
shared-memory concurrency, not just interleaved processes — both message
echod at once with distinct, checkable payloads (`"AAAA"` / `"BBBB"`),
each verifying its *own* reply matches what it sent. Before trusting the
fix, temporarily reverted just the two new wait loops in `SYS_IPC_SEND`
and reran `racetest` 20 times: **20/20 failures** — every single run
hung indefinitely (a thread's message got silently overwritten by the
other's before echod ever saw it, so it waited forever for a reply that
would never arrive — not a wrong value, a permanent hang, exactly matching
what the design analysis predicted). Restored the fix, reran the exact
same test: 20/20 clean. This is the first entry in this project's history
to run a change's own regression test *against the deliberately-broken
prior version* to confirm the test has real discriminating power, rather
than trusting that a passing test means what it's supposed to mean.

**A documented, accepted new tradeoff:** true synchronous rendezvous
trades "silent data race" for "deadlock if two processes ever try to
send to each other simultaneously without either being ready to
receive." Every existing client/server pair in this codebase follows a
strict request-then-reply discipline (nobody sends to something that
will never `recv`, nothing does bidirectional simultaneous sending) so
this doesn't bite today — worth naming as a real, not hypothetical,
constraint on future protocol design rather than pretending the tradeoff
doesn't exist.

**Verified:** 20/20 `racetest` runs with the fix (after confirming
20/20 *failures* without it), full regression across every feature built
this session and prior phases in one boot, and `scripts/stress_test.sh
15` on both existing scenarios (which exercise diskd/fsd's own IPC under
the new rendezvous too) — all clean.

**Files changed:** `src/process.c3`, `src/entry.c3`, `user/shell.c3`.

---

## 2026-08-15 (10) — Generation counters: closing `join`'s pid-reuse race

**Goal:** close the race the previous entry's `join` deliberately
documented rather than fixed — pids are slot-indexed
(`pid = slot index + 1`) and get reused the moment a slot frees up, so a
`join(pid)` outstanding when that exact pid gets recycled to an
unrelated process would wait for the wrong thing. Not a crash risk (the
original target is genuinely, fully gone the moment it exits — `join`
could never falsely report success), just a real liveness gap: waiting
for the wrong process to disappear instead of the right one.

**The standard fix for recycled small integer IDs:** a generation
counter per slot, bumped every time the slot is reused, that never
resets. `Process.generation` (`src/process.c3`), incremented alongside
`pid` in both `create_process` and `SYS_RFORK`'s child-creation path.
`rfork()` and `threadcreate()` both gained an optional `generation_out`
out-pointer (same "null means don't care" convention as
`SYS_IPC_RECV`'s `type_out`) so a caller that intends to `join()` later
can capture it; `join(pid, generation)` now breaks its poll loop on
*either* condition — slot empty, or the slot's current generation no
longer matches what the caller captured, meaning it's since been reused
by something else entirely. Two states now correctly read as "my target
is gone": actually empty, or reused (in which case the wrong occupant
being alive doesn't matter — the check never looks at *who's* there now,
just whether it's still the same instance).

**The ripple, and the one place it required real care:**
`threadcreate` (`user/user.c3`) is hand-written `@naked` asm — adding a
4th parameter meant it now arrives in `a3`, the exact register the
function was about to overwrite with the `SYS_RFORK` syscall number a
few instructions later. Threaded through `s4` alongside the existing
`s1`-`s3` (`func`/`arg`/`stack_top`), saved and restored around the
`ecall` in the parent path same as the others. Disassembled the rebuilt
`shell.elf` before trusting it — `s4`'s save/restore and the `mv a1, s4`
right before the `ecall` matched the design exactly, same discipline as
the original `threadcreate` build.

One easy-to-miss spot: `rforkmemtest`'s existing inline-asm `ecall`
(hand-written to avoid the shared-stack hazard two entries back) didn't
set `a1` at all before this change — meaning it would have carried
whatever garbage was already sitting in that register into the kernel's
new `SYS_RFORK` handler, which now unconditionally reads `f.a1` as a
pointer to maybe-write through. Caught by inspection while updating call
sites, not by a crash — fixed by explicitly loading `0` (null) into it,
same as every other call site that doesn't intend to join.

**Verified:** 25/25 stress runs of `threadjointest` (3 joins per boot,
75 total, exercising the new generation check on every single one), full
regression across every feature built this session, and
`scripts/stress_test.sh 15` on both existing scenarios — all clean.

**Files changed:** `src/process.c3`, `src/entry.c3`, `user/user.c3`,
`user/shell.c3`.

---

## 2026-08-15 (9) — `join`

**Goal:** replace the awkward "call `ping` a few times and hope the
background process has run by now" pattern this session's own testing
kept reaching for with an actual, correct wait — `join(pid)`, completing
the standard `fork`/`thread`/**`join`** vocabulary on top of `rfork` and
`threadcreate`.

**Much lower-risk than the last two entries, deliberately.** No new
kernel state, no new asm, no new resume mechanism — `SYS_JOIN`
(`src/entry.c3`) is a plain polling loop: check `proc_by_pid(pid) ==
null`, `yield()`, recheck. Exactly the shape `SYS_GETCHAR`'s own retry
loop already has, reusing `proc_by_pid` exactly as it already stands.

**One real bug caught before it shipped, this time by re-reading the
code rather than by stress testing** — a nice change of pace. The first
draft set `current_proc.state = PROC_BLOCKED` before yielding, mirroring
`SYS_IPC_RECV`'s pattern. But `PROC_BLOCKED` only ever gets cleared by
something *else* explicitly flipping it back — `SYS_IPC_SEND` does that
for a receiver. Nothing does that for a joiner: `SYS_EXIT` only ever
touches its *own* process's state, never anyone waiting on it. Setting
`PROC_BLOCKED` here would have made the joiner permanently
unschedulable the instant it was set, even after the joined process
actually exited — `yield()`'s scan only ever matches
`PROC_RUNNABLE`. Fixed by staying `PROC_RUNNABLE` throughout and just
re-yielding, matching `SYS_GETCHAR`'s proven "busy-poll via cooperative
yielding" shape instead of the IPC inbox's "block until explicitly
woken" shape — the right template depends on whether anything is going
to do the waking, and here nothing was.

**A documented, accepted simplification, not a fix:** pids are slot-
indexed and do get reused once a process exits and something new is
created in that slot. If a joined pid gets recycled to an unrelated
process before `join` notices, it can't tell the difference — the same
wart Unix had before zombie/reap semantics. Not a real risk for how this
codebase actually uses `join` today (always joining something the same
caller just created, nothing else racing to create processes
independently), but worth a comment rather than silently assuming it
away.

**`threadjointest`** (`user/shell.c3`): `threadcreate` a thread, `join`
it, read `thread_result` immediately after — no more separate
`threadtest`/`threadresult`-with-a-`ping`-in-between dance. The read
right after `join()` returns is guaranteed current, not a guess.

**Verified:** 20/20 stress runs, 3 `threadjointest` calls per boot (60
total joins), full regression across every feature built this session,
and `scripts/stress_test.sh 15` on both existing scenarios — all clean.
The self-join rejection (`join_pid == current_proc.pid`) is a one-line
guard verified by reading, not by a dedicated runtime test — there's no
`getpid()` in this codebase to let a shell command name its own pid to
try it against, and adding one solely to exercise a guard clause this
simple wasn't worth it.

**Files changed:** `src/entry.c3`, `user/user.c3`, `user/shell.c3`.

---

## 2026-08-15 (8) — `threadcreate`, and a real crash `rforkmemtest` was
hiding

**Goal:** make `RFMEM` (previous `rfork` entry) actually safe to use,
not just demonstrable — `threadcreate(fn, arg, stack_top)`, a userland
trampoline built on top of `rfork(RFPROC|RFMEM)`, matching how real
Plan 9 code gets thread-like behavior (`libthread`'s own `threadcreate`,
built the same way, for the same reason). Full design and the "why not
just have the kernel swap the child's stack" analysis in the plan file.

**Why a kernel-side fix doesn't work:** `rfork()`/`syscall()`
(`user/user.c3`) are ordinary non-leaf functions — at typical
optimization levels, their own prologues spill their own return
addresses onto the stack before making the next call, and their
epilogues reload those relative to `sp` *as it was at their own entry*.
Silently handing the child a different `sp` in its trap frame breaks
that outright: the child would be "returning through" frames whose
saved state lives on a stack it no longer has. Real thread primitives
(Linux `clone`, pthreads) sidestep this by never letting the child
return through the creating call's frame at all — it starts fresh, at a
new function, on a new stack. `threadcreate` does the same, by hand:

```c3
// user/user.c3 — @naked, string-form asm, no block-form binding
addi sp, sp, -16
sw s1, 0(sp); sw s2, 4(sp); sw s3, 8(sp); sw ra, 12(sp)
mv s1, a0; mv s2, a1; mv s3, a2       # fn, arg, stack_top
li a0, 3; li a3, 11                   # RFPROC|RFMEM, SYS_RFORK
ecall
bnez a0, 1f
mv sp, s3; mv a0, s2; jalr s1; j .    # child: switch stack, call fn(arg)
1: lw s1,0(sp); lw s2,4(sp); lw s3,8(sp); lw ra,12(sp); addi sp,sp,16; ret
```

The property that actually closes the hazard (not just narrows it, like
last entry's `rforkmemtest` fix did): from the `ecall` through the
branch and the stack switch, nothing touches memory at all — `a0` (the
branch test) and `s1`-`s3` (`fn`/`arg`/`stack_top`) are registers, and
the kernel's own trap-frame save/restore (`fork_entry`, unchanged since
the last entry) already guarantees those survive. By the time the child
would otherwise need to read anything through `sp`, `sp` already points
at its own private buffer, for the rest of its life, not just the resume
instant. This is also the first hand-written asm in this codebase with a
conditional branch and local labels — every prior naked function
(`switch_context`, `user_entry`, `fork_entry`, `kernel_entry`) is
straight-line. Disassembled `shell.elf` before trusting it at runtime;
every instruction matched the intended design exactly, labels included.

**A real crash, found while stress-testing something else.** While
retesting the previous entry's `rforkmemtest` under slightly different
timing (`rforktest` → `ping` → `rforkmemtest` → `ping`, instead of the
original sequence), the kernel paged-faulted:
`unexpected trap scause=c, stval=2, sepc=2` — an instruction fetch at
address `0x2`, a jump into garbage. Root cause: the *previous* fix for
`rforkmemtest` only protected the child's initial resume instant (by
inlining the `ecall` and branch into `main()`'s own frame). It did
nothing for what the child does *afterward* — and that version's child
still called `print()`, `putchar()`, and `exit()`, every one of them a
real function call spilling its own return address onto the *same,
still-shared* stack the parent kept using. Earlier testing happened to
never disturb that memory in time; this run's extra `ping` (which
genuinely blocks on IPC, forcing more scheduling activity) did. This
wasn't a new bug so much as the previous fix being necessary but not
sufficient — RFMEM's hazard covers the child's *entire* lifetime on the
shared stack, not just the moment it wakes up. Fixed by extending the
exact same "touch nothing but registers" discipline to the whole child
path: it now does a single global assignment (no call, no stack) and
exits via a second raw inline `ecall`, never calling `rfork()`,
`syscall()`, `print()`, `putchar()`, or `exit()` at all. A new
`rforkmemresult` command (mirroring `threadresult`) checks the result
from a safe, later point instead of the child printing anything itself.

**A minor, related lesson about testing this kind of thing with piped
input:** an early attempt to verify `threadresult` right after several
`hello` commands was flaky (~65% pass) for a boring reason — piped input
arrives fast enough that `getchar()`'s retry loop rarely actually blocks,
so `yield()` rarely runs during ordinary command processing, and the
background thread doesn't get a turn. Checking after `exit()` instead
was *worse* (0%): `exit()` respawns the shell as a completely fresh
process with its own independent memory, so it was reading a different
process's un-shared `thread_result`. What actually works reliably:
checking after a command that *genuinely* blocks on IPC (`ping`, which
waits for echod's reply) — a real, guaranteed yield, from the same
process that holds the shared memory. None of this reflects on
`threadcreate`'s or `rfork`'s own correctness — every one of these
attempts showed the mechanism itself working every single time; only the
*test's* ability to observe it reliably was in question.

**Verified:** `threadtest`/`threadresult` — 20/20 clean (using the
`ping`-based check). The exact `rforkmemtest` sequence that crashed —
25/25 clean after the fix. Full regression across every feature built
this session, `scripts/stress_test.sh 15` on both existing scenarios —
all clean.

**Files changed:** `user/user.c3`, `user/shell.c3`.

---

## 2026-08-15 (7) — Namespace unmount + a real sandboxed-child demo

**Goal:** give the namespace mechanism (phase 3) and `rfork` (previous
entry) an actual payoff together — a process that can restrict its own
view of the world after forking, proving the whole point of building
per-process namespaces as real per-`Process` state instead of a shared
global three sessions ago.

**What was added:** `SYS_NS_UNMOUNT` (`src/entry.c3`) — removes one of
the *caller's own* namespace mounts by exact prefix match (`str_eq`,
brought back from the deleted `src/fs.c3` alongside `str_starts_with`,
which already made that trip when this file was removed). Deliberately
a different match rule from `SYS_NS_RESOLVE`'s longest-prefix logic:
unmounting targets one specific entry by its own key, not "whichever
mount a path would currently resolve to." `user/user.c3` gets a trivial
`ns_unmount(prefix)` wrapper. `user/shell.c3`'s new `sandboxtest`:
`rfork(RFPROC)` a child (plain copy — deliberately *not* `RFMEM`, so
none of the previous entry's shared-stack hazard applies here at all),
the child immediately calls `ns_unmount("")` to drop its own fsd mount,
then demonstrates both sides: `fs_read("hello.txt")` now fails
(`ns_resolve` finds nothing, since the `""` catch-all is gone from *this
process's own copy* of the namespace), while `ipc_send`/`ipc_recv` to
echod still works fine — the raw IPC primitive was never namespace-gated
to begin with, so this also incidentally demonstrates that a "sandbox"
built purely on namespace restriction only restricts what the namespace
actually gates.

Because the child's namespace is a fresh **copy**, not a reference, made
at fork time (`SYS_RFORK`'s existing per-`Mount` copy loop, unchanged),
unmounting in the child has zero effect on the parent or any sibling —
verified explicitly (`readfile` still works in the parent after
`sandboxtest` runs).

**Verified:** 15/15 stress runs (`sandboxtest`, checking for both the
denial and the still-working ping, no crashes), full regression across
every feature built so far in one boot, and `scripts/stress_test.sh 15`
on both existing scenarios — all clean.

**Files changed:** `src/entry.c3`, `src/process.c3`, `user/user.c3`,
`user/shell.c3`.

---

## 2026-08-15 (6) — `rfork`: one process-creation primitive, no
process/thread split

**Goal:** with the microkernel roadmap complete, close the gap the
architecture guide's own "What's next" flagged — every process gets an
identical default namespace today because nothing yet creates a process
with a *different* one. Build something in the spirit of Plan 9's
`rfork(2)`: a single syscall, controlled by flags, that produces either
an independent child (`fork`) or one sharing the caller's address space
(a "thread") — the same call, a flag apart, so there's never a separate
thread-creation API to maintain alongside process creation. Scoped to
exactly two flags — `RFPROC` (required) and `RFMEM` (share memory
instead of copying it) — since racccoon has no fd table, note groups, or
env groups for the rest of Plan 9's real flag set to attach to. Full
design in the (still-present) plan file at
`.claude/plans/giggly-prancing-iverson.md`.

**Why this was harder than anything since the trap-frame work itself:**
every process before this was created by `create_process()`, which
always starts a *fresh* image at a fixed entry point. `rfork`'s child has
to resume *mid-syscall*, at the exact point the parent called it, with
different register state (`a0 = 0`) but otherwise identical context —
something this kernel had never done. Solved by copying the parent's own
31-word `Trap_frame` (live on its kernel stack inside `handle_syscall`)
into a 32-word block (31 GPRs + a separately-saved `sepc`, since `sepc`
is a single CPU CSR with nothing else to inherit it from) on the child's
own fresh kernel stack, and giving it a new naked entry point,
`fork_entry()` (`src/process.c3`) — deliberately a *separate* function
from `kernel_entry`'s own restore tail, not a refactor to share it, to
keep zero risk to the one function this project's history says never to
touch casually.

**Memory: full copy for `RFPROC` alone, literal page-table-pointer
aliasing for `RFMEM`.** The copy path reuses `SYS_EXIT`'s own page-table
walk shape (walk table1 → table0 → leaf) verbatim, copying instead of
freeing. The share path is one line — `child.page_table =
current_proc.page_table` — true sharing, not a second mapping of the
same pages. That reintroduced a real hazard `SYS_EXIT`'s teardown wasn't
built for: two `Process` structs can now point at the *same* table, and
the first one to exit must not free memory the other is still running
on. Fixed with a linear `PROCS_MAX`-sized scan before the free loop
(any other live process sharing this exact pointer? skip freeing
entirely) — no new field, since `page_table` pointers are never aliased
any other way.

**A real bug, found the same way the last two were — stress testing, not
inspection.** `rforktest` (plain `RFPROC`) worked first try, reliably.
`rforkmemtest` (`RFPROC|RFMEM`) silently never printed anything from the
child — no crash, no hang of the whole system (the shell kept responding
to other commands), just... nothing from that one process, forever.
Diagnostic prints (temporarily, in `yield()` and `handle_syscall`)
showed the scheduler *repeatedly* selecting and switching to the child —
but the child never made a single syscall of its own, meaning it never
even reached its first `print()` call. Root cause, worked out by hand-
tracing the exact stack addresses involved: `RFMEM` shares the *live
user stack* too, not just the address space in the abstract. The child's
saved resume point sits mid-call, inside `rfork()`'s and `syscall()`'s
own stack frames — and at typical optimization levels those wrapper
functions' own return addresses get spilled onto that same, now-shared
stack. The parent's very next function call (its own `print()`,
happening before the child is ever scheduled, since scheduling is
cooperative) overwrites exactly that memory. When the child finally
resumes, unwinding back out through those frames jumps into whatever the
parent left behind instead. This is not a bug in `rfork` — `rforktest`
proves the core mechanism (register/PC save-restore, memory sharing at
the page-table level) is correct — it's `RFMEM`'s documented behavior
matching real Plan 9 exactly: raw `rfork(RFMEM)` was never meant to be
used bare, only under a threading library that gives the child its own
stack before doing anything else. Fixed `rforkmemtest` itself, not
`rfork`, by inlining its ecall directly in `main()`'s own frame instead
of going through the `rfork()`/`syscall()` wrappers — no function-call
boundary for the child to unwind back through, so nothing spills to the
at-risk stack region in the first place. This sidesteps the hazard for
*this one command*; it doesn't make general `RFMEM` use safe, and isn't
meant to — that's exactly the seam a future stack-aware wrapper would
fill.

**Verified:** `rforktest` and `rforkmemtest` both reliable — 20/20 clean
on a from-scratch build, plus 15 more immediately prior, plus full
regression (`hello`/`ping`/`p9test`/`nstest`/`writefile`/`readfile`/
`exit`+respawn/`rforktest`/`rforkmemtest`, one boot) and
`scripts/stress_test.sh 15` on both existing scenarios — 65+ consecutive
clean runs across all of this session's testing before calling it done,
given this phase's own history of a plausible-looking first attempt
turning out to hide a real bug.

**Next up:** nothing currently planned — the microkernel roadmap and this
follow-up are both done. A stack-aware wrapper around `RFMEM` (give the
child a fresh stack before it runs anything) would be the natural next
increment if `RFMEM` needs to be genuinely usable rather than just
demonstrated; a private, restricted namespace for a sandboxed child (the
namespace-copy machinery this phase added is already in place for it)
is the other obvious direction.

**Files changed:** `src/entry.c3`, `src/process.c3`, `user/user.c3`,
`user/shell.c3`.

---

## 2026-08-15 (5) — Microkernel roadmap phase 5: fsd, the last kernel
filesystem code moved out

**Goal:** move `src/fs.c3`'s tar parsing out of the trusted kernel into
its own user-mode process, `fsd` — the final phase of the microkernel
plan. `SYS_READFILE`/`SYS_WRITEFILE` are gone from the kernel now; file
access only happens over IPC.

**Much simpler than phase 4, for a specific reason.** diskd needed the
kernel to become an IPC *client* (the `KERNEL_PID`/`kernel_reply_waiter`
machinery from the last entry), because `fs_init()`/`fs_flush()` still
ran as kernel code at the time. fsd doesn't have that problem — it's a
genuine process, so it just uses ordinary blocking `ipc_send`/`ipc_recv`
(`p9_call`) like any other client, both to serve requests and to talk to
diskd itself. That let all of the `KERNEL_PID` machinery from phase 4 be
deleted outright — it existed only to bridge a transitional state, and
this phase closed the gap it was bridging. Also worth noting: fsd never
hits the sscratch/nested-trap hazard `SYS_IPC_POLL` was built for either
— that was specific to diskd waiting on a *hardware interrupt* while
parked mid-trap; ordinary process-to-process IPC (which is all fsd ever
does) wakes the receiver via an explicit state flip in `SYS_IPC_SEND`,
not an asynchronous event, so an ordinary blocking wait is fine.

**Protocol:** `FS_READ`/`FS_WRITE`, a small message layout (100-byte
filename, 4-byte length, up to 1024 bytes of data — matching the file
size the old direct-copy `SYS_WRITEFILE` syscall always allowed, so
moving this out of the kernel didn't quietly shrink the max file size).
`MSG_MAX` bumped from 516 (sized for diskd's one sector) to 1128 to fit
it — trivial cost, ~5KB more kernel BSS across 8 process slots.

**Namespace wrinkle:** the existing default mount is `"/" -> echod`, but
every file access in this codebase has always used a bare filename with
no leading slash (`"hello.txt"`), which never matches a `"/"` prefix.
Rather than force filenames into a path scheme they've never used, added
a *second* default mount with an **empty-string prefix** — `""` — which
`str_starts_with` already treats as matching anything, and whose zero
length always loses a longest-prefix-match tie against `"/"`. That makes
it a genuine catch-all: `"/some/path"` still resolves to echod (p9test
unaffected), while any bare filename falls through to fsd. No changes
needed to `SYS_NS_RESOLVE` itself — this reused the longest-prefix-match
logic phase 3 already built, just with a new kind of mount entry.

**Two bugs, both caught before calling it done, not after:**

1. `user/fsd.c3` declared `FS_READ`/`FS_WRITE`/`FS_MSG_MAX` itself, not
   realizing `user/user.c3` (which every user program compiles together
   with — see `scripts/build_user.sh`) already declared them for the
   client side. Duplicate-declaration compile error, caught immediately.
2. A real one: first boot of fsd panicked with `unexpected trap
   scause=2` (illegal instruction) at a `sepc` that disassembled to a
   bare `unimp` sitting where a function call should have been —
   `scripts/build_user.sh` never passed `--safe=no` to `c3c
   compile-only` for user builds (only the kernel build had it), so
   fsd's array-indexing-heavy code was compiled with bounds/overflow
   checks whose failure path calls a panic handler that doesn't exist in
   this freestanding environment — the trap fires correctly, there's
   just nothing on the other end to catch it. shell/echod/diskd happened
   to never trip a check, so this had been latent since phase 1. Fixed
   by adding `--safe=no` to `build_user_program`, matching the kernel's
   own flags — the right fix regardless of whatever fsd bug (if any) had
   actually tripped a check, since a freestanding kernel target has
   nowhere for a safety-check panic to go either way.

**Verified:** `hello`, `ping`, `p9test`, `nstest` (updated — see below),
`writefile`, `readfile`, `exit`+respawn, one clean boot. `readfile`/
`writefile` now round-trip entirely through fsd → diskd over IPC, zero
kernel involvement. `scripts/stress_test.sh 20` clean on both scenarios
— its own success markers needed updating too, since they grepped for
kernel-side `io::printfn` output (`"file: hello.txt"`, `"wrote %d bytes
to disk"`) that no longer exists now that fs.c3 is gone; added matching
prints to fsd.c3 (`"fsd: file: ..."`, `"fsd: wrote N bytes to disk"`)
and updated the script rather than declare 40 non-hangs "failures."
`nstest`'s "nope has no mount" assertion also needed updating — it now
*does* resolve, to fsd, which is the whole point of the catch-all; it
asserts the new pid instead.

**Roadmap status:** all five phases of the original microkernel plan are
now done. The kernel's own trusted surface is down to: process/scheduling,
paging, traps/syscalls, IPC, namespace resolution, and PLIC interrupt
routing — no device drivers, no filesystem, no knowledge of what a "file"
or a "disk" even is. Both diskd and fsd are ordinary user-mode processes
reachable only through the same primitives any future server would use.

**Files changed:** `src/process.c3`, `src/entry.c3`, `src/kernel.c3`,
`src/fs.c3` (deleted), `user/fsd.c3` (new), `user/user.c3`, `user/shell.c3`,
`scripts/build_user.sh`, `scripts/build.sh`, `scripts/stress_test.sh`.

---

## 2026-08-15 (4) — Microkernel roadmap phase 4: diskd, the virtio-blk
driver moved to user mode

**Goal:** move `src/virtio.c3`'s driver logic out of the trusted kernel
into a new user-mode process, `diskd` — phase 4 of the microkernel plan.
The kernel keeps owning `fs.c3`'s tar parsing for now (that's phase 5);
this phase is specifically about who talks to the hardware.

**The hard part, and how it got solved:** a paged U-mode process only
sees virtual addresses, but the virtio device's queue/descriptor fields
are physical, and the legacy virtio layout needs the virtqueue to be one
physically contiguous run — something diskd's own per-page image mapping
can't guarantee (each page comes from a separate `alloc_pages(1)` call).
Solved by having the kernel allocate diskd's virtqueue and request buffer
at process-creation time (`setup_diskd_mappings`, `src/process.c3`,
guaranteed contiguous via a single `alloc_pages(n)` call) and
**identity-map** them into diskd's own page table (vaddr == paddr) — so
diskd's own pointer dereferences and the physical addresses it hands the
device are the same number, no translation needed. diskd learns that
number via a new syscall, `SYS_DISKD_INFO`, called once at its own
startup — it has no other way to find out (can't call `alloc_pages()`
itself, and can't derive it from anything it's told at compile time).
Device MMIO (`VIRTIO_BLK_PADDR`) is now mapped into diskd's page table
only — every other process's `create_process` mapping loop stopped
mapping it (it used to be universal). PLIC MMIO stays mapped everywhere,
unchanged: `handle_trap`'s `plic_claim()`/`plic_complete()` are S-mode
code reached from inside a trap regardless of which process's page table
happens to be active, not something any one process owns.

**Interrupt routing changed too.** The old kernel-resident driver just
let *whichever process happened to be `wfi`-waiting* wake up naturally
when the interrupt fired. With the driver in its own process, that's not
good enough — `handle_trap`'s interrupt branch now recognizes
`IRQ_VIRTIO_BLK` specifically and delivers a synthetic message
(`DISKD_IRQ_NOTIFY`) straight to diskd's inbox, waking it if blocked,
regardless of who was actually running when the IRQ landed.

**A genuinely new problem: the kernel itself needed to be an IPC
client.** `fs_init()`/`fs_flush()` still run as kernel code (either
during `kernel_main`'s own boot-time call, or inside a
`SYS_READFILE`/`SYS_WRITEFILE` syscall), and now need to *send a request
to diskd and block for the reply* — but IPC's addressing is pid-based,
and the kernel isn't a process. `current_proc` at boot time is
`idle_proc`, whose pid is deliberately 0 (unaddressable) — using it
directly as the reply target would have made every boot-time disk read
silently undeliverable. Added a reserved sentinel, `KERNEL_PID = -1`,
recognized specially by `SYS_IPC_SEND`'s handler: a message addressed to
it lands in kernel-owned globals (`kernel_msg_data` etc.) instead of a
`Process`'s inbox, and a new `kernel_reply_waiter` pointer tracks which
process (if any) is parked waiting for it, so delivery can flip that
process back to `PROC_RUNNABLE` — mirroring what `SYS_IPC_SEND` already
does for an ordinary `Process` target, just for a target that isn't one.
`fs.c3`'s new `diskd_read_write()` uses this to talk to diskd regardless
of whether it's running as idle_proc (boot) or a real process (a syscall)
— and routing disk-driver replies through a separate channel, rather
than whatever process's own inbox happens to be current, also avoids any
chance of colliding with that process's own unrelated IPC traffic.

**A real bug, caught by the project's own stress-testing habit, not by
inspection.** diskd's first version blocked on `ipc_recv()` for the
completion notify, the same way it already blocked waiting for a client
request. Manual boots mostly worked; 20 automated boot-only runs (no
shell input, just `fs_init()`'s own reads) showed 8/20 hanging right
after diskd kicked the virtqueue. Root cause: `sstatus.SIE` has no
per-process save/restore in this kernel (`kernel_entry` only saves GPRs),
and whether interrupts are actually enabled while a process sits blocked
in `SYS_IPC_RECV` depends entirely on leftover state from whatever trap
last ran — not on anything the blocked process controls. That was
harmless before now: `SYS_GETCHAR`'s own retry loop just re-polls the SBI
console each time it wakes, it was never actually waiting *on* an
interrupt. diskd's completion-wait was the first blocking `ipc_recv` in
this codebase that genuinely needed one to fire to make progress.

The obvious fix — call `enable_interrupts()` right before yielding in
`SYS_IPC_RECV`'s loop — made things *worse*: 8/20 runs now paged-faulted
instead of hanging. Root cause of that: `switch_context` unconditionally
resets `sscratch` to a fixed "top of this process's own stack" value on
*every* switch, which is only correct when a process is about to take a
*fresh* trap. When resuming a process that's paused *mid*-trap (exactly
diskd's situation, blocked inside its own `SYS_IPC_RECV` call), that
reset clobbers the correctly-advanced value `kernel_entry`'s own prologue
had set for that in-progress frame. Enabling interrupts there risks a
nested trap building its own frame at that fixed (wrong) address,
overlapping and corrupting the still-live outer one — the same *family*
of bug as the reentrant-trap corruption from the previous session's
lost-wakeup fix, reached by a different path this time (resumption-time
`sscratch` reset, not "re-enabled with a completion still pending").

Properly fixing `sscratch` handling for resumed-mid-trap processes felt
like too large and risky a change to make as a side effect of this
phase. Instead: gave diskd a genuinely **non-blocking** poll syscall,
`SYS_IPC_POLL` — checks once, never sets `PROC_BLOCKED`, never yields.
diskd's completion-wait is now a user-mode spin calling it repeatedly.
Since diskd is never parked mid-trap between polls, `sstatus.SIE`'s
natural value (on, established once by `user_entry`) is safe to leave
alone the whole time, and the interrupt can fire and get routed normally
in the gaps. 20/20 clean boots after the fix, plus 15/15 on both of
`scripts/stress_test.sh`'s existing scenarios (35 consecutive clean runs
total) — considerably more scrutiny than the single clean boot this
project's regression bar technically requires, given how this session's
first two "fixes" each looked right until stress-tested.

**Verified:** `hello`, `ping`, `p9test`, `nstest`, `writefile`,
`readfile`, `exit`+respawn — one clean boot cycle, `readfile`/`writefile`
now flowing through diskd over IPC instead of a direct in-kernel driver
call, no behavior change visible to the shell. `scripts/stress_test.sh
15` clean on both scenarios; 20 additional bare boot-only runs clean.

**Next up:** phase 5 — move `fs.c3`'s tar parsing into its own user-mode
process (`fsd`), a 9P-lite client of diskd and server to everyone else,
eventually letting `SYS_READFILE`/`SYS_WRITEFILE` be deleted from the
kernel once the shell goes through namespace resolution + IPC for file
access too, the same way `p9test` already does for the echod-served
verbs.

**Files changed:** `src/process.c3`, `src/entry.c3`, `src/fs.c3`,
`src/virtio.c3` (gutted to just the struct shapes/consts diskd's mapping
setup still needs), `src/kernel.c3`, `user/diskd.c3` (new), `user/user.c3`,
`scripts/build_user.sh`, `scripts/build.sh`.

---

## 2026-08-15 (3) — Microkernel roadmap phase 3: per-process namespace

**Goal:** implement the per-process namespace/mount table sketched in the
microkernel plan's phase 3 — the second of Rob Pike's two Plan 9 ideas
(the first, the 9P-lite message protocol, landed in phase 2). Turns the
hardcoded `pid 2` littered through `shell.c3`'s IPC test commands into a
real kernel-resolved lookup.

**What was added:**
- `src/process.c3`: a `Mount { char[32] prefix; int server_pid; }` struct
  and a `Mount[NS_MOUNTS_MAX]` (`NS_MOUNTS_MAX = 4`) `namespace` field
  added directly to `Process` — a real per-process kernel structure, not
  a global table, so a later sandboxed process can get a restricted view
  without a redesign (the whole reason this was built this way from the
  start rather than as a shared table indexed by pid). `create_process`
  populates one default binding for every new process: `"/" -> pid 2`
  (echod — always pid 2, deterministically, per the existing convention).
  There's no `fork()`/namespace inheritance yet to make private
  namespaces differ from each other, so today every process's namespace
  is identical; the table itself being per-process is what matters for
  later.
- `src/fs.c3`: `str_starts_with(char* s, char* prefix)`, a small addition
  next to the existing `str_copy`/`str_eq` helpers.
- `src/entry.c3`: `SYS_NS_RESOLVE = 8` — walks the *caller's own*
  namespace (never another process's) for the longest-prefix match
  against a given path, returns the bound server pid or `-1`. Kept
  inline in `handle_syscall`'s switch per the standing, proven convention
  in this file (see the `SYS_EXIT`/`SYS_READFILE` comments) rather than
  risking the unexplained factor-into-a-function reboot bug again.
- `user/user.c3`: `ns_resolve(path)` (thin syscall wrapper) and
  `p9_call_path(path, verb, ...)` — the namespace-aware counterpart to
  the existing `p9_call(pid, verb, ...)`, resolving the path through the
  caller's namespace before sending.
- `user/shell.c3`: `p9test` now calls `p9_call_path("/some/path", ...)`
  and `p9_call_path("/", ...)` instead of hardcoding `p9_call(2, ...)` —
  no more magic pid in the protocol-layer test. Added `nstest`, a direct
  smoke test of `ns_resolve` itself (`/anything` resolves to pid 2;
  `nope`, which doesn't start with `/`, correctly resolves to nothing).
  `ping` was deliberately left using the raw hardcoded pid — it's the
  raw-IPC-primitive test, one layer below where namespace resolution
  belongs, and mixing concerns there would muddy what each command
  actually proves.

**Verified:** one clean boot cycle running `hello`, `ping`, `p9test`,
`nstest`, `writefile`, `readfile`, `exit` (respawn) back to back — no
regressions, `p9test`'s replies unchanged now that they arrive via
namespace resolution instead of a hardcoded pid. Also reran
`scripts/stress_test.sh 10` (both scenarios) to confirm this didn't
disturb the interrupt-driven disk path from the previous entry — 20/20
passed.

**Next up:** phases 4/5 of the microkernel plan — `diskd` (move
`virtio.c3` to a user-mode process, route the PLIC interrupt as an IPC
wake-up to it specifically instead of "whoever's `wfi`-waiting", and stop
mapping virtio/PLIC MMIO into every process) and `fsd` (move `fs.c3`'s
tar parsing to a user-mode 9P-lite server, client of `diskd`, eventually
letting `SYS_READFILE`/`SYS_WRITEFILE` be deleted from the kernel
entirely once the shell goes through namespace resolution + IPC for file
access too). Both are real, separately-scoped efforts — not started yet.

**Files changed:** `src/process.c3`, `src/fs.c3`, `src/entry.c3`,
`user/user.c3`, `user/shell.c3`.

---

## 2026-08-15 (2) — The flaky disk hang, root-caused and fixed (with a
detour through a worse bug I introduced fixing it)

**Goal:** chase down the ~1-in-7 clean hang in `fs_init()`'s
interrupt-driven disk reads, flagged but not investigated in the previous
session's devlog entry.

**Root cause, confirmed empirically, not guessed:** a classic lost-wakeup
race between checking `virtq_is_busy()` and executing `wfi` in
`read_write_disk()`. If the completion interrupt lands in that gap, the
PLIC claim/complete happens as part of an ordinary trap right there, and
the `wfi` that follows immediately after then waits forever for an
interrupt that already fired and was already consumed — nothing will
ever wake it, since the disk request it was waiting for is already done.
Confirmed by adding diagnostic prints before the busy-check (which delay
it enough that the device usually finishes first, skipping the risky
window entirely) and watching the hang disappear across 15 runs —
exactly the signature of a real race, not a fixed bug. The standard fix:
disable interrupts before the check, keep them disabled across the whole
check-and-wfi loop (`wfi` still wakes on a pending-but-globally-masked
interrupt — that's the actual point of the pattern), only re-enable once
the condition is genuinely met.

**That fix introduced a second, worse bug — full page-table corruption on
every `writefile`.** Re-enabling interrupts with the completion still
pending (never claimed, since it stayed masked through the whole wait)
made the CPU take it immediately as a **nested** trap — while the
*original* trap (`kernel_entry -> handle_trap -> handle_syscall -> ... ->
read_write_disk`) was still fully on the stack, not yet returned. Every
trap, nested or not, uses the exact same fixed `sscratch` anchor to build
its frame — there's no reentrancy accounting in `kernel_entry` at all —
so the nested trap's own prologue silently overwrote the *still in-flight
outer* trap's saved context in place, including its saved `sp`. 100%
reproducible: any `writefile` corrupted the calling process's `sp` to
point somewhere inside the kernel's own `procs[]` array, and the very
next thing that process touched its stack for page-faulted trying to
write into kernel memory from user mode. Traced precisely by computing
the byte offset of the faulting address into `procs[]` and confirming it
landed inside the writing process's own kernel-stack region, near the top
— exactly where a trap frame would sit.

**Real fix**: claim and complete the pending PLIC interrupt *ourselves*,
inside `read_write_disk`, immediately after the wait loop exits but
*before* re-enabling — so nothing is ever left pending at the moment
interrupts flip back on, and the nested-trap scenario can't happen at
all. Small, surgical, and directly closes the mechanism rather than
working around a symptom.

**Verified thoroughly**, three separate scenarios, all previously
reproducible failures: the original bare-mode hang (15/15 clean),
`writefile` immediately followed by returning to the shell prompt — the
scenario that was 100% reproducible with the interrupt-disable fix alone
(15/15 clean), and the full interactive regression — `hello`, `ping`,
`p9test`, `readfile`, `writefile`, `exit`+respawn, `hello`, `exit` (10/10
clean).

**A methodological note for future sessions**: this is a good example of
why "it got more reliable when I added debug prints" is a *diagnostic
signal*, not a fix — the reflex has to be "why did delay change the
outcome," not "great, ship it." It would have been easy to declare victory
after the first clean 30-run bare-mode test and never notice the
reentrancy bug the same change had introduced, since it only manifests on
a completely different code path (`writefile`'s per-syscall multi-sector
loop) that a narrower test wouldn't have touched.

**Files changed this session:** `src/entry.c3`, `src/virtio.c3`.

---

## 2026-08-15 — Microkernel route, step 2: a 9P-lite verb set

**Goal:** phase 2 of the roadmap in
`/home/blallo/.claude/plans/giggly-prancing-iverson.md` — a small,
fixed message-oriented protocol layered on top of last session's raw
IPC primitive, per the Plan 9-inspired direction (message protocol +
per-process namespace) agreed with the user. As planned, this needed no
new kernel *mechanism* — just one small completion to the primitive, plus
a shared convention.

**The one primitive gap**: `SYS_IPC_RECV` only ever returned who sent a
message, not what kind (`msg_type`) — fine for phase 1's raw echo test,
not enough for a real client to tell a normal reply from an error without
guessing from byte content. Fixed by repurposing `ipc_recv`'s previously-
always-zero 3rd syscall argument as an optional `uint*` out-pointer for
the type (`src/entry.c3`'s `SYS_IPC_RECV` case writes through it when
non-null). `user/user.c3` gained `ipc_recv_type(buf, len, &type)`, with
the original `ipc_recv(buf, len)` becoming a thin wrapper passing `null`
— existing callers (echod's raw echo, shell's `ping`) unchanged.

**The protocol itself** (`user/user.c3`, shared by every user program
since it's compiled into each one): two verbs to start, `P9_TWALK` and
`P9_TREAD` (numeric constants carried in the already-opaque `msg_type`
field — the kernel still never interprets it, exactly as planned), plus
`p9_call(dest_pid, verb, data, len, reply_buf, reply_len, reply_verb)`
combining send+recv into the one call shape every 9P-lite client
actually wants, matching 9P's own synchronous request/reply model.

**`echod` learned the two verbs** without losing its original job:
`P9_TWALK` gets acked back verbatim (no real namespace to resolve
against yet — that's the next phase), `P9_TREAD` gets a canned reply
string, and anything else (including plain untyped messages) falls
through to the original raw echo, so `ping` needed no changes at all.
`user/shell.c3` gained a `p9test` command exercising both verbs via
`p9_call` and checking `reply_verb` matches what was asked, not just
that *some* reply came back.

**Verified**: `p9test` prints `walk ack: some/path` and
`read: hello from 9p-lite`, both correctly typed. Full regression
(`hello`, `ping`, `p9test`, `readfile`, `writefile`, `exit` + respawn,
`hello`, `exit`) passed clean, single boot cycle, across 6 of 7 runs.

**One thing noticed, not caused by this session, not chased down**: about
1 in 7 runs of the exact same input hangs cleanly (no crash, no
corruption, no reboot loop — just stops progressing) partway through
`fs_init()`'s interrupt-driven disk reads, always before the tar
listing prints. Reproduced identically in last session's testing before
any of today's changes existed, so it predates phase 2 — most likely a
rare lost-wakeup race in the PLIC/`wfi` interrupt path from two sessions
ago (an interrupt firing and being claimed before the waiting process's
`wfi` actually executes, so the wake it needed never arrives). Worth a
dedicated investigation at some point; not urgent since it's rare, always
fails clean, and every success is fully correct.

**Next up:** phase 3, the per-process namespace/mount table — the piece
that turns `p9_call(2, P9_TWALK, "some/path", ...)`'s hardcoded pid `2`
into an actual path resolution, and phase 4/5 (`diskd`, `fsd`) after
that. See the plan file for the full roadmap.

**Files changed this session:** `src/entry.c3`, `user/user.c3`,
`user/echod.c3`, `user/shell.c3`.

---

## 2026-08-14 (12) — Microkernel route, step 1: IPC primitive, plus a
published architecture guide

**Goal:** two things, in order. First, a standalone illustrated reference
guide to the kernel's current architecture (published as an Artifact,
separate from this devlog — a "how it works" document rather than a
"how it got here" one). Second, the first concrete slice of the
microkernel direction discussed with the user: kernel-level message
passing between processes, deliberately designed around Plan 9's two
ideas (a message-oriented protocol and a per-process namespace) rather
than a generic capability-token scheme — full reasoning and the phased
roadmap are in `/home/blallo/.claude/plans/giggly-prancing-iverson.md`
(approved plan file). This session is phase 1 of that roadmap only:
prove two processes can actually exchange a message. No 9P-lite verbs,
no namespace, no driver/FS migration yet — those are future sessions.

**Architecture guide**: published as a Claude Artifact (favicon 🦝,
titled "Racccoon Internals"), covering boot, the address space, the
bitmap page allocator, Sv32 virtual memory, processes/scheduling, traps
and syscalls (including the `sscratch`/trap-frame mechanism and the real
bug that hit it), interrupts, the disk driver, the file system, and
userland — five hand-drawn inline-SVG diagrams showing actual mechanisms
(the Sv32 page-table walk, the syscall round-trip's register save/restore,
etc.), not decorative boxes. Visual identity deliberately grounded in the
project's own name — a raccoon's fur-grey/mask-black/amber-eye palette —
rather than a generic tech-doc look.

**IPC primitive** (`src/process.c3`, `src/entry.c3`, `user/user.c3`,
new `user/echod.c3`):
- New `PROC_BLOCKED` process state. `yield()`'s scheduling scan already
  only matches `PROC_RUNNABLE`, so a blocked process is automatically
  skipped — no scheduler change needed beyond the state itself and its
  transitions.
- Each `Process` gained a single-slot inbox
  (`has_message`/`msg_from`/`msg_type`/`msg_data[64]`) — no queue, no
  allocator. This makes send/receive a synchronous rendezvous with one
  known v1 gap: the *receiver* blocks until a message arrives, but the
  *sender* doesn't block if the target's inbox is already full — it just
  overwrites it. Safe as long as callers keep to one outstanding
  request at a time, which is all this phase's traffic does; noted in
  the plan as a deliberate simplification, not an oversight.
- Two new syscalls, `SYS_IPC_SEND`/`SYS_IPC_RECV` (6/7), handled inline in
  `handle_syscall`'s switch — same established, load-bearing convention
  as `SYS_EXIT`/`SYS_READFILE`/`SYS_WRITEFILE`: factoring this out into a
  separate function has reproducibly broken boot in this c3c version
  before, for reasons never root-caused, so new cases stay inline too.
  `SYS_IPC_SEND` needed a 4th argument (`dest_pid`, `type`, `data_ptr`,
  `len`) beyond the existing 3-arg syscall ABI — solved with a new
  `syscall4` in `user/user.c3` that also sets `a4` (already captured by
  `Trap_frame`, just unused until now), rather than changing the
  existing 3-arg `syscall()` every other syscall already relies on.
  `SYS_IPC_RECV` re-checks `has_message` in a loop after waking, same
  wait-then-recheck shape already used by `SYS_GETCHAR` and
  `virtq_is_busy`'s `wfi` loop.
- `proc_by_pid()` (`process.c3`): pid → `Process*`, trivial given
  `create_process` already assigns `pid = slot_index + 1`.

**Second user process, for real verification**: `scripts/build_user.sh`
was hardcoded to one program; refactored into a `build_user_program()`
function so `scripts/build.sh` now builds and embeds two independent
binaries (`shell.bin.o`, `echod.bin.o`) — both linked at the same
`USER_BASE`, which is fine since each only ever exists in its own
process's own page table. `user/echod.c3` is a minimal IPC test server:
receive, echo the same bytes back to the sender. `kernel_main` spawns it
once, right after idle (not through the shell's respawn loop — it isn't
meant to come back after exiting), which makes it deterministically
process slot 1 / pid 2 every boot. `user/shell.c3` gained a `ping`
command hardcoding that pid — a placeholder until there's a real
name → pid lookup (the namespace phase, not this one).

**Verified**: `ping` from the shell prints `echod (pid 2) replied: hello
echod` — a real message round-tripping through two independently
scheduled user processes. Full regression (`hello`, `ping`, `readfile`,
`writefile`, `exit` + respawn, `hello`, `exit` again) passed clean across
four separate runs, single boot cycle every time (one run hit an
unrelated one-off hang before any input was even processed — did not
reproduce across three immediate retries with the identical binary and
input, treated as QEMU/host timing flakiness rather than a kernel bug).

**Next up:** phase 2 of the roadmap (9P-lite verb set: a small fixed
op-code + path/data message shape layered on top of this raw IPC
primitive) and phase 3 (the per-process namespace/mount table) — see the
plan file for the full roadmap through moving the disk driver (`diskd`)
and file system (`fsd`) out of the trusted kernel.

**Files changed this session:** `src/process.c3`, `src/entry.c3`,
`user/user.c3`, `user/echod.c3` (new), `user/shell.c3`,
`scripts/build_user.sh`, `scripts/build.sh`, `src/kernel.c3`.

---

## 2026-08-14 (11) — Interrupt-driven disk I/O (PLIC), and a real
architectural bug this time, not a compiler mystery

**Goal:** replace `virtq_is_busy`'s tight busy-wait spin in
`read_write_disk` with real interrupt-driven waiting — ch.17's "do not
busy-wait for disk I/O" suggestion, left as an exercise by the tutorial
(no reference implementation to port from).

**What was added:**
- `src/plic.c3` (new): QEMU virt's PLIC (SiFive-style, same layout
  xv6-riscv targets). `plic_init()` sets priority>0 and enables IRQ 1
  (virtio-blk on `virtio-mmio-bus.0`, slot 0) for the S-mode context
  (context 1 for hart 0 — context 2*hart=M-mode, 2*hart+1=S-mode is
  QEMU virt's fixed wiring), threshold 0. `plic_claim()`/`plic_complete()`
  for acknowledging IRQs. Also exports page-aligned bases of the three
  distinct pages its registers span (priority/enable/claim aren't
  page-aligned individually, and aren't contiguous with each other).
- `src/entry.c3`: `handle_trap` now checks `scause`'s MSB to distinguish
  interrupts from exceptions before doing anything else; a supervisor
  external interrupt (cause code 9) claims and completes via the PLIC and
  falls through — no `sepc` adjustment needed for interrupts (unlike
  `ecall`, hardware already points `sepc` at the correct resume address).
  Added a general `write_csr(reg, value)` macro (generalizing
  `write_sepc`'s proven memory-bridged pattern to any CSR name) and
  `enable_external_interrupts()` (sets `sie.SEIE` and `sstatus.SIE`).
- `src/virtio.c3`: `read_write_disk`'s `while (virtq_is_busy(vq)) {}` is
  now `while (virtq_is_busy(vq)) { asm { wfi; } }` — the interrupt's only
  job is to wake the CPU; the real completion check (the used ring index)
  still happens in the loop condition itself, same as before.
- `src/process.c3`: mapped the PLIC's three pages into every process's
  page table (`PAGE_R|PAGE_W`, no `PAGE_U`) — proactively, learning from
  the ch.16 session where the equivalent virtio-blk mapping was missing
  and only surfaced once a syscall (not just `kernel_main`'s bare-mode
  bring-up) actually exercised the driver.

**A real, understood bug this time — not another unexplained c3c quirk.**
`sscratch` needs to point at a valid place to build a trap frame at all
times once interrupts are enabled, including during `kernel_main`'s own
bare-mode phase (before any process exists) — this matters concretely
because `fs_init()`'s initial disk reads happen in exactly that window,
and are now interrupt-driven too. First attempt anchored `sscratch` at
`&__stack_top` — reasoning (wrongly) that this parallels how a real
process's `sscratch` points at its own dedicated kernel stack. Result:
`fs_init`'s own local variable (`sector`, the sector-read loop counter)
got corrupted mid-loop to a garbage pointer-looking value, and shortly
after, execution jumped into a data page as if it were code (`scause=2`,
illegal instruction, at a `__free_ram`-range address).

Root cause, found by reading the disassembly rather than guessing:
`__stack_top` is not a spare/unused address — it's the literal top of the
**live boot stack kernel_main is actively executing on**. By the time an
interrupt fires deep inside `fs_init → read_write_disk → wfi`,
kernel_main's real stack pointer has already moved well below
`__stack_top` (several call frames deep). But `kernel_entry` unconditionally
resets `sp` to the fixed `sscratch` value on every trap and builds a new
124-byte frame downward from there — plus `handle_trap`'s own call depth
(`plic_claim`, `plic_complete`, any debug prints) growing further down
still. That collides with kernel_main's *own, currently-active* stack
frames occupying that exact same region, silently overwriting their
locals. A real process doesn't have this problem: its `sscratch` points
at a 64KB stack *nothing else is using concurrently*. `kernel_main`'s
bare-mode phase had no such isolated region — `__stack_top` looked like
one but wasn't.

**Fix**: a dedicated `char[4096] boot_trap_stack` global in `entry.c3`,
used only as the bare-mode `sscratch` anchor — a genuinely separate
memory region kernel_main's own execution never touches, so trap handling
during this window can never collide with it regardless of call depth on
either side.

**Verified thoroughly**: with the fix, all 5 of `fs_init`'s sector reads
completed via real interrupts (confirmed via trace: `scause` code 9,
`plic_claim` correctly returning IRQ 1, each time) with no corruption,
followed by a full regression — `hello`, `readfile`, `writefile`,
`readfile` (showing the write persisted), `exit`, respawn, `hello`,
`exit` again — single clean boot, no crashes. This exercises the
interrupt-driven path from both contexts that matter: `fs_init`'s
bare-mode reads (using `boot_trap_stack`) and a `writefile` syscall's
`fs_flush → read_write_disk` (using a real process's own `sscratch`,
which was already correct).

**Files changed this session:** `src/plic.c3` (new), `src/entry.c3`,
`src/kernel.c3`, `src/process.c3`, `src/virtio.c3`.

---

## 2026-08-14 (10) — Root cause found: the "mystery compiler bug" was a
misaligned trap vector, not a compiler bug

**Goal:** the previous session's respawn fix worked but leaned on two
unexplained, bisection-only "workarounds" (capture `create_process`'s
return value; keep the idle loop bounded under ~1000 iterations instead
of truly infinite). User correctly pushed back that this looked like
papering over the symptom rather than a real fix, and asked for a proper
disassembly-level investigation instead of more black-box bisection.

**Method:** built two kernels differing *only* in the idle loop's bound
(`1000`, known-working vs `10000`, known-broken), and diffed everything:
`c3c`'s LLVM IR output (`build/llvm/elf-riscv32/kernel.ll`) for
`kernel_main`, then the final RISC-V disassembly (`llvm-objdump -d`).

**Finding #1 — the IR is innocent.** The two `kernel_main` LLVM IR bodies
are byte-for-byte identical except for the literal constant in the loop
exit comparison (`icmp eq i32 %add14, 1000` vs `..., 10000`). So this was
never a c3c *frontend* bug — whatever's wrong happens later, in codegen or
linking.

**Finding #2 — the actual bug.** `10000` doesn't fit RISC-V's 12-bit
immediate the way `1000` does, so loading it takes one extra 2-byte
compressed instruction. That shifts every following symbol's address by
2 bytes — including `kernel_entry`, the trap handler, declared
`@align(4)`. In the broken build, `kernel_entry` landed at `0x8020585e`
(low 2 bits `10`) instead of a real 4-byte boundary. `@align(4)` was
**not being honored** once an unrelated earlier code-size change pushed
it off-boundary.

This matters enormously because `stvec`'s low 2 bits *are* the trap mode
field per the RISC-V privileged spec (0=Direct, 1=Vectored, 2/3=Reserved).
`write_reg("stvec", "kernel_entry")` writes kernel_entry's raw address
straight into `stvec` with no masking. A misaligned address there doesn't
just fail to trap — it puts the CPU into **Reserved trap mode**, which is
undefined behavior. That is almost certainly the real mechanism behind
*every* "silent reboot, no panic, no trap message ever printed" incident
this project has hit — ch.16's `fs_handle_syscall`, this session's
`free_process_pages`, the discarded-return-value trigger, and the
infinite-loop trigger. Four incidents, four different-looking triggers,
one root cause: any sufficiently large code-size shift before
`kernel_entry` in link order had roughly even odds of landing it off a
4-byte boundary, and every "fix" that happened to work was really just
an incidental code-size change that happened to re-align it.

**Real fix** (not a workaround): gave `kernel_entry` its own linker
section (`@section(".text.trap")` in `src/entry.c3`) and added an
explicit `.text.trap : ALIGN(4) { KEEP(*(.text.trap)); }` rule to
`src/kernel.ld`, ahead of the generic `.text` wildcard rule — matching
how `.text.boot` was already special-cased. This makes alignment the
*linker's* job, which — unlike the function attribute — is trustworthy
here: SECTIONS block alignment directives are a core, well-tested linker
feature, not something riding on `@align` propagating correctly through
arbitrary intervening codegen changes.

**Verified thoroughly**: rebuilt with the fix and the previously-broken
`iter < 10000` bound still in place — `kernel_entry` landed at
`0x8020000c` (aligned), boot succeeded clean. Then went further and
reverted *both* prior workarounds simultaneously — genuine `for(;;)`
infinite loop, `create_process(...)` called as a bare discarded-return
statement — and it still worked perfectly: three full `hello`/`exit`
respawn cycles, plus a combined run exercising `hello`/`readfile`/
`writefile`/`readfile`/`exit`/respawn/`hello`/`exit` together. Both
workarounds are now proven unnecessary and have been removed from
`src/kernel.c3` — the code reads naturally again, no defensive comments
about compiler quirks needed.

**Not chased further, but worth knowing**: this doesn't rule out that
`@align` might also fail to be honored for *other* future functions if a
similar code-size shift lands them off a required boundary — the
fix here is specific to `kernel_entry`. If another alignment-sensitive
function is ever added (unlikely in this design, but worth remembering),
the same linker-enforced-section pattern is the trustworthy way to pin it,
not the bare attribute.

**Files changed this session:** `src/entry.c3`, `src/kernel.c3`,
`src/kernel.ld`.

---

## 2026-08-14 (9) — Shell respawn, and the deepest dive yet into the
mystery compiler bug

**Goal:** make `SYS_EXIT` actually useful — before this, exiting the
shell left the kernel idling forever with nothing to run. Idea: when
idle notices nothing else is runnable, respawn a fresh shell from the
same embedded image.

**End state (`src/kernel.c3`, `kernel_main`)**: `idle_entry()` as a
separate function is gone — its loop merged directly into `kernel_main`,
which now runs a bounded `for (int iter = 0; iter < 1000; iter++)` loop
that scans `procs[]` for any runnable non-idle process, calls
`create_process(shell)` (capturing the return value into `Process* shell`,
even though it's unused) if none is found, then `yield()`s. Verified with
three full `hello` → `exit` → respawn cycles in one session — clean single
boot, no crashes, no reboot loop.

**This took a lot longer than it should have — a genuinely deep dive into
the recurring mystery c3c 0.8.2 bug from the last two sessions, this time
with two distinct, fully-bisected triggers found:**

1. **Discarding `create_process`'s return value breaks boot as soon as
   the call site is reachable more than once in a run** — even if the
   second call never actually executes at runtime. Confirmed by testing
   two flat, sequential, unlooped `create_process(...)` statements (no
   assignment): broke boot on the *first* call already (its own "5a:"
   print didn't even fire, despite that exact call working in isolation
   for the entire rest of this project). Assigning the result to a local
   variable — `Process* s1 = create_process(...)`, `Process* s2 =
   create_process(...)` — with nothing else changed, fixed it completely.
   This is a different trigger shape from the ch.16 (`fs_handle_syscall`)
   and earlier this session (`free_process_pages`) incidents — those were
   about factoring logic into a *separate function*; this one is about a
   discarded return value from an *already-proven* function called twice.
2. **A second, independent trigger, found after fixing #1**: with the
   return value captured, a loop calling `create_process` still broke
   boot — but only when the loop was *provably infinite*. `for(;;)` and
   `while(true)` around the exact same body both failed identically. The
   identical body in a *bounded* loop (`for (int k = 0; k < N; k++)`)
   worked — and only up to a point: bisected the bound itself, since "any
   finite N is safe" turned out to also be false. `N=1000` works, `N=10000`
   silently breaks it again (reboot loop, no panic, same signature as
   every prior incident). Landed on `N=1000` — a comfortable margin under
   the failure threshold, and functionally unlimited anyway since this
   loop only actually iterates when nothing else is runnable (essentially
   once at boot, once per `exit`).

Neither trigger has a real diagnosis. Both were isolated by strict
bisection (one code change at a time, rebuild, boot-test, repeat) rather
than reasoning about what the compiler "should" be doing — reasoning
about the *expected* behavior stopped being useful several incidents ago.
At this point there have been four separate reproducible instances of
"code that looks correct and matches working patterns elsewhere in this
codebase silently corrupts boot before the new code path is ever
exercised at runtime," each with a different specific shape (new function
+ `Trap_frame*` in ch.16, new function + `Process*` earlier this session,
discarded return value here, provably-infinite loop here). If this
happens a fifth time, it's probably worth trying a c3c version bump (if
one's available) before bisecting again — this smells increasingly like
a real, still-unfixed backend bug rather than anything about this
specific code.

**Files changed this session:** `src/kernel.c3`.

---

## 2026-08-14 (8) — SYS_EXIT: process teardown, and the same mystery
compiler bug strikes a third time

**Goal:** give `free_pages` (from the bitmap allocator work) an actual
caller — process exit. `user/user.c3`'s `exit()` was still `for(;;);`; a
process that "exited" just hung forever, leaking its page table and image
pages permanently.

**What landed:**
- `src/entry.c3`: `SYS_EXIT = 3` (filling the gap deliberately left in the
  syscall numbering — this is the tutorial's own number for it, we just
  hadn't implemented it yet). `handle_syscall`'s new case walks the
  exiting process's own page table: for every valid top-level entry, walk
  its 2nd-level table; free every leaf page that has `PAGE_U` set (the
  process's private image pages — deliberately *not* the shared
  kernel-identity or virtio-MMIO mappings, which were never marked
  `PAGE_U` for exactly this reason), then free the 2nd-level table page
  itself, then finally the top-level table. Resets the `Process` struct to
  `PROC_UNUSED`/`pid=0` so `create_process`'s free-slot scan can reuse it.
  Calls `yield()` last — since the process is now `PROC_UNUSED`, `yield`'s
  scan can never match it as `next`, so `switch_context` always actually
  switches away, and its `ret` never returns back up through this call
  chain (permanently abandoning it, harmlessly — a future `create_process`
  reusing this slot reinitializes the stack from scratch anyway).
- `user/user.c3`: `exit()` now calls `syscall(SYS_EXIT, 0, 0, 0)` for
  real, with a trailing `for(;;);` kept only as an unreachable fallback so
  the function still satisfies its `@noreturn` contract.

**The mystery c3c bug from the ch.16 cleanup session struck again, a third
time, with a new shape.** First attempt factored the page-table-walk into
`free_process_pages(Process* proc)` in `process.c3` (natural home, next to
`create_process`) and called it from `entry.c3`'s `handle_syscall`. That
alone broke boot — reboot-looping from the very first syscall
(`SYS_PUTCHAR`), before `SYS_EXIT`/this function could ever run at
runtime. Bisected carefully this time (confirmed via `git status`/rebuild
cycles, isolating one line at a time): `yield();` alone in the `SYS_EXIT`
case — fine. `free_process_pages(current_proc);` alone, no `yield()` —
broken. So the call itself is what triggers it, not some interaction with
`yield()`. This rules out my ch.16 theory that the earlier
`fs_handle_syscall` incident was specifically about `Trap_frame*` crossing
a file boundary — this new function takes `Process*`, a type that's
already passed across files successfully elsewhere in this codebase, and
it broke anyway. The common thread across both incidents seems to be:
**calling a moderately-complex, newly-added function from inside
`handle_syscall`'s `switch` statement**, independent of file or parameter
type. Still no real diagnosis — not going to keep sinking time into a
c3c 0.8.2 codegen mystery with no repro simpler than "the whole kernel."
Fixed the same way as `fs_handle_syscall`: inlined the entire walk
directly into the `SYS_EXIT` case in `entry.c3` instead of factoring it
out. Confirmed via bisection that this specific case (inline, in this
exact file) is what's safe — not a general rule to necessarily distrust,
but a specific, reproducible landmine to remember if `handle_syscall`
needs new cases again.

**Verified working**: boots clean (single cycle) with the inlined
version. Ran `hello` then `exit` — shell process terminates without any
crash or reboot loop, kernel stays up with idle spinning silently for the
rest of a 6-second run (no delayed fault). Didn't re-verify the specific
freed-address reuse this time (that mechanism — `free_pages` itself — was
already proven correct in the allocator session with a dedicated
alloc/free/alloc-again sanity check); this session's testing focus was
specifically "does calling it from the real exit path crash or corrupt
anything," which it doesn't.

**Next up (not started):** no re-spawn mechanism exists yet — once the
one shell process exits, the system just idles forever with nothing left
to run. If that's ever wanted, `kernel_main`'s current one-shot
`create_process` call would need to become something idle can trigger
again (or a `fork`/multi-shell design), which is a bigger design question
than this session's scope.

**Files changed this session:** `src/entry.c3`, `user/user.c3`.
(`src/allocation.c3` diff shown in `git status` is carried over from the
allocator session, already logged above.)

---

## 2026-08-14 (7) — Bitmap page allocator with real freeing

**Goal:** replace the bump allocator (`alloc_pages` in `src/allocation.c3`)
with one that supports `free_pages`, as the first step toward eventually
tearing down exited processes and reclaiming their memory. User designed
and wrote a first draft themselves after a theory discussion (free-list vs
bitmap vs buddy allocator design tradeoffs, why the current bump allocator
can't support freeing at all); asked me to review it, then to fix it.

**Issues found in the draft:**
- Bitmap sized off `STACK_SIZE` (per-process kernel stack size,
  unrelated) instead of the actual RAM pool size — only covered 512 pages
  (2MB) against a real 64MB pool.
- The bit-set operation (`bitmap[cnt/8] & (1 << (cnt%8))`) computed a
  value and discarded it — no assignment, so it was a complete no-op.
  Needed `|=` to actually set the bit.
- Index math (`cnt/8`, `cnt%8`) assumed 8 bits per array slot, but the
  array was `uint[]` (32 bits/word) — inconsistent bit-width assumption.
- `cnt += 8` advanced by a flat constant regardless of `n` (pages
  actually requested).
- Most fundamentally: the bitmap was being updated *alongside* the old
  bump-pointer scheme, not *driving* allocation — `paddr`/the OOM check
  still came entirely from `next_paddr`. Freeing a page wouldn't have
  done anything observable, since nothing ever scanned backward for
  reusable space.

**Rewrite** (`src/allocation.c3`): `TOTAL_PAGES = RAM_SIZE / PAGE_SIZE`
bits packed into `uint[TOTAL_PAGES / 32]` (`RAM_SIZE` a new const,
commented as needing to match `kernel.ld`'s `64 * 1024 * 1024`
reservation — same "duplicated with no shared header" situation as
`USER_BASE`/the syscall numbers from earlier sessions).
`bit_is_set`/`set_bit`/`clear_bit` do the shift-and-mask. `alloc_pages(n)`
does a single-pass scan tracking a candidate run's start/length, marks the
run's bits used once it reaches length `n`, and computes the returned
address from *where the run was found* rather than a monotonic cursor.
Added `free_pages(paddr, n)`, which just clears the corresponding bits.

**Verified with a targeted sanity check** (temporarily added to the very
top of `kernel_main`, before anything else touches the allocator, then
removed once confirmed): `alloc_pages(1)` then `alloc_pages(2)` gave two
adjacent addresses; freeing both and re-allocating in the same order gave
back the *exact same addresses* (`p3==p1`, `p4==p2`) — confirming freed
pages are actually found and reused by the scan, not just skipped over.
Full boot + shell regression (`hello`/`readfile`/`writefile`/`readfile`/
`exit`) still passes clean on top of the new allocator, including the
multi-page allocations the virtio driver needs (so the run-scanning logic
is exercised for `n>1`, not just single pages).

**Next up (not started, and explicitly the user's to do solo, not mine):**
`free_pages` still has no caller anywhere in the kernel — process exit
doesn't exist yet (`user/user.c3`'s `exit()` is still `for(;;);`). The
natural next step discussed: a `SYS_EXIT` syscall that walks the exiting
process's own page table (freeing each mapped leaf page, each on-demand
L2 table page `map_page` allocated, then the top-level table itself —
*not* the identity-mapped kernel range, which is shared across all
processes) and resets its `Process` struct to `PROC_UNUSED`.

**Files changed this session:** `src/allocation.c3`.

---

## 2026-08-14 (6) — Structure cleanup pass, and a genuine unexplained c3c bug

**Goal:** address structural issues flagged after finishing the tutorial
(ch.1–16 all implemented): inconsistent module placement under
`src/kernel/`, `entry.c3` having grown into a grab-bag, duplicated
constants between the kernel and user builds with no shared source of
truth, and one piece of dead code.

**What landed:**
- **Module convention, made explicit**: `src/*.c3` = `module kernel` (the
  core's tightly-coupled internal implementation — page tables, processes,
  allocation, trap entry, the virtio driver, the file system all mutate
  shared kernel-wide state with no clean boundary between them). `src/kernel/*.c3`
  = standalone modules with a narrow, self-contained API (`sbi`, `panic`).
  Moved `fs.c3` and `virtio.c3` from `src/kernel/` to `src/` to match —
  they're `module kernel`, so they belonged with `page.c3`/`process.c3`,
  not alongside `sbi.c3`/`panic.c3`.
- Deleted `print_hex` from `kernel.c3` — dead code, never called since
  before this session started. Dropped the now-unused `import libc;` that
  went with it.
- Added cross-reference comments at every place a constant is duplicated
  with no shared header to enforce it: `USER_BASE` (hardcoded in three
  places — `kernel.c3`'s const, the literal in `process.c3`'s
  `user_entry()` asm, and `user/user.ld`'s base address) and the `SYS_*`
  syscall numbers (defined once in `src/entry.c3`, once in `user/user.c3`
  — kernel and user are separate `c3c` compilations with no shared header
  between them, unlike the tutorial's C `common.h`).

**What did NOT land, and why — a genuinely unexplained compiler bug:**
Tried moving the `SYS_READFILE`/`SYS_WRITEFILE` handling body out of
`entry.c3`'s `handle_syscall` into a new `fs_handle_syscall(Trap_frame* f)`
function next to `fs_lookup`/`fs_flush` in `fs.c3` — a pure code-motion
refactor, no logic changes. This alone (confirmed via `git stash` bisection
against the known-good committed state, testing one change at a time)
broke boot: the kernel would reboot-loop from the very first syscall
(`SYS_PUTCHAR`, printing the shell's `"> "` prompt) — a code path that
**does not call `fs_handle_syscall` at all**. Tried adding `@noinline` to
rule out an inliner bug; same failure. Reverting *only* this one
extraction (keeping every other change, including the `fs.c3`/`virtio.c3`
relocation) fixed it immediately. Root cause not identified — best guess
is a c3c 0.8.2 codegen bug specific to a function taking `Trap_frame*`
(the `@packed` trap-frame struct) called across a file boundary within the
same module, but that's speculation, not a confirmed diagnosis. Left the
`SYS_READFILE`/`SYS_WRITEFILE` body inline in `entry.c3`'s `handle_syscall`
(proven correct), with a comment explaining why it's not where it looks
like it should live. Worth retrying against a newer c3c release if one
becomes available.

**Verified working**: full regression run through `hello`, `readfile`,
`writefile`, `readfile` (showing the write persisted), `exit` — single
clean boot cycle, no regressions from any of the landed changes.

**Files changed this session:** `src/entry.c3`, `src/kernel.c3`,
`src/process.c3` (comment only), `user/user.c3` (comment only),
`user/user.ld` (comment only), `src/fs.c3` (renamed from
`src/kernel/fs.c3`), `src/virtio.c3` (renamed from `src/kernel/virtio.c3`).

---

## 2026-08-14 (5) — Tar-based file system (tutorial ch.16)

**Goal:** the real file system on top of ch.15's virtio-blk driver — files
stored as a tar archive on disk, loaded into memory at boot, exposed to
user processes via `readfile`/`writefile` syscalls.

**What was added:**
- `src/kernel/fs.c3` (new): `Tar_header` (ustar layout, 512 bytes),
  `File` (in-memory: `in_use`, `name[100]`, `data[1024]`, `size`),
  `oct2int`, `fs_init` (reads the whole disk into a `disk[]` buffer, walks
  tar headers into the `files[]` array), `fs_flush` (rebuilds the tar
  image from `files[]`, including the ustar checksum, writes it back),
  `fs_lookup`. `str_copy`/`str_eq` are small freestanding helpers (no
  `strcpy`/`strcmp` in the kernel's custom libc).
- `src/entry.c3`: `handle_syscall` gained `SYS_READFILE`/`SYS_WRITEFILE`
  (4/5), dereferencing the user-supplied filename/buffer pointers directly
  and calling `fs_lookup`/`fs_flush`.
- `src/process.c3`: `user_entry` now also sets `SSTATUS_SUM` (bit 18) in
  `sstatus` alongside `SSTATUS_SPIE` — required for S-mode to access
  `PAGE_U` pages at all; without it, the kernel dereferencing a user
  pointer (the readfile/writefile filename and buffer) page-faults
  immediately.
- `user/user.c3`, `user/shell.c3`: `readfile`/`writefile` wrappers and
  `readfile`/`writefile` shell commands, per the tutorial.
- `disk/hello.txt` (new) + `scripts/build.sh`: builds `build/disk.tar`
  from `disk/*.txt` via `tar cf ... --format=ustar`, matching the
  tutorial's approach; `scripts/launch.sh` now attaches that instead of
  the raw `resources/disk.txt` from the ch.15 session (that file is now
  unused/superseded, left in place but nothing references it).

**C3 syntax notes (not bugs):** `SomeStruct::size` for `sizeof`, not
`.sizeof` (that parses as a member lookup and fails). No `offsetof` needed
— `(uint)&file.data` already gives the same address a real typed pointer
would.

**Two real bugs found:**

1. **virtio MMIO region wasn't mapped into process page tables.**
   `create_process`'s identity-mapping loop only covers `[__kernel_base,
   __free_ram_end)`; the virtio-blk MMIO registers at `0x10001000` are
   outside that range entirely. Invisible in the ch.15 session because
   `virtio_blk_init()`/`read_write_disk()` only ran from `kernel_main`
   before any process existed (bare/physical addressing, no page table
   involved). The first `writefile` (which triggers `fs_flush` ->
   `read_write_disk` from *inside* a syscall, i.e. under the shell
   process's page table) immediately store-page-faulted writing to the
   queue-notify register. Fixed by adding
   `map_page(page_table, VIRTIO_BLK_PADDR, VIRTIO_BLK_PADDR, PAGE_R | PAGE_W)`
   to `create_process`, same pattern as the identity-mapping loop.

2. **Tutorial's own length-clamping logic is wrong, and C3's safe mode
   caught it where C would have silently corrupted a stack byte.** The
   reference C clamps the requested `len` against the *file's* internal
   1024-byte buffer (`if (len > sizeof(file->data)) len = file->size;`),
   not against the caller's own buffer or the actual file size. Ported
   faithfully at first, it let a `readfile("hello.txt", buf, 128)` call
   return `len=128` unchanged (128 < 1024, so the clamp never triggers)
   even though the file only has 17 bytes — then `buf[128] = 0` in the
   128-byte-buffer shell code is a genuine out-of-bounds write. In C this
   is silent UB that usually goes unnoticed; C3's default safe mode
   (the user build has no `--safe=no`, unlike the kernel build) correctly
   trapped it as an illegal instruction (`unimp`). Fixed by clamping
   *reads* against `file.size` (never return more than the file actually
   has) and *writes* against `file.data.len` (never write more than the
   file's storage can hold) — separately, instead of reusing one
   ambiguous check for both directions. Also added a `len >= 0` guard in
   the shell before indexing `buf[len]`, since a `-1` (file-not-found)
   return would otherwise hit the same class of out-of-bounds trap.

**One more stack-overflow, same class as the ch.14 session's:** after
fixing both bugs above, `readfile` worked once, but a second `readfile`
after a `writefile` reported "file not found" — `files[0].in_use` had
gone back to `false` and its `name` was empty, i.e. the `files[]` array
itself was getting corrupted mid-session. The file-system call chain
(`handle_syscall` -> `fs_lookup`/`fs_flush` -> `read_write_disk` ->
`virtq_kick`/`virtq_is_busy`, plus `fs_flush`'s tar-rebuild and checksum
loops) is considerably deeper and heavier than the ch.14 syscalls
(`getchar`/`putchar`) that `STACK_SIZE = 8192` was sized for, and it
overflowed into the neighboring `Process` structs in `procs[]`. Confirmed
by bumping `STACK_SIZE` to 65536 and watching the corruption disappear.
Kept the larger size permanently (512KB total across `PROCS_MAX=8`
processes is negligible against the 64MB RAM pool). While in there, also
replaced two magic numbers (`2048`, `8191`) that were silently assuming
the old `STACK_SIZE=8192` value with proper `STACK_SIZE`-derived
expressions, since those would have quietly broken again on the next
resize.

**Verified working** end-to-end in QEMU: `readfile` prints the disk's
original `hello.txt` content ("Hello from disk!"), `writefile` reports
"wrote 2560 bytes to disk", and a following `readfile` shows the new
content ("Hello from shell!") — confirming both the tar parse-on-boot and
the write-back-to-disk paths work, and that the change actually persists
in the backing tar file across the write.

**Next up (not started):** ch.17 (outro/wrap-up — the tutorial's last
chapter, mostly a victory lap rather than new functionality). After that,
the user's earlier question about a microkernel-style refactor (moving
the disk driver/file system out of kernel space into a user-mode server
via IPC) becomes the natural next thing to actually scope out.

**Files changed this session:** `src/kernel/fs.c3` (new), `src/entry.c3`,
`src/process.c3`, `src/kernel.c3`, `user/user.c3`, `user/shell.c3`,
`scripts/build.sh`, `scripts/launch.sh`, `disk/hello.txt` (new).

---

## 2026-08-14 (4) — virtio-blk disk driver (tutorial ch.15)

**Goal:** implement the virtio-blk MMIO driver so the kernel can read/write
raw 512-byte sectors from a virtual disk, per tutorial ch.15 — the
foundation ch.16's real file system will sit on.

**What was added:**
- `src/kernel/virtio.c3` (new): the full driver, ported fairly directly
  from the tutorial's C — MMIO register constants, `Virtq_desc` /
  `Virtq_avail` / `Virtq_used` / `Virtio_virtq` / `Virtio_blk_req` structs,
  `virtio_reg_read32/64` / `virtio_reg_write32` / `_fetch_and_or32`,
  `virtq_init`, `virtio_blk_init`, `virtq_kick`, `virtq_is_busy`, and
  `read_write_disk(buf, sector, is_write)`.
- `src/kernel.c3`: `kernel_main` now calls `virtio_blk_init()` right after
  the trap vector is set up, reads sector 0 and prints it, then writes a
  test string back — same bring-up smoke test the tutorial uses in this
  chapter (this block is throwaway, meant to be replaced once ch.16's
  actual file system lands).
- `resources/disk.txt` (new): the backing disk image — plain text file
  QEMU treats as a raw block device. `scripts/launch.sh` now attaches it
  via `-drive ... -device virtio-blk-device,...`.

**C3-specific translation notes (not bugs, just syntax differences from
the tutorial's C that took a try to find):**
- `sizeof(SomeStruct)` in C3 is `SomeStructName::size`, not `.sizeof` —
  `.sizeof` errors as "no method found" since C3 parses it as a member
  lookup. `@sizeof(value)` (with `@`) is the separate form for an actual
  *value* expression, not a type name.
- `offsetof(struct, field)` isn't needed at all in C3 the way the tutorial
  uses it in C — `(uint)&blk_req.data` already gives the same address
  C's `blk_req_paddr + offsetof(virtio_blk_req, data)` computes, since
  `blk_req` is a real typed pointer at that physical address. Simpler than
  the C original.
- A page-aligned struct *member* (`used __attribute__((aligned(PAGE_SIZE)))`
  in the tutorial's C, required by the legacy virtio MMIO layout) is just
  `used @align(PAGE_SIZE)` in C3 — same effect, existing precedent for
  this attribute already in the c3c stdlib (e.g. `sha256.c3`).
- The block-form `asm { fence; }` (used successfully elsewhere this
  project for bare no-operand instructions like `wfi`) rejected `fence`
  specifically ("Unknown instruction for the current target"). Used the
  basic string form `asm("fence")` instead — no cross-statement register
  bridging involved here, so none of the hazards from the ch.14 session's
  `read_reg`/`write_reg` bugs apply.
- Volatile MMIO reads/writes and the `virtq_is_busy` poll use
  `mem::load(ptr, align, true)` / `mem::store(ptr, value, align, true)` —
  the c3 stdlib's own volatile-load/store macros — rather than a bare
  pointer dereference, to make sure the optimizer can't hoist/cache reads
  of memory the device writes asynchronously.

**Verified working** end-to-end in QEMU with the disk attached: boot log
shows `virtio-blk: capacity is 512 bytes` and `first sector: Hello from
disk!` (matching `resources/disk.txt`'s content exactly), then the
in-kernel write-back test was confirmed by inspecting the backing file
after a run — it now contained `hello from kernel!!!` null-padded to 32
bytes, proving both the read and write paths work. Reset `disk.txt` back
to its original content afterward. Rest of boot (process creation, shell
prompt) unaffected — no regressions.

**Next up (not started):** ch.16, the actual file system built on top of
this block driver (replacing the throwaway read/write test in
`kernel_main`), then ch.17 (outro / wrap-up). After that, the user asked
about eventually exploring a microkernel-style refactor (moving drivers/FS
out of kernel space into user-mode servers via IPC) as a deliberate
follow-up once the tutorial's monolithic design is complete.

**Files changed this session:** `src/kernel/virtio.c3` (new),
`src/kernel.c3`, `scripts/launch.sh`, `resources/disk.txt` (new).

---

## 2026-08-14 (3) — Real shell: command parsing, `hello`/`exit`

**Goal:** replace the raw echo-loop shell from the previous session with
the tutorial's actual ch.14 shell — a prompt, a command-line reader, and
`hello`/`exit` command handling — now that `getchar`/`putchar` syscalls are
proven working.

**What was added:**
- `user/user.c3`: two small freestanding helpers, since there's no libc on
  the user side (`--use-stdlib=no --link-libc=no`): `print(char*)` (loops
  `putchar` until NUL) and `strcmp(char*, char*)`. Kept intentionally
  minimal — no varargs `printf`, just what the shell needs.
- `user/shell.c3`: rewritten to the tutorial's loop — prints `> `, reads a
  line into a 128-byte buffer via `getchar()` (echoing each char, handling
  `\r` as end-of-line and a too-long line by restarting the prompt), then
  dispatches on `strcmp`: `hello` prints a greeting, `exit` calls
  `exit()`, anything else prints `unknown command: <line>`.

**One build snag:** `char[128] cmdline;` in `shell.c3` failed to link with
`undefined symbol: memset` — C3 zero-initializes local arrays by default,
and the user build has no libc/memset available (freestanding, matching
`user.c3`'s existing no-stdlib setup). Since the buffer is always
null-terminated by hand before use, zero-init isn't needed — fixed with
`char[128] cmdline @noinit;` to opt out of the implicit zeroing.

**Verified working** end-to-end via QEMU with `-serial stdio -monitor
none` and a piped command script (`xx\rhello\rfoo\rexit\r`): prompt shows,
unknown commands are echoed back correctly, `hello` prints the greeting,
`exit` terminates the shell process cleanly. No crashes, no regressions
from the syscall-path fixes earlier this session.

**Next up (not started):** ch.15 (virtio-blk disk I/O) and ch.16 (file
system) — the shell has no persistent storage or files yet.

**Files changed this session:** `user/user.c3`, `user/shell.c3`.

---

## 2026-08-14 (2) — Wiring up syscalls (tutorial ch.14), and three real compiler/codegen traps

**Goal:** implement `putchar`/`getchar` syscalls end-to-end (user
`syscall()` → `ecall` → kernel trap → SBI console), per tutorial ch.14, on
top of the now-booting `user_mode` branch from the previous session.

**What was added (straightforward part):**
- `user/user.c3`: `syscall(sysno, arg0, arg1, arg2)` using C3's block-form
  inline asm (`asm { mv $a0, arg0; ... ecall; mv result, $a0; }`) — this
  form binds C3 locals to physical registers and auto-infers clobbers,
  unlike the basic `asm("string")` form. `putchar`/`getchar` now call it for
  real instead of being stubs.
- `src/kernel/sbi.c3`: added `__getchar()` (legacy SBI eid=2), matching the
  existing `__putchar()` (eid=1) pattern.
- `src/entry.c3`: `handle_trap` now branches on `scause == SCAUSE_ECALL`
  (8) to a new `handle_syscall()`, dispatching `f.a3` (syscall number) to
  `SYS_PUTCHAR`/`SYS_GETCHAR`; `SYS_GETCHAR` polls `sbi::__getchar()` in a
  loop, calling `yield()` between polls since it's non-blocking.
- `user/shell.c3`: now a real getchar/putchar echo loop instead of an empty
  `for(;;)`, to exercise the path.

**Three real bugs found chasing this — all in the pre-existing low-level
asm helpers, none in the syscall logic itself:**

1. **`stvec` was never reliably set.** `write_reg`/the inline stvec setup
   in `kernel_main` used *two separate* `asm("...")` calls (`la t0,
   SYMBOL` then `csrw REG, t0`), trusting the compiler to keep `t0` live
   across them. Nothing enforces that — the optimizer is free to schedule
   other code between two independent `asm()` statements since each is an
   opaque, unrelated unit to it. This was silently broken (stvec pointing
   at garbage) the entire time; it was invisible because *no prior test
   had ever triggered a real trap* (the previous session's shell was a
   silent `for(;;)`; ch.14 is the first thing to actually execute `ecall`).
   When a trap finally fired with a broken vector, execution went
   somewhere undefined and eventually wandered back into `kernel_main`,
   reproducing the exact "reboot loop → out of memory" signature from the
   `.eh_frame` bug in the previous session, for a completely different
   reason. **Fix:** merged into one `asm(@sprintf(multi-line, ...))` call
   so the whole sequence is one opaque-but-atomic unit (`write_reg` in
   `src/entry.c3`).

2. **`read_reg` corrupted live caller state.** Same shape of bug: it read
   a CSR into `a0` via string asm, then a *separate* block-asm statement
   copied `a0` into the macro's return variable. `handle_trap(Trap_frame*
   f)` receives `f` in `a0` (standard calling convention) and, since the
   compiler can't see into the string-asm's clobbers, had no reason to
   move `f` out of `a0` before calling `read_reg()` three times in a row
   (for scause/stval/sepc) — each call silently overwrote `f` with the
   CSR value. By the third call, `f` == the value of `sepc` (a user-space
   address), so `handle_syscall(f)` dereferenced garbage and page-faulted.
   This is the same class of bug as #1, just hitting a live *variable*
   instead of a dead register — and again latent since nothing had
   previously called `read_reg` from a function with a live pointer
   parameter still needed afterward. **Fix:** rewrote `read_reg` to bridge
   through a dedicated global (`read_reg_tmp`) inside one atomic
   `asm(@sprintf(...))` call, same shape as the `write_sepc` helper added
   for advancing `sepc` past the `ecall`.

3. **Debug `io::printfn` calls deep in the trap-handling call chain caused
   real stack corruption.** While chasing bug #2, added multi-argument
   debug prints inside `yield()` and `handle_syscall()` (5+ struct-field
   args in one `printfn`). This didn't just add noise — at that call
   depth (`kernel_entry`'s raw 124-byte trap frame → `handle_trap` →
   `handle_syscall` → `yield()`, all sharing one process's 8KB kernel
   stack, `char[STACK_SIZE] stack` being the last field of `Process`), the
   extra stack pressure from formatting-heavy `printfn` calls blew past
   the 8KB budget and corrupted `Process` struct fields *before* `.stack`
   in memory (`pid`/`state`/`sp`/`page_table` — confirmed by dumping them
   and watching `idle_proc.state`/`procs[1].pid` read back as zero
   mid-session). Confirmed by testing at `-O0`: the corruption got *worse*
   with less optimization (bigger, unoptimized frames), which pointed
   straight at stack depth rather than a logic bug. **Fix:** none needed
   in the shipped code — just stripped the debug prints back out once the
   real bugs (#1, #2) were fixed. Lesson for next time: keep any debug
   instrumentation inside the trap-handling path (`kernel_entry` →
   `handle_trap` → `handle_syscall` → …) to single-argument prints, or
   move heavier tracing into codepaths outside a process's 8KB kernel
   stack budget.

**Testing gotcha (not a kernel bug):** `qemu-system-riscv32 ... -serial
mon:stdio` silently swallows/multiplexes piped or file-redirected stdin
differently than a real TTY — `getchar()` never saw any input through it.
Switching to `-serial stdio -monitor none` (dedicated, non-multiplexed
serial on stdio, no monitor) made piped/redirected input work exactly as
expected. Use this form for any non-interactive testing.

**End state:** `bash scripts/build.sh` builds clean. Booting with real
piped/redirected input (`-serial stdio -monitor none`) shows the shell
echoing typed characters back correctly via the real `getchar`/`putchar`
syscalls (a `hello world` test echoed as `ello world` — the leading char
lost to a boot-timing race in how QEMU delivers a pre-staged input file
before the guest UART is ready, not a kernel bug). No reboot loop, no
panic, over multiple runs.

**Next up (not started):** the shell is still just a raw echo loop.
Tutorial ch.14's actual shell (command line parsing, `hello`/`exit`
commands) needs `strcmp`/some `printf` on the user side, which the tiny
custom `user/user.c3` library doesn't have yet. After that: ch.15
(virtio-blk disk I/O) and ch.16 (file system).

**Files changed this session:** `user/user.c3`, `user/shell.c3`,
`src/kernel/sbi.c3`, `src/entry.c3`.

---

## 2026-08-14 — Getting `user_mode` branch building and booting again

**Starting state:** branch `user_mode` had uncommitted WIP for tutorial ch.12
("Application") and ch.13 ("User Mode") — a `user/` userland app, a
`scripts/build_user.sh` to embed it into the kernel image, and partial
changes to `src/process.c3` / `src/kernel.c3` to load and run it. The kernel
did not compile.

**Fixes applied, in order hit:**

1. `src/process.c3:97` — `*(--sp) = user_entry` used a function name as a
   value instead of a function pointer. Fixed to `(uint)&user_entry`.
2. `create_process` had the ch.13 signature (`image`, `image_size`) but the
   ch.12-era body — it never mapped the image into the process's address
   space. Added the page-by-page `mem::copy` + `map_page(..., PAGE_U|R|W|X)`
   loop at `USER_BASE`, per the tutorial.
3. `kernel::user_entry()` was a stub that called `panic::panic(...)`.
   Implemented it as the naked-asm trampoline that sets `sepc = USER_BASE`,
   `sstatus = SSTATUS_SPIE`, and executes `sret` to drop into U-mode. Note:
   C3's compile-time `asm(@sprintf(...))` only supports `%s` substitution,
   not `%d`, so the immediates are hardcoded in the asm text rather than
   interpolated from the `USER_BASE`/`SSTATUS_SPIE` constants.
4. `kernel_main` still called `create_process` with the old 1-arg signature
   and spun up kernel-side `proc_a`/`proc_b` demo processes instead of the
   embedded shell binary. Removed the demo code (`proc_a`, `proc_b`,
   `proc_a_entry`, `proc_b_entry`, `delay`); wired `create_process(null, 0)`
   for idle and `create_process(&_binary_shell_bin_start, (uint)&_binary_shell_bin_size)`
   for the shell process.
5. `scripts/build_user.sh` ran `llvm-objcopy -Ibinary` on the path
   `build/user/shell.bin`. objcopy derives the embedded symbol names from
   the *input path*, so this produced `_binary_build_user_shell_bin_start`
   instead of the expected `_binary_shell_bin_start`. Fixed by `cd`-ing into
   `build/user` before running objcopy so the symbol name is derived from
   just `shell.bin`.
6. First attempt at declaring the `_binary_shell_bin_*` symbols in
   `src/kernel.c3` copied the existing `char[] X @export("X")` pattern used
   for linker-script symbols like `__kernel_base`. That pattern actually
   *defines* a zero-size symbol in the C3 object file — fine when nothing
   else defines it (as with `__kernel_base`, which only exists as a linker
   script assignment), but it collided with the real data definition in
   `shell.bin.o`, causing a duplicate-symbol link error. Fixed by declaring
   them as `extern char[] X @cname("X")` instead (same pattern already used
   for `__stack_top` in `user/user.c3`).
7. **The subtle one.** After all of the above, the kernel booted but then
   appeared to "reboot" itself in a loop (`1: BSS cleared` through
   `Idle process started` repeating) until it panicked with "Out of memory".
   No trap/exception was ever logged by `handle_trap`, which ruled out a
   page fault. Root cause: `user/user.ld` didn't discard `.eh_frame`, so LLD
   placed that unwind-info section *before* `.text` at the `USER_BASE` load
   address. `start()` ended up at file offset `0x6c` inside `shell.bin`
   instead of offset `0`, but `user_entry`'s hardcoded `sepc = USER_BASE`
   jumps straight to offset `0`. The CPU executed `.eh_frame` bytes as
   garbage instructions — apparently without ever faulting — and eventually
   wandered back into kernel code space, re-entering `kernel_main` in a
   loop, which is what exhausted the 64MB free-RAM pool. Fixed by adding
   `/DISCARD/ { *(.eh_frame .eh_frame.*) }` to `user.ld`.

**End state:** `bash scripts/build.sh` builds cleanly. Booting
`build/kernel.elf` in QEMU (`qemu-system-riscv32 -machine virt -bios default
-nographic -serial mon:stdio -no-reboot -kernel build/kernel.elf`) runs the
full boot sequence exactly once, creates the idle and shell processes, drops
into U-mode at `USER_BASE`, and the shell process spins silently in its
`for(;;)` loop (its `putchar` is still a stub, so no output yet — that's
ch.14, syscalls). No crash, no reboot loop, confirmed stable over a 5s run.

**Next up (not started):** wire up a real syscall path (`putchar`/`getchar`
at minimum) so the shell can actually talk to the console — tutorial ch.14.

**Files changed this session:** `src/process.c3`, `src/kernel.c3`,
`scripts/build_user.sh`, `user/user.ld`.
