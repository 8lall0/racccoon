# `lib/go/` — tamago-go toolchain patch for racccoon

`racccoon.patch` is applied to a **tamago-go** checkout (branch
`tamago1.27.0`, matching the host's Go 1.27.0) before `src/make.bash`.
`scripts/setup_tamago.sh` does the clone + apply + build; then
`scripts/build_go.sh` uses the result via `$TAMAGO`.

## What the patch does

`GOOS=tamago`'s `syscall` package backs `package os` onto an in-memory
filesystem (`src/syscall/fs_tamago.go`). The patch adds an optional
`runtime/goos.FS` hook: when a `FSHook` is installed (the racccoon
tree's `go/racccoon` package does this in its `init`), every path-based
filesystem syscall — `Open`, `Read`/`Write`/`Seek`, `Stat`, `Mkdir`,
`Unlink`, `Rename`, `ReadDirent`, `Getwd`, `Chdir` — routes to that
backend instead. `nil` FS keeps stock tamago behaviour, so the patch is
inert for non-racccoon builds.

It also wires `os.Args`: `runtime/goos.Args` (a `func() []string` a
provider fills from the host exec ABI); a tiny `os_tamago.go` `init()`
refreshes `runtime.argslice` from it before package `os` reads
`os.Args` (the runtime's `goargs()` hardcodes `{"tamago"}` too early to
use a provider).

Files touched:

- `src/runtime/goos/linux_user.go` — the `FSHook` interface + `var FS`
  + `var Args` (kept in sync with `go/goos/racccoon_user.go`, the
  GOOSPKG overlay).
- `src/runtime/os_tamago.go` — the `init()` that refreshes `argslice`.
- `src/syscall/fs_racccoon.go` (new) — the `goosFile` `fileImpl` and the
  `goos.FS` call sites' helpers, incl. synthesising fixed-size dirent
  records for `os.ReadDir`.
- `src/syscall/fs_tamago.go` — one `if goos.FS != nil { … }` guard at
  the top of each entry point.
- `src/syscall/syscall_tamago.go` — `Getwd()` uses the hook.

## Bumping the Go version

Change `BRANCH` in `scripts/setup_tamago.sh` to match the new host Go,
re-run it, and regenerate this patch from the new tree if it doesn't
apply cleanly:

```
cd <tamago-go> && git stash && git checkout tamago1.XX.Y
# reapply the four edits by hand, then:
git diff > <racccoon>/lib/go/racccoon.patch
```
