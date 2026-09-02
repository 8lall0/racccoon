#!/bin/sh

set -e

cd "$(dirname "$0")"

# Near-duplicate of launch64.sh, differing only in which -drive it
# points at — boots the same kernel.elf against build/disk_ext2.img
# instead of build/disk.img, to exercise user/fs/ext2.c3's probe/mount/
# read/write path specifically (see scripts/build.sh's own comment on how
# disk_ext2.img is built, and docs/devlog.md's filesystem-abstraction
# entry). Not the default test path — launch64.sh (FAT32) stays that.
#
# Boots a throwaway copy so repeated runs always start from the pristine
# image — see launch64.sh's own comment.
cp ../build/disk_ext2.img ../build/disk_ext2.run.img

qemu-system-riscv64 \
  -machine virt \
  -m 2G \
  -bios default \
  -nographic \
  -serial mon:stdio \
  -no-reboot \
  -drive id=drive0,file=../build/disk_ext2.run.img,format=raw,if=none \
  -device virtio-blk-device,drive=drive0,bus=virtio-mmio-bus.0 \
  -netdev user,id=net0 \
  -device virtio-net-device,netdev=net0,bus=virtio-mmio-bus.1 \
  -kernel ../build/kernel.elf
