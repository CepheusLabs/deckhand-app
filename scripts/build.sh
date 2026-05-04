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

  # Per-(os,arch) subdir so cross-builds don't clobber each other.
  # Host-platform binaries also land at $DIST/ root unsuffixed so
  # packaging scripts (Inno Setup, AppImage, DMG) and the
  # `deckhand-sidecar doctor` smoke check find them at the same path
  # CI uses.
  local outdir="$DIST/${goos}-${goarch}"
  mkdir -p "$outdir"
  echo "=== Go sidecar: $goos/$goarch ==="
  local helper_syso=""

  # Windows: regenerate the elevated-helper's resource .syso from
  # its manifest so the embedded `requireAdministrator` element
  # always reflects the current source tree. The helper MUST ship
  # with this manifest — without it, ShellExecuteEx(verb=runas)
  # against the manifest-less .exe can fail silently on some
  # Windows builds (no UAC dialog, parent sees an empty events file).
  # `windres` ships with MinGW; CI uses the runner-provisioning
  # script to install it.
  if [ "$goos" = "windows" ]; then
    local helper_dir="$SIDECAR/cmd/deckhand-elevated-helper"
    if [ -f "$helper_dir/resource_windows.rc" ]; then
      helper_syso="$helper_dir/rsrc_windows.syso"
      ( cd "$helper_dir" && windres \
        -i resource_windows.rc -O coff -o rsrc_windows.syso )
    else
      echo "    WARN: resource_windows.rc missing — helper will ship without elevation manifest"
    fi
  fi

  for cmd in deckhand-sidecar deckhand-elevated-helper; do
    local ldflags="-s -w -X main.Version=$FULL"
    # Windows-only: link the elevated helper as a GUI-subsystem
    # binary so launching it via `Start-Process -Verb RunAs` does
    # NOT pop a black console window next to Deckhand. Console
    # subsystem is Go's Windows default; the helper writes events
    # via `--events-file` already, so no output is lost when
    # os.Stdout / os.Stderr aren't mapped to a console. The sidecar
    # stays in console subsystem because Flutter's Process.start
    # captures its stdout/stderr pipes for JSON-RPC.
    if [ "$goos" = "windows" ] && [ "$cmd" = "deckhand-elevated-helper" ]; then
      ldflags="$ldflags -H windowsgui"
    fi
    GOOS="$goos" GOARCH="$goarch" CGO_ENABLED=0 \
      go -C "$SIDECAR" build -trimpath \
        -ldflags "$ldflags" \
        -o "${outdir}/${cmd}${ext}" \
        "./cmd/${cmd}"
  done
  if [ -n "$helper_syso" ]; then
    rm -f "$helper_syso"
  fi

  if [ "$goos" = "$(go env GOOS)" ] && [ "$goarch" = "$(go env GOARCH)" ]; then
    cp "$outdir/deckhand-sidecar${ext}"         "$DIST/deckhand-sidecar${ext}"
    cp "$outdir/deckhand-elevated-helper${ext}" "$DIST/deckhand-elevated-helper${ext}"

    # Also seed the Flutter desktop runner output dirs when they
    # already exist, so a `flutter run` (or rerun of a dev build)
    # picks up freshly-built sidecar binaries without a manual copy.
    # These dirs only exist after at least one Flutter build has run;
    # we silently skip when absent so the first-ever sidecar build
    # doesn't error. Keeps the dev loop short:
    #   ./scripts/build.sh sidecar && flutter run -d windows
    # ...without "why is my Go change not in the running app?".
    case "$goos" in
      windows) flavors="Debug Release Profile" ;;
      *)       flavors="debug release profile" ;;
    esac
    case "$goos" in
      windows) runner_root="$APP/build/windows/x64/runner" ;;
      darwin)  runner_root="$APP/build/macos/Build/Products" ;;
      linux)   runner_root="$APP/build/linux/x64" ;;
      *)       runner_root="" ;;
    esac
    if [ -n "$runner_root" ]; then
      for flavor in $flavors; do
        local target_dir="$runner_root/$flavor"
        if [ "$goos" = "darwin" ]; then
          target_dir="$runner_root/$flavor/deckhand.app/Contents/MacOS"
        elif [ "$goos" = "linux" ]; then
          target_dir="$runner_root/$flavor/bundle"
        fi
        if [ -d "$target_dir" ]; then
          for cmd in deckhand-sidecar deckhand-elevated-helper; do
            cp "$outdir/${cmd}${ext}" "$target_dir/${cmd}${ext}" 2>/dev/null \
              || echo "    NOTE: could not refresh $target_dir/${cmd}${ext} (running app may be holding it open)"
          done
        fi
      done
    fi
  else
    # Cross-build: packaging scripts (Inno Setup, AppImage, DMG) read
    # from $DIST/ root and won't find these. Run packaging on a host
    # matching the target OS/arch, or run a separate `build_sidecar`
    # call there.
    echo "    (cross-build: packaging scripts can't find these unsuffixed; run on a $goos/$goarch host)"
  fi
  echo "    → $outdir"
}

build_flutter() {
  local target="$1"; shift || true
  echo "=== Flutter $target ==="
  ( cd "$APP" && "$FLUTTER" pub get >/dev/null )
  ( cd "$APP" && "$FLUTTER" create --platforms="$target" --project-name=deckhand . >/dev/null )
  ( cd "$APP" && "$FLUTTER" build "$target" "$@" \
      --build-name="$VERSION" \
      --build-number="$BUILD_NUMBER" )
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
