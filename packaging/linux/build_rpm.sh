#!/usr/bin/env bash
# Package Deckhand as an RPM.
#
#   build_rpm.sh <version>
#
# Consumes the Flutter Linux release bundle plus Deckhand's two Go binaries
# (deckhand-sidecar and deckhand-elevated-helper) and produces:
#   packaging/linux/dist/deckhand-<version>-1.x86_64.rpm
#
# Both Go binaries are embedded next to the Flutter binary inside
# /usr/lib/deckhand/, matching the AppImage build (build_appimage.sh).
#
# Signs via cepheus-build's shared scripts/sign-linux-gpg.sh (env-gated).
set -euo pipefail

VERSION="${1:-0.0.0-dev}"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUNDLE="$REPO_ROOT/app/build/linux/x64/release/bundle"
SIDECAR="$REPO_ROOT/sidecar/dist/deckhand-sidecar"
HELPER="$REPO_ROOT/sidecar/dist/deckhand-elevated-helper"
OUT_DIR="$REPO_ROOT/packaging/linux/dist"
APP="deckhand"
APPID="labs.cepheus.deckhand"
# rpm version fields may not contain '-'; normalize (e.g. 0.1.0-dev -> 0.1.0_dev).
RPM_VERSION="${VERSION//-/_}"

[ -d "$BUNDLE" ] || { echo "Missing $BUNDLE — build Flutter first"; exit 1; }
[ -x "$SIDECAR" ] || { echo "Missing $SIDECAR — build the Go sidecar first"; exit 1; }
[ -x "$HELPER" ]  || { echo "Missing $HELPER — build the Go elevated helper first"; exit 1; }
command -v rpmbuild >/dev/null 2>&1 || { echo "rpmbuild not found"; exit 1; }

BUILD="$OUT_DIR/rpm"
rm -rf "$BUILD"
mkdir -p "$BUILD"/{BUILD,RPMS,SOURCES,SPECS,BUILDROOT}

# Stage a buildroot tree the .spec just packages verbatim.
STAGE="$BUILD/stage"
mkdir -p "$STAGE/usr/lib/$APP" \
         "$STAGE/usr/bin" \
         "$STAGE/usr/share/applications" \
         "$STAGE/usr/share/icons/hicolor/256x256/apps"

# Flutter bundle + both Go binaries land together in /usr/lib/deckhand/.
cp -r "$BUNDLE/"* "$STAGE/usr/lib/$APP/"
cp "$SIDECAR" "$STAGE/usr/lib/$APP/deckhand-sidecar"
cp "$HELPER"  "$STAGE/usr/lib/$APP/deckhand-elevated-helper"
chmod +x "$STAGE/usr/lib/$APP/deckhand-sidecar" "$STAGE/usr/lib/$APP/deckhand-elevated-helper"
ln -sf "/usr/lib/$APP/$APP" "$STAGE/usr/bin/$APP"

cat > "$STAGE/usr/share/applications/$APPID.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Deckhand
Comment=Install Klipper / Kalico on 3D printers
Exec=$APP
Icon=$APPID
Categories=Utility;
Terminal=false
EOF

# Icon: prefer the real packaged icon, fall back to a minimal valid 1x1 PNG.
ICON_SRC="$REPO_ROOT/packaging/linux/deckhand.png"
if [ -f "$ICON_SRC" ] && [ -s "$ICON_SRC" ]; then
  cp "$ICON_SRC" "$STAGE/usr/share/icons/hicolor/256x256/apps/$APPID.png"
else
  printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\rIDATx\x9cc\xfc\xff\xff?\x03\x00\x05\xfe\x02\xfe\xa1V\xa3\x80\x00\x00\x00\x00IEND\xaeB`\x82' \
    > "$STAGE/usr/share/icons/hicolor/256x256/apps/$APPID.png"
fi

cat > "$BUILD/SPECS/$APP.spec" <<EOF
Name:           $APP
Version:        $RPM_VERSION
Release:        1
Summary:        Deckhand desktop app — installs Klipper/Kalico on 3D printers.
License:        Proprietary
URL:            https://github.com/CepheusLabs/deckhand
BuildArch:      x86_64
Requires:       gtk3
%description
Deckhand installs and configures Klipper / Kalico firmware on 3D printers.
%install
cp -r $STAGE/* %{buildroot}/
%files
/usr/lib/$APP
/usr/bin/$APP
/usr/share/applications/$APPID.desktop
/usr/share/icons/hicolor/256x256/apps/$APPID.png
EOF

mkdir -p "$OUT_DIR"
rpmbuild --define "_topdir $BUILD" \
         --define "_rpmdir $BUILD/RPMS" \
         --buildroot "$BUILD/BUILDROOT/stage" \
         -bb "$BUILD/SPECS/$APP.spec"

RPM="$(find "$BUILD/RPMS" -name '*.rpm' | head -1)"
# Use the normalized version in the filename so it matches the rpm's internal
# Version field (rpm forbids '-', so a dashed VERSION was normalized above).
DEST="$OUT_DIR/${APP}-${RPM_VERSION}-1.x86_64.rpm"
cp "$RPM" "$DEST"
echo "Wrote $DEST"

SIGNER="${CBUILD_TOOL_ROOT:-$REPO_ROOT/shared/cepheus-build}/scripts/sign-linux-gpg.sh"
[ -f "$SIGNER" ] && bash "$SIGNER" "$DEST" || echo "note: shared GPG signer not found; skipping signature"
