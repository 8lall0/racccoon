#!/bin/bash

set -e

LLVM_OBJCOPY=${LLVM_OBJCOPY:-llvm-objcopy}
LLVM_LLD=${LLVM_LLD:-/opt/riscv/bin/ld.lld}

ROOT="$(dirname "$0")/.."
cd "$ROOT"

mkdir -p build/user/obj

echo "==> Compiling user app..."
c3c compile-only \
  --no-entry \
  --use-stdlib=no \
  --link-libc=no \
  --target elf-riscv32 \
  --riscv-cpu=rvimac \
  --output-dir build/user/obj \
  user/user.c3 \
  user/shell.c3

OBJ_DIR="build/user/obj/obj/elf-riscv32"

echo "==> Linking shell.elf..."
$LLVM_LLD \
  "$OBJ_DIR"/*.o \
  -T user/user.ld \
  -Map=build/user/shell.map \
  -o build/user/shell.elf

echo "==> Converting ELF -> raw binary..."
$LLVM_OBJCOPY \
  --set-section-flags .bss=alloc,contents \
  -O binary \
  build/user/shell.elf \
  build/user/shell.bin

echo "==> Embedding binary as linkable object..."
(
  cd build/user
  $LLVM_OBJCOPY \
    -Ibinary \
    -Oelf32-littleriscv \
    shell.bin \
    shell.bin.o
)

echo "==> Done: build/user/shell.bin.o"