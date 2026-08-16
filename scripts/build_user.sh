#!/bin/bash

set -e

LLVM_OBJCOPY=${LLVM_OBJCOPY:-llvm-objcopy}
LLVM_LLD=${LLVM_LLD:-/opt/riscv/bin/ld.lld}

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

build_user_program shell user/user.c3 user/shell.c3
build_user_program echod user/user.c3 user/echod.c3
build_user_program diskd user/user.c3 user/diskd.c3
build_user_program sdd user/user.c3 user/sdd.c3
build_user_program fsd user/user.c3 user/fsd.c3
