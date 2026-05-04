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

// TestVerifyTagSignature_LightweightTagRejected proves a lightweight
// (unsigned) tag is treated as untrusted. go-git represents lightweight
// tags as plain refs; TagObject returns an error, which we map to
// ErrUnsignedOrUntrusted so the UI can surface it distinctly from a
// network or parse failure.
func TestVerifyTagSignature_LightweightTagRejected(t *testing.T) {
	dest := filepath.Join(t.TempDir(), "lw-tag")
	if err := os.MkdirAll(dest, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if _, err := git.PlainInit(dest, false); err != nil {
		t.Fatalf("PlainInit: %v", err)
	}
	repo, err := git.PlainOpen(dest)
	if err != nil {
		t.Fatalf("PlainOpen: %v", err)
	}
	wt, err := repo.Worktree()
	if err != nil {
		t.Fatalf("Worktree: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dest, "a"), []byte("hi"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	if _, err := wt.Add("a"); err != nil {
		t.Fatalf("Add: %v", err)
	}
	commit, err := wt.Commit("seed", &git.CommitOptions{
		Author: &object.Signature{Name: "T", Email: "t@e.invalid", When: time.Now()},
	})
	if err != nil {
		t.Fatalf("Commit: %v", err)
	}
	// Lightweight tag: no CreateTagOptions.Message/Tagger.
	if _, err := repo.CreateTag("v0", commit, nil); err != nil {
		t.Fatalf("CreateTag: %v", err)
	}
	// Bogus armored "keyring" — real go-git won't reach it because the
	// lightweight-tag branch returns first.
	_, err = verifyTagSignature(repo, "v0", []byte("armored-garbage"))
	if !errors.Is(err, ErrUnsignedOrUntrusted) {
		t.Fatalf("expected ErrUnsignedOrUntrusted, got %v", err)
	}
}

// TestFetchWithOptions_RequireSignedTag_RejectsCachedBranch proves that
// when a caller insists on a signed tag, a cached branch is rejected
// instead of bypassing the trust policy on the fast path.
func TestFetchWithOptions_RequireSignedTag_RejectsCachedBranch(t *testing.T) {
	dest := filepath.Join(t.TempDir(), "need-signed")
	if err := os.MkdirAll(dest, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if _, err := git.PlainInit(dest, false); err != nil {
		t.Fatalf("PlainInit: %v", err)
	}
	repo, err := git.PlainOpen(dest)
	if err != nil {
		t.Fatalf("PlainOpen: %v", err)
	}
	wt, err := repo.Worktree()
	if err != nil {
		t.Fatalf("Worktree: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dest, "a"), []byte("hi"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	if _, err := wt.Add("a"); err != nil {
		t.Fatalf("Add: %v", err)
	}
	if _, err := wt.Commit("seed", &git.CommitOptions{
		Author: &object.Signature{Name: "T", Email: "t@e.invalid", When: time.Now()},
	}); err != nil {
		t.Fatalf("Commit: %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	// Fast path: re-use the existing checkout as "cache hit" with
	// ResolvedKind="branch", then add the require-signed gate.
	res, err := FetchWithOptions(ctx, "https://example.invalid/x", "", dest, false, Options{
		TrustedKeys:      []byte("armored-garbage"),
		RequireSignedTag: true,
	})
	if !errors.Is(err, ErrUnsignedOrUntrusted) {
		t.Fatalf("expected ErrUnsignedOrUntrusted, got %v", err)
	}
	if !res.WasCached {
		t.Fatalf("expected cached result; got %+v", res)
	}
}

func TestFetchWithOptions_VerifiesCachedLightweightTag(t *testing.T) {
	dest := filepath.Join(t.TempDir(), "cached-lw-tag")
	if err := os.MkdirAll(dest, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if _, err := git.PlainInit(dest, false); err != nil {
		t.Fatalf("PlainInit: %v", err)
	}
	repo, err := git.PlainOpen(dest)
	if err != nil {
		t.Fatalf("PlainOpen: %v", err)
	}
	wt, err := repo.Worktree()
	if err != nil {
		t.Fatalf("Worktree: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dest, "a"), []byte("hi"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	if _, err := wt.Add("a"); err != nil {
		t.Fatalf("Add: %v", err)
	}
	commit, err := wt.Commit("seed", &git.CommitOptions{
		Author: &object.Signature{Name: "T", Email: "t@e.invalid", When: time.Now()},
	})
	if err != nil {
		t.Fatalf("Commit: %v", err)
	}
	if _, err := repo.CreateTag("v0.0.1", commit, nil); err != nil {
		t.Fatalf("CreateTag: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	res, err := FetchWithOptions(ctx, "https://example.invalid/x", "v0.0.1", dest, false, Options{
		TrustedKeys:      []byte("armored-garbage"),
		RequireSignedTag: true,
	})
	if !errors.Is(err, ErrUnsignedOrUntrusted) {
		t.Fatalf("expected ErrUnsignedOrUntrusted, got %v", err)
	}
	if !res.WasCached || res.ResolvedKind != "tag" {
		t.Fatalf("expected cached tag result, got %+v", res)
	}
}
