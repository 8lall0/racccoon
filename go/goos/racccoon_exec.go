// Copyright 2026 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

//go:build racccoon && riscv64

package goos

// The os/exec bridge: syscall.StartProcess / Wait4 (lib/go/racccoon.patch)
// route here. racccoon's model is rfork(RFPROC) + SYS_EXEC, where the
// caller reads the target binary and packs argv into one buffer — so the
// parent does all the work (allocation, fs I/O) BEFORE the fork, and the
// forked child does exactly one or two NOSPLIT ecalls (optional chdir,
// then exec) before its image is replaced. No allocation, no Go
// scheduler interaction in the child window.
//
// Spawn runs the whole child to completion synchronously: rfork, wire an
// optional capture pipe, drain it, join. racccoon's userspace has no
// async job control at this layer and GOMAXPROCS is 1 (a blocking ecall
// freezes the whole Go world regardless), so "start then wait later" and
// "run now" are the same thing — Wait just returns the code Spawn
// already recorded. os/exec's Start/Wait split still works: Start blocks
// until the child exits, Wait is then a lookup.
//
// Output capture: racccoon gives a process ONE console stream, not a
// separate stdout/stderr, so a captured child's output is necessarily
// combined. exec.Cmd.Output / CombinedOutput / a bytes.Buffer Stdout all
// work; if Stdout and Stderr are different writers they both receive the
// combined stream.
//
// Limitations (docs/go-port-plan.md):
//   - no stdin-from-pipe (exec.Cmd.Stdin as a non-*os.File): the child
//     inherits the console's stdin. `go` never feeds its subtools stdin.
//   - a spawned Go child sees its real args at os.Args[1:] with a
//     synthetic os.Args[0] (argv packed plain, no argv[0]).

// defined in racccoon_riscv64.s
//
//go:noescape
func sysRfork(flags int64, genOut *uint32, stdoutPipe int64) int64

//go:noescape
func sysExecRaw(buf *byte, imgLen, argvLen, argc int64) int64

//go:noescape
func sysJoin(pid, gen int64) int64

//go:noescape
func sysExitCode(code int64)

//go:noescape
func sysPipeNew() int64

//go:noescape
func sysPipeRead(id int64, buf *byte, max int64) int64

//go:noescape
func sysPipeHold(id, asWriter, delta int64) int64

const rfProc = 1 // RFPROC

// pid -> recorded exit code, filled by Spawn (which joins synchronously),
// read once by Wait. Fixed table, no lock (GOMAXPROCS=1). 16 outstanding
// unwaited children is far more than the go command needs.
type childEntry struct {
	pid  int
	exit int
	used bool
}

var children [16]childEntry

func recordExit(pid, exit int) {
	for i := range children {
		if !children[i].used {
			children[i] = childEntry{pid: pid, exit: exit, used: true}
			return
		}
	}
}

func takeExit(pid int) (int, bool) {
	for i := range children {
		if children[i].used && children[i].pid == pid {
			e := children[i].exit
			children[i].used = false
			return e, true
		}
	}
	return 0, false
}

// --- capture slots ------------------------------------------------
// An os.Pipe() pair opened to capture a child's output reserves one of
// these; Spawn fills capData[id] with the combined stream; the read
// end's fileImpl (syscall/fs_racccoon.go goosPipeFile) serves from it.

const numCaptureSlots = 8

var (
	capData [numCaptureSlots][]byte
	capUsed [numCaptureSlots]bool
)

// CaptureAlloc reserves a capture slot for an os.Pipe pair. Returns the
// slot id, or -1 if none are free.
func CaptureAlloc() int {
	for i := range capUsed {
		if !capUsed[i] {
			capUsed[i] = true
			capData[i] = nil
			return i
		}
	}
	return -1
}

// CaptureData returns the bytes collected for slot id — complete once
// the Spawn that targeted it has returned.
func CaptureData(id int) []byte {
	if id < 0 || id >= numCaptureSlots {
		return nil
	}
	return capData[id]
}

// CaptureFree releases a capture slot (the read end's Close).
func CaptureFree(id int) {
	if id >= 0 && id < numCaptureSlots {
		capUsed[id] = false
		capData[id] = nil
	}
}

// Spawn starts path with argv (argv[0] is the program name, dropped —
// racccoon's plain exec ABI carries only real args). dir, if non-empty,
// is the child's working directory. capID >= 0 collects the child's
// console output into capture slot capID; -1 lets it inherit the
// console. Blocks until the child exits. Returns the child pid, or a
// negative errno.
func Spawn(path string, argv []string, dir string, capID int) int {
	ap := abspath(path)
	size, isDir, e := statPath(ap)
	if e != 0 {
		return -eNOENT
	}
	if isDir || size <= 0 {
		return -eIO
	}

	// argv blob: the racccoon exec ABI packs argv[0] (the program path)
	// as blob string 0, then the rest of argv, all NUL-terminated after
	// the image. `argc` counts every string, argv[0] included. os/exec
	// already puts the command path at argv[0]; fall back to the resolved
	// path when the caller passed no argv at all.
	blob := argv
	if len(blob) == 0 {
		blob = []string{ap}
	}
	argvLen := 0
	for _, a := range blob {
		argvLen += len(a) + 1
	}

	buf := make([]byte, int(size)+argvLen)
	n, re := readAt(ap, buf[:size], 0)
	if re != 0 || int64(n) != size {
		return -eIO
	}
	off := int(size)
	for _, a := range blob {
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

	// Capture pipe: allocated and reader-held BEFORE the fork so the
	// child's writes are never dropped as reader-less (src/pipe.c3
	// pipe_try_put), and passed to rfork so the kernel wires the child's
	// stdout to it atomically — a follow-up SYS_PIPE_SETOUT would race
	// the child, which the Go scheduler can let run ahead the moment the
	// parent hits a safepoint. Degrades to console-inherit if the 6
	// kernel pipes are all in use.
	kpipe := int64(-1)
	if capID >= 0 {
		if kp := sysPipeNew(); kp >= 0 {
			kpipe = kp
			sysPipeHold(kpipe, 0, 1) // parent holds the read end
		}
	}

	var gen uint32
	pid := sysRfork(rfProc, &gen, kpipe)
	if pid < 0 {
		if kpipe >= 0 {
			sysPipeHold(kpipe, 0, -1)
		}
		return -eIO
	}
	if pid == 0 {
		// child: at most chdir, then exec; nothing else. stdout is
		// already wired (by rfork) if this is a captured spawn.
		if haveDir {
			sysChdir(&dirBuf[0])
		}
		sysExecRaw(&buf[0], size, int64(argvLen), int64(len(blob)))
		sysExitCode(127) // exec failed
	}

	// parent: drain the capture pipe to EOF. SYS_PIPE_READ blocks
	// in-kernel (yielding to the child) until data or EOF; it returns 0
	// only at true EOF, which is the child's exit detaching the last
	// writer.
	var captured []byte
	if kpipe >= 0 {
		var chunk [512]byte
		for {
			got := sysPipeRead(kpipe, &chunk[0], int64(len(chunk)))
			if got <= 0 {
				break
			}
			captured = append(captured, chunk[:got]...)
		}
		sysPipeHold(kpipe, 0, -1)
	}

	rc := sysJoin(int64(pid), int64(gen))
	if rc < 0 {
		rc = 127
	}
	if capID >= 0 {
		capData[capID] = captured
	}
	recordExit(int(pid), int(rc))
	return int(pid)
}

// Wait returns the exit code (0..255) Spawn already recorded for pid, or
// a negative errno if pid isn't a child this process spawned.
func Wait(pid int) int {
	if e, ok := takeExit(pid); ok {
		return e
	}
	return -eIO
}
