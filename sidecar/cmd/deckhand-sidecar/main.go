// Package main is the Deckhand sidecar entry point.
//
// The sidecar is a line-delimited JSON-RPC 2.0 server speaking over
// stdin/stdout. The Deckhand Flutter app spawns it as a child process at
// launch; it handles local disk I/O, sha256, shallow git clones, and
// HTTP fetches — operations Dart can't do portably without a lot of
// platform code.
package main

import (
	"bufio"
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"runtime"
	"time"

	"github.com/CepheusLabs/deckhand/sidecar/internal/doctor"
	"github.com/CepheusLabs/deckhand/sidecar/internal/handlers"
	"github.com/CepheusLabs/deckhand/sidecar/internal/host"
	"github.com/CepheusLabs/deckhand/sidecar/internal/logging"
	"github.com/CepheusLabs/deckhand/sidecar/internal/rpc"
)

// usageText is printed for `-h`/`--help` and for unknown subcommands.
// Intentionally terse — the sidecar's primary caller is the Flutter
// app, not humans, so we only document the human-facing entry points.
const usageText = `deckhand-sidecar — Deckhand's local helper process

Usage:
  deckhand-sidecar             Start the JSON-RPC 2.0 loop on stdin/stdout.
  deckhand-sidecar doctor      Run a self-diagnostic and exit. Exit code
                               0 means healthy, 1 means a blocking issue
                               was found. Prints a human-readable report
                               to stdout.
  deckhand-sidecar helper-smoke [--helper PATH] [--long-args]
                               Launch the elevated helper with a harmless
                               version probe and verify helper events work.
  deckhand-sidecar flash-smoke --disk DISK_ID --image PATH --sha256 HEX
                               [--helper PATH] [--timeout 60s]
                               Launch the elevated helper through the
                               write-image validation path without writing.
  deckhand-sidecar restore-smoke --disk DISK_ID --image PATH --sha256 HEX
                               [--helper PATH] [--timeout 60s]
                               Launch the elevated helper through the
                               restore validation path without writing.
  deckhand-sidecar backup-smoke --disk DISK_ID [--helper PATH]
                               [--output-root DIR] [--output PATH]
                               [--total-bytes N] [--timeout 45m]
                               Launch the elevated helper with a real
                               read-image backup probe.
  deckhand-sidecar download-os --url URL --sha256 HEX
                               [--id IMAGE_ID] [--dest PATH]
                               [--timeout 60m]
                               Download or reuse a verified OS image in
                               Deckhand's managed image cache.
  deckhand-sidecar -h|--help   Show this message and exit 0.
  deckhand-sidecar --version   Print the sidecar version and exit 0.
`

// Version is set at build time via -ldflags "-X main.Version=..."
var Version = "0.0.0-dev"

func main() {
	// Dispatch on argv[1] before doing anything else. The RPC loop
	// unconditionally drains stdin, so we *must* branch out early for
	// `doctor` / `--help` — otherwise a user running the binary from a
	// terminal with no stdin would appear to hang.
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "doctor":
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			passed, err := doctor.Run(ctx, os.Stdout, Version)
			if err != nil {
				fmt.Fprintf(os.Stderr, "[deckhand-sidecar] doctor: %v\n", err)
				os.Exit(1)
			}
			if !passed {
				os.Exit(1)
			}
			return
		case "helper-smoke":
			fs := flag.NewFlagSet("helper-smoke", flag.ExitOnError)
			helperPath := fs.String("helper", "", "path to deckhand-elevated-helper; default is sibling of sidecar")
			longArgs := fs.Bool("long-args", false, "include read-image-like extra args after the version op")
			if err := fs.Parse(os.Args[2:]); err != nil {
				fmt.Fprintf(os.Stderr, "[deckhand-sidecar] helper-smoke: %v\n", err)
				os.Exit(2)
			}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			passed, err := doctor.RunHelperSmoke(ctx, os.Stdout, doctor.HelperSmokeOptions{
				HelperPath: *helperPath,
				LongArgs:   *longArgs,
			})
			if err != nil {
				fmt.Fprintf(os.Stderr, "[deckhand-sidecar] helper-smoke: %v\n", err)
				os.Exit(1)
			}
			if !passed {
				os.Exit(1)
			}
			return
		case "flash-smoke":
			fs := flag.NewFlagSet("flash-smoke", flag.ExitOnError)
			helperPath := fs.String("helper", "", "path to deckhand-elevated-helper; default is sibling of sidecar")
			diskID := fs.String("disk", "", "disk id to validate, for example PhysicalDrive3")
			imagePath := fs.String("image", "", "managed OS image .img path")
			expectedSHA256 := fs.String("sha256", "", "required 64-hex sha256 of image")
			timeoutRaw := fs.String("timeout", "60s", "maximum time to wait, for example 30s or 2m")
			if err := fs.Parse(os.Args[2:]); err != nil {
				fmt.Fprintf(os.Stderr, "[deckhand-sidecar] flash-smoke: %v\n", err)
				os.Exit(2)
			}
			timeout, err := time.ParseDuration(*timeoutRaw)
			if err != nil {
				fmt.Fprintf(os.Stderr, "[deckhand-sidecar] flash-smoke: invalid --timeout %q: %v\n", *timeoutRaw, err)
				os.Exit(2)
			}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			passed, err := doctor.RunFlashSmoke(ctx, os.Stdout, doctor.FlashSmokeOptions{
				HelperPath:     *helperPath,
				ImagePath:      *imagePath,
				DiskID:         *diskID,
				ExpectedSHA256: *expectedSHA256,
				Timeout:        timeout,
			})
			if err != nil {
				fmt.Fprintf(os.Stderr, "[deckhand-sidecar] flash-smoke: %v\n", err)
				os.Exit(1)
			}
			if !passed {
				os.Exit(1)
			}
			return
		case "restore-smoke":
			fs := flag.NewFlagSet("restore-smoke", flag.ExitOnError)
			helperPath := fs.String("helper", "", "path to deckhand-elevated-helper; default is sibling of sidecar")
			diskID := fs.String("disk", "", "disk id to validate, for example PhysicalDrive3")
			imagePath := fs.String("image", "", "Deckhand eMMC backup .img path")
			expectedSHA256 := fs.String("sha256", "", "required 64-hex sha256 of image")
			timeoutRaw := fs.String("timeout", "60s", "maximum time to wait, for example 30s or 2m")
			if err := fs.Parse(os.Args[2:]); err != nil {
				fmt.Fprintf(os.Stderr, "[deckhand-sidecar] restore-smoke: %v\n", err)
				os.Exit(2)
			}
			timeout, err := time.ParseDuration(*timeoutRaw)
			if err != nil {
				fmt.Fprintf(os.Stderr, "[deckhand-sidecar] restore-smoke: invalid --timeout %q: %v\n", *timeoutRaw, err)
				os.Exit(2)
			}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			passed, err := doctor.RunRestoreSmoke(ctx, os.Stdout, doctor.RestoreSmokeOptions{
				HelperPath:     *helperPath,
				ImagePath:      *imagePath,
				DiskID:         *diskID,
				ExpectedSHA256: *expectedSHA256,
				Timeout:        timeout,
			})
			if err != nil {
				fmt.Fprintf(os.Stderr, "[deckhand-sidecar] restore-smoke: %v\n", err)
				os.Exit(1)
			}
			if !passed {
				os.Exit(1)
			}
			return
		case "backup-smoke":
			fs := flag.NewFlagSet("backup-smoke", flag.ExitOnError)
			helperPath := fs.String("helper", "", "path to deckhand-elevated-helper; default is sibling of sidecar")
			diskID := fs.String("disk", "", "disk id to read, for example PhysicalDrive3")
			outputRoot := fs.String("output-root", "", "Deckhand emmc-backups root; default is the app state backup root")
			outputPath := fs.String("output", "", "full output .img path; default is a timestamped file in output-root")
			totalBytes := fs.Int64("total-bytes", 0, "expected disk size in bytes; auto-detected when omitted")
			timeoutRaw := fs.String("timeout", "45m", "maximum time to wait, for example 10m or 1h")
			if err := fs.Parse(os.Args[2:]); err != nil {
				fmt.Fprintf(os.Stderr, "[deckhand-sidecar] backup-smoke: %v\n", err)
				os.Exit(2)
			}
			timeout, err := time.ParseDuration(*timeoutRaw)
			if err != nil {
				fmt.Fprintf(os.Stderr, "[deckhand-sidecar] backup-smoke: invalid --timeout %q: %v\n", *timeoutRaw, err)
				os.Exit(2)
			}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			passed, err := doctor.RunBackupSmoke(ctx, os.Stdout, doctor.BackupSmokeOptions{
				HelperPath: *helperPath,
				DiskID:     *diskID,
				OutputRoot: *outputRoot,
				OutputPath: *outputPath,
				TotalBytes: *totalBytes,
				Timeout:    timeout,
			})
			if err != nil {
				fmt.Fprintf(os.Stderr, "[deckhand-sidecar] backup-smoke: %v\n", err)
				os.Exit(1)
			}
			if !passed {
				os.Exit(1)
			}
			return
		case "download-os":
			fs := flag.NewFlagSet("download-os", flag.ExitOnError)
			rawURL := fs.String("url", "", "HTTPS URL to the compressed or raw OS image")
			expectedSHA256 := fs.String("sha256", "", "required 64-hex sha256 of the download artifact")
			imageID := fs.String("id", "", "stable image id used for the managed cache filename")
			destPath := fs.String("dest", "", "full managed .img destination path; default is Deckhand's OS image cache")
			timeoutRaw := fs.String("timeout", "60m", "maximum time to wait, for example 10m or 1h")
			if err := fs.Parse(os.Args[2:]); err != nil {
				fmt.Fprintf(os.Stderr, "[deckhand-sidecar] download-os: %v\n", err)
				os.Exit(2)
			}
			timeout, err := time.ParseDuration(*timeoutRaw)
			if err != nil {
				fmt.Fprintf(os.Stderr, "[deckhand-sidecar] download-os: invalid --timeout %q: %v\n", *timeoutRaw, err)
				os.Exit(2)
			}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			passed, err := doctor.RunDownloadOS(ctx, os.Stdout, doctor.DownloadOSOptions{
				URL:            *rawURL,
				ExpectedSHA256: *expectedSHA256,
				DestPath:       *destPath,
				ImageID:        *imageID,
				Timeout:        timeout,
			})
			if err != nil {
				fmt.Fprintf(os.Stderr, "[deckhand-sidecar] download-os: %v\n", err)
				os.Exit(1)
			}
			if !passed {
				os.Exit(1)
			}
			return
		case "-h", "--help", "help":
			_, _ = fmt.Fprint(os.Stdout, usageText)
			return
		case "--version", "-V":
			_, _ = fmt.Fprintf(os.Stdout, "deckhand-sidecar %s\n", Version)
			return
		default:
			fmt.Fprintf(os.Stderr, "unknown subcommand %q\n\n%s", os.Args[1], usageText)
			os.Exit(2)
		}
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Logging is wired first so every subsequent step (handler
	// registration, serve, shutdown) can emit structured events. If
	// logging setup itself fails we still have os.Stderr plus
	// slog.Default as a last-resort logger.
	logger, closeLog, err := logging.Init(host.Current().Data)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[deckhand-sidecar] log init failed: %v\n", err)
		logger = slog.Default()
		closeLog = func() error { return nil }
	}
	defer func() { _ = closeLog() }()

	server := rpc.NewServer()
	server.SetLogger(logger)
	// handlers.Register needs `cancel` so `shutdown` can tear the
	// loop down cleanly without killing in-flight handlers with
	// os.Exit.
	handlers.Register(server, cancel, Version)

	reader := bufio.NewReader(os.Stdin)

	logger.Info("sidecar.start",
		"version", Version,
		"os", runtime.GOOS,
		"arch", runtime.GOARCH,
		"pid", os.Getpid(),
	)

	// Hand os.Stdout directly to Serve; the server owns its own
	// buffered writer + output mutex. Wrapping stdout twice at this
	// layer was dead code and could hide partial writes.
	//
	// The `shutdown` RPC handler calls our `cancel` so the server's
	// context is Done, which causes Serve to return context.Canceled.
	// That's the documented graceful-exit path — treat it as success
	// so callers (smoke tests, the Flutter parent process) see a
	// clean exit code instead of conflating graceful shutdown with
	// internal failure.
	if err := server.Serve(ctx, reader, os.Stdout); err != nil {
		if errors.Is(err, context.Canceled) {
			logger.Info("sidecar.shutdown")
			return
		}
		logger.Error("sidecar.serve_error", "error", err.Error())
		os.Exit(1)
	}
}
