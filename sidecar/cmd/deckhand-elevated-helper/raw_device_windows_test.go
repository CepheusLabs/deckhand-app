//go:build windows

package main

import (
	"errors"
	"strings"
	"testing"

	"golang.org/x/sys/windows"
)

func TestLockMountedVolumesForDiskFailsClosedWhenVolumeCannotOpen(t *testing.T) {
	restore := stubWindowsVolumeOps(t)
	defer restore()

	enumerateWindowsVolumesFn = func() ([]string, error) {
		return []string{`\\?\Volume{ok}\`, `\\?\Volume{blocked}\`}, nil
	}
	openWindowsVolumeFn = func(name string) (windows.Handle, error) {
		if strings.Contains(name, "blocked") {
			return 0, errors.New("access denied")
		}
		return windows.Handle(101), nil
	}
	volumeContainsDiskFn = func(windows.Handle, uint32) (bool, error) {
		return true, nil
	}
	lockAndDismountVolumeFn = func(windows.Handle, string) error {
		return nil
	}
	var closed []windows.Handle
	closeWindowsHandleFn = func(handle windows.Handle) error {
		closed = append(closed, handle)
		return nil
	}

	locks, err := lockMountedVolumesForDisk(3)
	if err == nil || !strings.Contains(err.Error(), "open volume") {
		t.Fatalf("expected open-volume error, got locks=%v err=%v", locks, err)
	}
	if len(closed) != 1 || closed[0] != windows.Handle(101) {
		t.Fatalf("closed handles = %v, want [101]", closed)
	}
}

func TestLockMountedVolumesForDiskFailsClosedWhenExtentsCannotBeQueried(t *testing.T) {
	restore := stubWindowsVolumeOps(t)
	defer restore()

	enumerateWindowsVolumesFn = func() ([]string, error) {
		return []string{`\\?\Volume{unknown}\`}, nil
	}
	openWindowsVolumeFn = func(string) (windows.Handle, error) {
		return windows.Handle(202), nil
	}
	volumeContainsDiskFn = func(windows.Handle, uint32) (bool, error) {
		return false, errors.New("device io control failed")
	}
	var closed []windows.Handle
	closeWindowsHandleFn = func(handle windows.Handle) error {
		closed = append(closed, handle)
		return nil
	}

	locks, err := lockMountedVolumesForDisk(3)
	if err == nil || !strings.Contains(err.Error(), "query volume") {
		t.Fatalf("expected query-volume error, got locks=%v err=%v", locks, err)
	}
	if len(closed) != 1 || closed[0] != windows.Handle(202) {
		t.Fatalf("closed handles = %v, want [202]", closed)
	}
}

func TestLockMountedVolumesForDiskSkipsUnsupportedVolumeExtents(t *testing.T) {
	restore := stubWindowsVolumeOps(t)
	defer restore()

	enumerateWindowsVolumesFn = func() ([]string, error) {
		return []string{`\\?\Volume{unsupported}\`, `\\?\Volume{target}\`}, nil
	}
	openWindowsVolumeFn = func(name string) (windows.Handle, error) {
		if strings.Contains(name, "unsupported") {
			return windows.Handle(303), nil
		}
		return windows.Handle(404), nil
	}
	volumeContainsDiskFn = func(handle windows.Handle, diskNumber uint32) (bool, error) {
		if handle == windows.Handle(303) {
			return false, windows.ERROR_INVALID_FUNCTION
		}
		if diskNumber != 3 {
			t.Fatalf("diskNumber = %d, want 3", diskNumber)
		}
		return true, nil
	}
	var locked []windows.Handle
	lockAndDismountVolumeFn = func(handle windows.Handle, volumeName string) error {
		locked = append(locked, handle)
		return nil
	}
	var closed []windows.Handle
	closeWindowsHandleFn = func(handle windows.Handle) error {
		closed = append(closed, handle)
		return nil
	}

	locks, err := lockMountedVolumesForDisk(3)
	if err != nil {
		t.Fatalf("lockMountedVolumesForDisk() error = %v", err)
	}
	if len(locks) != 1 || locks[0] != windows.Handle(404) {
		t.Fatalf("locks = %v, want [404]", locks)
	}
	if len(locked) != 1 || locked[0] != windows.Handle(404) {
		t.Fatalf("locked = %v, want [404]", locked)
	}
	if len(closed) != 1 || closed[0] != windows.Handle(303) {
		t.Fatalf("closed handles = %v, want [303]", closed)
	}
}

func TestLockAndDismountVolumeDismountsBusyVolumeBeforeRetryingLock(t *testing.T) {
	restore := stubWindowsVolumeOps(t)
	defer restore()

	var calls []uint32
	deviceIoControlFn = func(
		handle windows.Handle,
		ioControlCode uint32,
		inBuffer *byte,
		inBufferSize uint32,
		outBuffer *byte,
		outBufferSize uint32,
		bytesReturned *uint32,
		overlapped *windows.Overlapped,
	) error {
		calls = append(calls, ioControlCode)
		if ioControlCode == fsctlLockVolume && len(calls) == 1 {
			return windows.ERROR_ACCESS_DENIED
		}
		return nil
	}

	if err := lockAndDismountVolume(windows.Handle(505), `\\?\Volume{busy}\`); err != nil {
		t.Fatalf("lockAndDismountVolume() error = %v", err)
	}

	want := []uint32{fsctlLockVolume, fsctlDismountVolume, fsctlLockVolume}
	if len(calls) != len(want) {
		t.Fatalf("calls = %v, want %v", calls, want)
	}
	for i := range want {
		if calls[i] != want[i] {
			t.Fatalf("calls = %v, want %v", calls, want)
		}
	}
}

func TestLockAndDismountVolumeAcceptsBusyLockAfterSuccessfulDismount(t *testing.T) {
	restore := stubWindowsVolumeOps(t)
	defer restore()

	var calls []uint32
	deviceIoControlFn = func(
		handle windows.Handle,
		ioControlCode uint32,
		inBuffer *byte,
		inBufferSize uint32,
		outBuffer *byte,
		outBufferSize uint32,
		bytesReturned *uint32,
		overlapped *windows.Overlapped,
	) error {
		calls = append(calls, ioControlCode)
		if ioControlCode == fsctlLockVolume {
			return windows.ERROR_ACCESS_DENIED
		}
		return nil
	}

	if err := lockAndDismountVolume(windows.Handle(606), `\\?\Volume{usb}\`); err != nil {
		t.Fatalf("lockAndDismountVolume() error = %v", err)
	}

	want := []uint32{fsctlLockVolume, fsctlDismountVolume, fsctlLockVolume}
	if len(calls) != len(want) {
		t.Fatalf("calls = %v, want %v", calls, want)
	}
	for i := range want {
		if calls[i] != want[i] {
			t.Fatalf("calls = %v, want %v", calls, want)
		}
	}
}

func TestLockAndDismountVolumeFailsWhenDismountFails(t *testing.T) {
	restore := stubWindowsVolumeOps(t)
	defer restore()

	deviceIoControlFn = func(
		handle windows.Handle,
		ioControlCode uint32,
		inBuffer *byte,
		inBufferSize uint32,
		outBuffer *byte,
		outBufferSize uint32,
		bytesReturned *uint32,
		overlapped *windows.Overlapped,
	) error {
		if ioControlCode == fsctlLockVolume {
			return windows.ERROR_ACCESS_DENIED
		}
		return windows.ERROR_LOCK_VIOLATION
	}

	err := lockAndDismountVolume(windows.Handle(707), `\\?\Volume{stuck}\`)
	if err == nil || !strings.Contains(err.Error(), "dismount busy volume also failed") {
		t.Fatalf("expected dismount failure, got %v", err)
	}
}

func stubWindowsVolumeOps(t *testing.T) func() {
	t.Helper()
	prevEnumerate := enumerateWindowsVolumesFn
	prevOpen := openWindowsVolumeFn
	prevContains := volumeContainsDiskFn
	prevLock := lockAndDismountVolumeFn
	prevClose := closeWindowsHandleFn
	prevDeviceIoControl := deviceIoControlFn
	return func() {
		enumerateWindowsVolumesFn = prevEnumerate
		openWindowsVolumeFn = prevOpen
		volumeContainsDiskFn = prevContains
		lockAndDismountVolumeFn = prevLock
		closeWindowsHandleFn = prevClose
		deviceIoControlFn = prevDeviceIoControl
	}
}
