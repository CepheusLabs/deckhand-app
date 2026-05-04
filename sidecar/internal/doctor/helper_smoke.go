package doctor

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

// HelperSmokeOptions controls the human-facing helper launch probe.
type HelperSmokeOptions struct {
	HelperPath string
	LongArgs   bool
	Timeout    time.Duration
}

// RunHelperSmoke launches deckhand-elevated-helper with the harmless
// "version" op and verifies that the helper can write its events file.
// On Windows it uses the same PowerShell Start-Process elevation dance
// as the Flutter app; on other platforms it execs the helper directly.
func RunHelperSmoke(ctx context.Context, w io.Writer, opts HelperSmokeOptions) (bool, error) {
	if opts.Timeout <= 0 {
		opts.Timeout = 30 * time.Second
	}
	helper := opts.HelperPath
	if helper == "" {
		resolved, err := defaultElevatedHelperPath()
		if err != nil {
			return false, err
		}
		helper = resolved
	}
	if _, err := os.Stat(helper); err != nil {
		fmt.Fprintf(w, "[FAIL] helper_present — %s: %v\n", helper, err)
		return false, nil
	}

	ctx, cancel := context.WithTimeout(ctx, opts.Timeout)
	defer cancel()

	events, err := os.CreateTemp("", "deckhand-helper-smoke-*.log")
	if err != nil {
		return false, err
	}
	eventsPath := events.Name()
	_ = events.Close()
	defer func() {
		if _, err := os.Stat(eventsPath); err == nil {
			_ = os.Remove(eventsPath)
		}
		_ = os.Remove(eventsPath + ".openerr")
	}()

	args := helperSmokeArgs(eventsPath, opts.LongArgs)
	exit, stderr, runErr := runHelperSmokeCommand(ctx, helper, args)
	body, _ := os.ReadFile(eventsPath)
	openErr, _ := os.ReadFile(eventsPath + ".openerr")
	eventsText := strings.TrimSpace(string(body))
	openErrText := strings.TrimSpace(string(openErr))

	passed := runErr == nil &&
		exit == 0 &&
		strings.Contains(eventsText, `"event":"started"`) &&
		strings.Contains(eventsText, `"event":"version"`)

	if passed {
		fmt.Fprintf(w, "[PASS] helper_launch — %s\n", helper)
	} else {
		fmt.Fprintf(w, "[FAIL] helper_launch — %s\n", helper)
	}
	fmt.Fprintf(w, "events_file=%s\n", eventsPath)
	fmt.Fprintf(w, "exit=%d\n", exit)
	if runErr != nil {
		fmt.Fprintf(w, "run_error=%v\n", runErr)
	}
	if strings.TrimSpace(stderr) != "" {
		fmt.Fprintf(w, "stderr=%s\n", strings.TrimSpace(stderr))
	}
	if openErrText != "" {
		fmt.Fprintf(w, "open_error=%s\n", openErrText)
	}
	if eventsText == "" {
		fmt.Fprintln(w, "events=(empty)")
	} else {
		fmt.Fprintf(w, "events=\n%s\n", eventsText)
	}
	return passed, nil
}

func defaultElevatedHelperPath() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	return filepath.Join(filepath.Dir(exe), elevatedHelperName(runtime.GOOS)), nil
}

func helperSmokeArgs(eventsPath string, longArgs bool) []string {
	args := []string{"version", "--events-file", eventsPath}
	if !longArgs {
		return args
	}
	return append(args,
		"--target", "PhysicalDrive3",
		"--output", filepath.Join(os.TempDir(), "deckhand-helper-smoke.img"),
		"--output-root", os.TempDir(),
		"--token-file", filepath.Join(os.TempDir(), "deckhand-helper-smoke.token"),
		"--cancel-file", filepath.Join(os.TempDir(), "deckhand-helper-smoke.cancel"),
		"--total-bytes", "7818182656",
		"--watchdog-pid", fmt.Sprintf("%d", os.Getpid()),
	)
}

func runHelperSmokeCommand(ctx context.Context, helper string, args []string) (int, string, error) {
	if runtime.GOOS != "windows" {
		cmd := exec.CommandContext(ctx, helper, args...)
		out, err := cmd.CombinedOutput()
		return commandExitCode(err), string(out), err
	}

	argList := make([]string, 0, len(args))
	for _, arg := range args {
		argList = append(argList, powerShellDoubleQuoted(arg))
	}
	helperLiteral := powerShellDoubleQuoted(helper)
	ps := strings.Join([]string{
		`$ErrorActionPreference = "Stop";`,
		`try {`,
		`$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator);`,
		fmt.Sprintf(`if ($isAdmin) { $p = Start-Process -FilePath %s -ArgumentList %s -Wait -PassThru -WindowStyle Hidden; }`, helperLiteral, strings.Join(argList, ",")),
		fmt.Sprintf(`else { $p = Start-Process -FilePath %s -ArgumentList %s -Verb RunAs -Wait -PassThru; }`, helperLiteral, strings.Join(argList, ",")),
		`exit $p.ExitCode`,
		`} catch {`,
		`[Console]::Error.WriteLine($_.Exception.Message);`,
		`exit 1`,
		`}`,
	}, " ")

	cmd := exec.CommandContext(ctx, "powershell.exe", "-NoProfile", "-NonInteractive", "-Command", ps)
	out, err := cmd.CombinedOutput()
	return commandExitCode(err), string(out), err
}

func commandExitCode(err error) int {
	if err == nil {
		return 0
	}
	if exitErr, ok := err.(*exec.ExitError); ok {
		return exitErr.ExitCode()
	}
	return -1
}

func powerShellDoubleQuoted(s string) string {
	return `"` + strings.ReplaceAll(s, `"`, `""`) + `"`
}
