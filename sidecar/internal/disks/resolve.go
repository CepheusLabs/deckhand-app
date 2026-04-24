package disks

import (
	"fmt"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
)

// ResolveDevicePath turns the RPC-supplied path/deviceID pair into the
// canonical OS-specific device path. Keeps platform-specific string
// munging out of the handler layer where it used to live.
//
// Preference order:
//  1. explicit `path` (caller knows the exact device node)
//  2. `deviceID` mapped via the OS convention:
//     - windows: `\\.\PHYSICALDRIVE<N>`
//     - unix: `/dev/<id>`
//
// Every returned path goes through a strict allowlist so a compromised
// caller cannot coerce the sidecar into reading or writing an
// arbitrary file. This mirrors the elevated helper's allowlist - keep
// them in sync if one moves.
func ResolveDevicePath(path, deviceID string) (string, error) {
	if path == "" && deviceID == "" {
		return "", fmt.Errorf("disks.resolve: either path or device_id is required")
	}

	var candidate string
	if path != "" {
		candidate = path
	} else {
		if runtime.GOOS == "windows" {
			candidate = `\\.\` + deviceID
		} else {
			// Accept both "sda" (bare) and "/dev/sda" (already prefixed).
			if strings.HasPrefix(deviceID, "/dev/") {
				candidate = deviceID
			} else {
				candidate = "/dev/" + deviceID
			}
		}
	}

	return validateDevicePath(candidate)
}

var windowsPhysicalDrive = regexp.MustCompile(`(?i)^\\\\\.\\PHYSICALDRIVE[0-9]+$`)

func validateDevicePath(candidate string) (string, error) {
	if candidate == "" {
		return "", fmt.Errorf("empty device path")
	}
	if runtime.GOOS == "windows" {
		if !windowsPhysicalDrive.MatchString(candidate) {
			return "", fmt.Errorf("disks.resolve: %q is not a recognised Windows physical drive path", candidate)
		}
		return strings.ToUpper(candidate), nil
	}
	clean := filepath.Clean(candidate)
	if strings.Contains(clean, "..") {
		return "", fmt.Errorf("disks.resolve: %q contains path traversal", candidate)
	}
	allowedPrefixes := []string{
		"/dev/sd", "/dev/nvme", "/dev/mmcblk",
		"/dev/disk", "/dev/rdisk", "/dev/loop", "/dev/vd",
	}
	for _, prefix := range allowedPrefixes {
		if strings.HasPrefix(clean, prefix) && len(clean) > len(prefix) {
			return clean, nil
		}
	}
	return "", fmt.Errorf("disks.resolve: %q is not under an allowed /dev/ prefix", candidate)
}
