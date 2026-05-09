package doctor

import (
	"os"
	"path/filepath"
	"strings"
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

func TestWindowsHelperSmokePowerShellUsesDirectLaunchWhenAlreadyAdmin(t *testing.T) {
	ps := windowsHelperSmokePowerShell(
		`C:\Deckhand Builds\deckhand-elevated-helper.exe`,
		[]string{"version", "--events-file", `C:\Temp $With Spaces\events.log`},
	)

	if !strings.Contains(ps, `[System.Diagnostics.ProcessStartInfo]::new`) {
		t.Fatalf("expected direct ProcessStartInfo launch in script:\n%s", ps)
	}
	for _, want := range []string{
		`$argv = @('version','--events-file','C:\Temp $With Spaces\events.log');`,
		`$psi.UseShellExecute = $false;`,
		`$psi.CreateNoWindow = $true;`,
		`$psi.Arguments = $directArgs;`,
		`Start-Process -FilePath $helperPath -ArgumentList $argv -Verb RunAs -Wait -PassThru;`,
	} {
		if !strings.Contains(ps, want) {
			t.Fatalf("expected %q in script:\n%s", want, ps)
		}
	}

	adminBlock := between(t, ps, `if ($isAdmin) {`, `} else {`)
	if strings.Contains(adminBlock, "Start-Process") {
		t.Fatalf("admin launch path should not use Start-Process:\n%s", adminBlock)
	}
}

func TestWindowsCommandLineQuoted(t *testing.T) {
	tests := map[string]string{
		"":                        `""`,
		"version":                 "version",
		`PhysicalDrive3`:          `PhysicalDrive3`,
		`C:\Temp With Spaces\img`: `"C:\Temp With Spaces\img"`,
		`C:\path with spaces\`:    `"C:\path with spaces\\"`,
		`has"quote`:               `"has\"quote"`,
		`backslash\"quote`:        `"backslash\\\"quote"`,
	}
	for input, want := range tests {
		if got := windowsCommandLineQuoted(input); got != want {
			t.Fatalf("windowsCommandLineQuoted(%q) = %q, want %q", input, got, want)
		}
	}
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

func between(t *testing.T, s, start, end string) string {
	t.Helper()
	startAt := strings.Index(s, start)
	if startAt < 0 {
		t.Fatalf("missing start marker %q in:\n%s", start, s)
	}
	startAt += len(start)
	endAt := strings.Index(s[startAt:], end)
	if endAt < 0 {
		t.Fatalf("missing end marker %q in:\n%s", end, s)
	}
	return s[startAt : startAt+endAt]
}
