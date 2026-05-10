//go:build !windows

package winutil

// PowerShellExe is only used by Windows code paths today. Returning the
// command name keeps cross-platform callers simple if a future diagnostic
// wants to report the fallback.
func PowerShellExe() (string, error) {
	return "powershell.exe", nil
}
