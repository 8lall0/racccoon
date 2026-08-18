#!/bin/bash

set -e

LLVM_LLD=${LLVM_LLD:-/opt/riscv/bin/ld.lld}
LLC=${LLC:-llc}

(
  cd "$(dirname "$0")/.."

  # Build user app first (produces build/user/shell.bin.o)
  bash scripts/build_user.sh

  echo "==> Building disk image (FAT32)..."
  # user/fsd.c3 now reads a real FAT32 filesystem (see docs/devlog.md),
  # not the tar format this used to build. Whole-disk FAT32 (no MBR/
  # partition table, board::FS_PARTITION_START_SECTOR=0 for QEMU — see
  # boards/qemu/board.c3) — the simplest thing mkfs.vfat can produce.
  # `-F 32` forces FAT32 specifically: dosfstools defaults to FAT16 below
  # its own size threshold, and fsd.c3 only parses the FAT32 BPB layout.
  # mtools' mcopy writes into the image directly, no root/loop-mount
  # needed. 64M comfortably clears FAT32's own minimum practical size.
  rm -f build/disk.img
  dd if=/dev/zero of=build/disk.img bs=1M count=64 status=none
  mkfs.vfat -F 32 build/disk.img > /dev/null
  mcopy -i build/disk.img disk/*.txt ::

  echo "==> Building disk image (ext2, for scripts/launch64_ext2.sh)..."
  # Additional, not a replacement — build/disk.img (FAT32) above stays
  # the default image every other script/test uses. This one exists
  # purely to exercise user/fs/ext2.c3 on QEMU (see docs/devlog.md's
  # filesystem-abstraction entry): a whole-disk ext2 volume (no MBR,
  # same reasoning as the FAT32 image above), seeded via `debugfs -w`
  # (part of e2fsprogs) rather than a loop-mount, so this needs no root
  # either. `-b 1024` keeps the block size comfortably under
  # user/fs/ext2.c3's own EXT2_MAX_BLOCK_SIZE — not required for
  # correctness on a small image (mke2fs would pick 1024 by default
  # here anyway), just explicit. Reuses the name "hello.txt" (with
  # distinct content from disk/hello.txt) so the shell's existing
  # readfile command exercises either filesystem unchanged.
  rm -f build/disk_ext2.img
  dd if=/dev/zero of=build/disk_ext2.img bs=1M count=16 status=none
  mke2fs -q -F -b 1024 build/disk_ext2.img
  debugfs -w -R "write disk-ext2/hello.txt hello.txt" build/disk_ext2.img > /dev/null

  echo "==> Building disk image (dual FAT32+ext2, for scripts/launch64_dual.sh)..."
  # Third test image — exercises fsd/fsd2 mounting two filesystems at once
  # (see docs/devlog.md's multi-mount entry, src/kernel.c3's conditional
  # fsd2 spawn gated on board::HAS_SECOND_FS_PARTITION). One flat image,
  # two independent filesystems at fixed byte offsets, no MBR/partition
  # table — mirrors how the Duo reads two real partitions off one card
  # with no partition-table parsing in fsd.c3 either way. The FAT32 half
  # MUST start at sector 0, not some other offset: fsd's own
  # FS_PARTITION_START_SECTOR (boards/qemu/board.c3) is one fixed constant
  # shared with the default disk.img above, which is whole-disk FAT32 from
  # sector 0 — a different offset here would just mean the first fsd finds
  # nothing (confirmed the hard way while building this image: an earlier
  # attempt put FAT32 at sector 2048 and got exactly that). ext2 goes at
  # sector 18432, matching FS_PARTITION_2_START_SECTOR. 9MiB FAT32 (sized
  # so it never writes past sector 18432) + 8MiB ext2, 20MiB file total.
  # The ext2 half is built in a scratch file first (mke2fs has no
  # offset option) then `dd`'d into place at sector 18432.
  rm -f build/disk_dual.img build/disk_dual_ext2_part.img
  dd if=/dev/zero of=build/disk_dual.img bs=1M count=20 status=none
  mkfs.vfat -F 32 build/disk_dual.img 9216 > /dev/null
  mcopy -i build/disk_dual.img disk/*.txt ::
  dd if=/dev/zero of=build/disk_dual_ext2_part.img bs=1M count=8 status=none
  mke2fs -q -F -b 1024 build/disk_dual_ext2_part.img
  debugfs -w -R "write disk-ext2/hello.txt hello.txt" build/disk_dual_ext2_part.img > /dev/null
  dd if=build/disk_dual_ext2_part.img of=build/disk_dual.img bs=512 seek=18432 conv=notrunc status=none
  rm -f build/disk_dual_ext2_part.img

  echo "==> Compiling kernel to LLVM IR..."
  rm -rf build/obj build/llvm build/obj_medany build/kernel.*
  c3c build racccoon --no-entry --safe=no --riscv-cpu=rvimac --emit-llvm

  # RV64 port: c3c's own object-file codegen only knows RISC-V's default
  # "small"/medlow code model, which requires every absolute address it
  # emits (every global variable, every string literal, every rodata
  # constant) to fit in the signed 32-bit range — i.e. below 2GiB. This
  # kernel boots at 0x80200000 (OpenSBI's fixed RV64 payload address,
  # just past the 2GiB line), so under medlow *every* such reference is
  # out of range; ld.lld catches this at link time
  # (R_RISCV_HI20 out of range). c3c has no --mcmodel flag to ask for
  # "medany" (PC-relative auipc-based addressing, valid across the full
  # 64-bit space) — the standard, correct code model for exactly this
  # situation, and what every real RV64 kernel (Linux, OpenSBI itself)
  # actually uses. So we take the one escape hatch --emit-llvm gives us:
  # recompile c3c's own LLVM IR ourselves via llc, this time asking for
  # -code-model=medium (LLVM's name for RISC-V's "medany"). See
  # docs/devlog.md for the full debugging story — this took a while to
  # pin down.
  echo "==> Recompiling IR with the medium (medany) code model..."
  mkdir -p build/obj_medany
  for f in build/llvm/elf-riscv64/*.ll; do
    name=$(basename "$f" .ll)
    $LLC -mtriple=riscv64-unknown-elf -mattr=+m,+a,+c \
      -code-model=medium -relocation-model=static \
      -filetype=obj -o "build/obj_medany/$name.o" "$f"
  done

  echo "==> Linking kernel.elf (with embedded shell)..."
  # No libclang_rt.builtins-riscv64 to link against (see
  # src/kernel/softfloat_stubs.c3's own comment for why that's fine).
  $LLVM_LLD \
    build/obj_medany/*.o \
    build/user/shell.bin.o \
    build/user/echod.bin.o \
    build/user/diskd.bin.o \
    build/user/sdd.bin.o \
    build/user/fsd.bin.o \
    -T src/kernel.ld \
    -Map=build/kernel.map \
    -o build/kernel.elf

  echo "==> Done: build/kernel.elf"
)
