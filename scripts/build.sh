#!/bin/bash

rm -rf ../build/obj
rm -rf ../build/kernel.*

set -e

(
  cd ..
  c3c build --no-entry --safe=no --riscv-cpu=rvimac

  /opt/riscv/bin/ld.lld \
    build/obj/elf-riscv32/*.o \
    -T src/kernel.ld \
    -L /opt/riscv/lib/linux \
    -lclang_rt.builtins-riscv32 \
    -Map=build/kernel.map \
    -o build/kernel.elf
)
