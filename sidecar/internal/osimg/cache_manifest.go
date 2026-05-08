package osimg

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

const cacheManifestSchemaVersion = 1

type cacheManifest struct {
	SchemaVersion  int    `json:"schema_version"`
	URL            string `json:"url"`
	Path           string `json:"path"`
	ExpectedSHA256 string `json:"expected_sha256"`
	ActualSHA256   string `json:"actual_sha256"`
	DownloadedAt   string `json:"downloaded_at,omitempty"`
	ReusedAt       string `json:"reused_at,omitempty"`
}

// TryReuseCachedImage verifies whether dest is a reusable cached OS image.
// expectedSha is the profile-declared artifact hash. For raw images that hash
// is also the final image hash; for compressed artifacts the sidecar manifest
// binds the compressed artifact hash to the extracted image hash.
func TryReuseCachedImage(dest, rawURL, expectedSha string) (bool, string, error) {
	info, err := os.Lstat(dest)
	if os.IsNotExist(err) {
		return false, "", nil
	}
	if err != nil {
		return false, "", fmt.Errorf("inspect cached image %q: %w", dest, err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return false, "", fmt.Errorf("cached image %q must be a regular file", dest)
	}
	actual, err := sha256File(dest)
	if err != nil {
		return false, "", fmt.Errorf("hash cached image %q: %w", dest, err)
	}
	if actual == expectedSha {
		return true, actual, nil
	}
	manifest, ok, err := readCacheManifest(dest)
	if err != nil || !ok {
		return false, "", err
	}
	if manifest.SchemaVersion != cacheManifestSchemaVersion ||
		manifest.URL != rawURL ||
		!sameCleanPath(manifest.Path, dest) ||
		manifest.ExpectedSHA256 != expectedSha ||
		!isSHA256Hex(manifest.ActualSHA256) {
		return false, "", nil
	}
	if actual != manifest.ActualSHA256 {
		return false, "", nil
	}
	return true, actual, nil
}

func WriteCacheManifest(dest, rawURL, expectedSha, actualSha string, reused bool) error {
	if !isSHA256Hex(expectedSha) {
		return fmt.Errorf("expected sha256 must be 64 lowercase hex characters")
	}
	if !isSHA256Hex(actualSha) {
		return fmt.Errorf("actual sha256 must be 64 lowercase hex characters")
	}
	manifestPath := CacheManifestPath(dest)
	if info, err := os.Lstat(manifestPath); err == nil {
		if info.Mode()&os.ModeSymlink != 0 || info.IsDir() {
			return fmt.Errorf("download manifest path %q must be a regular file", manifestPath)
		}
	} else if !os.IsNotExist(err) {
		return fmt.Errorf("inspect download manifest %q: %w", manifestPath, err)
	}
	if err := os.MkdirAll(filepath.Dir(manifestPath), 0o700); err != nil {
		return fmt.Errorf("create download manifest directory: %w", err)
	}
	now := time.Now().UTC().Format(time.RFC3339Nano)
	manifest := cacheManifest{
		SchemaVersion:  cacheManifestSchemaVersion,
		URL:            rawURL,
		Path:           dest,
		ExpectedSHA256: expectedSha,
		ActualSHA256:   actualSha,
	}
	if reused {
		manifest.ReusedAt = now
	} else {
		manifest.DownloadedAt = now
	}
	body, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return fmt.Errorf("encode download manifest: %w", err)
	}
	body = append(body, '\n')
	if err := os.WriteFile(manifestPath, body, 0o600); err != nil {
		return fmt.Errorf("write download manifest: %w", err)
	}
	return nil
}

func RemoveCacheManifest(dest string) error {
	manifestPath := CacheManifestPath(dest)
	info, err := os.Lstat(manifestPath)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("inspect download manifest %q: %w", manifestPath, err)
	}
	if info.Mode()&os.ModeSymlink != 0 || info.IsDir() {
		return fmt.Errorf("download manifest path %q must be a regular file", manifestPath)
	}
	if err := os.Remove(manifestPath); err != nil {
		return fmt.Errorf("remove download manifest %q: %w", manifestPath, err)
	}
	return nil
}

func CacheManifestPath(dest string) string {
	return dest + ".deckhand-download.json"
}

func readCacheManifest(dest string) (cacheManifest, bool, error) {
	manifestPath := CacheManifestPath(dest)
	info, err := os.Lstat(manifestPath)
	if os.IsNotExist(err) {
		return cacheManifest{}, false, nil
	}
	if err != nil {
		return cacheManifest{}, false, fmt.Errorf("inspect download manifest %q: %w", manifestPath, err)
	}
	if info.Mode()&os.ModeSymlink != 0 || info.IsDir() {
		return cacheManifest{}, false, fmt.Errorf("download manifest path %q must be a regular file", manifestPath)
	}
	body, err := os.ReadFile(manifestPath)
	if err != nil {
		return cacheManifest{}, false, fmt.Errorf("read download manifest %q: %w", manifestPath, err)
	}
	var manifest cacheManifest
	if err := json.Unmarshal(body, &manifest); err != nil {
		return cacheManifest{}, false, nil
	}
	return manifest, true, nil
}

func sameCleanPath(a, b string) bool {
	aa, err := filepath.Abs(filepath.Clean(a))
	if err != nil {
		return false
	}
	bb, err := filepath.Abs(filepath.Clean(b))
	if err != nil {
		return false
	}
	if runtime.GOOS == "windows" {
		return strings.EqualFold(aa, bb)
	}
	return aa == bb
}

func isSHA256Hex(s string) bool {
	if len(s) != 64 {
		return false
	}
	for _, r := range s {
		if !((r >= '0' && r <= '9') || (r >= 'a' && r <= 'f')) {
			return false
		}
	}
	return true
}
