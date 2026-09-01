// Copyright 2026 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

//go:build tamago && riscv64

// Raw racccoon ecalls for the fsd bridge (package racccoon). ABI:
// syscall number in A3, args A0/A1/A2 and A4/A5 for a 5-arg call,
// result A0. Numbers from user/user.c3.

#include "textflag.h"

#define SYS_NS_RESOLVE  8
#define SYS_IPC_CALL    34
#define SYS_CHDIR       37
#define SYS_GETCWD      38

// func nsResolve(path *byte, prefixOut *uint32) int64
TEXT ·nsResolve(SB),NOSPLIT,$0-24
	MOV	path+0(FP), A0
	MOV	prefixOut+8(FP), A1
	MOV	$0, A2
	MOV	$SYS_NS_RESOLVE, A3
	ECALL
	MOV	A0, ret+16(FP)
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
