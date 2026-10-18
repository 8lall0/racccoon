# Shared kernel build steps, sourced by every board build script
# (scripts/build.sh, build_duo.sh, build_opi.sh, build_opi_qemu.sh).
# Run from the repo root. A board script still builds its own userspace
# first (scripts/build_user.sh, with any per-board knobs like
# SDD_SOC_SRC) and then calls, in order:
#
#   kernel_compile <c3c-target> <out>          IR -> medany objects
#   kernel_test_shell_obj <dir>                (optional) re-embed shell_test
#   kernel_link <shell.bin.o> <linker-script> <out>
#
# <out> is the output basename under build/ (kernel, kernel_duo, ...).

# Prefer the /opt/riscv LLVM if it's installed, else fall back to the
# system tools on PATH (an Arch host with llvm/lld packages, say).
if [ -x /opt/riscv/bin/ld.lld ]; then
  LLVM_LLD=${LLVM_LLD:-/opt/riscv/bin/ld.lld}
else
  LLVM_LLD=${LLVM_LLD:-ld.lld}
fi
LLC=${LLC:-llc}
LLVM_OBJCOPY=${LLVM_OBJCOPY:-llvm-objcopy}
LLVM_MC=${LLVM_MC:-llvm-mc}

# The boot servers embedded in every kernel image, one build/user/<name>.bin.o
# each — must match src/kernel.c3's _binary_<name>_bin_* externs. All of them
# are linked into every board even though the board's DEVICES table decides
# which actually spawn: kernel.c3 references each symbol unconditionally.
# Adding a server = add it here + its externs/service_boot in kernel.c3.
KERNEL_SERVERS="echod diskd sdd fsd procd envd usbd ethd netd gpiod i2cd cifd"

# kernel_compile <c3c-target> <out>
#
# RV64 code model: c3c's own object-file codegen only knows RISC-V's default
# "small"/medlow code model, which requires every absolute address it emits
# (every global variable, every string literal, every rodata constant) to fit
# in the signed 32-bit range — i.e. below 2GiB. QEMU and the Duo boot at
# 0x80200000 (OpenSBI's fixed RV64 payload address, just past the 2GiB line),
# so under medlow *every* such reference is out of range; ld.lld catches this
# at link time (R_RISCV_HI20 out of range). c3c has no --mcmodel flag to ask
# for "medany" (PC-relative auipc-based addressing, valid across the full
# 64-bit space) — the standard, correct code model for exactly this
# situation, and what every real RV64 kernel (Linux, OpenSBI itself) uses.
# So we take the one escape hatch --emit-llvm gives us: recompile c3c's own
# LLVM IR ourselves via llc, asking for -code-model=medium (LLVM's name for
# RISC-V's "medany"). The JH7110's 0x40200000 is within medlow's reach, but
# every board goes through the same pipeline. See docs/devlog.md for the full
# debugging story.
kernel_compile() {
  local target="$1" out="$2"
  echo "==> Compiling kernel to LLVM IR ($target target)..."
  rm -rf build/obj build/llvm build/obj_medany build/"$out".*
  c3c build "$target" --no-entry --safe=no --riscv-cpu=rvimac --riscv-abi=double --emit-llvm

  echo "==> Recompiling IR with the medium (medany) code model..."
  mkdir -p build/obj_medany
  local f name
  for f in build/llvm/elf-riscv64/*.ll; do
    name=$(basename "$f" .ll)
    $LLC -mtriple=riscv64-unknown-elf -mattr=+m,+a,+c,+f,+d \
      -code-model=medium -relocation-model=static \
      -filetype=obj -o "build/obj_medany/$name.o" "$f"
  done
}

# kernel_test_shell_obj <dir>  — prints the object's path
#
# Embed the *test* shell (user/shell_test.c3 — every dev/regression-test
# builtin) in place of the production shell. src/kernel.c3's
# _binary_shell_bin_start/_end symbols are fixed by name, and the embedded
# symbol name comes from the input file's basename — so shell_test.bin is
# re-embedded under the literal name "shell.bin" in its own directory
# build/<dir> (not build/user/, which holds the production shell.bin.o).
# llvm-mc + .incbin (see build_user.sh's matching comment): -Ibinary
# wrappers carry soft-float e_flags, which ld.lld rejects against the
# rv64imafdc kernel.
#
# Called as SHELL_OBJ=$(kernel_test_shell_obj ...), where set -e does not
# reach inside the function — hence the explicit `|| return 1`s.
kernel_test_shell_obj() {
  local dir="build/$1"
  mkdir -p "$dir" || return 1
  cp build/user/shell_test.bin "$dir/shell.bin" || return 1
  (
    cd "$dir"
    cat > shell.bin.s <<'STUB'
	.section .rodata._binary_shell_bin, "a"
	.balign 8
	.globl _binary_shell_bin_start
_binary_shell_bin_start:
	.incbin "shell.bin"
	.globl _binary_shell_bin_end
_binary_shell_bin_end:
STUB
    "$LLVM_MC" --triple=riscv64 --mattr=+m,+a,+c,+f,+d --target-abi=lp64d \
      --filetype=obj -o shell.bin.o shell.bin.s
  ) >&2 || return 1
  echo "$dir/shell.bin.o"
}

# kernel_link <shell.bin.o> <linker-script> <out>
#
# Built rv64imafdc/lp64d (--riscv-abi=double + llc -mattr=+f,+d), so LLVM
# emits hardware FP inline — no compiler-rt soft-float builtins to resolve,
# hence no libclang_rt.builtins-riscv64 needed.
kernel_link() {
  local shell_obj="$1" ldscript="$2" out="$3"
  local servers=() s
  for s in $KERNEL_SERVERS; do servers+=("build/user/$s.bin.o"); done
  echo "==> Linking $out.elf (with embedded shell)..."
  $LLVM_LLD \
    build/obj_medany/*.o \
    "$shell_obj" \
    "${servers[@]}" \
    -T "$ldscript" \
    -Map="build/$out.map" \
    -o "build/$out.elf"
}
