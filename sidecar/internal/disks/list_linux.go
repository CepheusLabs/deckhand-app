//go:build linux

package disks

import (
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"
)

// List enumerates disks on Linux using lsblk's JSON output. Requires
// lsblk 2.27+ (Ubuntu 16.04+, Debian 9+) — every supported distro.
func List(ctx context.Context) ([]DiskInfo, error) {
	cmd := exec.CommandContext(ctx, "lsblk", "-J", "-b",
		"-o", "NAME,SIZE,TYPE,MODEL,RM,FSTYPE,MOUNTPOINT,TRAN")
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("lsblk failed: %w", err)
	}
	return parseLsblk(out)
}

type lsblkDevice struct {
	Name       string        `json:"name"`
	Size       int64         `json:"size"`
	Type       string        `json:"type"`
	Model      string        `json:"model"`
	Removable  bool          `json:"rm"`
	FSType     string        `json:"fstype"`
	Mountpoint string        `json:"mountpoint"`
	Tran       string        `json:"tran"`
	Children   []lsblkDevice `json:"children"`
}

func parseLsblk(out []byte) ([]DiskInfo, error) {
	var root struct {
		BlockDevices []lsblkDevice `json:"blockdevices"`
	}
	if err := json.Unmarshal(out, &root); err != nil {
		return nil, fmt.Errorf("parse lsblk: %w", err)
	}
	var results []DiskInfo
	for _, d := range root.BlockDevices {
		if d.Type != "disk" {
			continue
		}
		parts := make([]Partition, 0, len(d.Children))
		for i, c := range d.Children {
			parts = append(parts, Partition{
				Index:      i + 1,
				Filesystem: c.FSType,
				SizeBytes:  c.Size,
				Mountpoint: c.Mountpoint,
			})
		}
		results = append(results, DiskInfo{
			ID:         d.Name,
			Path:       "/dev/" + d.Name,
			SizeBytes:  d.Size,
			Bus:        strings.ToUpper(d.Tran),
			Model:      strings.TrimSpace(d.Model),
			Removable:  d.Removable,
			Partitions: parts,
		})
	}
	return results, nil
}
