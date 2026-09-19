#!/bin/bash
#
# Put racccoon on an Orange Pi RV's vendor-Debian microSD so the board boots
# it unattended — no sudo (udisksctl), no USB, no SPI-flash writes.
#
#   build_opi.sh (kernel_opi.bin)
#     -> udisksctl-mount the card's `bootfs` (FAT, partition 1)
#     -> rename extlinux/extlinux.conf -> .bak   (else the Linux boot wins)
#     -> copy kernel_opi.bin + boards/opi-rv/vf2_uEnv.txt (also as uEnv.txt)
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
#   OPI_BOOT_PART  the card's boot (bootfs, FAT32, label opi_boot) partition —
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

# Refuse anything that isn't the vendor Debian boot partition (a Duo card's
# DUOBOOT, say): it must hold the kernel image + an extlinux dir.
if [ ! -f "$MNT/Image" ] || [ ! -d "$MNT/extlinux" ]; then
  echo "$MNT has no Image + extlinux/ — not an Orange Pi vendor bootfs, refusing." >&2
  exit 1
fi

if [ -f "$MNT/extlinux/extlinux.conf" ]; then
  echo "==> extlinux.conf -> extlinux.conf.bak (so the vendor Linux boot doesn't win)"
  mv "$MNT/extlinux/extlinux.conf" "$MNT/extlinux/extlinux.conf.bak"
fi

echo "==> Copying kernel_opi.bin + vf2_uEnv.txt/uEnv.txt"
cp build/kernel_opi.bin "$MNT/kernel_opi.bin"
cp boards/opi-rv/vf2_uEnv.txt "$MNT/vf2_uEnv.txt"
cp boards/opi-rv/vf2_uEnv.txt "$MNT/uEnv.txt"
sync

cmp build/kernel_opi.bin "$MNT/kernel_opi.bin" && cmp boards/opi-rv/vf2_uEnv.txt "$MNT/vf2_uEnv.txt" \
  || { echo "readback mismatch" >&2; exit 1; }
echo "==> verified"

udisksctl unmount -b "$OPI_BOOT_PART" >/dev/null 2>&1 || true
echo "==> Done. Put the card in the Orange Pi and power-cycle: expect"
echo "    'racccoon: loading kernel_opi.bin from mmc 1:1...' then the kernel boot log."
