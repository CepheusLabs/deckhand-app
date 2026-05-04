#!/usr/bin/env bash
# setup-linux-runner.sh — one-shot remediation for the deckhand
# self-hosted Linux runner (cl-* in CepheusLabs/deckhand-app).
#
# Run this ON THE LINUX RUNNER MACHINE, as a user that can sudo,
# AFTER the actions runner is registered. It:
#
#   1. Locates the runner install dir.
#   2. Drops a runner-scoped `.env` so jobs see Go, Flutter, and
#      the runner work tree as a git safe.directory. This is the
#      same mechanism that fixed the Windows runner — runner-local
#      env, no system-wide PATH edits.
#   3. Installs the Flutter Linux platform deps (ninja, cmake,
#      libgtk-3-dev, libsecret-1-dev) once, so the workflow's
#      `apt-get install` step becomes a no-op (or can be removed).
#   4. Grants the runner's service user passwordless sudo for the
#      specific apt-get invocation the workflow needs, in case
#      future deps are added.
#   5. Restarts the runner service so the new `.env` is loaded.
#
# Idempotent — re-running is safe and reports what changed.
#
# Usage:
#   bash setup-linux-runner.sh                  # autodetect runner dir
#   RUNNER_DIR=/opt/actions-runner bash ...     # explicit override
#
# Environment:
#   FLUTTER_BIN  optional path to flutter's bin/ if not on PATH
#   GO_BIN       optional path to go's bin/ if not on PATH

set -euo pipefail

# Skip ANSI escapes when stdout/stderr aren't TTYs (cron, journalctl,
# CI artifact viewers — all render \e[...m as literal garbage).
if [ -t 1 ]; then C_INFO='\e[1;36m'; C_RST='\e[0m'; else C_INFO=''; C_RST=''; fi
if [ -t 2 ]; then C_WARN='\e[1;33m'; C_ERR='\e[1;31m'; else C_WARN=''; C_ERR=''; fi

log()  { printf "${C_INFO}[setup-linux-runner]${C_RST} %s\n" "$*"; }
warn() { printf "${C_WARN}[setup-linux-runner WARN]${C_RST} %s\n" "$*" >&2; }
die()  { printf "${C_ERR}[setup-linux-runner ERR]${C_RST} %s\n" "$*" >&2; exit 1; }

# 1. Find the runner directory ---------------------------------------------
runner_dir="${RUNNER_DIR:-}"
if [ -z "$runner_dir" ]; then
  for candidate in \
    /opt/actions-runner \
    /home/*/actions-runner \
    /media/actions-runner \
    /var/lib/actions-runner \
    "$HOME/actions-runner"
  do
    # Glob may not expand; eval-quote to be safe.
    for path in $candidate; do
      if [ -f "$path/.runner" ] && [ -f "$path/svc.sh" ]; then
        runner_dir="$path"
        break 2
      fi
    done
  done
fi
[ -n "$runner_dir" ] || die "could not locate actions runner; pass RUNNER_DIR=..."
log "runner dir: $runner_dir"

# 2. Locate Flutter + Go ---------------------------------------------------
flutter_bin="${FLUTTER_BIN:-}"
go_bin="${GO_BIN:-}"

if [ -z "$flutter_bin" ]; then
  if command -v flutter >/dev/null 2>&1; then
    flutter_bin="$(dirname "$(command -v flutter)")"
  fi
fi
if [ -z "$go_bin" ]; then
  if command -v go >/dev/null 2>&1; then
    go_bin="$(dirname "$(command -v go)")"
  fi
fi

# Fallback search for go in standard install locations.
if [ -z "$go_bin" ]; then
  for path in /usr/local/go/bin /opt/go/bin /usr/lib/go-*/bin; do
    if [ -x "$path/go" ]; then go_bin="$path"; break; fi
  done
fi

[ -n "$go_bin" ] || die "go not found; install it or pass GO_BIN=..."
log "go bin: $go_bin"
[ -n "$flutter_bin" ] || warn "flutter not found on PATH; Flutter jobs will fail"
[ -n "$flutter_bin" ] && log "flutter bin: $flutter_bin"

# 3. Compose runner-scoped PATH and write .env -----------------------------
# We DO NOT modify /etc/environment or any user shell rc — the runner
# reads its own .env on startup. Same model as Windows.
env_file="$runner_dir/.env"
new_path="$go_bin"
[ -n "$flutter_bin" ] && new_path="$flutter_bin:$new_path"
new_path="$new_path:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin"

git_config="$runner_dir/.runner-gitconfig"
# Single-tenant CI runner — checkouts always land in dirs the runner
# user doesn't own (work tree is created by the actions/checkout step).
# The wildcard is the right trade-off here; a per-path entry would
# require updating every time a new repo gets checked out on this
# runner.
cat > "$git_config" <<EOF
[safe]
	directory = *
EOF
log "wrote $git_config"

# Preserve any existing keys that aren't PATH or GIT_CONFIG_GLOBAL.
tmp_env="$(mktemp)"
if [ -f "$env_file" ]; then
  grep -v -E '^(PATH|GIT_CONFIG_GLOBAL)=' "$env_file" > "$tmp_env" || true
fi
{
  cat "$tmp_env"
  printf 'PATH=%s\n' "$new_path"
  printf 'GIT_CONFIG_GLOBAL=%s\n' "$git_config"
} > "$env_file"
rm -f "$tmp_env"
log "wrote $env_file"

# 4. Install Flutter Linux platform deps -----------------------------------
# These are the packages that the CI workflow's `apt-get install`
# step needs. Pre-installing them here means the workflow step
# becomes a no-op rather than prompting for sudo password.
#
# We deliberately do NOT install a sudoers NOPASSWD rule for future
# apt-get invocations: a wildcard `apt-get install *` rule permits
# privilege escalation via apt-get -o options
# (e.g. -o DPkg::Pre-Install-Pkgs=cmd). If CI workflow deps change,
# re-run this script to refresh the pre-installed package set.
log "installing Flutter Linux platform deps via sudo apt-get..."
sudo apt-get update -y
sudo apt-get install -y ninja-build cmake libgtk-3-dev libsecret-1-dev clang pkg-config

# 5. Restart the runner so the new .env is picked up -----------------------
unit=$(systemctl list-units --type=service --no-pager 2>/dev/null \
        | awk '/actions\.runner/ {print $1; exit}' || true)
if [ -n "$unit" ]; then
  log "restarting $unit"
  sudo systemctl restart "$unit"
  sleep 2
  sudo systemctl --no-pager status "$unit" | head -5
else
  warn "could not find systemd unit; restart the runner manually"
fi

log "done. The runner should now claim Linux jobs and find go/flutter."
