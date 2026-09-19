#!/bin/bash
#
# Make a microSD boot racccoon on an Orange Pi RV, unattended — no sudo
# (udisksctl), no USB, no SPI-flash writes. Works on either card layout:
#
#   racccoon card (the Milk-V Duo's card: DUOBOOT + ext2 root) — copies
#     kernel_opi.bin + vf2_uEnv.txt next to the Duo's fip.bin, so the SAME card
#     boots in both boards, and racccoon on the Orange Pi mounts the ext2 root
#     (its /bin, /adm/users, /usr/root) that the Duo uses.
#   Orange Pi vendor-Debian card (bootfs) — also renames extlinux.conf so the
#     Linux boot doesn't win, and copies the shell's commands into bootfs/bin/.
#
#   build_opi.sh (kernel_opi.bin) -> mount the FAT boot partition -> copy.
#
# How it boots: the vendor U-Boot reads mmc1 (the microSD), loads
# /vf2_uEnv.txt, imports it and runs `boot2` — which loads kernel_opi.bin and
# jumps to it (see boards/opi-rv/vf2_uEnv.txt). Nothing on the board changes;
# to get vendor Debian back: mv extlinux/extlinux.conf.bak extlinux/extlinux.conf
# (and/or delete vf2_uEnv.txt + uEnv.txt from the card).
#
# Usage:
#   OPI_BOOT_PART=/dev/sda1 bash scripts/flash_opi.sh
#
# Env:
#   OPI_BOOT_PART  the card's FAT boot partition (racccoon: DUOBOOT; Debian: bootfs) —
#                  REQUIRED, no default (device paths vary; `lsblk` shows it)
#   OPI_TEST_SHELL=1  embed shell_test.c3's dev builtins (passed to build_opi.sh)
#   SKIP_BUILD=1   flash the existing build/kernel_opi.bin as-is
#   LLVM_LLD / LLC / LLVM_OBJCOPY  passed through to build_opi.sh

set -e

OPI_BOOT_PART=${OPI_BOOT_PART:?set OPI_BOOT_PART to the card bootfs partition, e.g. /dev/sda1 — no default}

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ "${SKIP_BUILD:-0}" != "1" ]; then
  bash scripts/build_opi.sh
fi
[ -f build/kernel_opi.bin ] || { echo "build/kernel_opi.bin missing — run scripts/build_opi.sh" >&2; exit 1; }

udisksctl mount -b "$OPI_BOOT_PART" >/dev/null 2>&1 || true
MNT=$(findmnt -n -o TARGET --source "$OPI_BOOT_PART" | head -1)
[ -n "$MNT" ] || { echo "could not mount $OPI_BOOT_PART" >&2; exit 1; }
echo "==> bootfs mounted at $MNT"

# Two card layouts are supported; refuse anything else (so it can't hit some
# unrelated card):
#   racccoon  the Milk-V Duo card — DUOBOOT (FAT32, holds the Duo's fip.bin) +
#             an ext2 root. Add the Orange Pi boot files next to fip.bin; the
#             SAME card then boots in both boards. Its ext2 root already has bin/.
#   debian    the Orange Pi vendor image's bootfs (Image + extlinux/). Rename
#             extlinux.conf so the Linux boot doesn't win. NOTE the kernel mounts
#             the racccoon card's ext2 root (board FS_PARTITION_START_SECTOR), so on
#             this card racccoon has no filesystem unless rebuilt with 8192.
if [ -f "$MNT/fip.bin" ]; then
  MODE=racccoon
elif [ -f "$MNT/Image" ] && [ -d "$MNT/extlinux" ]; then
  MODE=debian
else
  echo "$MNT is neither a racccoon/Duo DUOBOOT (fip.bin) nor an Orange Pi vendor bootfs (Image + extlinux/) — refusing." >&2
  exit 1
fi
echo "==> card layout: $MODE"

if [ "$MODE" = debian ] && [ -f "$MNT/extlinux/extlinux.conf" ]; then
  echo "==> extlinux.conf -> extlinux.conf.bak (so the vendor Linux boot doesn't win)"
  mv "$MNT/extlinux/extlinux.conf" "$MNT/extlinux/extlinux.conf.bak"
fi

echo "==> Copying kernel_opi.bin + vf2_uEnv.txt/uEnv.txt"
cp build/kernel_opi.bin "$MNT/kernel_opi.bin"
cp boards/opi-rv/vf2_uEnv.txt "$MNT/vf2_uEnv.txt"
cp boards/opi-rv/vf2_uEnv.txt "$MNT/uEnv.txt"

# The shell's commands (ls, cat, ...) are ordinary programs exec()'d off the
# mounted filesystem, not embedded in the kernel — so put them in bin/ on the
# partition racccoon mounts (board::FS_PARTITION_START_SECTOR = this bootfs).
# Same list scripts/populate_duo_bin.sh uses, minus the Duo-only hardware tools
# (usbrw, gpio) and the boot servers that are linked into the kernel (echod,
# fsd). Debian card only (the racccoon card's ext2 root already has bin/).
# OPI_NO_BIN=1 skips it.
if [ "$MODE" = debian ] && [ "${OPI_NO_BIN:-0}" != "1" ]; then
  BINARIES="cat ls echo true false ed grep wc sort find cmp tr dmesg ps top head whoami write rm mkdir mv chmod chown test expr wasm"
  for b in $BINARIES; do
    [ -f "build/user/$b.bin" ] || { echo "build/user/$b.bin missing — run scripts/build_user.sh" >&2; exit 1; }
  done
  echo "==> Populating bin/ ($(echo $BINARIES | wc -w) commands)"
  mkdir -p "$MNT/bin"
  for b in $BINARIES; do cp "build/user/$b.bin" "$MNT/bin/$b"; done
fi
sync

cmp build/kernel_opi.bin "$MNT/kernel_opi.bin" && cmp boards/opi-rv/vf2_uEnv.txt "$MNT/vf2_uEnv.txt" \
  || { echo "readback mismatch" >&2; exit 1; }
echo "==> verified"

udisksctl unmount -b "$OPI_BOOT_PART" >/dev/null 2>&1 || true
echo "==> Done. Put the card in the Orange Pi and power-cycle: expect"
echo "    'racccoon: loading kernel_opi.bin from mmc 1:1...' then the kernel boot log."
