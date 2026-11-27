#!/usr/bin/env bash
# Reproducible builder for Variant A bundled `slipstream-client` (arngory/slipstream + picoquic)
# pinned by niko/buildScript/lib/slipstream/env.sh.
#
# Usage:
#   tool/build_slipstream.sh [--os linux|darwin|windows] [--out <dir>]
# Requires: git, cmake, ninja, C/C++ compiler, OpenSSL dev libraries.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NIKO_DIR="${NIKO_ROOT:-$ROOT/../niko}"
TARGET_OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
OUT_DIR="$ROOT/build/slipstream"

while [ $# -gt 0 ]; do
  case "$1" in
    --os) TARGET_OS="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,9p' "$0"
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

# shellcheck source=/dev/null
source "$NIKO_DIR/buildScript/lib/slipstream/env.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SRC="$WORK/slipstream"
BUILD="$WORK/build"

echo "1. Fetching arngory/slipstream @ $COMMIT_SLIPSTREAM..."
git init -q "$SRC"
git -C "$SRC" remote add origin "$REPOSITORY_SLIPSTREAM"
git -C "$SRC" fetch -q --depth 1 origin "$COMMIT_SLIPSTREAM"
git -C "$SRC" checkout -q --force "$COMMIT_SLIPSTREAM"
git -C "$SRC" submodule update -q --init --recursive

echo "2. Configuring CMake ($TARGET_OS)..."
cmake -S "$SRC" -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DPICOQUIC_ENFORCED_INITIAL_MTU=64

grep -qx 'PICOQUIC_ENFORCED_INITIAL_MTU:STRING=64' "$BUILD/CMakeCache.txt" || {
  echo "ERROR: PICOQUIC_ENFORCED_INITIAL_MTU is not 64" >&2
  exit 1
}

echo "3. Building slipstream-client..."
cmake --build "$BUILD" --target slipstream-client

BIN_NAME="slipstream-client"
if [ "$TARGET_OS" = "windows" ]; then
  BIN_NAME="slipstream-client.exe"
fi

mkdir -p "$OUT_DIR"
cp -a "$BUILD/$BIN_NAME" "$OUT_DIR/$BIN_NAME"
chmod 0755 "$OUT_DIR/$BIN_NAME"
echo "Built: $OUT_DIR/$BIN_NAME"
sha256sum "$OUT_DIR/$BIN_NAME"
