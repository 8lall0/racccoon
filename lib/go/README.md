# `lib/go/` — tamago-go toolchain patch for racccoon

`racccoon.patch` is applied to a **tamago-go** checkout (branch
`tamago1.27.0`, matching the host's Go 1.27.0) before `src/make.bash`.
`scripts/setup_tamago.sh` does the clone + apply + build; then
`scripts/build_go.sh` uses the result via `$TAMAGO`.

## What the patch does

Three things, all inert for a non-racccoon `GOOS=tamago` build (the
racccoon side is supplied by the GOOSPKG overlay in `go/goos/`).

**1. Filesystem.** `GOOS=tamago`'s `syscall` backs `package os` onto an
in-memory fs (`fs_tamago.go`). The patch adds an optional
`runtime/goos.FS` `FSHook`; when set (the overlay's `racccoon_fs.go`
installs it), every path-based syscall — `Open`, `Read`/`Write`/`Seek`,
`Stat`, `Mkdir`, `Unlink`, `Rename`, `ReadDirent`, `Getwd`, `Chdir` —
routes there instead. `FSHook` uses errno ints, not `error`
(`runtime/goos` can't import `errors`); `fs_racccoon.go` maps them to
`syscall.Errno`.

**2. `os.Args`.** `runtime/goos.Args` (`func() []string`, filled from
the host exec ABI); a tiny `os_tamago.go` `init()` refreshes
`runtime.argslice` from it before `os` reads `os.Args` (the runtime's
`goargs()` hardcodes `{"tamago"}` too early to use a provider).

**3. `os/exec`.** `syscall_tamago.go`'s `StartProcess` / `Wait4` /
`WaitStatus` stubs (labelled "not supported, just enough for package
os") get real bodies via `runtime/goos.Spawn` / `Wait` — racccoon's
`rfork(RFPROC)` + `SYS_EXEC` + `SYS_JOIN`. `WaitStatus` uses the
standard `wait(2)` bit layout (exit code in bits 8..15). First cut: the
child inherits the console (`cmd.Stdout = os.Stdout` works, pipe
capture doesn't); `/dev/null` is a reserved fs-backend handle.

Files touched:

- `src/runtime/goos/linux_user.go` — `FSHook` + `var FS` + `var Args` +
  `Spawn`/`Wait` stubs (kept in sync with `go/goos/racccoon_user.go`).
- `src/runtime/os_tamago.go` — the `init()` that refreshes `argslice`.
- `src/syscall/fs_racccoon.go` (new) — the `goosFile` `fileImpl`, the
  `goos.FS` call-site helpers + dirent synthesis, errno→`Errno`.
- `src/syscall/fs_tamago.go` — one `if goos.FS != nil { … }` guard per
  entry point.
- `src/syscall/syscall_tamago.go` — `Getwd` uses the hook;
  `StartProcess`/`Wait4`/`WaitStatus` real bodies.

## Bumping the Go version

Change `BRANCH` in `scripts/setup_tamago.sh` to match the new host Go,
re-run it, and regenerate this patch from the new tree if it doesn't
apply cleanly:

```
cd <tamago-go> && git stash && git checkout tamago1.XX.Y
# reapply the four edits by hand, then:
git diff > <racccoon>/lib/go/racccoon.patch
```
