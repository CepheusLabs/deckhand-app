package doctor

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/CepheusLabs/deckhand/sidecar/internal/osimg"
)

func TestDefaultDownloadOSDestUsesManagedCacheAndImageID(t *testing.T) {
	got, err := defaultDownloadOSDest(
		"https://github.com/armbian/community/releases/download/26.2.0/Armbian.img.xz",
		"armbian-trixie-minimal",
	)
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Base(filepath.Dir(got)) != "os-images" {
		t.Fatalf("dest parent = %q, want os-images", filepath.Dir(got))
	}
	if filepath.Base(got) != "armbian-trixie-minimal.img" {
		t.Fatalf("dest basename = %q", filepath.Base(got))
	}
}

func TestDefaultDownloadOSDestFallsBackToURLBasename(t *testing.T) {
	got, err := defaultDownloadOSDest(
		"https://github.com/armbian/community/releases/download/26.2.0/Armbian_current.img.xz",
		"",
	)
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Base(got) != "armbian_current.img" {
		t.Fatalf("dest basename = %q", filepath.Base(got))
	}
}

func TestValidateDownloadOSDestRejectsUnmanagedPath(t *testing.T) {
	dest := filepath.Join(t.TempDir(), "image.img")
	if err := validateDownloadOSDest(dest); err == nil {
		t.Fatalf("expected unmanaged path to be rejected")
	}
}

func TestRunDownloadOSReusesVerifiedCacheWithoutNetwork(t *testing.T) {
	root := filepath.Join(os.TempDir(), downloadTempRootName)
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatal(err)
	}
	body := []byte("cached image")
	sum := sha256.Sum256(body)
	expected := hex.EncodeToString(sum[:])
	dest := filepath.Join(root, "deckhand-download-os-reuse.img")
	t.Cleanup(func() {
		_ = os.Remove(dest)
		_ = os.Remove(dest + ".part")
	})
	if err := os.WriteFile(dest, body, 0o600); err != nil {
		t.Fatal(err)
	}

	var out bytes.Buffer
	passed, err := RunDownloadOS(t.Context(), &out, DownloadOSOptions{
		URL:            "https://example.invalid/should-not-be-fetched.img",
		ExpectedSHA256: expected,
		DestPath:       dest,
	})
	if err != nil {
		t.Fatal(err)
	}
	if !passed {
		t.Fatalf("passed = false; output:\n%s", out.String())
	}
	if !strings.Contains(out.String(), "[PASS] os_image_reuse") {
		t.Fatalf("expected reuse output, got:\n%s", out.String())
	}
}

func TestRunDownloadOSReusesExtractedXZCacheFromManifest(t *testing.T) {
	root := filepath.Join(os.TempDir(), downloadTempRootName)
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatal(err)
	}
	raw := []byte("cached extracted image")
	artifact := []byte("compressed artifact bytes")
	rawSum := sha256.Sum256(raw)
	artifactSum := sha256.Sum256(artifact)
	rawSha := hex.EncodeToString(rawSum[:])
	artifactSha := hex.EncodeToString(artifactSum[:])
	dest := filepath.Join(root, "deckhand-download-os-xz-reuse.img")
	rawURL := "https://example.invalid/should-not-be-fetched.img.xz"
	t.Cleanup(func() {
		_ = os.Remove(dest)
		_ = os.Remove(dest + ".part")
		_ = os.Remove(dest + ".download.part")
		_ = os.Remove(dest + ".deckhand-download.json")
	})
	if err := os.WriteFile(dest, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := osimg.WriteCacheManifest(dest, rawURL, artifactSha, rawSha, false); err != nil {
		t.Fatal(err)
	}

	var out bytes.Buffer
	passed, err := RunDownloadOS(t.Context(), &out, DownloadOSOptions{
		URL:            rawURL,
		ExpectedSHA256: artifactSha,
		DestPath:       dest,
	})
	if err != nil {
		t.Fatal(err)
	}
	if !passed {
		t.Fatalf("passed = false; output:\n%s", out.String())
	}
	if !strings.Contains(out.String(), "[PASS] os_image_reuse") {
		t.Fatalf("expected reuse output, got:\n%s", out.String())
	}
}

func TestRunDownloadOSRequiresSHA256(t *testing.T) {
	var out bytes.Buffer
	_, err := RunDownloadOS(t.Context(), &out, DownloadOSOptions{
		URL: "https://github.com/example/image.img",
	})
	if err == nil || !strings.Contains(err.Error(), "64-hex sha256") {
		t.Fatalf("expected sha error, got %v", err)
	}
}
