#!/bin/bash
# Assemble the on-device GOROOT for `go build` (Stage 4.4,
# docs/go-port-plan.md). Emits build/go/goroot/ + build/go/gocache/,
# which scripts/build.sh seeds onto the ext2 image as /goroot + /gocache.
#
# `go build` on racccoon: the stdlib closure comes from a prepopulated
# build cache (same bootstrapping idea as lib/tcc's prebuilt crt1.o —
# a host build with the exact same cross-toolchain produces cache
# entries whose content-hash keys the on-device build hits), so only
# `runtime`, `runtime/goos` and the user's `main` compile on-device,
# then link. cmd/link defaults -T/-R for tamago (lib/go/racccoon.patch)
# so a bare `go build` produces a racccoon-loadable ELF.
set -e

TAMAGO="${TAMAGO:-}"
if [ -z "$TAMAGO" ] || [ ! -x "$TAMAGO" ]; then
  echo "build_go_goroot.sh: TAMAGO unset — skipping"
  exit 0
fi
REPO="$(cd "$(dirname "$0")/.." && pwd)"
for b in go compile link asm; do
  [ -f "$REPO/build/go/$b.elf" ] || { echo "build_go_goroot.sh: build/go/$b.elf missing — run build_go.sh cmd/$b first"; exit 0; }
done

TGROOT="$("$TAMAGO" env GOROOT)"
TGSRC="$TGROOT/src"
OUT="$REPO/build/go/goroot"
CACHE="$REPO/build/go/gocache"
rm -rf "$OUT" "$CACHE"
mkdir -p "$OUT/pkg/tool/tamago_riscv64" "$OUT/pkg/include" "$OUT/src/runtime/goos"

cp "$TGROOT/VERSION" "$OUT/VERSION"

# go.env — cfg.findGOROOT reads it before the (empty) process env, so
# it's how racccoon's `go` gets a working config. GOCACHE/GOMODCACHE
# point at real writable fsd dirs (build.sh seeds them); GOCACHE=off is
# rejected by `go build` since Go 1.12.
cat > "$OUT/go.env" <<'EOF'
GOFLAGS=-mod=mod
GOPROXY=off
GOSUMDB=off
GOTOOLCHAIN=local
GOCACHE=/gocache
GOMODCACHE=/gomodcache
GOTMPDIR=/tmp
GO111MODULE=on
CGO_ENABLED=0
EOF

cp "$REPO/build/go/compile.elf" "$OUT/pkg/tool/tamago_riscv64/compile"
cp "$REPO/build/go/link.elf"    "$OUT/pkg/tool/tamago_riscv64/link"
cp "$REPO/build/go/asm.elf"     "$OUT/pkg/tool/tamago_riscv64/asm"

# assembly #include headers
cp "$TGROOT"/pkg/include/*.h "$OUT/pkg/include/" 2>/dev/null || true
mkdir -p "$OUT/src/runtime/cgo"
cp "$TGSRC"/runtime/cgo/*.h "$OUT/src/runtime/cgo/" 2>/dev/null || true

# $GOROOT/src — the dependency closure of a trivial `main` (from the
# PATCHED tamago tree, so syscall/os/runtime are racccoon-aware), minus
# test files. runtime/goos is the racccoon overlay, not the vanilla
# linux_user.go.
DEPS="$(cd "$REPO/go" && GOOS=tamago GOARCH=riscv64 CGO_ENABLED=0 \
  GOOSPKG=racccoon.local/goport GOFLAGS=-mod=mod \
  "$TAMAGO" list -deps ./cmd/hello 2>/dev/null | grep -v 'racccoon.local/goport')"
DEPS="$DEPS internal/goexperiment internal/buildcfg go/build/constraint"
for pkg in $DEPS; do
  [ "$pkg" = "runtime/goos" ] && continue
  [ -d "$TGSRC/$pkg" ] || continue
  mkdir -p "$OUT/src/$pkg"
  for f in "$TGSRC/$pkg"/*.go "$TGSRC/$pkg"/*.s "$TGSRC/$pkg"/*.h; do
    [ -e "$f" ] || continue
    case "$(basename "$f")" in *_test.go|*_test.s) continue ;; esac
    cp "$f" "$OUT/src/$pkg/"
  done
done
cp "$REPO"/go/goos/*.go "$REPO"/go/goos/*.s "$OUT/src/runtime/goos/"

# Prepopulated build cache — a host build of the same trivial main with
# the same toolchain. -trimpath keeps the stdlib cache keys
# machine-independent so the on-device build hits them.
mkdir -p "$CACHE"
( cd "$REPO/go" && GOOS=tamago GOARCH=riscv64 CGO_ENABLED=0 \
  GOOSPKG=racccoon.local/goport GOFLAGS=-mod=mod GOCACHE="$CACHE" \
  "$TAMAGO" build -trimpath -o /dev/null ./cmd/hello ) 2>/dev/null || \
  echo "build_go_goroot.sh: host cache-prime build failed (go build on-device will be slow)"

echo "==> $OUT ($(du -sh "$OUT" | cut -f1)) + $CACHE ($(du -sh "$CACHE" | cut -f1))"
