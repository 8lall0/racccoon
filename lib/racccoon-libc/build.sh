#!/bin/bash
#
# Builds the racccoon C library (Stage 1: crt0 + syscall stubs) into
#   build/libc/crt0.o
#   build/libc/libracccoon.a
# and — if any exist — cross-compiles test/c-src/*.c into
#   build/libc/<name>.elf
# ready for scripts/build.sh to seed onto the disk images next to /bin.
#
# Needs a bare-metal riscv64 C compiler; picks it up from CC_RC or,
# failing that, the first of a short list on PATH. rv64imafdc / lp64d /
# medany — the same ABI + code model as the c3 userspace (see
# scripts/build_user.sh).

set -e

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

CC_RC="${CC_RC:-}"
if [ -z "$CC_RC" ]; then
  for cand in riscv64-unknown-elf-gcc riscv64-elf-gcc riscv64-linux-gnu-gcc; do
    if command -v "$cand" >/dev/null 2>&1; then CC_RC="$cand"; break; fi
  done
fi
if [ -z "$CC_RC" ]; then
  echo "lib/racccoon-libc/build.sh: no riscv64 C compiler found (set CC_RC)" >&2
  echo "  — the C libc / self-hosting track is skipped; the c3 userspace is unaffected." >&2
  exit 0
fi

LD_RC="${LD_RC:-}"
if [ -z "$LD_RC" ]; then
  if command -v ld.lld >/dev/null 2>&1; then LD_RC="ld.lld"
  else LD_RC="${CC_RC%-gcc}-ld"; fi
fi
OBJCOPY_RC="${OBJCOPY_RC:-}"
if [ -z "$OBJCOPY_RC" ]; then
  if command -v llvm-objcopy >/dev/null 2>&1; then OBJCOPY_RC="llvm-objcopy"
  else OBJCOPY_RC="${CC_RC%-gcc}-objcopy"; fi
fi

CFLAGS="-march=rv64imafdc -mabi=lp64d -mcmodel=medany -ffreestanding -fno-pic
        -fno-stack-protector -fno-builtin -Os -Wall -Wextra -std=c11
        -nostdinc -isystem $($CC_RC -print-file-name=include)
        -I lib/racccoon-libc/include"

OUT="build/libc"
mkdir -p "$OUT/obj"

echo "==> C libc: $CC_RC  ($($CC_RC -dumpversion))"

# --- library ----------------------------------------------------------
for src in lib/racccoon-libc/src/*.c; do
  [ -e "$src" ] || continue
  name=$(basename "$src" .c)
  $CC_RC $CFLAGS -c "$src" -o "$OUT/obj/$name.o"
done

# crt0 (start.o) is linked explicitly by every program, not pulled from
# the archive — keep it out of the .a.
cp "$OUT/obj/start.o" "$OUT/crt0.o"
rm -f "$OUT/libracccoon.a"
ar rcs "$OUT/libracccoon.a" $(ls "$OUT"/obj/*.o | grep -v '/start\.o$')
echo "==> Done: $OUT/crt0.o $OUT/libracccoon.a"

# --- test programs --------------------------------------------------
# Linked, then flattened to a raw binary the same way scripts/
# build_user.sh does for the c3 /bin commands (.bss materialised) —
# racccoon's flat-binary exec path is simpler and better-tested than
# its ELF loader, and a C program's layout is otherwise identical.
for src in test/c-src/*.c; do
  [ -e "$src" ] || continue
  name=$(basename "$src" .c)
  $CC_RC $CFLAGS -c "$src" -o "$OUT/obj/$name.o"
  $LD_RC -T lib/racccoon-libc/racccoon-libc.ld -o "$OUT/$name.elf" \
    "$OUT/crt0.o" "$OUT/obj/$name.o" "$OUT/libracccoon.a"
  $OBJCOPY_RC --set-section-flags .bss=alloc,contents -O binary \
    "$OUT/$name.elf" "$OUT/$name.bin"
  echo "==> Done: $OUT/$name.bin"
done
