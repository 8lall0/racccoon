#!/bin/bash
# Renames the tamago GOOS -> racccoon across a Go source tree, turning
# usbarmory/tamago-go into a "GOOS=racccoon" fork. Run by setup_go.sh on
# a fresh tamago-go checkout, BEFORE lib/go/racccoon.patch is applied.
#
#   bash scripts/rename_goos.sh <goroot>
#
# Idempotent enough to inspect afterward; not meant to be re-run on an
# already-renamed tree. See docs/go-port-plan.md.
set -euo pipefail
GOROOT="${1:?usage: rename_goos.sh <goroot>}"
SRC="$GOROOT/src"
cd "$SRC"

IS_GIT=0
git -C "$GOROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 && IS_GIT=1

echo "== 1. rename *tamago* source files (skip _test / testdata) =="
mapfile -t files < <(find . \( -name '*tamago*.go' -o -name '*tamago*.s' -o -name '*tamago*.h' \) \
  ! -name '*_test.go' | grep -v '/testdata/' | sort)
for f in "${files[@]}"; do
  nf="$(echo "$f" | sed 's/tamago/racccoon/g')"
  if [ "$IS_GIT" = 1 ]; then git mv -f "$f" "$nf"; else mv "$f" "$nf"; fi
done
echo "   renamed ${#files[@]} files"

echo "== 2. build constraints mentioning tamago (//go:build, // +build) =="
grep -rlZ --include='*.go' --include='*.s' -e '//go:build' -e '+build' . \
  | xargs -0 grep -lZ 'tamago' \
  | xargs -0 sed -i -E '\#^(//go:build|// ?\+build)#{ s/\btamago\b/racccoon/g }'

echo "== 3. GOOS string literals — every non-test .go (all quoted \"tamago\" is the GOOS) =="
grep -rlZ '"tamago"' --include='*.go' . | grep -zvE '_test\.go|/testdata/' \
  | xargs -0 --no-run-if-empty sed -i 's/"tamago"/"racccoon"/g'
# "tamago/<arch>" tuples in cmd/dist
sed -i 's#"tamago/#"racccoon/#g' cmd/dist/build.go
# GOOS backtick literal (generated zgoos file, now renamed)
sed -i 's/`tamago`/`racccoon`/g' internal/goos/zgoos_racccoon.go

echo "== 4. identifiers: IsTamago->IsRacccoon, Htamago->Hracccoon, GOOS_tamago->GOOS_racccoon =="
grep -rlZ --include='*.go' -e 'IsTamago' -e 'Htamago' . \
  | xargs -0 sed -i 's/IsTamago/IsRacccoon/g; s/Htamago/Hracccoon/g'
sed -i 's/GOOS_tamago/GOOS_racccoon/g' runtime/asm_riscv64.s

echo "== 5. rt0 entry-point symbols in the renamed runtime asm =="
for f in runtime/rt0_racccoon_*.s runtime/sys_racccoon_*.s runtime/goos/linux_user*.s syscall/asm_racccoon_*.s; do
  [ -e "$f" ] && sed -i 's/tamago/racccoon/g' "$f"
done
# linker's list of overlay-reachable rt0 symbols
sed -i -E 's/rt0_(amd64|arm64|arm|loong64|riscv64)_tamago/rt0_\1_racccoon/g' \
  cmd/link/internal/loader/loader.go

echo "== 6. cosmetic: stale tamago in comments (not project/URL references) =="
grep -rlZ --include='*.go' -e 'GOOS=tamago' -e 'sys_tamago_' -e '\-tags tamago,' . \
  | xargs -0 --no-run-if-empty sed -i \
    's/GOOS=tamago/GOOS=racccoon/g; s/sys_tamago_/sys_racccoon_/g; s/-tags tamago,/-tags racccoon,/g'

echo
echo "== sanity =="
grep -q '"racccoon": *true' internal/syslist/syslist.go && echo "  syslist: ok"
grep -q 'IsRacccoon = 1' internal/goos/zgoos_racccoon.go && echo "  zgoos:   ok"
grep -q 'case "racccoon"' cmd/internal/objabi/head.go && echo "  objabi:  ok"
n=$(grep -rn -e '^//go:build' -e '^// +build' --include='*.go' --include='*.s' . \
  | grep 'tamago' | grep -vcE '_test\.|/testdata/' || true)
echo "  residual tamago ON a build-constraint line: $n (want 0)"
