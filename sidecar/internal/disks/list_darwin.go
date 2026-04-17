//go:build darwin

package disks

import (
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"
)

// List enumerates disks on macOS via diskutil's JSON output (-p JSON
// format, supported on macOS 12+). We use `list -plist` then convert
// via plutil for broader compatibility.
func List(ctx context.Context) ([]DiskInfo, error) {
	// `diskutil list -plist` emits plist; pipe through plutil to get JSON.
	plistCmd := exec.CommandContext(ctx, "diskutil", "list", "-plist")
	plistOut, err := plistCmd.Output()
	if err != nil {
		return nil, fmt.Errorf("diskutil list failed: %w", err)
	}

	conv := exec.CommandContext(ctx, "plutil", "-convert", "json", "-o", "-", "-")
	conv.Stdin = strings.NewReader(string(plistOut))
	convOut, err := conv.Output()
	if err != nil {
		return nil, fmt.Errorf("plutil convert failed: %w", err)
	}

	var list struct {
		AllDisksAndPartitions []struct {
			DeviceIdentifier string `json:"DeviceIdentifier"`
			Size             int64  `json:"Size"`
			Content          string `json:"Content"`
			Partitions       []struct {
				DeviceIdentifier string `json:"DeviceIdentifier"`
				Size             int64  `json:"Size"`
				Content          string `json:"Content"`
				MountPoint       string `json:"MountPoint"`
			} `json:"Partitions"`
		} `json:"AllDisksAndPartitions"`
	}
	if err := json.Unmarshal(convOut, &list); err != nil {
		return nil, fmt.Errorf("parse diskutil json: %w", err)
	}

	var out []DiskInfo
	for _, d := range list.AllDisksAndPartitions {
		parts := make([]Partition, 0, len(d.Partitions))
		for i, pp := range d.Partitions {
			parts = append(parts, Partition{
				Index:      i + 1,
				Filesystem: pp.Content,
				SizeBytes:  pp.Size,
				Mountpoint: pp.MountPoint,
			})
		}

		// Fetch per-disk details for bus + removable + model.
		info := extraDiskInfo(ctx, d.DeviceIdentifier)

		out = append(out, DiskInfo{
			ID:         d.DeviceIdentifier,
			Path:       "/dev/r" + d.DeviceIdentifier, // raw device for faster dd
			SizeBytes:  d.Size,
			Bus:        info.bus,
			Model:      info.model,
			Removable:  info.removable,
			Partitions: parts,
		})
	}
	return out, nil
}

type diskExtras struct {
	bus       string
	model     string
	removable bool
}

func extraDiskInfo(ctx context.Context, deviceID string) diskExtras {
	cmd := exec.CommandContext(ctx, "diskutil", "info", "-plist", deviceID)
	plistOut, err := cmd.Output()
	if err != nil {
		return diskExtras{bus: "Unknown"}
	}
	conv := exec.CommandContext(ctx, "plutil", "-convert", "json", "-o", "-", "-")
	conv.Stdin = strings.NewReader(string(plistOut))
	convOut, err := conv.Output()
	if err != nil {
		return diskExtras{bus: "Unknown"}
	}
	var info struct {
		BusProtocol   string `json:"BusProtocol"`
		DeviceModel   string `json:"MediaName"`
		RemovableMedia bool  `json:"RemovableMedia"`
	}
	if err := json.Unmarshal(convOut, &info); err != nil {
		return diskExtras{bus: "Unknown"}
	}
	return diskExtras{
		bus:       info.BusProtocol,
		model:     strings.TrimSpace(info.DeviceModel),
		removable: info.RemovableMedia,
	}
}
