package main

// Stage 4.1 for Go on racccoon (docs/go-port-plan.md): os/exec, backed
// by rfork(RFPROC) + SYS_EXEC + SYS_JOIN (runtime/goos.Spawn/Wait, via
// a syscall_tamago.go patch). First cut: the child inherits the
// parent's console — an explicit cmd.Stdout/Stderr = os.Stdout/os.Stderr
// works; pipe capture (cmd.Output) does not yet.

import (
	"os"
	"os/exec"
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
	println("go stage 4.1: os/exec")

	// Run a c3 /bin utility, output straight to the console.
	c := exec.Command("/bin/echo", "exec", "from", "go")
	c.Stdout, c.Stderr = os.Stdout, os.Stderr
	err := c.Run()
	check("exec.Command(/bin/echo).Run()", err == nil)
	check("echo exit 0", c.ProcessState != nil && c.ProcessState.ExitCode() == 0)

	// A command that exits non-zero — /bin/false.
	f := exec.Command("/bin/false")
	f.Stdout, f.Stderr = os.Stdout, os.Stderr
	ferr := f.Run()
	check("false -> non-nil error", ferr != nil)
	check("false exit != 0", f.ProcessState != nil && f.ProcessState.ExitCode() != 0)

	// A missing command — should fail before spawning.
	m := exec.Command("/bin/does-not-exist")
	m.Stdout, m.Stderr = os.Stdout, os.Stderr
	merr := m.Run()
	check("missing command -> error", merr != nil)

	// Chain: run another Go binary if it's on the image.
	if _, e := os.Stat("/bin/go-hello"); e == nil {
		g := exec.Command("/bin/go-hello")
		g.Stdout, g.Stderr = os.Stdout, os.Stderr
		gerr := g.Run()
		check("exec a Go binary (/bin/go-hello)", gerr == nil && g.ProcessState.ExitCode() == 0)
	} else {
		println("  --   /bin/go-hello not on image, skipping Go-execs-Go")
	}

	if failed {
		println("go stage 4.1: FAILED")
		os.Exit(1)
	}
	println("go stage 4.1: all checks passed")
}
