#!/bin/bash
#
# seed_toolchain.sh <fat32|ext2> <image>: the headers /bin/clang compiles
# against on racccoon, and clangtest's inputs + references:
#
#   /src/sys/libc/include     racccoon-libc's headers
#   /src/sys/libcxx/include   libc++'s (build_cxx.sh)
#   /lib/clang/23/include     clang's resource headers — the host clang's,
#                             the ones every cross build here used
#   /src/clangtest/           hello.c, cxxtest.cpp, and the host clang's
#                             objects for them (build_llvm.sh)
#   /src/c3c, /src/sys/…,     c3c rebuilding itself (scripts/c3cbuild_ref.sh)
#   /src/c3c-ref              — ext2 only
#
# No-op until build_llvm.sh has made the references. Same shape as
# seed_tcc.sh / seed_selfbuild.sh.

set -e
KIND="$1"
IMG="$2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

[ -e build/llvm-fixtures/clang_cxx.ref.o ] && [ -d build/cxx/install/include/c++/v1 ] || exit 0
RES="$(clang -print-resource-dir)/include"

# Stage the device layout, then copy whole trees.
stage="build/toolchain-seed"
rm -rf "$stage"
mkdir -p "$stage/clangtest" "$stage/sys/libc" "$stage/sys/libcxx" "$stage/clang23"
cp -r lib/racccoon-libc/include "$stage/sys/libc/include"
cp -r build/cxx/install/include/c++/v1 "$stage/sys/libcxx/include"
cp -r "$RES" "$stage/clang23/include"
cp test/llvm-src/hello.c test/cxx-src/cxxtest.cpp \
   build/llvm-fixtures/clang_c.ref.o build/llvm-fixtures/clang_cxx.ref.o "$stage/clangtest/"

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
  for d in /src /lib /lib/clang; do
    debugfs -w -R "mkdir $d" "$IMG" >/dev/null 2>&1 || true
  done
  seed_tree_ext2 "$stage/sys" /src/sys
  seed_tree_ext2 "$stage/clang23" /lib/clang/23
  seed_tree_ext2 "$stage/clangtest" /src/clangtest
  # c3c's rebuild of itself (scripts/c3cbuild_ref.sh): ext2 only, ~330 MB.
  if [ -d build/c3cself ]; then
    seed_tree_ext2 build/c3cself/c3c /src/c3c
    seed_tree_ext2 build/c3cself/sys /src/sys
    seed_tree_ext2 build/c3cself/ref /src/c3c-ref
  fi
  ;;
fat32)
  mmd -i "$IMG" ::src ::lib ::lib/clang ::lib/clang/23 2>/dev/null || true
  mcopy -s -o -i "$IMG" "$stage/sys" ::src/
  mcopy -s -o -i "$IMG" "$stage/clang23/include" ::lib/clang/23/
  mcopy -s -o -i "$IMG" "$stage/clangtest" ::src/
  ;;
esac
