package main

// Stage 3.5 for Go on racccoon (docs/go-port-plan.md): the *standard*
// os package, operating on fsd. The only racccoon-specific line is the
// blank import below — it installs the fsd backend into runtime/goos.FS
// (via a small toolchain patch, lib/go/racccoon.patch), after which
// os.Open / os.ReadFile / os.ReadDir / os.Getwd / os.Create ... all
// hit the real filesystem. Exits 0 only if every check passes; e2fsck
// on the image afterward must be clean.

import (
	"bytes"
	"io"
	"os"

	_ "racccoon.local/goport/racccoon"
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

func main() {
	println("go stage 3.5: package os on fsd")

	// --- read a seeded fixture with the standard os API ---
	b, err := os.ReadFile("/hello.txt")
	check("os.ReadFile /hello.txt", err == nil && string(b) == "Hello from ext2!\n")

	fi, err := os.Stat("/hello.txt")
	check("os.Stat size + mode", err == nil && fi.Size() == int64(len(b)) && !fi.IsDir())

	di, err := os.Stat("/subdir")
	check("os.Stat /subdir IsDir", err == nil && di.IsDir())

	_, err = os.Open("/nope-not-here")
	check("os.Open missing -> IsNotExist", os.IsNotExist(err))

	// --- os.File: Open, io.ReadAll, Seek, ReadAt ---
	f, err := os.Open("/hello.txt")
	if err != nil {
		check("os.Open /hello.txt", false)
	} else {
		all, e := io.ReadAll(f)
		check("io.ReadAll(os.File)", e == nil && bytes.Equal(all, b))
		_, e = f.Seek(6, io.SeekStart)
		buf := make([]byte, 4)
		n, e2 := f.Read(buf)
		check("Seek+Read mid-file", e == nil && e2 == nil && n == 4 && string(buf) == "from")
		var at [4]byte
		nn, e3 := f.ReadAt(at[:], 0)
		check("ReadAt(0)", e3 == nil && nn == 4 && string(at[:]) == "Hell")
		f.Close()
	}

	// --- os.ReadDir (dirents through the hook) ---
	des, err := os.ReadDir("/")
	names := map[string]bool{}
	for _, d := range des {
		names[d.Name()] = true
	}
	check("os.ReadDir / (hello.txt, subdir, bin)", err == nil && names["hello.txt"] && names["subdir"] && names["bin"])

	sub, err := os.ReadDir("/subdir")
	check("os.ReadDir /subdir has nested.txt", err == nil && len(sub) == 1 && sub[0].Name() == "nested.txt")

	many, err := os.ReadDir("/manyfiles")
	check("os.ReadDir /manyfiles (60, paginated)", err == nil && len(many) == 60)

	// --- write path: WriteFile, Create, read back ---
	payload := bytes.Repeat([]byte("os-on-fsd-"), 500) // 5000 bytes
	err = os.WriteFile("/tmp/os35.txt", payload, 0644)
	check("os.WriteFile", err == nil)
	rb, err := os.ReadFile("/tmp/os35.txt")
	check("os.ReadFile back matches", err == nil && bytes.Equal(rb, payload))

	cf, err := os.Create("/tmp/os35b.txt")
	if err != nil {
		check("os.Create", false)
	} else {
		_, e1 := cf.Write([]byte("created via os.Create\n"))
		e2 := cf.Close()
		check("Create+Write+Close", e1 == nil && e2 == nil)
		cb, e3 := os.ReadFile("/tmp/os35b.txt")
		check("read Create'd file", e3 == nil && string(cb) == "created via os.Create\n")
	}

	// O_TRUNC: overwrite a longer file with a shorter one
	os.WriteFile("/tmp/os35.txt", []byte("short"), 0644)
	tb, err := os.ReadFile("/tmp/os35.txt")
	check("O_TRUNC shortens", err == nil && string(tb) == "short")

	// --- Mkdir, Rename, Remove, Getwd ---
	err = os.Mkdir("/tmp/os35dir", 0755)
	check("os.Mkdir", err == nil)
	err = os.WriteFile("/tmp/os35dir/inner.txt", []byte("x"), 0644)
	check("write into new dir", err == nil)

	err = os.Rename("/tmp/os35b.txt", "/tmp/os35c.txt")
	check("os.Rename", err == nil)
	_, err = os.Stat("/tmp/os35b.txt")
	check("old name gone after rename", os.IsNotExist(err))

	wd, err := os.Getwd()
	check("os.Getwd", err == nil && len(wd) > 0 && wd[0] == '/')

	// os.Args — the exec ABI, captured by the provider's CPUInit.
	// gostage35test execs this with "alpha" "beta"; os.Args[0] is a
	// synthetic "go".
	check("os.Args count", len(os.Args) == 3)
	check("os.Args[1:] == alpha beta",
		len(os.Args) == 3 && os.Args[1] == "alpha" && os.Args[2] == "beta")

	check("os.Remove file", os.Remove("/tmp/os35.txt") == nil)
	check("os.Remove renamed", os.Remove("/tmp/os35c.txt") == nil)
	check("os.RemoveAll dir", os.RemoveAll("/tmp/os35dir") == nil)
	_, err = os.Stat("/tmp/os35dir")
	check("dir gone after RemoveAll", os.IsNotExist(err))

	if failed {
		println("go stage 3.5: FAILED")
		panic("stage 3.5 checks failed")
	}
	println("go stage 3.5: all checks passed")
}
