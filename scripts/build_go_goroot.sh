#!/bin/bash
# Assemble the on-device GOROOT skeleton for `go version` / `go env`
# (Stage 4.4 part 1, docs/go-port-plan.md). Emits build/go/goroot/ which
# scripts/build.sh seeds onto the ext2 image as /goroot.
#
# `go build` needs more here — $GOROOT/src (the stdlib closure), the
# racccoon runtime/goos overlay, and $GOROOT/pkg/tool/{compile,link,asm}
# — see the plan; not wired yet.
set -e

TAMAGO="${TAMAGO:-}"
if [ -z "$TAMAGO" ] || [ ! -x "$TAMAGO" ]; then
  echo "build_go_goroot.sh: TAMAGO unset — skipping"
  exit 0
fi
[ -x "$(dirname "$0")/../build/go/go.elf" ] 2>/dev/null || true
REPO="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$REPO/build/go/go.elf" ] || { echo "build_go_goroot.sh: build/go/go.elf missing — run build_go.sh cmd/go first"; exit 0; }

OUT="$REPO/build/go/goroot"
rm -rf "$OUT"
mkdir -p "$OUT/pkg/tool/tamago_riscv64"

# VERSION — cmd/go reads buildcfg.Version from the binary, but a few
# paths still stat $GOROOT/VERSION; keep it in sync with $TAMAGO's.
TGROOT="$("$TAMAGO" env GOROOT)"
cp "$TGROOT/VERSION" "$OUT/VERSION"

# go.env — the on-device defaults. cfg.findGOROOT reads $GOROOT/go.env
# before the process environment, so this is how racccoon's `go` gets a
# sane config with an empty environment. GOCACHE points at a real
# writable fsd dir (build.sh seeds it); GOCACHE=off is rejected by
# `go build` since Go 1.12.
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

echo "==> $OUT (VERSION=$(cat "$OUT/VERSION" | head -1), go.env $(wc -l < "$OUT/go.env") lines)"
