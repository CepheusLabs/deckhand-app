# Contributing to Deckhand

## Versioning

Deckhand uses **date-based CalVer** (matching Printdeck's
`frontend/scripts/build.sh`):

- **Version**: today's UTC date, not zero-padded - `YY.M.D` (e.g. `26.4.18`)
- **Build number**: total `git rev-list --count HEAD` (monotonic)
- **Tag**: `v<VERSION>-<BUILD>` (e.g. `v26.4.18-1247`)

The version is computed automatically - there's nothing to bump, nothing
to remember. `cepheus-build release -p deckhand` stamps it when you cut a
release (see [How releases happen](#how-releases-happen)).

## Commit messages

No conventional-commits discipline required (but no harm in using them
if you want - the release notes are generated from `git log`).

Keep commits reasonably self-contained and their subjects meaningful;
the GitHub Release for each version lists every commit that landed since
the previous one.

## How releases happen

Releases are **not** triggered by pushing to `main`, and `release.yml`
no longer computes the version, builds artifacts, or creates the tag. The
canonical release flow lives in cepheus-build:

```powershell
cd /d/git/CepheusLabs/deckhand-app
../cepheus-build/bin/cepheus-build release -p deckhand
```

1. `cepheus-build release -p deckhand` computes the CalVer version and
   **creates + pushes** the tag `v<YY.M.D>-<count>` (add `--channel beta`
   for a `beta-v<YY.M.D>-<count>` pre-release tag).
2. Pushing that tag fires `.github/workflows/release.yml`, a thin caller
   that delegates to the shared
   `CepheusLabs/cepheus-build/.github/workflows/app-release.yml`.
3. The shared pipeline builds the Go sidecar + elevated helper and the
   Flutter app on the self-hosted runner fleet, runs the packaging
   recipes (Inno Setup / create-dmg / appimagetool / deb / rpm /
   flatpak), signs + notarizes when the secrets are configured, and
   publishes a GitHub Release with every artifact attached and
   auto-generated notes from the commits since the previous tag.

Takes ~25-30 minutes end-to-end. The longest jobs are the macOS and
Windows Flutter builds.

## Off-cycle / rebuild an old version

`Actions → Release → Run workflow` via the `workflow_dispatch` trigger.
It **must be dispatched from a TAG ref** (a `v...` / `beta-v...` tag),
not a branch — the shared pipeline's prepare step rejects branch refs.
To rebuild an existing version, dispatch from that tag; to cut a new
one, run `cepheus-build release -p deckhand` again.

## Local builds

The canonical local build uses cepheus-build:

```powershell
cd /d/git/CepheusLabs/deckhand-app
../cepheus-build/bin/cepheus-build build -p deckhand desktop                          # macos windows linux
../cepheus-build/bin/cepheus-build build -p deckhand windows                          # one target
../cepheus-build/bin/cepheus-build build -p deckhand desktop --execution-mode container  # cross-OS in container/VM pool
```

Use `--execution-mode container` (optionally `--container-profile errai`)
to build OS legs you can't build host-native; `--execution-mode local`
(the default) builds on the host.

Under the hood the flow invokes `scripts/build.sh`, which you can also
run directly for a quick host-native build:

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

PowerShell (Windows + cross-platform PS 7+):

```powershell
# Dart — run across the whole monorepo
$packages = @(
  'packages\deckhand_core',
  'packages\deckhand_profile_script',
  'packages\deckhand_profile_lint',
  'packages\deckhand_profiles',
  'packages\deckhand_ssh',
  'packages\deckhand_flash',
  'packages\deckhand_discovery',
  'packages\deckhand_ui',
  'app'
)
foreach ($p in $packages) {
  Push-Location $p
  flutter test
  Pop-Location
}

# Go sidecar
Push-Location sidecar
go test -race -count=1 ./...
golangci-lint run ./...
go run ./cmd/deckhand-ipc-docs       # regenerate IPC-METHODS.md
Pop-Location

# Profile lint against a local deckhand-profiles checkout
Push-Location packages\deckhand_profile_lint
dart run bin/deckhand_profile_lint.dart --root ..\..\..\deckhand-profiles --strict
Pop-Location
```

bash equivalent:

```bash
for p in packages/deckhand_core packages/deckhand_profile_script \
         packages/deckhand_profile_lint packages/deckhand_profiles \
         packages/deckhand_ssh packages/deckhand_flash \
         packages/deckhand_discovery packages/deckhand_ui app; do
  (cd "$p" && flutter test) || exit 1
done
(cd sidecar && go test -race -count=1 ./... && golangci-lint run ./...)
(cd sidecar && go run ./cmd/deckhand-ipc-docs)
(cd packages/deckhand_profile_lint && \
   dart run bin/deckhand_profile_lint.dart --root ../../../deckhand-profiles --strict)
```

## Self-diagnostic

`deckhand-sidecar doctor` runs a preflight over the user's machine
(helper-binary presence, disk enumeration, elevation tool on PATH,
writable data/cache dirs). Useful both in a bug report and during
packaging work:

```powershell
cd sidecar
go run ./cmd/deckhand-sidecar doctor
```

Exit 0 means healthy, 1 means at least one `[FAIL]` surfaced.

## Dry-run mode

Toggle `Settings → Dry-run` (or set `dry_run: true` in
`settings.json`) to exercise the full wizard without touching any
disk or running `sudo` on the printer. Every destructive step
renders a simulated progress stream; the persistent banner at the
top of every screen makes it impossible to forget dry-run is on.

## Security-sensitive changes

See [SECURITY.md](SECURITY.md) for the reviewer checklist when
touching disk writes, profile fetch, elevation, or the IPC surface.
