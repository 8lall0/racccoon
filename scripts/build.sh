#!/bin/bash

set -e

LLVM_LLD=${LLVM_LLD:-/opt/riscv/bin/ld.lld}

(
  cd "$(dirname "$0")/.."

  # Build user app first (produces build/user/shell.bin.o)
  bash scripts/build_user.sh

  echo "==> Building disk image..."
  (cd disk && tar cf ../build/disk.tar --format=ustar *.txt)

  echo "==> Compiling kernel..."
  rm -rf build/obj build/llvm build/kernel.*
  c3c build --no-entry --safe=no --riscv-cpu=rvimac --emit-llvm

  echo "==> Linking kernel.elf (with embedded shell)..."
  $LLVM_LLD \
    build/obj/elf-riscv32/*.o \
    build/user/shell.bin.o \
    build/user/echod.bin.o \
    -T src/kernel.ld \
    -L /opt/riscv/lib/linux \
    -lclang_rt.builtins-riscv32 \
    -Map=build/kernel.map \
    -o build/kernel.elf

  echo "==> Done: build/kernel.elf"
)
