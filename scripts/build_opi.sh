#!/bin/bash
#
# Build racccoon for the Orange Pi RV (StarFive JH7110) — see
# boards/opi-rv/board.c3 and docs/opi-rv-plan.md.
#
# Produces build/kernel_opi.elf (+ build/kernel_opi.bin, a raw copy).
# There is no firmware-packaging step like the Duo's fiptool chain: the
# bring-up path is to keep the vendor's SD image (SPL + OpenSBI + U-Boot)
# and load racccoon from U-Boot:
#
#   load mmc 1:1 0x40200000 kernel_opi.elf
#   bootelf 0x40200000
#
# `bootelf` honours the ELF entry point and jumps in S-mode with
# a0=hartid, a1=dtb — racccoon ignores both. `go 0x40200000` also works
# against kernel_opi.bin since .text.boot is first and load addr ==
# link addr.
#
# OPI_TEST_SHELL=1 embeds shell_test.c3 (the *killtest / wasmtest / etc.
# dev builtins) instead of the production shell — same trick as
# scripts/build_duo.sh.

set -e

if [ -x /opt/riscv/bin/ld.lld ]; then
  LLVM_LLD=${LLVM_LLD:-/opt/riscv/bin/ld.lld}
else
  LLVM_LLD=${LLVM_LLD:-ld.lld}
fi
LLC=${LLC:-llc}
LLVM_OBJCOPY=${LLVM_OBJCOPY:-llvm-objcopy}

(
  cd "$(dirname "$0")/.."

  # User-mode binaries have no board dependency (see build_duo.sh's own
  # comment — every board:: reference in user/ is in a comment; the
  # real board facts reach user code by syscall).
  bash scripts/build_user.sh

  echo "==> Compiling kernel to LLVM IR (racccoon-opi target)..."
  rm -rf build/obj build/llvm build/obj_medany build/kernel_opi.*
  c3c build racccoon-opi --no-entry --safe=no --riscv-cpu=rvimac --riscv-abi=double --emit-llvm

  # Same medium (medany) code-model workaround as scripts/build.sh /
  # build_duo.sh — c3c has no --mcmodel, so recompile the IR through llc.
  # The JH7110 load address (0x40200000) is actually within medlow's
  # +/-2GiB-of-zero reach, unlike QEMU/Duo — but the toolchain is set up
  # for medany and reusing the exact same objects the other boards build
  # keeps one pipeline, so do it anyway.
  echo "==> Recompiling IR with the medium (medany) code model..."
  mkdir -p build/obj_medany
  for f in build/llvm/elf-riscv64/*.ll; do
    name=$(basename "$f" .ll)
    $LLC -mtriple=riscv64-unknown-elf -mattr=+m,+a,+c,+f,+d \
      -code-model=medium -relocation-model=static \
      -filetype=obj -o "build/obj_medany/$name.o" "$f"
  done

  SHELL_OBJ=build/user/shell.bin.o
  if [ "${OPI_TEST_SHELL:-0}" = "1" ]; then
    echo "==> OPI_TEST_SHELL=1 — embedding shell_test.c3 as the shell"
    mkdir -p build/user_opi_shell
    cp build/user/shell_test.bin build/user_opi_shell/shell.bin
    (
      cd build/user_opi_shell
      cat > shell.bin.s <<'STUB'
	.section .rodata._binary_shell_bin, "a"
	.balign 8
	.globl _binary_shell_bin_start
_binary_shell_bin_start:
	.incbin "shell.bin"
	.globl _binary_shell_bin_end
_binary_shell_bin_end:
STUB
      "${LLVM_MC:-llvm-mc}" --triple=riscv64 --mattr=+m,+a,+c,+f,+d --target-abi=lp64d \
        --filetype=obj -o shell.bin.o shell.bin.s
    )
    SHELL_OBJ=build/user_opi_shell/shell.bin.o
  fi

  # diskd/sdd/usbd/ethd/netd/gpiod are all linked in on every target even
  # though board::HAS_* gates most of them from ever spawning on this one
  # — kernel.c3 references every embedded-binary symbol unconditionally.
  # Same as build_duo.sh.
  echo "==> Linking kernel_opi.elf (with embedded shell)..."
  $LLVM_LLD \
    build/obj_medany/*.o \
    "$SHELL_OBJ" \
    build/user/echod.bin.o \
    build/user/diskd.bin.o \
    build/user/sdd.bin.o \
    build/user/fsd.bin.o \
    build/user/procd.bin.o \
    build/user/envd.bin.o \
    build/user/usbd.bin.o \
    build/user/ethd.bin.o \
    build/user/netd.bin.o \
    build/user/gpiod.bin.o \
    -T boards/opi-rv/kernel.ld \
    -Map=build/kernel_opi.map \
    -o build/kernel_opi.elf

  $LLVM_OBJCOPY -O binary build/kernel_opi.elf build/kernel_opi.bin

  echo "==> Done: build/kernel_opi.elf + build/kernel_opi.bin"
  echo "    Load from the vendor U-Boot: load mmc 1:1 0x40200000 kernel_opi.elf ; bootelf 0x40200000"
)
