#!/usr/bin/env bash
# Verify that local sibling checkouts (../niko and ../sing-box, or NIKO_ROOT / SING_BOX_ROOT)
# have clean working trees and match the exact commit SHAs pinned in .github/niko.env and
# niko/buildScript/lib/core/get_source_env.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NIKO_DIR="${NIKO_ROOT:-$ROOT/../niko}"
SING_BOX_DIR="${SING_BOX_ROOT:-$ROOT/../sing-box}"

if [ ! -d "$NIKO_DIR/.git" ]; then
  echo "ERROR: niko checkout not found at $NIKO_DIR (set NIKO_ROOT)" >&2
  exit 1
fi
if [ ! -d "$SING_BOX_DIR/.git" ]; then
  echo "ERROR: sing-box checkout not found at $SING_BOX_DIR (set SING_BOX_ROOT)" >&2
  exit 1
fi

# 1. Clean working trees required (libcore/go.mod uses local replace => ../../sing-box)
for repo in "$SING_BOX_DIR" "$NIKO_DIR"; do
  dirty="$(git -C "$repo" status --porcelain)"
  if [ -n "$dirty" ]; then
    echo "ERROR: dirty working tree in $repo:" >&2
    echo "$dirty" >&2
    exit 1
  fi
done

# 2. Check COMMIT_SING_BOX in niko/buildScript/lib/core/get_source_env.sh
# shellcheck source=/dev/null
source "$NIKO_DIR/buildScript/lib/core/get_source_env.sh"
HAVE_SB="$(git -C "$SING_BOX_DIR" rev-parse HEAD)"
if [ "${COMMIT_SING_BOX:-}" != "$HAVE_SB" ]; then
  echo "ERROR: sing-box pin mismatch: get_source_env.sh=${COMMIT_SING_BOX:-unset}, HEAD=$HAVE_SB" >&2
  exit 1
fi

# 3. Check COMMIT_NIKO in .github/niko.env
# shellcheck source=/dev/null
source "$ROOT/.github/niko.env"
HAVE_NIKO="$(git -C "$NIKO_DIR" rev-parse HEAD)"
if [ "${COMMIT_NIKO:-}" != "$HAVE_NIKO" ]; then
  echo "ERROR: niko pin mismatch: .github/niko.env=${COMMIT_NIKO:-unset}, HEAD=$HAVE_NIKO" >&2
  exit 1
fi

echo "Pins OK: sing-box=${HAVE_SB:0:9}, niko=${HAVE_NIKO:0:8}"
