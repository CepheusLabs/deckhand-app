// Package profiles fetches deckhand-profiles checkouts via go-git.
package profiles

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	git "github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/plumbing"
)

// FetchResult summarizes what Fetch produced.
type FetchResult struct {
	LocalPath    string `json:"local_path"`
	ResolvedSha  string `json:"resolved_sha"`
	ResolvedRef  string `json:"resolved_ref"`
	WasCached    bool   `json:"was_cached"`
	Verified     bool   `json:"verified"`
	VerifiedBy   string `json:"verified_by,omitempty"`
	ResolvedKind string `json:"resolved_kind"` // "branch" | "tag"
}

// Options narrows Fetch's input so callers can add signing + trust
// controls without changing the positional-arg signature every time.
type Options struct {
	// TrustedKeys is an armored PGP keyring. When non-empty and the
	// resolved ref is a tag, the tag signature must verify against one
	// of these keys or Fetch returns ErrUnsignedOrUntrusted.
	TrustedKeys []byte
	// RequireSignedTag rejects any resolution that lands on an
	// unsigned tag or a branch when TrustedKeys is non-empty.
	RequireSignedTag bool
}

// ErrUnsignedOrUntrusted is returned when a tag's signature is absent
// or does not verify against the configured trusted keyring.
var ErrUnsignedOrUntrusted = errors.New("tag is unsigned or not signed by a trusted key")

// Fetch shallow-clones [repoURL] at [ref] into [destDir]. If the target
// directory already contains a clone of the same ref, returns its details
// without re-cloning (caller can force by passing force=true).
func Fetch(ctx context.Context, repoURL, ref, destDir string, force bool) (FetchResult, error) {
	return FetchWithOptions(ctx, repoURL, ref, destDir, force, Options{})
}

// FetchWithOptions is Fetch + trust configuration. The zero Options
// matches legacy unsigned behavior (used by the fast-path tests).
func FetchWithOptions(ctx context.Context, repoURL, ref, destDir string, force bool, opts Options) (FetchResult, error) {
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
				result := FetchResult{
					LocalPath:    absDest,
					ResolvedSha:  head.Hash().String(),
					ResolvedRef:  cachedResolvedRef(ref, head.Name()),
					WasCached:    true,
					ResolvedKind: cachedKindOfRef(repo, ref, head.Name()),
				}
				return verifyFetchResult(repo, ref, result, opts)
			}
		}
	}

	if force {
		if err := os.RemoveAll(absDest); err != nil {
			return FetchResult{}, fmt.Errorf("remove existing clone: %w", err)
		}
	}
	if err := os.MkdirAll(filepath.Dir(absDest), 0o750); err != nil {
		return FetchResult{}, fmt.Errorf("mkdir parent: %w", err)
	}

	// Clone as a branch first; fall back to tag on the expected
	// sentinel. Track which worked so we can decide whether to verify.
	kind := "branch"
	repo, err := git.PlainCloneContext(ctx, absDest, false, &git.CloneOptions{
		URL:           repoURL,
		ReferenceName: plumbing.NewBranchReferenceName(ref),
		Depth:         1,
		SingleBranch:  true,
		Tags:          git.NoTags,
	})
	if err != nil && !errors.Is(err, git.ErrRepositoryAlreadyExists) {
		kind = "tag"
		repo, err = git.PlainCloneContext(ctx, absDest, false, &git.CloneOptions{
			URL:           repoURL,
			ReferenceName: plumbing.NewTagReferenceName(ref),
			Depth:         1,
			SingleBranch:  true,
			Tags:          git.NoTags,
		})
	}
	if err != nil {
		return FetchResult{}, fmt.Errorf("clone: %w", err)
	}

	head, err := repo.Head()
	if err != nil {
		return FetchResult{}, fmt.Errorf("head: %w", err)
	}

	result := FetchResult{
		LocalPath:    absDest,
		ResolvedSha:  head.Hash().String(),
		ResolvedRef:  ref,
		WasCached:    false,
		ResolvedKind: kind,
	}

	return verifyFetchResult(repo, ref, result, opts)
}

// verifyFetchResult applies the profile trust policy to both newly cloned
// checkouts and fast-path cache hits. Only tags can be signed usefully;
// branches are mutable and can't be pinned cryptographically.
func verifyFetchResult(repo *git.Repository, ref string, result FetchResult, opts Options) (FetchResult, error) {
	if len(opts.TrustedKeys) > 0 {
		if result.ResolvedKind != "tag" {
			if opts.RequireSignedTag {
				return result, fmt.Errorf("%w: resolved ref %q is a branch, not a signed tag", ErrUnsignedOrUntrusted, ref)
			}
			// Don't mark as verified but don't fail either.
			return result, nil
		}
		entity, err := verifyTagSignature(repo, ref, opts.TrustedKeys)
		if err != nil {
			// Leave the clone on disk so a human can inspect it, but
			// report an error so the UI doesn't proceed.
			return result, fmt.Errorf("verify tag %q: %w", ref, err)
		}
		result.Verified = true
		result.VerifiedBy = entity
	} else if opts.RequireSignedTag {
		return result, fmt.Errorf("%w: no trusted keyring configured", ErrUnsignedOrUntrusted)
	}

	return result, nil
}

func cachedResolvedRef(ref string, head plumbing.ReferenceName) string {
	if ref != "" {
		return ref
	}
	return head.Short()
}

func cachedKindOfRef(repo *git.Repository, ref string, head plumbing.ReferenceName) string {
	if ref != "" {
		if _, err := repo.Tag(ref); err == nil {
			return "tag"
		}
		if _, err := repo.Reference(plumbing.NewBranchReferenceName(ref), true); err == nil {
			return "branch"
		}
	}
	return kindOfRef(head)
}

func kindOfRef(n plumbing.ReferenceName) string {
	if n.IsTag() {
		return "tag"
	}
	return "branch"
}

// verifyTagSignature looks up [ref] as an annotated tag, then calls
// go-git's Verify with the trusted keyring. Returns a stable signer
// label (the signing-key fingerprint) on success.
func verifyTagSignature(repo *git.Repository, ref string, armoredKeys []byte) (string, error) {
	// Resolve to an annotated tag object so we can Verify it. Lightweight
	// tags don't carry signatures; reject them explicitly so callers
	// don't mistake "no signature" for "verified".
	tagRef, err := repo.Tag(ref)
	if err != nil {
		return "", fmt.Errorf("resolve tag: %w", err)
	}
	tag, err := repo.TagObject(tagRef.Hash())
	if err != nil {
		// Lightweight tag — Hash points at the commit, not a tag object.
		return "", fmt.Errorf("%w: %q is a lightweight (unsigned) tag", ErrUnsignedOrUntrusted, ref)
	}
	if strings.TrimSpace(tag.PGPSignature) == "" {
		return "", fmt.Errorf("%w: tag %q has no PGP signature", ErrUnsignedOrUntrusted, ref)
	}
	entity, err := tag.Verify(string(armoredKeys))
	if err != nil {
		return "", fmt.Errorf("%w: %v", ErrUnsignedOrUntrusted, err)
	}
	// Entity comes from golang.org/x/crypto/openpgp; fingerprint is a
	// stable audit label that doesn't require importing that package
	// at compile time.
	return fmt.Sprintf("%x", entity.PrimaryKey.Fingerprint), nil
}
