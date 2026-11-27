#!/usr/bin/env bash
# Minimal macOS release packager skeleton (unverified on a macOS host yet).
# Must be run on macOS with Xcode + Flutter macOS desktop toolchain installed:
#   1. Builds Flutter macOS release app bundle (`build/macos/Build/Products/Release/Niko.app`)
#   2. Verifies no forbidden dev/unsafe strings in the app bundle
#   3. Builds release `niko-daemon` for darwin/<arch> and embeds it under
#      `Niko.app/Contents/Resources/daemon/niko-daemon`
#   4. Packs `niko-<version>-macos-<arch>.tar.gz` + `SHA256SUMS.macos-<arch>-tar`
#
# Usage:
#   tool/package_macos.sh [--app-dir <path/to/Niko.app>] [--arch arm64|amd64] \
#     [--version <ver>] [--out <dir>] [--minisign-key <file>]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR=""
ARCH=""
VERSION=""
OUT_DIR="$ROOT/build/dist"
MINISIGN_KEY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --app-dir) APP_DIR="$2"; shift 2 ;;
    --arch) ARCH="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    --minisign-key) MINISIGN_KEY="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,14p' "$0"
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$ARCH" ]; then
  case "$(uname -m)" in
    arm64|aarch64) ARCH="arm64" ;;
    *) ARCH="amd64" ;;
  esac
fi

if [ -z "$VERSION" ]; then
  VERSION="$(sed -n 's/^version: *\([^+]*\).*/\1/p' "$ROOT/pubspec.yaml")"
fi
[ -n "$VERSION" ] || { echo "ERROR: cannot determine version" >&2; exit 1; }

if [ -z "$APP_DIR" ]; then
  [ "$(uname -s)" = "Darwin" ] || {
    echo "ERROR: building Niko.app requires macOS (or pass --app-dir <Niko.app>)" >&2
    exit 1
  }
  echo "1. Building Flutter macOS release ($VERSION)..."
  (
    cd "$ROOT"
    flutter pub get --enforce-lockfile
    flutter build macos --release --dart-define="NIKO_WINDOW_VERSION=$VERSION"
  )
  APP_DIR="$ROOT/build/macos/Build/Products/Release/Niko.app"
fi

[ -d "$APP_DIR/Contents/MacOS" ] || {
  echo "ERROR: $APP_DIR is not a valid .app bundle" >&2
  exit 1
}

PKG_NAME="niko-${VERSION}-macos-${ARCH}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
STAGE_APP="$TMP_DIR/Niko.app"

echo "2. Staging Niko.app..."
cp -a "$APP_DIR" "$STAGE_APP"
for forbidden in "--daemon takes 127.0.0.1" "DevEndpoint" "--allow-unsafe-installation-directory-permissions"; do
  rc=0
  grep -rqaF -- "$forbidden" "$STAGE_APP" || rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "ERROR: release app carries forbidden string: $forbidden" >&2
    exit 1
  elif [ "$rc" -ne 1 ]; then
    echo "ERROR: grep failed (rc=$rc) checking $forbidden" >&2
    exit 1
  fi
done

echo "3. Building release niko-daemon (darwin/$ARCH)..."
DAEMON_OUT="$TMP_DIR/daemon"
"$ROOT/tool/build_daemon.sh" --os darwin --arch "$ARCH" --mode release --out "$DAEMON_OUT"
mkdir -p "$STAGE_APP/Contents/Resources/daemon"
cp -a "$DAEMON_OUT/darwin-$ARCH/niko-daemon" "$STAGE_APP/Contents/Resources/daemon/niko-daemon"
chmod 0755 "$STAGE_APP/Contents/Resources/daemon/niko-daemon"

for required in "sing-box/protocol/knock" "niko.v1.NikoService"; do
  grep -qaF -- "$required" "$STAGE_APP/Contents/Resources/daemon/niko-daemon" || {
    echo "ERROR: release niko-daemon missing required symbol: $required" >&2
    exit 1
  }
done

echo "4. Creating macOS release archive..."
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
TAR_PATH="$OUT_DIR/${PKG_NAME}.tar.gz"
tar -C "$TMP_DIR" -czf "$TAR_PATH" "Niko.app"

(
  cd "$OUT_DIR"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${PKG_NAME}.tar.gz" > "SHA256SUMS.macos-${ARCH}-tar"
  else
    sha256sum "${PKG_NAME}.tar.gz" > "SHA256SUMS.macos-${ARCH}-tar"
  fi
)
if [ -n "$MINISIGN_KEY" ]; then
  "$ROOT/tool/sign_release.sh" --dir "$OUT_DIR" --version "$VERSION" --minisign-key "$MINISIGN_KEY"
fi

echo "Packaged: $TAR_PATH"
