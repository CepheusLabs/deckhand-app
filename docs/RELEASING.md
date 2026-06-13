# Releasing Deckhand

The release pipeline is fully automated. This document captures what
the humans still need to do: cutting a tag, reviewing signing + SBOM
output, and handling hardware-in-the-loop smoke tests.

## Trigger

The canonical entry point is the cepheus-build release flow — it computes
the CalVer version, creates the tag, and pushes it. Pushing the tag is what
fires [`.github/workflows/release.yml`](../.github/workflows/release.yml),
a thin caller that delegates to the shared
`CepheusLabs/cepheus-build/.github/workflows/app-release.yml`.

- **Normal path:**

  ```powershell
  cd /d/git/CepheusLabs/deckhand-app
  ../cepheus-build/bin/cepheus-build release -p deckhand
  ```

  This pushes a CalVer tag `v<YY.M.D>-<count>` (no zero-padding; `<count>`
  is the total commit count). Add `--channel beta` to cut a pre-release
  instead — that pushes a `beta-v<YY.M.D>-<count>` tag. Either tag is
  matched by `release.yml`'s `on: push: tags: ['v*', 'beta-v*']` trigger.

- **Manual fallback:** `Actions → Release → Run workflow` via the
  `workflow_dispatch` trigger. It **must be dispatched from a TAG ref**
  (a `v...` / `beta-v...` tag), not a branch — the shared pipeline's
  prepare step rejects branch refs.

Versioning is CalVer — `YY.M.D` with no zero-padding, plus the total
commit count. `cepheus-build release` computes both; you don't set either.

## Required secrets

All optional; unset secrets downgrade the corresponding artifact to
unsigned instead of failing the build (the workflow prints a warning).

| Secret | Purpose |
|---|---|
| `WINDOWS_SIGN_THUMBPRINT` | Authenticode cert SHA-1 thumbprint — passed to `signtool /sha1`. |
| `MACOS_SIGN_CERT_P12` | Base64-encoded `.p12` Developer-ID Application cert. |
| `MACOS_SIGN_CERT_PASSWORD` | P12 password. |
| `MACOS_SIGN_ID` | Developer-ID Application common name (e.g. `Developer ID Application: Cepheus Labs (ABC1234567)`). |
| `MACOS_NOTARIZE_APPLE_ID`, `MACOS_NOTARIZE_PASSWORD`, `MACOS_NOTARIZE_TEAM_ID` | App Store Connect credentials for `xcrun notarytool submit`. |
| `GPG_SIGNING_KEY` | Armored PGP private key used to sign Linux AppImages + `SHA256SUMS`. |
| `GPG_SIGNING_KEY_PASSPHRASE` | Passphrase for the GPG key. |

Keep Windows cert + macOS cert renewals on the calendar a month before
expiry. A signed release with an expired chain still installs but
SmartScreen / Gatekeeper UX degrades.

## What each release produces

Per tag, attached to the GitHub Release:

- `deckhand-<VERSION>-x64-setup.exe` (Windows Inno Setup installer).
- `deckhand-<VERSION>-amd64.dmg` and `deckhand-<VERSION>-arm64.dmg`.
- `deckhand-<VERSION>-x86_64.AppImage` and `.AppImage.asc` (when GPG
  is configured).
- Raw sidecar binaries: `deckhand-sidecar(-<os>-<arch>)(.exe)` and
  `deckhand-elevated-helper(-<os>-<arch>)(.exe)`, four pairs.
- `SHA256SUMS` + `SHA256SUMS.asc` — signed checksum manifest.
- `manifest.json` — machine-readable release index keyed by platform
  and arch; the landing page fetches it instead of the GitHub API.
- `sbom.spdx.json` + `sbom.cdx.json` — SBOM in both SPDX and
  CycloneDX formats, covering the Go and Dart dep graphs.

## Pre-flight checklist

Before pushing the tag:

1. `go test -race -count=1 ./...` clean on a fresh checkout of the
   target ref.
2. Every Dart package: `flutter analyze --fatal-infos && flutter test`
   clean.
3. `go run ./cmd/deckhand-ipc-docs --check` — no drift.
4. `deckhand-sidecar doctor` on Windows + macOS + Linux dev machines.
5. CHANGELOG entry or release-notes summary drafted (the release
   body auto-generates from commit subjects, so a well-titled set of
   commits leading up to the tag is all you need).
6. Hardware-in-the-loop smoke test against the Sovol Zero (or Arco,
   whichever is nearest) — one stock-keep flow and one fresh-flash
   flow, end to end. Record the printer's sidecar log in the release
   PR for future regression comparisons. The automated HITL workflow
   ([`HITL.md`](HITL.md)) gates the tag-push pipeline; this manual run
   is the smoke test that confirms a maintainer-attended replication
   on the rig closest to release before the tag fires.

## Post-release checklist

After the workflow finishes:

1. Site: visit `https://dh.printdeck.io/` and confirm every download
   card resolves to the new artifact and shows the sha256 from
   `manifest.json`.
2. Fetch the AppImage on a clean Linux VM and verify the detached
   signature: `gpg --verify deckhand-*.AppImage.asc`.
3. Windows: install from the signed installer on a stock Windows VM
   and confirm no SmartScreen warning.
4. macOS: install the DMG on a fresh macOS account; confirm Gatekeeper
   opens the app without a right-click override.
5. Announce in `#releases` (Slack) with the release URL and any known
   issues from the HITL run.

## Rolling back

There is no "unrelease" button on GitHub — but:

1. Delete the release (keeps the tag) or delete both (retag).
2. Flip the site's `manifest.json` consumer to the prior release by
   moving the `latest/` pointer in the upload step (or ship a hotfix
   release that rewrites the manifest).
3. If a signed artifact has a security issue, revoke the Authenticode
   or Developer-ID signing as well — users who already installed
   won't see the revocation until their OS refreshes the CRL, but
   new installers will fail `signtool verify /pa`.

## Offline rebuild

To produce the same versioned artifacts locally for pre-tag smoke tests,
use the canonical build flow:

```powershell
cd /d/git/CepheusLabs/deckhand-app
../cepheus-build/bin/cepheus-build build -p deckhand desktop --execution-mode container [--container-profile errai]
```

`--execution-mode container` runs each OS leg in a container/VM on the
build pool and returns the artifacts to the repo (`--container-profile
errai` pins the errai pool; `--execution-mode local` builds host-native
instead). As a no-cepheus-build fallback, `./scripts/build.sh all` on a
dev machine produces the same artifacts directly. Either way they won't
be signed (no CI secrets on your laptop), so don't ship them to users.
