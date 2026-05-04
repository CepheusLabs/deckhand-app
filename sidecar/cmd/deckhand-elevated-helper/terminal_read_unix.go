//go:build !windows

package main

func platformTerminalDeviceReadError(error, int64, int64) bool {
	return false
}
