#!/bin/bash

set -e

LLVM_LLD=${LLVM_LLD:-/opt/riscv/bin/ld.lld}
LLC=${LLC:-llc}

(
  cd "$(dirname "$0")/.."

  # Build user app first (produces build/user/shell.bin.o)
  bash scripts/build_user.sh

  echo "==> Building disk image..."
  (cd disk && tar cf ../build/disk.tar --format=ustar *.txt)

  echo "==> Compiling kernel to LLVM IR..."
  rm -rf build/obj build/llvm build/obj_medany build/kernel.*
  c3c build --no-entry --safe=no --riscv-cpu=rvimac --emit-llvm

  # RV64 port: c3c's own object-file codegen only knows RISC-V's default
  # "small"/medlow code model, which requires every absolute address it
  # emits (every global variable, every string literal, every rodata
  # constant) to fit in the signed 32-bit range — i.e. below 2GiB. This
  # kernel boots at 0x80200000 (OpenSBI's fixed RV64 payload address,
  # just past the 2GiB line), so under medlow *every* such reference is
  # out of range; ld.lld catches this at link time
  # (R_RISCV_HI20 out of range). c3c has no --mcmodel flag to ask for
  # "medany" (PC-relative auipc-based addressing, valid across the full
  # 64-bit space) — the standard, correct code model for exactly this
  # situation, and what every real RV64 kernel (Linux, OpenSBI itself)
  # actually uses. So we take the one escape hatch --emit-llvm gives us:
  # recompile c3c's own LLVM IR ourselves via llc, this time asking for
  # -code-model=medium (LLVM's name for RISC-V's "medany"). See
  # docs/devlog.md for the full debugging story — this took a while to
  # pin down.
  echo "==> Recompiling IR with the medium (medany) code model..."
  mkdir -p build/obj_medany
  for f in build/llvm/elf-riscv64/*.ll; do
    name=$(basename "$f" .ll)
    $LLC -mtriple=riscv64-unknown-elf -mattr=+m,+a,+c \
      -code-model=medium -relocation-model=static \
      -filetype=obj -o "build/obj_medany/$name.o" "$f"
  done

  echo "==> Linking kernel.elf (with embedded shell)..."
  # No libclang_rt.builtins-riscv64 to link against (see
  # src/kernel/softfloat_stubs.c3's own comment for why that's fine).
  $LLVM_LLD \
    build/obj_medany/*.o \
    build/user/shell.bin.o \
    build/user/echod.bin.o \
    build/user/diskd.bin.o \
    build/user/fsd.bin.o \
    -T src/kernel.ld \
    -Map=build/kernel.map \
    -o build/kernel.elf

  echo "==> Done: build/kernel.elf"
)
