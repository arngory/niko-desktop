#!/usr/bin/env bash
# Local mirror of the CI daemon build job: builds niko-daemon for Linux and/or Windows (dev or
# release mode) and verifies libcronet SHA256SUMS + Chromium anchor version.
#
# Usage:
#   tool/build_daemon.sh --os linux|windows|darwin|all --mode dev|release [--arch amd64|arm64] [--manifest-sha256 <hex>] [--out <dir>]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NIKO_DIR="${NIKO_ROOT:-$ROOT/../niko}"
SING_BOX_DIR="${SING_BOX_ROOT:-$ROOT/../sing-box}"

TARGET_OS="linux"
TARGET_ARCH="amd64"
MODE="dev"
MANIFEST_SHA256=""
OUT_DIR="$ROOT/build/daemon"

while [ $# -gt 0 ]; do
  case "$1" in
    --os) TARGET_OS="$2"; shift 2 ;;
    --arch) TARGET_ARCH="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --manifest-sha256) MANIFEST_SHA256="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,8p' "$0"
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

BASE_TAGS="with_gvisor,with_quic,with_wireguard,with_utls,with_clash_api,with_xhttp,with_awg,with_dnstt,with_masterdnsvpn,with_yggdrasil,badlinkname,tfogo_checklinkname0"
NIKO_VERSION="$(sed -n 's/^VERSION_NAME=//p' "$NIKO_DIR/niko.properties")-$(git -C "$NIKO_DIR" rev-parse --short=7 HEAD)"
CHROMIUM="$(sed -n 's/^const ChromiumAnchorsVersion = "\(.*\)"$/\1/p' "$SING_BOX_DIR/common/certificate/chromium_anchors_neko_generated.go")"
[ -n "$CHROMIUM" ] || { echo "ERROR: cannot read ChromiumAnchorsVersion" >&2; exit 1; }

LDFLAGS="-s -w -checklinkname=0 -X libcore/nikoservice.Version=$NIKO_VERSION"
if [ "$MODE" = "dev" ]; then
  LDFLAGS="$LDFLAGS -X main.development=true"
elif [ "$MODE" = "release" ]; then
  if [ -n "$MANIFEST_SHA256" ]; then
    LDFLAGS="$LDFLAGS -X main.manifestSHA256=$MANIFEST_SHA256"
  fi
else
  echo "ERROR: --mode must be dev or release" >&2
  exit 2
fi

copy_verified_cronet() {
  local goos="$1" arch="$2" dest="$3" libfile
  if [ "$goos" = "windows" ]; then libfile="libcronet.dll"; else libfile="libcronet.so"; fi
  local mod="github.com/sagernet/cronet-go/lib/${goos}_${arch}"
  local libdir rootdir want have
  libdir="$(go -C "$NIKO_DIR/libcore" list -m -f '{{.Dir}}' "$mod")"
  rootdir="$(go -C "$NIKO_DIR/libcore" list -m -f '{{.Dir}}' github.com/sagernet/cronet-go)"
  want="$(awk -v f="lib/${goos}_${arch}/$libfile" '$2 == f {print $1}' "$rootdir/SHA256SUMS")"
  have="$(sha256sum "$libdir/$libfile" | cut -d' ' -f1)"
  [ -n "$want" ] && [ "$have" = "$want" ] || { echo "ERROR: $libfile SHA256 mismatch ($have vs ${want:-none})" >&2; exit 1; }
  grep -q "const Version = \"$CHROMIUM\"" "$libdir"/libcronet*.go || { echo "ERROR: $mod is not Chromium $CHROMIUM" >&2; exit 1; }
  cp -a "$libdir/$libfile" "$dest/$libfile"
}

build_linux() {
  local out="$OUT_DIR/linux-$TARGET_ARCH"
  mkdir -p "$out"
  local tags="$BASE_TAGS"
  if [ "$MODE" = "release" ]; then
    tags="$BASE_TAGS,with_naive_outbound,with_purego"
    copy_verified_cronet linux "$TARGET_ARCH" "$out"
  fi
  (cd "$NIKO_DIR/libcore" && GOOS=linux GOARCH="$TARGET_ARCH" CGO_ENABLED=0 go build -trimpath \
    -ldflags="$LDFLAGS" -tags="$tags" -o "$out/niko-daemon" ./cmd/nikod)
  echo "Built $out/niko-daemon ($MODE, $NIKO_VERSION)"
}

build_windows() {
  local out="$OUT_DIR/windows-$TARGET_ARCH"
  mkdir -p "$out"
  local tags="$BASE_TAGS,with_naive_outbound,with_purego,with_external_windivert,with_external_usbip_drivers"
  (cd "$NIKO_DIR/libcore" && GOOS=windows GOARCH="$TARGET_ARCH" CGO_ENABLED=0 go build -trimpath \
    -ldflags="$LDFLAGS" -tags="$tags" -o "$out/niko-daemon.exe" ./cmd/nikod)
  copy_verified_cronet windows "$TARGET_ARCH" "$out"
  echo "Built $out/niko-daemon.exe ($MODE, $NIKO_VERSION)"
}

build_darwin() {
  local out="$OUT_DIR/darwin-$TARGET_ARCH"
  mkdir -p "$out"
  local tags="$BASE_TAGS"
  (cd "$NIKO_DIR/libcore" && GOOS=darwin GOARCH="$TARGET_ARCH" CGO_ENABLED=0 go build -trimpath \
    -ldflags="$LDFLAGS" -tags="$tags" -o "$out/niko-daemon" ./cmd/nikod)
  echo "Built $out/niko-daemon ($MODE, $NIKO_VERSION)"
}

case "$TARGET_OS" in
  linux) build_linux ;;
  windows) build_windows ;;
  darwin) build_darwin ;;
  all) build_linux; build_windows ;;
  *) echo "ERROR: --os must be linux, windows, darwin, or all" >&2; exit 2 ;;
esac
