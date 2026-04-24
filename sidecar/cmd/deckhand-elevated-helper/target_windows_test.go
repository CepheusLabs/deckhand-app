//go:build windows

package main

import "testing"

func TestTargetToDevicePath_Windows_Accepts(t *testing.T) {
	cases := map[string]string{
		"PhysicalDrive0":       `\\.\PHYSICALDRIVE0`,
		"PhysicalDrive3":       `\\.\PHYSICALDRIVE3`,
		"physicaldrive10":      `\\.\PHYSICALDRIVE10`,
		"PHYSICALDRIVE42":      `\\.\PHYSICALDRIVE42`,
		`\\.\PhysicalDrive5`:   `\\.\PHYSICALDRIVE5`,
		`\\.\PHYSICALDRIVE100`: `\\.\PHYSICALDRIVE100`,
	}
	for input, want := range cases {
		t.Run(input, func(t *testing.T) {
			got, err := targetToDevicePath(input)
			if err != nil {
				t.Fatalf("expected accept, got error: %v", err)
			}
			if got != want {
				t.Fatalf("got %q, want %q", got, want)
			}
		})
	}
}

func TestTargetToDevicePath_Windows_Rejects(t *testing.T) {
	cases := []string{
		"",                       // empty
		`C:\Windows\System32`,    // regular path
		`\\.\C:`,                 // volume letter
		`\\.\PIPE\foo`,           // named pipe
		`\\.\PhysicalDriveX`,     // non-digit suffix
		`\\.\PhysicalDrive`,      // no digits
		`PhysicalDrive 1`,        // space in id
		`PhysicalDrive;PowerOff`, // command injection attempt
		`..\PhysicalDrive3`,      // traversal-looking prefix
	}
	for _, tc := range cases {
		t.Run(tc, func(t *testing.T) {
			if got, err := targetToDevicePath(tc); err == nil {
				t.Fatalf("expected reject for %q, got %q", tc, got)
			}
		})
	}
}
