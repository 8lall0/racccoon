#!/bin/bash
#
# C++ on racccoon: cross-builds libc++ + libc++abi (static, from an
# llvm-project checkout) against racccoon-libc, then test/cxx-src/*.cpp
# into build/libc/<name>.bin next to the C test programs — the first step
# towards LLVM on racccoon (docs/manual.md, "C++ programs").
#
#   LLVM_SRC   llvm-project checkout at the tag matching the host clang
#              (default ~/Workspace/llvm-project); skipped if missing.
#
# Same ABI and code model as racccoon-libc (lib/racccoon-libc/build.sh),
# which must already be built (crt0.o, libracccoon.a). The C++ subset is
# what LLVM itself builds with: no exceptions, no RTTI, no threads, no
# locale, no <filesystem>.

set -e

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

LLVM_SRC="${LLVM_SRC:-$HOME/Workspace/llvm-project}"
if [ ! -d "$LLVM_SRC/libcxx" ] || ! command -v clang++ >/dev/null 2>&1; then
  echo "lib/racccoon-libc/build_cxx.sh: no llvm-project at LLVM_SRC=$LLVM_SRC (or no clang++)" >&2
  echo "  — C++ (libc++, /bin/cxxtest) is skipped." >&2
  exit 0
fi

OUT="build/cxx"
LIBC="build/libc"
RESDIR="$(clang -print-resource-dir)"
LIBGCC_RC="${LIBGCC_RC:-$(riscv64-unknown-elf-gcc -print-libgcc-file-name 2>/dev/null)}"
[ -e "$LIBGCC_RC" ] || LIBGCC_RC=""

ARCH="--target=riscv64-unknown-elf -march=rv64imafdc -mabi=lp64d -mcmodel=medany -fno-pic"
SYSINC="-nostdinc -isystem $ROOT/lib/racccoon-libc/include -isystem $RESDIR/include"
COMMON="$ARCH -ffunction-sections -fdata-sections -fno-asynchronous-unwind-tables -fno-stack-protector"

# --- libc++ / libc++abi -------------------------------------------------
# Rebuilt only when this script or racccoon-libc's headers change.
STAMP="$OUT/install/lib/libc++.a"
if [ ! -e "$STAMP" ] || [ "$0" -nt "$STAMP" ] \
   || [ -n "$(find lib/racccoon-libc/include -newer "$STAMP" -print -quit)" ]; then
  echo "==> libc++: configuring ($LLVM_SRC)"
  rm -rf "$OUT/build"
  cmake -G Ninja -S "$LLVM_SRC/runtimes" -B "$OUT/build" \
    -DCMAKE_BUILD_TYPE=MinSizeRel \
    -DCMAKE_INSTALL_PREFIX="$ROOT/$OUT/install" \
    -DCMAKE_SYSTEM_NAME=Generic \
    -DCMAKE_SYSTEM_PROCESSOR=riscv64 \
    -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
    -DCMAKE_ASM_COMPILER=clang \
    -DCMAKE_AR="$(command -v llvm-ar)" -DCMAKE_RANLIB="$(command -v llvm-ranlib)" \
    -DCMAKE_C_COMPILER_TARGET=riscv64-unknown-elf \
    -DCMAKE_CXX_COMPILER_TARGET=riscv64-unknown-elf \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DCMAKE_C_FLAGS="$COMMON $SYSINC" \
    -DCMAKE_CXX_FLAGS="$COMMON $SYSINC" \
    -DLLVM_ENABLE_RUNTIMES="libcxx;libcxxabi" \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLIBCXX_ENABLE_SHARED=OFF \
    -DLIBCXX_ENABLE_STATIC=ON \
    -DLIBCXX_ENABLE_THREADS=OFF \
    -DLIBCXX_ENABLE_MONOTONIC_CLOCK=OFF \
    -DLIBCXX_ENABLE_LOCALIZATION=OFF \
    -DLIBCXX_ENABLE_WIDE_CHARACTERS=OFF \
    -DLIBCXX_ENABLE_FILESYSTEM=OFF \
    -DLIBCXX_ENABLE_RANDOM_DEVICE=OFF \
    -DLIBCXX_ENABLE_EXCEPTIONS=OFF \
    -DLIBCXX_ENABLE_RTTI=OFF \
    -DLIBCXX_ENABLE_TIME_ZONE_DATABASE=OFF \
    -DLIBCXX_INCLUDE_TESTS=OFF \
    -DLIBCXX_INCLUDE_BENCHMARKS=OFF \
    -DLIBCXX_CXX_ABI=libcxxabi \
    -DLIBCXX_ENABLE_STATIC_ABI_LIBRARY=ON \
    -DLIBCXX_USE_COMPILER_RT=OFF \
    -DLIBCXXABI_ENABLE_SHARED=OFF \
    -DLIBCXXABI_ENABLE_STATIC=ON \
    -DLIBCXXABI_ENABLE_THREADS=OFF \
    -DLIBCXXABI_ENABLE_EXCEPTIONS=OFF \
    -DLIBCXXABI_USE_LLVM_UNWINDER=OFF \
    -DLIBCXXABI_USE_COMPILER_RT=OFF \
    -DLIBCXXABI_BAREMETAL=ON \
    -DLIBCXXABI_INCLUDE_TESTS=OFF \
    > "$OUT.configure.log" 2>&1 || { tail -40 "$OUT.configure.log"; exit 1; }
  echo "==> libc++: building"
  ninja -C "$OUT/build" install-cxx install-cxxabi > "$OUT.build.log" 2>&1 \
    || { grep -E "error|undefined" "$OUT.build.log" | head -40; exit 1; }
fi
echo "==> Done: $STAMP"

# --- test programs -------------------------------------------------------
CXXFLAGS="$COMMON -std=c++20 -Os -g -fno-exceptions -fno-rtti
          -nostdinc++ -nostdinc -isystem $ROOT/$OUT/install/include/c++/v1
          -isystem $ROOT/lib/racccoon-libc/include -isystem $RESDIR/include"
mkdir -p "$LIBC/obj"
for src in test/cxx-src/*.cpp; do
  [ -e "$src" ] || continue
  name=$(basename "$src" .cpp)
  clang++ $CXXFLAGS -c "$src" -o "$LIBC/obj/$name.o"
  ld.lld --gc-sections -T lib/racccoon-libc/racccoon-libc.ld -o "$LIBC/$name.elf" \
    "$LIBC/crt0.o" "$LIBC/obj/$name.o" \
    "$OUT/install/lib/libc++.a" "$LIBC/libracccoon.a" $LIBGCC_RC
  llvm-objcopy --set-section-flags .bss=alloc,contents -O binary \
    "$LIBC/$name.elf" "$LIBC/$name.bin"
  echo "==> Done: $LIBC/$name.bin ($(stat -c %s "$LIBC/$name.bin") bytes)"
done
