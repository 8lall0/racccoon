#!/bin/bash
# Builds a Go program for racccoon: GOOS=tamago GOARCH=riscv64 + the
# GOOSPKG provider in go/, linked at USER_BASE, emitted as a static
# ELF the racccoon exec path loads. See docs/go-port-plan.md.
#
# STAGE 0 SCAFFOLD — the exact GOOSPKG / go.work wiring and the
# -ldflags are a Stage 1 line item; this is the shape, not a working
# build yet.
#
# Needs the tamago-go toolchain (branch tamago1.27.0, matches the
# installed Go 1.27.0). Point TAMAGO at its bin/go. No-op with a
# friendly message otherwise — same convention as scripts/build_opi.sh.
set -e

TAMAGO="${TAMAGO:-}"
if [ -z "$TAMAGO" ] || [ ! -x "$TAMAGO" ]; then
  echo "build_go.sh: set TAMAGO=/path/to/tamago-go/bin/go (branch tamago1.27.0) — skipping"
  exit 0
fi

SRC="${1:?usage: build_go.sh <prog.go> [out.elf]}"
OUT="${2:-build/go/$(basename "${SRC%.go}").elf}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$(dirname "$OUT")"

# USER_BASE = 0x1000000 (src/kernel.c3). The tamago rt0 entry is
# _rt0_riscv64_tamago; CPUInit (go/goos/racccoon_riscv64.s) takes it
# from there.
GOOS=tamago GOARCH=riscv64 CGO_ENABLED=0 \
GOOSPKG=racccoon.local/goport \
GOFLAGS=-mod=mod \
  "$TAMAGO" build \
  -C "$REPO/go" \
  -ldflags "-T 0x1000000" \
  -o "$OUT" \
  "$SRC"

echo "==> $OUT"
"$TAMAGO" tool nm "$OUT" | grep -q _rt0_riscv64_tamago && echo "    (rt0 present)"
