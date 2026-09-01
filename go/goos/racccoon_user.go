// Copyright 2026 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

//go:build tamago && riscv64

// Package goos is the runtime/goos implementation for GOOS=tamago Go
// binaries running as racccoon userspace processes, selected via the
// GOOSPKG build setting (see docs/go-port-plan.md).
//
// It is a direct adaptation of tamago-go's own
// src/runtime/goos/linux_user.go — the same ~10 hooks, wired to
// racccoon's ecall ABI (syscall number in a3; args a0/a1/a2, a4 for a
// 4th; result a0) instead of the Linux syscall ABI.
//
// STAGE 0 SCAFFOLD — Nanotime and GetRandomData are stubs, no Task
// (single-threaded, GOMAXPROCS=1). See the plan's Stage 1 for what
// makes this actually run.
package goos

import "unsafe"

// adapted from tamago-go src/runtime/goos/linux_user.go
const (
	bits = 32 << (^uint(0) >> 63) / 8

	ArenaBaseOffset     = 0
	HeapAddrBits        = (8-bits)*3 + bits*5 // 64-bit: 40
	LogHeapArenaBytes   = (2 + 20)
	LogPallocChunkPages = 9
	MinPhysPageSize     = 4096
	StackSystem         = 0
)

var (
	// RamStart / RamSize / RamStackOffset describe the one contiguous
	// region the runtime gets for its heap and g0 stack. On racccoon
	// there is no fixed physical map — CPUInit (asm) SYS_MAPs RamSize
	// bytes at startup and writes the returned base into RamStart and
	// Bloc before the Go world starts.
	RamStart uint
	// RamSize is the SYS_MAP region for the whole Go heap + g0 stack.
	// SYS_MAP is eager (every page really allocated + zeroed at startup),
	// so this trades startup cost for GC headroom. 64 MiB is plenty —
	// the gostage2 GC test's working set is well under 10 MiB — and
	// keeps `gohello` startup quick even on emulated hardware. Fits
	// under QEMU's board::HEAP_MAX_BYTES (512 MiB); the JH7110 (2 GiB)
	// can take far more. CPUInit falls back to 8 MiB if a board refuses.
	RamSize        uint = 64 << 20
	RamStackOffset uint = 0x1000

	// Bloc redefines the heap start (osinit picks it up). Set from asm
	// in CPUInit alongside RamStart.
	Bloc uintptr

	Exit = sys_exit

	// Idle: racccoon userspace is cooperative, so the useful thing to
	// do while a runtime semaphore spin-waits is yield the timeslice.
	Idle = func(until int64) { sys_yield() }

	ProcID func() uint64
	Wake   func(uint64)

	// Task stays nil — racccoon has rfork(RFPROC|RFMEM) + futex and
	// could do real multi-M scheduling, but Stage 1 is single-threaded
	// (GOMAXPROCS=1). newosproc throws only if it's ever actually
	// called, which it isn't at GOMAXPROCS=1.
	Task func(sp, mp, gp, fn unsafe.Pointer)

	Hwinit0  = func() {}
	InitRNG  = func() {}
	Hwinit1  = func() {}
	Nanotime = nanotime
)

// defined in racccoon_riscv64.s
func CPUInit()
func sys_putchar(c *byte)
func sys_exit(code int32)
func sys_yield()
func sys_timebase() int64 // the `time` CSR tick rate (Hz) — SYS_TIMEBASE
func rdtime() int64       // the `time` CSR itself

// preallocated to avoid an allocation on the panic path
var pchar [1]byte

// Printk writes one byte to the racccoon console (SYS_PUTCHAR).
func Printk(c byte) {
	pchar[0] = c
	sys_putchar(&pchar[0])
}

// tbHz caches the `time` CSR rate (SYS_TIMEBASE) — a syscall, and
// nanotime() is on hot paths (scheduler, GC, timers). 0 until the first
// call. Single-threaded, so no lock.
var tbHz int64

// nanotime converts the monotonic `time` CSR into nanoseconds. The
// split-then-recombine avoids the int64 overflow a plain
// ticks*1e9/hz would hit after ~500 s at a 10 MHz timebase.
func nanotime() int64 {
	if tbHz == 0 {
		tbHz = sys_timebase()
		if tbHz == 0 {
			return 0
		}
	}
	t := rdtime()
	return (t/tbHz)*1e9 + (t%tbHz)*1e9/tbHz
}

// GetRandomData — STAGE 0 STUB (fixed bytes). racccoon has no RNG
// syscall yet; the JH7110 has a TRNG worth a SYS_RANDOM later.
func GetRandomData(b []byte) {
	for i := range b {
		b[i] = byte(i * 2654435761)
	}
}

// FS routes package os's filesystem operations to racccoon's fsd server
// instead of GOOS=tamago's in-memory fs. It is installed by
// racccoon_fs.go's init(), so every racccoon Go binary gets real
// filesystem access with no import of its own. The syscall-side call
// sites are a small toolchain patch (lib/go/racccoon.patch); keep this
// type in sync with that patch's copy in
// src/runtime/goos/linux_user.go. See docs/go-port-plan.md.
var FS FSHook

// rcArgc / rcArgvBlob are filled by CPUInit (asm) from racccoon's exec
// ABI: argc, and the base of the NUL-separated argv string blob.
var (
	rcArgc     int
	rcArgvBlob *byte
)

// Args returns os.Args, parsed from the exec-ABI blob CPUInit stashed.
// The runtime reaches it via goosArgs() (lib/go/racccoon.patch).
// racccoon's c3 exec() ABI carries only the real arguments (no argv[0]),
// so a synthetic "go" is prepended — same convention the libc crt0
// uses — leaving the real args at os.Args[1:].
var Args = func() []string {
	out := []string{"go"}
	if rcArgc <= 0 || rcArgvBlob == nil {
		return out
	}
	p := unsafe.Pointer(rcArgvBlob)
	for i := 0; i < rcArgc; i++ {
		n := 0
		for *(*byte)(unsafe.Add(p, n)) != 0 {
			n++
		}
		out = append(out, unsafe.String((*byte)(p), n))
		p = unsafe.Add(p, n+1)
	}
	return out
}

// FSHook is the host filesystem backend contract. Handles are opaque
// tokens Open hands back and every later call passes in. Paths are
// already absolute (the syscall layer resolves cwd first via Getwd).
// Results carry an errno int, not an error — runtime/goos is imported
// by runtime and syscall and must not pull in the errors package;
// fs_racccoon.go (lib/go/racccoon.patch) maps these to syscall.Errno.
// 0 = ok, 2 = ENOENT, 5 = EIO, 9 = EBADF, 17 = EEXIST, 38 = ENOSYS.
type FSHook interface {
	Open(path string, flags int, perm uint32) (h uintptr, isDir bool, size int64, errno int)
	Close(h uintptr) int
	Pread(h uintptr, b []byte, off int64) (n int, errno int)
	Pwrite(h uintptr, b []byte, off int64) (n int, errno int)
	Fstat(h uintptr) (size int64, isDir bool, errno int)
	Dirents(h uintptr) (names []string, isDir []bool, errno int)
	Stat(path string) (size int64, isDir bool, errno int)
	Mkdir(path string, perm uint32) int
	Remove(path string, dir bool) int
	Rename(from, to string) int
	Truncate(path string, size int64) int
	Getwd() (string, int)
	Chdir(path string) int
}
