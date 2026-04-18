#!/usr/bin/env bash
#
# Auto-versioned build wrapper for Deckhand.
#
# Mirrors Printdeck's frontend/scripts/build.sh — version comes from
# today's date, build number comes from total git commit count. Both
# the Flutter app and the Go sidecar + elevated helper get stamped.
#
# Version:      YY.M.D   (not zero-padded; matches Printdeck)
# Build number: git commit count (always increases)
#
# Usage:
#   ./scripts/build.sh sidecar              # just the Go binaries
#   ./scripts/build.sh windows              # Flutter Windows build + sidecar
#   ./scripts/build.sh macos                # Flutter macOS build + sidecar
#   ./scripts/build.sh linux                # Flutter Linux build + sidecar
#   ./scripts/build.sh all                  # all three desktop targets
#   ./scripts/build.sh <platform> --debug   # pass flags through to `flutter build`

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
APP="$REPO/app"
SIDECAR="$REPO/sidecar"
DIST="$SIDECAR/dist"

cd "$REPO"

# --- Version: YY.M.D, build number: commit count ---
VERSION=$(date +"%y.%-m.%-d" 2>/dev/null \
  || date -j +"%y.%-m.%-d" 2>/dev/null \
  || date +"%y.%m.%d")
BUILD_NUMBER=$(git rev-list --count HEAD)
FULL="$VERSION+$BUILD_NUMBER"

echo "Deckhand build: $FULL"
echo "  repo:    $REPO"
echo

if [ $# -eq 0 ]; then
  cat <<EOF
Usage: $0 <target> [flutter build flags...]

Targets:
  sidecar                Go sidecar + elevated helper (host GOOS/GOARCH)
  windows|macos|linux    Flutter desktop app for that OS (also builds sidecar)
  all                    Flutter windows+macos+linux + sidecar

Version stamped in this build: $FULL
EOF
  exit 1
fi

PLATFORM="$1"
shift || true

# --- Resolve Flutter binary (adjust if you install elsewhere) ---
FLUTTER="${FLUTTER_BIN:-flutter}"
if [ "${OS:-}" = "Windows_NT" ] && [ -x "/d/git/flutter/bin/flutter.bat" ]; then
  FLUTTER="/d/git/flutter/bin/flutter.bat"
fi

build_sidecar() {
  local goos="${1:-$(go env GOOS)}"
  local goarch="${2:-$(go env GOARCH)}"
  local ext=""
  [ "$goos" = "windows" ] && ext=".exe"

  mkdir -p "$DIST"
  echo "=== Go sidecar: $goos/$goarch ==="
  for cmd in deckhand-sidecar deckhand-elevated-helper; do
    GOOS="$goos" GOARCH="$goarch" CGO_ENABLED=0 \
      go -C "$SIDECAR" build -trimpath \
        -ldflags "-s -w -X main.Version=$FULL" \
        -o "$DIST/${cmd}-${goos}-${goarch}${ext}" \
        "./cmd/${cmd}"
  done
  echo "    → $DIST"
}

build_flutter() {
  local target="$1"; shift || true
  echo "=== Flutter $target ==="
  "$FLUTTER" -C "$APP" pub get >/dev/null
  "$FLUTTER" -C "$APP" create --platforms="$target" --project-name=deckhand . >/dev/null
  "$FLUTTER" -C "$APP" build "$target" "$@" \
    --build-name="$VERSION" \
    --build-number="$BUILD_NUMBER"
}

case "$PLATFORM" in
  sidecar)
    build_sidecar
    ;;
  windows)
    build_sidecar windows amd64
    build_flutter windows "$@"
    ;;
  macos)
    build_sidecar darwin amd64
    build_sidecar darwin arm64
    build_flutter macos "$@"
    ;;
  linux)
    build_sidecar linux amd64
    build_flutter linux "$@"
    ;;
  all)
    build_sidecar windows amd64
    build_sidecar darwin  amd64
    build_sidecar darwin  arm64
    build_sidecar linux   amd64
    # Only the current host's Flutter target can build end-to-end
    # without a cross-platform toolchain.
    host_os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    case "$host_os" in
      darwin)   build_flutter macos "$@" ;;
      linux)    build_flutter linux "$@" ;;
      mingw*|msys*|cygwin*|*nt*|windows*) build_flutter windows "$@" ;;
      *) echo "Unknown host $host_os; skipping Flutter build" ;;
    esac
    ;;
  *)
    echo "Unknown target: $PLATFORM" >&2
    exit 1
    ;;
esac

echo
echo "Built Deckhand: $FULL"
