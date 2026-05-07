//go:build windows

package main

import (
	"encoding/binary"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"

	"golang.org/x/sys/windows"
)

const (
	fsctlLockVolume              = 0x00090018
	fsctlDismountVolume          = 0x00090020
	ioctlVolumeGetVolumeExtents  = 0x00560000
	maxVolumeDiskExtents         = 64
	volumeDiskExtentsHeaderBytes = 8
	diskExtentBytes              = 24
)

var (
	enumerateWindowsVolumesFn = enumerateWindowsVolumes
	openWindowsVolumeFn       = openWindowsVolume
	volumeContainsDiskFn      = volumeContainsDisk
	lockAndDismountVolumeFn   = lockAndDismountVolume
	closeWindowsHandleFn      = windows.CloseHandle
	deviceIoControlFn         = windows.DeviceIoControl
)

func requireRawDeviceAccess() error {
	var token windows.Token
	if err := windows.OpenProcessToken(
		windows.CurrentProcess(),
		windows.TOKEN_QUERY,
		&token,
	); err != nil {
		return fmt.Errorf("open process token: %w", err)
	}
	defer token.Close()

	if !token.IsElevated() {
		return fmt.Errorf("helper is not elevated; run Deckhand as Administrator or enable UAC prompts so Windows can elevate the helper")
	}
	return nil
}

func prepareWriteTarget(devicePath string) (func(), error) {
	if err := requireRawDeviceAccess(); err != nil {
		return nil, err
	}

	diskNumber, err := physicalDriveNumber(devicePath)
	if err != nil {
		return nil, err
	}

	locks, err := lockMountedVolumesForDisk(diskNumber)
	if err != nil {
		closeWindowsHandles(locks)
		return nil, err
	}

	return func() {
		closeWindowsHandles(locks)
	}, nil
}

func openDeviceForRead(devicePath string) (*os.File, error) {
	return openDevice(devicePath, windows.GENERIC_READ, windows.FILE_ATTRIBUTE_NORMAL)
}

func openDeviceForWrite(devicePath string) (*os.File, error) {
	return openDevice(
		devicePath,
		windows.GENERIC_WRITE,
		windows.FILE_ATTRIBUTE_NORMAL|windows.FILE_FLAG_WRITE_THROUGH,
	)
}

func openDevice(devicePath string, access uint32, attrs uint32) (*os.File, error) {
	name, err := windows.UTF16PtrFromString(devicePath)
	if err != nil {
		return nil, err
	}
	handle, err := windows.CreateFile(
		name,
		access,
		windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE,
		nil,
		windows.OPEN_EXISTING,
		attrs,
		0,
	)
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(handle), devicePath), nil
}

func physicalDriveNumber(devicePath string) (uint32, error) {
	normalised := strings.TrimPrefix(devicePath, `\\.\`)
	canonical := toCanonicalCase(normalised)
	if !physicalDrivePattern.MatchString(canonical) {
		return 0, fmt.Errorf("device target %q is not a recognised PhysicalDrive<N> id", devicePath)
	}
	n, err := strconv.ParseUint(canonical[len("PhysicalDrive"):], 10, 32)
	if err != nil {
		return 0, fmt.Errorf("parse physical drive number: %w", err)
	}
	return uint32(n), nil
}

func lockMountedVolumesForDisk(diskNumber uint32) ([]windows.Handle, error) {
	volumeNames, err := enumerateWindowsVolumesFn()
	if err != nil {
		return nil, err
	}

	var locks []windows.Handle
	for _, volumeName := range volumeNames {
		handle, err := openWindowsVolumeFn(volumeName)
		if err != nil {
			closeWindowsHandles(locks)
			return nil, fmt.Errorf("open volume %s: %w", volumeName, err)
		}

		matches, extErr := volumeContainsDiskFn(handle, diskNumber)
		if extErr != nil {
			_ = closeWindowsHandleFn(handle)
			if isUnsupportedVolumeExtentsError(extErr) {
				continue
			}
			closeWindowsHandles(locks)
			return nil, fmt.Errorf("query volume %s extents: %w", volumeName, extErr)
		}
		if !matches {
			_ = closeWindowsHandleFn(handle)
			continue
		}

		if err := lockAndDismountVolumeFn(handle, volumeName); err != nil {
			_ = closeWindowsHandleFn(handle)
			closeWindowsHandles(locks)
			return nil, err
		}
		locks = append(locks, handle)
	}
	return locks, nil
}

func isUnsupportedVolumeExtentsError(err error) bool {
	return errors.Is(err, windows.ERROR_INVALID_FUNCTION)
}

func enumerateWindowsVolumes() ([]string, error) {
	buf := make([]uint16, windows.MAX_LONG_PATH)
	find, err := windows.FindFirstVolume(&buf[0], uint32(len(buf)))
	if err != nil {
		if errors.Is(err, windows.ERROR_NO_MORE_FILES) {
			return nil, nil
		}
		return nil, fmt.Errorf("enumerate volumes: %w", err)
	}
	defer windows.FindVolumeClose(find)

	volumes := []string{windows.UTF16ToString(buf)}
	for {
		for i := range buf {
			buf[i] = 0
		}
		err = windows.FindNextVolume(find, &buf[0], uint32(len(buf)))
		if err != nil {
			if errors.Is(err, windows.ERROR_NO_MORE_FILES) {
				return volumes, nil
			}
			return nil, fmt.Errorf("enumerate volumes: %w", err)
		}
		volumes = append(volumes, windows.UTF16ToString(buf))
	}
}

func openWindowsVolume(volumeName string) (windows.Handle, error) {
	openName := strings.TrimRight(volumeName, `\`)
	name, err := windows.UTF16PtrFromString(openName)
	if err != nil {
		return 0, err
	}
	return windows.CreateFile(
		name,
		windows.GENERIC_READ|windows.GENERIC_WRITE,
		windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE,
		nil,
		windows.OPEN_EXISTING,
		windows.FILE_ATTRIBUTE_NORMAL,
		0,
	)
}

func volumeContainsDisk(handle windows.Handle, diskNumber uint32) (bool, error) {
	buf := make([]byte, volumeDiskExtentsHeaderBytes+diskExtentBytes*maxVolumeDiskExtents)
	var bytesReturned uint32
	err := windows.DeviceIoControl(
		handle,
		ioctlVolumeGetVolumeExtents,
		nil,
		0,
		&buf[0],
		uint32(len(buf)),
		&bytesReturned,
		nil,
	)
	if err != nil {
		return false, err
	}
	if bytesReturned < volumeDiskExtentsHeaderBytes {
		return false, fmt.Errorf("volume extents response too small")
	}

	count := binary.LittleEndian.Uint32(buf[0:4])
	maxCount := uint32(maxVolumeDiskExtents)
	if count > maxCount {
		count = maxCount
	}
	for i := uint32(0); i < count; i++ {
		offset := volumeDiskExtentsHeaderBytes + int(i)*diskExtentBytes
		if offset+4 > int(bytesReturned) {
			break
		}
		if binary.LittleEndian.Uint32(buf[offset:offset+4]) == diskNumber {
			return true, nil
		}
	}
	return false, nil
}

func lockAndDismountVolume(handle windows.Handle, volumeName string) error {
	if err := lockWindowsVolume(handle); err != nil {
		if !isBusyVolumeError(err) {
			return fmt.Errorf("lock volume %s: %w", volumeName, err)
		}
		if dismountErr := dismountWindowsVolume(handle); dismountErr != nil {
			return fmt.Errorf(
				"lock volume %s: %w; dismount busy volume also failed: %w",
				volumeName,
				err,
				dismountErr,
			)
		}
		if retryErr := lockWindowsVolume(handle); retryErr != nil {
			if isBusyVolumeError(retryErr) {
				// Some USB storage adapters keep returning
				// ACCESS_DENIED/SHARING_VIOLATION after FSCTL_DISMOUNT_VOLUME
				// even though the mounted filesystem has been invalidated.
				// Treat that post-dismount lock as best-effort: the helper
				// writes the physical drive handle next, and we still fail
				// closed if the dismount itself did not succeed.
				return nil
			}
			return fmt.Errorf(
				"lock volume %s after dismounting busy filesystem: %w",
				volumeName,
				retryErr,
			)
		}
		return nil
	}
	if err := dismountWindowsVolume(handle); err != nil {
		return fmt.Errorf("dismount volume %s: %w", volumeName, err)
	}
	return nil
}

func lockWindowsVolume(handle windows.Handle) error {
	var bytesReturned uint32
	return deviceIoControlFn(
		handle,
		fsctlLockVolume,
		nil,
		0,
		nil,
		0,
		&bytesReturned,
		nil,
	)
}

func dismountWindowsVolume(handle windows.Handle) error {
	var bytesReturned uint32
	return deviceIoControlFn(
		handle,
		fsctlDismountVolume,
		nil,
		0,
		nil,
		0,
		&bytesReturned,
		nil,
	)
}

func isBusyVolumeError(err error) bool {
	return errors.Is(err, windows.ERROR_ACCESS_DENIED) ||
		errors.Is(err, windows.ERROR_SHARING_VIOLATION) ||
		errors.Is(err, windows.ERROR_LOCK_VIOLATION)
}

func closeWindowsHandles(handles []windows.Handle) {
	for _, handle := range handles {
		_ = closeWindowsHandleFn(handle)
	}
}
