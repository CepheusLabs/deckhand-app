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
// On Windows it mirrors the Flutter app launcher: direct process launch
// when the caller is already elevated, and Start-Process RunAs only
// when elevation still needs to be requested.
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

	eventsPath, err := createHelperPrivateTempPath("deckhand-helper-smoke-*.log", "")
	if err != nil {
		return false, err
	}
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
		"--token-file", filepath.Join(helperPrivateRoot(), "deckhand-helper-smoke.token"),
		"--cancel-file", filepath.Join(helperPrivateRoot(), "deckhand-helper-smoke.cancel"),
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

	ps := windowsHelperSmokePowerShell(helper, args)

	cmd := exec.CommandContext(ctx, "powershell.exe", "-NoProfile", "-NonInteractive", "-Command", ps)
	out, err := cmd.CombinedOutput()
	return commandExitCode(err), string(out), err
}

func windowsHelperSmokePowerShell(helper string, args []string) string {
	argList := make([]string, 0, len(args))
	directArgList := make([]string, 0, len(args))
	for _, arg := range args {
		argList = append(argList, powerShellDoubleQuoted(arg))
		directArgList = append(directArgList, windowsCommandLineQuoted(arg))
	}
	return strings.Join([]string{
		`$ErrorActionPreference = "Stop";`,
		fmt.Sprintf(`$helperPath = %s;`, powerShellSingleQuoted(helper)),
		fmt.Sprintf(`$argv = @(%s);`, strings.Join(argList, ",")),
		fmt.Sprintf(`$directArgs = %s;`, powerShellSingleQuoted(strings.Join(directArgList, " "))),
		`try {`,
		`$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator);`,
		`if ($isAdmin) {`,
		`$psi = [System.Diagnostics.ProcessStartInfo]::new();`,
		`$psi.FileName = $helperPath;`,
		`$psi.Arguments = $directArgs;`,
		`$psi.UseShellExecute = $false;`,
		`$psi.CreateNoWindow = $true;`,
		`$p = [System.Diagnostics.Process]::Start($psi);`,
		`if ($null -eq $p) { throw "helper launch returned no process" }`,
		`$p.WaitForExit();`,
		`} else {`,
		`$p = Start-Process -FilePath $helperPath -ArgumentList $argv -Verb RunAs -Wait -PassThru;`,
		`if ($null -eq $p) { throw "helper launch returned no process" }`,
		`}`,
		`exit $p.ExitCode`,
		`} catch {`,
		`[Console]::Error.WriteLine($_.Exception.Message);`,
		`exit 1`,
		`}`,
	}, " ")
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

func powerShellSingleQuoted(s string) string {
	return `'` + strings.ReplaceAll(s, `'`, `''`) + `'`
}

func windowsCommandLineQuoted(arg string) string {
	if arg == "" {
		return `""`
	}
	if !strings.ContainsAny(arg, " \t\r\n\"") {
		return arg
	}
	var b strings.Builder
	b.WriteByte('"')
	backslashes := 0
	for _, r := range arg {
		switch r {
		case '\\':
			backslashes++
		case '"':
			b.WriteString(strings.Repeat(`\`, backslashes*2+1))
			b.WriteRune(r)
			backslashes = 0
		default:
			b.WriteString(strings.Repeat(`\`, backslashes))
			b.WriteRune(r)
			backslashes = 0
		}
	}
	b.WriteString(strings.Repeat(`\`, backslashes*2))
	b.WriteByte('"')
	return b.String()
}
