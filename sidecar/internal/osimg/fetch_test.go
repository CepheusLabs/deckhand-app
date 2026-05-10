package osimg

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/ulikunitz/xz"
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

func (r *recordingNotifier) progressEvents() []DownloadProgress {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]DownloadProgress, 0, len(r.events))
	for _, e := range r.events {
		if p, ok := e.params.(DownloadProgress); ok {
			out = append(out, p)
		}
	}
	return out
}

// serveBody stands up a fake HTTPS server that hands back `body` bytes
// with the given Content-Length. Returns the URL.
func serveBody(t *testing.T, body []byte) string {
	return serveBodyAt(t, body, "/image.img")
}

func serveBodyAt(t *testing.T, body []byte, path string) string {
	t.Helper()
	srv := httptest.NewTLSServer(http.HandlerFunc(
		func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path != path {
				http.NotFound(w, r)
				return
			}
			w.Header().Set("Content-Length", fmt.Sprintf("%d", len(body)))
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write(body)
		},
	))
	t.Cleanup(srv.Close)
	useHTTPClient(t, srv.Client())
	return srv.URL + path
}

func useHTTPClient(t *testing.T, client *http.Client) {
	t.Helper()
	prev := httpClient
	client.CheckRedirect = checkDownloadRedirect
	httpClient = client
	t.Cleanup(func() { httpClient = prev })
}

func TestDownloadRejectsPlainHTTPAndHTTPRedirect(t *testing.T) {
	httpTarget := httptest.NewServer(http.HandlerFunc(
		func(w http.ResponseWriter, r *http.Request) {
			_, _ = w.Write([]byte("not allowed"))
		},
	))
	t.Cleanup(httpTarget.Close)

	httpsRedirector := httptest.NewTLSServer(http.HandlerFunc(
		func(w http.ResponseWriter, r *http.Request) {
			http.Redirect(w, r, httpTarget.URL+"/image.img", http.StatusFound)
		},
	))
	t.Cleanup(httpsRedirector.Close)
	useHTTPClient(t, httpsRedirector.Client())

	for _, rawURL := range []string{httpTarget.URL + "/image.img", httpsRedirector.URL + "/image.img"} {
		t.Run(rawURL, func(t *testing.T) {
			dest := filepath.Join(t.TempDir(), "out.img")
			_, err := Download(context.Background(), rawURL, dest, "", nil)
			if err == nil {
				t.Fatalf("expected %q to be rejected", rawURL)
			}
			if _, statErr := os.Stat(dest); !os.IsNotExist(statErr) {
				t.Fatalf("dest existed after reject: %v", statErr)
			}
		})
	}
}

func TestValidateDownloadURLRequiresApprovedHost(t *testing.T) {
	good, _ := url.Parse("https://github.com/CepheusLabs/deckhand/releases/download/image.img")
	if err := validateDownloadURL(good); err != nil {
		t.Fatalf("expected approved host to pass: %v", err)
	}
	bad, _ := url.Parse("https://evil.example/image.img")
	if err := validateDownloadURL(bad); err == nil {
		t.Fatalf("expected unapproved host to be rejected")
	}
}

func TestDownloadRejectsOversizedContentLengthAndOverflow(t *testing.T) {
	t.Run("content-length", func(t *testing.T) {
		srv := httptest.NewTLSServer(http.HandlerFunc(
			func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Length", fmt.Sprintf("%d", maxDownloadBytes+1))
				w.WriteHeader(http.StatusOK)
			},
		))
		t.Cleanup(srv.Close)
		useHTTPClient(t, srv.Client())

		_, err := Download(context.Background(), srv.URL, filepath.Join(t.TempDir(), "out.img"), "", nil)
		if err == nil || !strings.Contains(err.Error(), "download is too large") {
			t.Fatalf("expected size rejection, got %v", err)
		}
	})

	t.Run("stream-overflow", func(t *testing.T) {
		prev := maxDownloadBytes
		maxDownloadBytes = 4
		t.Cleanup(func() { maxDownloadBytes = prev })
		srv := httptest.NewTLSServer(http.HandlerFunc(
			func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Length", "5")
				w.WriteHeader(http.StatusOK)
				_, _ = w.Write([]byte("12345"))
			},
		))
		t.Cleanup(srv.Close)
		useHTTPClient(t, srv.Client())

		dest := filepath.Join(t.TempDir(), "out.img")
		_, err := Download(context.Background(), srv.URL, dest, "", nil)
		if err == nil || (!strings.Contains(err.Error(), "download exceeded") && !strings.Contains(err.Error(), "download is too large")) {
			t.Fatalf("expected overflow/size rejection, got %v", err)
		}
		if _, statErr := os.Stat(dest + ".part"); !os.IsNotExist(statErr) {
			t.Fatalf("overflow left .part file: %v", statErr)
		}
	})
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
	events := note.progressEvents()
	if len(events) == 0 {
		t.Fatalf("expected progress notifications")
	}
	if events[0] != (DownloadProgress{BytesDone: 0, BytesTotal: int64(len(body)), Phase: "downloading"}) {
		t.Fatalf("first progress = %+v, want initial downloading event", events[0])
	}
	var finalDownload *DownloadProgress
	for i := range events {
		if events[i].Phase == "downloading" && events[i].BytesDone == int64(len(body)) {
			finalDownload = &events[i]
		}
	}
	if finalDownload == nil {
		t.Fatalf("expected final downloading progress for %d bytes, got %+v", len(body), events)
	}
	phases := note.phases()
	if len(phases) == 0 || phases[len(phases)-1] != "done" {
		t.Fatalf("expected final phase `done`, got %v", phases)
	}
}

func TestDownload_DecompressesXZAssetsToRawImage(t *testing.T) {
	raw := []byte("raw disk image bytes")
	var compressed bytes.Buffer
	xw, err := xz.NewWriter(&compressed)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := xw.Write(raw); err != nil {
		t.Fatal(err)
	}
	if err := xw.Close(); err != nil {
		t.Fatal(err)
	}
	url := serveBodyAt(t, compressed.Bytes(), "/image.img.xz")
	compressedSum := sha256.Sum256(compressed.Bytes())
	expectedArtifactSha := hex.EncodeToString(compressedSum[:])
	rawSum := sha256.Sum256(raw)
	expectedImageSha := hex.EncodeToString(rawSum[:])

	dest := filepath.Join(t.TempDir(), "out.img")
	got, err := Download(context.Background(), url, dest, expectedArtifactSha, nil)
	if err != nil {
		t.Fatalf("Download: %v", err)
	}
	if got != expectedImageSha {
		t.Fatalf("returned sha = %s, want raw image sha %s", got, expectedImageSha)
	}
	onDisk, err := os.ReadFile(dest)
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	if !bytes.Equal(onDisk, raw) {
		t.Fatalf("dest bytes = %q, want raw image bytes", onDisk)
	}
	if bytes.HasPrefix(onDisk, []byte{xzMagic0, xzMagic1, xzMagic2, xzMagic3, xzMagic4, xzMagic5}) {
		t.Fatalf("dest still contains xz bytes")
	}
}

func TestDownloadReportsXZExtractionProgressWithUncompressedTotal(t *testing.T) {
	raw := bytes.Repeat([]byte("raw disk image block\n"), 600000)
	var compressed bytes.Buffer
	xw, err := xz.NewWriter(&compressed)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := xw.Write(raw); err != nil {
		t.Fatal(err)
	}
	if err := xw.Close(); err != nil {
		t.Fatal(err)
	}
	url := serveBodyAt(t, compressed.Bytes(), "/image.img.xz")
	compressedSum := sha256.Sum256(compressed.Bytes())
	expectedArtifactSha := hex.EncodeToString(compressedSum[:])

	dest := filepath.Join(t.TempDir(), "out.img")
	note := &recordingNotifier{}
	if _, err := Download(context.Background(), url, dest, expectedArtifactSha, note); err != nil {
		t.Fatalf("Download: %v", err)
	}

	var extractionEvents []DownloadProgress
	for _, event := range note.progressEvents() {
		if event.Phase == "extracting" {
			extractionEvents = append(extractionEvents, event)
		}
	}
	if len(extractionEvents) == 0 {
		t.Fatalf("expected extracting progress events, got phases %v", note.phases())
	}
	if extractionEvents[0].BytesDone != 0 {
		t.Fatalf("first extracting event bytes done = %d, want 0", extractionEvents[0].BytesDone)
	}
	if extractionEvents[len(extractionEvents)-1].BytesDone != int64(len(raw)) {
		t.Fatalf(
			"last extracting event bytes done = %d, want %d",
			extractionEvents[len(extractionEvents)-1].BytesDone,
			len(raw),
		)
	}
	for _, event := range extractionEvents {
		if event.BytesTotal != int64(len(raw)) {
			t.Fatalf("extracting total = %d, want %d", event.BytesTotal, len(raw))
		}
		if event.BytesDone < 0 || event.BytesDone > event.BytesTotal {
			t.Fatalf("extracting bytes done out of range: %+v", event)
		}
	}
}

func TestDownloadReportsXZExtractionProgressWhenIndexProbeFails(t *testing.T) {
	oldProbe := probeXZUncompressedSize
	probeXZUncompressedSize = func(string) (int64, bool, error) {
		return 0, false, errors.New("unsupported xz index")
	}
	t.Cleanup(func() {
		probeXZUncompressedSize = oldProbe
	})

	raw := bytes.Repeat([]byte("fallback-counted raw image\n"), 50000)
	var compressed bytes.Buffer
	xw, err := xz.NewWriter(&compressed)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := xw.Write(raw); err != nil {
		t.Fatal(err)
	}
	if err := xw.Close(); err != nil {
		t.Fatal(err)
	}
	url := serveBodyAt(t, compressed.Bytes(), "/image.img.xz")
	compressedSum := sha256.Sum256(compressed.Bytes())
	expectedArtifactSha := hex.EncodeToString(compressedSum[:])

	dest := filepath.Join(t.TempDir(), "out.img")
	note := &recordingNotifier{}
	if _, err := Download(context.Background(), url, dest, expectedArtifactSha, note); err != nil {
		t.Fatalf("Download: %v", err)
	}

	var extractionEvents []DownloadProgress
	for _, event := range note.progressEvents() {
		if event.Phase == "extracting" {
			extractionEvents = append(extractionEvents, event)
		}
	}
	if len(extractionEvents) == 0 {
		t.Fatalf("expected extracting progress events, got phases %v", note.phases())
	}
	for _, event := range extractionEvents {
		if event.BytesTotal != int64(len(raw)) {
			t.Fatalf("extracting total = %d, want %d", event.BytesTotal, len(raw))
		}
	}
}

func TestDecompressXZHonorsCanceledContext(t *testing.T) {
	var compressed bytes.Buffer
	xw, err := xz.NewWriter(&compressed)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := xw.Write([]byte("raw disk image")); err != nil {
		t.Fatal(err)
	}
	if err := xw.Close(); err != nil {
		t.Fatal(err)
	}

	dir := t.TempDir()
	source := filepath.Join(dir, "image.img.xz")
	dest := filepath.Join(dir, "image.img")
	if err := os.WriteFile(source, compressed.Bytes(), 0o600); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	if _, _, err := decompressXZ(ctx, source, dest, &recordingNotifier{}); !errors.Is(err, context.Canceled) {
		t.Fatalf("decompressXZ error = %v, want context canceled", err)
	}
	if _, err := os.Stat(dest); !os.IsNotExist(err) {
		t.Fatalf("dest exists after canceled extraction: %v", err)
	}
}

func TestDownload_ReusesVerifiedXZDownloadPartWithoutNetwork(t *testing.T) {
	raw := []byte("raw disk image bytes from existing compressed partial")
	var compressed bytes.Buffer
	xw, err := xz.NewWriter(&compressed)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := xw.Write(raw); err != nil {
		t.Fatal(err)
	}
	if err := xw.Close(); err != nil {
		t.Fatal(err)
	}

	var requestCount int
	srv := httptest.NewTLSServer(http.HandlerFunc(
		func(w http.ResponseWriter, r *http.Request) {
			requestCount++
			http.Error(w, "should not fetch", http.StatusInternalServerError)
		},
	))
	t.Cleanup(srv.Close)
	useHTTPClient(t, srv.Client())

	dest := filepath.Join(t.TempDir(), "out.img")
	if err := os.WriteFile(dest+".download.part", compressed.Bytes(), 0o600); err != nil {
		t.Fatalf("write download part: %v", err)
	}
	compressedSum := sha256.Sum256(compressed.Bytes())
	rawSum := sha256.Sum256(raw)

	got, err := Download(
		context.Background(),
		srv.URL+"/image.img.xz",
		dest,
		hex.EncodeToString(compressedSum[:]),
		nil,
	)
	if err != nil {
		t.Fatalf("Download: %v", err)
	}
	if requestCount != 0 {
		t.Fatalf("expected no network request, got %d", requestCount)
	}
	if got != hex.EncodeToString(rawSum[:]) {
		t.Fatalf("returned sha = %s, want raw image sha", got)
	}
	onDisk, err := os.ReadFile(dest)
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	if !bytes.Equal(onDisk, raw) {
		t.Fatalf("dest bytes = %q, want raw image bytes", onDisk)
	}
	if _, err := os.Lstat(dest + ".download.part"); !os.IsNotExist(err) {
		t.Fatalf("expected verified compressed partial to be removed after extraction, got %v", err)
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

func TestDownload_RejectsExistingDestination(t *testing.T) {
	body := []byte("actual-bytes")
	url := serveBody(t, body)
	dest := filepath.Join(t.TempDir(), "out.img")
	if err := os.WriteFile(dest, []byte("existing"), 0o600); err != nil {
		t.Fatalf("write existing dest: %v", err)
	}
	sum := sha256.Sum256(body)
	_, err := Download(context.Background(), url, dest, hex.EncodeToString(sum[:]), nil)
	if err == nil {
		t.Fatalf("want existing destination error, got nil")
	}
	got, readErr := os.ReadFile(dest)
	if readErr != nil {
		t.Fatalf("read dest: %v", readErr)
	}
	if string(got) != "existing" {
		t.Fatalf("destination was overwritten: %q", got)
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
	srv := httptest.NewTLSServer(http.HandlerFunc(
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
	useHTTPClient(t, srv.Client())

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
	srv := httptest.NewTLSServer(http.HandlerFunc(
		func(w http.ResponseWriter, r *http.Request) {
			http.Error(w, "gone", http.StatusGone)
		},
	))
	t.Cleanup(srv.Close)
	useHTTPClient(t, srv.Client())

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
	srv := httptest.NewTLSServer(http.HandlerFunc(
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
	useHTTPClient(t, srv.Client())

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
