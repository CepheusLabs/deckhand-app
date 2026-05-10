package disks

import (
	"fmt"
	"runtime"
	"strings"
)

// SafetyCheckResult describes whether a target disk is plausibly the
// printer's storage (safe to overwrite) or plausibly the user's own
// boot/data drive (NOT safe). The UI is expected to refuse to send the
// confirmation token when any BlockingReason is present — even if the
// user clicked "flash" — and to require a second affirmative click when
// Warnings fire.
//
// This is defense-in-depth. The primary gate is the wizard asking the
// user to confirm the device path; this check catches typos or
// race-conditions where a USB reader was swapped between screens.
type SafetyCheckResult struct {
	DiskID          string   `json:"disk_id"`
	Allowed         bool     `json:"allowed"`
	BlockingReasons []string `json:"blocking_reasons,omitempty"`
	Warnings        []string `json:"warnings,omitempty"`
}

// Flash-target size ceilings. Deckhand targets printer-class eMMC or
// SD cards today (16 GiB – 256 GiB typical). Anything larger than
// MaxTargetBytes is treated as presumptively a user system disk and
// blocked; anything between Warn and Max triggers a warning that the
// UI must force the user to acknowledge.
const (
	MaxTargetBytes  int64 = 512 * 1024 * 1024 * 1024 // 512 GiB hard block
	WarnTargetBytes int64 = 128 * 1024 * 1024 * 1024 // 128 GiB soft warn
	MinTargetBytes  int64 = 1 * 1024 * 1024 * 1024   //   1 GiB too-small block
)

// AssessWriteTarget inspects a candidate DiskInfo and returns the
// safety verdict. The UI is expected to send the whole DiskInfo it
// got from `disks.list`; this keeps the check deterministic from the
// sidecar's perspective (no re-probing).
func AssessWriteTarget(d DiskInfo) SafetyCheckResult {
	res := SafetyCheckResult{DiskID: d.ID, Allowed: true}

	if d.SizeBytes <= 0 {
		res.Allowed = false
		res.BlockingReasons = append(res.BlockingReasons,
			"disk size is zero or unknown — refusing to flash")
	}
	if d.SizeBytes > 0 && d.SizeBytes < MinTargetBytes {
		res.Allowed = false
		res.BlockingReasons = append(res.BlockingReasons,
			fmt.Sprintf("disk is only %d bytes — too small for any printer image", d.SizeBytes))
	}
	if d.SizeBytes > MaxTargetBytes {
		res.Allowed = false
		res.BlockingReasons = append(res.BlockingReasons,
			fmt.Sprintf("disk is %.1f GiB (> %d GiB limit) — presumed not a printer device",
				float64(d.SizeBytes)/(1024*1024*1024),
				MaxTargetBytes/(1024*1024*1024),
			))
	} else if d.SizeBytes > WarnTargetBytes {
		res.Warnings = append(res.Warnings,
			fmt.Sprintf("disk is %.1f GiB — larger than typical printer storage, double-check the device",
				float64(d.SizeBytes)/(1024*1024*1024)))
	}

	// Non-removable on desktop OSes is a strong "this is the user's
	// system disk" signal. Linux/macOS expose eMMC as non-removable too,
	// so the warning is platform-aware.
	if !d.Removable {
		if runtime.GOOS == "windows" {
			res.Allowed = false
			res.BlockingReasons = append(res.BlockingReasons,
				"disk is not removable on Windows — refusing to flash a fixed/system drive")
		} else {
			res.Warnings = append(res.Warnings,
				"disk is reported as non-removable; confirm it is the printer's internal storage, not your own SSD")
		}
	}
	if d.IsBoot || d.IsSystem {
		res.Allowed = false
		res.BlockingReasons = append(res.BlockingReasons,
			"disk is marked as a Windows boot/system disk — refusing to flash")
	}
	if d.IsReadOnly {
		res.Allowed = false
		res.BlockingReasons = append(res.BlockingReasons,
			"disk is read-only — refusing to flash")
	}
	if d.IsOffline {
		res.Allowed = false
		res.BlockingReasons = append(res.BlockingReasons,
			"disk is offline — refusing to flash")
	}

	// Partitions containing a filesystem Windows/macOS/Linux actively
	// mounts at / or C:\ are a hard block.
	for _, part := range d.Partitions {
		m := strings.ToLower(part.Mountpoint)
		switch {
		case m == "/" || strings.HasPrefix(m, "/boot") || strings.HasPrefix(m, "/home"):
			res.Allowed = false
			res.BlockingReasons = append(res.BlockingReasons,
				fmt.Sprintf("partition %d is mounted at %q (system)", part.Index, part.Mountpoint))
		case strings.HasPrefix(m, "c:\\") || strings.HasPrefix(m, "c:/"):
			res.Allowed = false
			res.BlockingReasons = append(res.BlockingReasons,
				fmt.Sprintf("partition %d is mounted at %q (Windows system drive)", part.Index, part.Mountpoint))
		}
	}

	return res
}
