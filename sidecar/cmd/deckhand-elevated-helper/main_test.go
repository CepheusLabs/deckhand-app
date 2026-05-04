package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
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

func TestValidateBackupOutputPathRejectsNestedChild(t *testing.T) {
	root := makeBackupRoot(t)
	nested := filepath.Join(root, "nested")
	if err := os.MkdirAll(nested, 0o700); err != nil {
		t.Fatal(err)
	}

	err := validateBackupOutputPath(root, filepath.Join(nested, "backup.img"))
	if err == nil || !strings.Contains(err.Error(), "direct child") {
		t.Fatalf("expected direct-child error, got %v", err)
	}
}

func TestValidateBackupOutputPathRejectsSiblingTraversal(t *testing.T) {
	root := makeBackupRoot(t)
	outside := filepath.Join(filepath.Dir(root), "outside.img")

	err := validateBackupOutputPath(root, outside)
	if err == nil || !strings.Contains(err.Error(), "direct child") {
		t.Fatalf("expected direct-child error, got %v", err)
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
