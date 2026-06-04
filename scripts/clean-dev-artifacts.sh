#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

flutter_packages=(
  packages/deckhand_core
  packages/deckhand_profiles
  packages/deckhand_ssh
  packages/deckhand_flash
  packages/deckhand_discovery
  packages/deckhand_hitl
  packages/deckhand_ui
  packages/deckhand_profile_script
  packages/deckhand_profile_lint
  packages/deckhand_lints
  app
)

for package in "${flutter_packages[@]}"; do
  echo "Cleaning Flutter/Dart artifacts in $package..."
  if grep -Eq '(^[[:space:]]*flutter:|sdk:[[:space:]]*flutter|flutter_test:)' "$package/pubspec.yaml"; then
    (cd "$package" && flutter clean)
  else
    rm -rf "$package/.dart_tool" "$package/build" "$package/coverage"
  fi
done

echo "Removing Go and script test artifacts..."
rm -f sidecar/coverage.out
find sidecar scripts -path "*/__pycache__" -type d -prune -print -exec rm -rf {} +
find sidecar -type f \( -name "*.test" -o -name "*.out" \) -print -delete

echo "Done."
