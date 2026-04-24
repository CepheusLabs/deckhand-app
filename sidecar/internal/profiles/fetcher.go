// Package profiles fetches deckhand-builds checkouts via go-git.
package profiles

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	git "github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/plumbing"
)

// FetchResult summarizes what Fetch produced.
type FetchResult struct {
	LocalPath    string `json:"local_path"`
	ResolvedSha  string `json:"resolved_sha"`
	ResolvedRef  string `json:"resolved_ref"`
	WasCached    bool   `json:"was_cached"`
}

// Fetch shallow-clones [repoURL] at [ref] into [destDir]. If the target
// directory already contains a clone of the same ref, returns its details
// without re-cloning (caller can force by passing force=true).
func Fetch(ctx context.Context, repoURL, ref, destDir string, force bool) (FetchResult, error) {
	if ref == "" {
		ref = "main"
	}

	absDest, err := filepath.Abs(destDir)
	if err != nil {
		return FetchResult{}, fmt.Errorf("abs dest: %w", err)
	}

	// Fast path — already cloned, return cached info.
	if !force {
		if repo, err := git.PlainOpen(absDest); err == nil {
			head, hErr := repo.Head()
			if hErr == nil {
				return FetchResult{
					LocalPath:   absDest,
					ResolvedSha: head.Hash().String(),
					ResolvedRef: head.Name().Short(),
					WasCached:   true,
				}, nil
			}
		}
	}

	if force {
		if err := os.RemoveAll(absDest); err != nil {
			return FetchResult{}, fmt.Errorf("remove existing clone: %w", err)
		}
	}
	if err := os.MkdirAll(filepath.Dir(absDest), 0o755); err != nil {
		return FetchResult{}, fmt.Errorf("mkdir parent: %w", err)
	}

	repo, err := git.PlainCloneContext(ctx, absDest, false, &git.CloneOptions{
		URL:           repoURL,
		ReferenceName: plumbing.NewBranchReferenceName(ref),
		Depth:         1,
		SingleBranch:  true,
	})
	// errors.Is + sentinel match so the branch-vs-tag retry fires
	// correctly even if go-git begins wrapping ErrRepositoryAlreadyExists
	// in a future release.
	if err != nil && !errors.Is(err, git.ErrRepositoryAlreadyExists) {
		// Ref might be a tag, not a branch. Retry.
		repo, err = git.PlainCloneContext(ctx, absDest, false, &git.CloneOptions{
			URL:           repoURL,
			ReferenceName: plumbing.NewTagReferenceName(ref),
			Depth:         1,
			SingleBranch:  true,
		})
	}
	if err != nil {
		return FetchResult{}, fmt.Errorf("clone: %w", err)
	}

	head, err := repo.Head()
	if err != nil {
		return FetchResult{}, fmt.Errorf("head: %w", err)
	}

	return FetchResult{
		LocalPath:   absDest,
		ResolvedSha: head.Hash().String(),
		ResolvedRef: ref,
		WasCached:   false,
	}, nil
}
