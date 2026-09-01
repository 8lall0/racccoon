// Copyright 2026 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

//go:build tamago && riscv64

// Importing this package (even for its side effect: `import _
// "racccoon.local/goport/racccoon"`) installs the fsd backend into
// runtime/goos.FS, so package os operates on racccoon's real
// filesystem instead of GOOS=tamago's in-memory one. The syscall-side
// hooks live in a small patch to the toolchain (lib/go/racccoon.patch).
// See docs/go-port-plan.md.

package racccoon

import (
	"runtime/goos"
	"sync"
	"syscall"
)

func init() { goos.FS = fsdBackend{} }

// A handle is just a resolved absolute path plus its kind — fsd has no
// server-side file descriptors, every op is path-based.
type handle struct {
	path  string
	isDir bool
}

var (
	handMu   sync.Mutex
	handTab  = map[uintptr]*handle{}
	handNext uintptr = 1
)

type fsdBackend struct{}

func toErrno(err error) error {
	switch err {
	case nil:
		return nil
	case ErrNotExist:
		return syscall.ENOENT
	default:
		return syscall.EIO
	}
}

func (fsdBackend) Open(path string, flags int, perm uint32) (uintptr, bool, int64, error) {
	ap := abspath(path)
	fi, err := Stat(ap)
	exists := err == nil

	if !exists {
		if flags&syscall.O_CREATE == 0 {
			return 0, false, 0, toErrno(ErrNotExist)
		}
		if e := writeAtPathErr(ap, nil); e != nil {
			return 0, false, 0, toErrno(e)
		}
		fi = FileInfo{}
	} else if flags&syscall.O_EXCL != 0 && flags&syscall.O_CREATE != 0 {
		return 0, false, 0, syscall.EEXIST
	} else if flags&syscall.O_TRUNC != 0 && !fi.IsDir {
		// fsd's FS_WRITE_AT overwrites in place and never shrinks, so a
		// shorter new body would leave a stale tail — remove + recreate,
		// matching how the C POSIX layer emulates O_TRUNC.
		_ = Remove(ap)
		_ = writeAtPathErr(ap, nil)
		fi = FileInfo{}
	}

	handMu.Lock()
	h := handNext
	handNext++
	handTab[h] = &handle{path: ap, isDir: fi.IsDir}
	handMu.Unlock()
	return h, fi.IsDir, fi.Size, nil
}

func writeAtPathErr(ap string, b []byte) error {
	_, err := writeAtPath(ap, b, 0)
	return err
}

func (fsdBackend) hpath(h uintptr) (string, bool) {
	handMu.Lock()
	e := handTab[h]
	handMu.Unlock()
	if e == nil {
		return "", false
	}
	return e.path, true
}

func (b fsdBackend) Close(h uintptr) error {
	handMu.Lock()
	delete(handTab, h)
	handMu.Unlock()
	return nil
}

func (b fsdBackend) Pread(h uintptr, buf []byte, off int64) (int, error) {
	p, ok := b.hpath(h)
	if !ok {
		return 0, syscall.EBADF
	}
	n, err := readAtPath(p, buf, off)
	return n, toErrno(err)
}

func (b fsdBackend) Pwrite(h uintptr, buf []byte, off int64) (int, error) {
	p, ok := b.hpath(h)
	if !ok {
		return 0, syscall.EBADF
	}
	n, err := writeAtPath(p, buf, off)
	return n, toErrno(err)
}

func (b fsdBackend) Fstat(h uintptr) (int64, bool, error) {
	p, ok := b.hpath(h)
	if !ok {
		return 0, false, syscall.EBADF
	}
	fi, err := Stat(p)
	return fi.Size, fi.IsDir, toErrno(err)
}

func (b fsdBackend) Dirents(h uintptr) ([]string, []bool, error) {
	p, ok := b.hpath(h)
	if !ok {
		return nil, nil, syscall.EBADF
	}
	es, err := ReadDir(p)
	if err != nil {
		return nil, nil, toErrno(err)
	}
	names := make([]string, len(es))
	dirs := make([]bool, len(es))
	for i, e := range es {
		names[i], dirs[i] = e.Name, e.IsDir
	}
	return names, dirs, nil
}

func (fsdBackend) Stat(path string) (int64, bool, error) {
	fi, err := Stat(path)
	return fi.Size, fi.IsDir, toErrno(err)
}

func (fsdBackend) Mkdir(path string, perm uint32) error { return toErrno(Mkdir(path)) }

func (fsdBackend) Remove(path string, dir bool) error { return toErrno(Remove(path)) }

func (fsdBackend) Rename(from, to string) error { return toErrno(Rename(from, to)) }

func (fsdBackend) Truncate(path string, size int64) error {
	if size == 0 {
		_ = Remove(path)
		return toErrno(writeAtPathErr(path, nil))
	}
	// fsd has no shrink; a grow could be a zero-padded write, but nothing
	// in scope needs it.
	return syscall.ENOSYS
}

func (fsdBackend) Getwd() (string, error) {
	s, err := Getwd()
	return s, toErrno(err)
}

func (fsdBackend) Chdir(path string) error { return toErrno(Chdir(path)) }
