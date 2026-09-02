#!/bin/bash
# Stage 4.3 groundwork (docs/go-port-plan.md): prepares everything
# scripts/build.sh needs to seed racccoon's own `go tool compile` +
# `go tool link` onto the ext2 image, plus the stdlib object closure
# those tools need to link a real program.
#
# The closure (runtime + ~27 internal/* packages) is captured from a
# real `go build -work` of go/cmd/hello on the HOST tamago-go
# toolchain — this is the normal, expected way to bootstrap a
# self-hosting toolchain (same idea as lib/tcc's prebuilt crt1.o /
# libtcc1.a): cross-built support objects, not something racccoon's
# own compiler needs to produce from scratch. What Stage 4.3 tests is
# whether `go tool link`, running natively ON racccoon, can correctly
# consume that closure and racccoon-compiled main-package code to
# produce a working ELF — that's the genuinely new, untested part.
#
# Output (consumed by scripts/build.sh, gated on $TAMAGO like the rest
# of the Go port):
#   build/go/toolchain/pkg/<sanitized-import-path>.a   the closure objects
#   build/go/toolchain/importcfg                       compile-time cfg for go/cmd/hello (racccoon paths)
#   build/go/toolchain/importcfg.link                  link-time cfg, every package (racccoon paths)
#   build/go/toolchain/hello.go                         the source to compile on-device (go/cmd/hello/main.go)
set -e

TAMAGO="${TAMAGO:-}"
if [ -z "$TAMAGO" ] || [ ! -x "$TAMAGO" ]; then
  echo "build_go_toolchain.sh: set TAMAGO=/path/to/tamago-go/bin/go — skipping"
  exit 0
fi

REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$REPO/build/go/toolchain"
rm -rf "$OUT"
mkdir -p "$OUT/pkg"

# On-device paths these files will be seeded at (scripts/build.sh) —
# baked into the importcfg files now so they don't need rewriting again
# at seed time.
DEV_PKG_DIR="/lib/go/pkg"

WORK_PARENT="$(mktemp -d)"
trap 'rm -rf "$WORK_PARENT"' EXIT

echo "==> Capturing go/cmd/hello's stdlib closure (host go build -work)..."
# -a forces every package (including the top one) to actually recompile
# in this invocation, not just relink from the host's build cache — a
# cache hit skips the compile action entirely, and with it the
# per-package importcfg file this script reads below.
BUILD_LOG="$WORK_PARENT/build.log"
( cd "$REPO/go" && \
  GOOS=racccoon GOARCH=riscv64 GOOSPKG=racccoon.local/goport GOFLAGS=-mod=mod \
  TMPDIR="$WORK_PARENT" \
  "$TAMAGO" build -a -work -o "$WORK_PARENT/hello.elf" \
    -ldflags "-T 0x1010000 -R 0x1000" ./cmd/hello \
) > "$BUILD_LOG" 2>&1
WORK="$(grep -m1 '^WORK=' "$BUILD_LOG" | cut -d= -f2-)"
if [ -z "$WORK" ] || [ ! -d "$WORK" ]; then
  echo "build_go_toolchain.sh: couldn't find the -work directory:" >&2
  cat "$BUILD_LOG" >&2
  exit 1
fi

LINKCFG="$WORK/b001/importcfg.link"
COMPILECFG="$WORK/b001/importcfg"
[ -f "$LINKCFG" ] || { echo "build_go_toolchain.sh: no $LINKCFG" >&2; exit 1; }

# Sanitize an import path into a flat filename: internal/runtime/gc ->
# internal_runtime_gc.a
sanitize() { echo "$1" | tr '/' '_'; }

# The fixed path scripts/build.sh's gostage4toolchaintest (shell_test.c3)
# compiles go/cmd/hello's source to on-device, before running go-link
# against this same importcfg.link — baked in here so no on-device text
# munging is needed.
DEV_MAIN_OBJ="/tmp/hello.o"

echo "==> Copying the closure ($(grep -c '^packagefile' "$LINKCFG") packages) + rewriting importcfg..."
: > "$OUT/importcfg.link"
while IFS= read -r line; do
  case "$line" in
    packagefile*)
      pkg="${line#packagefile }"; pkg="${pkg%%=*}"
      src="${line#*=}"
      # The top package (racccoon.local/goport/cmd/hello) is compiled
      # on-device from source, not copied — point its importcfg.link
      # entry at the fixed path the on-device compile step writes to.
      if [ "$pkg" = "racccoon.local/goport/cmd/hello" ]; then
        echo "packagefile $pkg=$DEV_MAIN_OBJ" >> "$OUT/importcfg.link"
        continue
      fi
      base="$(sanitize "$pkg").a"
      cp "$src" "$OUT/pkg/$base"
      echo "packagefile $pkg=$DEV_PKG_DIR/$base" >> "$OUT/importcfg.link"
      ;;
    *) echo "$line" >> "$OUT/importcfg.link" ;;
  esac
done < "$LINKCFG"

# Compile-time importcfg for go/cmd/hello itself (what `compile` needs
# to type-check hello.go — just its own direct imports, here just
# "runtime", implicitly required by every Go program).
: > "$OUT/importcfg"
while IFS= read -r line; do
  case "$line" in
    packagefile*)
      pkg="${line#packagefile }"; pkg="${pkg%%=*}"
      base="$(sanitize "$pkg").a"
      echo "packagefile $pkg=$DEV_PKG_DIR/$base" >> "$OUT/importcfg"
      ;;
    *) echo "$line" >> "$OUT/importcfg" ;;
  esac
done < "$COMPILECFG"

cp "$REPO/go/cmd/hello/main.go" "$OUT/hello.go"

du -sh "$OUT" | sed 's/^/==> toolchain closure: /'
echo "==> Done: $OUT (importcfg, importcfg.link, pkg/*.a, hello.go)"
