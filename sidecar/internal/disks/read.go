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

// ReadImage dd's [devicePath] into [outputPath], optionally hashing as it
// goes and emitting progress notifications via [note].
//
// Requires read access to the raw block device. On Windows this typically
// means the sidecar needs to have been launched with admin; on Linux the
// user must be in disk/sudo. The elevated helper performs this op when
// needed — this direct path exists for cases where elevation already
// applies (e.g., Linux root session).
type ReadProgress struct {
	BytesDone  int64 `json:"bytes_done"`
	BytesTotal int64 `json:"bytes_total"`
	Phase      string `json:"phase"`
}

func ReadImage(ctx context.Context, devicePath, outputPath string, note rpc.Notifier) (sha256Hex string, err error) {
	src, err := os.Open(devicePath)
	if err != nil {
		return "", fmt.Errorf("open device: %w", err)
	}
	defer src.Close()

	// Size on Windows raw device: Seek(0, io.SeekEnd) returns total bytes.
	var total int64
	if info, err := src.Stat(); err == nil && info.Size() > 0 {
		total = info.Size()
	} else if n, err := src.Seek(0, io.SeekEnd); err == nil {
		total = n
		_, _ = src.Seek(0, io.SeekStart)
	}

	dst, err := os.Create(outputPath)
	if err != nil {
		return "", fmt.Errorf("create output: %w", err)
	}
	defer dst.Close()

	h := sha256.New()
	buf := make([]byte, 4<<20) // 4 MiB
	var done int64
	lastNotified := int64(0)

	for {
		if ctx.Err() != nil {
			return "", ctx.Err()
		}
		n, rerr := src.Read(buf)
		if n > 0 {
			if _, werr := dst.Write(buf[:n]); werr != nil {
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

	if note != nil {
		note.Notify("progress", ReadProgress{
			BytesDone: done, BytesTotal: total, Phase: "done",
		})
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}
