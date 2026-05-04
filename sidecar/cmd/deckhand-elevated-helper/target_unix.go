//go:build !windows

package main

import (
	"fmt"
	"path/filepath"
	"strings"
)

// allowedUnixPrefixes is the whitelist of raw-device path roots the
// helper will accept. Everything else - including regular files, config
// files, and `/dev/null` style specials - is rejected.
var allowedUnixPrefixes = []string{
	"/dev/sd",     // SCSI/SATA on Linux
	"/dev/nvme",   // NVMe on Linux
	"/dev/mmcblk", // SD/eMMC on Linux
	"/dev/disk",   // macOS whole-disk path
	"/dev/rdisk",  // macOS raw-disk path (recommended for writes)
	"/dev/loop",   // Linux loopback - used by tests + dev rigs
	"/dev/vd",     // virtio disks (KVM/QEMU) - appear in dev VMs
}

// targetToDevicePath validates the Unix device target and returns a
// cleaned path. The helper runs as root; accepting an arbitrary path
// here would be a root-arbitrary-write primitive.
func targetToDevicePath(target string) (string, error) {
	if target == "" {
		return "", fmt.Errorf("empty device target")
	}
	// filepath.Clean resolves `.` and `..` segments; we then reject any
	// path that still contains a `..` component after cleaning (which
	// only happens if the caller stuck one at the very start).
	clean := filepath.Clean(target)
	if strings.Contains(clean, "..") {
		return "", fmt.Errorf("device target %q contains path traversal", target)
	}
	for _, prefix := range allowedUnixPrefixes {
		// Require the path to start with the prefix AND have at least
		// one more character after it, so `/dev/sd` alone does not
		// match (it must be `/dev/sda`, `/dev/sdb1`, etc.).
		if strings.HasPrefix(clean, prefix) && len(clean) > len(prefix) {
			return clean, nil
		}
	}
	return "", fmt.Errorf("device target %q is not a recognised raw-disk path (allowed prefixes: %s)",
		target, strings.Join(allowedUnixPrefixes, ", "))
}
