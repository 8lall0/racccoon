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
# for every binary. NAME is bare either way (build.sh's own seed loops
# add the "go-" /bin prefix — cmd/compile -> bin/go-compile, not
# bin/go-go-compile).
case "$1" in
  cmd/*) PKG="$1"; NAME="$(basename "$1")" ;;
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
# cmd/go: bake the on-device GOROOT (Stage 4.4, docs/go-port-plan.md).
# runtime.GOROOT() falls back to this when os.Executable()-based
# detection fails (it does on racccoon), and cfg.findGOROOT returns it;
# then $GOROOT/go.env supplies GOFLAGS / GOPROXY / GOCACHE / etc.
EXTRA_LDFLAGS=""
BUILD_TAGS=""
case "$1" in
  cmd/go)
    EXTRA_LDFLAGS="-X runtime.defaultGOROOT=/goroot" ;;
  cmd/compile|cmd/link)
    # these peak far past the default 64 MiB Go arena compiling package
    # runtime on-device (racccoon_heap_big.go). Lazy SYS_MAP
    # (docs/devlog.md) makes the 448 MiB arena free until touched, and
    # src/kernel.ld's pool is 1792 MiB, so it fits comfortably alongside
    # `go`. `go` / `asm` stay on the default 64 MiB heap (historically
    # enough for the driver + assembler).
    BUILD_TAGS="racccoon_bigheap" ;;
esac

cd "$REPO/go"
GOOS=tamago GOARCH=riscv64 CGO_ENABLED=0 \
GOOSPKG=racccoon.local/goport GOFLAGS=-mod=mod \
  "$TAMAGO" build \
  ${BUILD_TAGS:+-tags "$BUILD_TAGS"} \
  -ldflags "-T 0x1010000 -R 0x1000 -s -w $EXTRA_LDFLAGS" \
  -o "$OUT" \
  "$PKG"

echo "==> $OUT ($(stat -c%s "$OUT") bytes)"
