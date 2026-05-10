package osimg

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestTryReuseCachedImageUsesManifestForExtractedXZImage(t *testing.T) {
	raw := []byte("raw extracted image")
	artifact := []byte("compressed artifact bytes")
	rawSum := sha256.Sum256(raw)
	artifactSum := sha256.Sum256(artifact)
	rawSha := hex.EncodeToString(rawSum[:])
	artifactSha := hex.EncodeToString(artifactSum[:])
	dest := filepath.Join(t.TempDir(), "image.img")
	rawURL := "https://github.com/example/releases/download/v1/image.img.xz"

	if err := os.WriteFile(dest, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := WriteCacheManifest(dest, rawURL, artifactSha, rawSha, false); err != nil {
		t.Fatal(err)
	}

	reused, actual, err := TryReuseCachedImage(dest, rawURL, artifactSha)
	if err != nil {
		t.Fatal(err)
	}
	if !reused {
		t.Fatalf("expected manifest-backed xz image to be reused")
	}
	if actual != rawSha {
		t.Fatalf("actual sha = %s, want %s", actual, rawSha)
	}
}

func TestTryReuseCachedImageRejectsManifestWhenImageHashDiffers(t *testing.T) {
	raw := []byte("raw extracted image")
	artifact := []byte("compressed artifact bytes")
	rawSum := sha256.Sum256(raw)
	artifactSum := sha256.Sum256(artifact)
	rawSha := hex.EncodeToString(rawSum[:])
	artifactSha := hex.EncodeToString(artifactSum[:])
	dest := filepath.Join(t.TempDir(), "image.img")
	rawURL := "https://github.com/example/releases/download/v1/image.img.xz"

	if err := os.WriteFile(dest, []byte("different image"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := WriteCacheManifest(dest, rawURL, artifactSha, rawSha, false); err != nil {
		t.Fatal(err)
	}

	reused, _, err := TryReuseCachedImage(dest, rawURL, artifactSha)
	if err != nil {
		t.Fatal(err)
	}
	if reused {
		t.Fatalf("expected stale manifest not to be reused")
	}
}

func TestWriteCacheManifestPreservesDownloadedAtOnReuse(t *testing.T) {
	dest := filepath.Join(t.TempDir(), "image.img")
	rawURL := "https://github.com/example/releases/download/v1/image.img.xz"
	expected := strings.Repeat("a", 64)
	actual := strings.Repeat("b", 64)

	if err := WriteCacheManifest(dest, rawURL, expected, actual, false); err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(CacheManifestPath(dest))
	if err != nil {
		t.Fatal(err)
	}
	var first map[string]any
	if err := json.Unmarshal(before, &first); err != nil {
		t.Fatal(err)
	}
	downloadedAt, ok := first["downloaded_at"].(string)
	if !ok || downloadedAt == "" {
		t.Fatalf("missing original downloaded_at in %+v", first)
	}

	if err := WriteCacheManifest(dest, rawURL, expected, actual, true); err != nil {
		t.Fatal(err)
	}
	after, err := os.ReadFile(CacheManifestPath(dest))
	if err != nil {
		t.Fatal(err)
	}
	var second map[string]any
	if err := json.Unmarshal(after, &second); err != nil {
		t.Fatal(err)
	}
	if got := second["downloaded_at"]; got != downloadedAt {
		t.Fatalf("downloaded_at = %v, want %s", got, downloadedAt)
	}
	if _, ok := second["reused_at"].(string); !ok {
		t.Fatalf("missing reused_at in %+v", second)
	}
}
