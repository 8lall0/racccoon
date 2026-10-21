#!/bin/bash
#
# c3c for racccoon (docs/manual.md §9.8): the C3 compiler with its normal
# LLVM backend and lld linked in, cross-built against racccoon-libc +
# libc++ + the LLVM libraries build_llvm.sh made, as a flat
# build/libc/c3c.bin (-> /bin/c3c). Run after build_llvm.sh.
#
#   C3C_SRC   a c3c checkout (default ~/Workspace/c3c-llvm): upstream
#             v0.8.5 — the version that builds racccoon — plus the
#             racccoon patches on the fork's `racccoon-llvm` branch
#             (no /proc/self/exe, the rv64 default target, small vmem
#             arenas, no LLVM threads). Skipped if missing.
#
# Compile flags: C3_SMALL_ARENAS=128 (MiB per vmem arena instead of 4 GiB:
# reservations count against the process heap cap), C3_NO_PROC_SELF_EXE,
# C3_LLVM_NO_THREADS, and *_DISABLE for every LLVM target but RISC-V
# (racccoon's LLVM is built for RISC-V only).

set -e

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

C3C_SRC="${C3C_SRC:-$HOME/Workspace/c3c-llvm}"
LLVM_SRC="${LLVM_SRC:-$HOME/Workspace/llvm-project}"
LLVM_OUT="build/llvm-racccoon"
if [ ! -e "$C3C_SRC/src/compiler/compiler.c" ] || [ ! -e "$LLVM_OUT/lib/cmake/lld/LLDConfig.cmake" ]; then
  echo "lib/racccoon-libc/build_c3c.sh: no c3c at C3C_SRC=$C3C_SRC (or no LLVM/lld from build_llvm.sh)" >&2
  echo "  — /bin/c3c is skipped." >&2
  exit 0
fi

# c3c links (nearly) all of LLVM's libraries, not just what the tools use.
echo "==> c3c: LLVM libraries"
ninja -C "$LLVM_OUT" > "$LLVM_OUT.c3c-libs.log" 2>&1 \
  || { grep -E "error" "$LLVM_OUT.c3c-libs.log" | head -20; exit 1; }

OUT="build/c3c-racccoon"
DEFS="-DC3_SMALL_ARENAS=128 -DC3_NO_PROC_SELF_EXE -DC3_LLVM_NO_THREADS"
DEFS="$DEFS -DAVR_DISABLE -DARM_DISABLE -DAARCH64_DISABLE -DWASM_DISABLE -DX86_DISABLE"   # one line: CMake flags can't hold a newline
if [ ! -e "$OUT/build.ninja" ] || [ "$0" -nt "$OUT/build.ninja" ]; then
  echo "==> c3c: configuring ($C3C_SRC)"
  rm -rf "$OUT"
  CFLAGS="$DEFS" CXXFLAGS="$DEFS" cmake -G Ninja -S "$C3C_SRC" -B "$OUT" \
    -DCMAKE_TOOLCHAIN_FILE="$ROOT/lib/racccoon-libc/racccoon.cmake" \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_DIR="$ROOT/$LLVM_OUT/lib/cmake/llvm" \
    -DLLD_DIR="$ROOT/$LLVM_OUT/lib/cmake/lld" \
    -DC3_LINK_DYNAMIC=OFF \
    "-DC3_LLD_INCLUDE_DIR=$LLVM_SRC/lld/include;$ROOT/$LLVM_OUT/tools/lld/include" \
    > "$OUT.configure.log" 2>&1 || { tail -30 "$OUT.configure.log"; exit 1; }
fi

# Same relink guard as build_llvm.sh: the link rule names the libc
# archives as text, not as ninja inputs.
for lib in build/libc/libracccoon.a build/libc/crt0_mapped.o build/cxx/install/lib/libc++.a \
           lib/racccoon-libc/racccoon-libc.ld; do
  [ "$lib" -nt "$OUT/c3c" ] && rm -f "$OUT/c3c"
done

echo "==> c3c: building"
ninja -k 0 -C "$OUT" c3c > "$OUT.build.log" 2>&1 \
  || { grep -E "error|undefined symbol" "$OUT.build.log" | sort -u | head -40; exit 1; }
llvm-objcopy --set-section-flags .bss=alloc,contents -O binary "$OUT/c3c" build/libc/c3c.bin
echo "==> Done: build/libc/c3c.bin ($(stat -c %s build/libc/c3c.bin) bytes)"
