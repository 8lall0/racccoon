#!/bin/bash
#
# seed_selfbuild.sh <fat32|ext2> <image>: what racccoon needs to build its
# own kernel with /bin/c3c (scripts/selfbuild_ref.sh made it):
#
#   /lib/c3/std/          c3c's standard library (C3C_SRC/lib/std) — c3c
#                         finds it there by itself
#   /src/racccoon/        the kernel's sources + embedded objects +
#                         selfbuild.rc
#   /src/racccoon-ref/    the host's kernel.elf and c3ctest.o for them
#   /src/c3ctest.c3       c3ctest's fixture
#
# No-op until selfbuild_ref.sh has run. Same shape as seed_tcc.sh.

set -e
KIND="$1"
IMG="$2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

C3C_SRC="${C3C_SRC:-$HOME/Workspace/c3c-llvm}"
[ -e build/selfbuild/ref/kernel.elf ] && [ -d "$C3C_SRC/lib/std" ] || exit 0

seed_tree_ext2() {   # seed_tree_ext2 <src dir> <dst dir>
  local src="$1" dst="$2"
  debugfs -w -R "mkdir $dst" "$IMG" >/dev/null 2>&1 || true
  ( cd "$src" && find . -type d | sort ) | while read -r d; do
    [ "$d" = "." ] && continue
    debugfs -w -R "mkdir $dst/${d#./}" "$IMG" >/dev/null 2>&1 || true
  done
  ( cd "$src" && find . -type f ) | while read -r f; do
    f="${f#./}"
    debugfs -w -R "rm $dst/$f" "$IMG" >/dev/null 2>&1 || true
    debugfs -w -R "write $src/$f $dst/$f" "$IMG" >/dev/null
  done
}

case "$KIND" in
ext2)
  for d in /lib /lib/c3 /src; do
    debugfs -w -R "mkdir $d" "$IMG" >/dev/null 2>&1 || true
  done
  seed_tree_ext2 "$C3C_SRC/lib/std" /lib/c3/std
  seed_tree_ext2 build/selfbuild/racccoon /src/racccoon
  seed_tree_ext2 build/selfbuild/ref /src/racccoon-ref
  debugfs -w -R "write test/c3-src/c3ctest.c3 /src/c3ctest.c3" "$IMG" >/dev/null
  ;;
fat32)
  mmd -i "$IMG" ::lib ::lib/c3 ::src 2>/dev/null || true
  mcopy -s -o -i "$IMG" "$C3C_SRC/lib/std" ::lib/c3/
  mcopy -s -o -i "$IMG" build/selfbuild/racccoon ::src/
  mmd -i "$IMG" ::src/racccoon-ref 2>/dev/null || true
  mcopy -o -i "$IMG" build/selfbuild/ref/* ::src/racccoon-ref/
  mcopy -o -i "$IMG" test/c3-src/c3ctest.c3 ::src/c3ctest.c3
  ;;
esac
