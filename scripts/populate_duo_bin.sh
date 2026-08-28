#!/bin/bash
#
# Copies the standard user-space command binaries (build/user/*.bin)
# onto the real Duo's own root ext2 filesystem's bin/ directory, the
# same way scripts/build.sh already populates bin/ on every QEMU disk
# image — needed because these commands are ordinary exec()'d files
# read off the mounted filesystem, not embedded in the kernel image the
# way echod/diskd-or-sdd/fsd/procd/envd/usbd/ethd/netd are.
#
# The real Duo's root ext2 filesystem is whatever partition starts at
# board::FS_PARTITION_START_SECTOR (boards/duo/board.c3) — 2099200
# sectors = exactly 1 GiB, i.e. wherever the DUOBOOT FAT32 partition
# (1 GiB, standard 1 MiB/2048-sector alignment) ends. On a real SD card
# with the standard two-partition layout this is the second partition
# (e.g. /dev/sdc2, often labeled EXT2TEST from this project's own dual-
# filesystem test history) — confirmed by that exact arithmetic, not
# assumed.
#
# Needs root: a freshly-created ext2 filesystem's root directory is
# root-owned with no write access for other users, same reason
# scripts/flash_duo.sh needs root to write DUOBOOT's own fip.bin.
#
# Does NOT touch partitioning or any existing file — only creates bin/
# if missing and copies these specific binaries into it, same
# repeat-safely guarantee flash_duo.sh's own header comment makes.
#
# Usage: sudo DUO_ROOT_PARTITION=/dev/sdc2 bash scripts/populate_duo_bin.sh

set -e

DUO_ROOT_PARTITION=${DUO_ROOT_PARTITION:?set DUO_ROOT_PARTITION to the real ext2 root partition, e.g. /dev/sdc2 — no default, device paths vary by machine/session}

ROOT="$(dirname "$0")/.."
cd "$ROOT"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this as root (needs to mount $DUO_ROOT_PARTITION and write to its root-owned bin/): sudo DUO_ROOT_PARTITION=$DUO_ROOT_PARTITION bash $0" >&2
  exit 1
fi

# Same command list scripts/build.sh copies into every QEMU disk
# image's own bin/ — kept in sync by hand, same convention this
# project already uses for the small protocol constants duplicated
# across diskd.c3/fsd.c3.
BINARIES="echod cat ls write rm mkdir mv usbrw fsd gpio"

for b in $BINARIES; do
  if [ ! -f "build/user/$b.bin" ]; then
    echo "build/user/$b.bin not found — run 'bash scripts/build_user.sh' (or 'bash scripts/build_duo.sh') first." >&2
    exit 1
  fi
done

MNT=$(mktemp -d)
echo "==> Mounting $DUO_ROOT_PARTITION..."
mount "$DUO_ROOT_PARTITION" "$MNT"

echo "==> Ensuring the canonical root tree exists..."
# docs/filesystem-layout.md / roadmap §1 — kept in sync by hand with the
# same list in scripts/build.sh (the QEMU images). /proc /srv /env are
# namespace mounts, not real dirs.
for d in bin lib usr usr/root adm tmp mnt; do
  mkdir -p "$MNT/$d"
done
if [ ! -e "$MNT/adm/users" ]; then
  printf '0:root\n' > "$MNT/adm/users"
fi

for b in $BINARIES; do
  echo "==> Copying build/user/$b.bin -> $MNT/bin/$b..."
  cp "build/user/$b.bin" "$MNT/bin/$b"
done
# echod.elf too, matching the QEMU images — exercises SYS_EXEC's own
# real-ELF loader (see scripts/build.sh's own comment), not just the
# flat-binary format every other command above uses.
if [ -f "build/user/echod.elf" ]; then
  echo "==> Copying build/user/echod.elf -> $MNT/bin/echod.elf..."
  cp "build/user/echod.elf" "$MNT/bin/echod.elf"
fi
sync

echo "==> Unmounting..."
umount "$MNT"
rmdir "$MNT"

echo "==> Done. bin/ on the real Duo's root filesystem now matches build/user/."
