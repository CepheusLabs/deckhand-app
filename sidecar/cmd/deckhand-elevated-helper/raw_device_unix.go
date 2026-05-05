//go:build !windows

package main

import (
	"fmt"
	"os"
)

func requireRawDeviceAccess() error {
	if os.Geteuid() != 0 {
		return fmt.Errorf("helper is not running as root")
	}
	return nil
}

func prepareWriteTarget(devicePath string) (func(), error) {
	if err := requireRawDeviceAccess(); err != nil {
		return nil, err
	}
	return func() {}, nil
}

func openDeviceForRead(devicePath string) (*os.File, error) {
	return os.Open(devicePath)
}

func openDeviceForWrite(devicePath string) (*os.File, error) {
	return os.OpenFile(devicePath, os.O_WRONLY, 0)
}
