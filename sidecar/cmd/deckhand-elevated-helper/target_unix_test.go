//go:build !windows

package main

import (
	"strings"
	"testing"
)

func TestTargetToDevicePath_Accepts(t *testing.T) {
	cases := []string{
		"/dev/sda",
		"/dev/sdb1",
		"/dev/nvme0n1",
		"/dev/nvme0n1p1",
		"/dev/mmcblk0",
		"/dev/mmcblk0p2",
		"/dev/disk2",
		"/dev/rdisk4",
		"/dev/loop0",
		"/dev/vda",
	}
	for _, tc := range cases {
		t.Run(tc, func(t *testing.T) {
			got, err := targetToDevicePath(tc)
			if err != nil {
				t.Fatalf("expected accept, got error: %v", err)
			}
			if got != tc {
				t.Fatalf("expected clean path %q, got %q", tc, got)
			}
		})
	}
}

func TestTargetToDevicePath_Rejects(t *testing.T) {
	cases := []struct {
		name   string
		target string
	}{
		{"empty", ""},
		{"etc_shadow", "/etc/shadow"},
		{"boot", "/boot/vmlinuz"},
		{"home", "/home/user/.ssh/authorized_keys"},
		{"null_device", "/dev/null"},
		{"zero_device", "/dev/zero"},
		{"random_device", "/dev/urandom"},
		{"regular_file", "/tmp/foo"},
		{"relative", "sda"},
		{"traversal", "/dev/../etc/shadow"},
		{"traversal_inside_allowed_prefix", "/dev/sd/../../etc/shadow"},
		{"bare_prefix_only_sd", "/dev/sd"},
		{"bare_prefix_only_nvme", "/dev/nvme"},
		{"bare_prefix_only_disk", "/dev/disk"},
		{"proc", "/proc/self/environ"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := targetToDevicePath(tc.target)
			if err == nil {
				t.Fatalf("expected reject for %q, got %q", tc.target, got)
			}
			if !strings.Contains(err.Error(), "target") {
				// Sanity-check the error message mentions the validator
				// domain so debugging is clear. Not a strict requirement
				// but a canary for future rewrites.
				t.Logf("error did not mention target: %v", err)
			}
		})
	}
}
