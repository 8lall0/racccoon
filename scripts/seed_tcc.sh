#!/bin/bash
#
# Seed a built TinyCC (build/tcc/) onto a disk image:
#   /bin/tcc              the compiler
#   /lib/tcc/include/     headers (CONFIG_TCC_SYSINCLUDEPATHS)
#   /lib/tcc/{crt1,crti,crtn}.o  crt for a tcc-linked binary
#   /lib/tcc/{libc,libtcc1}.a    libs a tcc-linked binary needs
#   /src/tcc/             tcc's own source subset — for `tcc /src/tcc/tcc.c`
#                         to rebuild tcc on racccoon (roadmap §7.8)
#   /hello.c             the smoke-test source (test/tcc-src/hello.c)
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

# seed_tree <local-dir> <image-dir>  (recursive)
seed_tree_ext2() {
  local src="$1" dst="$2"
  ( cd "$src" && find . -type d ) | while read -r d; do
    [ "$d" = "." ] && continue
    debugfs -w -R "mkdir $dst/${d#./}" "$IMG" >/dev/null 2>&1 || true
  done
  ( cd "$src" && find . -type f ) | while read -r f; do
    f="${f#./}"
    debugfs -w -R "rm $dst/$f" "$IMG" >/dev/null 2>&1 || true
    debugfs -w -R "write $src/$f $dst/$f" "$IMG" >/dev/null
  done
}

case "$MODE" in
ext2)
  for d in /lib /lib/tcc /src /src/tcc; do
    debugfs -w -R "mkdir $d" "$IMG" >/dev/null 2>&1 || true
  done
  seed_tree_ext2 build/tcc/lib /lib/tcc
  seed_tree_ext2 build/tcc/src /src/tcc
  debugfs -w -R "rm /bin/tcc" "$IMG" >/dev/null 2>&1 || true
  debugfs -w -R "write build/tcc/tcc.bin /bin/tcc" "$IMG" >/dev/null
  debugfs -w -R "rm /hello.c" "$IMG" >/dev/null 2>&1 || true
  debugfs -w -R "write test/tcc-src/hello.c /hello.c" "$IMG" >/dev/null
  ;;
fat32)
  mmd -i "$IMG" ::lib ::lib/tcc ::src ::src/tcc 2>/dev/null || true
  mcopy -s -o -i "$IMG" build/tcc/lib/* ::lib/tcc/
  mcopy -s -o -i "$IMG" build/tcc/src/* ::src/tcc/
  mcopy -o -i "$IMG" build/tcc/tcc.bin ::bin/tcc
  mcopy -o -i "$IMG" test/tcc-src/hello.c ::hello.c
  ;;
*)
  echo "seed_tcc.sh: mode must be 'ext2' or 'fat32'" >&2; exit 1 ;;
esac

echo "==> seeded tcc onto $(basename "$IMG")  —  tcc /hello.c -o /bin/hello && hello world"
