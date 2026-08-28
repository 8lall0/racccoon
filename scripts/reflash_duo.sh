#!/bin/bash
#
# End-to-end Milk-V Duo reflash, no sudo and no built SDK required:
#
#   build_duo.sh (kernel_duo.elf, production shell)
#     -> llvm-objcopy -> raw binary
#     -> scripts/make_loader2nd.py -> loader2nd_duo.bin
#     -> fiptool.py genfip --OLD_FIP <the fip.bin already on the card>
#        --LOADER_2ND <new kernel> -> fip_duo.bin
#     -> udisksctl-mount DUOBOOT, back up its fip.bin, copy the new one in
#
# --OLD_FIP reuses every non-kernel section (BL2/FSBL, MONITOR/OpenSBI,
# DDR_PARAM, CHIP_CONF) straight from the image currently on the card, so
# this needs only a *checkout* of duo-buildroot-sdk for fiptool.py itself
# — not a `build_fsbl` run, not the vendor Docker image. See
# docs/devlog.md's 2026-08-28 real-hardware entry.
#
# PATCH_OPENSBI=1 additionally rebuilds OpenSBI with the T-HEAD C900 PLIC
# S-mode delegate fix (scripts/build_opensbi_duo.sh) and swaps it in as
# the MONITOR — needed for any interrupt-driven driver on this board (the
# stock OpenSBI wedges S-mode PLIC access; see docs/devlog.md's
# "PLIC storm SOLVED" entry). Needs a riscv64-unknown-elf- toolchain.
#
# This flashes the PRODUCTION shell (user/shell.c3). For a throwaway test
# kernel with user/shell_test.c3's dev builtins, see build.sh's own
# shell-swap trick and the devlog.
#
# Keeps exactly one rollback copy on DUOBOOT: any older fip.bin.bak-* is
# pruned and this run's outgoing fip.bin is saved as
# fip.bin.bak-<timestamp> before the new one is written.
#
# Does NOT touch partitioning, EXT2TEST, or /bin on the root partition
# (that one is root-owned — `sudo DUO_ROOT_PARTITION=/dev/sdX2 bash
# scripts/populate_duo_bin.sh` if a /bin binary's source changed).
#
# Usage:
#   DUO_SD_PART=/dev/sda1 bash scripts/reflash_duo.sh
#
# Env:
#   DUO_SD_PART   the DUOBOOT FAT32 partition — REQUIRED, no default
#                 (device paths vary by machine/session; `lsblk` shows it,
#                 labelled DUOBOOT)
#   FIPTOOL       path to fiptool.py — default derived from $DUO_SDK, then
#                 ~/Workspace/duo-buildroot-sdk
#   LLVM_LLD / LLC / LLVM_OBJCOPY  passed through to build_duo.sh; on a
#                 host without /opt/riscv set these to /usr/bin/*

set -e

DUO_SD_PART=${DUO_SD_PART:?set DUO_SD_PART to the DUOBOOT FAT32 partition, e.g. /dev/sda1 — no default}
LLVM_OBJCOPY=${LLVM_OBJCOPY:-llvm-objcopy}

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# --- locate fiptool.py ----------------------------------------------------
if [ -z "${FIPTOOL:-}" ]; then
  for cand in \
    "${DUO_SDK:-}/fsbl/plat/cv180x/fiptool.py" \
    "$HOME/Workspace/duo-buildroot-sdk/fsbl/plat/cv180x/fiptool.py" \
    "$HOME/Workspace/duo-buildroot-sdk/fsbl/plat/cv181x/fiptool.py"; do
    [ -n "$cand" ] && [ -f "$cand" ] && FIPTOOL="$cand" && break
  done
fi
[ -n "${FIPTOOL:-}" ] && [ -f "$FIPTOOL" ] || {
  echo "fiptool.py not found — set FIPTOOL=/path/to/duo-buildroot-sdk/fsbl/plat/cv180x/fiptool.py" >&2
  exit 1
}
echo "==> fiptool: $FIPTOOL"

# --- build the kernel ---------------------------------------------------
bash scripts/build_duo.sh

echo "==> Extracting raw binary from kernel_duo.elf..."
$LLVM_OBJCOPY -O binary build/kernel_duo.elf build/kernel_duo_raw.bin

echo "==> Prepending the 32-byte LOADER_2ND (\"BL33\") header..."
python3 scripts/make_loader2nd.py build/kernel_duo_raw.bin build/loader2nd_duo.bin

# --- mount DUOBOOT ----------------------------------------------------
udisksctl mount -b "$DUO_SD_PART" >/dev/null 2>&1 || true
MNT=$(findmnt -n -o TARGET --source "$DUO_SD_PART" | head -1)
[ -n "$MNT" ] || { echo "could not mount $DUO_SD_PART" >&2; exit 1; }
echo "==> DUOBOOT mounted at $MNT"
[ -f "$MNT/fip.bin" ] || { echo "$MNT/fip.bin missing — is $DUO_SD_PART really DUOBOOT?" >&2; exit 1; }

# --- repackage via --OLD_FIP ----------------------------------------
cp "$MNT/fip.bin" build/fip_old_from_sd.bin

MONITOR_ARGS=()
if [ "${PATCH_OPENSBI:-0}" = "1" ]; then
  echo "==> PATCH_OPENSBI=1 — rebuilding OpenSBI with the T-HEAD PLIC delegate fix..."
  FIP="$ROOT/build/fip_old_from_sd.bin" bash scripts/build_opensbi_duo.sh
  MONITOR_ARGS=(--MONITOR "$ROOT/build/fw_dynamic_patched.bin")
fi

echo "==> Repackaging fip.bin (reusing BL2/DDR_PARAM/CHIP_CONF from the card${PATCH_OPENSBI:+, patched OpenSBI})..."
python3 "$FIPTOOL" genfip \
  "$ROOT/build/fip_duo.bin" \
  --OLD_FIP "$ROOT/build/fip_old_from_sd.bin" \
  "${MONITOR_ARGS[@]}" \
  --MONITOR_RUNADDR=0x80000000 \
  --BLCP_2ND_RUNADDR=0 \
  --LOADER_2ND="$ROOT/build/loader2nd_duo.bin" >/dev/null

# --- verify -----------------------------------------------------------
python3 - "$FIPTOOL" <<'PYEOF'
import sys, os
sys.path.insert(0, os.path.dirname(sys.argv[1]))
import fiptool
f = fiptool.FIP()
f.read_fip("build/fip_duo.bin")
runaddr = f.ldr_2nd_hdr["RUNADDR"].toint()
magic = bytes(f.ldr_2nd_hdr["MAGIC"].content)
mon = f.param2["MONITOR_RUNADDR"].toint()
rest = len(getattr(f, "rest_fip", b""))
ok = runaddr == 0x80200000 and magic == b"BL33" and mon == 0x80000000 and rest == 0
monitor = bytes(f.body2["MONITOR"].content)
has_fdt = monitor.find(bytes.fromhex("d00dfeed")) >= 0
print(f"    LOADER_2ND magic={magic!r} runaddr={runaddr:#x}  MONITOR runaddr={mon:#x} ({len(monitor)} B, embedded-FDT={has_fdt})  trailing={rest}")
if os.environ.get("PATCH_OPENSBI") == "1" and not has_fdt:
    print("    ERROR: PATCH_OPENSBI=1 but MONITOR has no embedded FDT — OpenSBI build did not take", file=sys.stderr)
    sys.exit(1)
l2 = open("build/loader2nd_duo.bin", "rb").read()
sec = bytes(f.body2["LOADER_2ND"].content)
if l2[32:] != sec[32:32 + len(l2) - 32]:
    print("    ERROR: LOADER_2ND body does not match loader2nd_duo.bin", file=sys.stderr)
    sys.exit(1)
if not ok:
    print("    ERROR: fip sanity check failed", file=sys.stderr)
    sys.exit(1)
print("    fip_duo.bin verified")
PYEOF

# --- flash ----------------------------------------------------------
# Keep exactly one rollback copy: drop any older fip.bin.bak-* before
# writing this run's. `back up the outgoing kernel, then flash` still
# holds — the copy is made from the current fip.bin, which is only
# overwritten after.
shopt -s nullglob
for old in "$MNT"/fip.bin.bak-*; do rm -f "$old"; done
shopt -u nullglob
BAK="$MNT/fip.bin.bak-$(date +%Y%m%d-%H%M%S)"
echo "==> Backing up current fip.bin -> $(basename "$BAK") (older backups pruned)"
cp "$MNT/fip.bin" "$BAK"
echo "==> Copying build/fip_duo.bin -> $MNT/fip.bin"
cp build/fip_duo.bin "$MNT/fip.bin"
sync
udisksctl unmount -b "$DUO_SD_PART" >/dev/null 2>&1 || umount "$MNT" 2>/dev/null || true

echo "==> Done. Move the SD to the Duo and power-cycle."
echo "    (restore $(basename "$BAK") over fip.bin if it doesn't boot)"
