#!/bin/sh

rm -rf ../build/obj

set -e

(
  cd ..
  c3c build --no-entry --safe=no --riscv-cpu=rvimac

  OBJS=`ls build/obj/elf-riscv32/*.o`
  DEL="build/obj/elf-riscv32/racccoon.o"
  for del in ${DEL[@]}
  do
     OBJS=("${OBJS[@]/$del}") #Quotes when working with strings
  done

  /opt/riscv/bin/llvm-ar rcs build/obj/elf-riscv32/libs.a $OBJS
  /opt/riscv/bin/ld.lld \
    build/obj/elf-riscv32/racccoon.o \
    build/obj/elf-riscv32/libs.a \
    -T src/kernel.ld \
    -L /opt/riscv/lib/linux \
    -lclang_rt.builtins-riscv32 \
    -Map=build/kernel.map \
    -o build/kernel.elf
)
