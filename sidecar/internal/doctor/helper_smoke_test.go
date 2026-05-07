package doctor

import (
	"os"
	"path/filepath"
	"testing"
)

func TestCreateHelperPrivateTempPathUsesHelperRoot(t *testing.T) {
	path, err := createHelperPrivateTempPath("deckhand-test-*.token", "token\n")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Remove(path) })

	root, err := filepath.Abs(helperPrivateRoot())
	if err != nil {
		t.Fatal(err)
	}
	gotDir, err := filepath.Abs(filepath.Dir(path))
	if err != nil {
		t.Fatal(err)
	}
	if gotDir != root {
		t.Fatalf("temp path dir = %q, want helper private root %q", gotDir, root)
	}
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(body) != "token\n" {
		t.Fatalf("body = %q", body)
	}
}

func TestHelperSmokeLongArgsUseHelperPrivateFiles(t *testing.T) {
	eventsPath := filepath.Join(helperPrivateRoot(), "events.log")
	got := helperSmokeArgs(eventsPath, true)

	assertArgValue(t, got, "--events-file", eventsPath)
	assertDirectHelperChildArg(t, got, "--token-file")
	assertDirectHelperChildArg(t, got, "--cancel-file")
}

func assertDirectHelperChildArg(t *testing.T, args []string, name string) {
	t.Helper()
	var got string
	for i := 0; i < len(args)-1; i++ {
		if args[i] == name {
			got = args[i+1]
			break
		}
	}
	if got == "" {
		t.Fatalf("%s missing from args %v", name, args)
	}
	root, err := filepath.Abs(helperPrivateRoot())
	if err != nil {
		t.Fatal(err)
	}
	gotDir, err := filepath.Abs(filepath.Dir(got))
	if err != nil {
		t.Fatal(err)
	}
	if gotDir != root {
		t.Fatalf("%s dir = %q, want %q; args=%v", name, gotDir, root, args)
	}
}
