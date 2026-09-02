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

# ext2_seed_tree <hostdir> <destdir-on-image> <image>
# Recursively copy a host directory into an ext2 image via debugfs
# (mkdir each subdir, write each file). Used for the on-device GOROOT +
# build cache (Stage 4.4) — hundreds of small files.
ext2_seed_tree() {
  local src="$1" dst="$2" img="$3"
  debugfs -w -R "mkdir $dst" "$img" > /dev/null 2>&1 || true
  ( cd "$src" && find . -mindepth 1 -type d ) | sed 's#^\./##' | while read -r d; do
    debugfs -w -R "mkdir $dst/$d" "$img" > /dev/null 2>&1
  done
  ( cd "$src" && find . -type f ) | sed 's#^\./##' | while read -r f; do
    debugfs -w -R "write $src/$f $dst/$f" "$img" > /dev/null 2>&1
  done
}

(
  cd "$(dirname "$0")/.."

  # Build user app first (produces build/user/shell.bin.o)
  bash scripts/build_user.sh

  # The C library + any C test programs (roadmap §7 — libc / self-host
  # track). No-ops cleanly if there's no riscv64 C compiler; the c3
  # userspace doesn't depend on it. Produces build/libc/*.bin.
  bash lib/racccoon-libc/build.sh

  # TinyCC, cross-built against that libc (roadmap §7.7). No-ops unless
  # the third_party/tinycc submodule is checked out. Produces
  # build/tcc/tcc.bin + build/tcc/lib/ (the CONFIG_TCCDIR payload).
  bash scripts/build_tcc.sh

  # Hand-built .wasm test fixtures for /bin/wasm (no wat2wasm on this
  # host — the bytes are assembled by the Python script). Seeded onto
  # every disk image below next to /bin. Cleaned first so a renamed or
  # removed fixture doesn't linger on the images.
  rm -rf build/wasm
  python3 test/mkwasm.py build/wasm

  # Real programs compiled from Zig (test/wasm-src/*.zig) — proof
  # /bin/wasm runs actual compiler output, not just hand-assembled
  # bytes. Built with `zig` if it's on PATH, else the committed
  # .wasm next to the source is used as-is.
  for z in test/wasm-src/*.zig; do
    [ -e "$z" ] || continue
    name=$(basename "$z" .zig)
    if command -v zig >/dev/null 2>&1 && \
       zig build-exe "$z" -target wasm32-freestanding -O ReleaseSmall \
         -fno-entry --export=_start -femit-bin="build/wasm/$name.wasm" 2>/dev/null; then
      cp "build/wasm/$name.wasm" "test/wasm-src/$name.wasm"   # refresh the committed fallback
    else
      cp "test/wasm-src/$name.wasm" "build/wasm/$name.wasm"
    fi
    rm -f "$name.wasm.o" "build/wasm/$name.wasm.o" 2>/dev/null
  done

  # Go programs for racccoon (go/cmd/*, via the GOOS=tamago toolchain).
  # No-op unless TAMAGO points at a tamago-go/bin/go — build_go.sh says
  # so and exits 0. Seeded as /bin/go-<name> onto the images below;
  # gotest / gostage{2,3}test (shell_test.c3) skip cleanly if the binary
  # isn't there, same as tcctest without /bin/tcc. See docs/go-port-plan.md.
  rm -rf build/go
  if [ -n "${TAMAGO:-}" ]; then
    for gd in go/cmd/*/; do
      [ -e "$gd" ] || continue
      bash scripts/build_go.sh "$(basename "$gd")" || true
    done

    # Stage 4 (docs/go-port-plan.md): racccoon's own go tool compile /
    # go tool link, plus the stdlib object closure they need to link a
    # real program (build_go_toolchain.sh — cross-built on the host,
    # same bootstrapping idea as lib/tcc's prebuilt crt1.o/libtcc1.a).
    # Seeded below under /lib/go/ and /bin/go-{compile,link}.
    bash scripts/build_go.sh cmd/compile || true
    bash scripts/build_go.sh cmd/link || true
    bash scripts/build_go_toolchain.sh || true

    # Stage 4.4: the `go` command runs on racccoon — `go version` /
    # `go env`, and `go build` (docs/go-port-plan.md). `go.elf` bakes
    # GOROOT=/goroot; cmd/asm joins compile/link as the third tool;
    # build_go_goroot.sh assembles /goroot (tools, headers, stdlib
    # source closure, runtime/goos overlay) + a prepopulated build
    # cache. All seeded below.
    bash scripts/build_go.sh cmd/go || true
    bash scripts/build_go.sh cmd/asm || true
    bash scripts/build_go_goroot.sh || true
  fi

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
  # Stage 4's go-compile / go-link are too big for this small FAT32
  # image (and only meaningfully testable next to the toolchain
  # closure seeded onto disk_ext2.img) — skip them here.
  for g in build/go/*.elf; do
    case "$(basename "$g")" in compile.elf|link.elf|go.elf|gostage*.elf) continue ;; esac
    [ -e "$g" ] && mcopy -i build/disk.img "$g" "::bin/go-$(basename "$g" .elf)"
  done
  # bin/{cat,ls,write,rm,mkdir,mv} — the real, argv-taking utilities
  # shell.c3's own /bin/ fallback branch execs (see docs/devlog.md),
  # replacing what used to be hardcoded shell builtins.
  for u in cat ls echo true false head whoami write rm mkdir mv chmod chown usbrw fsd gpio wasm; do
    mcopy -i build/disk.img "build/user/$u.bin" "::bin/$u"
  done
  for w in build/wasm/*.wasm; do mcopy -i build/disk.img "$w" "::$(basename "$w")"; done
  # C test programs (roadmap §7), if the C libc build produced any.
  for c in build/libc/*.bin; do [ -e "$c" ] && mcopy -i build/disk.img "$c" "::bin/$(basename "$c" .bin)"; done
  bash scripts/seed_tcc.sh fat32 build/disk.img

  # manyfiles/ — 60 entries, past FS_LIST's 31-per-reply cap (see the
  # matching block on the ext2 image below). test/c-src/pagelisttest.c.
  printf 'x\n' > build/tiny_fixture
  mmd -i build/disk.img ::manyfiles 2>/dev/null || true
  for i in $(seq -w 0 59); do mcopy -o -i build/disk.img build/tiny_fixture "::manyfiles/e$i"; done

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
  # correctness (mke2fs would pick 1024 by default here anyway), just
  # explicit. Reuses the name "hello.txt" (with distinct content from
  # disk/hello.txt) so the shell's existing readfile command exercises
  # either filesystem unchanged.
  #
  # 256 MiB, not the original 16 — the go-port Stage 4 toolchain
  # binaries (go-compile ~22 MiB, go-link ~6 MiB) plus their stdlib
  # object closure (~15 MiB, seeded below) no longer fit in 16 MiB.
  # 262144 1-KiB blocks / 8192 blocks-per-group = 32 groups, nowhere
  # near ext2.c3's own EXT2_MAX_GROUPS (2048) ceiling.
  rm -f build/disk_ext2.img
  # 448 MiB — the Stage 4.4 on-device GOROOT (stdlib source closure +
  # tool binaries) plus a prepopulated build cache is ~60 MiB on top of
  # the Stage 4.3 toolchain payload. 458752 1-KiB blocks / 8192 per
  # group = 56 groups, far under ext2.c3's EXT2_MAX_GROUPS (2048).
  dd if=/dev/zero of=build/disk_ext2.img bs=1M count=448 status=none
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
  for g in build/go/*.elf; do
    # go.elf is the `go` command itself — seeded as /bin/go with its
    # /goroot below, not as /bin/go-go.
    case "$(basename "$g")" in go.elf) continue ;; esac
    [ -e "$g" ] && debugfs -w -R "write $g bin/go-$(basename "$g" .elf)" build/disk_ext2.img > /dev/null
  done
  # Stage 4.4 (docs/go-port-plan.md): `/bin/go` + the on-device GOROOT
  # (build_go_goroot.sh — tools, headers, the stdlib source closure, the
  # racccoon runtime/goos overlay) + a prepopulated /gocache so
  # `go build` only compiles runtime / runtime/goos / the user's main
  # on-device, then links. /gomodcache is the (empty) module cache;
  # /gomod is a one-file module for gobuildtest.
  if [ -d build/go/goroot ]; then
    debugfs -w -R "write build/go/go.elf bin/go" build/disk_ext2.img > /dev/null
    ext2_seed_tree build/go/goroot goroot build/disk_ext2.img
    ext2_seed_tree build/go/gocache gocache build/disk_ext2.img
    debugfs -w -R "mkdir gomodcache" build/disk_ext2.img > /dev/null
    debugfs -w -R "mkdir gomod" build/disk_ext2.img > /dev/null
    printf 'module gobuildtest\n\ngo 1.27\n' > build/go/gomod_go.mod
    cat > build/go/gomod_main.go <<'GOEOF'
package main

func main() {
	println("hello from go build on racccoon")
	s := 0
	for i := 1; i <= 100; i++ {
		s += i
	}
	println("sum 1..100 =", s)
}
GOEOF
    debugfs -w -R "write build/go/gomod_go.mod gomod/go.mod" build/disk_ext2.img > /dev/null
    debugfs -w -R "write build/go/gomod_main.go gomod/main.go" build/disk_ext2.img > /dev/null
  fi
  # Stage 4 (docs/go-port-plan.md): the stdlib object closure + importcfg
  # go-compile/go-link need to build+link go/cmd/hello entirely on-device
  # (build_go_toolchain.sh). /lib/go/pkg/*.a, /lib/go/importcfg{,.link},
  # /hello.go. No-op (dir doesn't exist) without TAMAGO.
  if [ -d build/go/toolchain ]; then
    debugfs -w -R "mkdir lib/go" build/disk_ext2.img > /dev/null
    debugfs -w -R "mkdir lib/go/pkg" build/disk_ext2.img > /dev/null
    for a in build/go/toolchain/pkg/*.a; do
      [ -e "$a" ] && debugfs -w -R "write $a lib/go/pkg/$(basename "$a")" build/disk_ext2.img > /dev/null
    done
    debugfs -w -R "write build/go/toolchain/importcfg lib/go/importcfg" build/disk_ext2.img > /dev/null
    debugfs -w -R "write build/go/toolchain/importcfg.link lib/go/importcfg.link" build/disk_ext2.img > /dev/null
    debugfs -w -R "write build/go/toolchain/hello.go hello.go" build/disk_ext2.img > /dev/null
  fi
  for u in cat ls echo true false head whoami write rm mkdir mv chmod chown usbrw fsd gpio wasm; do
    debugfs -w -R "write build/user/$u.bin bin/$u" build/disk_ext2.img > /dev/null
  done
  for c in build/libc/*.bin; do [ -e "$c" ] && debugfs -w -R "write $c bin/$(basename "$c" .bin)" build/disk_ext2.img > /dev/null; done
  bash scripts/seed_tcc.sh ext2 build/disk_ext2.img
  for w in build/wasm/*.wasm; do debugfs -w -R "write $w $(basename "$w")" build/disk_ext2.img > /dev/null; done
  debugfs -w -R "write build/bigfile_fixture.bin bigfile.bin" build/disk_ext2.img > /dev/null

  # manyfiles/ — 60 entries in one directory, past FS_LIST's 31-per-reply
  # cap, so `ls` / readdir pagination (user.c3 fs_list / rc_fs.c) is
  # actually exercised across pages. Seeded with debugfs (racccoon's own
  # ext2_create_file still appends a whole dir block per file — a
  # separate limit; see ext2.c3's header). test/c-src/pagelisttest.c.
  printf 'x\n' > build/tiny_fixture
  debugfs -w -R "mkdir manyfiles" build/disk_ext2.img > /dev/null
  for i in $(seq -w 0 59); do
    debugfs -w -R "write build/tiny_fixture manyfiles/e$i" build/disk_ext2.img > /dev/null
  done

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
  # Same exclusion as the FAT32 image above — too big for this partition.
  for g in build/go/*.elf; do
    case "$(basename "$g")" in compile.elf|link.elf|go.elf|gostage*.elf) continue ;; esac
    [ -e "$g" ] && debugfs -w -R "write $g bin/go-$(basename "$g" .elf)" build/disk_dual_root_part.img > /dev/null
  done
  for u in cat ls echo true false head whoami write rm mkdir mv chmod chown usbrw fsd gpio wasm; do
    debugfs -w -R "write build/user/$u.bin bin/$u" build/disk_dual_root_part.img > /dev/null
  done
  for w in build/wasm/*.wasm; do debugfs -w -R "write $w $(basename "$w")" build/disk_dual_root_part.img > /dev/null; done
  for c in build/libc/*.bin; do [ -e "$c" ] && debugfs -w -R "write $c bin/$(basename "$c" .bin)" build/disk_dual_root_part.img > /dev/null; done
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
  # Same exclusion as the FAT32 image above — too big for this partition.
  for g in build/go/*.elf; do
    case "$(basename "$g")" in compile.elf|link.elf|go.elf|gostage*.elf) continue ;; esac
    [ -e "$g" ] && debugfs -w -R "write $g bin/go-$(basename "$g" .elf)" build/disk_dual_ext2_part.img > /dev/null
  done
  for u in cat ls echo true false head whoami write rm mkdir mv chmod chown usbrw fsd gpio wasm; do
    debugfs -w -R "write build/user/$u.bin bin/$u" build/disk_dual_ext2_part.img > /dev/null
  done
  for w in build/wasm/*.wasm; do debugfs -w -R "write $w $(basename "$w")" build/disk_dual_ext2_part.img > /dev/null; done
  for c in build/libc/*.bin; do [ -e "$c" ] && debugfs -w -R "write $c bin/$(basename "$c" .bin)" build/disk_dual_ext2_part.img > /dev/null; done
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

  # build_tcc.sh applied lib/tcc/racccoon.patch to the submodule in place
  # (seed_tcc.sh needs the patched riscv64-link.c on the images). Revert
  # it now that seeding is done, so `git status` stays clean.
  if [ -e third_party/tinycc/.git ]; then
    git -C third_party/tinycc checkout -- riscv64-link.c 2>/dev/null || true
  fi
)
