#!/usr/bin/env bash
# Aggregate all release archives for a version into a single sorted, deduplicated SHA256SUMS
# and optionally sign it with minisign using trusted comment "niko-desktop v<version>".
# Passphrase is read from NIKO_MINISIGN_PASS (never passed as a CLI argument).
#
# Usage:
#   tool/sign_release.sh --dir <dist-dir> --version <ver> [--minisign-key <file>]
set -euo pipefail

DIR=""
VERSION=""
MINISIGN_KEY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DIR="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --minisign-key) MINISIGN_KEY="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,8p' "$0"
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$DIR" ] && [ -d "$DIR" ] || { echo "ERROR: --dir must point to an existing directory" >&2; exit 2; }
[ -n "$VERSION" ] || { echo "ERROR: --version is required" >&2; exit 2; }
TAG="v${VERSION#v}"
VER="${VERSION#v}"

cd "$DIR"
shopt -s nullglob
FILES=(niko-"${VER}"-*.tar.gz niko-"${VER}"-*.zip niko-"${VER}"-*.AppImage niko-"${VER}"-*.deb niko-"${VER}"-*.rpm niko-"${VER}"-*.exe)
shopt -u nullglob

[ ${#FILES[@]} -gt 0 ] || { echo "ERROR: no niko-${VER}-* release artifacts found in $DIR" >&2; exit 1; }

sha256sum "${FILES[@]}" | LC_ALL=C sort -k2 -u > SHA256SUMS
rm -f SHA256SUMS.minisig

if [ -n "$MINISIGN_KEY" ]; then
  if [ -n "${NIKO_MINISIGN_PASS:-}" ]; then
    printf '%s\n' "$NIKO_MINISIGN_PASS" | minisign -S -s "$MINISIGN_KEY" -t "niko-desktop ${TAG}" -m SHA256SUMS -x SHA256SUMS.minisig >/dev/null
  else
    minisign -S -s "$MINISIGN_KEY" -t "niko-desktop ${TAG}" -m SHA256SUMS -x SHA256SUMS.minisig >/dev/null
  fi
fi

echo "Generated $DIR/SHA256SUMS for ${#FILES[@]} artifact(s):"
cat SHA256SUMS
