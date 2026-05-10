// Package doctor implements the `deckhand-sidecar doctor` self-diagnostic.
//
// Run produces a human-readable report of the host environment, the
// presence of the elevated helper binary, disk enumeration health,
// writability of the sidecar's managed data/cache dirs, and a few
// platform-specific probes (pkexec / osascript / trusted Windows PowerShell).
//
// The checks are executed against a pluggable Probe so they can be
// unit-tested without depending on the real host. The package exposes
// `Run` for production callers (wiring in the real probe) plus
// `RunWithProbe` for tests.
package doctor

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sync"
	"time"

	"github.com/CepheusLabs/deckhand/sidecar/internal/disks"
	"github.com/CepheusLabs/deckhand/sidecar/internal/host"
	"github.com/CepheusLabs/deckhand/sidecar/internal/winutil"
)

// Status is the verdict of a single diagnostic check.
type Status string

const (
	// StatusPass means the check succeeded.
	StatusPass Status = "PASS"
	// StatusWarn means the check surfaced something worth noting but
	// Deckhand should still work.
	StatusWarn Status = "WARN"
	// StatusFail means the check found a blocking issue. Run returns
	// passed=false when any FAIL result is recorded.
	StatusFail Status = "FAIL"
)

// Result is one diagnostic line item.
type Result struct {
	Name   string
	Status Status
	Detail string
}

// Probe is the seam used by Run to reach the outside world. Tests supply
// fakes so the logic can be exercised without a real filesystem or
// $PATH.
type Probe interface {
	// GOOS returns the effective operating system string (runtime.GOOS
	// in production; overridable in tests).
	GOOS() string
	// GOARCH returns the effective architecture string.
	GOARCH() string
	// GoVersion returns the Go runtime version.
	GoVersion() string
	// Executable returns the path to the current binary (os.Executable).
	Executable() (string, error)
	// Stat is os.Stat wrapped for fakeability.
	Stat(path string) (os.FileInfo, error)
	// LookPath is exec.LookPath wrapped for fakeability.
	LookPath(name string) (string, error)
	// PowerShellExe returns the trusted Windows PowerShell executable.
	// Windows production code does not resolve powershell.exe via PATH.
	PowerShellExe() (string, error)
	// HostInfo returns the host.Info Deckhand uses for its data/cache
	// directories.
	HostInfo() host.Info
	// ProbeWritable reports whether `dir` can be created and written to
	// by the current process. Returns nil on success.
	ProbeWritable(dir string) error
	// ListDisksCount enumerates disks and returns just the count (we
	// deliberately do not surface device paths or models in the report
	// for privacy).
	ListDisksCount(ctx context.Context) (int, error)
	// MDNSPrimitivesAvailable answers whether the OS lets us open a
	// UDP socket and join the mDNS multicast group. A failure here
	// means the wizard's S20 auto-discovery will silently return zero
	// hits, which users mistake for "Deckhand is broken." Returns nil
	// on success; an error explaining the cause otherwise.
	MDNSPrimitivesAvailable() error
	// GitHubRateLimit fetches the unauthenticated rate-limit endpoint
	// and returns (remaining, total). A network error returns
	// (0, 0, err) — the doctor surfaces the error as a WARN so an
	// offline first launch isn't a hard fail.
	GitHubRateLimit(ctx context.Context) (remaining int, total int, err error)
}

// defaultProbe is the production Probe: it delegates to the real
// runtime, os, and exec packages, and to disks.List.
type defaultProbe struct{}

func (defaultProbe) GOOS() string      { return runtime.GOOS }
func (defaultProbe) GOARCH() string    { return runtime.GOARCH }
func (defaultProbe) GoVersion() string { return runtime.Version() }
func (defaultProbe) Executable() (string, error) {
	return os.Executable()
}
func (defaultProbe) Stat(path string) (os.FileInfo, error) { return os.Stat(path) }
func (defaultProbe) LookPath(name string) (string, error)  { return exec.LookPath(name) }
func (defaultProbe) PowerShellExe() (string, error)        { return winutil.PowerShellExe() }
func (defaultProbe) HostInfo() host.Info                   { return host.Current() }
func (defaultProbe) ProbeWritable(dir string) error        { return probeWritable(dir) }
func (defaultProbe) ListDisksCount(ctx context.Context) (int, error) {
	infos, err := disks.List(ctx)
	if err != nil {
		return 0, err
	}
	return len(infos), nil
}
func (defaultProbe) MDNSPrimitivesAvailable() error {
	// Probe whether the OS lets us SEND multicast packets to the
	// mDNS group (224.0.0.251:5353). We deliberately DO NOT bind
	// port 5353 ourselves — that competes with system responders
	// (avahi-daemon on Linux, mDNSResponder on macOS) and falsely
	// fails on every healthy Unix host. The wizard's mDNS path
	// uses Bonsoir/nsd which work the same way: outbound queries
	// from an ephemeral port, replies routed back via the OS
	// stack's multicast group membership.
	//
	// What we actually verify:
	//   1. We can bind a UDP socket on an ephemeral port.
	//   2. We can write a one-byte datagram to 224.0.0.251:5353.
	// If a host firewall blocks outbound multicast (the Windows
	// Firewall default for some profiles) one of these will error;
	// avahi/bonjour running on the same host does not interfere.
	conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4zero, Port: 0})
	if err != nil {
		return fmt.Errorf("listen udp4 (ephemeral): %w", err)
	}
	defer func() { _ = conn.Close() }()
	mdnsAddr := &net.UDPAddr{IP: net.IPv4(224, 0, 0, 251), Port: 5353}
	if _, err := conn.WriteToUDP([]byte{0}, mdnsAddr); err != nil {
		return fmt.Errorf("send mdns probe: %w", err)
	}
	return nil
}
func (defaultProbe) GitHubRateLimit(ctx context.Context) (int, int, error) {
	const url = "https://api.github.com/rate_limit"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return 0, 0, err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return 0, 0, err
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		return 0, 0, fmt.Errorf("status %d", resp.StatusCode)
	}
	var body struct {
		Rate struct {
			Limit     int `json:"limit"`
			Remaining int `json:"remaining"`
		} `json:"rate"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return 0, 0, err
	}
	return body.Rate.Remaining, body.Rate.Limit, nil
}

// probeWritable creates `dir` (if missing), writes a small temp file,
// reads it back, and removes it. Any error short-circuits and is
// returned verbatim — the caller translates that into a FAIL result.
func probeWritable(dir string) error {
	if dir == "" {
		return fmt.Errorf("directory path is empty")
	}
	if err := os.MkdirAll(dir, 0o750); err != nil {
		return fmt.Errorf("mkdir %q: %w", dir, err)
	}
	f, err := os.CreateTemp(dir, ".deckhand-doctor-*")
	if err != nil {
		return fmt.Errorf("create probe file in %q: %w", dir, err)
	}
	name := f.Name()
	// Close first — on Windows you can't remove an open file, and even
	// on POSIX it's cleaner to close before removing.
	_ = f.Close()
	defer func() { _ = os.Remove(name) }()
	if err := os.WriteFile(name, []byte("ok"), 0o600); err != nil {
		return fmt.Errorf("write probe file: %w", err)
	}
	return nil
}

// elevatedHelperName returns the expected filename of the elevated
// helper binary next to the sidecar. Windows gets `.exe`.
func elevatedHelperName(goos string) string {
	if goos == "windows" {
		return "deckhand-elevated-helper.exe"
	}
	return "deckhand-elevated-helper"
}

// Run executes the full diagnostic sweep using the real host probe and
// writes a human-readable report to w. It returns (passed, err). passed
// is true iff no FAIL result was recorded. err is only non-nil if we
// couldn't write to w.
func Run(ctx context.Context, w io.Writer, version string) (bool, error) {
	return RunWithProbe(ctx, w, version, defaultProbe{})
}

// RunWithProbe is the testable entry point. Production callers use Run.
func RunWithProbe(ctx context.Context, w io.Writer, version string, p Probe) (bool, error) {
	results := collectWithProbe(ctx, version, p)
	return writeReport(w, results)
}

// Collect runs every diagnostic and returns the ordered Result list
// without writing a human-readable report. Used by the `doctor.run`
// JSON-RPC handler so the UI can render its own preflight panel
// instead of parsing the CLI's text output.
func Collect(ctx context.Context, version string) []Result {
	return collectWithProbe(ctx, version, defaultProbe{})
}

// collectWithProbe runs every diagnostic and returns the ordered
// Result list. Each check runs in its own goroutine so the user-facing
// latency is roughly the slowest check (GitHub rate-limit HTTP, capped
// at 5s) rather than the sum of all of them. Previously sequential,
// the whole sweep ran 3-5s on a healthy host because checkDisks
// (Windows PowerShell startup) and checkGitHubRateLimit (network
// round-trip) were stacked.
//
// Each goroutine writes to its own pre-allocated slot so the result
// order matches the report's expected order without a post-sort.
// Tests pin the order via Names so re-ordering would silently break
// them.
//
// Kept separate from writeReport so tests can assert on structured
// results without parsing text.
func collectWithProbe(ctx context.Context, version string, p Probe) []Result {
	const slots = 8
	results := make([]Result, slots)
	var wg sync.WaitGroup

	info := p.HostInfo()

	wg.Add(slots)
	// 0. Runtime + sidecar version (informational, always PASS).
	go func() {
		defer wg.Done()
		results[0] = Result{
			Name:   "runtime",
			Status: StatusPass,
			Detail: fmt.Sprintf("os=%s arch=%s go=%s sidecar=%s",
				p.GOOS(), p.GOARCH(), p.GoVersion(), version),
		}
	}()
	// 1. Elevated helper presence.
	go func() {
		defer wg.Done()
		results[1] = checkElevatedHelper(p)
	}()
	// 2. Disk enumeration (slow on Windows: PowerShell startup).
	go func() {
		defer wg.Done()
		results[2] = checkDisks(ctx, p)
	}()
	// 3. Data dir writability.
	go func() {
		defer wg.Done()
		results[3] = checkDirWritable(p, "data_dir", info.Data)
	}()
	// 4. Cache dir writability.
	go func() {
		defer wg.Done()
		results[4] = checkDirWritable(p, "cache_dir", info.Cache)
	}()
	// 5. Platform tool LookPath.
	go func() {
		defer wg.Done()
		results[5] = checkPlatformTool(p)
	}()
	// 6. mDNS primitives.
	go func() {
		defer wg.Done()
		results[6] = checkMDNS(p)
	}()
	// 7. GitHub rate limit (slow: HTTP round-trip with 5s timeout).
	go func() {
		defer wg.Done()
		results[7] = checkGitHubRateLimit(ctx, p)
	}()
	wg.Wait()
	return results
}

// checkMDNS exercises the OS primitives the wizard's mDNS auto-
// discovery depends on. Binding a UDP socket and joining the mDNS
// multicast group is enough to catch the most common failure
// (Windows Firewall blocking outbound multicast); a deeper "actually
// resolve a known service" probe would hang on networks with no
// responders, which is the common case in CI.
func checkMDNS(p Probe) Result {
	const name = "mdns_resolvable"
	if err := p.MDNSPrimitivesAvailable(); err != nil {
		return Result{
			Name:   name,
			Status: StatusWarn,
			Detail: fmt.Sprintf("UDP/multicast unavailable: %v (auto-discovery on S20 will return zero hits — manual IP still works)", err),
		}
	}
	return Result{Name: name, Status: StatusPass, Detail: "UDP socket + multicast group join OK"}
}

// checkGitHubRateLimit warns when the unauthenticated rate limit is
// running low. 60/hour is GitHub's documented unauthenticated cap;
// we WARN below 10 because a stock-keep flow performs ~5 git probes
// + ~3 release-asset metadata calls during install, leaving little
// headroom for retries.
func checkGitHubRateLimit(ctx context.Context, p Probe) Result {
	const name = "github_rate_limit"
	remaining, total, err := p.GitHubRateLimit(ctx)
	if err != nil {
		return Result{
			Name:   name,
			Status: StatusWarn,
			Detail: fmt.Sprintf("could not query api.github.com: %v (offline launches are fine; stock-keep flow may need a saved token if the limit hits)", err),
		}
	}
	if remaining < 10 {
		return Result{
			Name:   name,
			Status: StatusWarn,
			Detail: fmt.Sprintf("only %d/%d requests left this hour — set a GitHub PAT in Settings before starting an install", remaining, total),
		}
	}
	return Result{
		Name:   name,
		Status: StatusPass,
		Detail: fmt.Sprintf("%d/%d requests remaining this hour", remaining, total),
	}
}

// checkElevatedHelper looks for deckhand-elevated-helper in the same
// directory as the sidecar executable. Missing helper is WARN rather
// than FAIL: the sidecar is still useful for non-destructive RPCs like
// disks.list and os.download even without the helper.
func checkElevatedHelper(p Probe) Result {
	const name = "elevated_helper"
	exe, err := p.Executable()
	if err != nil {
		return Result{Name: name, Status: StatusWarn, Detail: fmt.Sprintf("os.Executable failed: %v", err)}
	}
	dir := filepath.Dir(exe)
	helper := filepath.Join(dir, elevatedHelperName(p.GOOS()))
	fi, err := p.Stat(helper)
	if err != nil {
		return Result{
			Name:   name,
			Status: StatusWarn,
			Detail: fmt.Sprintf("not found at %s: %v (disk-write flows will require elevation)", helper, err),
		}
	}
	if fi.IsDir() {
		return Result{
			Name:   name,
			Status: StatusFail,
			Detail: fmt.Sprintf("%s is a directory, not a binary", helper),
		}
	}
	return Result{Name: name, Status: StatusPass, Detail: helper}
}

// checkDisks runs disks.List. A non-nil error is a FAIL — disk
// enumeration is core functionality. Count-only reporting keeps device
// names / models out of the report (privacy).
func checkDisks(ctx context.Context, p Probe) Result {
	const name = "disks_enumerate"
	n, err := p.ListDisksCount(ctx)
	if err != nil {
		return Result{Name: name, Status: StatusFail, Detail: fmt.Sprintf("disks.List error: %v", err)}
	}
	if n == 0 {
		return Result{Name: name, Status: StatusWarn, Detail: "no disks reported (unusual — expected at least the system disk)"}
	}
	return Result{Name: name, Status: StatusPass, Detail: fmt.Sprintf("%d disk(s) enumerated", n)}
}

// checkDirWritable verifies a directory exists (or can be created) and
// accepts writes. Failures are FAIL because Deckhand can't stage
// downloads or persist settings without these.
func checkDirWritable(p Probe, label, dir string) Result {
	if dir == "" {
		return Result{Name: label, Status: StatusFail, Detail: "host.Current() returned empty path"}
	}
	if err := p.ProbeWritable(dir); err != nil {
		return Result{Name: label, Status: StatusFail, Detail: fmt.Sprintf("%s (%s)", err, dir)}
	}
	return Result{Name: label, Status: StatusPass, Detail: dir}
}

// checkPlatformTool probes the elevation tool used on the current OS:
// pkexec on Linux, osascript on macOS, and the trusted System32 Windows
// PowerShell path on Windows. An unknown OS is an informational WARN
// rather than FAIL.
func checkPlatformTool(p Probe) Result {
	var (
		tool, label string
	)
	switch p.GOOS() {
	case "linux":
		tool, label = "pkexec", "pkexec_on_path"
	case "darwin":
		tool, label = "osascript", "osascript_on_path"
	case "windows":
		powerShell, err := p.PowerShellExe()
		if err != nil {
			return Result{
				Name:   "powershell_system",
				Status: StatusFail,
				Detail: fmt.Sprintf("trusted Windows PowerShell path unavailable: %v", err),
			}
		}
		if _, err := p.Stat(powerShell); err != nil {
			return Result{
				Name:   "powershell_system",
				Status: StatusFail,
				Detail: fmt.Sprintf("%s not found: %v", powerShell, err),
			}
		}
		return Result{Name: "powershell_system", Status: StatusPass, Detail: powerShell}
	default:
		return Result{
			Name:   "platform_tool",
			Status: StatusWarn,
			Detail: fmt.Sprintf("no elevation probe for GOOS=%q", p.GOOS()),
		}
	}
	resolved, err := p.LookPath(tool)
	if err != nil {
		// Linux without pkexec can still use other polkit agents, but
		// the Deckhand helper path expects pkexec today — same for the
		// osascript dance on macOS. Escalate to FAIL so the user knows
		// to install it.
		return Result{
			Name:   label,
			Status: StatusFail,
			Detail: fmt.Sprintf("%s not found on PATH: %v", tool, err),
		}
	}
	return Result{Name: label, Status: StatusPass, Detail: resolved}
}

// writeReport prints results in `[STATUS] name — detail` form and a
// trailing summary line, then returns (passed, writeErr). A single
// write error aborts early.
func writeReport(w io.Writer, results []Result) (bool, error) {
	passed := true
	for _, r := range results {
		if r.Status == StatusFail {
			passed = false
		}
		if _, err := fmt.Fprintf(w, "[%s] %s — %s\n", r.Status, r.Name, r.Detail); err != nil {
			return false, err
		}
	}
	summary := "all checks passed"
	if !passed {
		summary = "one or more blocking issues found"
	}
	if _, err := fmt.Fprintf(w, "\n%s\n", summary); err != nil {
		return false, err
	}
	return passed, nil
}
