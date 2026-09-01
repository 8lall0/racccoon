// Copyright 2026 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

//go:build tamago && riscv64 && racccoon_bigheap

package goos

// Large heap arena for cmd/compile / cmd/link — built with
// `-tags racccoon_bigheap` (scripts/build_go.sh). Compiling package
// `runtime` on-device peaks well past the default 64 MiB. See RamSize.
const ramSizeBytes uint = 448 << 20
