// Package hash offers streaming file hashing.
package hash

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
)

// SHA256 returns the lowercase hex SHA-256 digest of the file at [path].
// Errors are wrapped with `hash.sha256: ...` so callers can see which
// layer they came from when the error surfaces as a JSON-RPC response.
func SHA256(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", fmt.Errorf("hash.sha256 open %q: %w", path, err)
	}
	defer f.Close()

	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", fmt.Errorf("hash.sha256 read %q: %w", path, err)
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}
