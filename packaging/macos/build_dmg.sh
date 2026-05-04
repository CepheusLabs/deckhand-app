#!/bin/bash
# Package Deckhand for macOS.
#
# Produces Deckhand-<version>-macos.dmg from:
#   - app/build/macos/Build/Products/Release/deckhand.app
#   - sidecar/dist/deckhand-sidecar
#   - sidecar/dist/deckhand-elevated-helper
#
# The sidecar + helper are copied into the .app bundle's MacOS dir so
# they ship alongside the Flutter binary.
#
# Signing + notarization gated on environment:
#   MACOS_SIGN_ID=Developer ID Application: ...
#   MACOS_NOTARIZE_APPLE_ID / MACOS_NOTARIZE_PASSWORD / MACOS_NOTARIZE_TEAM_ID
# If any are missing, the script emits an unsigned DMG with a warning.

set -euo pipefail

VERSION="${1:-0.0.0-dev}"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_BUNDLE="$REPO_ROOT/app/build/macos/Build/Products/Release/deckhand.app"
SIDECAR="$REPO_ROOT/sidecar/dist/deckhand-sidecar"
HELPER="$REPO_ROOT/sidecar/dist/deckhand-elevated-helper"
OUT_DIR="$REPO_ROOT/packaging/macos/dist"
DMG="$OUT_DIR/Deckhand-$VERSION-macos.dmg"

[ -d "$APP_BUNDLE" ] || { echo "Missing $APP_BUNDLE — build Flutter first"; exit 1; }
[ -x "$SIDECAR" ]    || { echo "Missing $SIDECAR"; exit 1; }
[ -x "$HELPER" ]     || { echo "Missing $HELPER"; exit 1; }

mkdir -p "$OUT_DIR"

# Embed sidecar + helper into the app bundle.
cp "$SIDECAR" "$APP_BUNDLE/Contents/MacOS/"
cp "$HELPER"  "$APP_BUNDLE/Contents/MacOS/"

# Sign if cert present.
#
# `codesign --deep` re-signs nested binaries with the app's identity
# but does NOT propagate per-binary entitlements. The elevated helper
# specifically needs its own entitlements (hardened-runtime exceptions
# documented in helper.entitlements) or Gatekeeper rejects it at
# runtime on macOS 13+. We sign the inner binaries individually FIRST
# with their own entitlements, then run --deep on the bundle to seal
# everything else.
if [ -n "${MACOS_SIGN_ID:-}" ]; then
  HELPER_ENTITLEMENTS="$REPO_ROOT/packaging/macos/helper.entitlements"
  SIDECAR_ENTITLEMENTS="$REPO_ROOT/packaging/macos/sidecar.entitlements"
  EMBEDDED_HELPER="$APP_BUNDLE/Contents/MacOS/deckhand-elevated-helper"
  EMBEDDED_SIDECAR="$APP_BUNDLE/Contents/MacOS/deckhand-sidecar"

  echo "Signing $EMBEDDED_HELPER with helper entitlements"
  codesign --force --options runtime --timestamp \
    --sign "$MACOS_SIGN_ID" \
    --entitlements "$HELPER_ENTITLEMENTS" \
    "$EMBEDDED_HELPER"

  echo "Signing $EMBEDDED_SIDECAR with sidecar entitlements"
  codesign --force --options runtime --timestamp \
    --sign "$MACOS_SIGN_ID" \
    --entitlements "$SIDECAR_ENTITLEMENTS" \
    "$EMBEDDED_SIDECAR"

  echo "Signing $APP_BUNDLE with $MACOS_SIGN_ID (--deep, but inner binaries already signed)"
  codesign --force --options runtime --timestamp --sign "$MACOS_SIGN_ID" \
    --deep "$APP_BUNDLE"

  # Verify each inner binary kept its own signature + entitlements
  # rather than getting flattened by --deep. Fails the build if --deep
  # ever changes behavior and clobbers what we just signed.
  for bin in "$EMBEDDED_HELPER" "$EMBEDDED_SIDECAR"; do
    echo "Verifying $bin"
    codesign --verify --strict --verbose=2 "$bin"
    codesign -d --entitlements - "$bin" | grep -q "disable-library-validation" \
      || { echo "ERROR: $bin lost its entitlements after --deep"; exit 1; }
  done
else
  echo "MACOS_SIGN_ID not set — producing unsigned app bundle"
fi

# Build the DMG. create-dmg is the convention; fallback to hdiutil.
STAGE="$OUT_DIR/stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP_BUNDLE" "$STAGE/"

if command -v create-dmg >/dev/null 2>&1; then
  create-dmg \
    --volname "Deckhand $VERSION" \
    --window-size 540 380 \
    --icon-size 96 \
    --app-drop-link 400 190 \
    --icon "deckhand.app" 140 190 \
    "$DMG" "$STAGE" || true
else
  hdiutil create -volname "Deckhand $VERSION" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG"
fi

# Notarize if credentials present.
if [ -n "${MACOS_NOTARIZE_APPLE_ID:-}" ] && \
   [ -n "${MACOS_NOTARIZE_PASSWORD:-}" ] && \
   [ -n "${MACOS_NOTARIZE_TEAM_ID:-}" ]; then
  echo "Submitting $DMG for notarization"
  xcrun notarytool submit "$DMG" \
    --apple-id "$MACOS_NOTARIZE_APPLE_ID" \
    --password "$MACOS_NOTARIZE_PASSWORD" \
    --team-id "$MACOS_NOTARIZE_TEAM_ID" \
    --wait
  xcrun stapler staple "$DMG" || true
else
  echo "MACOS_NOTARIZE_* not set — DMG is not notarized; users will need to"
  echo "    xattr -d com.apple.quarantine Deckhand.app"
fi

echo "Wrote $DMG"
