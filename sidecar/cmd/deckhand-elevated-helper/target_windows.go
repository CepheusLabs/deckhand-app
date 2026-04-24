//go:build windows

package main

import (
	"fmt"
	"regexp"
	"strings"
)

// physicalDrivePattern matches the form the UI hands us ("PhysicalDrive3")
// or the already-normalised `\\.\PHYSICALDRIVE3` form. Digits only after
// the prefix - rejecting anything else prevents the helper from writing
// to arbitrary device paths such as `\\.\PIPE\...` or `\\.\C:`.
var physicalDrivePattern = regexp.MustCompile(`^PhysicalDrive[0-9]+$`)

// targetToDevicePath validates a Windows disk id and returns the
// `\\.\PHYSICALDRIVE<N>` form the OS expects. The helper runs with
// admin privileges, so accepting anything outside the PhysicalDrive
// allowlist would be a privileged-arbitrary-write primitive.
func targetToDevicePath(target string) (string, error) {
	if target == "" {
		return "", fmt.Errorf("empty device target")
	}
	// Strip the `\\.\` prefix if present so the regex can validate the
	// remainder in a uniform way.
	normalised := strings.TrimPrefix(target, `\\.\`)
	// Case-insensitive match: users type `physicaldrive3`, the UI may
	// send `PhysicalDrive3`, the OS accepts `\\.\PHYSICALDRIVE3`.
	if !physicalDrivePattern.MatchString(toCanonicalCase(normalised)) {
		return "", fmt.Errorf("device target %q is not a recognised PhysicalDrive<N> id", target)
	}
	return `\\.\` + strings.ToUpper(normalised), nil
}

// toCanonicalCase upper-cases the leading prefix characters only if
// they spell "physicaldrive" case-insensitively, leaving the digits
// intact. Using strings.EqualFold here lets the regex stay strict
// while accepting the casing variants users actually type.
func toCanonicalCase(s string) string {
	const prefix = "PhysicalDrive"
	if len(s) <= len(prefix) {
		return s
	}
	if strings.EqualFold(s[:len(prefix)], prefix) {
		return prefix + s[len(prefix):]
	}
	return s
}
