# Packaging

Scripts + configs for turning the Flutter build output + Go binaries
into OS-native installers.

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

See `.github/workflows/release.yml` for the full matrix.
