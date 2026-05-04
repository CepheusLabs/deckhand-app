// Package handlers wires every JSON-RPC method the Deckhand sidecar
// exposes onto an rpc.Server. It lives in its own package (rather than
// inline in cmd/deckhand-sidecar) so the IPC docs generator at
// cmd/deckhand-ipc-docs can import and replay the same registration
// set - main packages are not importable in Go.
package handlers

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/CepheusLabs/deckhand/sidecar/internal/disks"
	"github.com/CepheusLabs/deckhand/sidecar/internal/doctor"
	"github.com/CepheusLabs/deckhand/sidecar/internal/hash"
	"github.com/CepheusLabs/deckhand/sidecar/internal/host"
	"github.com/CepheusLabs/deckhand/sidecar/internal/osimg"
	"github.com/CepheusLabs/deckhand/sidecar/internal/profiles"
	"github.com/CepheusLabs/deckhand/sidecar/internal/rpc"
)

const (
	backupRootMarker     = ".deckhand-emmc-backups-root"
	downloadTempRootName = "deckhand-os-images"
)

// Register wires every handler onto s. The cancel parameter is the
// outer Serve context's cancel func; `shutdown` calls it so the Serve
// loop exits cleanly. version is used by `ping` and `version.compat`.
func Register(s *rpc.Server, cancel context.CancelFunc, version string) {
	// Lifecycle
	s.RegisterMethod(rpc.MethodSpec{
		Name:        "ping",
		Description: "Liveness + version probe. Returns sidecar version and host os/arch.",
		Returns:     "{sidecar_version, os, arch}",
		Handler: func(_ context.Context, _ json.RawMessage, _ rpc.Notifier) (any, error) {
			return map[string]any{
				"sidecar_version": version,
				"os":              runtime.GOOS,
				"arch":            runtime.GOARCH,
			}, nil
		},
	})

	s.RegisterMethod(rpc.MethodSpec{
		Name:        "version.compat",
		Description: "Report whether the UI's version is compatible with this sidecar.",
		Params: []rpc.ParamSpec{
			{Name: "ui_version", Kind: rpc.ParamKindString, MaxLen: 64},
		},
		Returns: "{compatible, sidecar_version, ui_version}",
		Handler: func(_ context.Context, raw json.RawMessage, _ rpc.Notifier) (any, error) {
			var req struct {
				UIVersion string `json:"ui_version"`
			}
			if err := json.Unmarshal(raw, &req); err != nil {
				return nil, fmt.Errorf("decode params: %w", err)
			}
			// Today the contract is simple: there is one sidecar version
			// and it accepts every UI that speaks JSON-RPC 2.0 on our
			// method surface. When we introduce breaking changes we'll
			// switch this to real comparison - for now we honestly report
			// "compatible" plus the UI version we saw so a bug report can
			// include both.
			return map[string]any{
				"compatible":      true,
				"sidecar_version": version,
				"ui_version":      req.UIVersion,
			}, nil
		},
	})

	s.RegisterMethod(rpc.MethodSpec{
		Name:        "host.info",
		Description: "Return host platform info plus Deckhand's data/cache/settings paths.",
		Returns:     "host.Info",
		Handler: func(_ context.Context, _ json.RawMessage, _ rpc.Notifier) (any, error) {
			return host.Current(), nil
		},
	})

	s.RegisterMethod(rpc.MethodSpec{
		Name:        "doctor.run",
		Description: "Run the sidecar self-diagnostic and return structured results.",
		Returns:     "{passed: bool, results: [{name, status, detail}], report: string}",
		Handler: func(ctx context.Context, _ json.RawMessage, _ rpc.Notifier) (any, error) {
			results := doctor.Collect(ctx, version)
			passed := true
			out := make([]map[string]string, 0, len(results))
			for _, r := range results {
				if r.Status == doctor.StatusFail {
					passed = false
				}
				out = append(out, map[string]string{
					"name":   r.Name,
					"status": string(r.Status),
					"detail": r.Detail,
				})
			}
			// Also include the CLI-style human-readable report so the
			// UI's "View report" button can show identical output to
			// the bundled `deckhand-sidecar doctor` command. Render
			// from the already-collected slice rather than calling
			// doctor.Run a second time (which would re-run every
			// check and double the wall time of doctor.run).
			var buf bytes.Buffer
			for _, r := range results {
				_, _ = fmt.Fprintf(&buf, "[%s] %s — %s\n", r.Status, r.Name, r.Detail)
			}
			summary := "all checks passed"
			if !passed {
				summary = "one or more blocking issues found"
			}
			_, _ = fmt.Fprintf(&buf, "\n%s\n", summary)
			return map[string]any{
				"passed":  passed,
				"results": out,
				"report":  buf.String(),
			}, nil
		},
	})

	s.RegisterMethod(rpc.MethodSpec{
		Name:        "shutdown",
		Description: "Ask the sidecar to drain in-flight handlers and exit.",
		Returns:     "{ok}",
		Handler: func(_ context.Context, _ json.RawMessage, _ rpc.Notifier) (any, error) {
			// Cancel the Serve context so the loop exits naturally after
			// the response is flushed to stdout. This avoids the data
			// race the earlier `go os.Exit(0)` had with the response
			// write, and lets in-flight handlers finish (or respond to
			// ctx cancellation) instead of being hard-killed mid-
			// download.
			cancel()
			return map[string]any{"ok": true}, nil
		},
	})

	// jobs.cancel - cancel a single in-flight operation by its request id.
	jobsCancelSpecs := []rpc.ParamSpec{
		{Name: "id", Required: true, Kind: rpc.ParamKindString, MinLen: 1, MaxLen: 256},
	}
	s.RegisterMethod(rpc.MethodSpec{
		Name:        "jobs.cancel",
		Description: "Cancel an in-flight handler by its originating JSON-RPC id.",
		Params:      jobsCancelSpecs,
		Returns:     "{ok, cancelled}",
		Handler: func(_ context.Context, raw json.RawMessage, _ rpc.Notifier) (any, error) {
			if err := rpc.ValidateParams(raw, jobsCancelSpecs); err != nil {
				return nil, err
			}
			var req struct {
				ID string `json:"id"`
			}
			if err := json.Unmarshal(raw, &req); err != nil {
				return nil, rpc.NewError(rpc.CodeGeneric, "decode params: %v", err)
			}
			return map[string]any{
				"ok":        true,
				"cancelled": s.CancelJob(req.ID),
			}, nil
		},
	})

	// Disks
	s.RegisterMethod(rpc.MethodSpec{
		Name:        "disks.list",
		Description: "Enumerate writable disks attached to the host.",
		Returns:     "{disks: DiskInfo[]}",
		Handler: func(ctx context.Context, _ json.RawMessage, _ rpc.Notifier) (any, error) {
			infos, err := disks.List(ctx)
			if err != nil {
				return nil, rpc.NewError(rpc.CodeDisk, "disks.list failed: %v", err)
			}
			// Annotate with any interrupted-flash sentinels left over
			// from a prior write that didn't reach `event: done`. A
			// sentinel-read failure is non-fatal — disks.list must
			// always succeed if the underlying enumeration did, even
			// if the sentinel directory is corrupt or unreadable.
			sentinels, _ := disks.LoadSentinels(sentinelDir())
			infos = disks.AnnotateInterrupted(infos, sentinels)
			return map[string]any{"disks": infos}, nil
		},
	})

	disksHashSpecs := []rpc.ParamSpec{
		{Name: "path", Required: true, Kind: rpc.ParamKindString, MinLen: 1, MaxLen: 4096},
	}
	s.RegisterMethod(rpc.MethodSpec{
		Name:        "disks.hash",
		Description: "SHA-256 of a file at a Deckhand-managed path (downloads or device nodes).",
		Params:      disksHashSpecs,
		Returns:     "{sha256, path}",
		Handler: func(_ context.Context, raw json.RawMessage, _ rpc.Notifier) (any, error) {
			if err := rpc.ValidateParams(raw, disksHashSpecs); err != nil {
				return nil, err
			}
			var req struct {
				Path string `json:"path"`
			}
			if err := json.Unmarshal(raw, &req); err != nil {
				return nil, rpc.NewError(rpc.CodeGeneric, "decode params: %v", err)
			}
			// disks.hash is intended for image files Deckhand itself wrote
			// or downloaded (post-download verification), not arbitrary
			// paths. Enforce a safe subset to keep this from being a
			// generic "read file existence/contents" oracle.
			if err := validateHashPath(req.Path); err != nil {
				return nil, rpc.NewError(rpc.CodeGeneric, "%v", err)
			}
			h, err := hash.SHA256(req.Path)
			if err != nil {
				return nil, rpc.NewError(rpc.CodeDisk, "hash failed: %v", err)
			}
			return map[string]any{"sha256": h, "path": req.Path}, nil
		},
	})

	readImageSpecs := []rpc.ParamSpec{
		{Name: "device_id", Kind: rpc.ParamKindString, MaxLen: 256},
		{Name: "path", Kind: rpc.ParamKindString, MaxLen: 4096},
		{Name: "output", Required: true, Kind: rpc.ParamKindString, MinLen: 1, MaxLen: 4096},
	}
	s.RegisterMethod(rpc.MethodSpec{
		Name:        "disks.read_image",
		Description: "Read a raw device to a local file with progress notifications.",
		Params:      readImageSpecs,
		Returns:     "{sha256, output}",
		Handler: func(ctx context.Context, raw json.RawMessage, note rpc.Notifier) (any, error) {
			if err := rpc.ValidateParams(raw, readImageSpecs); err != nil {
				return nil, err
			}
			var req struct {
				DeviceID string `json:"device_id"`
				Path     string `json:"path"`
				Output   string `json:"output"`
			}
			if err := json.Unmarshal(raw, &req); err != nil {
				return nil, rpc.NewError(rpc.CodeGeneric, "decode params: %v", err)
			}
			dev, err := disks.ResolveDevicePath(req.Path, req.DeviceID)
			if err != nil {
				return nil, rpc.NewError(rpc.CodeDisk, "resolve device: %v", err)
			}
			// disks.read_image writes a raw-device backup. Keep it in
			// the same marked Deckhand-owned backup root as the elevated
			// helper so a caller cannot clobber arbitrary user files.
			if err := validateReadImageOutputPath(req.Output); err != nil {
				return nil, rpc.NewError(rpc.CodeGeneric, "%v", err)
			}
			sha, err := disks.ReadImage(ctx, dev, req.Output, note)
			if err != nil {
				return nil, rpc.NewError(rpc.CodeDisk, "read_image: %v", err)
			}
			return map[string]any{"sha256": sha, "output": req.Output}, nil
		},
	})

	s.RegisterMethod(rpc.MethodSpec{
		Name:        "disks.safety_check",
		Description: "Assess whether a target disk is safe to write. Returns a verdict.",
		Params: []rpc.ParamSpec{
			{Name: "disk", Required: true, Kind: rpc.ParamKindObject},
		},
		Returns: "SafetyVerdict",
		Handler: func(ctx context.Context, raw json.RawMessage, _ rpc.Notifier) (any, error) {
			var req struct {
				Disk disks.DiskInfo `json:"disk"`
			}
			if err := json.Unmarshal(raw, &req); err != nil {
				return nil, rpc.NewError(rpc.CodeGeneric, "decode params: %v", err)
			}
			if req.Disk.ID == "" {
				return nil, rpc.NewError(rpc.CodeGeneric, "disk.id is required")
			}
			// Cross-check against the live OS enumeration. A caller
			// that fabricates a DiskInfo (removable: true, small size,
			// no system mounts) could otherwise pass safety on a
			// fictional disk and then issue write_image against the
			// real disk ID. Re-probe and assess the live record.
			live, err := liveDiskByID(ctx, req.Disk.ID)
			if err != nil {
				return nil, rpc.NewError(rpc.CodeDisk, "%v", err)
			}
			return disks.AssessWriteTarget(*live), nil
		},
	})

	writeImageSpecs := []rpc.ParamSpec{
		{Name: "image_path", Required: true, Kind: rpc.ParamKindString, MinLen: 1, MaxLen: 4096},
		{Name: "disk_id", Required: true, Kind: rpc.ParamKindString, MinLen: 1, MaxLen: 256},
		{Name: "confirmation_token", Required: true, Kind: rpc.ParamKindString, MinLen: 1, MaxLen: 512},
		{Name: "disk", Kind: rpc.ParamKindObject},
	}
	s.RegisterMethod(rpc.MethodSpec{
		Name:        "disks.write_image",
		Description: "Write a local image to a disk. Requires a confirmation_token issued by the UI.",
		Params:      writeImageSpecs,
		Returns:     "{ok} or rpc.Error with reason elevation_required / unsafe_target",
		Handler: func(ctx context.Context, raw json.RawMessage, _ rpc.Notifier) (any, error) {
			if err := rpc.ValidateParams(raw, writeImageSpecs); err != nil {
				return nil, err
			}
			var req struct {
				ImagePath         string          `json:"image_path"`
				DiskID            string          `json:"disk_id"`
				ConfirmationToken string          `json:"confirmation_token"`
				Disk              *disks.DiskInfo `json:"disk"`
			}
			if err := json.Unmarshal(raw, &req); err != nil {
				return nil, rpc.NewError(rpc.CodeGeneric, "decode params: %v", err)
			}
			// Defense-in-depth preflight. Re-probe the disk live (do
			// NOT trust the caller-supplied DiskInfo) and re-run the
			// safety check before telling the caller to elevate. This
			// catches a malicious or racy UI that fabricated DiskInfo
			// or skipped the separate safety call.
			live, err := liveDiskByID(ctx, req.DiskID)
			if err != nil {
				return nil, rpc.NewError(rpc.CodeDisk, "%v", err)
			}
			verdict := disks.AssessWriteTarget(*live)
			if !verdict.Allowed {
				return nil, &rpc.Error{
					Code:    rpc.CodeDisk + 2,
					Message: "safety check refused this target",
					Data: map[string]any{
						"reason":  "unsafe_target",
						"verdict": verdict,
					},
				}
			}
			if err := disks.WriteImage(ctx, req.ImagePath, req.DiskID, req.ConfirmationToken); err != nil {
				if errors.Is(err, disks.ErrElevationRequired) {
					// Domain-specific code so the UI can branch to an
					// elevation prompt rather than treating this as a
					// generic failure.
					return nil, &rpc.Error{
						Code:    rpc.CodeDisk + 1,
						Message: err.Error(),
						Data:    map[string]any{"reason": "elevation_required"},
					}
				}
				return nil, rpc.NewError(rpc.CodeDisk, "write_image: %v", err)
			}
			return map[string]any{"ok": true}, nil
		},
	})

	// OS image download
	downloadSpecs := []rpc.ParamSpec{
		{Name: "url", Required: true, Kind: rpc.ParamKindString, MinLen: 1, MaxLen: 4096, Pattern: `^https://`},
		{Name: "dest", Required: true, Kind: rpc.ParamKindString, MinLen: 1, MaxLen: 4096},
		{Name: "sha256", Required: true, Kind: rpc.ParamKindString, MinLen: 64, MaxLen: 64, Pattern: `^[0-9a-f]{64}$`},
	}
	s.RegisterMethod(rpc.MethodSpec{
		Name:        "os.download",
		Description: "Download an OS image to a managed cache path, verifying the expected SHA-256.",
		Params:      downloadSpecs,
		Returns:     "{sha256, path}",
		Handler: func(ctx context.Context, raw json.RawMessage, note rpc.Notifier) (any, error) {
			if err := rpc.ValidateParams(raw, downloadSpecs); err != nil {
				return nil, err
			}
			var req struct {
				URL         string `json:"url"`
				Dest        string `json:"dest"`
				ExpectedSha string `json:"sha256"`
			}
			if err := json.Unmarshal(raw, &req); err != nil {
				return nil, fmt.Errorf("decode params: %w", err)
			}
			if err := validateDownloadDestPath(req.Dest); err != nil {
				return nil, rpc.NewError(rpc.CodeGeneric, "%v", err)
			}
			if err := os.MkdirAll(filepath.Dir(req.Dest), 0o700); err != nil {
				return nil, rpc.NewError(rpc.CodeGeneric, "create download dir: %v", err)
			}
			if err := validateDownloadDestPath(req.Dest); err != nil {
				return nil, rpc.NewError(rpc.CodeGeneric, "%v", err)
			}
			sha, err := osimg.Download(ctx, req.URL, req.Dest, req.ExpectedSha, note)
			if err != nil {
				return nil, err
			}
			return map[string]any{"sha256": sha, "path": req.Dest}, nil
		},
	})

	// Profile fetch (go-git shallow clone, optional signed-tag verify)
	profilesFetchSpecs := []rpc.ParamSpec{
		{Name: "repo_url", Required: true, Kind: rpc.ParamKindString, MinLen: 1, MaxLen: 2048},
		{Name: "ref", Kind: rpc.ParamKindString, MaxLen: 256},
		{Name: "dest", Required: true, Kind: rpc.ParamKindString, MinLen: 1, MaxLen: 4096},
		{Name: "force", Kind: rpc.ParamKindBool},
		{Name: "trusted_keys", Kind: rpc.ParamKindString},
		{Name: "require_signed_tag", Kind: rpc.ParamKindBool},
	}
	s.RegisterMethod(rpc.MethodSpec{
		Name:        "profiles.fetch",
		Description: "Shallow-clone a Klipper config profile repo; optionally verify a signed tag.",
		Params:      profilesFetchSpecs,
		Returns:     "profiles.FetchResult",
		Handler: func(ctx context.Context, raw json.RawMessage, _ rpc.Notifier) (any, error) {
			if err := rpc.ValidateParams(raw, profilesFetchSpecs); err != nil {
				return nil, err
			}
			var req struct {
				RepoURL          string `json:"repo_url"`
				Ref              string `json:"ref"`
				Dest             string `json:"dest"`
				Force            bool   `json:"force"`
				TrustedKeys      string `json:"trusted_keys"`       // armored PGP keyring
				RequireSignedTag bool   `json:"require_signed_tag"` // reject unsigned/branch
			}
			if err := json.Unmarshal(raw, &req); err != nil {
				return nil, fmt.Errorf("decode params: %w", err)
			}
			if err := validateRepoURL(req.RepoURL); err != nil {
				return nil, err
			}
			if err := validateGitRef(req.Ref); err != nil {
				return nil, err
			}
			if err := validateProfileFetchDestPath(req.Dest); err != nil {
				return nil, rpc.NewError(rpc.CodeGeneric, "%v", err)
			}
			opts := profiles.Options{
				RequireSignedTag: req.RequireSignedTag,
			}
			if req.TrustedKeys != "" {
				opts.TrustedKeys = []byte(req.TrustedKeys)
			}
			res, err := profiles.FetchWithOptions(ctx, req.RepoURL, req.Ref, req.Dest, req.Force, opts)
			if err != nil {
				if errors.Is(err, profiles.ErrUnsignedOrUntrusted) {
					return nil, &rpc.Error{
						Code:    rpc.CodeProfile + 1,
						Message: err.Error(),
						Data:    map[string]any{"reason": "unsigned_or_untrusted"},
					}
				}
				return nil, rpc.NewError(rpc.CodeProfile, "fetch: %v", err)
			}
			return res, nil
		},
	})
}

// sentinelDir returns the per-user directory the UI uses to record
// in-flight flash operations. It lives under the data dir from
// host.Current() so it follows the same per-OS convention as every
// other Deckhand state file. A best-effort read: returning "" when
// host.Current() can't resolve a data dir means LoadSentinels will
// silently return an empty map and disks.list still works.
func sentinelDir() string {
	info := host.Current()
	if info.Data == "" {
		return ""
	}
	return filepath.Join(info.Data, "Deckhand", "state", "flash-sentinels")
}

// validateHashPath restricts disks.hash to paths that plausibly belong
// to the set of files Deckhand itself manages - either raw block
// devices (when the UI is pre-flight checking a disk) or regular files
// under the sidecar's host-info download directory. Arbitrary
// filesystem paths are rejected so this RPC cannot be used as a
// "does-file-X-exist / hash-arbitrary-file" oracle.
func validateHashPath(p string) error {
	if p == "" {
		return fmt.Errorf("path is required")
	}
	clean := filepath.Clean(p)
	if strings.Contains(clean, "..") {
		return fmt.Errorf("path %q contains traversal", p)
	}
	// Raw-disk paths we use across OSes. These mirror the elevated
	// helper's allowlist (keep them in sync if one changes).
	devicePrefixes := []string{
		"/dev/sd", "/dev/nvme", "/dev/mmcblk", "/dev/disk",
		"/dev/rdisk", "/dev/loop", "/dev/vd",
	}
	for _, prefix := range devicePrefixes {
		if strings.HasPrefix(clean, prefix) && len(clean) > len(prefix) {
			return nil
		}
	}
	if runtime.GOOS == "windows" &&
		(strings.HasPrefix(clean, `\\.\`) || strings.HasPrefix(clean, `//./`)) {
		return nil
	}
	// Regular-file downloads under the sidecar's managed cache/data dirs.
	h := host.Current()
	for _, root := range []string{h.Cache, h.Data} {
		if root == "" {
			continue
		}
		cleanRoot := filepath.Clean(root)
		// Require a path separator after the root to prevent `/var/dataEVIL`
		// from matching `/var/data`.
		if strings.HasPrefix(clean, cleanRoot+string(os.PathSeparator)) {
			return nil
		}
	}
	// The system tmp dir is also acceptable for short-lived downloads
	// the UI stages before verification - TempDir is caller-controlled
	// by the OS, not attacker-controlled.
	tmp := filepath.Clean(os.TempDir())
	if tmp != "" && strings.HasPrefix(clean, tmp+string(os.PathSeparator)) {
		return nil
	}
	return fmt.Errorf("path %q is not under a Deckhand-managed directory or a recognised device node", p)
}

func validateRepoURL(raw string) error {
	if raw == "" {
		return fmt.Errorf("repo_url is required")
	}
	u, err := url.Parse(raw)
	if err != nil {
		return fmt.Errorf("parse repo_url %q: %w", raw, err)
	}
	// HTTPS only - profile content drives shell commands over SSH to
	// the printer, so a LAN MitM that can serve a malicious profile
	// repo over plain http would be a meaningful escalation. The
	// signed-tag verification path is the deeper defence, but this
	// closes the simpler attack at the network layer.
	if u.Scheme != "https" {
		return fmt.Errorf("repo_url scheme must be https, got %q", u.Scheme)
	}
	if u.Host == "" {
		return fmt.Errorf("repo_url %q has no host", raw)
	}
	if u.User != nil {
		return fmt.Errorf("repo_url must not contain embedded credentials")
	}
	if u.RawQuery != "" || u.Fragment != "" {
		return fmt.Errorf("repo_url must not contain query strings or fragments")
	}
	return nil
}

// validateProfileFetchDestPath constrains profiles.fetch to the
// Deckhand-owned profile cache. FetchWithOptions(force=true) removes
// the destination before cloning, so this RPC boundary must not accept
// arbitrary paths from the caller.
func validateProfileFetchDestPath(dest string) error {
	if dest == "" {
		return fmt.Errorf("dest is required")
	}
	if err := rejectDeviceOutputPath(dest); err != nil {
		return err
	}
	clean, err := filepath.Abs(filepath.Clean(dest))
	if err != nil {
		return fmt.Errorf("resolve dest %q: %w", dest, err)
	}
	if strings.Contains(clean, "..") {
		return fmt.Errorf("dest %q contains traversal", dest)
	}

	for _, base := range managedProfileBases() {
		if !isPathUnderRoot(clean, base) {
			continue
		}
		if !hasDeckhandProfilesAncestor(clean, base) {
			continue
		}
		if err := rejectSymlinkPath(base, clean); err != nil {
			return err
		}
		return nil
	}
	return fmt.Errorf("dest %q is not under a Deckhand-managed profile cache", dest)
}

func managedProfileBases() []string {
	h := host.Current()
	bases := []string{}
	for _, base := range []string{h.Cache, h.Data} {
		if base == "" {
			continue
		}
		absBase, err := filepath.Abs(base)
		if err != nil {
			continue
		}
		bases = append(bases, filepath.Clean(absBase))
	}
	return bases
}

func hasDeckhandProfilesAncestor(path, base string) bool {
	parent := filepath.Dir(path)
	for !samePath(parent, base) && parent != "." && parent != string(os.PathSeparator) {
		if filepath.Base(parent) == "profiles" &&
			filepath.Base(filepath.Dir(parent)) == "Deckhand" {
			return true
		}
		next := filepath.Dir(parent)
		if samePath(next, parent) {
			break
		}
		parent = next
	}
	return false
}

func isPathUnderRoot(path, root string) bool {
	if samePath(path, root) {
		return false
	}
	rel, err := filepath.Rel(root, path)
	if err != nil {
		return false
	}
	return rel != "." &&
		rel != ".." &&
		!strings.HasPrefix(rel, ".."+string(os.PathSeparator)) &&
		!filepath.IsAbs(rel)
}

func samePath(a, b string) bool {
	if runtime.GOOS == "windows" {
		return strings.EqualFold(a, b)
	}
	return a == b
}

func rejectSymlinkPath(base, target string) error {
	rel, err := filepath.Rel(base, target)
	if err != nil {
		return fmt.Errorf("resolve dest ancestry: %w", err)
	}
	if rel == "." {
		return nil
	}
	cur := base
	for _, part := range strings.Split(rel, string(os.PathSeparator)) {
		if part == "" || part == "." {
			continue
		}
		cur = filepath.Join(cur, part)
		info, err := os.Lstat(cur)
		if os.IsNotExist(err) {
			return nil
		}
		if err != nil {
			return fmt.Errorf("inspect dest ancestry %q: %w", cur, err)
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("dest ancestry %q must not be a symlink", cur)
		}
		if !info.IsDir() && cur != target {
			return fmt.Errorf("dest ancestry %q must be a directory", cur)
		}
	}
	return nil
}

// validateReadImageOutputPath constrains disks.read_image's destination
// to a marked Deckhand eMMC backup root. This mirrors the elevated
// helper policy so the non-elevated fallback cannot be used to truncate
// arbitrary user files or follow symlinks.
func validateReadImageOutputPath(output string) error {
	if output == "" {
		return fmt.Errorf("output is required")
	}
	if err := rejectDeviceOutputPath(output); err != nil {
		return err
	}
	clean, err := filepath.Abs(filepath.Clean(output))
	if err != nil {
		return fmt.Errorf("resolve output %q: %w", output, err)
	}
	if strings.Contains(clean, "..") {
		return fmt.Errorf("output %q contains traversal", output)
	}
	if filepath.Ext(clean) != ".img" {
		return fmt.Errorf("output %q must end in .img", output)
	}
	root := filepath.Dir(clean)
	if filepath.Base(root) != "emmc-backups" {
		return fmt.Errorf("output %q must be inside Deckhand's emmc-backups directory", output)
	}
	rootInfo, err := os.Lstat(root)
	if err != nil {
		return fmt.Errorf("backup root %q is not available: %w", root, err)
	}
	if rootInfo.Mode()&os.ModeSymlink != 0 || !rootInfo.IsDir() {
		return fmt.Errorf("backup root %q must be a real directory", root)
	}
	marker := filepath.Join(root, backupRootMarker)
	markerInfo, err := os.Lstat(marker)
	if err != nil {
		return fmt.Errorf("backup root %q is missing Deckhand marker", root)
	}
	if markerInfo.Mode()&os.ModeSymlink != 0 || !markerInfo.Mode().IsRegular() {
		return fmt.Errorf("backup root marker %q must be a regular file", marker)
	}
	if _, err := os.Lstat(clean); err == nil {
		return fmt.Errorf("output %q already exists", output)
	} else if !os.IsNotExist(err) {
		return fmt.Errorf("inspect output %q: %w", output, err)
	}
	return nil
}

// validateDownloadDestPath restricts os.download to Deckhand-owned OS
// image caches and rejects pre-existing final or partial files. The
// sidecar downloader still opens temp files with O_EXCL, but the policy
// check here keeps the RPC from being a generic "write file" primitive.
func validateDownloadDestPath(dest string) error {
	if dest == "" {
		return fmt.Errorf("dest is required")
	}
	if err := rejectDeviceOutputPath(dest); err != nil {
		return err
	}
	clean, err := filepath.Abs(filepath.Clean(dest))
	if err != nil {
		return fmt.Errorf("resolve dest %q: %w", dest, err)
	}
	if strings.Contains(clean, "..") {
		return fmt.Errorf("dest %q contains traversal", dest)
	}
	if filepath.Ext(clean) != ".img" {
		return fmt.Errorf("dest %q must end in .img", dest)
	}
	allowedRoots := managedDownloadRoots()
	if !isDirectChildOfAnyRoot(clean, allowedRoots) {
		return fmt.Errorf("dest %q is not under a Deckhand-managed OS image directory", dest)
	}
	parent := filepath.Dir(clean)
	if info, err := os.Lstat(parent); err == nil {
		if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
			return fmt.Errorf("download root %q must be a real directory", parent)
		}
	} else if !os.IsNotExist(err) {
		return fmt.Errorf("inspect download root %q: %w", parent, err)
	}
	if _, err := os.Lstat(clean); err == nil {
		return fmt.Errorf("dest %q already exists", dest)
	} else if !os.IsNotExist(err) {
		return fmt.Errorf("inspect dest %q: %w", dest, err)
	}
	part := clean + ".part"
	if _, err := os.Lstat(part); err == nil {
		return fmt.Errorf("partial dest %q already exists", part)
	} else if !os.IsNotExist(err) {
		return fmt.Errorf("inspect partial dest %q: %w", part, err)
	}
	return nil
}

func managedDownloadRoots() []string {
	h := host.Current()
	roots := []string{}
	for _, root := range []string{h.Cache, h.Data} {
		if root == "" {
			continue
		}
		if abs, err := filepath.Abs(filepath.Join(root, "Deckhand", "os-images")); err == nil {
			roots = append(roots, filepath.Clean(abs))
		}
	}
	if tmp := os.TempDir(); tmp != "" {
		if abs, err := filepath.Abs(filepath.Join(tmp, downloadTempRootName)); err == nil {
			roots = append(roots, filepath.Clean(abs))
		}
	}
	return roots
}

func isDirectChildOfAnyRoot(path string, roots []string) bool {
	parent := filepath.Dir(path)
	for _, root := range roots {
		if root != "" && parent == root {
			return true
		}
	}
	return false
}

func rejectDeviceOutputPath(path string) error {
	clean := filepath.Clean(path)
	devicePrefixes := []string{
		"/dev/sd", "/dev/nvme", "/dev/mmcblk", "/dev/disk",
		"/dev/rdisk", "/dev/loop", "/dev/vd",
	}
	for _, prefix := range devicePrefixes {
		if strings.HasPrefix(clean, prefix) {
			return fmt.Errorf("output %q must be a regular file path, not a device", path)
		}
	}
	if runtime.GOOS == "windows" &&
		(strings.HasPrefix(clean, `\\.\`) || strings.HasPrefix(clean, `//./`)) {
		return fmt.Errorf("output %q must be a regular file path, not a device", path)
	}
	return nil
}

// listDisksFn is the live OS enumeration. Tests substitute a stub via
// SetListDisksForTest so they can drive safety_check / write_image
// preflight without depending on hardware present on the test host.
var listDisksFn = disks.List

// SetListDisksForTest swaps the disk lister and returns a restore
// func. Production code must not call this.
func SetListDisksForTest(fn func(context.Context) ([]disks.DiskInfo, error)) func() {
	prev := listDisksFn
	listDisksFn = fn
	return func() { listDisksFn = prev }
}

// liveDiskByID re-probes the OS to fetch the authoritative DiskInfo
// for the given ID. Callers must use this rather than trusting any
// caller-supplied DiskInfo, since the supplied struct could fabricate
// safety-relevant fields (removable, mounted, size).
func liveDiskByID(ctx context.Context, id string) (*disks.DiskInfo, error) {
	all, err := listDisksFn(ctx)
	if err != nil {
		return nil, fmt.Errorf("enumerate disks: %w", err)
	}
	for i := range all {
		if all[i].ID == id {
			return &all[i], nil
		}
	}
	return nil, fmt.Errorf("disk %q not found in current enumeration", id)
}

func validateGitRef(ref string) error {
	if ref == "" {
		// Empty ref = use the remote's default branch, which go-git
		// resolves for us. That's fine.
		return nil
	}
	for _, r := range ref {
		switch {
		case r >= 'a' && r <= 'z',
			r >= 'A' && r <= 'Z',
			r >= '0' && r <= '9',
			r == '.' || r == '_' || r == '-' || r == '/':
			// allowed
		default:
			return fmt.Errorf("git ref %q contains disallowed character %q", ref, r)
		}
	}
	// No leading `-` (would look like a flag if ever spawned as a CLI
	// arg later), no `..` (ambiguous in ref syntax).
	if strings.HasPrefix(ref, "-") || strings.Contains(ref, "..") {
		return fmt.Errorf("git ref %q uses a disallowed sequence", ref)
	}
	return nil
}
