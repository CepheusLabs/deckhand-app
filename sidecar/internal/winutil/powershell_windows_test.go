//go:build windows

package winutil

import (
	"path/filepath"
	"strings"
	"testing"
)

func TestPowerShellExeUsesSystem32WindowsPowerShell(t *testing.T) {
	got, err := PowerShellExe()
	if err != nil {
		t.Fatalf("PowerShellExe() error = %v", err)
	}
	if !filepath.IsAbs(got) {
		t.Fatalf("PowerShellExe() = %q, want absolute path", got)
	}
	wantSuffix := strings.ToLower(
		filepath.Join("System32", "WindowsPowerShell", "v1.0", "powershell.exe"),
	)
	if !strings.HasSuffix(strings.ToLower(got), wantSuffix) {
		t.Fatalf("PowerShellExe() = %q, want suffix %q", got, wantSuffix)
	}
}
