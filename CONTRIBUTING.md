# Contributing to Deckhand

## Versioning

Deckhand uses **date-based CalVer** (matching Printdeck's
`frontend/scripts/build.sh`):

- **Version**: today's UTC date, not zero-padded — `YY.M.D` (e.g. `26.4.18`)
- **Build number**: total `git rev-list --count HEAD` (monotonic)
- **Tag**: `v<VERSION>-<BUILD>` (e.g. `v26.4.18-1247`)

The version is computed automatically — there's nothing to bump, nothing
to remember. You write code, push, GitHub Actions stamps the release.

## Commit messages

No conventional-commits discipline required (but no harm in using them
if you want — the release notes are generated from `git log`).

Keep commits reasonably self-contained and their subjects meaningful;
the GitHub Release for each version lists every commit that landed since
the previous one.

## How releases happen

1. You push to `main`.
2. `.github/workflows/release.yml` runs. It:
   - Computes `VERSION=YY.M.D`, `BUILD=git rev-list --count HEAD`.
   - Builds the Go sidecar + elevated helper for 4 OS/arch pairs.
   - Builds the Flutter app for Windows / macOS (both arches) / Linux.
   - Runs Inno Setup / create-dmg / appimagetool to produce installers.
   - Signs + notarizes if the appropriate secrets are configured.
   - Tags the commit `v<VERSION>-<BUILD>`.
   - Publishes a GitHub Release with every artifact attached and
     auto-generated notes from the commits since the previous tag.

Takes ~25-30 minutes end-to-end. The longest jobs are the macOS and
Windows Flutter builds.

## Off-cycle / rebuild an old version

`Actions → Release → Run workflow`, enter a branch / tag / SHA in the
`ref` input. The workflow still computes the version from today's date
— if you want a reproducible rebuild of an old tag, check out that tag
locally and push it back with a new tag name, or just accept today's
date as the new version.

## Local builds

`scripts/build.sh` mirrors the CI logic for local development:

```powershell
./scripts/build.sh sidecar             # just the Go binaries
./scripts/build.sh windows             # Flutter Windows + sidecar
./scripts/build.sh macos               # Flutter macOS (both arches)
./scripts/build.sh linux               # Flutter Linux
```

Same `YY.M.D+<commit_count>` stamping. Handy for verifying a build
before pushing or for producing a dev-signed artifact.

## Code conventions

- Dart: `dart format .` before committing. CI enforces with
  `--set-exit-if-changed`.
- Dart analyze: `--fatal-infos`; info-level deprecations are errors.
- Go: `gofmt` + `go vet`. CI runs both.
- Line endings: LF (`.gitattributes` handles CRLF on Windows).

## Running tests locally

```powershell
# Dart
cd packages\deckhand_core
D:\git\flutter\bin\flutter.bat test

# Go sidecar
cd sidecar
go test ./...
```
