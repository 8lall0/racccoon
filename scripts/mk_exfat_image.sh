#!/bin/bash

set -e

# Builds and populates build/disk_exfat.img — the exFAT QEMU test image
# for scripts/launch64_exfat.sh, exercising user/fs/exfat.c3's read path
# (probe/mount/read/read_at/list) and, from the second exFAT session on,
# its write path too (write/delete/mkdir via the shell's own
# write/rm/mkdir — see docs/devlog.md's exFAT entries).
#
# Unlike the FAT32 (mtools) and ext2 (debugfs) test images, exFAT has no
# pure-userspace image editor packaged anywhere — exfatprogs ships only
# mkfs/fsck/dump/label, none of which write file data. So this image has
# to be populated through a real, kernel-or-FUSE exFAT mount. That needs
# either udisksctl (no root, the normal case on a dev desktop — see
# docs/devlog.md's "Flash Duo without sudo" note for the same udisksctl-
# over-sudo reasoning) or passwordless `sudo mount`.
#
# This is why scripts/build.sh calls this script best-effort: a build
# host with neither just doesn't get build/disk_exfat.img, exactly like
# it already skips nothing else — the exFAT boot is an opt-in test
# target (launch64_exfat.sh), same as launch64_ext2.sh / launch64_dual.sh.

cd "$(dirname "$0")/.."

IMG=build/disk_exfat.img
LABEL=RACEXFAT

rm -f "$IMG"
dd if=/dev/zero of="$IMG" bs=1M count=64 status=none
mkfs.exfat -n "$LABEL" "$IMG" > /dev/null

# --- mount (udisksctl first, sudo fallback) ---------------------------
MNT=""
LOOP=""
CLEANUP_MODE=""
cleanup() {
  set +e
  if [ "$CLEANUP_MODE" = "udisks" ]; then
    [ -n "$LOOP" ] && udisksctl unmount -b "$LOOP" >/dev/null 2>&1
    [ -n "$LOOP" ] && udisksctl loop-delete -b "$LOOP" >/dev/null 2>&1
  elif [ "$CLEANUP_MODE" = "sudo" ]; then
    [ -n "$MNT" ] && sudo umount "$MNT" >/dev/null 2>&1
    [ -n "$MNT" ] && rmdir "$MNT" >/dev/null 2>&1
  fi
}
trap cleanup EXIT

if command -v udisksctl >/dev/null 2>&1; then
  LOOP=$(udisksctl loop-setup -f "$IMG" | sed -n 's/.* as \(\/dev\/loop[0-9]*\).*/\1/p')
  [ -n "$LOOP" ] || { echo "mk_exfat_image: udisksctl loop-setup gave no device" >&2; exit 1; }
  # give udev a moment, then mount
  sleep 1
  MNT=$(udisksctl mount -b "$LOOP" | sed -n 's/.* at \(.*\)$/\1/p')
  [ -n "$MNT" ] || { echo "mk_exfat_image: udisksctl mount gave no mountpoint" >&2; exit 1; }
  CLEANUP_MODE="udisks"
elif sudo -n true 2>/dev/null; then
  MNT=$(mktemp -d)
  sudo mount -o "loop,uid=$(id -u),gid=$(id -g)" "$IMG" "$MNT"
  CLEANUP_MODE="sudo"
else
  echo "mk_exfat_image: no udisksctl and no passwordless sudo — cannot populate exFAT image" >&2
  exit 1
fi

# --- populate --------------------------------------------------------
cp disk-exfat/hello.txt        "$MNT/hello.txt"
cp disk-exfat/MixedCase.txt    "$MNT/MixedCase.txt"   # mixed case: exercises the Up-case Table fold
mkdir "$MNT/subdir"
cp disk-exfat/subdir/nested.txt "$MNT/subdir/nested.txt"
# A name that is not valid 8.3 short form — the exFAT equivalent of
# fat32.c3's LFN fixture, except exFAT stores it directly (0xC1 File Name
# entries), no separate short/long split.
printf 'Hello from a name with spaces\n' > "$MNT/My Long File Name.txt"
# A genuinely empty directory — exfat_list has to return it as a
# zero-entry success, not an error.
mkdir "$MNT/emptydir"

# bin/ — real, already-built user binaries, exec()'d the ordinary way by
# the shell's /bin/<cmd> fallback. Every one of these lands contiguous
# (NoFatChain) on a fresh volume, so they exercise exfat_read_chain_at's
# contiguous path.
mkdir "$MNT/bin"
cp build/user/echod.bin "$MNT/bin/echod"
for u in cat ls write rm mkdir mv usbrw fsd gpio wasm; do
  cp "build/user/$u.bin" "$MNT/bin/$u"
done

# bin/ls_frag — a deliberately, maximally fragmented copy of ls.bin: each
# 4KB cluster written interleaved with a filler file that is then
# deleted, so no two data clusters end up adjacent. exFAT marks this one
# NoFatChain=0, forcing exfat_next_cluster (real FAT-chain traversal) at
# every single cluster boundary — the one thing a contiguous binary
# never exercises. `ls_frag <dir>` exec'ing correctly is the end-to-end
# proof of the FAT-chain read path on QEMU (see docs/devlog.md).
python3 - "$MNT" <<'PYEOF'
import sys, os
mnt = sys.argv[1]
data = open('build/user/ls.bin', 'rb').read()
CH = 4096
with open(mnt + '/bin/ls_frag', 'wb') as out, open(mnt + '/__frag_filler', 'wb') as fill:
    for off in range(0, len(data), CH):
        out.write(data[off:off + CH]);  out.flush();  os.fsync(out.fileno())
        fill.write(b'\0' * CH);         fill.flush(); os.fsync(fill.fileno())
os.remove(mnt + '/__frag_filler')
PYEOF

sync
echo "==> Done: $IMG"
