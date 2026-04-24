package disks

import (
	"runtime"
	"testing"
)

func TestResolveDevicePath_Unix(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("unix-only")
	}
	cases := map[string]string{
		"/dev/sda":       "/dev/sda",
		"/dev/nvme0n1":   "/dev/nvme0n1",
		"/dev/mmcblk0p2": "/dev/mmcblk0p2",
	}
	for in, want := range cases {
		t.Run(in, func(t *testing.T) {
			got, err := ResolveDevicePath(in, "")
			if err != nil {
				t.Fatalf("expected accept, got %v", err)
			}
			if got != want {
				t.Fatalf("got %q, want %q", got, want)
			}
		})
	}
	// deviceID without /dev prefix gets prepended.
	got, err := ResolveDevicePath("", "sda")
	if err != nil || got != "/dev/sda" {
		t.Fatalf("expected /dev/sda, got %q err=%v", got, err)
	}
}

func TestResolveDevicePath_RejectsBadPaths(t *testing.T) {
	rejects := []struct {
		name   string
		path   string
		device string
	}{
		{"empty", "", ""},
		{"etc_shadow", "/etc/shadow", ""},
		{"home_ssh_key", "/home/user/.ssh/id_rsa", ""},
		{"null_device", "/dev/null", ""},
		{"traversal", "/dev/sda/../../etc/shadow", ""},
	}
	if runtime.GOOS != "windows" {
		rejects = append(rejects, struct {
			name   string
			path   string
			device string
		}{"bare_dev_prefix", "/dev/sd", ""})
	}
	for _, tc := range rejects {
		t.Run(tc.name, func(t *testing.T) {
			if got, err := ResolveDevicePath(tc.path, tc.device); err == nil {
				t.Fatalf("expected reject, got %q", got)
			}
		})
	}
}

func TestResolveDevicePath_Windows(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("windows-only")
	}
	got, err := ResolveDevicePath("", "PhysicalDrive3")
	if err != nil {
		t.Fatalf("expected accept, got %v", err)
	}
	if got != `\\.\PHYSICALDRIVE3` {
		t.Fatalf("got %q", got)
	}
	// Existing \\.\ prefix also accepted.
	got, err = ResolveDevicePath(`\\.\PhysicalDrive0`, "")
	if err != nil {
		t.Fatalf("expected accept, got %v", err)
	}
	if got != `\\.\PHYSICALDRIVE0` {
		t.Fatalf("got %q", got)
	}
	// A named pipe is rejected.
	if _, err := ResolveDevicePath(`\\.\PIPE\evil`, ""); err == nil {
		t.Fatalf("expected reject for named pipe")
	}
}
