// Copyright 2026 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

//go:build tamago && riscv64

package goos

// The os/exec bridge: syscall.StartProcess / Wait4 (lib/go/racccoon.patch)
// route here. racccoon's model is rfork(RFPROC) + SYS_EXEC, where the
// caller reads the target binary and packs argv into one buffer — so the
// parent does all the work (allocation, fs I/O) BEFORE the fork, and the
// forked child does exactly one or two NOSPLIT ecalls (optional chdir,
// then exec) before its image is replaced. No allocation, no Go
// scheduler interaction in the child window.
//
// Limitations (Stage 4.1 first cut, docs/go-port-plan.md):
//   - the child inherits the parent's console I/O; ProcAttr.Files pipe
//     redirection (exec.Cmd.Output / a Stdout buffer) is not wired yet.
//   - argv is packed plain (no argv[0]); a spawned Go child sees its
//     real args at os.Args[1:] with a synthetic os.Args[0].

// defined in racccoon_riscv64.s
//
//go:noescape
func sysRfork(flags int64, genOut *uint32) int64

//go:noescape
func sysExecRaw(buf *byte, imgLen, argvLen, argc int64) int64

//go:noescape
func sysJoin(pid, gen int64) int64

//go:noescape
func sysExitCode(code int64)

const rfProc = 1 // RFPROC

// pid -> generation, filled by Spawn, read by Wait. Fixed table, no
// lock (GOMAXPROCS=1). 32 concurrent children is far more than the go
// command (which runs compile/link one at a time under -p 1) needs.
type childEntry struct {
	pid  int
	gen  uint32
	used bool
}

var children [32]childEntry

func recordChild(pid int, gen uint32) {
	for i := range children {
		if !children[i].used {
			children[i] = childEntry{pid: pid, gen: gen, used: true}
			return
		}
	}
}

func takeChildGen(pid int) (uint32, bool) {
	for i := range children {
		if children[i].used && children[i].pid == pid {
			g := children[i].gen
			children[i].used = false
			return g, true
		}
	}
	return 0, false
}

// Spawn starts path with argv (argv[0] is the program name, dropped —
// racccoon's plain exec ABI carries only real args). dir, if non-empty,
// is the child's working directory. Returns the child pid, or a
// negative errno.
func Spawn(path string, argv []string, dir string) int {
	ap := abspath(path)
	size, isDir, e := statPath(ap)
	if e != 0 {
		return -eNOENT
	}
	if isDir || size <= 0 {
		return -eIO
	}

	// argv blob: real args (argv[1:]) NUL-terminated, packed after the
	// image. argc is the count of those.
	real := argv
	if len(real) > 0 {
		real = real[1:]
	}
	argvLen := 0
	for _, a := range real {
		argvLen += len(a) + 1
	}

	buf := make([]byte, int(size)+argvLen)
	n, re := readAt(ap, buf[:size], 0)
	if re != 0 || int64(n) != size {
		return -eIO
	}
	off := int(size)
	for _, a := range real {
		copy(buf[off:], a)
		off += len(a)
		buf[off] = 0
		off++
	}

	// dir, NUL-terminated, prepared here so the child's chdir is a bare
	// ecall.
	var dirBuf [256]byte
	haveDir := dir != ""
	if haveDir {
		putPath(dirBuf[:], abspath(dir), len(dirBuf))
	}

	var gen uint32
	pid := sysRfork(rfProc, &gen)
	if pid < 0 {
		return -eIO
	}
	if pid == 0 {
		// child: at most chdir, then exec; nothing else.
		if haveDir {
			sysChdir(&dirBuf[0])
		}
		sysExecRaw(&buf[0], size, int64(argvLen), int64(len(real)))
		sysExitCode(127) // exec failed
	}
	recordChild(int(pid), gen)
	return int(pid)
}

// Wait blocks until the child pid (from Spawn) exits and returns its
// exit code (0..255), or a negative errno.
func Wait(pid int) int {
	gen, ok := takeChildGen(pid)
	if !ok {
		return -eIO
	}
	rc := sysJoin(int64(pid), int64(gen))
	if rc < 0 {
		return -eIO
	}
	return int(rc)
}
