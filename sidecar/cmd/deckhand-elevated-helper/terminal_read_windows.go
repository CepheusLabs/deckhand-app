//go:build windows

package main

import (
	"errors"
	"syscall"
)

const windowsErrorInvalidParameter syscall.Errno = 87

func platformTerminalDeviceReadError(err error, done, total int64) bool {
	if errors.Is(err, syscall.ERROR_HANDLE_EOF) {
		return readReachedExpectedEnd(done, total)
	}
	if total > 0 && readReachedExpectedEnd(done, total) && errors.Is(err, windowsErrorInvalidParameter) {
		return true
	}
	return false
}
