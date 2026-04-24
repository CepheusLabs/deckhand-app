//go:build darwin

package disks

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"
)

// List enumerates disks on macOS via diskutil's plist output, converted
// to JSON via plutil for broader compatibility (diskutil -p JSON only
// landed on macOS 12+).
func List(ctx context.Context) ([]DiskInfo, error) {
	plistCmd := exec.CommandContext(ctx, "diskutil", "list", "-plist")
	plistOut, err := plistCmd.Output()
	if err != nil {
		return nil, fmt.Errorf("diskutil list failed: %w", err)
	}

	conv := exec.CommandContext(ctx, "plutil", "-convert", "json", "-o", "-", "-")
	// bytes.NewReader avoids the []byte->string allocation copy that
	// strings.NewReader(string(...)) forced. On a system with many
	// disks this matters; on a system with one disk it's still the
	// correct type.
	conv.Stdin = bytes.NewReader(plistOut)
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

		info, infoErr := extraDiskInfo(ctx, d.DeviceIdentifier)
		// Don't fail the whole list because one disk's extras couldn't
		// be fetched (diskutil info occasionally errors on transient
		// disks), but do record the shortfall so callers can see it.
		if infoErr != nil && info.bus == "" {
			info.bus = "Unknown"
		}

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

func extraDiskInfo(ctx context.Context, deviceID string) (diskExtras, error) {
	cmd := exec.CommandContext(ctx, "diskutil", "info", "-plist", deviceID)
	plistOut, err := cmd.Output()
	if err != nil {
		return diskExtras{}, fmt.Errorf("diskutil info %q: %w", deviceID, err)
	}
	conv := exec.CommandContext(ctx, "plutil", "-convert", "json", "-o", "-", "-")
	conv.Stdin = bytes.NewReader(plistOut)
	convOut, err := conv.Output()
	if err != nil {
		return diskExtras{}, fmt.Errorf("plutil convert for %q: %w", deviceID, err)
	}
	var info struct {
		BusProtocol    string `json:"BusProtocol"`
		DeviceModel    string `json:"MediaName"`
		RemovableMedia bool   `json:"RemovableMedia"`
	}
	if err := json.Unmarshal(convOut, &info); err != nil {
		return diskExtras{}, fmt.Errorf("parse diskutil info json for %q: %w", deviceID, err)
	}
	return diskExtras{
		bus:       info.BusProtocol,
		model:     strings.TrimSpace(info.DeviceModel),
		removable: info.RemovableMedia,
	}, nil
}
