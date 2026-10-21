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
#   llc          -> /bin/llc            (IR -> RISC-V asm / objects)
#   lld          -> /bin/ld.lld         (the ELF linker; flavor from argv[0])
#
# LLVM_SRC must have llvm/, lld/ and libunwind/ (lld's Mach-O port
# includes one of its headers) besides what build_cxx.sh needs.
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

OUT="build/llvm-racccoon"   # not build/llvm: scripts/lib_kernel.sh owns that (kernel IR) and wipes it
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
    -DLLVM_ENABLE_PROJECTS=lld \
    -DLLVM_APPEND_VC_REV=OFF \
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

# racccoon.cmake's link rule names libracccoon.a / libc++.a / crt0 / the linker script as
# text, not as ninja inputs, so a libc change alone wouldn't relink:
# drop any tool older than them.
for t in llvm-readobj llc lld; do
  for lib in build/libc/libracccoon.a build/libc/crt0_mapped.o build/cxx/install/lib/libc++.a lib/racccoon-libc/racccoon-libc.ld; do
    [ "$lib" -nt "$OUT/bin/$t" ] && rm -f "$OUT/bin/$t"
  done
done

echo "==> LLVM: building llvm-readobj llc lld"
ninja -k 0 -C "$OUT" llvm-readobj llc lld > "$OUT.build.log" 2>&1 \
  || { grep -E "error|undefined symbol" "$OUT.build.log" | sort -u | head -60; exit 1; }

flat() {   # flat() <tool in $OUT/bin> <name in /bin>
  llvm-objcopy --set-section-flags .bss=alloc,contents -O binary "$OUT/bin/$1" "build/libc/$2.bin"
  echo "==> Done: build/libc/$2.bin ($(stat -c %s "build/libc/$2.bin") bytes)"
}
flat llvm-readobj llvm-readelf
flat llc llc
flat lld ld.lld

# llctest's fixture: the host llc's object for test/llvm-src/hello.ll —
# the same LLVM version, so racccoon's llc must produce identical bytes.
mkdir -p build/llvm-fixtures
llc -mattr=+m,+a,+f,+d,+c -filetype=obj test/llvm-src/hello.ll -o build/llvm-fixtures/hello.ref.o   # = llctest's flags

# lldtest's: the host ld.lld (same version) linking that object with the
# exact files build.sh seeds as /lib/racccoon/ — racccoon's ld.lld must
# produce the same bytes.
ld.lld -T lib/racccoon-libc/racccoon-libc.ld build/libc/crt0.o build/llvm-fixtures/hello.ref.o \
  build/libc/libracccoon.a "$(riscv64-unknown-elf-gcc -print-libgcc-file-name)" -o build/llvm-fixtures/hello.ref.elf
