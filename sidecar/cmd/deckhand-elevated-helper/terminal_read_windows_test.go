//go:build windows

package main

import (
	"syscall"
	"testing"
)

func TestTerminalDeviceReadErrorWindows(t *testing.T) {
	if !isTerminalDeviceReadError(syscall.ERROR_HANDLE_EOF, 0, 0) {
		t.Fatal("ERROR_HANDLE_EOF should be terminal")
	}
	if !isTerminalDeviceReadError(syscall.ERROR_HANDLE_EOF, 1024, 1024) {
		t.Fatal("ERROR_HANDLE_EOF at the expected end should be terminal")
	}
	if isTerminalDeviceReadError(syscall.ERROR_HANDLE_EOF, 512, 1024) {
		t.Fatal("early ERROR_HANDLE_EOF should fail")
	}
	if !isTerminalDeviceReadError(windowsErrorInvalidParameter, 1024, 1024) {
		t.Fatal("ERROR_INVALID_PARAMETER at the expected end should be terminal")
	}
	if isTerminalDeviceReadError(windowsErrorInvalidParameter, 512, 1024) {
		t.Fatal("ERROR_INVALID_PARAMETER before the expected end should fail")
	}
}
