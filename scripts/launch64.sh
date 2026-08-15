#!/bin/sh

set -e

qemu-system-riscv64 \
  -machine virt \
  -bios default \
  -nographic \
  -serial mon:stdio \
  -no-reboot \
  -drive id=drive0,file=../build/disk.tar,format=raw,if=none \
  -device virtio-blk-device,drive=drive0,bus=virtio-mmio-bus.0 \
  -kernel ../build/kernel.elf
