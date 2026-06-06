package logging

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeAndRead(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	logger, closeFn, err := Init(dir)
	if err != nil {
		t.Fatal(err)
	}
	logger.Debug("a-debug-line")
	logger.Info("an-info-line")
	if err := closeFn(); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(filepath.Join(dir, DefaultLogName))
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestLogLevel_DefaultsToInfo_DropsDebug(t *testing.T) {
	t.Setenv(LogLevelEnv, "") // explicit default
	out := writeAndRead(t)
	if strings.Contains(out, "a-debug-line") {
		t.Errorf("debug line should be dropped at info level:\n%s", out)
	}
	if !strings.Contains(out, "an-info-line") {
		t.Errorf("info line missing:\n%s", out)
	}
}

func TestLogLevel_DebugFromEnv_KeepsDebug(t *testing.T) {
	t.Setenv(LogLevelEnv, "DEBUG") // case-insensitive
	out := writeAndRead(t)
	if !strings.Contains(out, "a-debug-line") {
		t.Errorf("debug line missing at debug level:\n%s", out)
	}
	if !strings.Contains(out, "an-info-line") {
		t.Errorf("info line missing:\n%s", out)
	}
}

func TestLogLevel_ErrorFromEnv_DropsInfo(t *testing.T) {
	t.Setenv(LogLevelEnv, "error")
	out := writeAndRead(t)
	if strings.Contains(out, "an-info-line") {
		t.Errorf("info line should be dropped at error level:\n%s", out)
	}
}
