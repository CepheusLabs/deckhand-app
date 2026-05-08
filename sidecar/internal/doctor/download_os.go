package doctor

import (
	"context"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"time"

	"github.com/CepheusLabs/deckhand/sidecar/internal/host"
	"github.com/CepheusLabs/deckhand/sidecar/internal/osimg"
)

const downloadTempRootName = "deckhand-os-images"

var downloadOSIDUnsafe = regexp.MustCompile(`[^a-zA-Z0-9._-]+`)

// DownloadOSOptions controls the human-facing OS image cache/download probe.
type DownloadOSOptions struct {
	URL            string
	ExpectedSHA256 string
	DestPath       string
	ImageID        string
	Timeout        time.Duration
}

// RunDownloadOS downloads or reuses a verified OS image in Deckhand's
// managed image cache. ExpectedSHA256 is the profile-declared artifact
// hash; compressed downloads are cached with a manifest that binds that
// artifact hash to the extracted raw image hash.
func RunDownloadOS(ctx context.Context, w io.Writer, opts DownloadOSOptions) (bool, error) {
	expected := strings.ToLower(strings.TrimSpace(opts.ExpectedSHA256))
	if !isLowerSHA256(expected) {
		return false, fmt.Errorf("--sha256 must be a 64-hex sha256")
	}
	rawURL := strings.TrimSpace(opts.URL)
	if rawURL == "" {
		return false, fmt.Errorf("--url is required")
	}
	if opts.Timeout <= 0 {
		opts.Timeout = 60 * time.Minute
	}

	dest := strings.TrimSpace(opts.DestPath)
	var err error
	if dest == "" {
		dest, err = defaultDownloadOSDest(rawURL, opts.ImageID)
		if err != nil {
			return false, err
		}
	}
	dest = filepath.Clean(dest)
	if err := ensureDownloadOSRoot(filepath.Dir(dest)); err != nil {
		return false, err
	}
	if err := validateDownloadOSDest(dest); err != nil {
		return false, err
	}

	reused, actual, err := reuseDownloadOSDest(dest, expected, rawURL)
	if err != nil {
		return false, err
	}
	if reused {
		if err := osimg.WriteCacheManifest(dest, rawURL, expected, actual, true); err != nil {
			return false, err
		}
		fmt.Fprintf(w, "[PASS] os_image_reuse - %s\n", dest)
		fmt.Fprintf(w, "sha256=%s\n", actual)
		return true, nil
	}
	if err := removeDownloadOSPart(dest); err != nil {
		return false, err
	}

	ctx, cancel := context.WithTimeout(ctx, opts.Timeout)
	defer cancel()
	note := &downloadOSNotifier{w: w, startedAt: time.Now()}
	fmt.Fprintf(w, "[INFO] os_image_download - %s -> %s\n", rawURL, dest)
	sha, err := osimg.Download(ctx, rawURL, dest, expected, note)
	if err != nil {
		fmt.Fprintf(w, "[FAIL] os_image_download - %v\n", err)
		return false, nil
	}
	if err := osimg.WriteCacheManifest(dest, rawURL, expected, sha, false); err != nil {
		return false, err
	}
	fmt.Fprintf(w, "[PASS] os_image_download - %s\n", dest)
	fmt.Fprintf(w, "sha256=%s\n", sha)
	return true, nil
}

type downloadOSNotifier struct {
	w         io.Writer
	startedAt time.Time
	lastDone  int64
}

func (n *downloadOSNotifier) Notify(_ string, params any) {
	progress, ok := params.(osimg.DownloadProgress)
	if !ok {
		return
	}
	if progress.Phase == "done" {
		fmt.Fprintln(n.w, "[INFO] progress - download complete")
		return
	}
	if progress.BytesDone <= 0 {
		return
	}
	if progress.BytesDone-n.lastDone < 64*1024*1024 && n.lastDone > 0 {
		return
	}
	n.lastDone = progress.BytesDone
	fmt.Fprintln(n.w, formatBackupProgressLine(backupSmokeProgress{
		Phase:      "downloading",
		BytesDone:  progress.BytesDone,
		BytesTotal: progress.BytesTotal,
	}, n.startedAt, time.Now()))
}

func defaultDownloadOSDest(rawURL, imageID string) (string, error) {
	root := filepath.Join(host.Current().Cache, "Deckhand", "os-images")
	id := safeDownloadOSID(imageID)
	if id == "" {
		parsed, err := url.Parse(rawURL)
		if err != nil {
			return "", fmt.Errorf("parse url: %w", err)
		}
		id = safeDownloadOSID(filepath.Base(parsed.Path))
	}
	if id == "" {
		id = "image"
	}
	return filepath.Join(root, id+".img"), nil
}

func safeDownloadOSID(raw string) string {
	id := strings.TrimSpace(raw)
	for {
		lower := strings.ToLower(id)
		trimmed := false
		for _, suffix := range []string{".xz", ".gz", ".zst", ".zip", ".img"} {
			if strings.HasSuffix(lower, suffix) {
				id = id[:len(id)-len(suffix)]
				trimmed = true
				break
			}
		}
		if !trimmed {
			break
		}
	}
	id = strings.ToLower(downloadOSIDUnsafe.ReplaceAllString(id, "-"))
	id = strings.Trim(id, ".-_")
	if len(id) > 120 {
		id = id[:120]
		id = strings.Trim(id, ".-_")
	}
	return id
}

func ensureDownloadOSRoot(root string) error {
	cleanRoot, err := filepath.Abs(filepath.Clean(root))
	if err != nil {
		return fmt.Errorf("resolve download root: %w", err)
	}
	if !isManagedDownloadOSRoot(cleanRoot) {
		return fmt.Errorf("download root %q is not Deckhand-managed", root)
	}
	if info, err := os.Lstat(cleanRoot); err == nil {
		if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
			return fmt.Errorf("download root %q must be a real directory", root)
		}
	} else if os.IsNotExist(err) {
		if err := os.MkdirAll(cleanRoot, 0o700); err != nil {
			return fmt.Errorf("create download root: %w", err)
		}
	} else {
		return fmt.Errorf("inspect download root: %w", err)
	}
	if runtime.GOOS != "windows" {
		if err := os.Chmod(cleanRoot, 0o700); err != nil {
			return fmt.Errorf("chmod download root: %w", err)
		}
	}
	return nil
}

func validateDownloadOSDest(dest string) error {
	if err := rejectDevicePath(dest); err != nil {
		return err
	}
	clean, err := filepath.Abs(filepath.Clean(dest))
	if err != nil {
		return fmt.Errorf("resolve dest: %w", err)
	}
	if filepath.Ext(clean) != ".img" {
		return fmt.Errorf("dest %q must end in .img", dest)
	}
	if !isManagedDownloadOSRoot(filepath.Dir(clean)) {
		return fmt.Errorf("dest %q is not under a Deckhand-managed OS image directory", dest)
	}
	parent := filepath.Dir(clean)
	info, err := os.Lstat(parent)
	if err != nil {
		return fmt.Errorf("download root %q is not available: %w", parent, err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return fmt.Errorf("download root %q must be a real directory", parent)
	}
	return nil
}

func reuseDownloadOSDest(dest, expected, rawURL string) (bool, string, error) {
	reused, actual, err := osimg.TryReuseCachedImage(dest, rawURL, expected)
	if err != nil || reused {
		return reused, actual, err
	}
	if err := os.Remove(dest); err != nil {
		if os.IsNotExist(err) {
			return false, "", nil
		}
		return false, "", fmt.Errorf("remove stale cached image: %w", err)
	}
	if err := osimg.RemoveCacheManifest(dest); err != nil {
		return false, "", err
	}
	return false, actual, nil
}

func removeDownloadOSPart(dest string) error {
	part := dest + ".part"
	info, err := os.Lstat(part)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("inspect partial download: %w", err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return fmt.Errorf("partial download %q must be a regular file", part)
	}
	if err := os.Remove(part); err != nil {
		return fmt.Errorf("remove partial download: %w", err)
	}
	return nil
}

func managedDownloadOSRoots() []string {
	h := host.Current()
	roots := make([]string, 0, 3)
	for _, root := range []string{h.Cache, h.Data} {
		if root == "" {
			continue
		}
		if abs, err := filepath.Abs(filepath.Join(root, "Deckhand", "os-images")); err == nil {
			roots = append(roots, filepath.Clean(abs))
		}
	}
	if tmp := os.TempDir(); tmp != "" {
		if abs, err := filepath.Abs(filepath.Join(tmp, downloadTempRootName)); err == nil {
			roots = append(roots, filepath.Clean(abs))
		}
	}
	return roots
}

func isManagedDownloadOSRoot(root string) bool {
	clean, err := filepath.Abs(filepath.Clean(root))
	if err != nil {
		return false
	}
	for _, managed := range managedDownloadOSRoots() {
		if clean == managed {
			return true
		}
	}
	return false
}

func rejectDevicePath(path string) error {
	clean := filepath.Clean(path)
	upper := strings.ToUpper(clean)
	if strings.HasPrefix(upper, `\\.\`) || strings.HasPrefix(upper, `//./`) {
		return fmt.Errorf("path %q must be a regular file path, not a device", path)
	}
	return nil
}

func isLowerSHA256(s string) bool {
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
