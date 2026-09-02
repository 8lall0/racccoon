package main

// Stage 3 for Go on racccoon (docs/go-port-plan.md): real file I/O
// against the fsd server, via the racccoon package (go/racccoon). Reads
// a seeded fixture, walks directories (including a paginated one),
// writes + reads back + renames + removes under /tmp, and makes a
// directory tree. Exits 0 only if every check passes; e2fsck on the
// image afterward must be clean.

import (
	"bytes"

	rc "racccoon.local/goport/racccoon"
)

var failed bool

func check(name string, ok bool) {
	if ok {
		println("  ok  ", name)
	} else {
		println("  FAIL", name)
		failed = true
	}
}

func hasEntry(es []rc.DirEntry, name string, dir bool) bool {
	for _, e := range es {
		if e.Name == name {
			return e.IsDir == dir
		}
	}
	return false
}

func main() {
	println("go stage 3: file I/O against fsd")

	// --- read a seeded fixture ---
	b, err := rc.ReadFile("/hello.txt")
	check("ReadFile /hello.txt", err == nil && string(b) == "Hello from ext2!\n")

	fi, err := rc.Stat("/hello.txt")
	check("Stat /hello.txt size", err == nil && fi.Size == int64(len(b)) && !fi.IsDir)

	di, err := rc.Stat("/subdir")
	check("Stat /subdir is dir", err == nil && di.IsDir)

	_, err = rc.ReadFile("/does-not-exist")
	check("ReadFile missing -> error", err != nil)

	// --- directory walks ---
	root, err := rc.ReadDir("/")
	check("ReadDir / has hello.txt", err == nil && hasEntry(root, "hello.txt", false))
	check("ReadDir / has subdir/", err == nil && hasEntry(root, "subdir", true))
	check("ReadDir / has bin/", err == nil && hasEntry(root, "bin", true))

	sub, err := rc.ReadDir("/subdir")
	check("ReadDir /subdir has nested.txt", err == nil && hasEntry(sub, "nested.txt", false))

	// /manyfiles is 60 entries — past one FS_LIST reply, so this
	// exercises the pagination loop.
	many, err := rc.ReadDir("/manyfiles")
	check("ReadDir /manyfiles paginated (60)", err == nil && len(many) == 60)

	// --- write, read back, rename, remove under /tmp ---
	payload := bytes.Repeat([]byte("racccoon-go-"), 400) // 4800 bytes, several FS_WRITE_AT chunks
	err = rc.WriteFile("/tmp/go3.txt", payload)
	check("WriteFile /tmp/go3.txt", err == nil)

	back, err := rc.ReadFile("/tmp/go3.txt")
	check("read back matches", err == nil && bytes.Equal(back, payload))

	wfi, err := rc.Stat("/tmp/go3.txt")
	check("Stat written size", err == nil && wfi.Size == int64(len(payload)))

	err = rc.Rename("/tmp/go3.txt", "/tmp/go3b.txt")
	check("Rename", err == nil)
	back2, err := rc.ReadFile("/tmp/go3b.txt")
	check("read renamed", err == nil && bytes.Equal(back2, payload))

	// --- a directory tree ---
	err = rc.Mkdir("/tmp/godir")
	check("Mkdir /tmp/godir", err == nil)
	gdi, err := rc.Stat("/tmp/godir")
	check("Mkdir'd path is a dir", err == nil && gdi.IsDir)

	err = rc.WriteFile("/tmp/godir/inner.txt", []byte("inner"))
	check("WriteFile in new dir", err == nil)
	gd, err := rc.ReadDir("/tmp/godir")
	check("ReadDir new dir has inner.txt", err == nil && hasEntry(gd, "inner.txt", false))

	// --- cleanup ---
	check("Remove /tmp/go3b.txt", rc.Remove("/tmp/go3b.txt") == nil)
	check("RemoveAll /tmp/godir", rc.RemoveAll("/tmp/godir") == nil)
	_, err = rc.Stat("/tmp/go3b.txt")
	check("removed file is gone", err != nil)

	if failed {
		println("go stage 3: FAILED")
		panic("stage 3 checks failed")
	}
	println("go stage 3: all checks passed")
}
