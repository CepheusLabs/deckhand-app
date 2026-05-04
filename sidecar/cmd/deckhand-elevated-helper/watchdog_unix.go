//go:build !windows

// Unix half of the parent-PID watchdog. macOS / Linux can use the
// portable kill(pid, 0) trick to test for liveness without actually
// signalling the target.

package main

import (
	"os"
	"syscall"
)

func parentAlive(pid int) bool {
	p, err := os.FindProcess(pid)
	if err != nil {
		return false
	}
	// Signal 0 is a no-op delivery probe: returns nil if the PID
	// exists and we have permission to signal it; ESRCH or EPERM
	// otherwise. We treat any error as "treat as gone" — see
	// watchdog_windows.go for the false-positive vs false-negative
	// trade-off rationale.
	return p.Signal(syscall.Signal(0)) == nil
}
