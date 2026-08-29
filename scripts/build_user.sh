#!/bin/bash

set -e

LLVM_OBJCOPY=${LLVM_OBJCOPY:-llvm-objcopy}
LLVM_LLD=${LLVM_LLD:-/opt/riscv/bin/ld.lld}

# std::nolibc::{mem,atomic,fmt,main_stub} — the freestanding pieces
# every user-mode binary needs, adapted from the real c3 stdlib
# (mem/atomic/main_stub) or original (fmt) — see docs/devlog.md. Used
# to live as vendored copies under user/ (one per project needing
# them); now sourced from the 8lall0/c3c fork's own stdlib tree
# (lib/std/_nolibc/), where any project can `import std::nolibc::mem;`
# etc. Passed as plain source file arguments (same as user/user.c3
# always has been) rather than requiring --use-stdlib=yes: that flag
# pulls in far more of the real stdlib (std::io, libc.os, ...) than
# this freestanding link step can handle — confirmed by testing, not
# assumed. Gated `@feat(RACCCOON)` in those files themselves, not the
# ambient NO_LIBC every freestanding build already sets — -D RACCCOON
# below is what actually turns them on, so they stay dormant for any
# other project built against the same fork that hasn't explicitly
# opted in.
#
# main_stub.c3 provides `@main_no_args`, the forwarding macro the
# compiler's own standard main-detection looks up by name for a plain
# `fn void main()` — every main-providing file below `import
# std::nolibc::main_stub;` for it, which is what lets these binaries
# use ordinary `fn void main()` with no `@export("main")` boilerplate
# and no --no-entry: the compiler generates and exports the real,
# unmangled `main` entry point itself, the same as any hosted c3
# program (see docs/devlog.md).
RACCCOON_STD_DIR=${RACCCOON_STD_DIR:-/home/blallo/Workspace/c3c/lib/std/_nolibc}

ROOT="$(dirname "$0")/.."
cd "$ROOT"

# Builds one user-mode program from user/user.c3 (the shared library:
# syscall wrappers, start()/exit()) plus its own main-providing source
# file(s), producing build/user/<name>.bin.o ready to embed in the kernel
# image. Every program links at the same USER_BASE (user/user.ld) — that's
# fine, each one only ever exists in its own process's own page table.
build_user_program() {
  local name="$1"
  shift
  local sources=("$@")

  mkdir -p "build/user/$name/obj"

  echo "==> Compiling $name..."
  c3c compile-only \
    --safe=no \
    --use-stdlib=no \
    --link-libc=no \
    -D RACCCOON \
    --target elf-riscv64 \
    --riscv-cpu=rvimac \
    --output-dir "build/user/$name/obj" \
    "${sources[@]}"

  local obj_dir="build/user/$name/obj/obj/elf-riscv64"

  # RV64 port: no libclang_rt.builtins-riscv64 available or needed — see
  # build.sh's matching comment.
  echo "==> Linking $name.elf..."
  $LLVM_LLD \
    "$obj_dir"/*.o \
    -T user/user.ld \
    -Map="build/user/$name.map" \
    -o "build/user/$name.elf"

  echo "==> Converting ELF -> raw binary..."
  $LLVM_OBJCOPY \
    --set-section-flags .bss=alloc,contents \
    -O binary \
    "build/user/$name.elf" \
    "build/user/$name.bin"

  echo "==> Embedding binary as linkable object..."
  (
    cd build/user
    $LLVM_OBJCOPY \
      -Ibinary \
      -Oelf64-littleriscv \
      "$name.bin" \
      "$name.bin.o"
  )

  echo "==> Done: build/user/$name.bin.o"
}

build_user_program shell user/user.c3 $RACCCOON_STD_DIR/atomic.c3 $RACCCOON_STD_DIR/mem.c3 $RACCCOON_STD_DIR/fmt.c3 $RACCCOON_STD_DIR/main_stub.c3 user/shell_common.c3 user/shell.c3
build_user_program shell_test user/user.c3 $RACCCOON_STD_DIR/atomic.c3 $RACCCOON_STD_DIR/mem.c3 $RACCCOON_STD_DIR/fmt.c3 $RACCCOON_STD_DIR/main_stub.c3 user/shell_common.c3 user/shell_test.c3
build_user_program echod user/user.c3 $RACCCOON_STD_DIR/atomic.c3 $RACCCOON_STD_DIR/mem.c3 $RACCCOON_STD_DIR/fmt.c3 $RACCCOON_STD_DIR/main_stub.c3 user/sys/echod.c3
build_user_program cat user/user.c3 $RACCCOON_STD_DIR/atomic.c3 $RACCCOON_STD_DIR/mem.c3 $RACCCOON_STD_DIR/fmt.c3 $RACCCOON_STD_DIR/main_stub.c3 user/bin/cat.c3
build_user_program ls user/user.c3 $RACCCOON_STD_DIR/atomic.c3 $RACCCOON_STD_DIR/mem.c3 $RACCCOON_STD_DIR/fmt.c3 $RACCCOON_STD_DIR/main_stub.c3 user/bin/ls.c3
build_user_program echo user/user.c3 $RACCCOON_STD_DIR/atomic.c3 $RACCCOON_STD_DIR/mem.c3 $RACCCOON_STD_DIR/fmt.c3 $RACCCOON_STD_DIR/main_stub.c3 user/bin/echo.c3
build_user_program true user/user.c3 $RACCCOON_STD_DIR/atomic.c3 $RACCCOON_STD_DIR/mem.c3 $RACCCOON_STD_DIR/fmt.c3 $RACCCOON_STD_DIR/main_stub.c3 user/bin/true.c3
build_user_program false user/user.c3 $RACCCOON_STD_DIR/atomic.c3 $RACCCOON_STD_DIR/mem.c3 $RACCCOON_STD_DIR/fmt.c3 $RACCCOON_STD_DIR/main_stub.c3 user/bin/false.c3
build_user_program whoami user/user.c3 $RACCCOON_STD_DIR/atomic.c3 $RACCCOON_STD_DIR/mem.c3 $RACCCOON_STD_DIR/fmt.c3 $RACCCOON_STD_DIR/main_stub.c3 user/bin/whoami.c3
build_user_program write user/user.c3 $RACCCOON_STD_DIR/atomic.c3 $RACCCOON_STD_DIR/mem.c3 $RACCCOON_STD_DIR/fmt.c3 $RACCCOON_STD_DIR/main_stub.c3 user/bin/write.c3
build_user_program rm user/user.c3 $RACCCOON_STD_DIR/atomic.c3 $RACCCOON_STD_DIR/mem.c3 $RACCCOON_STD_DIR/fmt.c3 $RACCCOON_STD_DIR/main_stub.c3 user/bin/rm.c3
build_user_program mkdir user/user.c3 $RACCCOON_STD_DIR/atomic.c3 $RACCCOON_STD_DIR/mem.c3 $RACCCOON_STD_DIR/fmt.c3 $RACCCOON_STD_DIR/main_stub.c3 user/bin/mkdir.c3
build_user_program mv user/user.c3 $RACCCOON_STD_DIR/atomic.c3 $RACCCOON_STD_DIR/mem.c3 $RACCCOON_STD_DIR/fmt.c3 $RACCCOON_STD_DIR/main_stub.c3 user/bin/mv.c3
build_user_program usbrw user/user.c3 $RACCCOON_STD_DIR/atomic.c3 $RACCCOON_STD_DIR/mem.c3 $RACCCOON_STD_DIR/fmt.c3 $RACCCOON_STD_DIR/main_stub.c3 user/bin/usbrw.c3
build_user_program gpio user/user.c3 $RACCCOON_STD_DIR/atomic.c3 $RACCCOON_STD_DIR/mem.c3 $RACCCOON_STD_DIR/fmt.c3 $RACCCOON_STD_DIR/main_stub.c3 user/bin/gpio.c3
build_user_program diskd user/user.c3 $RACCCOON_STD_DIR/atomic.c3 $RACCCOON_STD_DIR/mem.c3 $RACCCOON_STD_DIR/fmt.c3 $RACCCOON_STD_DIR/main_stub.c3 user/virtio.c3 user/block/diskd.c3
build_user_program sdd user/user.c3 $RACCCOON_STD_DIR/atomic.c3 $RACCCOON_STD_DIR/mem.c3 $RACCCOON_STD_DIR/fmt.c3 $RACCCOON_STD_DIR/main_stub.c3 user/block/sdhci.c3 user/block/sdd.c3
build_user_program fsd user/user.c3 $RACCCOON_STD_DIR/atomic.c3 $RACCCOON_STD_DIR/mem.c3 $RACCCOON_STD_DIR/fmt.c3 $RACCCOON_STD_DIR/main_stub.c3 user/fs/fsd.c3 user/fs/fat32.c3 user/fs/ext2.c3 user/fs/exfat.c3
build_user_program procd user/user.c3 $RACCCOON_STD_DIR/atomic.c3 $RACCCOON_STD_DIR/mem.c3 $RACCCOON_STD_DIR/fmt.c3 $RACCCOON_STD_DIR/main_stub.c3 user/sys/procd.c3
build_user_program envd user/user.c3 $RACCCOON_STD_DIR/atomic.c3 $RACCCOON_STD_DIR/mem.c3 $RACCCOON_STD_DIR/fmt.c3 $RACCCOON_STD_DIR/main_stub.c3 user/sys/envd.c3
build_user_program usbd user/user.c3 $RACCCOON_STD_DIR/atomic.c3 $RACCCOON_STD_DIR/mem.c3 $RACCCOON_STD_DIR/fmt.c3 $RACCCOON_STD_DIR/main_stub.c3 user/usb/dwc2.c3 user/usb/xpad.c3 user/usb/kbd.c3 user/usb/msc.c3 user/usb/usbd.c3
build_user_program ethd user/user.c3 $RACCCOON_STD_DIR/atomic.c3 $RACCCOON_STD_DIR/mem.c3 $RACCCOON_STD_DIR/fmt.c3 $RACCCOON_STD_DIR/main_stub.c3 user/net/eth_proto.c3 user/net/dhcp.c3 user/net/dwmac.c3 user/net/ephy.c3 user/net/ethd.c3
build_user_program netd user/user.c3 $RACCCOON_STD_DIR/atomic.c3 $RACCCOON_STD_DIR/mem.c3 $RACCCOON_STD_DIR/fmt.c3 $RACCCOON_STD_DIR/main_stub.c3 user/virtio.c3 user/net/eth_proto.c3 user/net/dhcp.c3 user/net/netd.c3
build_user_program gpiod user/user.c3 $RACCCOON_STD_DIR/atomic.c3 $RACCCOON_STD_DIR/mem.c3 $RACCCOON_STD_DIR/fmt.c3 $RACCCOON_STD_DIR/main_stub.c3 user/gpio/gpiod.c3
