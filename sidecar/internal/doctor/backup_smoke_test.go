package doctor

import (
	"os"
	"path/filepath"
	"testing"
)

func TestBackupSmokeArgsPlacesEventsFileAfterOperation(t *testing.T) {
	got := backupSmokeArgs(backupSmokeInvocation{
		EventsPath:  "events.log",
		Target:      "PhysicalDrive3",
		OutputPath:  `C:\Deckhand\emmc-backups\cli.img`,
		OutputRoot:  `C:\Deckhand\emmc-backups`,
		TokenFile:   "token.txt",
		CancelFile:  "cancel.txt",
		TotalBytes:  7818182656,
		WatchdogPID: 1234,
	})

	wantPrefix := []string{"read-image", "--events-file", "events.log", "--target", "PhysicalDrive3"}
	if len(got) < len(wantPrefix) {
		t.Fatalf("backupSmokeArgs() length = %d, want at least %d", len(got), len(wantPrefix))
	}
	for i, want := range wantPrefix {
		if got[i] != want {
			t.Fatalf("backupSmokeArgs()[%d] = %q, want %q; args=%v", i, got[i], want, got)
		}
	}

	assertArgValue(t, got, "--output", `C:\Deckhand\emmc-backups\cli.img`)
	assertArgValue(t, got, "--output-root", `C:\Deckhand\emmc-backups`)
	assertArgValue(t, got, "--token-file", "token.txt")
	assertArgValue(t, got, "--cancel-file", "cancel.txt")
	assertArgValue(t, got, "--total-bytes", "7818182656")
	assertArgValue(t, got, "--watchdog-pid", "1234")
}

func TestParseBackupSmokeEvents(t *testing.T) {
	body := []byte(
		`{"event":"started","op":"read-image"}` + "\n" +
			`{"event":"progress","phase":"reading","bytes_done":4194304,"bytes_total":8388608}` + "\n" +
			`{"event":"done","sha256":"abc123","bytes":8388608}` + "\n",
	)

	got := parseBackupSmokeEvents(body)
	if !got.Started {
		t.Fatalf("Started = false, want true")
	}
	if got.Progress == nil {
		t.Fatalf("Progress = nil, want latest progress")
	}
	if got.Progress.BytesDone != 4194304 || got.Progress.BytesTotal != 8388608 {
		t.Fatalf("Progress = %+v, want 4194304/8388608", got.Progress)
	}
	if got.Done == nil {
		t.Fatalf("Done = nil, want terminal done event")
	}
	if got.Done.SHA256 != "abc123" || got.Done.Bytes != 8388608 {
		t.Fatalf("Done = %+v, want sha abc123 and 8388608 bytes", got.Done)
	}
}

func TestRecoverCompletedBackupRequiresExactExpectedSize(t *testing.T) {
	dir := t.TempDir()
	output := filepath.Join(dir, "backup.img")
	if err := os.WriteFile(output, []byte("deckhand"), 0o600); err != nil {
		t.Fatal(err)
	}

	got, ok := recoverCompletedBackup(output, int64(len("deckhand")))
	if !ok {
		t.Fatalf("recoverCompletedBackup() ok = false, want true")
	}
	if got.Bytes != int64(len("deckhand")) {
		t.Fatalf("Bytes = %d, want %d", got.Bytes, len("deckhand"))
	}
	if got.SHA256 != "87842a2c9a74c3c2e0d534fde1a6b9990e3393ccee6103b212cd42561d81683b" {
		t.Fatalf("SHA256 = %q", got.SHA256)
	}

	if _, ok := recoverCompletedBackup(output, int64(len("deckhand")+1)); ok {
		t.Fatalf("recoverCompletedBackup() ok = true for a partial output")
	}
}

func assertArgValue(t *testing.T, args []string, name string, want string) {
	t.Helper()
	for i := 0; i < len(args)-1; i++ {
		if args[i] == name {
			if args[i+1] != want {
				t.Fatalf("%s = %q, want %q; args=%v", name, args[i+1], want, args)
			}
			return
		}
	}
	t.Fatalf("%s missing from args %v", name, args)
}
