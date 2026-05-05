package handlers

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/CepheusLabs/deckhand/sidecar/internal/disks"
	"github.com/CepheusLabs/deckhand/sidecar/internal/rpc"
)

// stubDisks installs a disk lister returning the supplied fixtures
// for the duration of the test. Use this for any handler test that
// touches safety_check or write_image preflight - those handlers
// re-probe the live OS rather than trusting caller-supplied DiskInfo.
func stubDisks(t *testing.T, items ...disks.DiskInfo) {
	t.Helper()
	restore := SetListDisksForTest(func(_ context.Context) ([]disks.DiskInfo, error) {
		return items, nil
	})
	t.Cleanup(restore)
}

// TestRegister_RegistersEveryMethod makes sure the IPC docs generator
// (which reuses handlers.Register) will always see every public method.
// If you add a new RPC, add it here too - that's the whole point.
func TestRegister_RegistersEveryMethod(t *testing.T) {
	s := rpc.NewServer()
	_, cancel := context.WithCancel(context.Background())
	defer cancel()

	Register(s, cancel, "test-version")

	md := s.RenderMethodsMarkdown()
	expected := []string{
		"`ping`",
		"`version.compat`",
		"`host.info`",
		"`shutdown`",
		"`jobs.cancel`",
		"`disks.list`",
		"`disks.hash`",
		"`disks.read_image`",
		"`disks.safety_check`",
		"`disks.write_image`",
		"`os.download`",
		"`profiles.fetch`",
	}
	for _, want := range expected {
		if !strings.Contains(md, want) {
			t.Errorf("expected %s in rendered markdown, not found", want)
		}
	}
}

// dispatch runs the full RPC read/dispatch/respond loop for a single
// request and returns the decoded response. It's the integration
// seam we want when a handler test isn't about the domain package
// behind it (that package has its own unit tests) but about the
// handler's params validation + error mapping.
func dispatch(t *testing.T, req map[string]any) map[string]any {
	t.Helper()

	s := rpc.NewServer()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	Register(s, cancel, "test-version")

	body, err := json.Marshal(req)
	if err != nil {
		t.Fatalf("marshal request: %v", err)
	}
	in := bytes.NewReader(append(body, '\n'))
	var out bytes.Buffer

	done := make(chan error, 1)
	go func() { done <- s.Serve(ctx, in, &out) }()

	select {
	case err := <-done:
		if err != nil && err != context.Canceled && err != io.EOF {
			t.Fatalf("Serve: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatalf("Serve did not return within 5s")
	}

	sc := bufio.NewScanner(&out)
	sc.Buffer(make([]byte, 1<<16), 1<<24)
	if !sc.Scan() {
		t.Fatalf("no response on stdout")
	}
	var resp map[string]any
	if err := json.Unmarshal(sc.Bytes(), &resp); err != nil {
		t.Fatalf("decode response: %v (line=%q)", err, sc.Text())
	}
	return resp
}

// TestDisksSafetyCheck_MissingParamsRejected confirms the RPC-layer
// ParamSpec fires before the handler touches the domain layer. A
// caller that forgot `disk.id` should get a -32602 invalid-params
// error, not a cryptic domain failure.
func TestDisksSafetyCheck_MissingParamsRejected(t *testing.T) {
	resp := dispatch(t, map[string]any{
		"jsonrpc": "2.0",
		"id":      "1",
		"method":  "disks.safety_check",
		"params":  map[string]any{},
	})

	errObj, ok := resp["error"].(map[string]any)
	if !ok {
		t.Fatalf("expected error response, got %+v", resp)
	}
	if code, _ := errObj["code"].(float64); int(code) != -32000 {
		// -32000 is CodeGeneric; handler explicitly rejects empty ID
		// before the safety check runs. Adjust if policy changes.
		t.Fatalf("expected code -32000, got %v: %v", code, errObj["message"])
	}
}

// TestDisksSafetyCheck_AllowsEMMC runs the happy path: a typical
// 32 GiB removable disk with no system mounts should come back
// Allowed=true and no warnings. The handler re-probes the live OS,
// so we install a stub lister returning the eMMC fixture.
func TestDisksSafetyCheck_AllowsEMMC(t *testing.T) {
	stubDisks(t, disks.DiskInfo{
		ID:        "mmcblk0",
		Path:      "/dev/mmcblk0",
		SizeBytes: 32 * 1024 * 1024 * 1024,
		Bus:       "MMC",
		Model:     "Generic eMMC",
		Removable: true,
	})
	resp := dispatch(t, map[string]any{
		"jsonrpc": "2.0",
		"id":      "2",
		"method":  "disks.safety_check",
		"params":  map[string]any{"disk": map[string]any{"id": "mmcblk0"}},
	})
	if _, hasErr := resp["error"]; hasErr {
		t.Fatalf("expected no error, got %+v", resp["error"])
	}
	result, ok := resp["result"].(map[string]any)
	if !ok {
		t.Fatalf("expected result object, got %+v", resp)
	}
	if allowed, _ := result["allowed"].(bool); !allowed {
		t.Fatalf("expected allowed=true, got %+v", result)
	}
}

// TestDisksSafetyCheck_BlocksOversizedDisk ensures the RPC surfaces
// the blocking reasons as structured data the UI can render.
func TestDisksSafetyCheck_BlocksOversizedDisk(t *testing.T) {
	stubDisks(t, disks.DiskInfo{
		ID:        "nvme0n1",
		SizeBytes: 2 * 1024 * 1024 * 1024 * 1024, // 2 TiB
		Removable: false,
	})
	resp := dispatch(t, map[string]any{
		"jsonrpc": "2.0",
		"id":      "3",
		"method":  "disks.safety_check",
		"params":  map[string]any{"disk": map[string]any{"id": "nvme0n1"}},
	})
	result, ok := resp["result"].(map[string]any)
	if !ok {
		t.Fatalf("expected result, got %+v", resp)
	}
	if allowed, _ := result["allowed"].(bool); allowed {
		t.Fatalf("expected allowed=false on 2TiB disk, got %+v", result)
	}
	reasons, _ := result["blocking_reasons"].([]any)
	if len(reasons) == 0 {
		t.Fatalf("expected blocking_reasons, got %+v", result)
	}
}

// TestDisksSafetyCheck_UnknownDiskIDRejected confirms a caller cannot
// pass an arbitrary disk.id and have the handler quietly return an
// "allowed" verdict on a fictional device. The live re-probe must
// fail closed when the ID isn't in the enumeration.
func TestDisksSafetyCheck_UnknownDiskIDRejected(t *testing.T) {
	stubDisks(t /* no disks */)
	resp := dispatch(t, map[string]any{
		"jsonrpc": "2.0",
		"id":      "2u",
		"method":  "disks.safety_check",
		"params":  map[string]any{"disk": map[string]any{"id": "ghost0"}},
	})
	errObj, ok := resp["error"].(map[string]any)
	if !ok {
		t.Fatalf("expected error for unknown disk, got %+v", resp)
	}
	if msg, _ := errObj["message"].(string); !strings.Contains(msg, "not found") {
		t.Fatalf("expected 'not found' in error, got %q", msg)
	}
}

// TestDisksWriteImage_PreflightBlocksUnsafeTarget proves the
// defense-in-depth re-check inside the write handler: even if the
// UI somehow skipped disks.safety_check, the live-probed disk must
// drive the safety verdict.
func TestDisksWriteImage_PreflightBlocksUnsafeTarget(t *testing.T) {
	stubDisks(t, disks.DiskInfo{
		ID:        "nvme0n1",
		SizeBytes: 2 * 1024 * 1024 * 1024 * 1024,
		Removable: false,
	})
	resp := dispatch(t, map[string]any{
		"jsonrpc": "2.0",
		"id":      "4",
		"method":  "disks.write_image",
		"params": map[string]any{
			"image_path":         "/tmp/does-not-matter.img",
			"disk_id":            "nvme0n1",
			"confirmation_token": "tok-1234567890abcd",
		},
	})
	errObj, ok := resp["error"].(map[string]any)
	if !ok {
		t.Fatalf("expected error (unsafe_target), got %+v", resp)
	}
	data, _ := errObj["data"].(map[string]any)
	if reason, _ := data["reason"].(string); reason != "unsafe_target" {
		t.Fatalf("expected data.reason=unsafe_target, got %v (full: %+v)", reason, errObj)
	}
}

// TestDisksWriteImage_FabricatedDiskInfoIsIgnored proves the handler
// ignores caller-supplied DiskInfo entirely. A caller crafting a
// "safe-looking" disk struct (small, removable, no mounts) cannot
// override the live re-probe, which sees the real (unsafe) disk.
func TestDisksWriteImage_FabricatedDiskInfoIsIgnored(t *testing.T) {
	stubDisks(t, disks.DiskInfo{
		ID:        "nvme0n1",
		SizeBytes: 2 * 1024 * 1024 * 1024 * 1024, // really 2 TiB
		Removable: false,
	})
	resp := dispatch(t, map[string]any{
		"jsonrpc": "2.0",
		"id":      "4f",
		"method":  "disks.write_image",
		"params": map[string]any{
			"image_path":         "/tmp/does-not-matter.img",
			"disk_id":            "nvme0n1",
			"confirmation_token": "tok-1234567890abcd",
			"disk": map[string]any{ // hostile/fabricated:
				"id":         "nvme0n1",
				"size_bytes": 8 * 1024 * 1024 * 1024,
				"removable":  true,
			},
		},
	})
	errObj, ok := resp["error"].(map[string]any)
	if !ok {
		t.Fatalf("expected error - fabricated DiskInfo must not bypass live probe (got %+v)", resp)
	}
	data, _ := errObj["data"].(map[string]any)
	if reason, _ := data["reason"].(string); reason != "unsafe_target" {
		t.Fatalf("expected data.reason=unsafe_target, got %v", reason)
	}
}

func TestReadImageOutputPolicyRequiresMarkedBackupRoot(t *testing.T) {
	root := filepath.Join(t.TempDir(), "emmc-backups")
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatalf("mkdir root: %v", err)
	}
	output := filepath.Join(root, "printer.img")

	if err := validateReadImageOutputPath(output); err == nil {
		t.Fatalf("expected missing marker to reject output")
	}
	if err := os.WriteFile(filepath.Join(root, backupRootMarker), []byte("ok\n"), 0o600); err != nil {
		t.Fatalf("write marker: %v", err)
	}
	if err := validateReadImageOutputPath(output); err != nil {
		t.Fatalf("expected marked direct child to pass: %v", err)
	}
	if err := os.WriteFile(output, []byte("existing"), 0o600); err != nil {
		t.Fatalf("write existing output: %v", err)
	}
	if err := validateReadImageOutputPath(output); err == nil {
		t.Fatalf("expected existing output to be rejected")
	}
}

func TestReadImageOutputPolicyRejectsUnsafeOutputs(t *testing.T) {
	root := filepath.Join(t.TempDir(), "emmc-backups")
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatalf("mkdir root: %v", err)
	}
	if err := os.WriteFile(filepath.Join(root, backupRootMarker), []byte("ok\n"), 0o600); err != nil {
		t.Fatalf("write marker: %v", err)
	}

	deviceOutput := "/dev/sda"
	if runtime.GOOS == "windows" {
		deviceOutput = `\\.\PhysicalDrive3`
	}
	cases := []struct {
		name   string
		output string
		want   string
	}{
		{
			name:   "raw device path",
			output: deviceOutput,
			want:   "regular file path",
		},
		{
			name:   "wrong extension",
			output: filepath.Join(root, "printer.bin"),
			want:   "must end in .img",
		},
		{
			name:   "nested below backup root",
			output: filepath.Join(root, "nested", "printer.img"),
			want:   "emmc-backups directory",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := validateReadImageOutputPath(tc.output)
			if err == nil {
				t.Fatalf("expected %q to be rejected", tc.output)
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("expected %q in error, got %q", tc.want, err.Error())
			}
		})
	}
}

func TestDownloadDestPolicyRejectsUnmanagedAndExistingPaths(t *testing.T) {
	outside := filepath.Join(t.TempDir(), "image.img")
	if _, err := validateDownloadDestPolicy(outside); err == nil {
		t.Fatalf("expected unmanaged temp path to be rejected")
	}

	root := filepath.Join(os.TempDir(), downloadTempRootName)
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatalf("mkdir root: %v", err)
	}
	name := "deckhand-test-" + strings.ReplaceAll(t.Name(), "/", "-") + ".img"
	dest := filepath.Join(root, name)
	t.Cleanup(func() {
		_ = os.Remove(dest)
		_ = os.Remove(dest + ".part")
	})
	if err := validateDownloadDestPath(dest); err != nil {
		t.Fatalf("expected managed download path to pass: %v", err)
	}
	if err := os.WriteFile(dest, []byte("existing"), 0o600); err != nil {
		t.Fatalf("write existing dest: %v", err)
	}
	if _, err := validateDownloadDestPolicy(dest); err != nil {
		t.Fatalf("expected policy to allow existing managed cache file: %v", err)
	}
	if err := validateDownloadDestPath(dest); err == nil {
		t.Fatalf("expected existing download dest to be rejected")
	}
}

func TestOsDownloadReusesVerifiedExistingImage(t *testing.T) {
	root := filepath.Join(os.TempDir(), downloadTempRootName)
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatalf("mkdir root: %v", err)
	}
	body := []byte("already downloaded")
	sum := sha256.Sum256(body)
	expected := hex.EncodeToString(sum[:])
	dest := filepath.Join(root, "deckhand-test-reuse-"+strings.ReplaceAll(t.Name(), "/", "-")+".img")
	t.Cleanup(func() {
		_ = os.Remove(dest)
		_ = os.Remove(dest + ".part")
	})
	if err := os.WriteFile(dest, body, 0o600); err != nil {
		t.Fatalf("write cached dest: %v", err)
	}

	resp := dispatch(t, map[string]any{
		"jsonrpc": "2.0",
		"id":      "os-reuse",
		"method":  "os.download",
		"params": map[string]any{
			"url":    "https://example.invalid/should-not-be-fetched.img",
			"dest":   dest,
			"sha256": expected,
		},
	})
	if _, hasErr := resp["error"]; hasErr {
		t.Fatalf("expected cached reuse, got error %+v", resp["error"])
	}
	result, ok := resp["result"].(map[string]any)
	if !ok {
		t.Fatalf("expected result object, got %+v", resp)
	}
	if reused, _ := result["reused"].(bool); !reused {
		t.Fatalf("expected reused=true, got %+v", result)
	}
	if got, _ := result["sha256"].(string); got != expected {
		t.Fatalf("sha mismatch: got %s want %s", got, expected)
	}
}

func TestReuseOrClearDownloadDestDeletesOnlyAfterPolicy(t *testing.T) {
	root := filepath.Join(os.TempDir(), downloadTempRootName)
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatalf("mkdir root: %v", err)
	}
	dest := filepath.Join(root, "deckhand-test-stale-"+strings.ReplaceAll(t.Name(), "/", "-")+".img")
	part := dest + ".part"
	t.Cleanup(func() {
		_ = os.Remove(dest)
		_ = os.Remove(part)
	})
	if err := os.WriteFile(dest, []byte("stale"), 0o600); err != nil {
		t.Fatalf("write stale dest: %v", err)
	}
	if err := os.WriteFile(part, []byte("partial"), 0o600); err != nil {
		t.Fatalf("write partial dest: %v", err)
	}

	clean, err := validateDownloadDestPolicy(dest)
	if err != nil {
		t.Fatalf("expected managed path to pass policy: %v", err)
	}
	reused, _, err := reuseOrClearDownloadDest(clean, strings.Repeat("a", 64))
	if err != nil {
		t.Fatalf("reuseOrClearDownloadDest: %v", err)
	}
	if reused {
		t.Fatalf("expected stale file not to be reused")
	}
	if _, err := os.Lstat(dest); !os.IsNotExist(err) {
		t.Fatalf("expected stale dest removed, got %v", err)
	}
	if _, err := os.Lstat(part); !os.IsNotExist(err) {
		t.Fatalf("expected stale partial removed, got %v", err)
	}
}

func TestOsDownloadRejectsMissingShaBeforeNetwork(t *testing.T) {
	resp := dispatch(t, map[string]any{
		"jsonrpc": "2.0",
		"id":      "os-missing-sha",
		"method":  "os.download",
		"params": map[string]any{
			"url":  "https://example.invalid/image.img",
			"dest": filepath.Join(os.TempDir(), downloadTempRootName, "image.img"),
		},
	})

	if _, ok := resp["error"].(map[string]any); !ok {
		t.Fatalf("expected missing sha to fail, got %+v", resp)
	}
}

func TestProfileFetchDestPolicyRejectsUnmanagedPath(t *testing.T) {
	dest := filepath.Join(t.TempDir(), "profiles", "main")
	if err := validateProfileFetchDestPath(dest); err == nil {
		t.Fatalf("expected unmanaged profile dest to be rejected")
	}
}

func TestProfileFetchDestPolicyAllowsManagedCachePath(t *testing.T) {
	cache, err := os.UserCacheDir()
	if err != nil || cache == "" {
		t.Skipf("user cache dir unavailable: %v", err)
	}
	cases := []string{
		filepath.Join(cache, "Deckhand", "profiles", "test-ref-security-policy"),
		filepath.Join(cache, "DeckhandApp", "Deckhand", "profiles", "test-ref-security-policy"),
	}
	for _, dest := range cases {
		if err := validateProfileFetchDestPath(dest); err != nil {
			t.Fatalf("expected managed profile cache path %q to pass: %v", dest, err)
		}
	}
}

func TestProfilesFetchRejectsUnmanagedDestBeforeNetwork(t *testing.T) {
	resp := dispatch(t, map[string]any{
		"jsonrpc": "2.0",
		"id":      "profile-unmanaged-dest",
		"method":  "profiles.fetch",
		"params": map[string]any{
			"repo_url": "https://example.invalid/deckhand-profiles.git",
			"ref":      "main",
			"dest":     filepath.Join(t.TempDir(), "outside"),
			"force":    true,
		},
	})

	errObj, ok := resp["error"].(map[string]any)
	if !ok {
		t.Fatalf("expected unmanaged dest to fail, got %+v", resp)
	}
	if msg, _ := errObj["message"].(string); !strings.Contains(msg, "profile cache") {
		t.Fatalf("expected profile cache policy error, got %q", msg)
	}
}

func TestValidateRepoURLRejectsEmbeddedCredentials(t *testing.T) {
	if err := validateRepoURL("https://token@example.com/repo.git"); err == nil {
		t.Fatalf("expected repo URL credentials to be rejected")
	}
	if err := validateRepoURL("https://example.com/repo.git?token=secret"); err == nil {
		t.Fatalf("expected repo URL query string to be rejected")
	}
}
