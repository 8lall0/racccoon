# `go/` — Go on racccoon (`GOOSPKG` provider)

**Stage 0 scaffold.** See `docs/go-port-plan.md` for the full plan.

This module (`racccoon.local/goport`) is the `runtime/goos`
implementation that lets a `GOOS=tamago GOARCH=riscv64` Go binary run as
a racccoon userspace process. It is a thin adaptation of tamago-go's own
`src/runtime/goos/linux_user*` — the same hooks, wired to racccoon's
`ecall` ABI instead of Linux's.

## Why tamago

The Go toolchain has no external dependency (unlike LLVM). The only hard
part is the runtime↔OS contract, and tamago
(`github.com/usbarmory/tamago-go`) already stripped the OS assumptions
for `GOOS=tamago`: single-threaded, no futex, no signals, no mmap, all
OS interaction behind a ~10-hook `runtime/goos` package pointed at an
out-of-tree module by `GOOSPKG`. racccoon is just another host for that
pattern.

## Layout

```
go/
  go.mod              module racccoon.local/goport
  goos/
    racccoon_user.go        the goos hooks (RamStart/RamSize/Bloc, Printk,
                            Exit, Idle, Nanotime, GetRandomData, …)
    racccoon_riscv64.s      CPUInit + the ecall stubs
```

## Building (once the toolchain exists)

```
git clone https://github.com/usbarmory/tamago-go -b tamago1.27.0
cd tamago-go/src && ./make.bash
export TAMAGO=$PWD/../bin/go
bash scripts/build_go.sh test/go-src/hello.go
```

## Stage 0 status / TODO

- `Nanotime` — stub; needs userspace `rdtime` or a `SYS_CLOCK` verb.
- `GetRandomData` — fixed bytes; JH7110 TRNG → `SYS_RANDOM` later.
- No `Task` — single-threaded (`GOMAXPROCS=1`), racccoon has no
  thread-creating rfork.
- Kernel: `EXEC_MAX_IMAGE_SIZE` must rise to ~4 MiB (a stripped Go
  hello is ~1 MiB) — JH7110/QEMU only, not the Duo.
- The exact `GOOSPKG` / `go.work` invocation is a Stage 1 line item.
