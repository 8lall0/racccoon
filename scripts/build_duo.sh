#!/bin/bash

set -e

. "$(dirname "$0")/lib_kernel.sh"

(
  cd "$(dirname "$0")/.."

  # Same user-mode binaries as the QEMU build — user-mode code has no
  # board dependency (board facts reach it by syscall). Which embedded
  # servers actually spawn is the board's DEVICES table; see
  # lib_kernel.sh's KERNEL_SERVERS for why all of them are linked in.
  bash scripts/build_user.sh

  kernel_compile racccoon-duo kernel_duo

  # DUO_TEST_SHELL=1 embeds shell_test.c3 (the dev shell with the
  # *killtest / wasmtest / etc. builtins) instead of the production
  # shell.c3 — for exercising things that only exist on real hardware
  # (usbd/ethd/gpiod respawn, a fixture off the SD card). Reflash the
  # production kernel afterwards.
  SHELL_OBJ=build/user/shell.bin.o
  if [ "${DUO_TEST_SHELL:-0}" = "1" ]; then
    echo "==> DUO_TEST_SHELL=1 — embedding shell_test.c3 as the shell"
    SHELL_OBJ=$(kernel_test_shell_obj user_duo_shell)
  fi

  kernel_link "$SHELL_OBJ" boards/duo/kernel.ld kernel_duo

  # Not yet a flashable image: the boot ROM needs it wrapped with the
  # 32-byte LOADER_2ND ("BL33") header and packaged into a fip.bin —
  # scripts/build_duo_fip.sh, or scripts/reflash_duo.sh (repackages
  # against the fip.bin already on the card, then flashes).
  echo "==> Done: build/kernel_duo.elf (not yet fiptool-packaged)"
)
