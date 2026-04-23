// Package main is deckhand-elevated-helper - a single-op Go binary the
// Deckhand Flutter UI launches with platform-native elevation (UAC on
// Windows, AuthorizationServices on macOS, pkexec on Linux) when it
// needs to write to a raw block device.
//
// Contract:
//   - One operation per invocation; exits when done.
//   - No persistent state.
//   - Args on the command line; no stdin.
//   - Progress + results to stdout as newline-delimited JSON.
//   - No network access (enforced: this binary uses no http/net packages).
//
// Usage:
//   deckhand-elevated-helper write-image \
//     --image <path> --target <disk_id> --token <confirmation_token> \
//     [--verify] [--sha256 <hex>]
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"runtime"
	"time"
)

var Version = "0.0.0-dev"

func main() {
	if len(os.Args) < 2 {
		fatalf("usage: deckhand-elevated-helper <op> [flags]")
	}

	op := os.Args[1]
	args := os.Args[2:]

	switch op {
	case "write-image":
		runWriteImage(args)
	case "version":
		emitJSON(map[string]any{"event": "version", "version": Version, "os": runtime.GOOS, "arch": runtime.GOARCH})
	default:
		fatalf("unknown op %q", op)
	}
}

func runWriteImage(args []string) {
	fs := flag.NewFlagSet("write-image", flag.ExitOnError)
	image := fs.String("image", "", "path to the source image file")
	target := fs.String("target", "", "target disk id, e.g. PhysicalDrive3 on Windows, /dev/sde on Linux, /dev/rdisk4 on macOS")
	token := fs.String("token", "", "single-use confirmation token issued by the UI")
	verify := fs.Bool("verify", true, "read the written disk back and compare sha256")
	expectedSha := fs.String("sha256", "", "optional expected sha256 of the image (post-write verification compares against this)")
	_ = fs.Parse(args)

	if *image == "" || *target == "" || *token == "" {
		fatalf("write-image requires --image, --target, and --token")
	}

	// The confirmation token's format is opaque to the helper; we only
	// validate it's present + non-trivial. The actual single-use/TTL
	// enforcement happens in the UI's SecurityService, which has already
	// been consulted by the time this binary is launched.
	if len(*token) < 16 {
		fatalf("token is implausibly short; refusing")
	}

	devicePath := targetToDevicePath(*target)
	emitJSON(map[string]any{"event": "preparing", "device": devicePath, "image": *image})

	src, err := os.Open(*image)
	if err != nil {
		fatalf("open image: %v", err)
	}
	defer src.Close()

	// Total size for progress reporting.
	var total int64
	if info, err := src.Stat(); err == nil {
		total = info.Size()
	}

	dst, err := os.OpenFile(devicePath, os.O_RDWR, 0)
	if err != nil {
		fatalf("open device: %v", err)
	}
	defer dst.Close()

	hasher := sha256.New()
	mw := io.MultiWriter(dst, hasher)

	buf := make([]byte, 4<<20) // 4 MiB
	var done int64
	lastEmit := time.Now()

	for {
		n, rerr := src.Read(buf)
		if n > 0 {
			if _, werr := mw.Write(buf[:n]); werr != nil {
				fatalf("write: %v", werr)
			}
			done += int64(n)
			if time.Since(lastEmit) > 250*time.Millisecond {
				emitJSON(map[string]any{
					"event":       "progress",
					"phase":       "writing",
					"bytes_done":  done,
					"bytes_total": total,
				})
				lastEmit = time.Now()
			}
		}
		if errors.Is(rerr, io.EOF) {
			break
		}
		if rerr != nil {
			fatalf("read image: %v", rerr)
		}
	}

	if err := dst.Sync(); err != nil {
		fatalf("sync: %v", err)
	}

	srcSha := hex.EncodeToString(hasher.Sum(nil))
	if *expectedSha != "" && srcSha != *expectedSha {
		fatalf("image sha256 mismatch (got %s, want %s) - aborting before verification pass", srcSha, *expectedSha)
	}

	emitJSON(map[string]any{
		"event":      "progress",
		"phase":      "write-complete",
		"bytes_done": done, "bytes_total": total, "sha256": srcSha,
	})

	if *verify {
		verifySha, err := verifyDevice(devicePath, done)
		if err != nil {
			fatalf("verify: %v", err)
		}
		if verifySha != srcSha {
			fatalf("verification mismatch: disk sha %s != image sha %s", verifySha, srcSha)
		}
		emitJSON(map[string]any{"event": "progress", "phase": "verified", "sha256": verifySha})
	}

	emitJSON(map[string]any{"event": "done", "sha256": srcSha, "bytes": done})
}

func verifyDevice(devicePath string, expectBytes int64) (string, error) {
	f, err := os.Open(devicePath)
	if err != nil {
		return "", fmt.Errorf("open for verify: %w", err)
	}
	defer f.Close()

	h := sha256.New()
	buf := make([]byte, 4<<20)
	var done int64
	for done < expectBytes {
		n, rerr := f.Read(buf)
		if n > 0 {
			// Only hash the bytes we actually wrote.
			remaining := expectBytes - done
			if int64(n) > remaining {
				n = int(remaining)
			}
			h.Write(buf[:n])
			done += int64(n)
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			return "", rerr
		}
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func emitJSON(v any) {
	b, err := json.Marshal(v)
	if err != nil {
		return
	}
	fmt.Println(string(b))
}

func fatalf(format string, args ...any) {
	msg := fmt.Sprintf(format, args...)
	emitJSON(map[string]any{"event": "error", "message": msg})
	os.Exit(1)
}
