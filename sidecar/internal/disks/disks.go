// Package disks handles local disk enumeration, image reads (backups),
// and image writes (flashes). Writes route through the elevated helper
// binary — the sidecar itself never runs with elevation.
package disks

// DiskInfo is the JSON-serializable shape returned by `disks.list`.
type DiskInfo struct {
	ID         string      `json:"id"`
	Path       string      `json:"path"`
	SizeBytes  int64       `json:"size_bytes"`
	Bus        string      `json:"bus"`
	Model      string      `json:"model"`
	Removable  bool        `json:"removable"`
	IsBoot     bool        `json:"is_boot,omitempty"`
	IsSystem   bool        `json:"is_system,omitempty"`
	IsReadOnly bool        `json:"is_read_only,omitempty"`
	IsOffline  bool        `json:"is_offline,omitempty"`
	Partitions []Partition `json:"partitions"`
	// InterruptedFlash is set when a sentinel left over from a prior,
	// unfinished flash matches this disk. The UI surfaces it so users
	// can recognise a power-loss / crash mid-write before they reuse
	// the device. Nil means "no record of an interrupted flash."
	InterruptedFlash *InterruptedFlash `json:"interrupted_flash,omitempty"`
}

// Partition is one partition on a DiskInfo.
type Partition struct {
	Index      int    `json:"index"`
	Filesystem string `json:"filesystem,omitempty"`
	SizeBytes  int64  `json:"size_bytes"`
	Mountpoint string `json:"mountpoint,omitempty"`
}
