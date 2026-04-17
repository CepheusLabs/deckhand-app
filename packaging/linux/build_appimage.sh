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

# Placeholder icon — replace with a real one when the design lands.
touch "$APPDIR/deckhand.png"

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
