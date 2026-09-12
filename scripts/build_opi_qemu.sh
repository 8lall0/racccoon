#!/bin/bash
#
# Build the Orange Pi RV *verification harness* for QEMU `-machine
# sifive_u` — see boards/opi-rv-qemu/board.c3's header for why this
# exists (a pre-hardware proxy for the JH7110's monitor-hart-0 +
# application-hart-1 split and its PLIC S-context 2, neither of which
# QEMU `virt` exercises).
#
# Produces build/kernel_opi_qemu.elf. Run it with scripts/launch_opi_qemu.sh
# (QEMU's own `-kernel`, no U-Boot). This ELF links at DRAM base
# 0x80000000 (sifive_u), NOT the real board's 0x40000000, so it is
# deliberately NOT loadable on hardware — use scripts/build_opi.sh for
# that.
#
# OPI_TEST_SHELL=1 embeds shell_test.c3 (the killtest / faulttest / etc.
# dev builtins) instead of the production shell — same trick as
# scripts/build_opi.sh. That is how Stage 2 (traps under load, faulttest,
# supervisor respawn) gets exercised here.

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

  bash scripts/build_user.sh

  echo "==> Compiling kernel to LLVM IR (racccoon-opi-qemu target)..."
  rm -rf build/obj build/llvm build/obj_medany build/kernel_opi_qemu.*
  c3c build racccoon-opi-qemu --no-entry --safe=no --riscv-cpu=rvimac --riscv-abi=double --emit-llvm

  # Same medium (medany) code-model workaround as every other board build
  # — c3c has no --mcmodel, so recompile the IR through llc. 0x80200000 is
  # just outside medlow's +/-2GiB-of-zero reach, so medany is genuinely
  # needed here (unlike the real opi build).
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
    mkdir -p build/user_opi_qemu_shell
    cp build/user/shell_test.bin build/user_opi_qemu_shell/shell.bin
    (
      cd build/user_opi_qemu_shell
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
    SHELL_OBJ=build/user_opi_qemu_shell/shell.bin.o
  fi

  # Every server binary is linked in on every target even though
  # board::HAS_* gates most from spawning — kernel.c3 references each
  # embedded-binary symbol unconditionally. Same as scripts/build_opi.sh.
  echo "==> Linking kernel_opi_qemu.elf (with embedded shell)..."
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
    -T boards/opi-rv-qemu/kernel.ld \
    -Map=build/kernel_opi_qemu.map \
    -o build/kernel_opi_qemu.elf

  echo "==> Done: build/kernel_opi_qemu.elf"
  echo "    Run it: scripts/launch_opi_qemu.sh"
)
