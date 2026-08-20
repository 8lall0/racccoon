#!/bin/bash
#
# Flashes build/fip_duo.bin (scripts/build_duo_fip.sh) onto a Milk-V Duo
# SD card's existing DUOBOOT FAT32 partition — the correct way, not a
# raw dd to the disk. BootROM reads fip.bin as a literal file inside
# DUOBOOT's own filesystem (confirmed in docs/devlog.md, real-hardware
# verification from early in this board's bring-up); a raw
# `dd if=fip.bin of=/dev/sdX bs=1M` starting at disk offset 0 destroys
# the MBR/partition table instead, since DUOBOOT itself starts at
# sector 2048 (boards/duo/board.c3's own FS_PARTITION_START_SECTOR),
# not 0 — found the hard way once already, see that same devlog entry.
#
# Does NOT touch partitioning or existing filesystem content on
# DUOBOOT/EXT2TEST — safe to run repeatedly, every time you rebuild.
# If the partition table itself is gone (confirm via `lsblk` — no
# sdX1/sdX2 shown), this script can't fix that; the SD card needs
# repartitioning from scratch first.
#
# Usage: sudo DUO_SD_PARTITION=/dev/sdc1 bash scripts/flash_duo.sh

set -e

DUO_SD_PARTITION=${DUO_SD_PARTITION:?set DUO_SD_PARTITION to the DUOBOOT FAT32 partition, e.g. /dev/sdc1 — no default, device paths vary by machine/session}

ROOT="$(dirname "$0")/.."
cd "$ROOT"

FIP=build/fip_duo.bin

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this as root (needs to mount $DUO_SD_PARTITION): sudo DUO_SD_PARTITION=$DUO_SD_PARTITION bash $0" >&2
  exit 1
fi

if [ ! -f "$FIP" ]; then
  echo "$FIP not found — run 'bash scripts/build_duo.sh' then 'DUO_SDK=... bash scripts/build_duo_fip.sh' first." >&2
  exit 1
fi

MNT=$(mktemp -d)
echo "==> Mounting $DUO_SD_PARTITION..."
mount "$DUO_SD_PARTITION" "$MNT"

echo "==> Copying $FIP -> $MNT/fip.bin..."
cp "$FIP" "$MNT/fip.bin"
sync

echo "==> Unmounting..."
umount "$MNT"
rmdir "$MNT"

echo "==> Done. Power-cycle the board to boot the new kernel."
