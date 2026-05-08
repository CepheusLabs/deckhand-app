package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestValidateBackupOutputPathAllowsNewDirectImageChild(t *testing.T) {
	root := makeBackupRoot(t)
	output := filepath.Join(root, "printer-emmc.img")

	if err := validateBackupOutputPath(root, output); err != nil {
		t.Fatalf("validateBackupOutputPath() error = %v", err)
	}
}

func TestValidateBackupOutputPathRequiresMarker(t *testing.T) {
	tmp := t.TempDir()
	root := filepath.Join(tmp, "emmc-backups")
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatal(err)
	}

	err := validateBackupOutputPath(root, filepath.Join(root, "backup.img"))
	if err == nil || !strings.Contains(err.Error(), "marker missing") {
		t.Fatalf("expected missing-marker error, got %v", err)
	}
}

func TestValidateBackupOutputPathRejectsExistingFile(t *testing.T) {
	root := makeBackupRoot(t)
	output := filepath.Join(root, "backup.img")
	if err := os.WriteFile(output, []byte("existing"), 0o600); err != nil {
		t.Fatal(err)
	}

	err := validateBackupOutputPath(root, output)
	if err == nil || !strings.Contains(err.Error(), "already exists") {
		t.Fatalf("expected existing-file error, got %v", err)
	}
}

func TestValidateBackupOutputPathRejectsSymlink(t *testing.T) {
	root := makeBackupRoot(t)
	target := filepath.Join(root, "target.img")
	link := filepath.Join(root, "backup.img")
	if err := os.Symlink(target, link); err != nil {
		t.Skipf("symlink not supported in this test environment: %v", err)
	}

	err := validateBackupOutputPath(root, link)
	if err == nil || !strings.Contains(err.Error(), "symlink") {
		t.Fatalf("expected symlink error, got %v", err)
	}
}

func TestValidateBackupOutputPathRejectsSymlinkRoot(t *testing.T) {
	tmp := t.TempDir()
	realRoot := filepath.Join(tmp, "real-emmc-backups")
	if err := os.MkdirAll(realRoot, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(
		filepath.Join(realRoot, backupRootMarker),
		[]byte("deckhand-emmc-backups/1\n"),
		0o600,
	); err != nil {
		t.Fatal(err)
	}
	rootLink := filepath.Join(tmp, "emmc-backups")
	if err := os.Symlink(realRoot, rootLink); err != nil {
		t.Skipf("symlink not supported in this test environment: %v", err)
	}

	err := validateBackupOutputPath(rootLink, filepath.Join(rootLink, "backup.img"))
	if err == nil || !strings.Contains(err.Error(), "symlink") {
		t.Fatalf("expected root-symlink error, got %v", err)
	}
}

func TestValidateBackupOutputPathAllowsNestedImageChild(t *testing.T) {
	root := makeBackupRoot(t)
	nested := filepath.Join(root, "phrozen-arco", "2026-05-07T18-19-20Z")
	if err := os.MkdirAll(nested, 0o700); err != nil {
		t.Fatal(err)
	}

	if err := validateBackupOutputPath(root, filepath.Join(nested, "emmc.img")); err != nil {
		t.Fatalf("validateBackupOutputPath() error = %v", err)
	}
}

func TestValidateBackupOutputPathRejectsSiblingTraversal(t *testing.T) {
	root := makeBackupRoot(t)
	outside := filepath.Join(filepath.Dir(root), "outside.img")

	err := validateBackupOutputPath(root, outside)
	if err == nil || !strings.Contains(err.Error(), "under") {
		t.Fatalf("expected under-root error, got %v", err)
	}
}

func TestValidateBackupOutputPathRejectsSymlinkAncestor(t *testing.T) {
	root := makeBackupRoot(t)
	realDir := filepath.Join(root, "real")
	if err := os.MkdirAll(realDir, 0o700); err != nil {
		t.Fatal(err)
	}
	linkDir := filepath.Join(root, "linked")
	if err := os.Symlink(realDir, linkDir); err != nil {
		t.Skipf("symlink not supported in this test environment: %v", err)
	}

	err := validateBackupOutputPath(root, filepath.Join(linkDir, "backup.img"))
	if err == nil || !strings.Contains(err.Error(), "symlink") {
		t.Fatalf("expected symlink-ancestor error, got %v", err)
	}
}

func TestValidateBackupOutputPathRejectsBadExtension(t *testing.T) {
	root := makeBackupRoot(t)

	err := validateBackupOutputPath(root, filepath.Join(root, "backup.raw"))
	if err == nil || !strings.Contains(err.Error(), ".img") {
		t.Fatalf("expected extension error, got %v", err)
	}
}

func TestValidateBackupOutputPathRejectsWrongRootName(t *testing.T) {
	tmp := t.TempDir()
	root := filepath.Join(tmp, "not-deckhand")
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(
		filepath.Join(root, backupRootMarker),
		[]byte("deckhand-emmc-backups/1\n"),
		0o600,
	); err != nil {
		t.Fatal(err)
	}

	err := validateBackupOutputPath(root, filepath.Join(root, "backup.img"))
	if err == nil || !strings.Contains(err.Error(), "emmc-backups") {
		t.Fatalf("expected root-name error, got %v", err)
	}
}

func TestOperationCanceledRequiresLiveRegularFile(t *testing.T) {
	if operationCanceled("") {
		t.Fatal("empty cancel file should not cancel")
	}

	cancelFile := filepath.Join(t.TempDir(), "cancel")
	if err := os.WriteFile(cancelFile, []byte("active"), 0o600); err != nil {
		t.Fatal(err)
	}
	if operationCanceled(cancelFile) {
		t.Fatal("existing regular cancel file should keep operation active")
	}
	if err := os.Remove(cancelFile); err != nil {
		t.Fatal(err)
	}
	if !operationCanceled(cancelFile) {
		t.Fatal("missing cancel file should cancel")
	}
}

func TestHelperPrivatePathPolicyAllowsDirectChild(t *testing.T) {
	root := helperPrivateRoot()
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "deckhand-test-token-"+strings.ReplaceAll(t.Name(), "/", "-")+".txt")
	t.Cleanup(func() { _ = os.Remove(path) })
	if err := os.WriteFile(path, []byte("tok-1234567890abcd"), 0o600); err != nil {
		t.Fatal(err)
	}

	if err := validateHelperPrivateFilePath(path, "token file"); err != nil {
		t.Fatalf("expected private direct child to pass: %v", err)
	}
}

func TestHelperPrivatePathPolicyRejectsUnmanagedAndNestedPaths(t *testing.T) {
	tmp := t.TempDir()
	cases := []string{
		filepath.Join(tmp, "token.txt"),
		filepath.Join(tmp, helperTempRootName, "nested", "token.txt"),
	}
	for _, path := range cases {
		t.Run(path, func(t *testing.T) {
			if err := validateHelperPrivateFilePath(path, "token file"); err == nil {
				t.Fatalf("expected %q to be rejected", path)
			}
		})
	}
}

func TestValidateWriteManifestRequiresFreshMatchingManifest(t *testing.T) {
	root := makeHelperTempRoot(t)
	image := filepath.Join(root, "image.img")
	payload := []byte("deckhand image")
	if err := os.WriteFile(image, payload, 0o600); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(payload)
	sha := hex.EncodeToString(sum[:])
	manifest := filepath.Join(root, "write-manifest.json")
	writeManifestFile(t, manifest, writeManifest{
		Version:     1,
		Op:          "write-image",
		ImagePath:   image,
		ImageSHA256: sha,
		Target:      "/dev/sdz",
		TokenSHA256: tokenDigest("tok-1234567890abcd"),
		ExpiresAt:   time.Now().Add(time.Minute).UTC(),
	})

	if err := validateWriteManifest(manifest, image, "/dev/sdz", sha, "tok-1234567890abcd"); err != nil {
		t.Fatalf("validateWriteManifest() error = %v", err)
	}
	if err := validateWriteManifest(manifest, image, "/dev/sdy", sha, "tok-1234567890abcd"); err == nil {
		t.Fatalf("expected target mismatch to be rejected")
	}
}

func TestValidateImagePathRequiresManagedImageAndSha(t *testing.T) {
	root := filepath.Join(os.TempDir(), downloadTempRootName)
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatal(err)
	}
	image := filepath.Join(root, "deckhand-helper-test-"+strings.ReplaceAll(t.Name(), "/", "-")+".img")
	t.Cleanup(func() { _ = os.Remove(image) })
	payload := []byte("image-bytes")
	if err := os.WriteFile(image, payload, 0o600); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(payload)
	sha := hex.EncodeToString(sum[:])

	if err := validateManagedImagePath(image, sha); err != nil {
		t.Fatalf("expected managed image to pass: %v", err)
	}
	if err := validateManagedImagePath(image, ""); err == nil {
		t.Fatalf("expected missing sha to be rejected")
	}
	if err := validateManagedImagePath(filepath.Join(t.TempDir(), "image.img"), sha); err == nil {
		t.Fatalf("expected unmanaged image path to be rejected")
	}
}

func TestValidateManagedImagePathAllowsMarkedBackupImage(t *testing.T) {
	root := makeBackupRoot(t)
	nested := filepath.Join(root, "phrozen-arco", "2026-05-07T18-19-20Z")
	if err := os.MkdirAll(nested, 0o700); err != nil {
		t.Fatal(err)
	}
	image := filepath.Join(nested, "emmc.img")
	payload := []byte("restorable backup image")
	if err := os.WriteFile(image, payload, 0o600); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(payload)
	sha := hex.EncodeToString(sum[:])

	if err := validateManagedImagePath(image, sha); err != nil {
		t.Fatalf("expected marked backup image to pass: %v", err)
	}
}

func TestValidateManagedImagePathRejectsBackupSymlinkAncestor(t *testing.T) {
	root := makeBackupRoot(t)
	realDir := filepath.Join(root, "real")
	if err := os.MkdirAll(realDir, 0o700); err != nil {
		t.Fatal(err)
	}
	linkDir := filepath.Join(root, "linked")
	if err := os.Symlink(realDir, linkDir); err != nil {
		t.Skipf("symlink not supported in this test environment: %v", err)
	}
	image := filepath.Join(linkDir, "emmc.img")
	payload := []byte("restorable backup image")
	if err := os.WriteFile(filepath.Join(realDir, "emmc.img"), payload, 0o600); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(payload)
	sha := hex.EncodeToString(sum[:])

	err := validateManagedImagePath(image, sha)
	if err == nil || !strings.Contains(err.Error(), "symlink") {
		t.Fatalf("expected symlink ancestor to be rejected, got %v", err)
	}
}

func TestValidateWriteImageRequestSmokeSkipsRawDeviceAccess(t *testing.T) {
	root := makeHelperTempRoot(t)
	imageRoot := filepath.Join(os.TempDir(), downloadTempRootName)
	if err := os.MkdirAll(imageRoot, 0o700); err != nil {
		t.Fatal(err)
	}
	image := filepath.Join(imageRoot, "deckhand-helper-smoke-"+strings.ReplaceAll(t.Name(), "/", "-")+".img")
	t.Cleanup(func() { _ = os.Remove(image) })
	payload := []byte("smoke image")
	if err := os.WriteFile(image, payload, 0o600); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(payload)
	sha := hex.EncodeToString(sum[:])
	tokenFile := filepath.Join(root, "token.txt")
	token := "tok-1234567890abcd"
	if err := os.WriteFile(tokenFile, []byte(token+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	manifest := filepath.Join(root, "write-manifest.json")
	writeManifestFile(t, manifest, writeManifest{
		Version:     1,
		Op:          "write-image",
		ImagePath:   image,
		ImageSHA256: sha,
		Target:      "PhysicalDrive3",
		TokenSHA256: tokenDigest(token),
		ExpiresAt:   time.Now().Add(time.Minute).UTC(),
	})

	request, err := validateWriteImageRequest(writeImageRequestOptions{
		OpName:        "write-image-smoke",
		Args:          []string{"--image", image, "--target", "PhysicalDrive3", "--token-file", tokenFile, "--manifest", manifest, "--sha256", sha},
		RequireAccess: false,
	})
	if err != nil {
		t.Fatalf("validateWriteImageRequest() error = %v", err)
	}
	if request.Image != image || request.Target != "PhysicalDrive3" || request.ExpectedSHA != sha {
		t.Fatalf("request = %+v", request)
	}
	if _, err := os.Stat(tokenFile); !os.IsNotExist(err) {
		t.Fatalf("token file should be consumed, stat err = %v", err)
	}
}

func TestHashReaderHashesEveryByte(t *testing.T) {
	payload := "deckhand live disk hash"
	wantBytes := int64(len(payload))
	sum := sha256.Sum256([]byte(payload))
	wantSha := hex.EncodeToString(sum[:])

	gotSha, gotBytes, err := hashReader(strings.NewReader(payload), wantBytes, "")
	if err != nil {
		t.Fatalf("hashReader() error = %v", err)
	}
	if gotSha != wantSha {
		t.Fatalf("hashReader() sha = %s, want %s", gotSha, wantSha)
	}
	if gotBytes != wantBytes {
		t.Fatalf("hashReader() bytes = %d, want %d", gotBytes, wantBytes)
	}
}

func TestTerminalDeviceReadErrorAcceptsEOFOnly(t *testing.T) {
	if !isTerminalDeviceReadError(io.EOF, 1024, 1024) {
		t.Fatal("io.EOF should be terminal")
	}
	if isTerminalDeviceReadError(io.EOF, 512, 1024) {
		t.Fatal("early EOF should not be treated as a complete raw-device read")
	}
	if !isTerminalDeviceReadError(io.EOF, 1024, 0) {
		t.Fatal("io.EOF should be terminal when no expected size is known")
	}
	if isTerminalDeviceReadError(io.ErrUnexpectedEOF, 1024, 1024) {
		t.Fatal("unexpected EOF should not be treated as a complete raw-device read")
	}
	if isTerminalDeviceReadError(errors.New("read failed"), 1024, 1024) {
		t.Fatal("generic read error should not be terminal")
	}
}

func makeHelperTempRoot(t *testing.T) string {
	t.Helper()
	root := helperPrivateRoot()
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = os.Remove(filepath.Join(root, "image.img"))
		_ = os.Remove(filepath.Join(root, "write-manifest.json"))
	})
	return root
}

func writeManifestFile(t *testing.T, path string, manifest writeManifest) {
	t.Helper()
	b, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, b, 0o600); err != nil {
		t.Fatal(err)
	}
}

func makeBackupRoot(t *testing.T) string {
	t.Helper()
	root := filepath.Join(t.TempDir(), "emmc-backups")
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(
		filepath.Join(root, backupRootMarker),
		[]byte("deckhand-emmc-backups/1\n"),
		0o600,
	); err != nil {
		t.Fatal(err)
	}
	return root
}
