#!/usr/bin/env bash
# Package a Linux AppImage on top of the verified release bundle from tool/package_linux.sh.
#
# Usage:
#   tool/package_appimage.sh [--window-dir <dir>] [--arch amd64|arm64] [--version <ver>] \
#     [--out <dir>] [--minisign-key <file>]
#   (Optional minisign passphrase is read from NIKO_MINISIGN_PASS env var.)
#   Note: AppImage builds do not register host URL scheme handlers automatically unless
#   integrated via AppImageLauncher or a user-level .desktop file pointing at $APPIMAGE.
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
      sed -n '2,10p' "$0"
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v appimagetool >/dev/null 2>&1 || {
  echo "ERROR: appimagetool is required in PATH (https://github.com/AppImage/appimagetool)" >&2
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

APPDIR="$TMP_DIR/Niko.AppDir"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/share/applications" "$APPDIR/usr/share/icons/hicolor/scalable/apps"
cp -a "$STAGE_DIR"/. "$APPDIR/usr/bin/"
cp "$ROOT/packaging/io.niko.niko_desktop.desktop" "$APPDIR/io.niko.niko_desktop.desktop"
cp "$ROOT/packaging/io.niko.niko_desktop.desktop" "$APPDIR/usr/share/applications/io.niko.niko_desktop.desktop"
cp "$ROOT/packaging/niko.svg" "$APPDIR/niko.svg"
cp "$ROOT/packaging/niko.svg" "$APPDIR/usr/share/icons/hicolor/scalable/apps/niko.svg"

cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/sh
set -eu
HERE="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="$HERE/usr/bin/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$HERE/usr/bin/niko" "$@"
EOF
chmod 0755 "$APPDIR/AppRun"

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

APPIMAGE_ARCH="x86_64"
if [ "$ARCH" = "arm64" ]; then
  APPIMAGE_ARCH="aarch64"
fi
APPIMAGE_OUT="$OUT_DIR/niko-${VERSION}-linux-${ARCH}.AppImage"
ARCH="$APPIMAGE_ARCH" appimagetool "$APPDIR" "$APPIMAGE_OUT"

(
  cd "$OUT_DIR"
  sha256sum "niko-${VERSION}-linux-${ARCH}.AppImage" > "SHA256SUMS.linux-${ARCH}-appimage"
)
if [ -n "$MINISIGN_KEY" ]; then
  "$ROOT/tool/sign_release.sh" --dir "$OUT_DIR" --version "$VERSION" --minisign-key "$MINISIGN_KEY"
fi

echo "Packaged: $APPIMAGE_OUT ($(du -h "$APPIMAGE_OUT" | cut -f1))"
