//go:build windows

package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
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
	if !isTerminalDeviceReadError(windowsErrorSectorNotFound, 1024, 1024) {
		t.Fatal("ERROR_SECTOR_NOT_FOUND at the expected end should be terminal")
	}
	if isTerminalDeviceReadError(windowsErrorSectorNotFound, 512, 1024) {
		t.Fatal("ERROR_SECTOR_NOT_FOUND before the expected end should fail")
	}
}

func TestHashReaderTreatsWindowsTerminalReadErrorAsComplete(t *testing.T) {
	payload := []byte("deckhand live disk hash")
	sum := sha256.Sum256(payload)

	gotSha, gotBytes, err := hashReader(
		&terminalErrorReader{
			reader: bytes.NewReader(payload),
			err:    windowsErrorInvalidParameter,
		},
		int64(len(payload)),
		"",
	)
	if err != nil {
		t.Fatalf("hashReader() error = %v", err)
	}
	if gotBytes != int64(len(payload)) {
		t.Fatalf("hashReader() bytes = %d, want %d", gotBytes, len(payload))
	}
	if gotSha != hex.EncodeToString(sum[:]) {
		t.Fatalf("hashReader() sha = %s, want %s", gotSha, hex.EncodeToString(sum[:]))
	}
}

type terminalErrorReader struct {
	reader *bytes.Reader
	err    error
}

func (r *terminalErrorReader) Read(p []byte) (int, error) {
	if r.reader.Len() == 0 {
		return 0, r.err
	}
	return r.reader.Read(p)
}
