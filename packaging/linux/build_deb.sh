#!/usr/bin/env bash
# Package Deckhand as a Debian .deb.
#
#   build_deb.sh <version>
#
# Consumes the Flutter Linux release bundle (app/build/linux/x64/release/bundle)
# plus the two Go binaries Deckhand ships (deckhand-sidecar and
# deckhand-elevated-helper) and produces:
#   packaging/linux/dist/deckhand-<version>-linux-amd64.deb
#
# Both Go binaries are embedded next to the Flutter binary inside
# /usr/lib/deckhand/ so the installed app finds them alongside itself, exactly
# like the AppImage build (packaging/linux/build_appimage.sh) does.
#
# After building, signs it with a detached GPG signature via cepheus-build's
# shared scripts/sign-linux-gpg.sh (env-gated: unsigned + warning without a key).
set -euo pipefail

VERSION="${1:-0.0.0-dev}"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUNDLE="$REPO_ROOT/app/build/linux/x64/release/bundle"
SIDECAR="$REPO_ROOT/sidecar/dist/deckhand-sidecar"
HELPER="$REPO_ROOT/sidecar/dist/deckhand-elevated-helper"
OUT_DIR="$REPO_ROOT/packaging/linux/dist"
APP="deckhand"
APPID="labs.cepheus.deckhand"

[ -d "$BUNDLE" ] || { echo "Missing $BUNDLE — build Flutter first"; exit 1; }
[ -x "$SIDECAR" ] || { echo "Missing $SIDECAR — build the Go sidecar first"; exit 1; }
[ -x "$HELPER" ]  || { echo "Missing $HELPER — build the Go elevated helper first"; exit 1; }

DEB_ROOT="$OUT_DIR/deb/${APP}_${VERSION}_amd64"
rm -rf "$DEB_ROOT"
mkdir -p "$DEB_ROOT/DEBIAN" \
         "$DEB_ROOT/usr/lib/$APP" \
         "$DEB_ROOT/usr/bin" \
         "$DEB_ROOT/usr/share/applications" \
         "$DEB_ROOT/usr/share/icons/hicolor/256x256/apps"

# Flutter bundle + both Go binaries land together in /usr/lib/deckhand/.
cp -r "$BUNDLE/"* "$DEB_ROOT/usr/lib/$APP/"
cp "$SIDECAR" "$DEB_ROOT/usr/lib/$APP/deckhand-sidecar"
cp "$HELPER"  "$DEB_ROOT/usr/lib/$APP/deckhand-elevated-helper"
chmod +x "$DEB_ROOT/usr/lib/$APP/deckhand-sidecar" "$DEB_ROOT/usr/lib/$APP/deckhand-elevated-helper"
ln -sf "/usr/lib/$APP/$APP" "$DEB_ROOT/usr/bin/$APP"

cat > "$DEB_ROOT/DEBIAN/control" <<EOF
Package: $APP
Version: $VERSION
Section: utils
Priority: optional
Architecture: amd64
Depends: libgtk-3-0, libblkid1, liblzma5
Maintainer: Cepheus Labs, LLC <support@cepheuslabs.com>
Description: Deckhand desktop app — installs Klipper/Kalico on 3D printers.
 Deckhand installs and configures Klipper / Kalico firmware on 3D printers.
EOF

cat > "$DEB_ROOT/usr/share/applications/$APPID.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Deckhand
Comment=Install Klipper / Kalico on 3D printers
Exec=$APP
Icon=$APPID
Categories=Utility;
Terminal=false
EOF

# Icon: prefer the real packaged icon, fall back to a minimal valid 1x1 PNG so
# the package never ships a broken-image launcher placeholder.
ICON_SRC="$REPO_ROOT/packaging/linux/deckhand.png"
if [ -f "$ICON_SRC" ] && [ -s "$ICON_SRC" ]; then
  cp "$ICON_SRC" "$DEB_ROOT/usr/share/icons/hicolor/256x256/apps/$APPID.png"
else
  printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\rIDATx\x9cc\xfc\xff\xff?\x03\x00\x05\xfe\x02\xfe\xa1V\xa3\x80\x00\x00\x00\x00IEND\xaeB`\x82' \
    > "$DEB_ROOT/usr/share/icons/hicolor/256x256/apps/$APPID.png"
fi

mkdir -p "$OUT_DIR"
DEB="$OUT_DIR/${APP}-${VERSION}-linux-amd64.deb"
dpkg-deb --build --root-owner-group "$DEB_ROOT" "$DEB"
echo "Wrote $DEB"

# Detached GPG signature (env-gated).
SIGNER="${CBUILD_TOOL_ROOT:-$REPO_ROOT/shared/cepheus-build}/scripts/sign-linux-gpg.sh"
[ -f "$SIGNER" ] && bash "$SIGNER" "$DEB" || echo "note: shared GPG signer not found; skipping signature"
