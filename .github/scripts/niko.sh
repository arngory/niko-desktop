#!/bin/bash
# Niko at the commit .github/niko.env pins into niko/ of DIR, and with --core the core at the commit that Niko pins
# (its buildScript/lib/core/get_source_env.sh) into sing-box/ of DIR: the layout the window's tools and tests take by
# default when this repository is checked out into DIR too (../niko, ../niko/../sing-box), the one ./run lib core/init
# of Niko makes for the core.
#
#   .github/scripts/niko.sh DIR [--core]     (CI: DIR is the workspace, ".")
#
# NIKO_COMMIT, when set, is another commit of arngory/niko to take in place of the pin (a manual run of ci.yml: the
# window against a pull request of Niko before it is pinned). A full commit only, fetched by itself.
set -euo pipefail
here=$(cd "$(dirname "$0")/../.." && pwd)
dir=$1
. "$here/.github/niko.env"
commit=${NIKO_COMMIT:-$COMMIT_NIKO}
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "::error::not a full commit of Niko: '$commit'"; exit 1; }
[ "$commit" = "$COMMIT_NIKO" ] || echo "::notice::Niko at $commit, not at the pinned $COMMIT_NIKO"
git init -q "$dir/niko"
git -C "$dir/niko" fetch -q --depth 1 --filter=blob:none "$REPOSITORY_NIKO" "$commit"
git -C "$dir/niko" checkout -q FETCH_HEAD
echo "Niko: $REPOSITORY_NIKO at $(git -C "$dir/niko" rev-parse HEAD)"
if [ "${2:-}" = "--core" ]; then
  . "$dir/niko/buildScript/lib/core/get_source_env.sh"
  git clone -q --filter=blob:none --no-checkout "$REPOSITORY_SING_BOX" "$dir/sing-box"
  git -C "$dir/sing-box" checkout -q "$COMMIT_SING_BOX"
  echo "the core: $REPOSITORY_SING_BOX at $COMMIT_SING_BOX"
fi
