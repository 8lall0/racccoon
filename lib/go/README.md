# `lib/go/` — racccoon Go toolchain patch

`racccoon.patch` is applied to a **`usbarmory/tamago-go`** checkout
(branch `tamago1.27.0`, matching the host's Go 1.27.0) — *after*
`scripts/rename_goos.sh` renames its GOOS `tamago` → `racccoon` — and
before `src/make.bash`. `scripts/setup_go.sh` does clone + rename +
patch + build; then `scripts/build_go.sh` uses the result via
`$TAMAGO` (env var name kept for continuity; the toolchain is
`GOOS=racccoon` now).

## What the patch does

Three things, on top of the bare GOOS rename (the racccoon side of each
hook is supplied by the `GOOSPKG` overlay in `go/goos/`).

**1. Filesystem.** `racccoon`'s `syscall` (inherited from tamago) backs
`package os` onto an in-memory fs (`fs_racccoon.go`, renamed from
`fs_tamago.go` by `rename_goos.sh`).
The patch adds an optional `runtime/goos.FS` `FSHook`; when set (the
overlay's `racccoon_fs.go` installs it), every path-based syscall —
`Open`, `Read`/`Write`/`Seek`, `Stat`, `Mkdir`, `Unlink`, `Rename`,
`ReadDirent`, `Getwd`, `Chdir` — routes there instead. `FSHook` uses
errno ints, not `error` (`runtime/goos` can't import `errors`);
`fsgoos_racccoon.go` maps them to `syscall.Errno`.

**2. `os.Args`.** `runtime/goos.Args` (`func() []string`, filled from
the host exec ABI); a tiny `os_racccoon.go` `init()` refreshes
`runtime.argslice` from it before `os` reads `os.Args` (the runtime's
`goargs()` hardcodes `{"racccoon"}` too early to use a provider).

**3. `os/exec`.** `syscall_racccoon.go`'s `StartProcess` / `Wait4` /
`WaitStatus` stubs (labelled "not supported, just enough for package
os") get real bodies via `runtime/goos.Spawn` / `Wait` — racccoon's
`rfork(RFPROC)` + `SYS_EXEC` + `SYS_JOIN`. `WaitStatus` uses the
standard `wait(2)` bit layout (exit code in bits 8..15). `/dev/null`
is a reserved fs-backend handle.

**Output capture.** `os.Pipe()` (`os/pipe_racccoon.go`) calls a new
`syscall.PipeGoos`, which reserves a `runtime/goos` capture slot and
two `goosPipeFile` fds. `StartProcess` reads the slot id off the child's
stdout/stderr fd in `attr.Files` and passes it to `Spawn`, which points
the child's console at a kernel pipe **as part of `rfork` (a new `a2`
on `SYS_RFORK`)** — a follow-up `SYS_PIPE_SETOUT` loses the race to the
Go scheduler. `Spawn` drains the pipe to a byte slice; the read end
serves it to os/exec's `io.Copy` goroutine. racccoon has one console
stream per process, so `Cmd.Output` / `CombinedOutput` capture combined
stdout+stderr. `Cmd.Stdin` from a non-`*os.File` isn't wired.

Files touched:

- `src/runtime/goos/linux_user.go` — `FSHook` + `var FS` + `var Args` +
  `Spawn`/`Wait`/`Capture*` stubs (kept in sync with `go/goos/`).
- `src/runtime/os_racccoon.go` — the `init()` that refreshes `argslice`.
- `src/syscall/fsgoos_racccoon.go` (new) — the `goosFile` `fileImpl`, the
  `goos.FS` call-site helpers + dirent synthesis, errno→`Errno`, plus
  `goosPipeFile` + `PipeGoos` for output capture.
- `src/syscall/fs_racccoon.go` — one `if goos.FS != nil { … }` guard per
  entry point.
- `src/syscall/syscall_racccoon.go` — `Getwd` uses the hook;
  `StartProcess` (with `attr.Files` capID resolution) / `Wait4` /
  `WaitStatus` real bodies.
- `src/os/pipe_racccoon.go` — `os.Pipe()` via `syscall.PipeGoos`.

## Bumping the Go version

Change `BRANCH` in `scripts/setup_go.sh` to match the new host Go and
re-run it. If `rename_goos.sh` or the patch no longer applies cleanly,
adjust the failing step, then regenerate the patch from the renamed
tree:

```
cd <tamago-go>                     # after rename_goos.sh, before the patch
git apply <racccoon>/lib/go/racccoon.patch   # fix rejects by hand
git diff > <racccoon>/lib/go/racccoon.patch
```
