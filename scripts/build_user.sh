#!/bin/bash

set -e

LLVM_OBJCOPY=${LLVM_OBJCOPY:-llvm-objcopy}
LLVM_MC=${LLVM_MC:-llvm-mc}
# /opt/riscv LLVM if present, else the system lld on PATH.
if [ -x /opt/riscv/bin/ld.lld ]; then
  LLVM_LLD=${LLVM_LLD:-/opt/riscv/bin/ld.lld}
else
  LLVM_LLD=${LLVM_LLD:-ld.lld}
fi

# std::nolibc::{mem,atomic,fmt,main_stub} — the freestanding pieces
# every user-mode binary needs, adapted from the real c3 stdlib
# (mem/atomic/main_stub) or original (fmt) — see docs/devlog.md. Used
# to live as vendored copies under user/ (one per project needing
# them); now sourced from the 8lall0/c3c fork's own stdlib tree
# (lib/std/_nolibc/), where any project can `import std::nolibc::mem;`
# etc. Passed as plain source file arguments (same as user/user.c3
# always has been) rather than requiring --use-stdlib=yes: that flag
# pulls in far more of the real stdlib (std::io, libc.os, ...) than
# this freestanding link step can handle — confirmed by testing, not
# assumed. Gated `@feat(RACCCOON)` in those files themselves, not the
# ambient NO_LIBC every freestanding build already sets — -D RACCCOON
# below is what actually turns them on, so they stay dormant for any
# other project built against the same fork that hasn't explicitly
# opted in.
#
# main_stub.c3 provides `@main_no_args`, the forwarding macro the
# compiler's own standard main-detection looks up by name for a plain
# `fn void main()` — every main-providing file below `import
# std::nolibc::main_stub;` for it, which is what lets these binaries
# use ordinary `fn void main()` with no `@export("main")` boilerplate
# and no --no-entry: the compiler generates and exports the real,
# unmangled `main` entry point itself, the same as any hosted c3
# program (see docs/devlog.md).
RACCCOON_STD_DIR=${RACCCOON_STD_DIR:-/home/blallo/Workspace/c3c/lib/std/_nolibc}

ROOT="$(dirname "$0")/.."
cd "$ROOT"

# Builds one user-mode program from user/user.c3 (the shared library:
# syscall wrappers, start()/exit()) plus its own main-providing source
# file(s), producing build/user/<name>.bin.o ready to embed in the kernel
# image. Every program links at the same USER_BASE (user/user.ld) — that's
# fine, each one only ever exists in its own process's own page table.
build_user_program() {
  local name="$1"
  shift
  local sources=("$@")

  mkdir -p "build/user/$name/obj"

  echo "==> Compiling $name..."
  c3c compile-only \
    --safe=no \
    --use-stdlib=no \
    --link-libc=no \
    -D RACCCOON \
    --target elf-riscv64 \
    --riscv-cpu=rvimac \
    --riscv-abi=double \
    --output-dir "build/user/$name/obj" \
    "${sources[@]}"

  local obj_dir="build/user/$name/obj/obj/elf-riscv64"

  # rv64imafdc/lp64d (--riscv-abi=double): hardware FP inline, no
  # compiler-rt soft-float builtins to link. See build.sh's matching comment.
  echo "==> Linking $name.elf..."
  $LLVM_LLD \
    "$obj_dir"/*.o \
    -T user/user.ld \
    -Map="build/user/$name.map" \
    -o "build/user/$name.elf"

  echo "==> Converting ELF -> raw binary..."
  $LLVM_OBJCOPY \
    --set-section-flags .bss=alloc,contents \
    -O binary \
    "build/user/$name.elf" \
    "build/user/$name.bin"

  echo "==> Embedding binary as linkable object..."
  # llvm-mc + .incbin, not objcopy -Ibinary: an -Ibinary wrapper has
  # e_flags = 0 (soft-float ABI), and since the kernel went rv64imafdc
  # (double-float ABI) ld.lld now rejects linking the two together. The
  # .s stub assembled with --target-abi=lp64d carries matching e_flags.
  # Same _binary_<name>_bin_start/_end symbols objcopy produced (kernel.c3
  # computes the size as end - start, doesn't use _bin_size).
  (
    cd build/user
    cat > "$name.bin.s" <<STUB
	.section .rodata._binary_${name}_bin, "a"
	.balign 8
	.globl _binary_${name}_bin_start
_binary_${name}_bin_start:
	.incbin "${name}.bin"
	.globl _binary_${name}_bin_end
_binary_${name}_bin_end:
STUB
    $LLVM_MC --triple=riscv64 --mattr=+m,+a,+c,+f,+d --target-abi=lp64d \
      --filetype=obj -o "$name.bin.o" "$name.bin.s"
  )

  echo "==> Done: build/user/$name.bin.o"
}

# Builds one user-mode program against the REAL c3 stdlib (std::io,
# std::core::mem, ...) instead of std::nolibc — see docs/devlog.md
# ("std::io on racccoon"). Same output shape as build_user_program
# (build/user/<name>.bin.o), three real differences:
#   - --use-stdlib isn't forced off, and --custom-libc=yes activates
#     the @feat(CUSTOM_LIBC) hooks user/std_racccoon/ (libc.c3,
#     io_native.c3, rcsys.c3, trunctfdf2_stub.c3 — the userspace
#     counterparts of src/libc/libc.c3 + src/std/io/io_native.c3 the
#     KERNEL already uses for the exact same reason) and three files
#     reused verbatim from the kernel's own override set
#     (src/std/core/mem.c3, nolibc_allocator.c3, nolibc_vmem.c3) plus
#     std::io's own os.c3/io.c3 overrides (src/std/io/...) satisfy.
#   - entry point is user/std_racccoon/rt_entry.c3's hand-written
#     `_start` (ENTRY(_start), not std::nolibc::main_stub's `start`) —
#     c3c's own synthetic-main generator still produces the real,
#     exported `main` for a plain `fn void main()` here (that's stock
#     compiler behavior, not something RACCCOON_STD_DIR provides); what's
#     missing on a target with no OS is only the thing that calls it.
#   - reuses lib/racccoon-libc/racccoon-libc.ld (ENTRY(_start), same
#     USER_BASE layout as user/user.ld) rather than user/user.ld.
#
# user/user.c3 CAN be one of the sources — its own exported `putchar`
# looked like it would collide with libc.c3's POSIX one (both claim
# the bare linker name "putchar"), but empirically it doesn't: a
# program that never actually calls user.c3's print()/putchar()/
# getchar() family (using io::print/io::putchar for output instead,
# "std::io on racccoon" style, while still calling user::fs_read/exec/
# etc. for everything racccoon-specific) never keeps that function
# reachable, and the linker just drops it — proven across cat/ls/echo/
# head/whoami/write/rm/mkdir/mv/chmod/chown/usbrw/gpio (2026-09-05),
# including the ones that reach fairly deep into user.c3 (usbrw.c3/
# gpio.c3's ns_mount_wait/p9_call_path). -D RACCCOON activates
# RACCCOON_STD_DIR's own @feat(RACCCOON) gate, same as
# build_user_program needs it for — user.c3 itself imports those files.
build_user_program_stdio() {
  local name="$1"
  shift
  local sources=("$@")

  mkdir -p "build/user/$name/obj"

  echo "==> Compiling $name (real stdlib)..."
  c3c compile-only \
    --safe=no \
    --link-libc=no \
    --custom-libc=yes \
    -D RACCCOON \
    --target elf-riscv64 \
    --riscv-cpu=rvimac \
    --riscv-abi=double \
    --output-dir "build/user/$name/obj" \
    "${sources[@]}"

  local obj_dir="build/user/$name/obj/obj/elf-riscv64"

  echo "==> Linking $name.elf..."
  $LLVM_LLD \
    "$obj_dir"/*.o \
    -T lib/racccoon-libc/racccoon-libc.ld \
    -Map="build/user/$name.map" \
    -o "build/user/$name.elf"

  echo "==> Converting ELF -> raw binary..."
  $LLVM_OBJCOPY \
    --set-section-flags .bss=alloc,contents \
    -O binary \
    "build/user/$name.elf" \
    "build/user/$name.bin"

  echo "==> Embedding binary as linkable object..."
  (
    cd build/user
    cat > "$name.bin.s" <<STUB
	.section .rodata._binary_${name}_bin, "a"
	.balign 8
	.globl _binary_${name}_bin_start
_binary_${name}_bin_start:
	.incbin "${name}.bin"
	.globl _binary_${name}_bin_end
_binary_${name}_bin_end:
STUB
    $LLVM_MC --triple=riscv64 --mattr=+m,+a,+c,+f,+d --target-abi=lp64d \
      --filetype=obj -o "$name.bin.o" "$name.bin.s"
  )

  echo "==> Done: build/user/$name.bin.o"
}

build_user_program shell user/user.c3 $RACCCOON_STD_DIR/atomic.c3 $RACCCOON_STD_DIR/mem.c3 $RACCCOON_STD_DIR/fmt.c3 $RACCCOON_STD_DIR/main_stub.c3 user/shell_words.c3 user/shell_jobs.c3 user/shell_common.c3 user/shell.c3
build_user_program shell_test user/user.c3 $RACCCOON_STD_DIR/atomic.c3 $RACCCOON_STD_DIR/mem.c3 $RACCCOON_STD_DIR/fmt.c3 $RACCCOON_STD_DIR/main_stub.c3 user/shell_words.c3 user/shell_jobs.c3 user/shell_common.c3 user/shell_test.c3
build_user_program echod user/user.c3 $RACCCOON_STD_DIR/atomic.c3 $RACCCOON_STD_DIR/mem.c3 $RACCCOON_STD_DIR/fmt.c3 $RACCCOON_STD_DIR/main_stub.c3 user/sys/echod.c3
# true/false do zero I/O (just exitcode(0)/(1)) — no benefit from the
# real stdlib's ~180 KiB, kept on the lightweight std::nolibc path.
build_user_program true user/user.c3 $RACCCOON_STD_DIR/atomic.c3 $RACCCOON_STD_DIR/mem.c3 $RACCCOON_STD_DIR/fmt.c3 $RACCCOON_STD_DIR/main_stub.c3 user/bin/true.c3
build_user_program false user/user.c3 $RACCCOON_STD_DIR/atomic.c3 $RACCCOON_STD_DIR/mem.c3 $RACCCOON_STD_DIR/fmt.c3 $RACCCOON_STD_DIR/main_stub.c3 user/bin/false.c3

# The small /bin utilities, ported to the real stdlib (io::print/
# io::printfn instead of user.c3's own print()/putchar(), String.to_int/
# to_uint instead of hand-rolled digit parsing where that's a real
# simplification) — "std::io on racccoon", docs/devlog.md 2026-09-05.
# Not ported: wasm.c3 (already close to its own size budget on top of
# a real interpreter), shell/shell_test (the most complex, most tested
# file in the project — high risk, no formatting/collection need), and
# every system server (diskd/sdd/fsd/procd/envd/usbd/ethd/netd/gpiod —
# reliability-critical, no benefit, stay on std::nolibc).
STDIO_COMMON="src/std/core/mem.c3 src/std/core/nolibc_allocator.c3 src/std/core/nolibc_vmem.c3 \
  src/std/io/io.c3 src/std/io/os/os.c3 \
  user/std_racccoon/rcsys.c3 user/std_racccoon/libc.c3 user/std_racccoon/io_native.c3 \
  user/std_racccoon/trunctfdf2_stub.c3 user/std_racccoon/heap.c3 user/std_racccoon/rt_entry.c3 \
  user/user.c3 $RACCCOON_STD_DIR/atomic.c3 $RACCCOON_STD_DIR/mem.c3 $RACCCOON_STD_DIR/fmt.c3"
build_user_program_stdio cat $STDIO_COMMON user/bin/cat.c3
build_user_program_stdio ls $STDIO_COMMON user/bin/ls.c3
build_user_program_stdio echo $STDIO_COMMON user/bin/echo.c3
build_user_program_stdio head $STDIO_COMMON user/bin/head.c3
build_user_program_stdio whoami $STDIO_COMMON user/bin/whoami.c3
build_user_program_stdio write $STDIO_COMMON user/bin/write.c3
build_user_program_stdio rm $STDIO_COMMON user/bin/rm.c3
build_user_program_stdio mkdir $STDIO_COMMON user/bin/mkdir.c3
build_user_program_stdio mv $STDIO_COMMON user/bin/mv.c3
build_user_program_stdio chmod $STDIO_COMMON user/bin/chmod.c3
build_user_program_stdio chown $STDIO_COMMON user/bin/chown.c3
build_user_program_stdio usbrw $STDIO_COMMON user/bin/usbrw.c3
build_user_program_stdio gpio $STDIO_COMMON user/bin/gpio.c3
build_user_program wasm user/user.c3 $RACCCOON_STD_DIR/atomic.c3 $RACCCOON_STD_DIR/mem.c3 $RACCCOON_STD_DIR/fmt.c3 $RACCCOON_STD_DIR/main_stub.c3 user/bin/wasm.c3
build_user_program diskd user/user.c3 $RACCCOON_STD_DIR/atomic.c3 $RACCCOON_STD_DIR/mem.c3 $RACCCOON_STD_DIR/fmt.c3 $RACCCOON_STD_DIR/main_stub.c3 user/virtio.c3 user/block/diskd.c3
build_user_program sdd user/user.c3 $RACCCOON_STD_DIR/atomic.c3 $RACCCOON_STD_DIR/mem.c3 $RACCCOON_STD_DIR/fmt.c3 $RACCCOON_STD_DIR/main_stub.c3 user/block/sdhci.c3 user/block/sdd.c3
build_user_program fsd user/user.c3 $RACCCOON_STD_DIR/atomic.c3 $RACCCOON_STD_DIR/mem.c3 $RACCCOON_STD_DIR/fmt.c3 $RACCCOON_STD_DIR/main_stub.c3 user/fs/fsd.c3 user/fs/fat32.c3 user/fs/ext2.c3 user/fs/exfat.c3
build_user_program procd user/user.c3 $RACCCOON_STD_DIR/atomic.c3 $RACCCOON_STD_DIR/mem.c3 $RACCCOON_STD_DIR/fmt.c3 $RACCCOON_STD_DIR/main_stub.c3 user/sys/procd.c3
build_user_program envd user/user.c3 $RACCCOON_STD_DIR/atomic.c3 $RACCCOON_STD_DIR/mem.c3 $RACCCOON_STD_DIR/fmt.c3 $RACCCOON_STD_DIR/main_stub.c3 user/sys/envd.c3
build_user_program usbd user/user.c3 $RACCCOON_STD_DIR/atomic.c3 $RACCCOON_STD_DIR/mem.c3 $RACCCOON_STD_DIR/fmt.c3 $RACCCOON_STD_DIR/main_stub.c3 user/usb/dwc2.c3 user/usb/xpad.c3 user/usb/kbd.c3 user/usb/msc.c3 user/usb/usbd.c3
build_user_program ethd user/user.c3 $RACCCOON_STD_DIR/atomic.c3 $RACCCOON_STD_DIR/mem.c3 $RACCCOON_STD_DIR/fmt.c3 $RACCCOON_STD_DIR/main_stub.c3 user/net/eth_proto.c3 user/net/dhcp.c3 user/net/dwmac.c3 user/net/ephy.c3 user/net/ethd.c3
build_user_program netd user/user.c3 $RACCCOON_STD_DIR/atomic.c3 $RACCCOON_STD_DIR/mem.c3 $RACCCOON_STD_DIR/fmt.c3 $RACCCOON_STD_DIR/main_stub.c3 user/virtio.c3 user/net/eth_proto.c3 user/net/dhcp.c3 user/net/netd.c3
build_user_program gpiod user/user.c3 $RACCCOON_STD_DIR/atomic.c3 $RACCCOON_STD_DIR/mem.c3 $RACCCOON_STD_DIR/fmt.c3 $RACCCOON_STD_DIR/main_stub.c3 user/gpio/gpiod.c3

build_user_program_stdio stdiotest \
  src/std/core/mem.c3 src/std/core/nolibc_allocator.c3 src/std/core/nolibc_vmem.c3 \
  src/std/io/io.c3 src/std/io/os/os.c3 \
  user/std_racccoon/rcsys.c3 user/std_racccoon/libc.c3 user/std_racccoon/io_native.c3 \
  user/std_racccoon/trunctfdf2_stub.c3 user/std_racccoon/heap.c3 user/std_racccoon/rt_entry.c3 \
  user/bin/stdiotest.c3
