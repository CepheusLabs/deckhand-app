package doctor

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/CepheusLabs/deckhand/sidecar/internal/host"
)

// fakeProbe is the test seam for RunWithProbe. Zero-value fields behave
// as "success" where applicable so individual tests only have to set
// the knobs they care about.
type fakeProbe struct {
	goos, goarch, goVersion string

	exePath string
	exeErr  error

	// statResults maps path → (info, err). A present entry (even with
	// nil info + nil err) means "we have an answer"; a missing entry
	// simulates os.ErrNotExist.
	statResults map[string]statAnswer

	// lookPathResults maps name → resolved path (or "" + error).
	lookPathResults map[string]lookPathAnswer

	powerShellPath string
	powerShellErr  error

	hostInfo host.Info

	// writable: map dir → nil for writable, an error otherwise.
	writable map[string]error

	disksCount int
	disksErr   error

	// mDNS/network probes. Zero values are healthy so existing tests
	// pass without touching them; tests targeting the new checks set
	// these explicitly.
	mdnsErr       error
	rateRemaining int
	rateTotal     int
	rateErr       error
}

type statAnswer struct {
	info os.FileInfo
	err  error
}

type lookPathAnswer struct {
	path string
	err  error
}

func (f *fakeProbe) GOOS() string      { return f.goos }
func (f *fakeProbe) GOARCH() string    { return f.goarch }
func (f *fakeProbe) GoVersion() string { return f.goVersion }
func (f *fakeProbe) Executable() (string, error) {
	return f.exePath, f.exeErr
}
func (f *fakeProbe) Stat(path string) (os.FileInfo, error) {
	if ans, ok := f.statResults[path]; ok {
		return ans.info, ans.err
	}
	return nil, os.ErrNotExist
}
func (f *fakeProbe) LookPath(name string) (string, error) {
	if ans, ok := f.lookPathResults[name]; ok {
		return ans.path, ans.err
	}
	return "", errors.New("not found")
}
func (f *fakeProbe) PowerShellExe() (string, error) {
	if f.powerShellErr != nil {
		return "", f.powerShellErr
	}
	if f.powerShellPath != "" {
		return f.powerShellPath, nil
	}
	return `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe`, nil
}
func (f *fakeProbe) HostInfo() host.Info { return f.hostInfo }
func (f *fakeProbe) ProbeWritable(dir string) error {
	if err, ok := f.writable[dir]; ok {
		return err
	}
	return errors.New("unknown dir in fake")
}
func (f *fakeProbe) ListDisksCount(ctx context.Context) (int, error) {
	return f.disksCount, f.disksErr
}
func (f *fakeProbe) MDNSPrimitivesAvailable() error { return f.mdnsErr }
func (f *fakeProbe) GitHubRateLimit(ctx context.Context) (int, int, error) {
	if f.rateErr != nil {
		return 0, 0, f.rateErr
	}
	return f.rateRemaining, f.rateTotal, nil
}

// fakeFileInfo is the minimum os.FileInfo surface doctor touches.
type fakeFileInfo struct {
	name    string
	size    int64
	dir     bool
	mode    os.FileMode
	modTime time.Time
}

func (f fakeFileInfo) Name() string       { return f.name }
func (f fakeFileInfo) Size() int64        { return f.size }
func (f fakeFileInfo) Mode() os.FileMode  { return f.mode }
func (f fakeFileInfo) ModTime() time.Time { return f.modTime }
func (f fakeFileInfo) IsDir() bool        { return f.dir }
func (f fakeFileInfo) Sys() any           { return nil }

// baseProbe builds a fakeProbe pre-seeded with a healthy Linux host.
// Individual tests clone or tweak fields on the returned value. Paths
// are built with filepath.Join so the test works on both POSIX (where
// checkElevatedHelper emits forward slashes) and Windows (where it
// emits backslashes) — the real code calls filepath.Join, so the fake
// Stat lookup must use matching separators.
func baseProbe() *fakeProbe {
	exe := filepath.Join(string(filepath.Separator)+"opt", "deckhand", "deckhand-sidecar")
	helper := filepath.Join(filepath.Dir(exe), "deckhand-elevated-helper")
	powerShell := `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe`
	return &fakeProbe{
		goos:      "linux",
		goarch:    "amd64",
		goVersion: "go1.22.0",
		exePath:   exe,
		statResults: map[string]statAnswer{
			helper:     {info: fakeFileInfo{name: "deckhand-elevated-helper"}},
			powerShell: {info: fakeFileInfo{name: "powershell.exe"}},
		},
		lookPathResults: map[string]lookPathAnswer{
			"pkexec":    {path: "/usr/bin/pkexec"},
			"osascript": {path: "/usr/bin/osascript"},
		},
		powerShellPath: powerShell,
		hostInfo: host.Info{
			OS:    "linux",
			Arch:  "amd64",
			Home:  "/home/user",
			Cache: "/home/user/.cache",
			Data:  "/home/user/.config",
		},
		writable: map[string]error{
			"/home/user/.cache":  nil,
			"/home/user/.config": nil,
		},
		disksCount: 2,
		// Healthy network defaults so legacy tests don't have to know
		// the new checks exist. mdnsErr=nil + remoteTimeFunc=nil =
		// healthy clock; tests that exercise the new failure paths
		// override these explicitly.
		rateRemaining: 60,
		rateTotal:     60,
	}
}

func TestCollect_HappyPath_Linux(t *testing.T) {
	p := baseProbe()
	got := collectWithProbe(context.Background(), "1.2.3", p)

	wantNames := []string{
		"runtime",
		"elevated_helper",
		"disks_enumerate",
		"data_dir",
		"cache_dir",
		"pkexec_on_path",
		"mdns_resolvable",
		"github_rate_limit",
	}
	if len(got) != len(wantNames) {
		t.Fatalf("want %d results, got %d: %+v", len(wantNames), len(got), got)
	}
	for i, name := range wantNames {
		if got[i].Name != name {
			t.Errorf("result[%d].Name = %q, want %q", i, got[i].Name, name)
		}
		if got[i].Status != StatusPass {
			t.Errorf("result[%d] %s status = %s, want PASS (detail: %s)", i, name, got[i].Status, got[i].Detail)
		}
	}

	// Runtime detail should include all the knobs we care about in a bug report.
	rt := got[0].Detail
	for _, needle := range []string{"linux", "amd64", "go1.22.0", "1.2.3"} {
		if !strings.Contains(rt, needle) {
			t.Errorf("runtime detail %q missing %q", rt, needle)
		}
	}
}

func TestCollect_HelperMissing_Warns(t *testing.T) {
	p := baseProbe()
	p.statResults = map[string]statAnswer{} // nothing found
	got := collectWithProbe(context.Background(), "1.0.0", p)

	helper := findResult(t, got, "elevated_helper")
	if helper.Status != StatusWarn {
		t.Fatalf("helper status = %s, want WARN; detail=%s", helper.Status, helper.Detail)
	}
}

func TestCollect_HelperIsDirectory_Fails(t *testing.T) {
	p := baseProbe()
	helperPath := filepath.Join(filepath.Dir(p.exePath), "deckhand-elevated-helper")
	p.statResults[helperPath] = statAnswer{
		info: fakeFileInfo{name: "deckhand-elevated-helper", dir: true},
	}
	got := collectWithProbe(context.Background(), "1.0.0", p)

	r := findResult(t, got, "elevated_helper")
	if r.Status != StatusFail {
		t.Fatalf("helper status = %s, want FAIL; detail=%s", r.Status, r.Detail)
	}
}

func TestCollect_WindowsUsesExeSuffixAndTrustedPowerShell(t *testing.T) {
	p := baseProbe()
	p.goos = "windows"
	p.goarch = "amd64"
	// Build paths via filepath.Join so the test is portable: on Linux
	// runners the separators will be /, on Windows \. What we're
	// actually exercising here is that (a) the `.exe` suffix is applied
	// to the helper name regardless of host and (b) the trusted
	// System32 PowerShell probe fires on GOOS=windows.
	dataDir := filepath.Join("Users", "x", "AppData", "Roaming")
	cacheDir := filepath.Join("Users", "x", "AppData", "Local")
	exe := filepath.Join("Program Files", "Deckhand", "deckhand-sidecar.exe")
	helper := filepath.Join(filepath.Dir(exe), "deckhand-elevated-helper.exe")
	powerShell := `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe`
	p.exePath = exe
	p.powerShellPath = powerShell
	p.statResults = map[string]statAnswer{
		helper:     {info: fakeFileInfo{name: "deckhand-elevated-helper.exe"}},
		powerShell: {info: fakeFileInfo{name: "powershell.exe"}},
	}
	p.lookPathResults = map[string]lookPathAnswer{}
	p.hostInfo = host.Info{OS: "windows", Data: dataDir, Cache: cacheDir}
	p.writable = map[string]error{
		dataDir:  nil,
		cacheDir: nil,
	}
	got := collectWithProbe(context.Background(), "1.0.0", p)

	helperR := findResult(t, got, "elevated_helper")
	if helperR.Status != StatusPass {
		t.Fatalf("helper status = %s, want PASS; detail=%s", helperR.Status, helperR.Detail)
	}
	tool := findResult(t, got, "powershell_system")
	if tool.Status != StatusPass {
		t.Fatalf("powershell status = %s, want PASS", tool.Status)
	}
	if tool.Detail != powerShell {
		t.Fatalf("powershell detail = %q, want trusted path %q", tool.Detail, powerShell)
	}
}

func TestCollect_DarwinProbesOsascript(t *testing.T) {
	p := baseProbe()
	p.goos = "darwin"
	got := collectWithProbe(context.Background(), "1.0.0", p)
	tool := findResult(t, got, "osascript_on_path")
	if tool.Status != StatusPass {
		t.Fatalf("osascript status = %s, want PASS", tool.Status)
	}
}

func TestCollect_DiskEnumFailure_Fails(t *testing.T) {
	p := baseProbe()
	p.disksErr = errors.New("permission denied")
	p.disksCount = 0
	got := collectWithProbe(context.Background(), "1.0.0", p)

	r := findResult(t, got, "disks_enumerate")
	if r.Status != StatusFail {
		t.Fatalf("disks_enumerate status = %s, want FAIL", r.Status)
	}
	if !strings.Contains(r.Detail, "permission denied") {
		t.Errorf("expected failure detail to include the underlying error; got %q", r.Detail)
	}
}

func TestCollect_WindowsGetDiskFailure_ExplainsRemediation(t *testing.T) {
	p := baseProbe()
	p.goos = "windows"
	p.disksErr = errors.New("Get-Disk failed: exit status 1")
	p.disksCount = 0
	got := collectWithProbe(context.Background(), "1.0.0", p)

	r := findResult(t, got, "disks_enumerate")
	if r.Status != StatusFail {
		t.Fatalf("disks_enumerate status = %s, want FAIL", r.Status)
	}
	for _, want := range []string{
		"Get-Disk failed",
		"Run Deckhand as Administrator",
		"Windows Disk Management",
		"PowerShell Get-Disk",
	} {
		if !strings.Contains(r.Detail, want) {
			t.Errorf("detail = %q, want to contain %q", r.Detail, want)
		}
	}
}

func TestCollect_ZeroDisks_Warns(t *testing.T) {
	p := baseProbe()
	p.disksCount = 0
	p.disksErr = nil
	got := collectWithProbe(context.Background(), "1.0.0", p)
	r := findResult(t, got, "disks_enumerate")
	if r.Status != StatusWarn {
		t.Fatalf("zero-disk status = %s, want WARN", r.Status)
	}
}

func TestCollect_UnwritableDataDir_Fails(t *testing.T) {
	p := baseProbe()
	p.writable["/home/user/.config"] = errors.New("read-only filesystem")
	got := collectWithProbe(context.Background(), "1.0.0", p)

	r := findResult(t, got, "data_dir")
	if r.Status != StatusFail {
		t.Fatalf("data_dir status = %s, want FAIL", r.Status)
	}
	if !strings.Contains(r.Detail, "read-only filesystem") {
		t.Errorf("detail missing underlying error; got %q", r.Detail)
	}
}

func TestCollect_EmptyDataDir_Fails(t *testing.T) {
	p := baseProbe()
	p.hostInfo.Data = ""
	got := collectWithProbe(context.Background(), "1.0.0", p)
	r := findResult(t, got, "data_dir")
	if r.Status != StatusFail {
		t.Fatalf("empty data_dir status = %s, want FAIL", r.Status)
	}
}

func TestCollect_MissingPlatformTool_Fails(t *testing.T) {
	p := baseProbe()
	p.lookPathResults["pkexec"] = lookPathAnswer{err: errors.New("not found")}
	got := collectWithProbe(context.Background(), "1.0.0", p)

	r := findResult(t, got, "pkexec_on_path")
	if r.Status != StatusFail {
		t.Fatalf("pkexec status = %s, want FAIL", r.Status)
	}
}

func TestCollect_UnknownGOOS_WarnsInsteadOfFails(t *testing.T) {
	p := baseProbe()
	p.goos = "plan9"
	got := collectWithProbe(context.Background(), "1.0.0", p)

	// Walk results to find the single platform_tool entry.
	r := findResult(t, got, "platform_tool")
	if r.Status != StatusWarn {
		t.Fatalf("unknown GOOS status = %s, want WARN", r.Status)
	}
}

func TestRunWithProbe_HappyPath_ReturnsPassed(t *testing.T) {
	var buf bytes.Buffer
	p := baseProbe()
	passed, err := RunWithProbe(context.Background(), &buf, "9.9.9", p)
	if err != nil {
		t.Fatalf("RunWithProbe error: %v", err)
	}
	if !passed {
		t.Fatalf("expected passed=true; report:\n%s", buf.String())
	}
	out := buf.String()
	if !strings.Contains(out, "[PASS] runtime") {
		t.Errorf("report missing PASS runtime line; got:\n%s", out)
	}
	if !strings.Contains(out, "all checks passed") {
		t.Errorf("expected summary 'all checks passed'; got:\n%s", out)
	}
}

func TestRunWithProbe_FailurePath_ReturnsPassedFalse(t *testing.T) {
	var buf bytes.Buffer
	p := baseProbe()
	p.disksErr = errors.New("boom")
	passed, err := RunWithProbe(context.Background(), &buf, "1.0.0", p)
	if err != nil {
		t.Fatalf("RunWithProbe error: %v", err)
	}
	if passed {
		t.Fatalf("expected passed=false; report:\n%s", buf.String())
	}
	if !strings.Contains(buf.String(), "one or more blocking issues") {
		t.Errorf("expected summary to mention blocking issues; got:\n%s", buf.String())
	}
}

func TestWriteReport_ReturnsWriteError(t *testing.T) {
	// failingWriter returns an error on every write; writeReport must
	// propagate it rather than pretending success.
	fw := &failingWriter{}
	_, err := writeReport(fw, []Result{{Name: "x", Status: StatusPass, Detail: "ok"}})
	if err == nil {
		t.Fatalf("expected writeReport to surface the writer error")
	}
}

type failingWriter struct{}

func (failingWriter) Write(p []byte) (int, error) { return 0, errors.New("disk full") }

func TestElevatedHelperName(t *testing.T) {
	cases := []struct {
		goos string
		want string
	}{
		{"linux", "deckhand-elevated-helper"},
		{"darwin", "deckhand-elevated-helper"},
		{"windows", "deckhand-elevated-helper.exe"},
		{"plan9", "deckhand-elevated-helper"},
	}
	for _, tc := range cases {
		if got := elevatedHelperName(tc.goos); got != tc.want {
			t.Errorf("elevatedHelperName(%q) = %q, want %q", tc.goos, got, tc.want)
		}
	}
}

// TestProbeWritable_Real runs the real probeWritable against a tmp dir
// so we exercise the default probe's code path end-to-end.
func TestProbeWritable_Real(t *testing.T) {
	dir := t.TempDir()
	if err := probeWritable(dir); err != nil {
		t.Fatalf("probeWritable(%q) = %v, want nil", dir, err)
	}
	// Empty path is a fast-fail.
	if err := probeWritable(""); err == nil {
		t.Errorf("probeWritable(\"\") = nil, want error")
	}
	// Nested dir that doesn't exist yet — probeWritable should create it.
	sub := filepath.Join(dir, "nested", "deeper")
	if err := probeWritable(sub); err != nil {
		t.Fatalf("probeWritable nested dir = %v", err)
	}
}

func findResult(t *testing.T, rs []Result, name string) Result {
	t.Helper()
	for _, r := range rs {
		if r.Name == name {
			return r
		}
	}
	t.Fatalf("no result named %q in %+v", name, rs)
	return Result{}
}

func TestCheckMDNS_BlockedFirewall_Warns(t *testing.T) {
	p := baseProbe()
	p.mdnsErr = errors.New("operation not permitted")
	got := collectWithProbe(context.Background(), "1.0.0", p)
	r := findResult(t, got, "mdns_resolvable")
	if r.Status != StatusWarn {
		t.Fatalf("status=%s, want WARN", r.Status)
	}
	if !strings.Contains(r.Detail, "operation not permitted") {
		t.Errorf("detail %q missing underlying error", r.Detail)
	}
}

// TestCheckMDNS_AvahiCoexistence_Passes pins the regression that the
// original probe falsely WARNed on every avahi/bonjour-running host
// because it tried to bind 5353 itself. The fix sends a multicast
// probe from an ephemeral port instead, which works alongside a
// system responder. The fake probe represents the healthy case
// (mdnsErr nil) — this test exists so a future regression that
// re-introduces the bind would have to update this test, making
// the change loud rather than silent.
func TestCheckMDNS_AvahiCoexistence_Passes(t *testing.T) {
	p := baseProbe()
	// p.mdnsErr stays nil — simulates "send to 224.0.0.251:5353
	// from an ephemeral port succeeds on a host with avahi
	// already bound to 5353."
	got := collectWithProbe(context.Background(), "1.0.0", p)
	r := findResult(t, got, "mdns_resolvable")
	if r.Status != StatusPass {
		t.Fatalf("status=%s, want PASS (regression: probe falsely "+
			"WARNs on avahi-running hosts); detail=%s", r.Status, r.Detail)
	}
}

func TestCheckGitHubRateLimit_Network_Warns(t *testing.T) {
	p := baseProbe()
	p.rateErr = errors.New("dial tcp: i/o timeout")
	got := collectWithProbe(context.Background(), "1.0.0", p)
	r := findResult(t, got, "github_rate_limit")
	if r.Status != StatusWarn {
		t.Fatalf("status=%s, want WARN", r.Status)
	}
	if !strings.Contains(r.Detail, "i/o timeout") {
		t.Errorf("detail %q missing underlying error", r.Detail)
	}
}

func TestCheckGitHubRateLimit_LowRemaining_Warns(t *testing.T) {
	p := baseProbe()
	p.rateRemaining = 3
	p.rateTotal = 60
	got := collectWithProbe(context.Background(), "1.0.0", p)
	r := findResult(t, got, "github_rate_limit")
	if r.Status != StatusWarn {
		t.Fatalf("status=%s, want WARN; detail=%s", r.Status, r.Detail)
	}
	if !strings.Contains(r.Detail, "3/60") {
		t.Errorf("detail %q missing the ratio", r.Detail)
	}
}
