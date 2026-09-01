#!/bin/bash
# Builds a Go program for racccoon and emits a static riscv64 ELF the
# racccoon exec path loads. See docs/go-port-plan.md.
#
# GOOS=tamago + the runtime/goos provider in go/ (GOOSPKG), linked so
# every PT_LOAD segment sits inside [USER_BASE, USER_BASE + 4 MiB):
#   -T 0x1010000  text start (USER_BASE + 64 KiB, headers land at USER_BASE)
#   -R 0x1000     segment rounding = page size, so -T's file offsets stay sane
#
# Programs live as main packages under go/cmd/<name>/. Usage:
#   TAMAGO=/path/to/tamago-go/bin/go bash scripts/build_go.sh hello
# Needs the tamago-go toolchain (branch tamago1.27.0, matches the
# installed Go 1.27.0): git clone -b tamago1.27.0, cd src && ./make.bash.
# No-op with a friendly message if TAMAGO is unset — same convention as
# scripts/build_opi.sh.
set -e

TAMAGO="${TAMAGO:-}"
if [ -z "$TAMAGO" ] || [ ! -x "$TAMAGO" ]; then
  echo "build_go.sh: set TAMAGO=/path/to/tamago-go/bin/go (branch tamago1.27.0) — skipping"
  exit 0
fi

NAME="${1:?usage: build_go.sh <cmd-name>   (a package under go/cmd/)}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${2:-$REPO/build/go/$NAME.elf}"
mkdir -p "$(dirname "$OUT")"

cd "$REPO/go"
GOOS=tamago GOARCH=riscv64 CGO_ENABLED=0 \
GOOSPKG=racccoon.local/goport \
  "$TAMAGO" build \
  -ldflags "-T 0x1010000 -R 0x1000" \
  -o "$OUT" \
  "./cmd/$NAME"

echo "==> $OUT ($(stat -c%s "$OUT") bytes)"
