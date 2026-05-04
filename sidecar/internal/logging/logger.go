// Package logging wires the sidecar's slog.Logger to a rotated JSON
// log file under the host's data dir plus a duplicate stream to stderr
// (so a developer running the sidecar manually sees logs in their
// terminal too).
//
// Rotation is implemented in-process - we intentionally avoid pulling
// in a third-party rotator so the sidecar binary stays small and the
// behaviour is explicit/auditable. See rotateIfNeeded for the policy.
package logging

import (
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
)

// Default rotation parameters. Tests override them via the unexported
// fields on Options.
const (
	DefaultMaxFileBytes = 5 * 1024 * 1024 // 5 MiB
	DefaultMaxFiles     = 5
	DefaultLogName      = "deckhand-sidecar.log"
)

// Options lets tests tune rotation bounds without touching the public
// Init signature. Zero values mean "use the default".
type Options struct {
	MaxFileBytes int64
	MaxFiles     int
	Filename     string
}

func (o Options) resolved() Options {
	if o.MaxFileBytes <= 0 {
		o.MaxFileBytes = DefaultMaxFileBytes
	}
	if o.MaxFiles <= 0 {
		o.MaxFiles = DefaultMaxFiles
	}
	if o.Filename == "" {
		o.Filename = DefaultLogName
	}
	return o
}

// Init creates the log file under dataDir (mkdir -p first), wires a JSON
// slog.Handler that writes to both the file and stderr, and returns the
// logger plus a close function the caller must defer.
//
// dataDir should typically be host.Current().Data; it's a parameter so
// tests can point somewhere under t.TempDir().
func Init(dataDir string) (*slog.Logger, func() error, error) {
	return InitWithOptions(dataDir, Options{})
}

// InitWithOptions is Init with explicit rotation parameters. Used by
// tests; production callers should stick to Init.
func InitWithOptions(dataDir string, opts Options) (*slog.Logger, func() error, error) {
	opts = opts.resolved()
	if dataDir == "" {
		return nil, nil, fmt.Errorf("logging: dataDir is empty")
	}
	if err := os.MkdirAll(dataDir, 0o750); err != nil {
		return nil, nil, fmt.Errorf("logging: mkdir %q: %w", dataDir, err)
	}
	path := filepath.Join(dataDir, opts.Filename)

	rf, err := newRotatingFile(path, opts.MaxFileBytes, opts.MaxFiles)
	if err != nil {
		return nil, nil, err
	}

	// io.MultiWriter fans out every log line to both the rotating file
	// and stderr. The slog JSONHandler does not care about concurrency
	// itself - rotatingFile's mutex is what makes this safe.
	mw := io.MultiWriter(rf, os.Stderr)
	handler := slog.NewJSONHandler(mw, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	})
	logger := slog.New(handler)

	return logger, rf.Close, nil
}

// rotatingFile is a size-based rotator. Writes that would push the
// current file past maxBytes roll it to .1, shift older files one slot
// up, and drop anything past maxFiles.
type rotatingFile struct {
	mu       sync.Mutex
	path     string
	maxBytes int64
	maxFiles int
	f        *os.File
	written  int64
}

func newRotatingFile(path string, maxBytes int64, maxFiles int) (*rotatingFile, error) {
	rf := &rotatingFile{
		path:     path,
		maxBytes: maxBytes,
		maxFiles: maxFiles,
	}
	if err := rf.open(); err != nil {
		return nil, err
	}
	return rf, nil
}

func (r *rotatingFile) open() error {
	// 0o600: logs may contain disk paths, profile URLs, and SSH-auth
	// failure messages. Credentials are redacted upstream, but keep
	// the on-disk file user-readable only so a multi-user host can't
	// surface diagnostic data to a different account. The single
	// owning user (and root) can still tail the file directly.
	f, err := os.OpenFile(r.path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return fmt.Errorf("logging: open %q: %w", r.path, err)
	}
	st, err := f.Stat()
	if err != nil {
		_ = f.Close()
		return fmt.Errorf("logging: stat %q: %w", r.path, err)
	}
	r.f = f
	r.written = st.Size()
	return nil
}

// Write implements io.Writer. It is safe for concurrent callers; the
// mutex also guards the rotation check so two near-simultaneous writes
// cannot produce two rotations in a row.
func (r *rotatingFile) Write(p []byte) (int, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	if r.written+int64(len(p)) > r.maxBytes {
		if err := r.rotate(); err != nil {
			return 0, err
		}
	}
	n, err := r.f.Write(p)
	r.written += int64(n)
	return n, err
}

// Close flushes the current file. Name matches io.Closer so the caller
// can defer logger-close.
func (r *rotatingFile) Close() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.f == nil {
		return nil
	}
	err := r.f.Close()
	r.f = nil
	return err
}

// rotate closes the current file, shifts .N files to .(N+1) (dropping
// anything past maxFiles total files including the current one),
// renames path -> path.1, and opens a fresh path. Called under r.mu.
//
// With maxFiles=N we keep path + path.1 ... path.(N-1) on disk, so the
// highest backup index is N-1. Any existing path.(N-1) is removed
// before shifting so the resulting backup count stays within the cap.
func (r *rotatingFile) rotate() error {
	if err := r.f.Close(); err != nil {
		// Keep going - we still want to rotate so logging can continue.
		// Real errors on Close are extremely rare (ENOSPC-at-close
		// territory) and re-opening below will surface a durable issue.
		_ = err
	}
	r.f = nil

	maxBackupIdx := r.maxFiles - 1
	// Drop anything that would exceed the cap after shifting.
	if maxBackupIdx >= 1 {
		_ = os.Remove(backupName(r.path, maxBackupIdx))
	}

	// Shift oldest-first so we don't overwrite a file we still need.
	// Example for maxFiles=5 (maxBackupIdx=4): path.3 -> path.4,
	// path.2 -> path.3, path.1 -> path.2, then path -> path.1.
	for i := maxBackupIdx - 1; i >= 1; i-- {
		src := backupName(r.path, i)
		dst := backupName(r.path, i+1)
		if _, err := os.Stat(src); err != nil {
			continue
		}
		// Remove any stale destination so Rename succeeds on Windows.
		_ = os.Remove(dst)
		if err := os.Rename(src, dst); err != nil {
			return fmt.Errorf("logging: rotate %s -> %s: %w", src, dst, err)
		}
	}
	// Current file becomes .1, unless maxFiles is 1 in which case we
	// just truncate the current file (no history kept).
	if r.maxFiles > 1 {
		dst := backupName(r.path, 1)
		_ = os.Remove(dst)
		if err := os.Rename(r.path, dst); err != nil && !os.IsNotExist(err) {
			return fmt.Errorf("logging: rotate current -> .1: %w", err)
		}
	} else {
		_ = os.Remove(r.path)
	}
	r.written = 0
	return r.open()
}

func backupName(base string, i int) string {
	return fmt.Sprintf("%s.%d", base, i)
}

// existingBackups is exposed for tests; returns the list of rotated
// files currently on disk (path.1, path.2, ...), sorted.
func existingBackups(base string) []string {
	dir := filepath.Dir(base)
	name := filepath.Base(base)
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var out []string
	for _, e := range entries {
		if !strings.HasPrefix(e.Name(), name+".") {
			continue
		}
		out = append(out, filepath.Join(dir, e.Name()))
	}
	sort.Strings(out)
	return out
}
