#!/bin/sh

set -e

# Near-duplicate of launch64.sh / launch64_ext2.sh, differing only in
# which -drive it points at — boots the same kernel.elf against
# build/disk_exfat.img instead of build/disk.img, to exercise
# user/fs/exfat.c3's probe/mount/read/list path specifically (see
# scripts/mk_exfat_image.sh for how that image is built and populated,
# and docs/devlog.md's exFAT entry). Not the default test path —
# launch64.sh (FAT32) stays that.

qemu-system-riscv64 \
  -machine virt \
  -bios default \
  -nographic \
  -serial mon:stdio \
  -no-reboot \
  -drive id=drive0,file=../build/disk_exfat.img,format=raw,if=none \
  -device virtio-blk-device,drive=drive0,bus=virtio-mmio-bus.0 \
  -netdev user,id=net0 \
  -device virtio-net-device,netdev=net0,bus=virtio-mmio-bus.1 \
  -kernel ../build/kernel.elf
