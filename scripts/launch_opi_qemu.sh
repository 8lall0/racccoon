#!/bin/sh
#
# Run the Orange Pi RV verification harness under QEMU `-machine
# sifive_u` — see boards/opi-rv-qemu/board.c3's header.
#
# `-smp 2` is the point, not an afterthought: on sifive_u that is one E51
# monitor hart (hart 0, no S-mode) + one U54 application hart (hart 1),
# so OpenSBI is forced to hand racccoon's S-mode payload to hart 1 — the
# same handoff the JH7110 does, and the one QEMU `virt` never does. A
# clean boot to the `root / #` prompt here means open questions 1 (boot
# hart / PLIC S-context 2), 2 (`rdtime` in S-mode) and 3 (SBI console)
# from docs/opi-rv-plan.md are all answered before the real board is even
# unblocked.
#
# `-smp 5` (1 monitor + 4 U54) also works — the 3 extra harts just
# announce themselves and park (no SMP scheduler; non-goal).
#
# No disk: this board is HAS_BLOCK_DEVICE = false, exactly like the
# opi-rv Stage-1 scaffold. `ls` / file commands fail cleanly; `echo`,
# pipes, `ns`, `ping`, and (with an OPI_TEST_SHELL=1 build) maptest /
# faulttest / hungservertest / mutextest are the testable surface.

set -e
cd "$(dirname "$0")"

exec qemu-system-riscv64 \
  -machine sifive_u \
  -smp "${SMP:-2}" \
  -bios default \
  -nographic \
  -serial mon:stdio \
  -no-reboot \
  -kernel ../build/kernel_opi_qemu.elf
