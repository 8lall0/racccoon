#!/bin/sh

set -e

cd "$(dirname "$0")"

# The guest writes to its disk in place — write/rm/mkdir persist into the
# image file — so booting build/disk.img directly would carry every
# previous run's mutations into the next one (a stale directory entry
# once made an ext2_rename look like it had failed — see docs/devlog.md).
# Boot a throwaway copy instead: build/disk.img stays exactly as
# scripts/build.sh produced it, and every launch starts clean. Same
# pattern in launch64_ext2.sh / launch64_exfat.sh / launch64_dual.sh.
cp ../build/disk.img ../build/disk.run.img

qemu-system-riscv64 \
  -machine virt \
  -m 1G \
  -bios default \
  -nographic \
  -serial mon:stdio \
  -no-reboot \
  -drive id=drive0,file=../build/disk.run.img,format=raw,if=none \
  -device virtio-blk-device,drive=drive0,bus=virtio-mmio-bus.0 \
  -netdev user,id=net0 \
  -device virtio-net-device,netdev=net0,bus=virtio-mmio-bus.1 \
  -kernel ../build/kernel.elf
