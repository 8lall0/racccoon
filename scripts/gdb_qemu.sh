#!/bin/bash
#
# gdb against a racccoon QEMU guest, kernel AND userspace.
#
#   terminal 1:  scripts/launch64.sh -s          (or launch64_ext2.sh -s;
#                                                 add -S to stop at reset)
#   terminal 2:  scripts/gdb_qemu.sh [PROG.elf]  [extra gdb args]
#
# Loads build/kernel.elf's symbols, plus PROG.elf's when given (a C3/C/C++
# program's linked ELF: build/user/<name>.elf, build/libc/<name>.elf —
# build with -g for source lines). Every program is linked at USER_BASE,
# so one program's symbols at a time, and a breakpoint on a user address
# fires in whichever process runs that address: filter it by process name
# with the commands below. QEMU's TCG gdbstub keeps breakpoints itself
# (it never writes an ebreak into guest memory), so a user breakpoint
# can't corrupt another process that maps the same VA.
#
# Commands added (build/racccoon.gdbinit):
#   ubreak LOCATION NAME   break at LOCATION only while process NAME
#                          (Process.name, what `ps` shows) is current
#   curproc                pid + name of the process on the CPU now
#
# gdb doesn't know C3, so the kernel's types aren't usable in expressions;
# the commands read current_proc's address and Process.name's offset out
# of kernel.elf (symbol table + DWARF) each time this script runs.

set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
PROG=""
if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then PROG="$(realpath "$1")"; shift; fi

[ -e "$KERNEL" ] || { echo "no $KERNEL — run scripts/build.sh first" >&2; exit 1; }

CUR=$(llvm-nm "$KERNEL" | awk '$3 == "kernel.current_proc" { print "0x" $1 }')
NAME_OFF=$(llvm-dwarfdump --name=Process --show-children "$KERNEL" | awk '
  /DW_AT_name/ && /"name"/ { want = 1 }
  want && /DW_AT_data_member_location/ { gsub(/[()]/, "", $2); print $2; exit }')
if [ -z "$CUR" ] || [ -z "$NAME_OFF" ]; then
  echo "couldn't find current_proc / Process.name in $KERNEL" >&2
  exit 1
fi

INIT="$ROOT/build/racccoon.gdbinit"
cat > "$INIT" <<EOF
set pagination off
set confirm off
set architecture riscv:rv64
file $KERNEL
$( [ -n "$PROG" ] && echo "add-symbol-file $PROG" )

# current_proc ($CUR) -> Process.name (+$NAME_OFF). Kernel pages are
# supervisor-only, so from a user-mode stop QEMU refuses virtual reads of
# them; the kernel is identity-mapped, so read it physically instead
# (QEMU's Qqemu.PhyMemMode) and switch back.
define rc-phys
  pipe maint packet Qqemu.PhyMemMode:\$arg0 | cat > /dev/null
end

define curproc
  rc-phys 1
  printf "pid %d  %s\n", *(int *)(*(long *)$CUR), (char *)(*(long *)$CUR + $NAME_OFF)
  rc-phys 0
end
document curproc
The racccoon process running on the CPU right now (pid and Process.name).
end

# One process filter for all ubreak breakpoints: the last NAME given.
define ubreak
  set \$rc_want = "\$arg1"
  break \$arg0
  commands
    silent
    rc-phys 1
    set \$rc_hit = \$_streq((char *)(*(long *)$CUR + $NAME_OFF), \$rc_want)
    rc-phys 0
    if !\$rc_hit
      continue
    end
    frame
  end
end
document ubreak
ubreak LOCATION NAME: break at LOCATION only while process NAME is
current. The name filter is shared: the last ubreak's NAME applies to all.
end

target remote :1234
EOF

exec gdb -x "$INIT" "$@"
