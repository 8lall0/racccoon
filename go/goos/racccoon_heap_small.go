// Copyright 2026 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

//go:build racccoon && riscv64 && !racccoon_bigheap

package goos

// Default heap arena — programs and the `go` command. See RamSize.
const ramSizeBytes uint = 64 << 20
