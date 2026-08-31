#!/bin/bash
#
# Seed a built TinyCC (build/tcc/) onto a disk image:
#   /bin/tcc            the compiler
#   /lib/tcc/include/   headers (CONFIG_TCC_SYSINCLUDEPATHS)
#   /lib/tcc/libtcc1.a  the riscv64 runtime (CONFIG_TCC_LIBPATHS)
#   /lib/tcc/crt0.o + /lib/tcc/libracccoon.a  so `tcc x.c -o x` can link
#   /hello.c           the smoke-test source (test/tcc-src/hello.c)
#
#   scripts/seed_tcc.sh ext2  <image>
#   scripts/seed_tcc.sh fat32 <image>
#
# No-ops (exit 0) if build/tcc/tcc.bin doesn't exist.
set -e

MODE="$1"
IMG="$2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

[ -f build/tcc/tcc.bin ] || exit 0
[ -n "$IMG" ] && [ -f "$IMG" ] || { echo "seed_tcc.sh: no image '$IMG'" >&2; exit 1; }

case "$MODE" in
ext2)
   D="debugfs -w -R"
  $D "mkdir /lib"     "$IMG" >/dev/null 2>&1 || true
  $D "mkdir /lib/tcc" "$IMG" >/dev/null 2>&1 || true
  # directories first (debugfs won't mkdir -p)
  ( cd build/tcc/lib && find . -type d ) | while read -r d; do
    [ "$d" = "." ] && continue
    $D "mkdir /lib/tcc/${d#./}" "$IMG" >/dev/null 2>&1 || true
  done
  ( cd build/tcc/lib && find . -type f ) | while read -r f; do
    f="${f#./}"
    $D "rm /lib/tcc/$f" "$IMG" >/dev/null 2>&1 || true
    $D "write build/tcc/lib/$f /lib/tcc/$f" "$IMG" >/dev/null
  done
  $D "rm /bin/tcc" "$IMG" >/dev/null 2>&1 || true
  $D "write build/tcc/tcc.bin /bin/tcc" "$IMG" >/dev/null
  $D "rm /hello.c" "$IMG" >/dev/null 2>&1 || true
  $D "write test/tcc-src/hello.c /hello.c" "$IMG" >/dev/null
  ;;
fat32)
  mmd   -i "$IMG" ::lib       2>/dev/null || true
  mmd   -i "$IMG" ::lib/tcc   2>/dev/null || true
  mcopy -s -o -i "$IMG" build/tcc/lib/* ::lib/tcc/
  mcopy -o -i "$IMG" build/tcc/tcc.bin ::bin/tcc
  mcopy -o -i "$IMG" test/tcc-src/hello.c ::hello.c
  ;;
*)
  echo "seed_tcc.sh: mode must be 'ext2' or 'fat32'" >&2; exit 1 ;;
esac

echo "==> seeded tcc onto $(basename "$IMG")"
