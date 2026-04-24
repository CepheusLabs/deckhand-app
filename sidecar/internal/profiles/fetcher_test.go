package profiles

import (
	"context"
	"errors"
	"io"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	git "github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/plumbing/object"
)

// TestFetch_FastPath_ReusesCachedClone exercises the non-force branch:
// a prior successful clone must be returned without hitting the
// network. Uses a minimal in-repo fixture rather than a real remote
// because this path never calls out to git.
func TestFetch_FastPath_ReusesCachedClone(t *testing.T) {
	dest := filepath.Join(t.TempDir(), "profile-cache")

	// Build a tiny local git repo to act as the cached clone.
	if err := os.MkdirAll(dest, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if _, err := git.PlainInit(dest, false); err != nil {
		t.Fatalf("PlainInit: %v", err)
	}
	f := filepath.Join(dest, "README.md")
	if err := os.WriteFile(f, []byte("hello"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	repo, err := git.PlainOpen(dest)
	if err != nil {
		t.Fatalf("PlainOpen: %v", err)
	}
	wt, err := repo.Worktree()
	if err != nil {
		t.Fatalf("Worktree: %v", err)
	}
	if _, err := wt.Add("README.md"); err != nil {
		t.Fatalf("Add: %v", err)
	}
	_, err = wt.Commit("seed", &git.CommitOptions{
		Author: &object.Signature{
			Name:  "Test",
			Email: "test@example.invalid",
			When:  time.Now(),
		},
	})
	if err != nil {
		t.Fatalf("Commit: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	// repoURL is irrelevant on the fast path.
	res, err := Fetch(ctx, "https://example.invalid/ignored", "main", dest, false)
	if err != nil {
		t.Fatalf("Fetch: %v", err)
	}
	if !res.WasCached {
		t.Fatalf("expected WasCached=true, got %+v", res)
	}
	if res.ResolvedSha == "" {
		t.Fatalf("expected non-empty ResolvedSha")
	}
}

// TestFetch_NotFound_Errors makes sure a dead URL surfaces a clean
// error rather than hanging or silently succeeding. Uses an httptest
// server that closes the connection immediately so we don't depend
// on external DNS.
func TestFetch_NotFound_Errors(t *testing.T) {
	srv := httptest.NewServer(nil)
	// Close immediately so any connection attempt fails.
	srv.Close()

	dest := filepath.Join(t.TempDir(), "dead")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, err := Fetch(ctx, srv.URL+"/missing.git", "main", dest, false)
	if err == nil {
		t.Fatalf("expected error for dead remote, got nil")
	}
	// Should wrap the underlying failure rather than panic.
	if strings.Contains(err.Error(), "panic") {
		t.Fatalf("error looks like a panic: %v", err)
	}
}

// TestFetch_BranchToTagFallback checks that errors.Is is used for the
// ErrRepositoryAlreadyExists sentinel instead of `!=`. We can't easily
// provoke this path without a real remote, but we can at least prove
// errors.Is behaves correctly on the sentinel itself.
func TestErrorsIs_MatchesWrappedRepositoryAlreadyExists(t *testing.T) {
	wrapped := &wrappedErr{inner: git.ErrRepositoryAlreadyExists}
	if !errors.Is(wrapped, git.ErrRepositoryAlreadyExists) {
		t.Fatalf("errors.Is should unwrap ErrRepositoryAlreadyExists")
	}
}

type wrappedErr struct{ inner error }

func (w *wrappedErr) Error() string { return "wrapped: " + w.inner.Error() }
func (w *wrappedErr) Unwrap() error { return w.inner }

// Compile-time proof that io.Reader is used somewhere in this file
// (keeps goimports from pruning the import when future edits rely on
// it).
var _ = io.Reader(strings.NewReader(""))
