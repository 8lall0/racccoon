#!/bin/bash

set -e

LLVM_LLD=${LLVM_LLD:-/opt/riscv/bin/ld.lld}
LLC=${LLC:-llc}

(
  cd "$(dirname "$0")/.."

  # Same user-mode binaries as the QEMU build — user-mode code has no
  # board dependency at all (USER_BASE is well under 2GiB regardless of
  # target, and none of shell/echod/diskd/sdd/fsd touch PLIC/console
  # directly, only through kernel syscalls). diskd and sdd both still get
  # built and linked in on every target even though only one of them ever
  # actually runs on a given board (board::HAS_SD_BLOCK/HAS_VIRTIO_BLOCK
  # picks which — see src/kernel.c3) — kernel.c3 references both
  # embedded-binary symbols unconditionally, each inside an `if` that
  # only runs on one board, so the linker needs both present regardless.
  bash scripts/build_user.sh

  echo "==> Compiling kernel to LLVM IR (racccoon-duo target)..."
  rm -rf build/obj build/llvm build/obj_medany build/kernel_duo.*
  c3c build racccoon-duo --no-entry --safe=no --riscv-cpu=rvimac --emit-llvm

  # Same medium (medany) code-model workaround as scripts/build.sh — see
  # that script's own comment and docs/devlog.md for the full story.
  # The Duo's load address is just as far past the 2GiB medlow ceiling
  # as QEMU's, so this applies here too, unchanged.
  echo "==> Recompiling IR with the medium (medany) code model..."
  mkdir -p build/obj_medany
  for f in build/llvm/elf-riscv64/*.ll; do
    name=$(basename "$f" .ll)
    $LLC -mtriple=riscv64-unknown-elf -mattr=+m,+a,+c \
      -code-model=medium -relocation-model=static \
      -filetype=obj -o "build/obj_medany/$name.o" "$f"
  done

  echo "==> Linking kernel_duo.elf (with embedded shell)..."
  $LLVM_LLD \
    build/obj_medany/*.o \
    build/user/shell.bin.o \
    build/user/echod.bin.o \
    build/user/diskd.bin.o \
    build/user/sdd.bin.o \
    build/user/fsd.bin.o \
    build/user/procd.bin.o \
    build/user/envd.bin.o \
    build/user/usbd.bin.o \
    -T boards/duo/kernel.ld \
    -Map=build/kernel_duo.map \
    -o build/kernel_duo.elf

  # NOT yet a flashable image: build/kernel_duo.elf still needs the
  # 32-byte LOADER_2ND ("BL33") header prepended and packaging through
  # duo-buildroot-sdk's fiptool.py into a fip.bin — see
  # boards/duo/kernel.ld's own comment and
  # ~/.claude/plans/giggly-prancing-iverson.md for what's still needed
  # (Stage 0.1/0.2), not yet automated here.
  echo "==> Done: build/kernel_duo.elf (not yet fiptool-packaged)"
)
