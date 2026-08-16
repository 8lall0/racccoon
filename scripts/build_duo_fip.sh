#!/bin/bash
#
# Packages build/kernel_duo.elf (from scripts/build_duo.sh) into a real
# flashable fip.bin, using a prebuilt duo-buildroot-sdk checkout for the
# pieces racccoon doesn't build itself: OpenSBI (MONITOR, fw_dynamic.bin)
# and FSBL (BL2, bl2.bin). Racccoon's own kernel replaces the LOADER_2ND
# ("BL33") slot that vendor images use for U-Boot.
#
# Prerequisites (not automated here — see docs/devlog.md for the full
# trace of getting this SDK to build at all, including a real vendor
# Kconfig bug and a corrupted host-tools checkout that both had to be
# fixed first):
#   - $DUO_SDK points at a duo-buildroot-sdk checkout where
#     `source build/envsetup_milkv.sh milkv-duo-sd && build_fsbl` has
#     already succeeded (needs the vendor's milkvtech/milkv-duo Docker
#     image — the host-tools cross toolchain and this SDK's own
#     kconfig-frontend are both too finicky about host GCC/Kconfig
#     versions to build natively).
#   - build/kernel_duo.elf exists (bash scripts/build_duo.sh).

set -e

LLVM_OBJCOPY=${LLVM_OBJCOPY:-llvm-objcopy}
DUO_SDK=${DUO_SDK:?set DUO_SDK to a duo-buildroot-sdk checkout with build_fsbl already run}

(
  cd "$(dirname "$0")/.."

  MONITOR="$DUO_SDK/opensbi/build/platform/generic/firmware/fw_dynamic.bin"
  BL2="$DUO_SDK/fsbl/build/cv1800b_milkv_duo_sd/bl2.bin"
  CHIP_CONF="$DUO_SDK/fsbl/build/cv1800b_milkv_duo_sd/chip_conf.bin"
  DDR_PARAM="$DUO_SDK/fsbl/test/cv181x/ddr_param.bin"
  EMPTY="$DUO_SDK/fsbl/test/empty.bin"
  FIPTOOL="$DUO_SDK/fsbl/plat/cv180x/fiptool.py"

  for f in "$MONITOR" "$BL2" "$CHIP_CONF" "$DDR_PARAM" "$EMPTY" "$FIPTOOL"; do
    if [ ! -f "$f" ]; then
      echo "missing $f — run build_fsbl in \$DUO_SDK first (see this script's header comment)" >&2
      exit 1
    fi
  done

  echo "==> Extracting raw binary from kernel_duo.elf..."
  $LLVM_OBJCOPY -O binary build/kernel_duo.elf build/kernel_duo_raw.bin

  echo "==> Prepending the 32-byte LOADER_2ND (\"BL33\") header..."
  python3 scripts/make_loader2nd.py build/kernel_duo_raw.bin build/loader2nd_duo.bin

  echo "==> Packaging fip_duo.bin via fiptool.py..."
  python3 "$FIPTOOL" -v genfip \
    "$(pwd)/build/fip_duo.bin" \
    --MONITOR_RUNADDR=0x80000000 \
    --BLCP_2ND_RUNADDR=0 \
    --CHIP_CONF="$CHIP_CONF" \
    --NOR_INFO=FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF \
    --NAND_INFO=00000000 \
    --BL2="$BL2" \
    --BLCP_IMG_RUNADDR=0x05200200 \
    --BLCP_PARAM_LOADADDR=0 \
    --BLCP="$EMPTY" \
    --DDR_PARAM="$DDR_PARAM" \
    --BLCP_2ND="$EMPTY" \
    --MONITOR="$MONITOR" \
    --LOADER_2ND="$(pwd)/build/loader2nd_duo.bin"

  echo "==> Done: build/fip_duo.bin"
)
