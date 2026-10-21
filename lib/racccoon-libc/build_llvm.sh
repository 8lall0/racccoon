#!/bin/bash
#
# LLVM tools for racccoon (docs/manual.md §9.8): cross-builds LLVM's
# libraries from the llvm-project checkout (LLVM_SRC, the same one
# build_cxx.sh uses) with lib/racccoon-libc/racccoon.cmake, and links the
# tools into flat build/libc/<name>.bin images, seeded as /bin/<name>
# with the C programs.
#
#   llvm-readobj -> /bin/llvm-readelf   (readobj picks readelf mode from
#                                        argv[0], which exec passes)
#
# tablegen runs on the host: the system llvm-tblgen must be the same
# version as the checkout's tag (the host clang's).

set -e

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

LLVM_SRC="${LLVM_SRC:-$HOME/Workspace/llvm-project}"
if [ ! -d "$LLVM_SRC/llvm/lib/Support" ] || [ ! -e build/cxx/install/lib/libc++.a ]; then
  echo "lib/racccoon-libc/build_llvm.sh: no llvm/ in LLVM_SRC=$LLVM_SRC (or no libc++ from build_cxx.sh)" >&2
  echo "  — LLVM tools (/bin/llvm-readelf) are skipped." >&2
  exit 0
fi
TBLGEN="$(command -v llvm-tblgen || true)"
if [ -z "$TBLGEN" ]; then
  echo "lib/racccoon-libc/build_llvm.sh: no host llvm-tblgen — LLVM tools skipped." >&2
  exit 0
fi

OUT="build/llvm"
if [ ! -e "$OUT/build.ninja" ] || [ "$0" -nt "$OUT/build.ninja" ] \
   || [ lib/racccoon-libc/racccoon.cmake -nt "$OUT/build.ninja" ]; then
  echo "==> LLVM: configuring ($LLVM_SRC)"
  rm -rf "$OUT"
  cmake -G Ninja -S "$LLVM_SRC/llvm" -B "$OUT" \
    -DCMAKE_TOOLCHAIN_FILE="$ROOT/lib/racccoon-libc/racccoon.cmake" \
    -DCMAKE_BUILD_TYPE=MinSizeRel \
    -DLLVM_TABLEGEN="$TBLGEN" \
    -DLLVM_HOST_TRIPLE=riscv64-unknown-elf \
    -DLLVM_DEFAULT_TARGET_TRIPLE=riscv64-unknown-elf \
    -DLLVM_TARGETS_TO_BUILD=RISCV \
    -DLLVM_ENABLE_THREADS=OFF \
    -DLLVM_ENABLE_PIC=OFF \
    -DLLVM_ENABLE_ZLIB=OFF \
    -DLLVM_ENABLE_ZSTD=OFF \
    -DLLVM_ENABLE_LIBXML2=OFF \
    -DLLVM_ENABLE_TERMINFO=OFF \
    -DLLVM_ENABLE_LIBEDIT=OFF \
    -DLLVM_ENABLE_LIBPFM=OFF \
    -DLLVM_ENABLE_BACKTRACES=OFF \
    -DLLVM_ENABLE_CRASH_OVERRIDES=OFF \
    -DLLVM_ENABLE_PLUGINS=OFF \
    -DLLVM_ENABLE_BINDINGS=OFF \
    -DLLVM_ENABLE_OCAMLDOC=OFF \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_DOCS=OFF \
    -DLLVM_INCLUDE_UTILS=OFF \
    -DLLVM_BUILD_TOOLS=OFF \
    -DLLVM_BUILD_UTILS=OFF \
    > "$OUT.configure.log" 2>&1 || { tail -40 "$OUT.configure.log"; exit 1; }
fi

echo "==> LLVM: building llvm-readobj"
ninja -k 0 -C "$OUT" llvm-readobj > "$OUT.build.log" 2>&1 \
  || { grep -E "error|undefined symbol" "$OUT.build.log" | sort -u | head -60; exit 1; }

llvm-objcopy --set-section-flags .bss=alloc,contents -O binary \
  "$OUT/bin/llvm-readobj" build/libc/llvm-readelf.bin
echo "==> Done: build/libc/llvm-readelf.bin ($(stat -c %s build/libc/llvm-readelf.bin) bytes)"
