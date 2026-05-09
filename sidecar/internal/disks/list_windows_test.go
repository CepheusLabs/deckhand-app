//go:build windows

package disks

import (
	"context"
	"errors"
	"strings"
	"testing"
)

func TestListFallsBackToCIMWhenGetDiskCannotLoad(t *testing.T) {
	orig := runPowerShell
	t.Cleanup(func() { runPowerShell = orig })

	runPowerShell = func(_ context.Context, script string) ([]byte, error) {
		switch {
		case strings.Contains(script, "Get-Disk"):
			return nil, errors.New("Storage module could not be loaded")
		case strings.Contains(script, "Win32_DiskDrive"):
			return []byte(`[
				{
					"Index": 3,
					"Model": "Generic STORAGE DEVICE USB Device",
					"Size": 7814016000,
					"InterfaceType": "USB",
					"MediaType": "Removable Media"
				}
			]`), nil
		default:
			t.Fatalf("unexpected PowerShell script: %s", script)
			return nil, nil
		}
	}

	got, err := List(context.Background())
	if err != nil {
		t.Fatalf("List() error = %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("List() returned %d disks, want 1", len(got))
	}
	d := got[0]
	if d.ID != "PhysicalDrive3" || d.Path != `\\.\PHYSICALDRIVE3` {
		t.Fatalf("disk identity = (%q, %q), want PhysicalDrive3 path", d.ID, d.Path)
	}
	if d.Model != "Generic STORAGE DEVICE USB Device" {
		t.Fatalf("model = %q", d.Model)
	}
	if d.Bus != "USB" || !d.Removable {
		t.Fatalf("bus/removable = %q/%v, want USB/removable", d.Bus, d.Removable)
	}
	if d.SizeBytes != 7814016000 {
		t.Fatalf("size = %d", d.SizeBytes)
	}
}

func TestListFallsBackToCIMWhenGetDiskReturnsNoUsableDisks(t *testing.T) {
	orig := runPowerShell
	t.Cleanup(func() { runPowerShell = orig })

	runPowerShell = func(_ context.Context, script string) ([]byte, error) {
		switch {
		case strings.Contains(script, "Get-Disk"):
			return []byte(`null`), nil
		case strings.Contains(script, "Win32_DiskDrive"):
			return []byte(`{
				"Index": 4,
				"Model": "USB Storage",
				"Size": 8000000000,
				"InterfaceType": "USB",
				"MediaType": "Removable Media"
			}`), nil
		default:
			t.Fatalf("unexpected PowerShell script: %s", script)
			return nil, nil
		}
	}

	got, err := List(context.Background())
	if err != nil {
		t.Fatalf("List() error = %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("List() returned %d disks, want 1", len(got))
	}
	if got[0].ID != "PhysicalDrive4" || got[0].Model != "USB Storage" {
		t.Fatalf("fallback disk = %#v", got[0])
	}
}

func TestListDropsInvalidGetDiskRecords(t *testing.T) {
	orig := runPowerShell
	t.Cleanup(func() { runPowerShell = orig })

	runPowerShell = func(_ context.Context, script string) ([]byte, error) {
		switch {
		case strings.Contains(script, "Get-Partition"):
			return []byte(`[]`), nil
		case strings.Contains(script, "Get-Disk"):
			return []byte(`[
				{"Number": -1, "FriendlyName": "bad number", "Size": 8000000000, "BusType": "USB", "OperationalStatus": "Online"},
				{"Number": 5, "FriendlyName": "bad size", "Size": 0, "BusType": "USB", "OperationalStatus": "Online"},
				{"Number": 6, "FriendlyName": "Good USB", "Size": 16000000000, "BusType": "USB", "OperationalStatus": "Online"}
			]`), nil
		default:
			t.Fatalf("unexpected PowerShell script: %s", script)
			return nil, nil
		}
	}

	got, err := List(context.Background())
	if err != nil {
		t.Fatalf("List() error = %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("List() returned %d disks, want 1: %#v", len(got), got)
	}
	if got[0].ID != "PhysicalDrive6" {
		t.Fatalf("disk id = %q, want PhysicalDrive6", got[0].ID)
	}
}
