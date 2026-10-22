#!/bin/bash
#
# Copies the QEMU ext2 test image's tree (build/disk_ext2.img, made by
# scripts/build.sh) onto a real card's ext2 root: /bin, the LLVM tools
# and c3c + its stdlib in /lib, the headers clang compiles against, the
# c3c self-build tree in /src, Go's toolchain dirs, and the test
# fixtures — everything the QEMU suite runs against, so the same tests
# (clangtest, selfbuildtest, c3cselftest, ...) run on the board.
#
# Leaves the card's own /adm (users, /adm/wifi credentials) and /usr
# (home directories) alone, and never deletes anything already on the
# card. User programs have no board dependency, so the QEMU build of
# /bin is the board's too (see scripts/build_duo.sh).
#
# Needs ~1 GB free on the card's ext2 (scripts/build.sh's ext2 image holds
# ~800 MB). Needs root: the card's ext2 is root-owned, and the image is
# loop-mounted (read-only).
#
# Usage: sudo CARD_ROOT_PARTITION=/dev/sdX2 bash scripts/populate_card.sh

set -e

CARD_ROOT_PARTITION=${CARD_ROOT_PARTITION:?set CARD_ROOT_PARTITION to the card ext2 root partition, e.g. /dev/sda2 — no default, device paths vary}

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMG="$ROOT/build/disk_ext2.img"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this as root: sudo CARD_ROOT_PARTITION=$CARD_ROOT_PARTITION bash $0" >&2
  exit 1
fi
[ -f "$IMG" ] || { echo "$IMG missing — run scripts/build.sh first" >&2; exit 1; }
[ "$(blkid -o value -s TYPE "$CARD_ROOT_PARTITION")" = "ext2" ] || {
  echo "$CARD_ROOT_PARTITION is not ext2 — is it really the card's root partition?" >&2
  exit 1
}

SRC=$(mktemp -d)
DST=$(mktemp -d)
cleanup() {
  umount "$SRC" 2>/dev/null || true
  umount "$DST" 2>/dev/null || true
  rmdir "$SRC" "$DST" 2>/dev/null || true
}
trap cleanup EXIT

mount -o loop,ro "$IMG" "$SRC"
mount "$CARD_ROOT_PARTITION" "$DST"

need=$(du -sk --exclude=adm --exclude=usr --exclude=lost+found "$SRC" | cut -f1)
free=$(df -k --output=avail "$DST" | tail -1)
echo "==> $((need / 1024)) MiB to copy, $((free / 1024)) MiB free on the card"
[ "$need" -lt "$free" ] || { echo "not enough space on $CARD_ROOT_PARTITION — grow it first" >&2; exit 1; }

echo "==> Copying (existing files are updated, nothing is deleted)..."
rsync -a --exclude=/adm --exclude=/usr --exclude=/lost+found "$SRC/" "$DST/"
sync
echo "==> Done."
