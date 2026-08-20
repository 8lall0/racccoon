#!/bin/bash

set -e

LLVM_OBJCOPY=${LLVM_OBJCOPY:-llvm-objcopy}
LLVM_LLD=${LLVM_LLD:-/opt/riscv/bin/ld.lld}

# std::nolibc::{mem,atomic,fmt} — the freestanding pieces every user-
# mode binary needs, adapted from the real c3 stdlib (mem/atomic) or
# original (fmt) — see docs/devlog.md. Used to live as vendored copies
# under user/ (one per project needing them); now sourced from the
# 8lall0/c3c fork's own stdlib tree (lib/std/_nolibc/), where any
# project can `import std::nolibc::mem;` etc. Passed as plain source
# file arguments (same as user/user.c3 always has been) rather than
# requiring --use-stdlib=yes: that flag pulls in far more of the real
# stdlib (std::io, libc.os, ...) than this freestanding link step can
# handle — confirmed by testing, not assumed. Gated `@feat(RACCCOON)`
# in those files themselves, not the ambient NO_LIBC every freestanding
# build already sets — -D RACCCOON below is what actually turns them
# on, so they stay dormant for any other project built against the
# same fork that hasn't explicitly opted in.
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
    --no-entry \
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

build_user_program shell user/user.c3 $RACCCOON_STD_DIR/atomic.c3 $RACCCOON_STD_DIR/mem.c3 $RACCCOON_STD_DIR/fmt.c3 user/shell.c3
build_user_program echod user/user.c3 $RACCCOON_STD_DIR/atomic.c3 $RACCCOON_STD_DIR/mem.c3 $RACCCOON_STD_DIR/fmt.c3 user/echod.c3
build_user_program diskd user/user.c3 $RACCCOON_STD_DIR/atomic.c3 $RACCCOON_STD_DIR/mem.c3 $RACCCOON_STD_DIR/fmt.c3 user/diskd.c3
build_user_program sdd user/user.c3 $RACCCOON_STD_DIR/atomic.c3 $RACCCOON_STD_DIR/mem.c3 $RACCCOON_STD_DIR/fmt.c3 user/sdd.c3
build_user_program fsd user/user.c3 $RACCCOON_STD_DIR/atomic.c3 $RACCCOON_STD_DIR/mem.c3 $RACCCOON_STD_DIR/fmt.c3 user/fsd.c3 user/fs/fat32.c3 user/fs/ext2.c3
build_user_program procd user/user.c3 $RACCCOON_STD_DIR/atomic.c3 $RACCCOON_STD_DIR/mem.c3 $RACCCOON_STD_DIR/fmt.c3 user/procd.c3
build_user_program envd user/user.c3 $RACCCOON_STD_DIR/atomic.c3 $RACCCOON_STD_DIR/mem.c3 $RACCCOON_STD_DIR/fmt.c3 user/envd.c3
