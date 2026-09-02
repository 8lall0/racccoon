#!/bin/bash
# One-time setup of the racccoon Go toolchain: clone the version-matched
# usbarmory/tamago-go branch, rename its GOOS tamago -> racccoon
# (scripts/rename_goos.sh), apply lib/go/racccoon.patch (the os <-> fsd
# bridge + linker defaults), and build it. Prints the TAMAGO export line
# to use with scripts/build_go.sh afterward. See docs/go-port-plan.md.
#
#   bash scripts/setup_go.sh [dest-dir]   (default: ./third_party/tamago-go)
#
# The env var is still called TAMAGO (it points at the built go binary);
# the toolchain it names is now GOOS=racccoon, forked from tamago-go.
set -e

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:-$REPO/third_party/tamago-go}"
BRANCH="tamago1.27.0"   # match the host's `go` (go1.27.0); bump both together
PATCH="$REPO/lib/go/racccoon.patch"

FRESH=0
if [ ! -d "$DEST/.git" ]; then
  echo "==> cloning $BRANCH into $DEST"
  git clone --depth 1 --branch "$BRANCH" https://github.com/usbarmory/tamago-go "$DEST"
  FRESH=1
fi

cd "$DEST"

if [ "$FRESH" = 1 ] || ! grep -q '"racccoon"' src/internal/syslist/syslist.go 2>/dev/null; then
  echo "==> renaming GOOS tamago -> racccoon"
  bash "$REPO/scripts/rename_goos.sh" "$DEST"
fi

if git apply --reverse --check "$PATCH" 2>/dev/null; then
  echo "==> lib/go/racccoon.patch already applied"
elif git apply --check "$PATCH" 2>/dev/null; then
  git apply "$PATCH"
  echo "==> applied lib/go/racccoon.patch"
else
  echo "setup_go.sh: lib/go/racccoon.patch does not apply cleanly to $DEST" >&2
  echo "  (branch mismatch, or rename_goos.sh out of sync with the patch)" >&2
  exit 1
fi

echo "==> building the toolchain (src/make.bash)"
( cd src && GOOS=linux GOARCH=amd64 ./make.bash )

echo
echo "Done. Use it with:"
echo "  export TAMAGO=$DEST/bin/go"
echo "  bash scripts/build_go.sh hello"
