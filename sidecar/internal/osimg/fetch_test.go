package osimg

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// recordingNotifier captures every Notify call so tests can assert on
// the per-phase progress stream without standing up a real RPC pipe.
type recordingNotifier struct {
	mu     sync.Mutex
	events []recorded
}

type recorded struct {
	method string
	params any
}

func (r *recordingNotifier) Notify(method string, params any) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.events = append(r.events, recorded{method, params})
}

func (r *recordingNotifier) phases() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]string, 0, len(r.events))
	for _, e := range r.events {
		if p, ok := e.params.(DownloadProgress); ok {
			out = append(out, p.Phase)
		}
	}
	return out
}

// serveBody stands up a fake HTTPS server that hands back `body` bytes
// with the given Content-Length. Returns the URL.
func serveBody(t *testing.T, body []byte) string {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(
		func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Length", fmt.Sprintf("%d", len(body)))
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write(body)
		},
	))
	t.Cleanup(srv.Close)
	return srv.URL + "/image.img"
}

func TestDownload_HappyPath_WritesFile_AndReturnsSha(t *testing.T) {
	body := []byte(strings.Repeat("X", 8<<20)) // 8 MiB
	url := serveBody(t, body)

	dest := filepath.Join(t.TempDir(), "out.img")
	note := &recordingNotifier{}

	got, err := Download(context.Background(), url, dest, "", note)
	if err != nil {
		t.Fatalf("Download: %v", err)
	}

	// Confirm the on-disk file matches what we served.
	onDisk, err := os.ReadFile(dest)
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	if len(onDisk) != len(body) {
		t.Fatalf("size mismatch: got %d, want %d", len(onDisk), len(body))
	}

	// SHA matches a fresh hash of what we sent.
	h := sha256.Sum256(body)
	want := hex.EncodeToString(h[:])
	if got != want {
		t.Fatalf("sha mismatch: got %s, want %s", got, want)
	}

	// At minimum we emitted a `done` phase at the end.
	phases := note.phases()
	if len(phases) == 0 || phases[len(phases)-1] != "done" {
		t.Fatalf("expected final phase `done`, got %v", phases)
	}
}

func TestDownload_ShaMismatch_Fails(t *testing.T) {
	url := serveBody(t, []byte("actual-bytes"))
	dest := filepath.Join(t.TempDir(), "out.img")
	_, err := Download(
		context.Background(),
		url,
		dest,
		"0000000000000000000000000000000000000000000000000000000000000000",
		nil,
	)
	if err == nil {
		t.Fatalf("want sha mismatch error, got nil")
	}
	if !strings.Contains(err.Error(), "sha256 mismatch") {
		t.Fatalf("unexpected error: %v", err)
	}
	// After a sha mismatch the destination must not exist - a future
	// caller must not find a corrupt file masquerading as a complete
	// download. This is the CRITICAL we are fixing.
	if _, statErr := os.Stat(dest); !os.IsNotExist(statErr) {
		t.Fatalf("expected dest to be missing after mismatch, got stat %v", statErr)
	}
	// And the .part file must also be gone.
	if _, statErr := os.Stat(dest + ".part"); !os.IsNotExist(statErr) {
		t.Fatalf("expected .part to be removed, got stat %v", statErr)
	}
}

func TestDownload_RejectsFileScheme(t *testing.T) {
	dest := filepath.Join(t.TempDir(), "out.img")
	cases := []string{
		// POSIX-style path (parses cleanly; must be rejected by the
		// scheme check).
		"file:///etc/shadow",
		// Windows-style path with backslashes (parses poorly; the
		// rejection comes from url.Parse itself which is still a safe
		// outcome - this URL never reaches the HTTP client).
		`file://C:\Windows\System32\drivers\etc\hosts`,
		// Other dangerous schemes.
		"ftp://evil.example/image.img",
		"ssh://root@evil.example/image.img",
		"javascript:alert(1)",
	}
	for _, u := range cases {
		t.Run(u, func(t *testing.T) {
			_, err := Download(context.Background(), u, dest, "", nil)
			if err == nil {
				t.Fatalf("expected reject for %q, got nil", u)
			}
			// Either the URL parser rejects it OR the scheme check
			// does. Both paths leave the sidecar safe - what we really
			// want to prove is that NO local or remote fetch occurred.
			if _, statErr := os.Stat(dest); !os.IsNotExist(statErr) {
				t.Fatalf("dest existed after reject for %q: %v", u, statErr)
			}
		})
	}
}

func TestDownload_RejectsEmptyHost(t *testing.T) {
	dest := filepath.Join(t.TempDir(), "out.img")
	_, err := Download(context.Background(), "https:///foo", dest, "", nil)
	if err == nil {
		t.Fatalf("want error for missing host, got nil")
	}
}

func TestDownload_CancelLeavesNoPartFile(t *testing.T) {
	// Server streams endlessly so we can cancel mid-flight.
	srv := httptest.NewServer(http.HandlerFunc(
		func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Length", "1073741824") // 1 GiB
			w.WriteHeader(http.StatusOK)
			chunk := make([]byte, 1024)
			for {
				if _, err := w.Write(chunk); err != nil {
					return
				}
				if f, ok := w.(http.Flusher); ok {
					f.Flush()
				}
			}
		},
	))
	t.Cleanup(srv.Close)

	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(50 * time.Millisecond)
		cancel()
	}()
	dest := filepath.Join(t.TempDir(), "out.img")
	if _, err := Download(ctx, srv.URL, dest, "", nil); err == nil {
		t.Fatalf("want cancellation error, got nil")
	}
	if _, statErr := os.Stat(dest); !os.IsNotExist(statErr) {
		t.Fatalf("cancelled download left dest in place: %v", statErr)
	}
	if _, statErr := os.Stat(dest + ".part"); !os.IsNotExist(statErr) {
		t.Fatalf("cancelled download left .part: %v", statErr)
	}
}

func TestDownload_Non200Status_Fails(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(
		func(w http.ResponseWriter, r *http.Request) {
			http.Error(w, "gone", http.StatusGone)
		},
	))
	t.Cleanup(srv.Close)

	dest := filepath.Join(t.TempDir(), "out.img")
	_, err := Download(
		context.Background(), srv.URL, dest, "", nil,
	)
	if err == nil {
		t.Fatalf("want status error, got nil")
	}
	if !strings.Contains(err.Error(), "unexpected status") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestDownload_Cancelled_ReturnsCtxErr(t *testing.T) {
	// Server that writes forever in 1 KiB chunks, so Download has
	// plenty of time to notice a cancellation.
	srv := httptest.NewServer(http.HandlerFunc(
		func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Length", "1073741824") // 1 GiB
			w.WriteHeader(http.StatusOK)
			chunk := make([]byte, 1024)
			for {
				if _, err := w.Write(chunk); err != nil {
					return
				}
				if f, ok := w.(http.Flusher); ok {
					f.Flush()
				}
			}
		},
	))
	t.Cleanup(srv.Close)

	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(50 * time.Millisecond)
		cancel()
	}()
	dest := filepath.Join(t.TempDir(), "out.img")
	_, err := Download(ctx, srv.URL, dest, "", nil)
	if err == nil {
		t.Fatalf("want cancellation error, got nil")
	}
}

// Make sure io.EOF on the response body isn't mistaken for an error.
func TestDownload_ZeroBytes_Works(t *testing.T) {
	url := serveBody(t, []byte{})
	dest := filepath.Join(t.TempDir(), "out.img")
	got, err := Download(context.Background(), url, dest, "", nil)
	if err != nil {
		t.Fatalf("Download: %v", err)
	}
	// sha of empty string.
	const emptySha = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
	if got != emptySha {
		t.Fatalf("sha: got %s, want %s", got, emptySha)
	}
	// Dest file exists and is empty.
	info, err := os.Stat(dest)
	if err != nil {
		t.Fatalf("Stat: %v", err)
	}
	if info.Size() != 0 {
		t.Fatalf("expected 0 bytes, got %d", info.Size())
	}
}

var _ = io.Reader(strings.NewReader(""))
