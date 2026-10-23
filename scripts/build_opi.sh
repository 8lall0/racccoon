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
#   load mmc 1:1 0x40200000 kernel_opi.bin
#   go 0x40200000
#
# (mmc 1 is the microSD; mmc 0 is the Wi-Fi's SDIO. Use the raw .bin + `go`:
# `bootelf` on the ELF crashes this vendor U-Boot.) .text.boot is first and
# load addr == link addr, so `go` on the .bin lands on boot(). scripts/
# flash_opi.sh installs it on the card and wires it into the vendor boot
# chain via vf2_uEnv.txt so the board starts it unattended.
#
# OPI_TEST_SHELL=1 embeds shell_test.c3 (the *killtest / wasmtest / etc.
# dev builtins) instead of the production shell — same trick as
# scripts/build_duo.sh.

set -e

. "$(dirname "$0")/lib_kernel.sh"

(
  cd "$(dirname "$0")/.."

  # User-mode binaries have no board dependency (see build_duo.sh's own
  # comment — every board:: reference in user/ is in a comment; the
  # real board facts reach user code by syscall).
  SDD_SOC_SRC=user/block/dw_mshc.c3 GPIO_SOC_SRC=user/gpio/gpio_jh7110.c3 bash scripts/build_user.sh

  kernel_compile racccoon-opi kernel_opi

  SHELL_OBJ=build/user/shell.bin.o
  if [ "${OPI_TEST_SHELL:-0}" = "1" ]; then
    echo "==> OPI_TEST_SHELL=1 — embedding shell_test.c3 as the shell"
    SHELL_OBJ=$(kernel_test_shell_obj user_opi_shell)
  fi

  kernel_link "$SHELL_OBJ" boards/opi-rv/kernel.ld kernel_opi

  $LLVM_OBJCOPY -O binary build/kernel_opi.elf build/kernel_opi.bin

  echo "==> Done: build/kernel_opi.elf + build/kernel_opi.bin"
  echo "    Install on the card: OPI_BOOT_PART=/dev/sdX1 bash scripts/flash_opi.sh"
)
