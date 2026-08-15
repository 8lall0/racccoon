#!/bin/bash
#
# Repeatedly boots build/kernel.elf under QEMU to catch flaky, timing-
# dependent failures that a single manual boot won't reliably show —
# specifically written for the interrupt-driven disk I/O bugs fixed in
# docs/devlog.md (a rare lost-wakeup hang, and a since-fixed reentrancy
# bug that briefly replaced it). Run after `bash scripts/build.sh`.
#
# Usage: bash scripts/stress_test.sh [N]   (default N=20 runs per scenario)

set -u

ROOT="$(dirname "$0")/.."
cd "$ROOT"

N=${1:-20}
KERNEL=build/kernel.elf
DISK=build/disk.tar

if [ ! -f "$KERNEL" ] || [ ! -f "$DISK" ]; then
  echo "build/kernel.elf or build/disk.tar missing — run 'bash scripts/build.sh' first." >&2
  exit 1
fi

run_qemu() {
  local input_file="$1"
  local out_file="$2"
  # riscv64, not riscv32: RV64/Sv39 port (see docs/devlog.md) — kernel.elf
  # is now an RV64 ELF, so it needs the matching QEMU machine.
  timeout 6 qemu-system-riscv64 \
    -machine virt -bios default -nographic -serial stdio -monitor none -no-reboot \
    -drive id=drive0,file="$DISK",format=raw,if=none \
    -device virtio-blk-device,drive=drive0,bus=virtio-mmio-bus.0 \
    -kernel "$KERNEL" < "$input_file" > "$out_file" 2>&1 || true
}

stress() {
  local name="$1"
  local input_file="$2"
  local success_grep="$3"
  local fail_grep="unexpected trap|PANIC"

  local ok=0
  local bad=0
  echo "==> $name ($N runs)"
  for i in $(seq 1 "$N"); do
    local out
    out="$(mktemp)"
    run_qemu "$input_file" "$out"
    if grep -qE "$fail_grep" "$out"; then
      bad=$((bad+1))
      echo "    run $i: CRASH — $(grep -E "$fail_grep" "$out" | head -1)"
    elif grep -q "$success_grep" "$out"; then
      ok=$((ok+1))
    else
      bad=$((bad+1))
      echo "    run $i: HUNG (no crash, never reached expected output)"
    fi
    rm -f "$out"
  done
  echo "    -> $ok/$N passed"
  echo
}

# Scenario 1: bare-mode boot, no input — fs_init()'s own interrupt-driven
# disk reads are the only thing exercising the disk path. This is the one
# that used to hang about 1 in 7 runs.
EMPTY_INPUT=$(mktemp)
stress "boot hang (fs_init disk reads)" "$EMPTY_INPUT" "fsd: file: hello.txt"
rm -f "$EMPTY_INPUT"

# Scenario 2: writefile immediately after boot — exercises the same disk
# path from inside a syscall (SYS_WRITEFILE -> fs_flush), which is where
# the reentrancy bug specifically showed up. This one was 100%
# reproducible before the fix.
WRITEFILE_INPUT=$(mktemp)
# Leading "x" pads out a known, unrelated quirk: piped/redirected stdin's
# first character sometimes gets eaten before the guest UART is ready,
# which would otherwise turn "writefile" into "ritefile" (unknown
# command) and produce a false failure here.
printf 'xwritefile\rexit\r' > "$WRITEFILE_INPUT"
stress "writefile reentrancy" "$WRITEFILE_INPUT" "fsd: wrote 2560 bytes to disk"
rm -f "$WRITEFILE_INPUT"

echo "Done."
