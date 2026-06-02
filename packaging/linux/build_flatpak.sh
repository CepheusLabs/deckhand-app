#!/usr/bin/env bash
# Package Deckhand as a single-file Flatpak bundle.
#
#   build_flatpak.sh <version>
#
# Consumes the Flutter Linux release bundle plus Deckhand's two Go binaries
# (deckhand-sidecar and deckhand-elevated-helper) and produces:
#   packaging/linux/dist/deckhand-<version>.flatpak
#
# Uses flatpak-builder against labs.cepheus.deckhand.yml. Both Go binaries are
# staged next to the manifest so it can install them into /app/lib/deckhand/
# alongside the Flutter binary (matching the AppImage / .deb / .rpm builds).
# The OSTree repo is then signed + the single-file bundle GPG-signed via
# cepheus-build's shared scripts/sign-linux-gpg.sh (env-gated).
set -euo pipefail

VERSION="${1:-0.0.0-dev}"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$REPO_ROOT/packaging/linux"
BUNDLE="$REPO_ROOT/app/build/linux/x64/release/bundle"
SIDECAR="$REPO_ROOT/sidecar/dist/deckhand-sidecar"
HELPER="$REPO_ROOT/sidecar/dist/deckhand-elevated-helper"
OUT_DIR="$REPO_ROOT/packaging/linux/dist"
APPID="labs.cepheus.deckhand"

[ -d "$BUNDLE" ] || { echo "Missing $BUNDLE — build Flutter first"; exit 1; }
[ -x "$SIDECAR" ] || { echo "Missing $SIDECAR — build the Go sidecar first"; exit 1; }
[ -x "$HELPER" ]  || { echo "Missing $HELPER — build the Go elevated helper first"; exit 1; }
command -v flatpak-builder >/dev/null 2>&1 || { echo "flatpak-builder not found"; exit 1; }

# Stage everything the manifest's simple buildsystem copies (offline build):
# the Flutter bundle under bundle/, and both Go binaries at the stage root.
STAGE="$OUT_DIR/flatpak-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE/bundle"
cp -r "$BUNDLE/"* "$STAGE/bundle/"
cp "$SIDECAR" "$STAGE/deckhand-sidecar"
cp "$HELPER"  "$STAGE/deckhand-elevated-helper"
chmod +x "$STAGE/deckhand-sidecar" "$STAGE/deckhand-elevated-helper"

cat > "$STAGE/$APPID.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Deckhand
Comment=Install Klipper / Kalico on 3D printers
Exec=deckhand
Icon=$APPID
Categories=Utility;
Terminal=false
EOF

# Icon: prefer the real packaged icon, fall back to a minimal valid 1x1 PNG so
# install -Dm644 icon.png never fails (and never ships a broken-image tile).
ICON_SRC="$REPO_ROOT/packaging/linux/deckhand.png"
if [ -f "$ICON_SRC" ] && [ -s "$ICON_SRC" ]; then
  cp "$ICON_SRC" "$STAGE/icon.png"
else
  printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\rIDATx\x9cc\xfc\xff\xff?\x03\x00\x05\xfe\x02\xfe\xa1V\xa3\x80\x00\x00\x00\x00IEND\xaeB`\x82' > "$STAGE/icon.png"
fi

BUILD_DIR="$OUT_DIR/flatpak-build"
REPO="$OUT_DIR/flatpak-repo"
rm -rf "$BUILD_DIR"
mkdir -p "$OUT_DIR"

# Optional GPG signing of the OSTree repo (env-gated; reuse the shared helper's
# key import). Resolve the signing key id without forcing a signature.
GPG_ARGS=()
SIGNER="${CBUILD_TOOL_ROOT:-$REPO_ROOT/shared/cepheus-build}/scripts/sign-linux-gpg.sh"
if [ -f "$SIGNER" ] && [ -n "${GPG_SIGNING_KEY:-}" ]; then
  # shellcheck source=/dev/null
  source "$SIGNER"
  if key_id="$(ensure_gpg_key 2>/dev/null)"; then GPG_ARGS=(--gpg-sign="$key_id"); fi
fi

echo "==> flatpak-builder (v$VERSION)"
# flatpak-builder resolves a `dir` source `path:` relative to the MANIFEST's
# directory. We stage under $OUT_DIR, so run against a copy of the manifest
# placed there — then `path: flatpak-stage` resolves to $OUT_DIR/flatpak-stage.
cp "$HERE/$APPID.yml" "$OUT_DIR/$APPID.yml"
flatpak-builder --force-clean --repo="$REPO" "${GPG_ARGS[@]}" \
  "$BUILD_DIR" "$OUT_DIR/$APPID.yml"

BUNDLE_OUT="$OUT_DIR/deckhand-${VERSION}.flatpak"
flatpak build-bundle "${GPG_ARGS[@]}" "$REPO" "$BUNDLE_OUT" "$APPID"
echo "Wrote $BUNDLE_OUT"

# Detached GPG signature on the single-file bundle too (env-gated).
[ -f "$SIGNER" ] && bash "$SIGNER" "$BUNDLE_OUT" || true
