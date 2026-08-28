# Racccoon

Racccoon (yes, with three `c`s — for [C3](https://c3-lang.org/)) is a small
microkernel for 64-bit RISC-V (`rv64imac`, integer-only — floating point is
stubbed), written entirely in C3 with no libc.

It began as a walk through [OS in 1,000 Lines](https://operating-system-in-1000-lines.vercel.app/en/)
as an experiment in how far C3 can be pushed for kernel and bare-metal work.
It has since grown well past 1,000 lines and past the tutorial: a preemptive
microkernel with user-space drivers, a Plan 9-style IPC and namespace layer,
three filesystems, a USB host stack, and a port to real hardware.

## Targets

| Target | Machine | Notes |
| --- | --- | --- |
| `racccoon` | QEMU `virt` | virtio-mmio block / net |
| `racccoon-duo` | [Milk-V Duo](https://milkv.io/duo) | Sophgo CV1800B, single T-HEAD C906 core; boots as S-mode payload under the stock OpenSBI |

Sv39 paging, one hart. The second C906 core on the Duo (no MMU) is not a target.

## What works

- **Scheduler** — preemptive, timer-interrupt driven, round-robin.
- **Processes** — `rfork` (`RFPROC` = process, `RFMEM` = shared address space =
  thread), `exec` (ELF64 or flat binary), `exit`, `join`, `kill`, `setuid`,
  futexes.
- **IPC & namespaces** — synchronous message rendezvous, a 9P-style verb
  protocol (`attach`/`walk`/`open`/`read`/`write`/`clunk`), per-process mount
  tables, `post` + `mount` server binding, `/proc`, `/srv`, `/env`.
- **Filesystems** — FAT32, ext2, and exFAT, all read **and** write (create,
  delete, rename, mkdir, offset-aware read/write, stat), served by the
  user-space `fsd`. Plan 9 topology: ext2 is the root, FAT32 is the boot
  partition, other mounts live under `/mnt/`.
- **Block storage** — virtio-blk on QEMU, SDHCI + SDMA on the Duo, both
  interrupt-driven.
- **USB** (Duo) — DWC2 host controller, interrupt-driven transfer completion,
  hubs with USB 2.0 split transactions, mass storage, and HID: a USB keyboard
  types straight into the shell; mouse reports decode; Xbox-style gamepads
  enumerate and take rumble/LED commands (input reports are still flaky on some
  clones).
- **Networking** — virtio-net on QEMU, DesignWare MAC + on-chip PHY on the Duo,
  with a hand-rolled ARP / ICMP-echo / DHCP client.
- **GPIO** (Duo) — the on-board LED, via a user-space `gpiod`.
- A tiny shell with the usual builtins plus `/bin` binaries loaded through
  `exec`.

Everything except the kernel core (traps, scheduling, paging, IPC) runs as an
ordinary user process.

## Building & running

Needs `c3c`, an LLVM toolchain (`llc`, `ld.lld`, `llvm-objcopy`),
`qemu-system-riscv64`, and image tools (`dosfstools`, `mtools`, `e2fsprogs`,
`exfatprogs`).

```sh
# QEMU
scripts/build.sh                 # kernel + user programs + disk images
scripts/launch64.sh              # boot (FAT32 root)
scripts/launch64_ext2.sh         # ext2 root
scripts/launch64_dual.sh         # two partitions (FAT32 boot + ext2 root)
scripts/launch64_exfat.sh        # exFAT

# Milk-V Duo — repackages the fip.bin already on the SD card, keeping its
# FSBL/OpenSBI, and swaps in the new kernel. No sudo, no vendor SDK build.
DUO_SD_PART=/dev/sdX1 scripts/reflash_duo.sh
```

If your LLVM tools aren't on `PATH` under `/opt/riscv`, pass them explicitly:
`LLVM_LLD=/usr/bin/ld.lld LLC=llc LLVM_OBJCOPY=llvm-objcopy scripts/build.sh`.

The build recompiles C3's LLVM IR through `llc -code-model=medium` because c3c
has no `--mcmodel` flag and the default `small` model can't reach the kernel's
link address on RV64.

## Layout

```
src/          kernel — traps & syscalls (entry.c3), scheduling & processes
              (process.c3), paging (page.c3), allocator, console/SBI
boards/       per-board constants & PLIC setup (qemu/, duo/)
user/         everything that runs in user mode:
  user.c3       the shared user runtime (syscall wrappers, print, mmio, ...)
  fs/           fsd + the FAT32 / ext2 / exFAT backends
  usb/          usbd + dwc2, hub, HID (kbd/xpad), MSC
  net/          netd (virtio) / ethd (dwmac) + eth_proto + dhcp
  block/        diskd (virtio) / sdd (SDHCI)
  sys/          procd, envd, echod
  bin/          standalone /bin programs (ls, cat, ...)
scripts/      build & launch & flash
docs/         devlog.md — a running log of every work session
```

## Status

An active experiment, not a product. Interfaces change freely, there is no
stable ABI, and "it boots on my Duo" is the bar for the hardware paths. The
[devlog](docs/devlog.md) is the real record of what was done and why.

MIT licensed.
