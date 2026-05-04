#!/usr/bin/env bash
# stamp_changelog.sh — replace the leading `## Unreleased` heading
# in CHANGELOG.md with the resolved tag heading right before tagging.
# Idempotent: re-running on an already-stamped CHANGELOG is a no-op.
#
# Usage:
#   bash scripts/stamp_changelog.sh v26.5.1-44 2026-05-01
#   # → rewrites `## Unreleased — ...` to `## v26.5.1-44 (2026-05-01) — ...`
#
# Called from the release workflow's "Compute version" job after the
# tag is resolved but before `git tag` runs, so the committed CHANGELOG
# always matches the tag that was created.

set -euo pipefail

if [ $# -lt 2 ]; then
  echo "usage: $0 <tag> <YYYY-MM-DD>" >&2
  exit 1
fi

TAG="$1"
DATE="$2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHANGELOG="$ROOT/CHANGELOG.md"

if [ ! -f "$CHANGELOG" ]; then
  echo "CHANGELOG.md not found at $CHANGELOG" >&2
  exit 1
fi

# Match ONLY the first `## Unreleased` heading. Trailing dash-separated
# subtitle (`— Initial release`) is preserved if present.
if ! grep -q '^## Unreleased' "$CHANGELOG"; then
  echo "stamp_changelog: no '## Unreleased' heading; nothing to do" >&2
  exit 0
fi

# In-place rewrite. We use a Python one-liner instead of sed because
# the runner's BSD sed (macOS) and GNU sed (Linux) disagree on -i syntax,
# and Python ships everywhere we run release jobs.
python3 - "$CHANGELOG" "$TAG" "$DATE" <<'PY'
import re, sys
path, tag, date = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, 'r', encoding='utf-8') as f:
    text = f.read()
# First match only.
new, n = re.subn(
    r'^## Unreleased',
    f'## {tag} ({date})',
    text,
    count=1,
    flags=re.MULTILINE,
)
if n != 1:
    sys.exit('stamp_changelog: failed to replace heading')
with open(path, 'w', encoding='utf-8') as f:
    f.write(new)
PY

echo "stamp_changelog: stamped $CHANGELOG -> ## $TAG ($DATE)"
