// GOOSPKG provider module for running GOOS=racccoon Go binaries as
// racccoon userspace processes. See docs/go-port-plan.md.
//
// The runtime/goos implementation lives in the goos/ subdirectory, per
// the GOOSPKG contract (cmd/go/internal/goos). Point the tamago-go
// toolchain at it with GOOSPKG=racccoon.local/goport.
module racccoon.local/goport

go 1.27
