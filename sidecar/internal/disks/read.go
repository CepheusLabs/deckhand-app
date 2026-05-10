package disks

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"

	"github.com/CepheusLabs/deckhand/sidecar/internal/rpc"
)

// ReadProgress is the JSON shape emitted via [rpc.Notifier] while
// [ReadImage] runs. `Phase` is "reading" during the dd loop and
// "done" once the final byte has been hashed.
type ReadProgress struct {
	BytesDone  int64  `json:"bytes_done"`
	BytesTotal int64  `json:"bytes_total"`
	Phase      string `json:"phase"`
}

// ReadImage `dd`s [devicePath] into [outputPath], hashing as it goes
// and emitting progress notifications via [note].
//
// Requires read access to the raw block device. On Windows this
// typically means the sidecar needs to have been launched with admin;
// on Linux the user must be in disk/sudo. The elevated helper
// performs this op when needed — this direct path exists for cases
// where elevation already applies (e.g. a Linux root session).
func ReadImage(ctx context.Context, devicePath, outputPath string, note rpc.Notifier) (sha256Hex string, err error) {
	src, err := os.Open(devicePath)
	if err != nil {
		return "", fmt.Errorf("open device: %w", err)
	}
	defer func() { _ = src.Close() }()

	// Size on Windows raw device: Seek(0, io.SeekEnd) returns total bytes.
	var total int64
	if info, err := src.Stat(); err == nil && info.Size() > 0 {
		total = info.Size()
	} else if n, err := src.Seek(0, io.SeekEnd); err == nil {
		total = n
		_, _ = src.Seek(0, io.SeekStart)
	}

	dst, err := os.OpenFile(outputPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return "", fmt.Errorf("create output: %w", err)
	}
	completed := false
	defer func() {
		_ = dst.Close()
		if !completed {
			_ = os.Remove(outputPath)
		}
	}()

	h := sha256.New()
	buf := make([]byte, 4<<20) // 4 MiB
	var done int64
	lastNotified := int64(0)
	if note != nil {
		note.Notify("progress", ReadProgress{
			BytesDone: 0, BytesTotal: total, Phase: "reading",
		})
	}

	for {
		if ctx.Err() != nil {
			return "", ctx.Err()
		}
		n, rerr := src.Read(buf)
		if n > 0 {
			if werr := writeAll(dst, buf[:n]); werr != nil {
				return "", fmt.Errorf("write: %w", werr)
			}
			h.Write(buf[:n])
			done += int64(n)
			if note != nil && done-lastNotified >= 16<<20 { // every 16 MiB
				note.Notify("progress", ReadProgress{
					BytesDone: done, BytesTotal: total, Phase: "reading",
				})
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

	if err := dst.Sync(); err != nil {
		return "", fmt.Errorf("sync output: %w", err)
	}
	completed = true
	if note != nil {
		note.Notify("progress", ReadProgress{
			BytesDone: done, BytesTotal: total, Phase: "done",
		})
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func writeAll(dst io.Writer, p []byte) error {
	for len(p) > 0 {
		n, err := dst.Write(p)
		if n > 0 {
			p = p[n:]
		}
		if err != nil {
			return err
		}
		if n == 0 {
			return io.ErrShortWrite
		}
	}
	return nil
}
