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
//
//	deckhand-elevated-helper write-image \
//	  --image <path> --target <disk_id> --token-file <path> \
//	  [--verify] [--sha256 <hex>]
//
// The confirmation token is supplied via a 0600-mode file rather than
// a CLI argument so it does not appear in /proc/<pid>/cmdline or the
// equivalent OS process table. The helper reads the file once and
// removes it before any other I/O. The unprivileged controller consumes
// the token before launch; this process treats it as a launch nonce and
// relies on the controller's live disk safety preflight for authorization.
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
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"
)

// Version is set at build time via -ldflags "-X main.Version=...".
var Version = "0.0.0-dev"

// eventsOut is the destination the helper writes its line-delimited
// JSON events to. By default it's stdout; --events-file <path>
// switches it to an append-mode file. The latter is load-bearing on
// Windows: PowerShell's `Start-Process -Verb RunAs` doesn't honor
// -RedirectStandardOutput because the elevated child is spawned by
// Windows itself (via ShellExecuteEx) rather than by PowerShell, and
// file handles don't cross the elevation boundary. A direct file
// path bypasses that — both the unelevated parent (writing the path
// it just created) and the elevated child (writing events into it)
// end up at the same on-disk file.
var eventsOut io.Writer = os.Stdout

func main() {
	if len(os.Args) < 2 {
		fatalf("usage: deckhand-elevated-helper <op> [flags]")
	}

	op := os.Args[1]
	args := os.Args[2:]

	// Pre-scan args for --events-file so emitJSON works for ALL ops
	// (write-image, read-image, errors during arg parse, etc.) and so
	// the per-op flag.Parse doesn't have to know about it. Removing
	// the consumed pair from args means the per-op flagset never sees
	// the unknown flag.
	for i := 0; i < len(args); i++ {
		if args[i] == "--events-file" && i+1 < len(args) {
			f, err := os.OpenFile(
				args[i+1],
				os.O_WRONLY|os.O_CREATE|os.O_APPEND,
				0o600,
			)
			if err != nil {
				// Fall back to a sibling .err file so the parent has
				// SOMETHING to read when --events-file is unwritable
				// (path mangled by ShellExecuteEx, ACL denial under
				// elevation, etc.). Without this the parent sees
				// "exit 0, no events" with no clue.
				errPath := args[i+1] + ".openerr"
				if ef, ferr := os.Create(errPath); ferr == nil {
					fmt.Fprintf(ef,
						"helper could not open events-file %q: %v\n",
						args[i+1], err)
					_ = ef.Close()
				}
				fmt.Fprintf(os.Stderr,
					"open events-file %q: %v\n", args[i+1], err)
				os.Exit(2)
			}
			eventsOut = f
			args = append(args[:i], args[i+2:]...)
			break
		}
	}

	// Pre-scan for --watchdog-pid <pid>. The Flutter parent passes
	// its own PID; if the parent dies (user closes Deckhand mid-op,
	// crash, etc.) we self-terminate instead of continuing to write
	// the disk in the background. Without this, an aborted UI flow
	// leaves the elevated process running until the disk write
	// finishes naturally — surprising behaviour the user can't
	// observe or cancel because the unprivileged parent is no longer
	// allowed to terminate the elevated child.
	//
	// Polled every 2s in a goroutine via parentAlive (platform code
	// in watchdog_{windows,unix}.go). On parent-gone, fatalf so the
	// last event the parent's events-file would have captured is a
	// proper "error" record — except the parent is gone, so it'll
	// only show up in a debug bundle for forensics.
	for i := 0; i < len(args); i++ {
		if args[i] == "--watchdog-pid" && i+1 < len(args) {
			if pid, perr := strconv.Atoi(args[i+1]); perr == nil && pid > 0 {
				go runParentWatchdog(pid)
			}
			args = append(args[:i], args[i+2:]...)
			break
		}
	}

	// Sentinel: write a "started" event the moment we have eventsOut
	// configured. This proves the helper actually ran, isolated from
	// any per-op crash. If the parent sees this event but no
	// progress/done, the helper got past arg parse but the op body
	// failed. If the parent sees no events at all, the helper was
	// never launched, the elevation failed silently, or
	// --events-file was empty/unwritable.
	emitJSON(map[string]any{
		"event":   "started",
		"op":      op,
		"pid":     os.Getpid(),
		"version": Version,
	})

	switch op {
	case "write-image":
		runWriteImage(args)
	case "read-image":
		runReadImage(args)
	case "hash-device":
		runHashDevice(args)
	case "version":
		emitJSON(map[string]any{"event": "version", "version": Version, "os": runtime.GOOS, "arch": runtime.GOARCH})
	default:
		fatalf("unknown op %q", op)
	}
}

// runReadImage opens [target] for raw read and streams its bytes into
// [output], hashing as it goes. Counterpart to runWriteImage for the
// "back up the eMMC before we flash" flow on platforms where the
// sidecar can't open raw devices unprivileged (Windows is the
// load-bearing case — `\\.\PHYSICALDRIVE3` returns "Access is denied"
// without admin).
func runReadImage(args []string) {
	fs := flag.NewFlagSet("read-image", flag.ExitOnError)
	target := fs.String("target", "", "source disk id, e.g. PhysicalDrive3 on Windows, /dev/sde on Linux, /dev/rdisk4 on macOS")
	output := fs.String("output", "", "absolute path of the image file to write")
	outputRoot := fs.String("output-root", "", "Deckhand-owned backup directory containing the output file")
	tokenFile := fs.String("token-file", "", "path to a 0600-mode file containing the UI-issued confirmation token; deleted on read")
	cancelFile := fs.String("cancel-file", "", "optional regular file; operation aborts when the file disappears")
	totalBytesHint := fs.Int64("total-bytes", 0, "optional size hint for progress reporting; used as bytes_total when the device handle reports 0 (Windows raw devices via Stat/Seek both return 0)")
	if err := fs.Parse(args); err != nil {
		fatalf("parse flags: %v", err)
	}

	fatalIfCanceled(*cancelFile, nil)
	if *target == "" || *output == "" || *outputRoot == "" || *tokenFile == "" {
		fatalf("read-image requires --target, --output, --output-root, and --token-file")
	}

	token, err := readAndRemoveTokenFile(*tokenFile)
	if err != nil {
		fatalf("read token: %v", err)
	}
	if len(token) < 16 {
		fatalf("token is implausibly short; refusing")
	}
	if err := validateBackupOutputPath(*outputRoot, *output); err != nil {
		fatalf("validate output: %v", err)
	}
	fatalIfCanceled(*cancelFile, nil)

	devicePath, err := targetToDevicePath(*target)
	if err != nil {
		fatalf("validate target: %v", err)
	}
	emitJSON(map[string]any{"event": "preparing", "device": devicePath, "output": *output})

	src, err := os.Open(devicePath)
	if err != nil {
		fatalf("open device: %v", err)
	}
	defer func() { _ = src.Close() }()

	// Total size for progress reporting. Windows raw devices report 0
	// from Stat AND from Seek(end) — opening \\.\PhysicalDriveN as a
	// regular file gives us a working Read() but neither size probe.
	// When the caller passes --total-bytes (the UI already has the
	// real size from listDisks() upstream), use that as the
	// authoritative total so the UI's progress bar can move and the
	// "X of Y" label means something.
	var total int64
	if info, statErr := src.Stat(); statErr == nil && info.Size() > 0 {
		total = info.Size()
	} else if n, seekErr := src.Seek(0, io.SeekEnd); seekErr == nil && n > 0 {
		total = n
		_, _ = src.Seek(0, io.SeekStart)
	}
	if total == 0 && *totalBytesHint > 0 {
		total = *totalBytesHint
	}

	dst, err := os.OpenFile(*output, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		fatalf("create output: %v", err)
	}
	defer func() { _ = dst.Close() }()
	cancelCleanup := func() {
		_ = src.Close()
		_ = dst.Close()
		_ = os.Remove(*output)
	}

	hasher := sha256.New()
	buf := make([]byte, 4<<20)
	var done int64
	lastEmit := time.Now()

	for {
		fatalIfCanceled(*cancelFile, cancelCleanup)
		n, rerr := src.Read(buf)
		if n > 0 {
			if _, werr := dst.Write(buf[:n]); werr != nil {
				fatalf("write output: %v", werr)
			}
			hasher.Write(buf[:n])
			done += int64(n)
			if time.Since(lastEmit) > 250*time.Millisecond {
				emitJSON(map[string]any{
					"event":       "progress",
					"phase":       "reading",
					"bytes_done":  done,
					"bytes_total": total,
				})
				lastEmit = time.Now()
			}
		}
		fatalIfCanceled(*cancelFile, cancelCleanup)
		if errors.Is(rerr, io.EOF) {
			break
		}
		if rerr != nil {
			fatalf("read device after %d of %d bytes: %v", done, total, rerr)
		}
	}

	fatalIfCanceled(*cancelFile, cancelCleanup)
	if err := dst.Sync(); err != nil {
		fatalf("sync: %v", err)
	}

	sum := hex.EncodeToString(hasher.Sum(nil))
	emitJSON(map[string]any{"event": "done", "sha256": sum, "bytes": done})
}

// runHashDevice opens [target] read-only and streams every byte through
// SHA-256 without writing an image file. The UI uses this to prove that
// a completed eMMC backup image matches the currently attached live disk
// before auto-acknowledging the rollback step.
func runHashDevice(args []string) {
	fs := flag.NewFlagSet("hash-device", flag.ExitOnError)
	target := fs.String("target", "", "source disk id, e.g. PhysicalDrive3 on Windows, /dev/sde on Linux, /dev/rdisk4 on macOS")
	tokenFile := fs.String("token-file", "", "path to a 0600-mode file containing the UI-issued confirmation token; deleted on read")
	cancelFile := fs.String("cancel-file", "", "optional regular file; operation aborts when the file disappears")
	totalBytesHint := fs.Int64("total-bytes", 0, "optional size hint for progress reporting; used as bytes_total when the device handle reports 0")
	if err := fs.Parse(args); err != nil {
		fatalf("parse flags: %v", err)
	}

	fatalIfCanceled(*cancelFile, nil)
	if *target == "" || *tokenFile == "" {
		fatalf("hash-device requires --target and --token-file")
	}
	token, err := readAndRemoveTokenFile(*tokenFile)
	if err != nil {
		fatalf("read token: %v", err)
	}
	if len(token) < 16 {
		fatalf("token is implausibly short; refusing")
	}
	fatalIfCanceled(*cancelFile, nil)

	devicePath, err := targetToDevicePath(*target)
	if err != nil {
		fatalf("validate target: %v", err)
	}
	emitJSON(map[string]any{"event": "preparing", "device": devicePath})

	src, err := os.Open(devicePath)
	if err != nil {
		fatalf("open device: %v", err)
	}
	defer func() { _ = src.Close() }()

	total := readableSize(src, *totalBytesHint)
	sum, done, err := hashReader(src, total, *cancelFile)
	if err != nil {
		fatalf("hash device after %d of %d bytes: %v", done, total, err)
	}
	emitJSON(map[string]any{"event": "done", "sha256": sum, "bytes": done})
}

func readableSize(src *os.File, hint int64) int64 {
	var total int64
	if info, statErr := src.Stat(); statErr == nil && info.Size() > 0 {
		total = info.Size()
	} else if n, seekErr := src.Seek(0, io.SeekEnd); seekErr == nil && n > 0 {
		total = n
		_, _ = src.Seek(0, io.SeekStart)
	}
	if total == 0 && hint > 0 {
		total = hint
	}
	return total
}

func hashReader(src io.Reader, total int64, cancelFile string) (string, int64, error) {
	hasher := sha256.New()
	buf := make([]byte, 4<<20)
	var done int64
	lastEmit := time.Now()

	for {
		if operationCanceled(cancelFile) {
			return "", done, fmt.Errorf("operation canceled by user")
		}
		n, rerr := src.Read(buf)
		if n > 0 {
			hasher.Write(buf[:n])
			done += int64(n)
			if time.Since(lastEmit) > 250*time.Millisecond {
				emitJSON(map[string]any{
					"event":       "progress",
					"phase":       "reading",
					"bytes_done":  done,
					"bytes_total": total,
				})
				lastEmit = time.Now()
			}
		}
		if operationCanceled(cancelFile) {
			return "", done, fmt.Errorf("operation canceled by user")
		}
		if errors.Is(rerr, io.EOF) {
			break
		}
		if rerr != nil {
			return "", done, rerr
		}
	}
	return hex.EncodeToString(hasher.Sum(nil)), done, nil
}

const backupRootMarker = ".deckhand-emmc-backups-root"

func validateBackupOutputPath(root, output string) error {
	if root == "" || output == "" {
		return fmt.Errorf("output-root and output are required")
	}
	cleanRoot, err := filepath.Abs(filepath.Clean(root))
	if err != nil {
		return fmt.Errorf("resolve output-root: %w", err)
	}
	cleanOutput, err := filepath.Abs(filepath.Clean(output))
	if err != nil {
		return fmt.Errorf("resolve output: %w", err)
	}
	if filepath.Base(cleanRoot) != "emmc-backups" {
		return fmt.Errorf("output-root %q is not Deckhand's emmc-backups directory", root)
	}
	rootInfo, err := os.Lstat(cleanRoot)
	if err != nil {
		return fmt.Errorf("inspect output-root: %w", err)
	}
	if rootInfo.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("output-root %q is a symlink", root)
	}
	if !rootInfo.IsDir() {
		return fmt.Errorf("output-root %q is not a directory", root)
	}
	marker := filepath.Join(cleanRoot, backupRootMarker)
	info, err := os.Lstat(marker)
	if err != nil {
		return fmt.Errorf("backup root marker missing: %w", err)
	}
	if !info.Mode().IsRegular() {
		return fmt.Errorf("backup root marker %q is not a regular file", marker)
	}
	if filepath.Dir(cleanOutput) != cleanRoot {
		return fmt.Errorf("output %q must be a direct child of %q", output, cleanRoot)
	}
	if filepath.Ext(cleanOutput) != ".img" {
		return fmt.Errorf("output %q must use .img extension", output)
	}
	if err := rejectDeviceOutput(cleanOutput); err != nil {
		return err
	}
	if info, err := os.Lstat(cleanOutput); err == nil {
		if info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("output %q is a symlink", output)
		}
		return fmt.Errorf("output %q already exists", output)
	} else if !os.IsNotExist(err) {
		return fmt.Errorf("inspect output: %w", err)
	}
	return nil
}

func rejectDeviceOutput(output string) error {
	vol := filepath.VolumeName(output)
	withoutVol := strings.TrimPrefix(output, vol)
	devicePrefixes := []string{
		"/dev/sd", "/dev/nvme", "/dev/mmcblk", "/dev/disk",
		"/dev/rdisk", "/dev/loop", "/dev/vd",
	}
	for _, prefix := range devicePrefixes {
		if strings.HasPrefix(withoutVol, prefix) {
			return fmt.Errorf("output %q must be a regular file path, not a device", output)
		}
	}
	if runtime.GOOS == "windows" {
		upper := strings.ToUpper(output)
		if strings.HasPrefix(upper, `\\.\`) || strings.HasPrefix(upper, `//./`) {
			return fmt.Errorf("output %q must be a regular file path, not a device", output)
		}
	}
	return nil
}

func runWriteImage(args []string) {
	fs := flag.NewFlagSet("write-image", flag.ExitOnError)
	image := fs.String("image", "", "path to the source image file")
	target := fs.String("target", "", "target disk id, e.g. PhysicalDrive3 on Windows, /dev/sde on Linux, /dev/rdisk4 on macOS")
	tokenFile := fs.String("token-file", "", "path to a 0600-mode file containing the UI-issued confirmation token; deleted on read")
	cancelFile := fs.String("cancel-file", "", "optional regular file; operation aborts when the file disappears")
	verify := fs.Bool("verify", true, "read the written disk back and compare sha256")
	expectedSha := fs.String("sha256", "", "optional expected sha256 of the image (post-write verification compares against this)")
	// flag.ExitOnError calls os.Exit on parse failure, so Parse's return
	// is only informational in that mode. Keep the explicit call so a
	// future switch to ContinueOnError still surfaces the error.
	if err := fs.Parse(args); err != nil {
		fatalf("parse flags: %v", err)
	}

	if *image == "" || *target == "" || *tokenFile == "" {
		fatalf("write-image requires --image, --target, and --token-file")
	}
	fatalIfCanceled(*cancelFile, nil)

	token, err := readAndRemoveTokenFile(*tokenFile)
	if err != nil {
		fatalf("read token: %v", err)
	}

	// The token is a UI-flow linearization gate: the UI's
	// SecurityService validates it and marks it consumed before this
	// helper is launched. The helper does NOT independently enforce
	// single-use/TTL semantics - it has no IPC channel back to the
	// SecurityService and would have to trust caller-supplied state
	// either way. This length+shape check is a sanity gate against
	// accidentally launching the helper without a token at all.
	if len(token) < 16 {
		fatalf("token is implausibly short; refusing")
	}
	fatalIfCanceled(*cancelFile, nil)

	devicePath, err := targetToDevicePath(*target)
	if err != nil {
		fatalf("validate target: %v", err)
	}
	emitJSON(map[string]any{"event": "preparing", "device": devicePath, "image": *image})

	src, err := os.Open(*image)
	if err != nil {
		fatalf("open image: %v", err)
	}
	defer func() { _ = src.Close() }()

	// Total size for progress reporting.
	var total int64
	if info, err := src.Stat(); err == nil {
		total = info.Size()
	}

	// O_WRONLY (not O_RDWR): the verify pass reopens with os.Open. Asking
	// for only the access level we actually need makes auditing clearer
	// and avoids rejections on systems that have different read/write
	// permissions for the same device node.
	dst, err := os.OpenFile(devicePath, os.O_WRONLY, 0)
	if err != nil {
		fatalf("open device: %v", err)
	}
	defer func() { _ = dst.Close() }()

	hasher := sha256.New()
	mw := io.MultiWriter(dst, hasher)

	buf := make([]byte, 4<<20) // 4 MiB
	var done int64
	lastEmit := time.Now()

	for {
		fatalIfCanceled(*cancelFile, nil)
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
		fatalIfCanceled(*cancelFile, nil)
		if errors.Is(rerr, io.EOF) {
			break
		}
		if rerr != nil {
			fatalf("read image: %v", rerr)
		}
	}

	fatalIfCanceled(*cancelFile, nil)
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
		verifySha, err := verifyDevice(devicePath, done, *cancelFile)
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

func verifyDevice(devicePath string, expectBytes int64, cancelFile string) (string, error) {
	f, err := os.Open(devicePath)
	if err != nil {
		return "", fmt.Errorf("open for verify: %w", err)
	}
	defer func() { _ = f.Close() }()

	h := sha256.New()
	buf := make([]byte, 4<<20)
	var done int64
	for done < expectBytes {
		if operationCanceled(cancelFile) {
			return "", fmt.Errorf("operation canceled by user")
		}
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
		if errors.Is(rerr, io.EOF) {
			break
		}
		if rerr != nil {
			return "", rerr
		}
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func fatalIfCanceled(cancelFile string, cleanup func()) {
	if !operationCanceled(cancelFile) {
		return
	}
	if cleanup != nil {
		cleanup()
	}
	fatalf("operation canceled by user")
}

func operationCanceled(cancelFile string) bool {
	if strings.TrimSpace(cancelFile) == "" {
		return false
	}
	info, err := os.Stat(cancelFile)
	if err != nil {
		return true
	}
	return !info.Mode().IsRegular()
}

// readAndRemoveTokenFile reads the token from disk and immediately
// removes the file. The helper deletes on read so a buggy caller that
// forgets to clean up doesn't leave the token lying around. We refuse
// world-readable files on Unix to defend against a same-user attacker
// observing the file before the helper deletes it - the caller must
// chmod 0600 (or set the equivalent ACL on Windows) before invocation.
func readAndRemoveTokenFile(path string) (string, error) {
	info, err := os.Stat(path)
	if err != nil {
		return "", err
	}
	if !info.Mode().IsRegular() {
		return "", fmt.Errorf("token file %q is not a regular file", path)
	}
	if runtime.GOOS != "windows" {
		// 0o077 = any "group" or "other" permission bits set.
		if info.Mode().Perm()&0o077 != 0 {
			return "", fmt.Errorf("token file %q has overbroad permissions %v; expected 0600", path, info.Mode().Perm())
		}
	}
	b, readErr := os.ReadFile(path)
	// Best-effort delete regardless of read outcome - we never want
	// to leave the token on disk.
	if rmErr := os.Remove(path); rmErr != nil && !os.IsNotExist(rmErr) {
		// Log via stderr; not fatal.
		fmt.Fprintf(os.Stderr, "warn: could not remove token file %q: %v\n", path, rmErr)
	}
	if readErr != nil {
		return "", readErr
	}
	return strings.TrimSpace(string(b)), nil
}

func emitJSON(v any) {
	b, err := json.Marshal(v)
	if err != nil {
		return
	}
	fmt.Fprintln(eventsOut, string(b))
	// Best-effort flush so the parent sees events in real time when
	// eventsOut is a file. os.Stdout is line-buffered by default for
	// ttys; for an opened file we need to nudge it. Ignoring the
	// type-assertion failure handles os.Stdout (no Sync method needed).
	if f, ok := eventsOut.(*os.File); ok {
		_ = f.Sync()
	}
}

func fatalf(format string, args ...any) {
	msg := fmt.Sprintf(format, args...)
	emitJSON(map[string]any{"event": "error", "message": msg})
	os.Exit(1)
}

// runParentWatchdog polls [pid] every 2 seconds and self-terminates
// when the process is gone. Designed for the elevated-helper case:
// the unprivileged parent that launched us via UAC can't terminate
// us directly, so we have to opt in to dying when the parent does.
//
// 2s cadence chosen as a balance between "user perceives the ghost
// helper still chewing the disk" (long) and "wasted syscalls during
// a 5-minute backup" (short). At 2s the worst-case orphan window is
// imperceptible alongside Windows' own UAC-prompt latency.
//
// Uses fatalf so the exit lands in the events file as an error
// event — useful for the debug-bundle path, even though the parent
// that would have read live events is by definition gone.
func runParentWatchdog(pid int) {
	for {
		time.Sleep(2 * time.Second)
		if !parentAlive(pid) {
			fatalf("parent process %d gone; aborting elevated op", pid)
		}
	}
}
