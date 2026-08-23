#!/bin/bash
#
# Partitions a raw Milk-V Duo SD card from scratch into the layout
# racccoon expects: DUOBOOT (FAT32, sector 2048, 1GiB) for the BootROM
# to read fip.bin from, then EXT2TEST (ext2, 4096-byte blocks) starting
# at sector 2099200 through the end of the card, for fsd's own root
# filesystem — sector offsets match boards/duo/board.c3's own
# FS_PARTITION_START_SECTOR (2099200) and DUOBOOT's fixed sector 2048
# (see that file's own comment; scripts/flash_duo.sh's header comment
# has the BootROM-reads-a-literal-partition reasoning for why DUOBOOT
# can't start anywhere else).
#
# DESTROYS EVERYTHING CURRENTLY ON THE CARD — both new partitions are
# freshly formatted, empty. Only needed when the card's partition
# table itself is gone or wrong (confirm via `lsblk` first — no
# DUOBOOT/EXT2TEST labels shown means this is likely needed); if
# DUOBOOT/EXT2TEST already exist and just need a new kernel,
# scripts/flash_duo.sh alone is the right (non-destructive) tool.
#
# Usage: sudo DUO_SD_DEVICE=/dev/sdc bash scripts/provision_duo_sd.sh

set -e

DUO_SD_DEVICE=${DUO_SD_DEVICE:?set DUO_SD_DEVICE to the whole SD card device, e.g. /dev/sdc — NOT a partition like /dev/sdc1, and no default since device paths vary by machine/session}

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this as root (needs to repartition $DUO_SD_DEVICE): sudo DUO_SD_DEVICE=$DUO_SD_DEVICE bash $0" >&2
  exit 1
fi

echo "==> About to WIPE and repartition $DUO_SD_DEVICE. Ctrl-C now to abort."
echo "    (double-check this is really the SD card, not a real disk — see \`lsblk\`)"
sleep 5

echo "==> Unmounting any existing partitions..."
umount "${DUO_SD_DEVICE}1" "${DUO_SD_DEVICE}2" 2>/dev/null || true

echo "==> Writing partition table (DUOBOOT: sectors 2048-2099199, EXT2TEST: 2099200-end)..."
sfdisk "$DUO_SD_DEVICE" << 'EOF'
label: dos
unit: sectors

start=2048, size=2097152, type=c
start=2099200, type=83
EOF

partprobe "$DUO_SD_DEVICE" 2>/dev/null || true
sleep 1

echo "==> Formatting ${DUO_SD_DEVICE}1 as DUOBOOT (FAT32)..."
mkfs.vfat -F 32 -n DUOBOOT "${DUO_SD_DEVICE}1"

echo "==> Formatting ${DUO_SD_DEVICE}2 as EXT2TEST (ext2, 4096-byte blocks)..."
mkfs.ext2 -b 4096 -L EXT2TEST "${DUO_SD_DEVICE}2"

echo "==> Done. Both partitions are empty — copy fip.bin onto DUOBOOT next"
echo "    (scripts/flash_duo.sh, or udisksctl mount/cp/unmount by hand)."
