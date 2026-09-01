// Copyright 2026 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

//go:build tamago && riscv64

package goos

// The fsd bridge: package os's filesystem operations, over
// SYS_NS_RESOLVE + SYS_IPC_CALL and the FS_* verbs, mirroring
// lib/racccoon-libc/src/rc_fs.c. Installed into FS by init() below, so
// every racccoon Go binary gets real filesystem access with no import
// of its own — including the toolchain binaries (Stage 4).
//
// runtime/goos is imported by runtime and syscall, so this file must
// stay minimal: no sync (import cycle), no errors — errno ints only,
// which the syscall side (lib/go/racccoon.patch's fs_racccoon.go) maps
// to syscall.Errno. Single-threaded (GOMAXPROCS=1), so the handle table
// needs no lock: nothing between a Lock-shaped pair yields.

const (
	fsMsgMax  = 1128
	fsReadAt  = 26
	fsWriteAt = 27
	fsDelete  = 22
	fsList    = 23
	fsMkdir   = 24
	fsRename  = 25
	fsStat    = 28

	readChunk     = fsMsgMax - 4   // 1124
	writeChunk    = fsMsgMax - 108 // 1020
	listEntrySize = 36
	listNameMax   = 32
	listPageMax   = (fsMsgMax - 4) / listEntrySize

	// errno values (subset of syscall's); fs_racccoon.go maps these.
	eOK     = 0
	eNOENT  = 2
	eIO     = 5
	eBADF   = 9
	eEXIST  = 17
	eNOSYS  = 38
)

// defined in racccoon_riscv64.s
//
//go:noescape
func nsResolve(path *byte, prefixOut *uint32) int64

//go:noescape
func ipcCall(pid, verb int64, buf *byte, packed int64, verbOut *uint32) int64

//go:noescape
func sysGetcwd(buf *byte, cap int64) int64

//go:noescape
func sysChdir(path *byte) int64

func le32(b []byte, v uint32) {
	b[0], b[1], b[2], b[3] = byte(v), byte(v>>8), byte(v>>16), byte(v>>24)
}

func rd32(b []byte) uint32 {
	return uint32(b[0]) | uint32(b[1])<<8 | uint32(b[2])<<16 | uint32(b[3])<<24
}

func putPath(b []byte, s string, n int) {
	i := 0
	for ; i < len(s) && i < n-1; i++ {
		b[i] = s[i]
	}
	b[i] = 0
}

func getcwd() (string, int) {
	var cw [256]byte
	n := sysGetcwd(&cw[0], int64(len(cw)))
	if n <= 0 {
		return "", eIO
	}
	return string(cw[:n]), eOK
}

func abspath(p string) string {
	if len(p) > 0 && p[0] == '/' {
		return p
	}
	cw, e := getcwd()
	if e != eOK {
		return p
	}
	if p == "" {
		return cw
	}
	return cw + "/" + p
}

// resolve maps an absolute path to (fsd pid, path with the mount prefix
// stripped).
func resolve(ap string) (int64, string, bool) {
	var pb [256]byte
	putPath(pb[:], ap, len(pb))
	var prefix uint32
	pid := nsResolve(&pb[0], &prefix)
	if pid < 0 {
		return 0, "", false
	}
	if int(prefix) > len(ap) {
		prefix = uint32(len(ap))
	}
	return pid, ap[prefix:], true
}

func fsdCall(pid, verb int64, buf []byte) (int32, bool) {
	packed := (int64(fsMsgMax) << 16) | int64(fsMsgMax&0xFFFF)
	var rv uint32
	from := ipcCall(pid, verb, &buf[0], packed, &rv)
	if from <= 0 || int64(rv) != verb {
		return -1, false
	}
	return int32(rd32(buf)), true
}

func statPath(ap string) (size int64, isDir bool, errno int) {
	pid, stripped, ok := resolve(ap)
	if !ok {
		return 0, false, eNOENT
	}
	var buf [fsMsgMax]byte
	putPath(buf[:100], stripped, 100)
	res, ok := fsdCall(pid, fsStat, buf[:])
	if !ok || res < 0 {
		return 0, false, eNOENT
	}
	return int64(rd32(buf[4:8])), buf[8] == 1, eOK
}

func readAt(ap string, b []byte, off int64) (int, int) {
	pid, stripped, ok := resolve(ap)
	if !ok {
		return 0, eNOENT
	}
	var msg [fsMsgMax]byte
	total := 0
	for total < len(b) {
		want := len(b) - total
		if want > readChunk {
			want = readChunk
		}
		putPath(msg[:100], stripped, 100)
		le32(msg[100:104], uint32(want))
		le32(msg[104:108], uint32(off+int64(total)))
		res, ok := fsdCall(pid, fsReadAt, msg[:])
		if !ok || res < 0 {
			if total == 0 {
				return 0, eIO
			}
			break
		}
		if res == 0 {
			break
		}
		if int(res) > want {
			res = int32(want)
		}
		copy(b[total:], msg[4:4+res])
		total += int(res)
		if int(res) < want {
			break
		}
	}
	return total, eOK
}

func writeAt(ap string, b []byte, off int64) (int, int) {
	pid, stripped, ok := resolve(ap)
	if !ok {
		return 0, eNOENT
	}
	var msg [fsMsgMax]byte
	done := 0
	for done < len(b) || (done == 0 && len(b) == 0) {
		n := len(b) - done
		if n > writeChunk {
			n = writeChunk
		}
		putPath(msg[:100], stripped, 100)
		le32(msg[100:104], uint32(n))
		le32(msg[104:108], uint32(off+int64(done)))
		copy(msg[108:108+n], b[done:done+n])
		res, ok := fsdCall(pid, fsWriteAt, msg[:])
		if !ok || res < 0 {
			if done == 0 {
				return 0, eIO
			}
			break
		}
		done += n
		if len(b) == 0 {
			break
		}
	}
	return done, eOK
}

func simpleVerb(ap string, verb int64, aux uint32) int {
	pid, stripped, ok := resolve(ap)
	if !ok {
		return eNOENT
	}
	var buf [fsMsgMax]byte
	putPath(buf[:100], stripped, 100)
	le32(buf[100:104], aux)
	res, ok := fsdCall(pid, verb, buf[:])
	if !ok || res < 0 {
		return eIO
	}
	return eOK
}

func listDir(ap string) (names []string, isDir []bool, errno int) {
	pid, stripped, ok := resolve(ap)
	if !ok {
		return nil, nil, eNOENT
	}
	var buf [fsMsgMax]byte
	start := 0
	for {
		putPath(buf[:100], stripped, 100)
		le32(buf[104:108], uint32(start))
		res, ok := fsdCall(pid, fsList, buf[:])
		if !ok || res < 0 {
			if len(names) > 0 {
				break
			}
			return nil, nil, eIO
		}
		page := int(res)
		for i := 0; i < page; i++ {
			rec := buf[4+i*listEntrySize:]
			nlen := 0
			for nlen < listNameMax && rec[nlen] != 0 {
				nlen++
			}
			names = append(names, string(rec[:nlen]))
			isDir = append(isDir, rec[listNameMax] == 1)
		}
		start += page
		if page < listPageMax {
			break
		}
	}
	return names, isDir, eOK
}

// --- the FSHook implementation -------------------------------------

// A handle is a resolved absolute path — fsd has no server-side fds.
// Fixed table indexed by (handle-1); no lock (GOMAXPROCS=1, nothing
// yields between a claim and its use). 64 is well past what any single
// Go program opens concurrently.
type handleEntry struct {
	path string
	used bool
}

const maxHandles = 64

var handles [maxHandles]handleEntry

func allocHandle(path string) uintptr {
	for i := range handles {
		if !handles[i].used {
			handles[i] = handleEntry{path: path, used: true}
			return uintptr(i + 1)
		}
	}
	return 0
}

func handlePath(h uintptr) (string, bool) {
	i := int(h) - 1
	if i < 0 || i >= maxHandles || !handles[i].used {
		return "", false
	}
	return handles[i].path, true
}

func freeHandle(h uintptr) {
	i := int(h) - 1
	if i >= 0 && i < maxHandles {
		handles[i].used = false
	}
}

type fsdBackend struct{}

// hNull is the reserved handle for /dev/null — reads EOF, writes are
// discarded. os/exec opens it for a Cmd whose Stdin/Stdout/Stderr is
// nil, and the go command uses it liberally.
const hNull = ^uintptr(0)

func (fsdBackend) Open(path string, flags int, perm uint32) (uintptr, bool, int64, int) {
	const oCREATE, oEXCL, oTRUNC = 0100, 0200, 01000
	ap := abspath(path)
	if ap == "/dev/null" {
		return hNull, false, 0, eOK
	}
	size, isDir, e := statPath(ap)
	exists := e == eOK
	if !exists {
		if flags&oCREATE == 0 {
			return 0, false, 0, eNOENT
		}
		if _, we := writeAt(ap, nil, 0); we != eOK {
			return 0, false, 0, we
		}
		size, isDir = 0, false
	} else if flags&oEXCL != 0 && flags&oCREATE != 0 {
		return 0, false, 0, eEXIST
	} else if flags&oTRUNC != 0 && !isDir {
		simpleVerb(ap, fsDelete, 0)
		writeAt(ap, nil, 0)
		size = 0
	}
	h := allocHandle(ap)
	if h == 0 {
		return 0, false, 0, eIO
	}
	return h, isDir, size, eOK
}

func (fsdBackend) Close(h uintptr) int {
	if h != hNull {
		freeHandle(h)
	}
	return eOK
}

func (fsdBackend) Pread(h uintptr, b []byte, off int64) (int, int) {
	if h == hNull {
		return 0, eOK // EOF
	}
	p, ok := handlePath(h)
	if !ok {
		return 0, eBADF
	}
	return readAt(p, b, off)
}

func (fsdBackend) Pwrite(h uintptr, b []byte, off int64) (int, int) {
	if h == hNull {
		return len(b), eOK // discard
	}
	p, ok := handlePath(h)
	if !ok {
		return 0, eBADF
	}
	return writeAt(p, b, off)
}

func (fsdBackend) Fstat(h uintptr) (int64, bool, int) {
	if h == hNull {
		return 0, false, eOK
	}
	p, ok := handlePath(h)
	if !ok {
		return 0, false, eBADF
	}
	return statPath(p)
}

func (fsdBackend) Dirents(h uintptr) ([]string, []bool, int) {
	p, ok := handlePath(h)
	if !ok {
		return nil, nil, eBADF
	}
	return listDir(p)
}

func (fsdBackend) Stat(path string) (int64, bool, int) { return statPath(abspath(path)) }

func (fsdBackend) Mkdir(path string, perm uint32) int { return simpleVerb(abspath(path), fsMkdir, 0) }

func (fsdBackend) Remove(path string, dir bool) int { return simpleVerb(abspath(path), fsDelete, 0) }

func (fsdBackend) Rename(from, to string) int {
	apo, apn := abspath(from), abspath(to)
	pido, so, ok1 := resolve(apo)
	pidn, sn, ok2 := resolve(apn)
	if !ok1 || !ok2 || pido != pidn {
		return eIO
	}
	var buf [fsMsgMax]byte
	putPath(buf[:100], so, 100)
	putPath(buf[100:200], sn, 100)
	res, ok := fsdCall(pido, fsRename, buf[:])
	if !ok || res < 0 {
		return eIO
	}
	return eOK
}

func (fsdBackend) Truncate(path string, size int64) int {
	if size != 0 {
		return eNOSYS
	}
	ap := abspath(path)
	simpleVerb(ap, fsDelete, 0)
	_, e := writeAt(ap, nil, 0)
	return e
}

func (fsdBackend) Getwd() (string, int) { return getcwd() }

func (fsdBackend) Chdir(path string) int {
	ap := abspath(path)
	var pb [256]byte
	putPath(pb[:], ap, len(pb))
	if sysChdir(&pb[0]) != 0 {
		return eIO
	}
	return eOK
}

func init() { FS = fsdBackend{} }
