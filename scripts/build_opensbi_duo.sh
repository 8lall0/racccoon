#!/bin/bash
#
# Build a patched OpenSBI for the Milk-V Duo (CV1800B) — the ONE change
# is the T-HEAD C900 PLIC S-mode-access delegate write that the stock
# Milk-V OpenSBI v0.9 never does (see scripts/opensbi-thead-plic-delegate.patch
# and docs/devlog.md's 2026-08-28 "PLIC storm SOLVED" entry). Without it,
# arming any PLIC source from S-mode wedges the CPU in a permanent
# interrupt storm; with it, interrupt-driven drivers work.
#
# Output: build/fw_dynamic_patched.bin  (embed it as the fip MONITOR;
# reflash_duo.sh does this automatically when PATCH_OPENSBI=1).
#
# The Duo devicetree is extracted verbatim from the MONITOR section of a
# known-good fip (the stock Milk-V OpenSBI carries it embedded) so the
# rebuilt firmware sees exactly the same DT the working one did — no
# dtc/cpp of the SDK dts sources needed.
#
# Usage:
#   FIP=build/fip_old_from_sd.bin bash scripts/build_opensbi_duo.sh
#
# Env:
#   FIP        a fip.bin to lift the embedded Duo DTB out of — REQUIRED
#              (reflash_duo.sh passes the one it just copied off the card)
#   DUO_SDK    duo-buildroot-sdk checkout (has opensbi/ + fiptool.py);
#              default ~/Workspace/duo-buildroot-sdk
#   CROSS_COMPILE   riscv64 bare-metal prefix; default riscv64-unknown-elf-

set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FIP=${FIP:?set FIP to a known-good fip.bin to lift the Duo DTB from}
DUO_SDK=${DUO_SDK:-$HOME/Workspace/duo-buildroot-sdk}
CROSS_COMPILE=${CROSS_COMPILE:-riscv64-unknown-elf-}

OPENSBI_DIR="$DUO_SDK/opensbi"
FIPTOOL="$DUO_SDK/fsbl/plat/cv180x/fiptool.py"
[ -d "$OPENSBI_DIR" ] || { echo "no opensbi at $OPENSBI_DIR — set DUO_SDK" >&2; exit 1; }
[ -f "$FIPTOOL" ]     || { echo "no fiptool at $FIPTOOL" >&2; exit 1; }
command -v "${CROSS_COMPILE}gcc" >/dev/null || { echo "${CROSS_COMPILE}gcc not found — set CROSS_COMPILE" >&2; exit 1; }

# --- apply the patch (idempotent) -------------------------------------
echo "==> Applying opensbi-thead-plic-delegate.patch (if not already)..."
if git -C "$DUO_SDK" apply --reverse --check "$ROOT/scripts/opensbi-thead-plic-delegate.patch" >/dev/null 2>&1; then
  echo "    already applied"
else
  git -C "$DUO_SDK" apply "$ROOT/scripts/opensbi-thead-plic-delegate.patch"
  echo "    applied"
fi

# --- lift the Duo DTB out of the fip's MONITOR -----------------------
echo "==> Extracting the embedded Duo DTB from $FIP ..."
python3 - "$FIPTOOL" "$FIP" "$ROOT/build/duo.dtb" <<'PYEOF'
import sys, os, struct
sys.path.insert(0, os.path.dirname(sys.argv[1]))
import fiptool
f = fiptool.FIP(); f.read_fip(sys.argv[2])
m = bytes(f.body2["MONITOR"].content)
i = m.find(bytes.fromhex("d00dfeed"))
if i < 0:
    sys.exit("no embedded FDT (d00dfeed) in that fip's MONITOR — pass a stock/known-good fip")
size = struct.unpack(">I", m[i+4:i+8])[0]
open(sys.argv[3], "wb").write(m[i:i+size])
print(f"    wrote build/duo.dtb ({size} bytes)")
PYEOF

# --- build ----------------------------------------------------------
echo "==> Building OpenSBI (PLATFORM=generic, FW_FDT embedded)..."
make -C "$OPENSBI_DIR" distclean >/dev/null 2>&1 || true
make -C "$OPENSBI_DIR" -j"$(nproc)" \
  PLATFORM=generic \
  CROSS_COMPILE="$CROSS_COMPILE" \
  PLATFORM_RISCV_ISA=rv64imafdc_zicsr_zifencei \
  FW_PIC=n \
  FW_FDT_PATH="$ROOT/build/duo.dtb" \
  >/dev/null

cp "$OPENSBI_DIR/build/platform/generic/firmware/fw_dynamic.bin" "$ROOT/build/fw_dynamic_patched.bin"

python3 - <<'PYEOF'
m = open("build/fw_dynamic_patched.bin", "rb").read()
fdt = m.find(bytes.fromhex("d00dfeed"))
assert fdt >= 0, "built firmware has no embedded FDT"
print(f"==> build/fw_dynamic_patched.bin  ({len(m)} bytes, FDT @ {fdt})")
PYEOF
