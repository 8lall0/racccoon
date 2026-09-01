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
	// RamSize must fit under the kernel's per-process SYS_MAP ceiling
	// (board::HEAP_MAX_BYTES: 64 MiB on QEMU/JH7110) minus this binary's
	// own image, and SYS_MAP is eager — every page is really allocated.
	// 48 MiB is comfortable for Go hello-world on QEMU; the JH7110 with
	// GiBs can take far more. On a board too small to honour it (the
	// Duo) SYS_MAP fails and the first stack store faults — a retry-with-
	// smaller loop in CPUInit is a follow-up.
	RamSize        uint = 48 << 20
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
