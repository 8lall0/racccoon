#!/bin/sh

set -e

# Near-duplicate of launch64.sh, differing only in which -drive it points
# at — boots the same kernel.elf against build/disk_dual.img, which has
# two independent ext2 filesystems in one image (see scripts/build.sh's
# own comment), to exercise the two-simultaneous-mounts feature end to
# end: fsd (mount "", root) gets partition 1, fsd2 (mount "/mnt/fs2/")
# gets partition 2, matching boards/qemu/board.c3's
# FS_PARTITION_START_SECTOR/FS_PARTITION_2_START_SECTOR.
# Not the default test path — launch64.sh (single FAT32) stays that.

qemu-system-riscv64 \
  -machine virt \
  -bios default \
  -nographic \
  -serial mon:stdio \
  -no-reboot \
  -drive id=drive0,file=../build/disk_dual.img,format=raw,if=none \
  -device virtio-blk-device,drive=drive0,bus=virtio-mmio-bus.0 \
  -netdev user,id=net0 \
  -device virtio-net-device,netdev=net0,bus=virtio-mmio-bus.1 \
  -kernel ../build/kernel.elf
