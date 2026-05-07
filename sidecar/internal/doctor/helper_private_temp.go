package doctor

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
)

const helperTempRootName = "deckhand-elevated-helper"

func helperPrivateRoot() string {
	return filepath.Join(os.TempDir(), helperTempRootName)
}

func createHelperPrivateTempPath(pattern, body string) (string, error) {
	root := helperPrivateRoot()
	if err := ensureHelperPrivateRoot(root); err != nil {
		return "", err
	}
	f, err := os.CreateTemp(root, pattern)
	if err != nil {
		return "", err
	}
	path := f.Name()
	if runtime.GOOS != "windows" {
		if err := os.Chmod(path, 0o600); err != nil {
			_ = f.Close()
			_ = os.Remove(path)
			return "", fmt.Errorf("chmod helper temp file: %w", err)
		}
	}
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

func ensureHelperPrivateRoot(root string) error {
	info, err := os.Lstat(root)
	if err == nil {
		if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
			return fmt.Errorf("helper temp root %q must be a real directory", root)
		}
	} else if os.IsNotExist(err) {
		if err := os.MkdirAll(root, 0o700); err != nil {
			return fmt.Errorf("create helper temp root: %w", err)
		}
	} else {
		return fmt.Errorf("inspect helper temp root: %w", err)
	}
	if runtime.GOOS != "windows" {
		if err := os.Chmod(root, 0o700); err != nil {
			return fmt.Errorf("chmod helper temp root: %w", err)
		}
	}
	return nil
}
