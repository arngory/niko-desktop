#!/usr/bin/env bash
# Package a Linux release tar.gz archive following doc/release-layout.md:
#   1. Build (or copy --window-dir) Flutter Linux release bundle
#   2. Verify no forbidden dev/unsafe strings in the window bundle
#   3. Fetch verified libcronet.so into resources/daemon/libcronet.so
#   4. Generate resources/daemon/files.sha256 and compute its SHA-256
#   5. Build release niko-daemon with -X main.manifestSHA256=<hash> and with_naive_outbound,with_purego
#   6. Verify required symbols (knock, naive, NikoService) and absence of DevEndpoint
#   7. Pack niko-<version>-linux-<arch>.tar.gz + SHA256SUMS (+ optional SHA256SUMS.minisig)
#
# Usage:
#   tool/package_linux.sh [--window-dir <dir>] [--arch amd64|arm64] [--version <ver>] \
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
      sed -n '2,15p' "$0"
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$VERSION" ]; then
  VERSION="$(sed -n 's/^version: *\([^+]*\).*/\1/p' "$ROOT/pubspec.yaml")"
fi
[ -n "$VERSION" ] || { echo "ERROR: cannot determine version" >&2; exit 1; }

if [ -z "$WINDOW_DIR" ]; then
  echo "1. Building Flutter Linux release ($VERSION)..."
  (
    cd "$ROOT"
    flutter pub get --enforce-lockfile
    flutter build linux --release --dart-define="NIKO_WINDOW_VERSION=$VERSION"
  )
  if [ "$ARCH" = "arm64" ]; then
    WINDOW_DIR="$ROOT/build/linux/arm64/release/bundle"
  else
    WINDOW_DIR="$ROOT/build/linux/x64/release/bundle"
  fi
fi

[ -x "$WINDOW_DIR/niko" ] || { echo "ERROR: $WINDOW_DIR/niko not found or not executable" >&2; exit 1; }

PKG_NAME="niko-${VERSION}-linux-${ARCH}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
STAGE_ROOT="$TMP_DIR/$PKG_NAME"
mkdir -p "$STAGE_ROOT/resources/daemon"

echo "2. Staging Linux Flutter release bundle..."
cp -a "$WINDOW_DIR"/. "$STAGE_ROOT/"
for forbidden in "--daemon takes 127.0.0.1" "DevEndpoint" "--allow-unsafe-installation-directory-permissions"; do
  rc=0
  grep -rqaF -- "$forbidden" "$STAGE_ROOT" || rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "ERROR: release window carries forbidden string: $forbidden" >&2
    exit 1
  elif [ "$rc" -ne 1 ]; then
    echo "ERROR: grep failed (rc=$rc) checking $forbidden" >&2
    exit 1
  fi
done

echo "3. Fetching verified libcronet.so..."
DAEMON_PRE="$TMP_DIR/daemon-pre"
"$ROOT/tool/build_daemon.sh" --os linux --arch "$ARCH" --mode release --out "$DAEMON_PRE" >/dev/null
cp -a "$DAEMON_PRE/linux-$ARCH/libcronet.so" "$STAGE_ROOT/resources/daemon/libcronet.so"
if [ -n "${SLIPSTREAM_BIN:-}" ] && [ -x "$SLIPSTREAM_BIN" ]; then
  echo "   staging optional slipstream-client from $SLIPSTREAM_BIN"
  cp "$SLIPSTREAM_BIN" "$STAGE_ROOT/resources/daemon/slipstream-client"
  chmod 0755 "$STAGE_ROOT/resources/daemon/slipstream-client"
fi

echo "4. Generating resources/daemon/files.sha256..."
(
  cd "$STAGE_ROOT/resources/daemon"
  LC_ALL=C find . -type f ! -path './files.sha256' ! -path './niko-daemon' \
    | sed 's|^\./||' \
    | LC_ALL=C sort \
    | while IFS= read -r rel; do
        sum="$(sha256sum "$rel" | cut -d' ' -f1)"
        printf '%s  %s\n' "$sum" "$rel"
      done > files.sha256
)
MANIFEST_SHA256="$(sha256sum "$STAGE_ROOT/resources/daemon/files.sha256" | cut -d' ' -f1)"
echo "   daemon manifest SHA-256: $MANIFEST_SHA256"

echo "5. Building release niko-daemon with embedded manifestSHA256 and naive+purego..."
DAEMON_FINAL="$TMP_DIR/daemon-final"
"$ROOT/tool/build_daemon.sh" --os linux --arch "$ARCH" --mode release \
  --manifest-sha256 "$MANIFEST_SHA256" --out "$DAEMON_FINAL"
cp -a "$DAEMON_FINAL/linux-$ARCH/niko-daemon" "$STAGE_ROOT/resources/daemon/niko-daemon"
chmod 0755 "$STAGE_ROOT/resources/daemon/niko-daemon"

rc=0
grep -qaF -- "DevEndpoint" "$STAGE_ROOT/resources/daemon/niko-daemon" || rc=$?
if [ "$rc" -eq 0 ]; then
  echo "ERROR: release niko-daemon carries forbidden string: DevEndpoint" >&2
  exit 1
elif [ "$rc" -ne 1 ]; then
  echo "ERROR: grep failed (rc=$rc) checking DevEndpoint" >&2
  exit 1
fi
for required in "sing-box/protocol/knock" "sing-box/protocol/naive" "niko.v1.NikoService"; do
  grep -qaF -- "$required" "$STAGE_ROOT/resources/daemon/niko-daemon" || {
    echo "ERROR: release niko-daemon missing required symbol: $required" >&2
    exit 1
  }
done

echo "6. Creating Linux release tar.gz archive..."
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
TAR_PATH="$OUT_DIR/${PKG_NAME}.tar.gz"
tar -C "$TMP_DIR" -czf "$TAR_PATH" "$PKG_NAME"

(
  cd "$OUT_DIR"
  sha256sum "${PKG_NAME}.tar.gz" > "SHA256SUMS.linux-${ARCH}-tar"
)
if [ -n "$MINISIGN_KEY" ]; then
  "$ROOT/tool/sign_release.sh" --dir "$OUT_DIR" --version "$VERSION" --minisign-key "$MINISIGN_KEY"
fi

echo "Packaged: $TAR_PATH ($(du -h "$TAR_PATH" | cut -f1))"
cat "$OUT_DIR/SHA256SUMS.linux-${ARCH}-tar"
