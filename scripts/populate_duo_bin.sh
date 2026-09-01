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
BINARIES="echod cat ls echo true false head whoami write rm mkdir mv chmod chown usbrw fsd gpio wasm"

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
for d in bin lib usr usr/root usr/glenda adm tmp mnt; do
  mkdir -p "$MNT/$d"
done
if [ ! -e "$MNT/adm/users" ]; then
  printf '0:root\n1000:glenda\n65534:none\n' > "$MNT/adm/users"
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

# C libc test programs (roadmap §7), if the C libc build produced any —
# same as scripts/build.sh seeds onto the QEMU images. Harmless on a
# production card (just extra /bin entries); lets the libc stages be
# checked on real hardware (stage6test, exiter, ...).
for c in build/libc/*.bin; do
  [ -e "$c" ] || continue
  echo "==> Copying $c -> $MNT/bin/$(basename "$c" .bin)..."
  cp "$c" "$MNT/bin/$(basename "$c" .bin)"
done

# Test fixtures — the same data files scripts/build.sh seeds onto the
# QEMU ext2 images, so the fixture-backed tests (p9fstest, pagelisttest,
# wasmtest) pass on real hardware instead of failing "file not found".
# All harmless extra root-level files on a production card. Only copied
# if the repo/build actually has them. (bigreadtest is NOT here — it
# reads /mnt/fs2/, the second mount, which the Duo doesn't have
# [board::HAS_SECOND_FS_PARTITION = false]; bigwritetest covers the same
# double-indirect path on the root mount and does run on the Duo.)
echo "==> Seeding test fixtures (hello.txt, subdir/, nestdir/, manyfiles/, *.wasm)..."
[ -f disk-ext2/hello.txt ] && cp disk-ext2/hello.txt "$MNT/hello.txt"
if [ -f disk-ext2/subdir/nested.txt ]; then
  mkdir -p "$MNT/subdir" "$MNT/nestdir/innerdir"
  cp disk-ext2/subdir/nested.txt "$MNT/subdir/nested.txt"
  cp disk-ext2/subdir/nested.txt "$MNT/nestdir/inner.txt"
  cp disk-ext2/subdir/nested.txt "$MNT/nestdir/innerdir/inner2.txt"
fi
# manyfiles/ — 60 one-line files in one dir, past FS_LIST's per-reply cap (pagelisttest).
mkdir -p "$MNT/manyfiles"
printf 'x\n' > "$MNT/.tiny.$$"
for i in $(seq -w 0 59); do cp "$MNT/.tiny.$$" "$MNT/manyfiles/e$i"; done
rm -f "$MNT/.tiny.$$"
# wasm fixtures (wasmtest).
if ls build/wasm/*.wasm >/dev/null 2>&1; then
  for w in build/wasm/*.wasm; do cp "$w" "$MNT/$(basename "$w")"; done
fi

# TinyCC payload (roadmap §7.7/§7.8) — same tree scripts/seed_tcc.sh puts
# on the QEMU images: /bin/tcc, /lib/tcc/ (headers + crt + libc.a +
# libtcc1.a), /src/tcc/ (the ONE_SOURCE subset for self-hosting), and
# the /hello.c smoke source. Lets tcctest and `tcc /src/tcc/tcc.c` run
# on real hardware. Only if the tcc build produced output.
if [ -f build/tcc/tcc.bin ]; then
  echo "==> Seeding TinyCC (/bin/tcc, /lib/tcc/, /src/tcc/, /hello.c)..."
  cp build/tcc/tcc.bin "$MNT/bin/tcc"
  rm -rf "$MNT/lib/tcc" "$MNT/src/tcc"
  mkdir -p "$MNT/lib/tcc" "$MNT/src"
  cp -r build/tcc/lib/. "$MNT/lib/tcc/"
  cp -r build/tcc/src "$MNT/src/tcc"
  [ -f test/tcc-src/hello.c ] && cp test/tcc-src/hello.c "$MNT/hello.c"
fi
sync

echo "==> Unmounting..."
umount "$MNT"
rmdir "$MNT"

echo "==> Done. bin/ on the real Duo's root filesystem now matches build/user/, plus the QEMU-image test fixtures + TinyCC payload."
