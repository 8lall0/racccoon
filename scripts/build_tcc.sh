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

# lib/tcc/racccoon.patch: ELF_START_ADDR -> USER_BASE (see the patch and
# lib/tcc/config.h). Applied idempotently — skipped if already in.
PATCH="$ROOT/lib/tcc/racccoon.patch"
if [ -f "$PATCH" ] && [ -e "$TCC_SRC/.git" ]; then   # .git is a file for a submodule
  if git -C "$TCC_SRC" apply --reverse --check "$PATCH" 2>/dev/null; then
    echo "==> lib/tcc/racccoon.patch already applied"
  elif git -C "$TCC_SRC" apply --check "$PATCH" 2>/dev/null; then
    git -C "$TCC_SRC" apply "$PATCH"
    echo "==> applied lib/tcc/racccoon.patch"
  else
    echo "scripts/build_tcc.sh: lib/tcc/racccoon.patch does not apply cleanly to $TCC_SRC" >&2
    exit 1
  fi
fi

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
# ONE_SOURCE / CONFIG_TCC_STATIC / CONFIG_TCC_SEMLOCK / TCC_GITHASH now
# come from tcc.c's own default and lib/tcc/config.h — the same config a
# self-host build on racccoon reads, so `tcc /src/tcc/tcc.c -o tcc2`
# needs no -D flags.
CFLAGS="-march=rv64imafdc -mabi=lp64d -mcmodel=medany -ffreestanding -fno-pic
 -fno-stack-protector -fno-builtin -Os -std=gnu11 -ffunction-sections -fdata-sections
 -nostdinc -isystem $GCCINC -I $LIBC/include -I $ROOT/lib/tcc"

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
# compiled program can #include the standard set. Plus the crt + libs a
# tcc-linked binary needs.
cp "$TCC_SRC"/include/*.h "$OUT/lib/include/" 2>/dev/null || true
cp "$LIBC"/include/*.h "$OUT/lib/include/" 2>/dev/null || true
cp -r "$LIBC"/include/sys "$LIBC"/include/racccoon "$OUT/lib/include/" 2>/dev/null || true

# crt1.o (self-maps its stack — lib/tcc/crt1.c), empty crti/crtn (our
# runtime doesn't use _init/_fini), and libracccoon.a under the name
# tcc's default `-lc` looks for.
$CC_RC $CFLAGS -c "$ROOT/lib/tcc/crt1.c" -o "$OUT/lib/crt1.o"
: | $CC_RC -x c -march=rv64imafdc -mabi=lp64d -mcmodel=medany -c - -o "$OUT/lib/crti.o"
: | $CC_RC -x c -march=rv64imafdc -mabi=lp64d -mcmodel=medany -c - -o "$OUT/lib/crtn.o"
cp build/libc/libracccoon.a "$OUT/lib/libc.a"
cp build/libc/crt0.o "$OUT/lib/crt0.o"
# same .riscv.attributes strip as the library objects (see build.sh)
for o in crt0.o crt1.o crti.o crtn.o; do
  $OBJCOPY_RC --remove-section=.riscv.attributes --remove-section=.comment "$OUT/lib/$o" 2>/dev/null || true
done

# libtcc1.a — the target runtime helpers (soft 128-bit float, __va_arg,
# bounds of __divdi3 etc., alloca). Built with the cross gcc rather than
# tcc itself: lib/lib-arm64.c (misnamed — it's the arm64/riscv64 soft-
# float + varargs file) + libtcc1.c + a few small ones. armflush.c is
# skipped (its __riscv branch calls a tcc builtin, __riscv64_clear_cache,
# that gcc can't compile) — lib/tcc/rvflush.c provides __clear_cache
# instead.
LT1="$OUT/lib_obj"; mkdir -p "$LT1"; rm -f "$LT1"/*.o
LT1_SRC="lib-arm64.c libtcc1.c stdatomic.c builtin.c dsohandle.c"
ok=1
for s in $LT1_SRC; do
  [ -f "$TCC_SRC/lib/$s" ] || continue
  $CC_RC $CFLAGS -c "$TCC_SRC/lib/$s" -o "$LT1/${s%.c}.o" 2>/dev/null || ok=0
done
$CC_RC $CFLAGS -c "$ROOT/lib/tcc/rvflush.c" -o "$LT1/rvflush.o" || ok=0
for o in "$LT1"/*.o; do
  $OBJCOPY_RC --remove-section=.riscv.attributes --remove-section=.comment "$o" 2>/dev/null || true
done
if [ "$ok" = 1 ] && ls "$LT1"/*.o >/dev/null 2>&1; then
  $AR_RC rcs "$OUT/lib/libtcc1.a" "$LT1"/*.o
  echo "==> Done: $OUT/lib/libtcc1.a"
else
  echo "==> libtcc1.a: partial/failed" >&2
fi

# --- self-host source subset (roadmap §7.8) -----------------------
# The files an ONE_SOURCE build of tcc.c #includes for the riscv64
# target, plus the generated config.h / tccdefs_.h, so `tcc
# /src/tcc/tcc.c ...` can rebuild tcc on racccoon itself. riscv64-link.c
# is the patched copy (ELF_START_ADDR), so tcc2's own output also loads
# at USER_BASE.
SRC="$OUT/src"
rm -rf "$SRC"; mkdir -p "$SRC"
SELF_C="tcc.c libtcc.c tcctools.c tccpp.c tccgen.c tccdbg.c tccasm.c
        tccelf.c tccrun.c riscv64-gen.c riscv64-link.c riscv64-asm.c"
SELF_H="tcc.h libtcc.h elf.h stab.h stab.def dwarf.h tcctok.h riscv64-tok.h"
for f in $SELF_C $SELF_H; do cp "$TCC_SRC/$f" "$SRC/"; done
cp "$ROOT/lib/tcc/config.h" "$SRC/config.h"
cp "$OUT/tccdefs_.h" "$SRC/tccdefs_.h"
echo "==> Done: $SRC/  ($(ls "$SRC" | wc -l) files, $(du -sh "$SRC" | cut -f1))"

echo "==> build/tcc/ ready. Seed onto an image: /bin/tcc + /lib/tcc/ + /src/tcc/"
