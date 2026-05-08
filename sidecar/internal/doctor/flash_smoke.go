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
	"strconv"
	"strings"
	"time"
)

// FlashSmokeOptions controls the safe write-image launch probe.
type FlashSmokeOptions struct {
	HelperPath     string
	ImagePath      string
	DiskID         string
	ExpectedSHA256 string
	Timeout        time.Duration
}

type flashSmokeInvocation struct {
	EventsPath  string
	ImagePath   string
	Target      string
	TokenFile   string
	CancelFile  string
	Manifest    string
	SHA256      string
	WatchdogPID int
}

type flashSmokeManifest struct {
	Version     int       `json:"version"`
	Op          string    `json:"op"`
	ImagePath   string    `json:"image_path"`
	ImageSHA256 string    `json:"image_sha256"`
	Target      string    `json:"target"`
	TokenSHA256 string    `json:"token_sha256"`
	ExpiresAt   time.Time `json:"expires_at"`
}

// RunFlashSmoke launches the elevated helper through the same platform
// elevation mechanism used for destructive writes, then runs the helper's
// write-image validation path without opening or writing the target disk.
func RunFlashSmoke(ctx context.Context, w io.Writer, opts FlashSmokeOptions) (bool, error) {
	if opts.Timeout <= 0 {
		opts.Timeout = 60 * time.Second
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

	imagePath := filepath.Clean(strings.TrimSpace(opts.ImagePath))
	if imagePath == "." || imagePath == "" {
		return false, fmt.Errorf("--image is required")
	}
	target := strings.TrimSpace(opts.DiskID)
	if target == "" {
		return false, fmt.Errorf("--disk is required")
	}
	expected := strings.ToLower(strings.TrimSpace(opts.ExpectedSHA256))
	if !isLowerSHA256(expected) {
		return false, fmt.Errorf("--sha256 must be a 64-hex sha256")
	}

	token := "deckhand-flash-smoke-token"
	eventsPath, err := createHelperPrivateTempPath("deckhand-flash-smoke-*.log", "")
	if err != nil {
		return false, err
	}
	tokenFile, err := createHelperPrivateTempPath("deckhand-flash-smoke-*.token", token+"\n")
	if err != nil {
		return false, err
	}
	cancelFile, err := createHelperPrivateTempPath("deckhand-flash-smoke-*.cancel", "active\n")
	if err != nil {
		_ = os.Remove(tokenFile)
		return false, err
	}
	manifestPath, err := createHelperPrivateTempPath("deckhand-flash-smoke-*.json", "")
	if err != nil {
		_ = os.Remove(tokenFile)
		_ = os.Remove(cancelFile)
		return false, err
	}
	defer func() {
		_ = os.Remove(tokenFile)
		_ = os.Remove(cancelFile)
		_ = os.Remove(manifestPath)
		_ = os.Remove(eventsPath + ".openerr")
	}()

	if err := writeFlashSmokeManifest(manifestPath, flashSmokeManifest{
		Version:     1,
		Op:          "write-image",
		ImagePath:   imagePath,
		ImageSHA256: expected,
		Target:      target,
		TokenSHA256: flashSmokeTokenDigest(token),
		ExpiresAt:   time.Now().Add(2 * time.Minute).UTC(),
	}); err != nil {
		return false, err
	}

	args := flashSmokeArgs(flashSmokeInvocation{
		EventsPath:  eventsPath,
		ImagePath:   imagePath,
		Target:      target,
		TokenFile:   tokenFile,
		CancelFile:  cancelFile,
		Manifest:    manifestPath,
		SHA256:      expected,
		WatchdogPID: os.Getpid(),
	})

	ctx, cancel := context.WithTimeout(ctx, opts.Timeout)
	defer cancel()

	fmt.Fprintf(w, "[INFO] flash_smoke_start - disk=%s image=%s\n", target, imagePath)
	exit, stderr, runErr := runHelperSmokeCommand(ctx, helper, args)
	body, _ := os.ReadFile(eventsPath)
	openErr, _ := os.ReadFile(eventsPath + ".openerr")
	events := parseBackupSmokeEvents(body)
	passed := runErr == nil && exit == 0 && events.Started && events.Done != nil && events.Done.SHA256 == expected

	if passed {
		fmt.Fprintf(w, "[PASS] flash_write_launch - %s\n", target)
	} else {
		fmt.Fprintf(w, "[FAIL] flash_write_launch - %s\n", target)
	}
	fmt.Fprintf(w, "helper=%s\n", helper)
	fmt.Fprintf(w, "events_file=%s\n", eventsPath)
	fmt.Fprintf(w, "image=%s\n", imagePath)
	fmt.Fprintf(w, "exit=%d\n", exit)
	if runErr != nil {
		fmt.Fprintf(w, "run_error=%v\n", runErr)
	}
	if strings.TrimSpace(stderr) != "" {
		fmt.Fprintf(w, "stderr=%s\n", strings.TrimSpace(stderr))
	}
	if strings.TrimSpace(string(openErr)) != "" {
		fmt.Fprintf(w, "open_error=%s\n", strings.TrimSpace(string(openErr)))
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

func flashSmokeArgs(inv flashSmokeInvocation) []string {
	args := []string{
		"write-image-smoke",
		"--events-file", inv.EventsPath,
		"--image", inv.ImagePath,
		"--target", inv.Target,
		"--token-file", inv.TokenFile,
		"--cancel-file", inv.CancelFile,
		"--manifest", inv.Manifest,
		"--sha256", inv.SHA256,
	}
	if inv.WatchdogPID > 0 {
		args = append(args, "--watchdog-pid", strconv.Itoa(inv.WatchdogPID))
	}
	return args
}

func writeFlashSmokeManifest(path string, manifest flashSmokeManifest) error {
	b, err := json.Marshal(manifest)
	if err != nil {
		return err
	}
	return os.WriteFile(path, b, 0o600)
}

func flashSmokeTokenDigest(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}
