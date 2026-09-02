// Copyright 2026 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

//go:build tamago && riscv64 && racccoon_bigheap

package goos

// Large heap arena for cmd/compile / cmd/link — built with
// `-tags racccoon_bigheap` (scripts/build_go.sh). Compiling package
// `runtime` on-device peaks well past the default 64 MiB. Since lazy
// SYS_MAP (docs/devlog.md) this is just a reservation — real pages are
// demand-faulted on touch, so it no longer bloats rfork; the 768 MiB
// QEMU pool (src/kernel.ld) is still why `go` / `asm` stay small. See
// RamSize.
const ramSizeBytes uint = 448 << 20
