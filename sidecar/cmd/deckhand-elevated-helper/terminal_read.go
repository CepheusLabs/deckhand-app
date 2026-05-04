package main

import (
	"errors"
	"io"
)

func isTerminalDeviceReadError(err error, done, total int64) bool {
	if err == nil {
		return false
	}
	return (errors.Is(err, io.EOF) && readReachedExpectedEnd(done, total)) ||
		platformTerminalDeviceReadError(err, done, total)
}

func readReachedExpectedEnd(done, total int64) bool {
	return total <= 0 || done >= total
}
