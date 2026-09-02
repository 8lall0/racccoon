// Copyright 2026 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

//go:build racccoon && riscv64

// Adapted from tamago-go src/runtime/goos/linux_user_riscv64.s.
// racccoon ecall ABI: syscall number in A3 (not A7 like Linux); args in
// A0/A1/A2 (A4 for a 4th); result in A0. Numbers from user/user.c3.

#include "textflag.h"

#define SYS_PUTCHAR      1
#define SYS_EXIT         3
#define SYS_NS_RESOLVE   8
#define SYS_NS_TRANSLATE 52
#define SYS_RFORK        11
#define SYS_JOIN         13
#define SYS_EXEC         24
#define SYS_YIELD        27
#define SYS_IPC_CALL     34
#define SYS_CHDIR        37
#define SYS_GETCWD       38
#define SYS_PIPE         39
#define SYS_PIPE_SETOUT  40
#define SYS_PIPE_READ    42
#define SYS_PIPE_HOLD    44
#define SYS_MAP          47
#define SYS_TIMEBASE     49

// CPUInit is the provider entry point _rt0_riscv64_racccoon jumps to. It
// carves the runtime's RAM out of a fresh SYS_MAP region, sets the
// stack pointer to the top of it, publishes the base to ·RamStart and
// ·Bloc, then hands control to the racccoon rt0.
//
// Runs before the Go world starts: no allocation, no g.
TEXT ·CPUInit(SB),NOSPLIT|NOFRAME,$0
	// racccoon's exec ABI hands the ELF entry argc in A0 and the
	// argv blob base (NUL-separated strings) in A1 — stash both before
	// they are clobbered; ·Args parses them for os.Args.
	MOV	A0, ·rcArgc(SB)
	MOV	A1, ·rcArgvBlob(SB)

	// SYS_MAP(RamSize) -> base vaddr, or -1 if the board's per-process
	// HEAP_MAX_BYTES can't honour it. On failure fall back to 8 MiB so
	// the runtime still starts (and OOMs cleanly) rather than running
	// with a wrapped-around stack pointer.
	MOV	·RamSize(SB), A0
	MOV	$SYS_MAP, A3
	ECALL
	MOV	$-1, T0
	BNE	A0, T0, mapped
	MOV	$(8*1024*1024), A0
	MOV	A0, ·RamSize(SB)
	MOV	$SYS_MAP, A3
	ECALL

mapped:
	MOV	A0, ·RamStart(SB)
	MOV	A0, ·Bloc(SB)

	// stack pointer = base + RamSize - RamStackOffset (stack at the top;
	// rt0 sets g0.stack.lo to SP-64KiB, the rest of the region is heap)
	MOV	A0, X2
	MOV	·RamSize(SB), T1
	ADD	T1, X2
	MOV	·RamStackOffset(SB), T2
	SUB	T2, X2

	JMP	runtime·rt0_riscv64_racccoon(SB)

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

// --- fsd bridge ecalls (racccoon_fs.go) --------------------------

// func nsResolve(path *byte, prefixOut *uint32) int64
TEXT ·nsResolve(SB),NOSPLIT,$0-24
	MOV	path+0(FP), A0
	MOV	prefixOut+8(FP), A1
	MOV	$0, A2
	MOV	$SYS_NS_RESOLVE, A3
	ECALL
	MOV	A0, ret+16(FP)
	RET

// func nsTranslate(path *byte, member int64, out *byte, outMax int64) int64
TEXT ·nsTranslate(SB),NOSPLIT,$0-40
	MOV	path+0(FP), A0
	MOV	member+8(FP), A1
	MOV	out+16(FP), A2
	MOV	outMax+24(FP), A4
	MOV	$SYS_NS_TRANSLATE, A3
	ECALL
	MOV	A0, ret+32(FP)
	RET

// func ipcCall(pid, verb int64, buf *byte, packed int64, verbOut *uint32) int64
TEXT ·ipcCall(SB),NOSPLIT,$0-48
	MOV	pid+0(FP), A0
	MOV	verb+8(FP), A1
	MOV	buf+16(FP), A2
	MOV	packed+24(FP), A4
	MOV	verbOut+32(FP), A5
	MOV	$SYS_IPC_CALL, A3
	ECALL
	MOV	A0, ret+40(FP)
	RET

// func sysGetcwd(buf *byte, cap int64) int64
TEXT ·sysGetcwd(SB),NOSPLIT,$0-24
	MOV	buf+0(FP), A0
	MOV	cap+8(FP), A1
	MOV	$SYS_GETCWD, A3
	ECALL
	MOV	A0, ret+16(FP)
	RET

// func sysChdir(path *byte) int64
TEXT ·sysChdir(SB),NOSPLIT,$0-16
	MOV	path+0(FP), A0
	MOV	$SYS_CHDIR, A3
	ECALL
	MOV	A0, ret+8(FP)
	RET

// --- os/exec bridge ecalls (racccoon_exec.go) --------------------
// racccoon's fork+exec model: rfork(RFPROC) then the child SYS_EXECs a
// blob (image bytes + packed argv) prepared by the parent — so the
// child does exactly one ecall between fork and exec, no allocation.

// func sysRfork(flags int64, genOut *uint32, stdoutPipe int64) int64
// stdoutPipe >= 0 wires the child's stdout to that pipe id as part of
// the fork (SYS_RFORK a2) — race-free vs. a follow-up SYS_PIPE_SETOUT,
// which the Go scheduler can let the child outrun. -1 = plain console.
TEXT ·sysRfork(SB),NOSPLIT,$0-32
	MOV	flags+0(FP), A0
	MOV	genOut+8(FP), A1
	MOV	stdoutPipe+16(FP), A2
	MOV	$SYS_RFORK, A3
	ECALL
	MOV	A0, ret+24(FP)
	RET

// func sysExecRaw(buf *byte, imgLen, argvLen, argc int64) int64
// (only returns on failure — on success the image is replaced)
TEXT ·sysExecRaw(SB),NOSPLIT,$0-40
	MOV	buf+0(FP), A0
	MOV	imgLen+8(FP), A1
	MOV	argvLen+16(FP), A2
	MOV	argc+24(FP), A4
	MOV	$SYS_EXEC, A3
	ECALL
	MOV	A0, ret+32(FP)
	RET

// func sysJoin(pid, gen int64) int64
TEXT ·sysJoin(SB),NOSPLIT,$0-24
	MOV	pid+0(FP), A0
	MOV	gen+8(FP), A1
	MOV	$SYS_JOIN, A3
	ECALL
	MOV	A0, ret+16(FP)
	RET

// func sysExitCode(code int64)  — child bail-out after a failed exec
TEXT ·sysExitCode(SB),NOSPLIT,$0-8
	MOV	code+0(FP), A0
	MOV	$SYS_EXIT, A3
	ECALL
	RET

// --- output-capture ecalls (racccoon_exec.go) -------------------
// A captured child's console output goes through a kernel pipe: the
// parent allocates it, holds the read end, points the child's stdout
// there right after rfork, then drains it to EOF (child exit). racccoon
// has one console stream per process (no separate stderr) — capture is
// therefore combined stdout+stderr. Numbers from src/pipe.c3 / user.c3.

// func sysPipeNew() int64  — SYS_PIPE, returns a pipe id or -1
TEXT ·sysPipeNew(SB),NOSPLIT,$0-8
	MOV	$0, A0
	MOV	$0, A1
	MOV	$0, A2
	MOV	$SYS_PIPE, A3
	ECALL
	MOV	A0, ret+0(FP)
	RET

// func sysPipeRead(id int64, buf *byte, max int64) int64  — drain, 0 = EOF
TEXT ·sysPipeRead(SB),NOSPLIT,$0-32
	MOV	id+0(FP), A0
	MOV	buf+8(FP), A1
	MOV	max+16(FP), A2
	MOV	$SYS_PIPE_READ, A3
	ECALL
	MOV	A0, ret+24(FP)
	RET

// func sysPipeHold(id, asWriter, delta int64) int64  — claim/release an end
TEXT ·sysPipeHold(SB),NOSPLIT,$0-32
	MOV	id+0(FP), A0
	MOV	asWriter+8(FP), A1
	MOV	delta+16(FP), A2
	MOV	$SYS_PIPE_HOLD, A3
	ECALL
	MOV	A0, ret+24(FP)
	RET
