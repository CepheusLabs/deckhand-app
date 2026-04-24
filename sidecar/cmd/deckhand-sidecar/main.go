// Package main is the Deckhand sidecar entry point.
//
// The sidecar is a line-delimited JSON-RPC 2.0 server speaking over
// stdin/stdout. The Deckhand Flutter app spawns it as a child process at
// launch; it handles local disk I/O, sha256, shallow git clones, and
// HTTP fetches — operations Dart can't do portably without a lot of
// platform code.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/CepheusLabs/deckhand/sidecar/internal/disks"
	"github.com/CepheusLabs/deckhand/sidecar/internal/hash"
	"github.com/CepheusLabs/deckhand/sidecar/internal/host"
	"github.com/CepheusLabs/deckhand/sidecar/internal/osimg"
	"github.com/CepheusLabs/deckhand/sidecar/internal/profiles"
	"github.com/CepheusLabs/deckhand/sidecar/internal/rpc"
)

// Version is set at build time via -ldflags "-X main.Version=..."
var Version = "0.0.0-dev"

func main() {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	server := rpc.NewServer()
	// registerHandlers needs `cancel` so `shutdown` can tear the loop
	// down cleanly without killing in-flight handlers with os.Exit.
	registerHandlers(server, cancel)

	reader := bufio.NewReader(os.Stdin)

	fmt.Fprintf(os.Stderr, "[deckhand-sidecar] version=%s os=%s arch=%s pid=%d\n",
		Version, runtime.GOOS, runtime.GOARCH, os.Getpid())

	// Hand os.Stdout directly to Serve; the server owns its own
	// buffered writer + output mutex. Wrapping stdout twice at this
	// layer was dead code and could hide partial writes.
	if err := server.Serve(ctx, reader, os.Stdout); err != nil {
		fmt.Fprintf(os.Stderr, "[deckhand-sidecar] serve error: %v\n", err)
		os.Exit(1)
	}
}

func registerHandlers(s *rpc.Server, cancel context.CancelFunc) {
	// Lifecycle
	s.Register("ping", func(ctx context.Context, _ json.RawMessage, _ rpc.Notifier) (any, error) {
		return map[string]any{
			"sidecar_version": Version,
			"os":              runtime.GOOS,
			"arch":            runtime.GOARCH,
		}, nil
	})

	s.Register("version.compat", func(ctx context.Context, raw json.RawMessage, _ rpc.Notifier) (any, error) {
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
			"sidecar_version": Version,
			"ui_version":      req.UIVersion,
		}, nil
	})

	s.Register("host.info", func(ctx context.Context, _ json.RawMessage, _ rpc.Notifier) (any, error) {
		return host.Current(), nil
	})

	s.Register("shutdown", func(ctx context.Context, _ json.RawMessage, _ rpc.Notifier) (any, error) {
		// Cancel the Serve context so the loop exits naturally after the
		// response is flushed to stdout. This avoids the data race the
		// earlier `go os.Exit(0)` had with the response write, and lets
		// in-flight handlers finish (or respond to ctx cancellation)
		// instead of being hard-killed mid-download.
		cancel()
		return map[string]any{"ok": true}, nil
	})

	// Disks
	s.Register("disks.list", func(ctx context.Context, _ json.RawMessage, _ rpc.Notifier) (any, error) {
		infos, err := disks.List(ctx)
		if err != nil {
			return nil, err
		}
		return map[string]any{"disks": infos}, nil
	})

	s.Register("disks.hash", func(ctx context.Context, raw json.RawMessage, _ rpc.Notifier) (any, error) {
		var req struct {
			Path string `json:"path"`
		}
		if err := json.Unmarshal(raw, &req); err != nil {
			return nil, fmt.Errorf("decode params: %w", err)
		}
		// disks.hash is intended for image files Deckhand itself wrote
		// or downloaded (post-download verification), not arbitrary
		// paths. Enforce a safe subset to keep this from being a
		// generic "read file existence/contents" oracle.
		if err := validateHashPath(req.Path); err != nil {
			return nil, err
		}
		h, err := hash.SHA256(req.Path)
		if err != nil {
			return nil, err
		}
		return map[string]any{"sha256": h, "path": req.Path}, nil
	})

	s.Register("disks.read_image", func(ctx context.Context, raw json.RawMessage, note rpc.Notifier) (any, error) {
		var req struct {
			DeviceID string `json:"device_id"`
			Path     string `json:"path"`
			Output   string `json:"output"`
		}
		if err := json.Unmarshal(raw, &req); err != nil {
			return nil, fmt.Errorf("decode params: %w", err)
		}
		dev := req.Path
		if dev == "" {
			dev = `\\.\` + req.DeviceID
		}
		sha, err := disks.ReadImage(ctx, dev, req.Output, note)
		if err != nil {
			return nil, err
		}
		return map[string]any{"sha256": sha, "output": req.Output}, nil
	})

	s.Register("disks.write_image", func(ctx context.Context, raw json.RawMessage, _ rpc.Notifier) (any, error) {
		var req struct {
			ImagePath         string `json:"image_path"`
			DiskID            string `json:"disk_id"`
			ConfirmationToken string `json:"confirmation_token"`
		}
		if err := json.Unmarshal(raw, &req); err != nil {
			return nil, fmt.Errorf("decode params: %w", err)
		}
		if err := disks.WriteImage(ctx, req.ImagePath, req.DiskID, req.ConfirmationToken); err != nil {
			return nil, err
		}
		return map[string]any{"ok": true}, nil
	})

	// OS image download
	s.Register("os.download", func(ctx context.Context, raw json.RawMessage, note rpc.Notifier) (any, error) {
		var req struct {
			URL         string `json:"url"`
			Dest        string `json:"dest"`
			ExpectedSha string `json:"sha256"`
		}
		if err := json.Unmarshal(raw, &req); err != nil {
			return nil, fmt.Errorf("decode params: %w", err)
		}
		sha, err := osimg.Download(ctx, req.URL, req.Dest, req.ExpectedSha, note)
		if err != nil {
			return nil, err
		}
		return map[string]any{"sha256": sha, "path": req.Dest}, nil
	})

	// Profile fetch (go-git shallow clone)
	s.Register("profiles.fetch", func(ctx context.Context, raw json.RawMessage, _ rpc.Notifier) (any, error) {
		var req struct {
			RepoURL string `json:"repo_url"`
			Ref     string `json:"ref"`
			Dest    string `json:"dest"`
			Force   bool   `json:"force"`
		}
		if err := json.Unmarshal(raw, &req); err != nil {
			return nil, fmt.Errorf("decode params: %w", err)
		}
		// Reject local/ssh/git schemes. A compromised UI or a
		// malicious caller could otherwise point us at a file:// repo
		// to read local git state, or at an ssh:// host to exfiltrate
		// via an attacker-controlled SSH server.
		if err := validateRepoURL(req.RepoURL); err != nil {
			return nil, err
		}
		// Refs are limited to the charset git itself uses for branch +
		// tag names - lets us refuse anything that might trip tool
		// integrations down the line (even though go-git itself is
		// shell-free).
		if err := validateGitRef(req.Ref); err != nil {
			return nil, err
		}
		res, err := profiles.Fetch(ctx, req.RepoURL, req.Ref, req.Dest, req.Force)
		if err != nil {
			return nil, err
		}
		return res, nil
	})
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
	if u.Scheme != "https" && u.Scheme != "http" {
		return fmt.Errorf("repo_url scheme must be http or https, got %q", u.Scheme)
	}
	if u.Host == "" {
		return fmt.Errorf("repo_url %q has no host", raw)
	}
	return nil
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
