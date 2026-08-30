#!/bin/bash

set -e

# Prefer the /opt/riscv LLVM if it's installed, else fall back to the
# system tools on PATH (an Arch host with llvm/lld packages, say).
if [ -x /opt/riscv/bin/ld.lld ]; then
  LLVM_LLD=${LLVM_LLD:-/opt/riscv/bin/ld.lld}
else
  LLVM_LLD=${LLVM_LLD:-ld.lld}
fi
LLC=${LLC:-llc}
LLVM_OBJCOPY=${LLVM_OBJCOPY:-llvm-objcopy}

(
  cd "$(dirname "$0")/.."

  # Build user app first (produces build/user/shell.bin.o)
  bash scripts/build_user.sh

  # Hand-built .wasm test fixtures for /bin/wasm (no wat2wasm on this
  # host — the bytes are assembled by the Python script). Seeded onto
  # every disk image below next to /bin.
  python3 test/mkwasm.py build/wasm

  # The disk images built below are pristine masters — every one is
  # rm -f'd and rebuilt from scratch on each run, so re-running this
  # script is itself a full reset. The scripts/launch64*.sh scripts
  # never boot these directly: each copies its master to a
  # build/<name>.run.img throwaway first, so a guest that writes to its
  # disk (the FAT32/ext2/exFAT write paths all do) can't carry mutations
  # from one test run into the next (see docs/devlog.md). Clear any stale
  # throwaways here so a fresh build never leaves an old one lying around.
  rm -f build/*.run.img

  echo "==> Building disk image (FAT32)..."
  # user/fsd.c3 now reads a real FAT32 filesystem (see docs/devlog.md),
  # not the tar format this used to build. Whole-disk FAT32 (no MBR/
  # partition table, board::FS_PARTITION_START_SECTOR=0 for QEMU — see
  # boards/qemu/board.c3) — the simplest thing mkfs.vfat can produce.
  # `-F 32` forces FAT32 specifically: dosfstools defaults to FAT16 below
  # its own size threshold, and fsd.c3 only parses the FAT32 BPB layout.
  # mtools' mcopy writes into the image directly, no root/loop-mount
  # needed. 64M comfortably clears FAT32's own minimum practical size.
  rm -f build/disk.img
  dd if=/dev/zero of=build/disk.img bs=1M count=64 status=none
  mkfs.vfat -F 32 build/disk.img > /dev/null
  mcopy -i build/disk.img disk/*.txt ::
  # "My Long File Name.txt" — a real VFAT long-filename (LFN) fixture,
  # exercising fat32.c3's own LFN read support (see docs/devlog.md and
  # shell_test.c3's own lfntest). mcopy itself (a real, independent
  # VFAT implementation, not this driver) writes the genuine on-disk
  # LFN chain here — renamed on copy from the existing hello.txt source
  # rather than a new space-containing file under disk/, since an
  # unquoted glob (disk/*.txt above) would otherwise word-split a real
  # space in a source filename.
  mcopy -i build/disk.img disk/hello.txt "::My Long File Name.txt"
  # disk/subdir/ exercises fat32.c3's read-only subdirectory support
  # (see docs/devlog.md) — mmd creates the directory entry, mcopy then
  # writes into it same as the root.
  mmd -i build/disk.img ::subdir
  mcopy -i build/disk.img disk/subdir/*.txt ::subdir
  # disk's own emptydir/ exercises fat32_delete()'s rmdir support (see
  # docs/devlog.md) — a genuinely empty directory to actually remove.
  # This driver has no mkdir of its own, so the positive case (delete
  # succeeds) needs a real, pre-seeded empty directory; the negative
  # case (refuses a non-empty one) is already covered by subdir itself.
  mmd -i build/disk.img ::emptydir
  # disk's own nestdir/ (a file plus a nested subdirectory, itself
  # containing a file) exercises fat32_delete_recursive()'s actual
  # recursion — emptydir above only proves the empty-directory case,
  # already covered by the plain (non-recursive) fat32_delete().
  mmd -i build/disk.img ::nestdir
  mcopy -i build/disk.img disk/subdir/nested.txt ::nestdir/inner.txt
  mmd -i build/disk.img ::nestdir/innerdir
  mcopy -i build/disk.img disk/subdir/nested.txt ::nestdir/innerdir/inner2.txt
  # disk's own bin/ — exercises exec() (user/user.c3's own chunked-read
  # SYS_EXEC wrapper, see docs/devlog.md): a real, already-built binary
  # (build/user/echod.bin — known behavior, already exercised at boot as
  # pid 2) copied in as the payload, rather than writing a new one just
  # for this test.
  mmd -i build/disk.img ::bin
  mcopy -i build/disk.img build/user/echod.bin ::bin/echod
  # bin/echod.elf — same idea, but the real ELF (build/user/echod.elf,
  # before objcopy strips it to the flat bin/echod above), exercising
  # SYS_EXEC's own ELF loader (see docs/devlog.md): 3 PT_LOAD segments,
  # 3 different permission combinations, a real .bss gap. Not a
  # replacement for bin/echod — elftest execs this one specifically,
  # runtest/argvtest/pathtest keep using the flat binary unchanged.
  mcopy -i build/disk.img build/user/echod.elf ::bin/echod.elf
  # bin/{cat,ls,write,rm,mkdir,mv} — the real, argv-taking utilities
  # shell.c3's own /bin/ fallback branch execs (see docs/devlog.md),
  # replacing what used to be hardcoded shell builtins.
  for u in cat ls echo true false head whoami write rm mkdir mv usbrw fsd gpio wasm; do
    mcopy -i build/disk.img "build/user/$u.bin" "::bin/$u"
  done
  for w in build/wasm/*.wasm; do mcopy -i build/disk.img "$w" "::$(basename "$w")"; done

  # bigfile.bin — deterministic byte[i] = i % 256 pattern, 300000 bytes,
  # genuinely past ext2's own single-indirect reach even at the smallest
  # 1024-byte block size used below (12 + 256 = 268 blocks = 268KB) —
  # exercises user/fs/ext2.c3's double-indirect block support
  # (ext2_resolve_block/ext2_resolve_leaf, see docs/devlog.md). Shared
  # by both ext2 images below (single-mount and dual-mount) rather than
  # regenerated twice. Generated at build time, not committed — this
  # project's own disk-ext2/ fixtures are small, hand-authored text
  # files; a 300KB generated binary belongs in build/ like every other
  # generated image, not in version control. The pattern is
  # independently recomputable by shell.c3's own bigreadtest, which
  # never needs to read this exact file back to know what to expect.
  python3 -c "import sys; sys.stdout.buffer.write(bytes(i % 256 for i in range(300000)))" > build/bigfile_fixture.bin

  echo "==> Building disk image (ext2, for scripts/launch64_ext2.sh)..."
  # Additional, not a replacement — build/disk.img (FAT32) above stays
  # the default image every other script/test uses. This one exists
  # purely to exercise user/fs/ext2.c3 on QEMU (see docs/devlog.md's
  # filesystem-abstraction entry): a whole-disk ext2 volume (no MBR,
  # same reasoning as the FAT32 image above), seeded via `debugfs -w`
  # (part of e2fsprogs) rather than a loop-mount, so this needs no root
  # either. `-b 1024` keeps the block size comfortably under
  # user/fs/ext2.c3's own EXT2_MAX_BLOCK_SIZE — not required for
  # correctness on a small image (mke2fs would pick 1024 by default
  # here anyway), just explicit. Reuses the name "hello.txt" (with
  # distinct content from disk/hello.txt) so the shell's existing
  # readfile command exercises either filesystem unchanged.
  rm -f build/disk_ext2.img
  dd if=/dev/zero of=build/disk_ext2.img bs=1M count=16 status=none
  mke2fs -q -F -b 1024 build/disk_ext2.img
  debugfs -w -R "write disk-ext2/hello.txt hello.txt" build/disk_ext2.img > /dev/null
  # disk-ext2/subdir/ exercises ext2.c3's read-only subdirectory support
  # (see docs/devlog.md), same purpose as disk/subdir/ above.
  debugfs -w -R "mkdir subdir" build/disk_ext2.img > /dev/null
  debugfs -w -R "write disk-ext2/subdir/nested.txt subdir/nested.txt" build/disk_ext2.img > /dev/null
  # disk_ext2's own emptydir/ — same rmdir-testing purpose as disk.img's
  # own emptydir/ above.
  debugfs -w -R "mkdir emptydir" build/disk_ext2.img > /dev/null
  # disk-ext2's own nestdir/ — same recursive-delete-testing purpose
  # as disk.img's own nestdir/ above.
  debugfs -w -R "mkdir nestdir" build/disk_ext2.img > /dev/null
  debugfs -w -R "write disk-ext2/subdir/nested.txt nestdir/inner.txt" build/disk_ext2.img > /dev/null
  debugfs -w -R "mkdir nestdir/innerdir" build/disk_ext2.img > /dev/null
  debugfs -w -R "write disk-ext2/subdir/nested.txt nestdir/innerdir/inner2.txt" build/disk_ext2.img > /dev/null
  # The canonical Plan 9-style root tree (docs/filesystem-layout.md,
  # roadmap §1). /proc /srv /env are namespace mounts, not real dirs, so
  # they're absent here. Kept in sync by hand with the same list in
  # scripts/populate_duo_bin.sh (real Duo) — same convention as the
  # binary list below.
  for d in bin lib usr usr/root usr/glenda adm tmp mnt; do
    debugfs -w -R "mkdir $d" build/disk_ext2.img > /dev/null
  done
  printf '0:root\n1000:glenda\n65534:none\n' > build/adm_users_fixture
  debugfs -w -R "write build/adm_users_fixture adm/users" build/disk_ext2.img > /dev/null
  # A deliberately root-only file (mode 0600) so §2's read-permission
  # enforcement (ext2_read_allowed) is testable: `su glenda; cat
  # adm/secret` must fail. debugfs's `sif` sets the raw i_mode.
  printf 'top secret\n' > build/adm_secret_fixture
  debugfs -w -R "write build/adm_secret_fixture adm/secret" build/disk_ext2.img > /dev/null
  debugfs -w -R "sif adm/secret mode 0100600" build/disk_ext2.img > /dev/null
  debugfs -w -R "write build/user/echod.bin bin/echod" build/disk_ext2.img > /dev/null
  debugfs -w -R "write build/user/echod.elf bin/echod.elf" build/disk_ext2.img > /dev/null
  for u in cat ls echo true false head whoami write rm mkdir mv usbrw fsd gpio wasm; do
    debugfs -w -R "write build/user/$u.bin bin/$u" build/disk_ext2.img > /dev/null
  done
  for w in build/wasm/*.wasm; do debugfs -w -R "write $w $(basename "$w")" build/disk_ext2.img > /dev/null; done
  debugfs -w -R "write build/bigfile_fixture.bin bigfile.bin" build/disk_ext2.img > /dev/null

  echo "==> Building disk image (dual ext2+ext2, for scripts/launch64_dual.sh)..."
  # Third test image — exercises fsd/fsd2 mounting two filesystems at once
  # (src/kernel.c3's conditional fsd2 spawn, gated on
  # board::HAS_SECOND_FS_PARTITION). One flat image, two independent
  # ext2 filesystems at fixed byte offsets, no MBR/partition table —
  # mirrors how the Duo reads two real partitions off one card with no
  # partition-table parsing in fsd.c3 either way.
  #
  # Both ext2, not FAT32+ext2 like this image used to be — this
  # project's own Plan9-style reorganization (docs/devlog.md) makes ext2
  # root everywhere and FAT32 boot-partition-only everywhere; QEMU has
  # no boot-ROM-reads-a-partition step to mirror (it loads the kernel
  # ELF directly via -kernel), so FAT32 has no structural role in this
  # image anymore. disk.img above stays FAT32-only, on its own, purely
  # as ongoing regression coverage for the FAT32 backend itself.
  #
  # Partition 1 (root) MUST start at sector 0 — fsd's own
  # FS_PARTITION_START_SECTOR (boards/qemu/board.c3) is one fixed
  # constant shared with the default disk.img above (confirmed the hard
  # way while first building this image with FAT32: a different offset
  # here just means the first fsd finds nothing). Partition 2 (bound at
  # "/mnt/fs2/" — user/shell.c3) goes at sector 18432, matching
  # FS_PARTITION_2_START_SECTOR. Both built as scratch files first
  # (mke2fs has no offset option) then `dd`'d into place.
  rm -f build/disk_dual.img build/disk_dual_root_part.img build/disk_dual_ext2_part.img
  dd if=/dev/zero of=build/disk_dual.img bs=1M count=20 status=none

  dd if=/dev/zero of=build/disk_dual_root_part.img bs=1M count=8 status=none
  mke2fs -q -F -b 1024 build/disk_dual_root_part.img
  debugfs -w -R "write disk-ext2/hello.txt hello.txt" build/disk_dual_root_part.img > /dev/null
  debugfs -w -R "mkdir subdir" build/disk_dual_root_part.img > /dev/null
  debugfs -w -R "write disk-ext2/subdir/nested.txt subdir/nested.txt" build/disk_dual_root_part.img > /dev/null
  debugfs -w -R "mkdir emptydir" build/disk_dual_root_part.img > /dev/null
  debugfs -w -R "mkdir nestdir" build/disk_dual_root_part.img > /dev/null
  debugfs -w -R "write disk-ext2/subdir/nested.txt nestdir/inner.txt" build/disk_dual_root_part.img > /dev/null
  debugfs -w -R "mkdir nestdir/innerdir" build/disk_dual_root_part.img > /dev/null
  debugfs -w -R "write disk-ext2/subdir/nested.txt nestdir/innerdir/inner2.txt" build/disk_dual_root_part.img > /dev/null
  # mnt/ — a real, initially-empty directory, Plan9-style: an ordinary
  # place other services get mounted onto (see docs/devlog.md), nothing
  # structurally special about it. The actual "/mnt/fs2/" binding is
  # namespace-prefix resolution (intercepts before this directory's own
  # listing is ever consulted) — this exists purely so `ls /mnt`/`ls
  # mnt` behaves sensibly, not because anything reads its contents.
  # Canonical root tree — same set as disk_ext2.img above / the real
  # Duo (docs/filesystem-layout.md).
  for d in bin lib usr usr/root usr/glenda adm tmp mnt; do
    debugfs -w -R "mkdir $d" build/disk_dual_root_part.img > /dev/null
  done
  debugfs -w -R "write build/adm_users_fixture adm/users" build/disk_dual_root_part.img > /dev/null
  debugfs -w -R "write build/user/echod.bin bin/echod" build/disk_dual_root_part.img > /dev/null
  debugfs -w -R "write build/user/echod.elf bin/echod.elf" build/disk_dual_root_part.img > /dev/null
  for u in cat ls echo true false head whoami write rm mkdir mv usbrw fsd gpio wasm; do
    debugfs -w -R "write build/user/$u.bin bin/$u" build/disk_dual_root_part.img > /dev/null
  done
  for w in build/wasm/*.wasm; do debugfs -w -R "write $w $(basename "$w")" build/disk_dual_root_part.img > /dev/null; done
  dd if=build/disk_dual_root_part.img of=build/disk_dual.img bs=512 seek=0 conv=notrunc status=none
  rm -f build/disk_dual_root_part.img

  dd if=/dev/zero of=build/disk_dual_ext2_part.img bs=1M count=8 status=none
  mke2fs -q -F -b 1024 build/disk_dual_ext2_part.img
  debugfs -w -R "write disk-ext2/hello.txt hello.txt" build/disk_dual_ext2_part.img > /dev/null
  debugfs -w -R "mkdir subdir" build/disk_dual_ext2_part.img > /dev/null
  debugfs -w -R "write disk-ext2/subdir/nested.txt subdir/nested.txt" build/disk_dual_ext2_part.img > /dev/null
  debugfs -w -R "mkdir emptydir" build/disk_dual_ext2_part.img > /dev/null
  # bin/echod, bin/echod.elf — the exec()-family "2" test variants
  # (runtest2/argvtest2/pathtest2/elftest2, shell.c3) need these
  # reachable at "/mnt/fs2/bin/echod"/"/mnt/fs2/bin/echod.elf"
  # specifically, not just via the default (root) namespace — see
  # docs/devlog.md for why an unprefixed path can't be trusted to reach
  # the second mount whenever a root mount also exists.
  debugfs -w -R "mkdir bin" build/disk_dual_ext2_part.img > /dev/null
  debugfs -w -R "write build/user/echod.bin bin/echod" build/disk_dual_ext2_part.img > /dev/null
  debugfs -w -R "write build/user/echod.elf bin/echod.elf" build/disk_dual_ext2_part.img > /dev/null
  for u in cat ls echo true false head whoami write rm mkdir mv usbrw fsd gpio wasm; do
    debugfs -w -R "write build/user/$u.bin bin/$u" build/disk_dual_ext2_part.img > /dev/null
  done
  for w in build/wasm/*.wasm; do debugfs -w -R "write $w $(basename "$w")" build/disk_dual_ext2_part.img > /dev/null; done
  # bigfile.bin — same double-indirect-block fixture as the single-mount
  # ext2 image above, needed here too since bigreadtest always targets
  # "/mnt/fs2/bigfile.bin" (unambiguous, same reasoning as bin/echod above).
  debugfs -w -R "write build/bigfile_fixture.bin bigfile.bin" build/disk_dual_ext2_part.img > /dev/null
  dd if=build/disk_dual_ext2_part.img of=build/disk_dual.img bs=512 seek=18432 conv=notrunc status=none
  rm -f build/disk_dual_ext2_part.img

  echo "==> Building disk image (exFAT, for scripts/launch64_exfat.sh)..."
  # Additional, opt-in test target — same status as the ext2 and dual
  # images above (launch64.sh / build/disk.img / FAT32 stays the
  # default). exFAT has no pure-userspace image editor (exfatprogs ships
  # only mkfs/fsck/dump/label), so this one needs a real exFAT mount to
  # populate — udisksctl (no root) or passwordless sudo. Best-effort: a
  # build host with neither simply doesn't get build/disk_exfat.img, and
  # scripts/launch64_exfat.sh is the only thing that reads it. See
  # scripts/mk_exfat_image.sh's own header and docs/devlog.md's exFAT
  # entry.
  bash scripts/mk_exfat_image.sh || echo "    (skipped — see scripts/mk_exfat_image.sh; exFAT boot test unavailable on this host)"

  echo "==> Compiling kernel to LLVM IR..."
  rm -rf build/obj build/llvm build/obj_medany build/kernel.*
  c3c build racccoon --no-entry --safe=no --riscv-cpu=rvimac --riscv-abi=double --emit-llvm

  # RV64 port: c3c's own object-file codegen only knows RISC-V's default
  # "small"/medlow code model, which requires every absolute address it
  # emits (every global variable, every string literal, every rodata
  # constant) to fit in the signed 32-bit range — i.e. below 2GiB. This
  # kernel boots at 0x80200000 (OpenSBI's fixed RV64 payload address,
  # just past the 2GiB line), so under medlow *every* such reference is
  # out of range; ld.lld catches this at link time
  # (R_RISCV_HI20 out of range). c3c has no --mcmodel flag to ask for
  # "medany" (PC-relative auipc-based addressing, valid across the full
  # 64-bit space) — the standard, correct code model for exactly this
  # situation, and what every real RV64 kernel (Linux, OpenSBI itself)
  # actually uses. So we take the one escape hatch --emit-llvm gives us:
  # recompile c3c's own LLVM IR ourselves via llc, this time asking for
  # -code-model=medium (LLVM's name for RISC-V's "medany"). See
  # docs/devlog.md for the full debugging story — this took a while to
  # pin down.
  echo "==> Recompiling IR with the medium (medany) code model..."
  mkdir -p build/obj_medany
  for f in build/llvm/elf-riscv64/*.ll; do
    name=$(basename "$f" .ll)
    $LLC -mtriple=riscv64-unknown-elf -mattr=+m,+a,+c,+f,+d \
      -code-model=medium -relocation-model=static \
      -filetype=obj -o "build/obj_medany/$name.o" "$f"
  done

  # QEMU embeds the *test* shell (user/shell_test.c3 — every dev/
  # regression-test builtin this project has accumulated), not the
  # trimmed production shell.bin the real Duo build embeds
  # (scripts/build_duo.sh) — see docs/devlog.md. src/kernel.c3's
  # _binary_shell_bin_start/_end symbols are board-agnostic and fixed by
  # name, and objcopy -Ibinary derives the embedded symbol name from the
  # input file's own basename — so shell_test.bin.o's symbols would come
  # out named _binary_shell_test_bin_*, not matching. Re-embedding
  # shell_test.bin under the literal name "shell.bin" in its own
  # directory (not build/user/, which already holds the real
  # build/user/shell.bin.o for Duo) sidesteps that without changing
  # build_user.sh's own one-name-per-binary convention or touching
  # kernel.c3 at all.
  echo "==> Re-embedding the test shell as this kernel's own shell..."
  mkdir -p build/user_qemu_shell
  cp build/user/shell_test.bin build/user_qemu_shell/shell.bin
  # llvm-mc + .incbin (see build_user.sh's matching comment): -Ibinary
  # wrappers carry soft-float e_flags, which ld.lld now rejects against
  # the rv64imafdc kernel.
  (
    cd build/user_qemu_shell
    cat > shell.bin.s <<'STUB'
	.section .rodata._binary_shell_bin, "a"
	.balign 8
	.globl _binary_shell_bin_start
_binary_shell_bin_start:
	.incbin "shell.bin"
	.globl _binary_shell_bin_end
_binary_shell_bin_end:
STUB
    "${LLVM_MC:-llvm-mc}" --triple=riscv64 --mattr=+m,+a,+c,+f,+d --target-abi=lp64d \
      --filetype=obj -o shell.bin.o shell.bin.s
  )

  echo "==> Linking kernel.elf (with embedded shell)..."
  # Built rv64imafdc/lp64d (--riscv-abi=double above + llc -mattr=+f,+d), so
  # LLVM emits hardware FP inline — no compiler-rt soft-float builtins to
  # resolve, hence no libclang_rt.builtins-riscv64 needed. (Pre-FPU this
  # linked against src/kernel/softfloat_stubs.c3's panic stubs instead.)
  $LLVM_LLD \
    build/obj_medany/*.o \
    build/user_qemu_shell/shell.bin.o \
    build/user/echod.bin.o \
    build/user/diskd.bin.o \
    build/user/sdd.bin.o \
    build/user/fsd.bin.o \
    build/user/procd.bin.o \
    build/user/envd.bin.o \
    build/user/usbd.bin.o \
    build/user/ethd.bin.o \
    build/user/netd.bin.o \
    build/user/gpiod.bin.o \
    -T src/kernel.ld \
    -Map=build/kernel.map \
    -o build/kernel.elf

  echo "==> Done: build/kernel.elf"
)
