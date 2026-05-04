#!/bin/bash
# Package Deckhand for Linux as an AppImage.
#
# Produces Deckhand-<version>-linux-x86_64.AppImage from:
#   - app/build/linux/x64/release/bundle/     (Flutter app)
#   - sidecar/dist/deckhand-sidecar
#   - sidecar/dist/deckhand-elevated-helper
#
# Requires appimagetool in PATH (https://appimage.github.io/appimagetool/).

set -euo pipefail

VERSION="${1:-0.0.0-dev}"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FLUTTER_BUNDLE="$REPO_ROOT/app/build/linux/x64/release/bundle"
SIDECAR="$REPO_ROOT/sidecar/dist/deckhand-sidecar"
HELPER="$REPO_ROOT/sidecar/dist/deckhand-elevated-helper"
OUT_DIR="$REPO_ROOT/packaging/linux/dist"
APPDIR="$OUT_DIR/Deckhand.AppDir"

[ -d "$FLUTTER_BUNDLE" ] || { echo "Missing $FLUTTER_BUNDLE — build Flutter first"; exit 1; }
[ -x "$SIDECAR" ]        || { echo "Missing $SIDECAR"; exit 1; }
[ -x "$HELPER" ]         || { echo "Missing $HELPER"; exit 1; }

command -v appimagetool >/dev/null 2>&1 || {
  echo "appimagetool not in PATH. Install from https://appimage.github.io/appimagetool/"
  exit 1
}

rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/lib"

# Copy everything from the Flutter bundle into usr/bin + usr/lib.
cp -r "$FLUTTER_BUNDLE/"* "$APPDIR/usr/bin/"
cp "$SIDECAR" "$APPDIR/usr/bin/deckhand-sidecar"
cp "$HELPER"  "$APPDIR/usr/bin/deckhand-elevated-helper"
chmod +x "$APPDIR/usr/bin/deckhand-sidecar" "$APPDIR/usr/bin/deckhand-elevated-helper"

# Desktop entry — required by AppImage.
cat > "$APPDIR/deckhand.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Deckhand
Comment=Install Klipper / Kalico on 3D printers
Exec=deckhand
Icon=deckhand
Categories=Utility;
Terminal=false
EOF

# Icon: prefer a real packaged icon if present, fall back to a minimal
# valid 1x1 transparent PNG (NOT zero-byte - that ships a broken-image
# launcher placeholder to every Linux user). Drop a real icon at
# packaging/linux/deckhand.png when the design lands and this script
# will pick it up automatically.
ICON_SRC="$REPO_ROOT/packaging/linux/deckhand.png"
if [ -f "$ICON_SRC" ] && [ -s "$ICON_SRC" ]; then
  cp "$ICON_SRC" "$APPDIR/deckhand.png"
else
  # Embedded minimal transparent PNG (67 bytes, 1x1). Rendering as
  # a blank tile is acceptable; an empty file is not (appimagetool
  # warns and some launchers display a broken-image symbol).
  printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\rIDATx\x9cc\xfc\xff\xff?\x03\x00\x05\xfe\x02\xfe\xa1V\xa3\x80\x00\x00\x00\x00IEND\xaeB`\x82' \
    > "$APPDIR/deckhand.png"
fi

# AppRun — launches the Flutter binary with LD_LIBRARY_PATH set for bundled libs.
cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="$HERE/usr/lib:$LD_LIBRARY_PATH"
exec "$HERE/usr/bin/deckhand" "$@"
EOF
chmod +x "$APPDIR/AppRun"

# Build!
mkdir -p "$OUT_DIR"
OUTPUT="$OUT_DIR/Deckhand-$VERSION-linux-x86_64.AppImage"
ARCH=x86_64 appimagetool "$APPDIR" "$OUTPUT"

echo "Wrote $OUTPUT"
