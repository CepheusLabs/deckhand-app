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

usage() {
  cat <<'USAGE'
Usage: scripts/quality.sh [all|fmt|lint|test]...

Runs Deckhand's standard local quality gates. With no phase, runs all.
USAGE
}

flutter_coverage_floor() {
  case "$1" in
    packages/deckhand_core) echo 70 ;;
    packages/deckhand_ui) echo 60 ;;
    packages/deckhand_profile_script) echo 80 ;;
    packages/deckhand_profile_lint) echo 80 ;;
    packages/deckhand_profiles) echo 40 ;;
    packages/deckhand_ssh) echo 20 ;;
    packages/deckhand_flash) echo 30 ;;
    packages/deckhand_discovery) echo 30 ;;
    packages/deckhand_hitl) echo 40 ;;
    *) echo 0 ;;
  esac
}

check_flutter_coverage() {
  local package="$1"
  local lcov="$package/coverage/lcov.info"
  [[ -f "$lcov" ]] || return 0

  local hit found pct floor
  read -r hit found < <(awk -F: '/^LH:/{h+=$2} /^LF:/{f+=$2} END {print h+0, f+0}' "$lcov")
  if [[ "$found" == "0" ]]; then
    echo "No lines covered in $package; skipping floor"
    return 0
  fi

  floor="$(flutter_coverage_floor "$package")"
  pct="$(awk -v h="$hit" -v f="$found" 'BEGIN { printf "%.1f", (h*100)/f }')"
  echo "$package coverage: ${pct}% (floor ${floor}%)"
  awk -v a="$pct" -v b="$floor" 'BEGIN { if (a + 0 < b + 0) exit 1 }'
}

check_sidecar_coverage() {
  local report total
  report="$(cd sidecar && go tool cover -func=coverage.out)"
  total="$(awk '/^total:/ {print $3}' <<<"$report")"
  echo "Sidecar coverage (total): $total"
  awk -v a="${total%\%}" -v b=55 'BEGIN { if (a + 0 < b + 0) exit 1 }'

  local pkg floor actual
  for entry in internal/rpc:85 internal/logging:80 internal/hash:80 internal/doctor:70 internal/disks:70; do
    pkg="${entry%%:*}"
    floor="${entry##*:}"
    actual="$(
      awk -v p="$pkg/" '$1 ~ p {gsub("%","",$3); s+=$3; n++} END { if (n==0) print 0; else printf "%.1f", s/n }' <<<"$report"
    )"
    echo "$pkg coverage: ${actual}% (floor ${floor}%)"
    awk -v a="$actual" -v b="$floor" 'BEGIN { if (a + 0 < b + 0) exit 1 }'
  done
}

run_flutter_pub_get() {
  for package in "${flutter_packages[@]}"; do
    (cd "$package" && flutter pub get)
  done
}

run_fmt() {
  for package in "${flutter_packages[@]}"; do
    (cd "$package" && dart format --output=none --set-exit-if-changed .)
  done
}

run_golangci_lint() {
  if command -v golangci-lint >/dev/null 2>&1; then
    (cd sidecar && golangci-lint run --timeout=5m)
  else
    (cd sidecar && go run github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.1.6 run --timeout=5m)
  fi
}

run_python() {
  if command -v python >/dev/null 2>&1; then
    python "$@"
  else
    python3 "$@"
  fi
}

run_lint() {
  (cd sidecar && go mod download && go vet ./... && go build ./...)
  run_golangci_lint
  (cd sidecar && go run ./cmd/deckhand-ipc-docs --check)

  run_flutter_pub_get
  for package in "${flutter_packages[@]}"; do
    (cd "$package" && flutter analyze --fatal-infos)
  done
}

run_sidecar_tests() {
  case "$(uname -s)" in
    Darwin)
      (cd sidecar && go test -count=1 ./...)
      ;;
    *)
      (cd sidecar && go test -race -count=1 -coverprofile=coverage.out ./...)
      check_sidecar_coverage
      ;;
  esac
}

run_flutter_tests() {
  run_flutter_pub_get
  for package in "${flutter_packages[@]}"; do
    if [[ -d "$package/test" ]]; then
      (cd "$package" && flutter test --coverage --reporter=expanded)
      check_flutter_coverage "$package"
    else
      echo "No test/ directory in $package; skipping."
    fi
  done
}

run_profile_lint() {
  local ref tmp_dir
  ref="${DECKHAND_PROFILES_REF:-main}"
  tmp_dir="$(mktemp -d)"
  deckhand_profiles_tmp_dir="$tmp_dir"
  trap 'rm -rf "$deckhand_profiles_tmp_dir"' EXIT
  git clone --depth=1 --branch "$ref" https://github.com/CepheusLabs/deckhand-profiles.git "$tmp_dir/builds"
  (
    cd packages/deckhand_profile_lint
    dart pub get
    dart run bin/deckhand_profile_lint.dart --root "$tmp_dir/builds" --schema "$tmp_dir/builds/schema/profile.schema.json" --strict
  )
}

run_test() {
  run_sidecar_tests
  run_flutter_tests
  run_python -m unittest discover -s scripts -p 'test_*.py' -v
  run_profile_lint
}

run_phase() {
  case "$1" in
    all)
      run_fmt
      run_lint
      run_test
      ;;
    fmt) run_fmt ;;
    lint) run_lint ;;
    test) run_test ;;
    -h|--help|help)
      usage
      ;;
    *)
      echo "Unknown quality phase: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
}

if [[ $# -eq 0 ]]; then
  set -- all
fi

for phase in "$@"; do
  run_phase "$phase"
done
