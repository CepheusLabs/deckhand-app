package doctor

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/CepheusLabs/deckhand/sidecar/internal/disks"
)

const backupSmokeRootMarker = ".deckhand-emmc-backups-root"

// BackupSmokeOptions controls the real backup probe.
type BackupSmokeOptions struct {
	HelperPath string
	DiskID     string
	OutputRoot string
	OutputPath string
	TotalBytes int64
	Timeout    time.Duration
}

type backupSmokeInvocation struct {
	EventsPath  string
	Target      string
	OutputPath  string
	OutputRoot  string
	TokenFile   string
	CancelFile  string
	TotalBytes  int64
	WatchdogPID int
}

type backupSmokeProgress struct {
	Phase      string
	BytesDone  int64
	BytesTotal int64
}

type backupSmokeDone struct {
	SHA256    string
	Bytes     int64
	Recovered bool
}

type backupSmokeEvents struct {
	Started      bool
	Progress     *backupSmokeProgress
	Done         *backupSmokeDone
	ErrorMessage string
}

// RunBackupSmoke launches the elevated helper with the real read-image
// operation. Unlike helper-smoke, this performs a full read-only disk
// backup and leaves the produced .img in the Deckhand backup directory.
func RunBackupSmoke(ctx context.Context, w io.Writer, opts BackupSmokeOptions) (bool, error) {
	if opts.Timeout <= 0 {
		opts.Timeout = 45 * time.Minute
	}
	helper := opts.HelperPath
	if helper == "" {
		resolved, err := defaultElevatedHelperPath()
		if err != nil {
			return false, err
		}
		helper = resolved
	}
	if _, err := os.Stat(helper); err != nil {
		fmt.Fprintf(w, "[FAIL] helper_present - %s: %v\n", helper, err)
		return false, nil
	}

	target := strings.TrimSpace(opts.DiskID)
	if target == "" {
		return false, fmt.Errorf("--disk is required")
	}

	totalBytes := opts.TotalBytes
	if totalBytes <= 0 {
		size, err := discoverBackupDiskSize(ctx, target)
		if err != nil {
			return false, fmt.Errorf("resolve --total-bytes for %s: %w", target, err)
		}
		totalBytes = size
	}

	outputRoot := strings.TrimSpace(opts.OutputRoot)
	if outputRoot == "" {
		root, err := defaultBackupOutputRoot()
		if err != nil {
			return false, err
		}
		outputRoot = root
	}
	outputRoot = filepath.Clean(outputRoot)

	outputPath := strings.TrimSpace(opts.OutputPath)
	if outputPath == "" {
		outputPath = defaultBackupOutputPath(outputRoot, time.Now().UTC())
	}
	outputPath = filepath.Clean(outputPath)
	if err := validateBackupSmokeOutput(outputRoot, outputPath); err != nil {
		return false, err
	}

	eventsPath, err := createTempPath("deckhand-backup-smoke-*.log", "")
	if err != nil {
		return false, err
	}
	tokenFile, err := createTempPath("deckhand-backup-smoke-*.token", "deckhand-backup-smoke-token\n")
	if err != nil {
		return false, err
	}
	cancelFile, err := createTempPath("deckhand-backup-smoke-*.cancel", "active\n")
	if err != nil {
		_ = os.Remove(tokenFile)
		return false, err
	}
	defer func() {
		_ = os.Remove(tokenFile)
		_ = os.Remove(cancelFile)
		_ = os.Remove(eventsPath + ".openerr")
	}()

	args := backupSmokeArgs(backupSmokeInvocation{
		EventsPath:  eventsPath,
		Target:      target,
		OutputPath:  outputPath,
		OutputRoot:  outputRoot,
		TokenFile:   tokenFile,
		CancelFile:  cancelFile,
		TotalBytes:  totalBytes,
		WatchdogPID: os.Getpid(),
	})

	ctx, cancel := context.WithTimeout(ctx, opts.Timeout)
	defer cancel()

	type helperResult struct {
		exit   int
		stderr string
		err    error
	}
	resultCh := make(chan helperResult, 1)
	startedAt := time.Now()
	go func() {
		exit, stderr, runErr := runHelperSmokeCommand(ctx, helper, args)
		resultCh <- helperResult{exit: exit, stderr: stderr, err: runErr}
	}()

	fmt.Fprintf(w, "[INFO] backup_start - disk=%s output=%s total=%s\n", target, outputPath, humanBytes(totalBytes))
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	var lastPrintedDone int64 = -1
	var result helperResult
	for {
		select {
		case result = <-resultCh:
			goto finished
		case <-ticker.C:
			body, _ := os.ReadFile(eventsPath)
			events := parseBackupSmokeEvents(body)
			if events.Progress != nil && shouldPrintBackupProgress(events.Progress, lastPrintedDone) {
				fmt.Fprintln(w, formatBackupProgressLine(*events.Progress, startedAt, time.Now()))
				lastPrintedDone = events.Progress.BytesDone
			}
		}
	}

finished:
	body, _ := os.ReadFile(eventsPath)
	openErr, _ := os.ReadFile(eventsPath + ".openerr")
	events := parseBackupSmokeEvents(body)
	if events.Done == nil {
		if recovered, ok := recoverCompletedBackup(outputPath, totalBytes); ok {
			events.Done = recovered
		}
	}

	outputOK := false
	if info, statErr := os.Stat(outputPath); statErr == nil && info.Mode().IsRegular() {
		outputOK = totalBytes <= 0 || info.Size() == totalBytes
	}
	passed := outputOK && events.Done != nil && (events.Done.Bytes == 0 || events.Done.Bytes == totalBytes)

	if passed {
		if events.Done.Recovered {
			fmt.Fprintf(w, "[PASS] backup_read_recovered - %s\n", target)
		} else {
			fmt.Fprintf(w, "[PASS] backup_read - %s\n", target)
		}
	} else {
		fmt.Fprintf(w, "[FAIL] backup_read - %s\n", target)
	}
	fmt.Fprintf(w, "helper=%s\n", helper)
	fmt.Fprintf(w, "events_file=%s\n", eventsPath)
	fmt.Fprintf(w, "output=%s\n", outputPath)
	fmt.Fprintf(w, "exit=%d\n", result.exit)
	if result.err != nil {
		fmt.Fprintf(w, "run_error=%v\n", result.err)
	}
	if strings.TrimSpace(result.stderr) != "" {
		fmt.Fprintf(w, "stderr=%s\n", strings.TrimSpace(result.stderr))
	}
	if strings.TrimSpace(string(openErr)) != "" {
		fmt.Fprintf(w, "open_error=%s\n", strings.TrimSpace(string(openErr)))
	}
	if events.Done != nil {
		fmt.Fprintf(w, "bytes=%d\n", events.Done.Bytes)
		fmt.Fprintf(w, "sha256=%s\n", events.Done.SHA256)
	}
	if events.ErrorMessage != "" {
		fmt.Fprintf(w, "helper_error=%s\n", events.ErrorMessage)
	}
	if strings.TrimSpace(string(body)) == "" {
		fmt.Fprintln(w, "events=(empty)")
	} else if !passed {
		fmt.Fprintf(w, "events_tail=\n%s\n", tailLines(strings.TrimSpace(string(body)), 12))
	}
	return passed, nil
}

func backupSmokeArgs(inv backupSmokeInvocation) []string {
	args := []string{
		"read-image",
		"--events-file", inv.EventsPath,
		"--target", inv.Target,
		"--output", inv.OutputPath,
		"--output-root", inv.OutputRoot,
		"--token-file", inv.TokenFile,
		"--cancel-file", inv.CancelFile,
	}
	if inv.TotalBytes > 0 {
		args = append(args, "--total-bytes", strconv.FormatInt(inv.TotalBytes, 10))
	}
	if inv.WatchdogPID > 0 {
		args = append(args, "--watchdog-pid", strconv.Itoa(inv.WatchdogPID))
	}
	return args
}

func parseBackupSmokeEvents(body []byte) backupSmokeEvents {
	var out backupSmokeEvents
	for _, rawLine := range strings.Split(string(body), "\n") {
		line := strings.TrimSpace(rawLine)
		if line == "" {
			continue
		}
		var ev struct {
			Event      string `json:"event"`
			Phase      string `json:"phase"`
			BytesDone  int64  `json:"bytes_done"`
			BytesTotal int64  `json:"bytes_total"`
			Bytes      int64  `json:"bytes"`
			SHA256     string `json:"sha256"`
			Message    string `json:"message"`
		}
		if err := json.Unmarshal([]byte(line), &ev); err != nil {
			continue
		}
		switch ev.Event {
		case "started":
			out.Started = true
		case "progress":
			out.Progress = &backupSmokeProgress{
				Phase:      ev.Phase,
				BytesDone:  ev.BytesDone,
				BytesTotal: ev.BytesTotal,
			}
		case "done":
			out.Done = &backupSmokeDone{SHA256: ev.SHA256, Bytes: ev.Bytes}
		case "error":
			out.ErrorMessage = ev.Message
		}
	}
	return out
}

func recoverCompletedBackup(outputPath string, expectedBytes int64) (*backupSmokeDone, bool) {
	if expectedBytes <= 0 {
		return nil, false
	}
	info, err := os.Stat(outputPath)
	if err != nil || !info.Mode().IsRegular() || info.Size() != expectedBytes {
		return nil, false
	}
	f, err := os.Open(outputPath)
	if err != nil {
		return nil, false
	}
	defer func() { _ = f.Close() }()
	hasher := sha256.New()
	if _, err := io.Copy(hasher, f); err != nil {
		return nil, false
	}
	return &backupSmokeDone{
		SHA256:    hex.EncodeToString(hasher.Sum(nil)),
		Bytes:     expectedBytes,
		Recovered: true,
	}, true
}

func discoverBackupDiskSize(ctx context.Context, target string) (int64, error) {
	infos, err := disks.List(ctx)
	if err != nil {
		return 0, err
	}
	for _, info := range infos {
		if strings.EqualFold(info.ID, target) || strings.EqualFold(info.Path, target) {
			if info.SizeBytes <= 0 {
				return 0, fmt.Errorf("disk %s reported size %d", target, info.SizeBytes)
			}
			return info.SizeBytes, nil
		}
	}
	return 0, fmt.Errorf("disk %s not found", target)
}

func defaultBackupOutputRoot() (string, error) {
	config, err := os.UserConfigDir()
	if err != nil {
		return "", fmt.Errorf("resolve user config dir: %w", err)
	}
	return filepath.Join(config, "CepheusLabs", "Deckhand", "state", "emmc-backups"), nil
}

func defaultBackupOutputPath(root string, now time.Time) string {
	return filepath.Join(root, "deckhand-cli-backup-"+now.UTC().Format("20060102T150405Z")+".img")
}

func validateBackupSmokeOutput(root, output string) error {
	cleanRoot, err := filepath.Abs(filepath.Clean(root))
	if err != nil {
		return fmt.Errorf("resolve output root: %w", err)
	}
	cleanOutput, err := filepath.Abs(filepath.Clean(output))
	if err != nil {
		return fmt.Errorf("resolve output: %w", err)
	}
	if filepath.Base(cleanRoot) != "emmc-backups" {
		return fmt.Errorf("output root %q must be an emmc-backups directory", root)
	}
	info, err := os.Lstat(cleanRoot)
	if err != nil {
		return fmt.Errorf("inspect output root: %w", err)
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("output root %q is a symlink", root)
	}
	if !info.IsDir() {
		return fmt.Errorf("output root %q is not a directory", root)
	}
	marker := filepath.Join(cleanRoot, backupSmokeRootMarker)
	markerInfo, err := os.Lstat(marker)
	if err != nil {
		return fmt.Errorf("backup root marker missing at %s: %w", marker, err)
	}
	if !markerInfo.Mode().IsRegular() {
		return fmt.Errorf("backup root marker %q is not a regular file", marker)
	}
	if filepath.Dir(cleanOutput) != cleanRoot {
		return fmt.Errorf("output %q must be a direct child of %q", output, cleanRoot)
	}
	if filepath.Ext(cleanOutput) != ".img" {
		return fmt.Errorf("output %q must use .img extension", output)
	}
	if _, err := os.Lstat(cleanOutput); err == nil {
		return fmt.Errorf("output %q already exists", output)
	} else if !os.IsNotExist(err) {
		return fmt.Errorf("inspect output: %w", err)
	}
	if runtime.GOOS == "windows" {
		upper := strings.ToUpper(cleanOutput)
		if strings.HasPrefix(upper, `\\.\`) || strings.HasPrefix(upper, `//./`) {
			return fmt.Errorf("output %q must be a regular file path, not a device", output)
		}
	}
	return nil
}

func createTempPath(pattern, body string) (string, error) {
	f, err := os.CreateTemp("", pattern)
	if err != nil {
		return "", err
	}
	path := f.Name()
	if body != "" {
		if _, err := f.WriteString(body); err != nil {
			_ = f.Close()
			_ = os.Remove(path)
			return "", err
		}
	}
	if err := f.Close(); err != nil {
		_ = os.Remove(path)
		return "", err
	}
	return path, nil
}

func shouldPrintBackupProgress(progress *backupSmokeProgress, lastPrintedDone int64) bool {
	if progress == nil || progress.BytesDone <= 0 {
		return false
	}
	if lastPrintedDone < 0 {
		return true
	}
	if progress.BytesTotal > 0 {
		onePercent := progress.BytesTotal / 100
		if onePercent > 0 && progress.BytesDone-lastPrintedDone >= onePercent {
			return true
		}
	}
	return progress.BytesDone-lastPrintedDone >= 256*1024*1024
}

func formatBackupProgressLine(progress backupSmokeProgress, startedAt, now time.Time) string {
	elapsed := now.Sub(startedAt)
	if elapsed <= 0 {
		elapsed = time.Second
	}
	rate := int64(float64(progress.BytesDone) / elapsed.Seconds())
	eta := "unknown"
	percent := 0.0
	if progress.BytesTotal > 0 {
		percent = float64(progress.BytesDone) * 100 / float64(progress.BytesTotal)
		if rate > 0 && progress.BytesDone < progress.BytesTotal {
			eta = (time.Duration(float64(progress.BytesTotal-progress.BytesDone)/float64(rate)) * time.Second).Round(time.Second).String()
		} else if progress.BytesDone >= progress.BytesTotal {
			eta = "0s"
		}
	}
	return fmt.Sprintf("[INFO] progress - %.1f%% (%s of %s), %s/s, eta %s",
		percent,
		humanBytes(progress.BytesDone),
		humanBytes(progress.BytesTotal),
		humanBytes(rate),
		eta,
	)
}

func humanBytes(n int64) string {
	if n <= 0 {
		return "0 B"
	}
	const unit = 1024
	units := []string{"B", "KiB", "MiB", "GiB", "TiB"}
	value := float64(n)
	i := 0
	for value >= unit && i < len(units)-1 {
		value /= unit
		i++
	}
	if i == 0 {
		return fmt.Sprintf("%d %s", n, units[i])
	}
	return fmt.Sprintf("%.1f %s", value, units[i])
}

func tailLines(text string, maxLines int) string {
	lines := strings.Split(text, "\n")
	if len(lines) <= maxLines {
		return text
	}
	return strings.Join(lines[len(lines)-maxLines:], "\n")
}
