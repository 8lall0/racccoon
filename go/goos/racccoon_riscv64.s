// Copyright 2026 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

//go:build tamago && riscv64

// Adapted from tamago-go src/runtime/goos/linux_user_riscv64.s.
// racccoon ecall ABI: syscall number in A3 (not A7 like Linux); args in
// A0/A1/A2 (A4 for a 4th); result in A0. Numbers from user/user.c3.

#include "textflag.h"

#define SYS_PUTCHAR   1
#define SYS_EXIT      3
#define SYS_YIELD     27
#define SYS_MAP       47
#define SYS_TIMEBASE  49

// CPUInit is the provider entry point _rt0_riscv64_tamago jumps to. It
// carves the runtime's RAM out of a fresh SYS_MAP region, sets the
// stack pointer to the top of it, publishes the base to ·RamStart and
// ·Bloc, then hands control to the tamago rt0.
//
// Runs before the Go world starts: no allocation, no g.
TEXT ·CPUInit(SB),NOSPLIT|NOFRAME,$0
	// SYS_MAP(RamSize) -> base vaddr (or -1)
	MOV	·RamSize(SB), A0
	MOV	$SYS_MAP, A3
	ECALL

	// A0 = region base
	MOV	A0, ·RamStart(SB)
	MOV	A0, ·Bloc(SB)

	// stack pointer = base + RamSize - RamStackOffset (stack at the top;
	// rt0 sets g0.stack.lo to SP-64KiB, the rest of the region is heap)
	MOV	·RamSize(SB), T1
	MOV	·RamStackOffset(SB), T2
	ADD	A0, T1
	SUB	T2, T1
	MOV	T1, X2

	JMP	runtime·rt0_riscv64_tamago(SB)

// func sys_putchar(c *byte)
TEXT ·sys_putchar(SB),NOSPLIT,$0-8
	MOV	c+0(FP), T0
	MOVBU	(T0), A0
	MOV	$SYS_PUTCHAR, A3
	ECALL
	RET

// func sys_exit(code int32)
TEXT ·sys_exit(SB),$0-4
	MOVW	code+0(FP), A0
	MOV	$SYS_EXIT, A3
	ECALL
	RET

// func sys_yield()
TEXT ·sys_yield(SB),NOSPLIT,$0
	MOV	$SYS_YIELD, A3
	ECALL
	RET

// func sys_timebase() int64 — the `time` CSR tick rate in Hz
TEXT ·sys_timebase(SB),NOSPLIT,$0-8
	MOV	$SYS_TIMEBASE, A3
	ECALL
	MOV	A0, ret+0(FP)
	RET

// func rdtime() int64 — the `time` CSR. racccoon's kernel sets
// scounteren.TM so S/U-mode reads don't trap (user/user.c3 does the
// same csrr from c3).
TEXT ·rdtime(SB),NOSPLIT,$0-8
	RDTIME	A0
	MOV	A0, ret+0(FP)
	RET
