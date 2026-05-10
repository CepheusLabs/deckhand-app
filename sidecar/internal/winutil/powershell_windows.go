//go:build windows

package winutil

import (
	"path/filepath"

	"golang.org/x/sys/windows"
)

// PowerShellExe returns the trusted Windows PowerShell 5.1 executable path.
// Do not resolve powershell.exe through PATH; disk enumeration and helper
// launch diagnostics are security-sensitive enough to avoid PATH hijacking.
func PowerShellExe() (string, error) {
	windowsDir, err := windows.GetSystemWindowsDirectory()
	if err != nil {
		return "", err
	}
	return filepath.Join(
		windowsDir,
		"System32",
		"WindowsPowerShell",
		"v1.0",
		"powershell.exe",
	), nil
}
