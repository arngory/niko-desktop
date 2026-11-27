#!/usr/bin/env bash
# Package a Windows portable release ZIP following doc/release-layout.md with
# non-cyclic signing and manifest embedding:
#   1. Copy Flutter Windows release output into staging root
#   2. Check window bundle for forbidden dev/unsafe strings
#   3. Authenticode-sign niko.exe
#   4. Copy verified libcronet.dll into resources/daemon/
#   5. Generate resources/files.sha256 and compute its SHA-256
#   6. Build release niko-daemon.exe with -X main.manifestSHA256=<hash> and verify no forbidden strings
#   7. Authenticode-sign resources/daemon/niko-daemon.exe with the same certificate
#   8. Zip niko-<version>-windows-<arch>.zip + SHA256SUMS (+ optional SHA256SUMS.minisig)
#
# Usage:
#   tool/package_windows.sh --window-dir <dir> [--arch amd64|arm64] [--version <ver>] \
#     [--out <dir>] [--pfx <file> --pfx-pass <pass>] [--self-signed] \
#     [--sign-via-vm] [--minisign-key <file>] [--minisign-pass <pass>]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WINDOW_DIR=""
ARCH="amd64"
VERSION=""
OUT_DIR="$ROOT/build/dist"
PFX_PATH=""
PFX_PASS="niko-local-test"
SELF_SIGNED=0
SIGN_VIA_VM=0
MINISIGN_KEY=""
MINISIGN_PASS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --window-dir) WINDOW_DIR="$2"; shift 2 ;;
    --arch) ARCH="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    --pfx) PFX_PATH="$2"; shift 2 ;;
    --pfx-pass) PFX_PASS="$2"; shift 2 ;;
    --self-signed) SELF_SIGNED=1; shift ;;
    --sign-via-vm) SIGN_VIA_VM=1; shift ;;
    --minisign-key) MINISIGN_KEY="$2"; shift 2 ;;
    --minisign-pass) MINISIGN_PASS="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,18p' "$0"
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$WINDOW_DIR" ] && [ -f "$WINDOW_DIR/niko.exe" ] || {
  echo "ERROR: --window-dir must point to a directory containing niko.exe" >&2
  exit 2
}

if [ -z "$VERSION" ]; then
  VERSION="$(sed -n 's/^version: *\([^+]*\).*/\1/p' "$ROOT/pubspec.yaml")"
fi
[ -n "$VERSION" ] || { echo "ERROR: cannot determine version" >&2; exit 1; }

PKG_NAME="niko-${VERSION}-windows-${ARCH}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

if [ "$SELF_SIGNED" -eq 1 ] && [ -z "$PFX_PATH" ]; then
  echo "Generating ephemeral self-signed Authenticode code-signing certificate..."
  cat > "$TMP_DIR/codesign.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3_codesign
prompt = no

[dn]
CN = Niko Local Test Signer

[v3_codesign]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP_DIR/codesign.key" \
    -out "$TMP_DIR/codesign.crt" \
    -days 30 \
    -config "$TMP_DIR/codesign.cnf" >/dev/null 2>&1
  # Use -legacy on OpenSSL 3.x so Windows signtool/CryptoAPI can read the private key bag.
  if ! openssl pkcs12 -export -legacy \
    -out "$TMP_DIR/codesign.pfx" \
    -inkey "$TMP_DIR/codesign.key" \
    -in "$TMP_DIR/codesign.crt" \
    -passout "pass:$PFX_PASS" 2>/dev/null; then
    openssl pkcs12 -export \
      -out "$TMP_DIR/codesign.pfx" \
      -inkey "$TMP_DIR/codesign.key" \
      -in "$TMP_DIR/codesign.crt" \
      -passout "pass:$PFX_PASS"
  fi
  PFX_PATH="$TMP_DIR/codesign.pfx"
fi

[ -n "$PFX_PATH" ] && [ -f "$PFX_PATH" ] || {
  echo "ERROR: signing certificate required (--pfx <file> or --self-signed)" >&2
  exit 2
}

sign_pe() {
  local target="$1"
  if [ "$SIGN_VIA_VM" -eq 1 ]; then
    "$ROOT/tool/build_windows_vm.sh" --sign-exe "$target" --pfx "$PFX_PATH" --pfx-pass "$PFX_PASS" --keep-vm
  elif command -v osslsigncode >/dev/null 2>&1; then
    local signed="${target}.signed"
    osslsigncode sign -pkcs12 "$PFX_PATH" -pass "$PFX_PASS" -h sha256 \
      -n "Niko Desktop" -in "$target" -out "$signed" >/dev/null
    mv "$signed" "$target"
  elif command -v signtool.exe >/dev/null 2>&1 || command -v signtool >/dev/null 2>&1; then
    local st
    st="$(command -v signtool.exe || command -v signtool)"
    "$st" sign /fd SHA256 /f "$PFX_PATH" /p "$PFX_PASS" "$target"
  elif command -v powershell.exe >/dev/null 2>&1 || command -v pwsh >/dev/null 2>&1; then
    local ps
    ps="$(command -v powershell.exe || command -v pwsh)"
    local win_pfx win_target
    if command -v cygpath >/dev/null 2>&1; then
      win_pfx="$(cygpath -w "$PFX_PATH")"
      win_target="$(cygpath -w "$target")"
    else
      win_pfx="$PFX_PATH"
      win_target="$target"
    fi
    "$ps" -NoProfile -Command "
      \$ErrorActionPreference = 'Stop'
      \$pw = ConvertTo-SecureString '$PFX_PASS' -AsPlainText -Force
      \$cert = Import-PfxCertificate -FilePath '$win_pfx' -CertStoreLocation 'Cert:\LocalMachine\My' -Password \$pw
      try {
        \$signtool = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin\*\x64\signtool.exe' -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
        if (\$signtool) {
          & \$signtool.FullName sign /sm /fd SHA256 /sha1 \$cert.Thumbprint '$win_target'
          if (\$LASTEXITCODE -ne 0) { throw \"signtool failed with exit \$LASTEXITCODE\" }
        } else {
          \$res = Set-AuthenticodeSignature -FilePath '$win_target' -Certificate \$cert -HashAlgorithm SHA256
          if (-not \$res.SignerCertificate) { throw \"Sign failed: \$(\$res.Status) \$(\$res.StatusMessage)\" }
        }
      } finally {
        Remove-Item \"Cert:\LocalMachine\My\\\$(\$cert.Thumbprint)\" -Force -ErrorAction SilentlyContinue
      }
    "
  else
    echo "ERROR: no Authenticode signer available (install osslsigncode, run on Windows, or pass --sign-via-vm)" >&2
    exit 1
  fi
}

check_no_forbidden_strings() {
  local dir="$1"
  for forbidden in "--daemon takes 127.0.0.1" "DevEndpoint" "--allow-unsafe-installation-directory-permissions"; do
    local rc=0
    grep -rqaF -- "$forbidden" "$dir" || rc=$?
    if [ "$rc" -eq 0 ]; then
      echo "ERROR: release output carries forbidden string: $forbidden" >&2
      exit 1
    elif [ "$rc" -ne 1 ]; then
      echo "ERROR: grep failed (rc=$rc) checking $forbidden" >&2
      exit 1
    fi
  done
}

STAGE_ROOT="$TMP_DIR/$PKG_NAME"
mkdir -p "$STAGE_ROOT/resources/daemon"

echo "1. Staging Windows Flutter release bundle..."
cp -a "$WINDOW_DIR"/. "$STAGE_ROOT/"
check_no_forbidden_strings "$STAGE_ROOT"

echo "2. Signing niko.exe..."
sign_pe "$STAGE_ROOT/niko.exe"

echo "3. Building initial release daemon to fetch verified libcronet.dll..."
DAEMON_TMP="$TMP_DIR/daemon-pre"
"$ROOT/tool/build_daemon.sh" --os windows --arch "$ARCH" --mode release --out "$DAEMON_TMP" >/dev/null
cp -a "$DAEMON_TMP/windows-$ARCH/libcronet.dll" "$STAGE_ROOT/resources/daemon/libcronet.dll"

echo "4. Generating resources/files.sha256..."
(
  cd "$STAGE_ROOT"
  LC_ALL=C find . -type f ! -path './resources/files.sha256' ! -path './resources/daemon/niko-daemon.exe' \
    | sed 's|^\./||' \
    | LC_ALL=C sort \
    | while IFS= read -r rel; do
        sum="$(sha256sum "$rel" | cut -d' ' -f1)"
        printf '%s  %s\n' "$sum" "$rel"
      done > resources/files.sha256
)
MANIFEST_SHA256="$(sha256sum "$STAGE_ROOT/resources/files.sha256" | cut -d' ' -f1)"
echo "   manifest SHA-256: $MANIFEST_SHA256 ($(wc -l < "$STAGE_ROOT/resources/files.sha256") files)"

echo "5. Building release niko-daemon.exe with embedded manifestSHA256..."
DAEMON_FINAL="$TMP_DIR/daemon-final"
"$ROOT/tool/build_daemon.sh" --os windows --arch "$ARCH" --mode release \
  --manifest-sha256 "$MANIFEST_SHA256" --out "$DAEMON_FINAL"
cp -a "$DAEMON_FINAL/windows-$ARCH/niko-daemon.exe" "$STAGE_ROOT/resources/daemon/niko-daemon.exe"

# Verify release daemon contains no DevEndpoint and includes knock, naive, NikoService
rc=0
grep -qaF -- "DevEndpoint" "$STAGE_ROOT/resources/daemon/niko-daemon.exe" || rc=$?
if [ "$rc" -eq 0 ]; then
  echo "ERROR: release niko-daemon.exe carries forbidden dev string: DevEndpoint" >&2
  exit 1
elif [ "$rc" -ne 1 ]; then
  echo "ERROR: grep failed (rc=$rc) checking DevEndpoint" >&2
  exit 1
fi
for required in "sing-box/protocol/knock" "sing-box/protocol/naive" "niko.v1.NikoService"; do
  grep -qaF -- "$required" "$STAGE_ROOT/resources/daemon/niko-daemon.exe" || {
    echo "ERROR: release niko-daemon.exe missing required symbol: $required" >&2
    exit 1
  }
done

echo "6. Signing resources/daemon/niko-daemon.exe with the same certificate..."
sign_pe "$STAGE_ROOT/resources/daemon/niko-daemon.exe"

echo "7. Creating portable ZIP archive..."
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
ZIP_PATH="$OUT_DIR/${PKG_NAME}.zip"
rm -f "$ZIP_PATH"
(
  cd "$TMP_DIR"
  if command -v zip >/dev/null 2>&1; then
    zip -q -r -9 "$ZIP_PATH" "$PKG_NAME"
  else
    python3 -c "
import os, sys, zipfile
root, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
    for base, _, files in os.walk(root):
        for name in sorted(files):
            full = os.path.join(base, name)
            zf.write(full, os.path.relpath(full, os.path.dirname(root)))
" "$TMP_DIR/$PKG_NAME" "$ZIP_PATH"
  fi
)

(
  cd "$OUT_DIR"
  sha256sum "${PKG_NAME}.zip" > "SHA256SUMS.windows-${ARCH}-zip"
)
if [ -n "$MINISIGN_KEY" ]; then
  if [ -n "$MINISIGN_PASS" ]; then
    NIKO_MINISIGN_PASS="$MINISIGN_PASS" "$ROOT/tool/sign_release.sh" --dir "$OUT_DIR" --version "$VERSION" --minisign-key "$MINISIGN_KEY"
  else
    "$ROOT/tool/sign_release.sh" --dir "$OUT_DIR" --version "$VERSION" --minisign-key "$MINISIGN_KEY"
  fi
fi

echo "Packaged: $ZIP_PATH ($(du -h "$ZIP_PATH" | cut -f1))"
cat "$OUT_DIR/SHA256SUMS.windows-${ARCH}-zip"
