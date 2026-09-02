package main

// Stage 4.1 follow-up for Go on racccoon (docs/go-port-plan.md):
// os/exec OUTPUT CAPTURE. exec.Cmd.Output / CombinedOutput / a
// bytes.Buffer Stdout now work — the spawned child's console is pointed
// at a kernel pipe (SYS_PIPE + pipe_setout), drained by goos.Spawn, and
// served back to os/exec's io.Copy goroutine. racccoon gives a process
// one console stream, so captured output is combined stdout+stderr.

import (
	"bytes"
	"os"
	"os/exec"
	"strings"
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
	println("go stage 4.2: os/exec output capture")

	// 1. Output() of a c3 /bin utility.
	out, err := exec.Command("/bin/echo", "hi", "there").Output()
	check("echo Output() no error", err == nil)
	check("echo Output() == 'hi there'", strings.TrimSpace(string(out)) == "hi there")

	// 2. CombinedOutput() of a Go binary with known multi-line output.
	if _, e := os.Stat("/bin/go-hello"); e == nil {
		co, cerr := exec.Command("/bin/go-hello").CombinedOutput()
		check("go-hello CombinedOutput no error", cerr == nil)
		check("go-hello output has 'hello from go on racccoon'",
			strings.Contains(string(co), "hello from go on racccoon"))
		check("go-hello output has 'deferred: bye'",
			strings.Contains(string(co), "deferred: bye"))
	} else {
		println("  --   /bin/go-hello not on image, skipping")
	}

	// 3. A bytes.Buffer as Stdout, explicitly.
	var buf bytes.Buffer
	b := exec.Command("/bin/echo", "buffered")
	b.Stdout = &buf
	berr := b.Run()
	check("buffer Stdout no error", berr == nil)
	check("buffer got 'buffered'", strings.TrimSpace(buf.String()) == "buffered")

	// 4. Large output past the 4 KiB kernel pipe buffer — /bin/go-spew
	//    prints 300 x 72-byte lines (21600 bytes); the child blocks on a
	//    full pipe and the parent's drain loop keeps up. Verify exact
	//    length and that every line survived intact.
	if _, e := os.Stat("/bin/go-spew"); e == nil {
		const spewLine = "0123456789abcdefghijklmnopqrstuvwxyz-ABCDEFGHIJKLMNOPQRSTUVWXYZ_the_quick\n"
		const spewLines = 300
		sp, spErr := exec.Command("/bin/go-spew").Output()
		check("go-spew no error", spErr == nil)
		println("  ..   go-spew captured", len(sp), "bytes (want", spewLines*len(spewLine), ")")
		check("go-spew exact length", len(sp) == spewLines*len(spewLine))
		check("go-spew content is the repeated line",
			len(sp) == spewLines*len(spewLine) && string(sp) == strings.Repeat(spewLine, spewLines))
	} else {
		println("  --   /bin/go-spew not on image, skipping large-output test")
	}

	// 5. Regression: console-inherit (no capture) still works and exit
	//    codes still propagate.
	fr := exec.Command("/bin/false")
	fr.Stdout, fr.Stderr = os.Stdout, os.Stderr
	check("inherit-console /bin/false still errors", fr.Run() != nil)

	if failed {
		println("go stage 4.2: FAILED")
		os.Exit(1)
	}
	println("go stage 4.2: all checks passed")
}
