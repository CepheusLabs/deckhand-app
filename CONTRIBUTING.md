# Contributing to Deckhand

## Commit messages — Conventional Commits

Deckhand uses [Conventional Commits](https://www.conventionalcommits.org)
so [release-please](https://github.com/googleapis/release-please) can
compute the next version and generate a changelog automatically.

Structure:

```
<type>[optional scope]: <short summary>

[optional body]

[optional footers, e.g. BREAKING CHANGE: …]
```

### Types we use

| Type | When | Bumps |
|------|------|-------|
| `feat:` | new user-visible feature | minor (`0.X.0`) |
| `fix:` | bug fix | patch (`0.0.X`) |
| `perf:` | performance improvement | patch |
| `refactor:` | internal cleanup, no behavior change | patch |
| `docs:` | docs only | patch |
| `test:` | tests only | patch |
| `build:` | build system / packaging | patch |
| `ci:` | CI config | patch |
| `chore:` | misc housekeeping | none (hidden) |
| `ui:` | Flutter UI work | patch (shown in changelog under "UI") |
| `prod:` | production-readiness work | minor |

### Breaking changes

Any commit with `!` after the type (`feat!:` or `fix!:`) **or** a
`BREAKING CHANGE:` footer bumps **major** (`X.0.0`). Example:

```
feat!: replace SshService.run signature

BREAKING CHANGE: run() now requires an explicit Duration timeout.
```

### Scopes

Free-form; use when it clarifies. Examples:

```
feat(ui): add stepper to wizard screens
fix(sidecar): crash on empty disk list
docs(profiles): clarify DSL predicate list
```

## How releases are cut

1. You merge PRs to `main` with conventional-commit titles.
2. Release Please watches `main` and maintains a **release PR**
   (`chore(main): release X.Y.Z`) that bumps
   `.release-please-manifest.json`, updates every `pubspec.yaml`
   version, and adds the changelog entry.
3. When you merge the release PR, release-please tags the repo
   (`vX.Y.Z`).
4. The tag push fires `.github/workflows/release.yml`, which builds
   the sidecar, elevated helper, and Flutter apps for every target OS
   and publishes a draft GitHub release with all installers attached.
5. You review the draft release on GitHub and hit publish.

### Off-cycle releases

If you need to cut a tag without going through the Release Please PR
(e.g., an emergency fix), use **Actions → "Manual release tag" → Run
workflow** and enter a SemVer string. The tag still fires
`release.yml`.

## Code conventions

- Dart: run `dart format .` before committing. CI enforces.
- Dart analyze: runs `--fatal-infos`; info-level deprecations are
  treated as errors.
- Go: standard `gofmt` + `go vet`. CI runs both.
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
