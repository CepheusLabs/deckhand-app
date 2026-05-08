package doctor

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestFlashSmokeArgsUseWriteImageSmokeOp(t *testing.T) {
	root := helperPrivateRoot()
	got := flashSmokeArgs(flashSmokeInvocation{
		EventsPath:  filepath.Join(root, "events.log"),
		ImagePath:   `C:\Users\eknof\AppData\Local\Deckhand\os-images\image.img`,
		Target:      "PhysicalDrive3",
		TokenFile:   filepath.Join(root, "token.txt"),
		CancelFile:  filepath.Join(root, "cancel.txt"),
		Manifest:    filepath.Join(root, "manifest.json"),
		SHA256:      "43f0e0e5cf1adf47dc56b740aea94852be14f057eb1ebeeceb353fee702c7b2d",
		WatchdogPID: 1234,
	})

	wantPrefix := []string{
		"write-image-smoke",
		"--events-file",
		filepath.Join(root, "events.log"),
		"--image",
		`C:\Users\eknof\AppData\Local\Deckhand\os-images\image.img`,
	}
	if len(got) < len(wantPrefix) {
		t.Fatalf("flashSmokeArgs() length = %d, want at least %d", len(got), len(wantPrefix))
	}
	for i, want := range wantPrefix {
		if got[i] != want {
			t.Fatalf("flashSmokeArgs()[%d] = %q, want %q; args=%v", i, got[i], want, got)
		}
	}

	assertArgValue(t, got, "--target", "PhysicalDrive3")
	assertArgValue(t, got, "--token-file", filepath.Join(root, "token.txt"))
	assertArgValue(t, got, "--cancel-file", filepath.Join(root, "cancel.txt"))
	assertArgValue(t, got, "--manifest", filepath.Join(root, "manifest.json"))
	assertArgValue(t, got, "--sha256", "43f0e0e5cf1adf47dc56b740aea94852be14f057eb1ebeeceb353fee702c7b2d")
	assertArgValue(t, got, "--watchdog-pid", "1234")
}

func TestRunRestoreSmokeRequiresValidSHA256(t *testing.T) {
	helper := filepath.Join(t.TempDir(), "deckhand-elevated-helper")
	if err := os.WriteFile(helper, []byte("stub"), 0o700); err != nil {
		t.Fatal(err)
	}

	var out bytes.Buffer
	_, err := RunRestoreSmoke(context.Background(), &out, RestoreSmokeOptions{
		HelperPath:     helper,
		ImagePath:      filepath.Join(t.TempDir(), "emmc.img"),
		DiskID:         "PhysicalDrive3",
		ExpectedSHA256: "not-a-sha",
	})
	if err == nil || !strings.Contains(err.Error(), "--sha256") {
		t.Fatalf("RunRestoreSmoke() err = %v, want sha256 validation error", err)
	}
}
