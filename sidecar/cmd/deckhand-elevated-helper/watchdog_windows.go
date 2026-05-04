//go:build windows

// Windows half of the parent-PID watchdog. Used by the helper to
// self-terminate when the unprivileged Deckhand process that
// launched it (via UAC) exits — without this, an aborted UI flow
// leaves the elevated child running until the operation finishes
// naturally, with no way for the unprivileged parent to terminate
// the elevated child.

package main

import "golang.org/x/sys/windows"

// STILL_ACTIVE is GetExitCodeProcess's "the process is still
// running" sentinel (mirrors STATUS_PENDING). Anything else means
// the process has terminated.
const _stillActive = 259

func parentAlive(pid int) bool {
	h, err := windows.OpenProcess(
		windows.PROCESS_QUERY_LIMITED_INFORMATION,
		false,
		uint32(pid),
	)
	if err != nil {
		// OpenProcess failed: PID is gone OR we lack rights. Both
		// land us at "treat as gone" — the watchdog is allowed to
		// be slightly trigger-happy because the consequence of a
		// false-positive is just the helper aborts the op (which
		// the user can re-run), and false-negatives keep an orphan
		// helper running forever.
		return false
	}
	defer windows.CloseHandle(h)
	var exit uint32
	if err := windows.GetExitCodeProcess(h, &exit); err != nil {
		return false
	}
	return exit == _stillActive
}
