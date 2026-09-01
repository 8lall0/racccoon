package main

// A deliberately chatty helper for the Stage 4.2 os/exec capture test
// (go/cmd/gostage42): prints many lines of a fixed pattern so the
// captured stream crosses racccoon's 4 KiB kernel pipe buffer several
// times, exercising the producer-blocks / parent-drains path.

import "os"

const line = "0123456789abcdefghijklmnopqrstuvwxyz-ABCDEFGHIJKLMNOPQRSTUVWXYZ_the_quick\n" // 72 bytes

const lines = 300 // 21600 bytes total

func main() {
	for i := 0; i < lines; i++ {
		os.Stdout.WriteString(line)
	}
}
