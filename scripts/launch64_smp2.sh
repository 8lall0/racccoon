#!/bin/sh
set -e
cd "$(dirname "$0")"
cp ../build/disk.img ../build/disk.smp2.img
qemu-system-riscv64 \
  -machine virt \
  -smp 2 \
  -m 2G \
  -bios default \
  -nographic \
  -serial mon:stdio \
  -no-reboot \
  -drive id=drive0,file=../build/disk.smp2.img,format=raw,if=none \
  -device virtio-blk-device,drive=drive0,bus=virtio-mmio-bus.0 \
  -netdev user,id=net0 \
  -device virtio-net-device,netdev=net0,bus=virtio-mmio-bus.1 \
  -kernel ../build/kernel.elf
