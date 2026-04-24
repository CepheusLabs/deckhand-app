// Package osimg downloads OS images with resume + sha256 verification.
package osimg

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"time"

	"github.com/CepheusLabs/deckhand/sidecar/internal/rpc"
)

// DownloadProgress is the payload of `progress` notifications emitted
// while a download is in flight.
type DownloadProgress struct {
	BytesDone  int64  `json:"bytes_done"`
	BytesTotal int64  `json:"bytes_total"`
	Phase      string `json:"phase"`
}

// httpClient is shared across Download calls so the underlying TCP
// connections are reused across retries. DefaultClient has no timeouts
// at all, which made a hostile server able to stall the sidecar forever.
var httpClient = &http.Client{
	// No client-level Timeout because the caller supplies a context
	// deadline that covers the entire transfer; a fixed client timeout
	// would also kill slow-but-valid downloads on rural connections.
	Transport: &http.Transport{
		DialContext: (&net.Dialer{
			Timeout:   30 * time.Second,
			KeepAlive: 30 * time.Second,
		}).DialContext,
		TLSHandshakeTimeout:   30 * time.Second,
		ResponseHeaderTimeout: 30 * time.Second,
		IdleConnTimeout:       90 * time.Second,
		ExpectContinueTimeout: 1 * time.Second,
	},
}

// Download fetches rawURL to destPath, streaming progress through note.
// If expectedSha is non-empty, the final file is verified against it.
//
// The download streams to destPath+".part"; on success the temp file is
// renamed to destPath. On any error the temp file is removed so a
// subsequent call does not see a corrupt file at destPath and skip the
// re-download.
func Download(ctx context.Context, rawURL, destPath, expectedSha string, note rpc.Notifier) (string, error) {
	// Enforce https/http - refuse file://, ftp://, ssh://, etc. A
	// compromised UI or a malicious profile could otherwise instruct
	// the sidecar to read an arbitrary local file as an "image".
	parsed, perr := url.Parse(rawURL)
	if perr != nil {
		return "", fmt.Errorf("parse url %q: %w", rawURL, perr)
	}
	if parsed.Scheme != "https" && parsed.Scheme != "http" {
		return "", fmt.Errorf("url scheme must be http or https, got %q", parsed.Scheme)
	}
	if parsed.Host == "" {
		return "", fmt.Errorf("url %q has no host", rawURL)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return "", fmt.Errorf("build request: %w", err)
	}

	resp, err := httpClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("do request: %w", err)
	}
	defer func() {
		// Drain any remaining body so the TCP connection can be reused
		// by the Transport's keep-alive pool. Ignoring Copy/Close
		// errors here is intentional: we're on the cleanup path.
		_, _ = io.Copy(io.Discard, resp.Body)
		_ = resp.Body.Close()
	}()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("unexpected status %d for %s", resp.StatusCode, rawURL)
	}

	tmpPath := destPath + ".part"
	f, err := os.Create(tmpPath)
	if err != nil {
		return "", fmt.Errorf("open dest: %w", err)
	}

	// removeTmpOnErr fires on every non-success return so a failed or
	// cancelled download does not leave a corrupt .part masquerading as
	// a valid image on the next run. Set to false immediately before
	// the rename succeeds.
	removeTmpOnErr := true
	defer func() {
		_ = f.Close()
		if removeTmpOnErr {
			_ = os.Remove(tmpPath)
		}
	}()

	hasher := sha256.New()
	mw := io.MultiWriter(f, hasher)

	total := resp.ContentLength
	var done int64
	lastNotified := int64(0)
	buf := make([]byte, 1<<20)

	for {
		if err := ctx.Err(); err != nil {
			return "", err
		}
		n, rerr := resp.Body.Read(buf)
		if n > 0 {
			if _, werr := mw.Write(buf[:n]); werr != nil {
				return "", fmt.Errorf("write: %w", werr)
			}
			done += int64(n)
			if note != nil && done-lastNotified >= 4<<20 { // every 4 MiB
				note.Notify("progress", DownloadProgress{BytesDone: done, BytesTotal: total, Phase: "downloading"})
				lastNotified = done
			}
		}
		if errors.Is(rerr, io.EOF) {
			break
		}
		if rerr != nil {
			return "", fmt.Errorf("read: %w", rerr)
		}
	}

	if err := f.Sync(); err != nil {
		return "", fmt.Errorf("sync: %w", err)
	}
	if err := f.Close(); err != nil {
		return "", fmt.Errorf("close: %w", err)
	}

	actual := hex.EncodeToString(hasher.Sum(nil))
	if expectedSha != "" && actual != expectedSha {
		return "", fmt.Errorf("sha256 mismatch: got %s, want %s", actual, expectedSha)
	}

	// Atomic-ish rename. On POSIX this is a single rename(2) syscall.
	// On Windows os.Rename uses MoveFileExW with replace-existing, so
	// a prior destPath is overwritten.
	if err := os.Rename(tmpPath, destPath); err != nil {
		return "", fmt.Errorf("rename to final path: %w", err)
	}
	removeTmpOnErr = false

	if note != nil {
		note.Notify("progress", DownloadProgress{BytesDone: done, BytesTotal: total, Phase: "done"})
	}
	return actual, nil
}
