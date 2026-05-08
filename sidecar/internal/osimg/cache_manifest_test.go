package osimg

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
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
