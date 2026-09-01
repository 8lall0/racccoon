// Copyright 2026 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

//go:build tamago && riscv64

// Package racccoon is a thin convenience layer over package os for
// racccoon Go programs. The actual bridge to the fsd server lives in
// runtime/goos (racccoon_fs.go) and installs itself automatically, so
// plain os.Open / os.ReadFile / os.ReadDir already work — this package
// just offers a couple of small typed helpers. See docs/go-port-plan.md.
package racccoon

import "os"

// FileInfo is the subset of stat racccoon's FS_STAT carries.
type FileInfo struct {
	Size  int64
	IsDir bool
}

// DirEntry is one entry from ReadDir.
type DirEntry struct {
	Name  string
	IsDir bool
}

func ReadFile(name string) ([]byte, error)  { return os.ReadFile(name) }
func WriteFile(name string, b []byte) error { return os.WriteFile(name, b, 0644) }
func Mkdir(name string) error               { return os.Mkdir(name, 0755) }
func Remove(name string) error              { return os.Remove(name) }
func RemoveAll(name string) error           { return os.RemoveAll(name) }
func Rename(oldp, newp string) error        { return os.Rename(oldp, newp) }
func Getwd() (string, error)                { return os.Getwd() }
func Chdir(name string) error               { return os.Chdir(name) }

func Stat(name string) (FileInfo, error) {
	fi, err := os.Stat(name)
	if err != nil {
		return FileInfo{}, err
	}
	return FileInfo{Size: fi.Size(), IsDir: fi.IsDir()}, nil
}

func ReadDir(name string) ([]DirEntry, error) {
	es, err := os.ReadDir(name)
	if err != nil {
		return nil, err
	}
	out := make([]DirEntry, len(es))
	for i, e := range es {
		out[i] = DirEntry{Name: e.Name(), IsDir: e.IsDir()}
	}
	return out, nil
}
