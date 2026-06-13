# Packaging

Scripts + configs for turning the Flutter build output + Go binaries
into OS-native installers.

These scripts are recipes that the cepheus-build flow invokes — you
normally produce installers through it, which runs `scripts/build.sh`
plus the packaging script for each target:

```powershell
cd /d/git/CepheusLabs/deckhand-app
../cepheus-build/bin/cepheus-build build -p deckhand windows-installer
../cepheus-build/bin/cepheus-build build -p deckhand macos-dmg
../cepheus-build/bin/cepheus-build build -p deckhand linux-appimage
../cepheus-build/bin/cepheus-build build -p deckhand linux-deb linux-rpm linux-flatpak
```

(Or build every desktop installer at once with the `desktop_packages`
group.) The tables below document the underlying scripts the flow calls.

| OS | Script / config | Output |
|----|-----------------|--------|
| Windows | `windows/deckhand.iss` (Inno Setup) | `Deckhand-<ver>-win-x64.exe` |
| macOS | `macos/build_dmg.sh` | `Deckhand-<ver>-macos.dmg` |
| Linux | `linux/build_appimage.sh` | `Deckhand-<ver>-linux-x86_64.AppImage` |

## Prerequisites per host

### Windows
- [Inno Setup 6+](https://jrsoftware.org/isdl.php) (`iscc` in PATH)
- `app\build\windows\x64\runner\Release\` populated via `flutter build windows --release`
- `sidecar\dist\deckhand-sidecar.exe` + `deckhand-elevated-helper.exe`

### macOS
- Xcode command-line tools
- `create-dmg` (via `brew install create-dmg`) — optional; `hdiutil` fallback is included
- `app/build/macos/Build/Products/Release/deckhand.app` populated via `flutter build macos --release`

### Linux
- `appimagetool` in PATH
- `app/build/linux/x64/release/bundle/` populated via `flutter build linux --release`

## Signing + notarization

Gated on environment variables so unsigned builds "just work" during
early development:

- Windows: `SIGNTOOL_CERT_THUMBPRINT` — signtool runs in CI if present.
- macOS: `MACOS_SIGN_ID`, `MACOS_NOTARIZE_APPLE_ID`, `MACOS_NOTARIZE_PASSWORD`,
  `MACOS_NOTARIZE_TEAM_ID`.
- Linux: no signing required; consider GPG-signing the `.AppImage`
  artifact in CI.

The packaging targets, hosts, and publish stores are defined in
cepheus-build's `products/deckhand.toml` (`windows-installer`,
`macos-dmg`, `linux-appimage`, `linux-deb`, `linux-rpm`,
`linux-flatpak`, plus the `github_release` store). `release.yml` in this
repo is now a thin caller that delegates to the shared
`app-release.yml` — it carries no build matrix of its own. Run
`../cepheus-build/bin/cepheus-build describe -p deckhand --json` to see
the current enabled targets and stores.
