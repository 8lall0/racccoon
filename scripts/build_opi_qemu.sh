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

. "$(dirname "$0")/lib_kernel.sh"

(
  cd "$(dirname "$0")/.."

  bash scripts/build_user.sh

  kernel_compile racccoon-opi-qemu kernel_opi_qemu

  SHELL_OBJ=build/user/shell.bin.o
  if [ "${OPI_TEST_SHELL:-0}" = "1" ]; then
    echo "==> OPI_TEST_SHELL=1 — embedding shell_test.c3 as the shell"
    SHELL_OBJ=$(kernel_test_shell_obj user_opi_qemu_shell)
  fi

  kernel_link "$SHELL_OBJ" boards/opi-rv-qemu/kernel.ld kernel_opi_qemu

  echo "==> Done: build/kernel_opi_qemu.elf"
  echo "    Run it: scripts/launch_opi_qemu.sh"
)
