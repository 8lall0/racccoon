// Copyright 2026 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

//go:build tamago && riscv64

// Package racccoon bridges Go file I/O to the racccoon fsd server over
// SYS_NS_RESOLVE + SYS_IPC_CALL, mirroring lib/racccoon-libc/src/rc_fs.c
// byte for byte (see user/fs/fsd.c3 for the wire format).
//
// GOOS=tamago's own os/syscall packages back onto an in-memory
// filesystem; this package is real, persistent I/O against whatever
// racccoon has mounted (ext2 root, FAT32 boot partition, /mnt/*).
// A GOOS=racccoon rename that wires this into os.Open transparently is
// a later step — see docs/go-port-plan.md.
package racccoon

import (
	"errors"
	"runtime"
)

const (
	fsMsgMax  = 1128
	fsReadAt  = 26
	fsWriteAt = 27
	fsDelete  = 22
	fsList    = 23
	fsMkdir   = 24
	fsRename  = 25
	fsStat    = 28

	readChunk       = fsMsgMax - 4   // 1124 — reply data starts at byte 4
	writeChunk      = fsMsgMax - 108 // 1020 — FS_WRITE_AT data starts at byte 108
	listEntrySize   = 36
	listNameMax     = 32
	listPageEntries = (fsMsgMax - 4) / listEntrySize

	offsetAppend = 0xFFFFFFFF
)

// ErrIO is returned for any fsd-side failure — not found, permission,
// not a directory, a dead server. racccoon's wire protocol only carries
// a -1, so this package cannot distinguish them.
var ErrIO = errors.New("racccoon: fs error (not found / permission / not a dir)")

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

// putPath writes s into b[:n] as a NUL-terminated string (truncating).
func putPath(b []byte, s string, n int) {
	i := 0
	for ; i < len(s) && i < n-1; i++ {
		b[i] = s[i]
	}
	b[i] = 0
}

// Getwd returns the caller's current working directory.
func Getwd() (string, error) {
	var cw [256]byte
	n := sysGetcwd(&cw[0], int64(len(cw)))
	if n <= 0 {
		return "", ErrIO
	}
	return string(cw[:n]), nil
}

// Chdir sets the caller's cwd. The path must already be absolute and
// normalised — this is the raw syscall, same as the shell's `cd` after
// its own normalisation.
func Chdir(path string) error {
	var pb [256]byte
	putPath(pb[:], path, len(pb))
	if sysChdir(&pb[0]) != 0 {
		return ErrIO
	}
	return nil
}

func abspath(p string) string {
	if len(p) > 0 && p[0] == '/' {
		return p
	}
	cw, err := Getwd()
	if err != nil {
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

// fsdCall sends one request in buf and reads the reply back into it.
// Returns the int32 result at buf[0:4] and whether the round-trip and
// reply-verb matched.
func fsdCall(pid, verb int64, buf []byte) (int32, bool) {
	packed := (int64(fsMsgMax) << 16) | int64(fsMsgMax&0xFFFF)
	var rv uint32
	from := ipcCall(pid, verb, &buf[0], packed, &rv)
	runtime.KeepAlive(buf)
	if from <= 0 || int64(rv) != verb {
		return -1, false
	}
	return int32(rd32(buf)), true
}

// ReadFile reads the entire named file.
func ReadFile(name string) ([]byte, error) {
	pid, stripped, ok := resolve(abspath(name))
	if !ok {
		return nil, ErrIO
	}
	var buf [fsMsgMax]byte
	var out []byte
	var off uint32
	for {
		putPath(buf[:100], stripped, 100)
		le32(buf[100:104], uint32(readChunk))
		le32(buf[104:108], off)
		res, ok := fsdCall(pid, fsReadAt, buf[:])
		if !ok || res < 0 {
			if off == 0 {
				return nil, ErrIO
			}
			break
		}
		if res == 0 {
			break
		}
		if int(res) > readChunk {
			res = int32(readChunk)
		}
		out = append(out, buf[4:4+res]...)
		off += uint32(res)
		if int(res) < readChunk {
			break
		}
	}
	return out, nil
}

// WriteFile writes data to the named file, creating it if needed and
// truncating any previous longer content (an explicit zero-length write
// at offset 0 first, matching how the C layer's O_TRUNC is emulated is
// not done here — fsd's FS_WRITE_AT overwrites in place; callers that
// need a clean truncate should Remove first).
func WriteFile(name string, data []byte) error {
	pid, stripped, ok := resolve(abspath(name))
	if !ok {
		return ErrIO
	}
	var buf [fsMsgMax]byte
	off := 0
	for off < len(data) || (off == 0 && len(data) == 0) {
		n := len(data) - off
		if n > writeChunk {
			n = writeChunk
		}
		putPath(buf[:100], stripped, 100)
		le32(buf[100:104], uint32(n))
		le32(buf[104:108], uint32(off))
		copy(buf[108:108+n], data[off:off+n])
		res, ok := fsdCall(pid, fsWriteAt, buf[:])
		if !ok || res < 0 {
			return ErrIO
		}
		off += n
		if len(data) == 0 {
			break
		}
	}
	return nil
}

// FileInfo is the subset of stat racccoon's FS_STAT carries.
type FileInfo struct {
	Size  int64
	IsDir bool
}

// Stat returns metadata for the named file or directory.
func Stat(name string) (FileInfo, error) {
	pid, stripped, ok := resolve(abspath(name))
	if !ok {
		return FileInfo{}, ErrIO
	}
	var buf [fsMsgMax]byte
	putPath(buf[:100], stripped, 100)
	res, ok := fsdCall(pid, fsStat, buf[:])
	if !ok || res < 0 {
		return FileInfo{}, ErrIO
	}
	return FileInfo{Size: int64(rd32(buf[4:8])), IsDir: buf[8] == 1}, nil
}

// DirEntry is one entry from ReadDir.
type DirEntry struct {
	Name  string
	IsDir bool
}

// ReadDir lists the named directory, following FS_LIST's pagination.
func ReadDir(name string) ([]DirEntry, error) {
	pid, stripped, ok := resolve(abspath(name))
	if !ok {
		return nil, ErrIO
	}
	var buf [fsMsgMax]byte
	var entries []DirEntry
	start := 0
	for {
		putPath(buf[:100], stripped, 100)
		le32(buf[104:108], uint32(start))
		res, ok := fsdCall(pid, fsList, buf[:])
		if !ok {
			if len(entries) > 0 {
				break
			}
			return nil, ErrIO
		}
		if res < 0 {
			if len(entries) > 0 {
				break
			}
			return nil, ErrIO
		}
		page := int(res)
		for i := 0; i < page; i++ {
			rec := buf[4+i*listEntrySize:]
			nlen := 0
			for nlen < listNameMax && rec[nlen] != 0 {
				nlen++
			}
			entries = append(entries, DirEntry{
				Name:  string(rec[:nlen]),
				IsDir: rec[listNameMax] == 1,
			})
		}
		start += page
		if page < listPageEntries {
			break
		}
	}
	return entries, nil
}

// Mkdir creates the named directory.
func Mkdir(name string) error { return simpleVerb(name, fsMkdir, 0) }

// Remove deletes the named file or empty directory.
func Remove(name string) error { return simpleVerb(name, fsDelete, 0) }

// RemoveAll deletes the named file or directory tree.
func RemoveAll(name string) error { return simpleVerb(name, fsDelete, 1) }

func simpleVerb(name string, verb int64, aux uint32) error {
	pid, stripped, ok := resolve(abspath(name))
	if !ok {
		return ErrIO
	}
	var buf [fsMsgMax]byte
	putPath(buf[:100], stripped, 100)
	le32(buf[100:104], aux)
	res, ok := fsdCall(pid, verb, buf[:])
	if !ok || res < 0 {
		return ErrIO
	}
	return nil
}

// Rename moves oldPath to newPath. Both must resolve to the same fsd.
func Rename(oldPath, newPath string) error {
	apo, apn := abspath(oldPath), abspath(newPath)
	pido, so, ok1 := resolve(apo)
	pidn, sn, ok2 := resolve(apn)
	if !ok1 || !ok2 || pido != pidn {
		return ErrIO
	}
	var buf [fsMsgMax]byte
	putPath(buf[:100], so, 100)
	putPath(buf[100:200], sn, 100)
	res, ok := fsdCall(pido, fsRename, buf[:])
	if !ok || res < 0 {
		return ErrIO
	}
	return nil
}
