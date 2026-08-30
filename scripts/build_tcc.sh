#!/bin/bash
#
# Cross-build TinyCC for riscv64-racccoon (roadmap §7.7) against the
# userspace C library in lib/racccoon-libc/.
#
#   build/tcc/tcc.bin       — the compiler, flat binary (-> /bin/tcc)
#   build/tcc/lib/          — CONFIG_TCCDIR payload (headers, libtcc1.a)
#
# TinyCC's source is NOT vendored in this repo (68k lines, ~5 MB). Point
# TCC_SRC at a checkout of https://repo.or.cz/tinycc.git (mob branch,
# 0.9.28rc — the version lib/tcc/config.h is written for). With TCC_SRC
# unset the script no-ops, exactly like lib/racccoon-libc/build.sh does
# without a riscv64 C compiler — the rest of the build is unaffected.
#
# Bring-up ladder (see docs/devlog.md):
#   tcc -E hello.c              preprocessor only  — needs just tcc.bin
#   tcc -c hello.c              riscv64 codegen + ELF .o
#   tcc hello.c -o hello        integrated linker  — also needs libtcc1.a
#
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TCC_SRC="${TCC_SRC:-}"
for cand in "$TCC_SRC" third_party/tinycc lib/tcc/src ../tinycc; do
  [ -n "$cand" ] && [ -f "$cand/tcc.c" ] && { TCC_SRC="$cand"; break; }
done
if [ -z "$TCC_SRC" ] || [ ! -f "$TCC_SRC/tcc.c" ]; then
  echo "scripts/build_tcc.sh: no TinyCC source (set TCC_SRC=<tinycc checkout>)" >&2
  echo "  — the on-device C compiler (roadmap §7.7) is skipped; nothing else is affected." >&2
  exit 0
fi
TCC_SRC="$(cd "$TCC_SRC" && pwd)"

CC_RC="${CC_RC:-}"
if [ -z "$CC_RC" ]; then
  for c in riscv64-unknown-elf-gcc riscv64-elf-gcc riscv64-linux-gnu-gcc; do
    command -v "$c" >/dev/null 2>&1 && { CC_RC="$c"; break; }
  done
fi
[ -n "$CC_RC" ] || { echo "build_tcc.sh: no riscv64 C compiler (set CC_RC)" >&2; exit 0; }

LD_RC="${LD_RC:-$(command -v ld.lld || echo "${CC_RC%-gcc}-ld")}"
OBJCOPY_RC="${OBJCOPY_RC:-$(command -v llvm-objcopy || echo "${CC_RC%-gcc}-objcopy")}"
AR_RC="${AR_RC:-$(command -v llvm-ar || echo "${CC_RC%-gcc}-ar")}"
LIBGCC_RC="${LIBGCC_RC:-$($CC_RC -print-libgcc-file-name 2>/dev/null)}"
HOSTCC="${HOSTCC:-cc}"

OUT="build/tcc"
LIBC="$ROOT/lib/racccoon-libc"
mkdir -p "$OUT/obj" "$OUT/lib/include"

# Ensure the C library is built (crt0.o + libracccoon.a).
[ -f build/libc/libracccoon.a ] || bash lib/racccoon-libc/build.sh

echo "==> TinyCC: $TCC_SRC  ($(cat "$TCC_SRC/VERSION" 2>/dev/null))"

GCCINC="$($CC_RC -print-file-name=include)"
CFLAGS="-march=rv64imafdc -mabi=lp64d -mcmodel=medany -ffreestanding -fno-pic
 -fno-stack-protector -fno-builtin -Os -std=gnu11 -ffunction-sections -fdata-sections
 -nostdinc -isystem $GCCINC -I $LIBC/include -I $ROOT/lib/tcc
 -DTCC_GITHASH=\"racccoon\" -DONE_SOURCE=1 -DCONFIG_TCC_STATIC=1 -DCONFIG_TCC_SEMLOCK=0"

# --- tccdefs_.h (the built-in predefined macros), via the BUILD cc ----
$HOSTCC -DC2STR "$TCC_SRC/conftest.c" -o "$OUT/c2str.exe"
"$OUT/c2str.exe" "$TCC_SRC/include/tccdefs.h" "$OUT/tccdefs_.h"

# --- the compiler ----------------------------------------------------
$CC_RC $CFLAGS -I "$OUT" -c "$TCC_SRC/tcc.c" -o "$OUT/obj/tcc.o"
$LD_RC --gc-sections -T lib/tcc/racccoon-tcc.ld -o "$OUT/tcc.elf" \
  build/libc/crt0.o "$OUT/obj/tcc.o" build/libc/libracccoon.a $LIBGCC_RC
$OBJCOPY_RC --set-section-flags .bss=alloc,contents -O binary "$OUT/tcc.elf" "$OUT/tcc.bin"
$OBJCOPY_RC -O binary --only-section=.text "$OUT/tcc.elf" /dev/null 2>/dev/null || true
echo "==> Done: $OUT/tcc.bin  ($(stat -c%s "$OUT/tcc.bin") bytes)"

# --- CONFIG_TCCDIR payload -----------------------------------------
# tcc's own headers (stddef/stdarg/float/varargs/tccdefs …) + ours, so a
# compiled program can #include the standard set. Plus libtcc1.a for the
# full compile+link path.
cp "$TCC_SRC"/include/*.h "$OUT/lib/include/" 2>/dev/null || true
cp "$LIBC"/include/*.h "$OUT/lib/include/" 2>/dev/null || true
cp -r "$LIBC"/include/sys "$LIBC"/include/racccoon "$OUT/lib/include/" 2>/dev/null || true

# libtcc1.a — riscv64 runtime helpers (soft 128-bit float, __va_arg,
# alloca, …). Built with the cross gcc rather than tcc itself for the
# first bring-up; revisit once tcc runs on device.
LT1="$OUT/lib_obj"; mkdir -p "$LT1"
LT1_SRC="lib-arm64.c libtcc1.c stdatomic.c builtin.c dsohandle.c"
ok=1
for s in $LT1_SRC; do
  [ -f "$TCC_SRC/lib/$s" ] || continue
  $CC_RC $CFLAGS -c "$TCC_SRC/lib/$s" -o "$LT1/${s%.c}.o" 2>/dev/null || ok=0
done
for s in atomic.S armflush.S alloca.S alloca-bt.S; do
  [ -f "$TCC_SRC/lib/$s" ] || continue
  $CC_RC $CFLAGS -c "$TCC_SRC/lib/$s" -o "$LT1/${s%.S}.o" 2>/dev/null || true
done
if [ "$ok" = 1 ] && ls "$LT1"/*.o >/dev/null 2>&1; then
  $AR_RC rcs "$OUT/lib/libtcc1.a" "$LT1"/*.o
  echo "==> Done: $OUT/lib/libtcc1.a"
else
  echo "==> libtcc1.a: partial/failed (full 'tcc x.c -o x' link not ready yet)" >&2
fi

echo "==> build/tcc/ ready. Seed onto an image: /bin/tcc + /lib/tcc/"
