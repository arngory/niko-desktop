#!/usr/bin/env bash
# Package Linux .deb and .rpm packages using nfpm on top of the verified release bundle from tool/package_linux.sh.
#
# Usage:
#   tool/package_linux_deb_rpm.sh [--window-dir <dir>] [--arch amd64|arm64] [--version <ver>] \
#     [--out <dir>] [--minisign-key <file>]
#   (Optional minisign passphrase is read from NIKO_MINISIGN_PASS env var.)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WINDOW_DIR=""
ARCH="amd64"
VERSION=""
OUT_DIR="$ROOT/build/dist"
MINISIGN_KEY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --window-dir) WINDOW_DIR="$2"; shift 2 ;;
    --arch) ARCH="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    --minisign-key) MINISIGN_KEY="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,8p' "$0"
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v nfpm >/dev/null 2>&1 || {
  echo "ERROR: nfpm is required in PATH (https://nfpm.goreleaser.com/)" >&2
  exit 1
}

if [ -z "$VERSION" ]; then
  VERSION="$(sed -n 's/^version: *\([^+]*\).*/\1/p' "$ROOT/pubspec.yaml")"
fi
[ -n "$VERSION" ] || { echo "ERROR: cannot determine version" >&2; exit 1; }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PKG_ARGS=(--arch "$ARCH" --version "$VERSION" --out "$TMP_DIR/tar")
if [ -n "$WINDOW_DIR" ]; then
  PKG_ARGS+=(--window-dir "$WINDOW_DIR")
fi
"$ROOT/tool/package_linux.sh" "${PKG_ARGS[@]}"

PKG_NAME="niko-${VERSION}-linux-${ARCH}"
tar -C "$TMP_DIR" -xzf "$TMP_DIR/tar/${PKG_NAME}.tar.gz"
STAGE_DIR="$TMP_DIR/$PKG_NAME"
chmod 0755 "$ROOT/packaging/scripts/postinstall.sh"

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

DEB_OUT="$OUT_DIR/niko-${VERSION}-linux-${ARCH}.deb"
RPM_OUT="$OUT_DIR/niko-${VERSION}-linux-${ARCH}.rpm"

(
  cd "$ROOT"
  export NIKO_VERSION="$VERSION"
  export NIKO_ARCH="$ARCH"
  export NIKO_STAGE_DIR="$STAGE_DIR"
  nfpm package --config packaging/nfpm.yaml --packager deb --target "$DEB_OUT"
  nfpm package --config packaging/nfpm.yaml --packager rpm --target "$RPM_OUT"
)

(
  cd "$OUT_DIR"
  sha256sum "niko-${VERSION}-linux-${ARCH}.deb" "niko-${VERSION}-linux-${ARCH}.rpm" > "SHA256SUMS.linux-${ARCH}-pkg"
)
if [ -n "$MINISIGN_KEY" ]; then
  "$ROOT/tool/sign_release.sh" --dir "$OUT_DIR" --version "$VERSION" --minisign-key "$MINISIGN_KEY"
fi

echo "Packaged: $DEB_OUT"
echo "Packaged: $RPM_OUT"
