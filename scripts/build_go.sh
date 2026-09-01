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

# A local main package (go/cmd/<name>) or a stdlib command path
# (cmd/compile, cmd/link, cmd/asm, cmd/go — for Stage 4's on-device
# toolchain). Stdlib commands still get the fsd backend + os.Args:
# racccoon_fs.go's init in the GOOSPKG overlay installs runtime/goos.FS
# for every binary.
case "$1" in
  cmd/*) PKG="$1"; NAME="go-$(basename "$1")" ;;
  *)     PKG="./cmd/$1"; NAME="$1" ;;
esac
[ -n "$1" ] || { echo "usage: build_go.sh <cmd-name | cmd/stdlib-path>"; exit 2; }

REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${2:-$REPO/build/go/$NAME.elf}"
mkdir -p "$(dirname "$OUT")"

# The os <-> fsd bridge needs runtime/goos.FSHook, added by
# lib/go/racccoon.patch. Warn if $TAMAGO's tree is unpatched.
GOROOT_SRC="$("$TAMAGO" env GOROOT 2>/dev/null)/src"
if [ -f "$GOROOT_SRC/runtime/goos/linux_user.go" ] && \
   ! grep -q "FSHook" "$GOROOT_SRC/runtime/goos/linux_user.go" 2>/dev/null; then
  echo "build_go.sh: note — \$TAMAGO tree is missing lib/go/racccoon.patch"
  echo "  (os.* -> fsd won't work; run scripts/setup_tamago.sh). Building anyway."
fi

# -s -w keeps the big Stage-4 binaries (compile ~23 MiB) under the exec cap.
cd "$REPO/go"
GOOS=tamago GOARCH=riscv64 CGO_ENABLED=0 \
GOOSPKG=racccoon.local/goport GOFLAGS=-mod=mod \
  "$TAMAGO" build \
  -ldflags "-T 0x1010000 -R 0x1000 -s -w" \
  -o "$OUT" \
  "$PKG"

echo "==> $OUT ($(stat -c%s "$OUT") bytes)"
