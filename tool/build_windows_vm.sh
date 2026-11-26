#!/usr/bin/env bash
# Build the Windows Flutter release bundle inside the local QEMU win11-build VM
# (backed by ../win11-ent/disk.qcow2 so the clean test VM image stays untouched).
#
# Usage:
#   tool/build_windows_vm.sh [--out <dir>] [--ref <git-ref>] [--keep-vm] [--ssh-port <port>]
#   tool/build_windows_vm.sh --sign-exe <local-exe> --pfx <local-pfx> --pfx-pass <pass> [--ssh-port <port>]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VMS_ROOT="${NIKO_VMS_ROOT:-/home/huita/vms}"
VM_DIR="${NIKO_BUILD_VM_DIR:-$VMS_ROOT/win11-build}"
SSH_KEY="${NIKO_VM_SSH_KEY:-$VMS_ROOT/id_ed25519}"
SSH_PORT=22212
OUT_DIR="$ROOT/build/windows-vm/Release"
GIT_REF="HEAD"
KEEP_VM=0

SIGN_EXE=""
PFX_PATH=""
PFX_PASS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT_DIR="$2"; shift 2 ;;
    --ref) GIT_REF="$2"; shift 2 ;;
    --keep-vm) KEEP_VM=1; shift ;;
    --ssh-port) SSH_PORT="$2"; shift 2 ;;
    --sign-exe) SIGN_EXE="$2"; shift 2 ;;
    --pfx) PFX_PATH="$2"; shift 2 ;;
    --pfx-pass) PFX_PASS="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,8p' "$0"
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -p "$SSH_PORT")
SCP_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -P "$SSH_PORT")

VM_STARTED_BY_US=0
QEMU_PID=""
TPM_PID_FILE="$VM_DIR/tpm/swtpm.pid"

ensure_vm() {
  if ssh "${SSH_OPTS[@]}" tester@127.0.0.1 'echo ok' >/dev/null 2>&1; then
    return 0
  fi
  [ -f "$VM_DIR/disk.qcow2" ] || { echo "ERROR: build VM disk not found: $VM_DIR/disk.qcow2" >&2; exit 1; }
  echo "Starting win11-build VM (SSH port $SSH_PORT)..."
  local tpm_dir="$VM_DIR/tpm"
  local tpm_sock="$tpm_dir/swtpm-sock"
  local mon_sock="$VM_DIR/monitor.sock"
  rm -f "$tpm_sock" "$TPM_PID_FILE" "$mon_sock"
  swtpm socket --tpm2 --tpmstate dir="$tpm_dir" --ctrl type=unixio,path="$tpm_sock" --pid file="$TPM_PID_FILE" --daemon
  qemu-system-x86_64 \
    -name niko-win11-build \
    -machine q35,accel=kvm,smm=on \
    -cpu host,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time,hv_vpindex,hv_synic,hv_stimer \
    -smp 8,sockets=1,cores=8,threads=1 \
    -m 8G \
    -global driver=cfi.pflash01,property=secure,value=on \
    -drive "if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd" \
    -drive "if=pflash,format=raw,file=$VM_DIR/OVMF_VARS.fd" \
    -chardev "socket,id=chrtpm,path=$tpm_sock" \
    -tpmdev emulator,id=tpm0,chardev=chrtpm \
    -device tpm-tis,tpmdev=tpm0 \
    -device ich9-ahci,id=ahci \
    -drive "file=$VM_DIR/disk.qcow2,if=none,id=hd0,format=qcow2,cache=writeback,discard=unmap" \
    -device ide-hd,drive=hd0,bus=ahci.0,bootindex=1 \
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22" \
    -device e1000e,netdev=net0 \
    -device qemu-xhci \
    -device usb-tablet \
    -device virtio-vga \
    -rtc base=localtime,clock=host \
    -monitor "unix:$mon_sock,server,nowait" \
    -display none -vnc 127.0.0.1:3 &
  QEMU_PID=$!
  VM_STARTED_BY_US=1
  for _ in $(seq 1 60); do
    if ssh "${SSH_OPTS[@]}" tester@127.0.0.1 'echo ok' >/dev/null 2>&1; then
      return 0
    fi
    sleep 3
  done
  echo "ERROR: win11-build VM did not answer SSH in time" >&2
  exit 1
}

cleanup() {
  if [ "$VM_STARTED_BY_US" -eq 1 ] && [ "$KEEP_VM" -eq 0 ]; then
    echo "Shutting down win11-build VM..."
    ssh "${SSH_OPTS[@]}" tester@127.0.0.1 'Stop-Computer -Force' >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do
      kill -0 "$QEMU_PID" 2>/dev/null || break
      sleep 2
    done
    kill "$QEMU_PID" 2>/dev/null || true
    if [ -f "$TPM_PID_FILE" ]; then
      kill "$(cat "$TPM_PID_FILE")" 2>/dev/null || true
      rm -f "$TPM_PID_FILE"
    fi
  fi
}
trap cleanup EXIT

ensure_vm

if [ -n "$SIGN_EXE" ]; then
  [ -f "$SIGN_EXE" ] || { echo "ERROR: file not found: $SIGN_EXE" >&2; exit 1; }
  [ -f "$PFX_PATH" ] || { echo "ERROR: pfx not found: $PFX_PATH" >&2; exit 1; }
  base="$(basename "$SIGN_EXE")"
  ssh "${SSH_OPTS[@]}" tester@127.0.0.1 'New-Item -ItemType Directory -Path C:\build-sign -Force | Out-Null' >/dev/null
  scp -q "${SCP_OPTS[@]}" "$PFX_PATH" "tester@127.0.0.1:C:/build-sign/cert.pfx"
  scp -q "${SCP_OPTS[@]}" "$SIGN_EXE" "tester@127.0.0.1:C:/build-sign/$base"
  ssh "${SSH_OPTS[@]}" tester@127.0.0.1 "
    \$ErrorActionPreference = 'Stop'
    \$target = 'C:\build-sign\\${base}'
    \$pw = ConvertTo-SecureString '$PFX_PASS' -AsPlainText -Force
    \$cert = Import-PfxCertificate -FilePath 'C:\build-sign\cert.pfx' -CertStoreLocation 'Cert:\LocalMachine\My' -Password \$pw
    try {
      \$signtool = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin\*\x64\signtool.exe' -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
      if (\$signtool) {
        & \$signtool.FullName sign /sm /fd SHA256 /sha1 \$cert.Thumbprint \$target
        if (\$LASTEXITCODE -ne 0) { throw \"signtool failed with exit \$LASTEXITCODE\" }
      } else {
        \$res = Set-AuthenticodeSignature -FilePath \$target -Certificate \$cert -HashAlgorithm SHA256
        if (-not \$res.SignerCertificate) { throw \"Set-AuthenticodeSignature failed: \$(\$res.Status) \$(\$res.StatusMessage)\" }
      }
    } finally {
      Remove-Item \"Cert:\LocalMachine\My\\\$(\$cert.Thumbprint)\" -Force -ErrorAction SilentlyContinue
      Remove-Item 'C:\build-sign\cert.pfx' -Force -ErrorAction SilentlyContinue
    }
    \$sig = Get-AuthenticodeSignature \$target
    if (-not \$sig.SignerCertificate) { throw \"Signed file missing SignerCertificate: \$(\$sig.Status) \$(\$sig.StatusMessage)\" }
    Write-Host \"Signed ${base} (thumbprint \$(\$sig.SignerCertificate.Thumbprint), status \$(\$sig.Status))\"
  "
  scp -q "${SCP_OPTS[@]}" "tester@127.0.0.1:C:/build-sign/$base" "$SIGN_EXE"
  ssh "${SSH_OPTS[@]}" tester@127.0.0.1 "Remove-Item 'C:\build-sign\\${base}' -Force -ErrorAction SilentlyContinue" >/dev/null
  exit 0
fi

WINDOW_VERSION="$(sed -n 's/^version: *\([^+]*\).*/\1/p' "$ROOT/pubspec.yaml")"
[ -n "$WINDOW_VERSION" ] || { echo "ERROR: cannot read version from pubspec.yaml" >&2; exit 1; }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"; cleanup' EXIT

BUNDLE_REF="$GIT_REF"
TEMP_REF=""
if [ "$GIT_REF" = "HEAD" ]; then
  STASH_OID="$(git -C "$ROOT" stash create || true)"
  if [ -n "$STASH_OID" ]; then
    TEMP_REF="refs/tmp/vm-build-$$"
    git -C "$ROOT" update-ref "$TEMP_REF" "$STASH_OID"
    BUNDLE_REF="$TEMP_REF"
    echo "Bundling working tree snapshot ${STASH_OID:0:9} (version $WINDOW_VERSION)..."
  else
    echo "Creating git bundle of $GIT_REF (version $WINDOW_VERSION)..."
  fi
else
  echo "Creating git bundle of $GIT_REF (version $WINDOW_VERSION)..."
fi
git -C "$ROOT" bundle create "$TMP_DIR/niko-desktop.bundle" "$BUNDLE_REF"
if [ -n "$TEMP_REF" ]; then
  git -C "$ROOT" update-ref -d "$TEMP_REF"
fi

ssh "${SSH_OPTS[@]}" tester@127.0.0.1 'New-Item -ItemType Directory -Path C:\build-work -Force | Out-Null' >/dev/null
scp -q "${SCP_OPTS[@]}" "$TMP_DIR/niko-desktop.bundle" "tester@127.0.0.1:C:/build-work/niko-desktop.bundle"

echo "Building Windows Flutter release inside win11-build VM..."
ssh "${SSH_OPTS[@]}" tester@127.0.0.1 "
  \$ErrorActionPreference = 'Stop'
  \$env:PATH = 'C:\build-tools\git\cmd;C:\build-tools\flutter\bin;' + \$env:PATH
  \$repo = 'C:\build-work\niko-desktop'
  if (Test-Path \$repo) { Remove-Item -Recurse -Force \$repo }
  git init --quiet \$repo
  git -C \$repo fetch --quiet 'C:\build-work\niko-desktop.bundle' '$BUNDLE_REF'
  git -C \$repo checkout --quiet FETCH_HEAD
  Set-Location \$repo
  flutter pub get --enforce-lockfile
  flutter build windows --release --dart-define=NIKO_WINDOW_VERSION=$WINDOW_VERSION
  \$rel = Join-Path \$repo 'build\windows\x64\runner\Release'
  if (-not (Test-Path (Join-Path \$rel 'niko.exe'))) { throw 'niko.exe not produced' }
  \$tar = 'C:\build-work\window-release.tar'
  if (Test-Path \$tar) { Remove-Item \$tar -Force }
  tar.exe -C \$rel -cf \$tar .
  Get-ChildItem \$rel | Select-Object Name, Length | Format-Table -AutoSize
"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
scp -q "${SCP_OPTS[@]}" "tester@127.0.0.1:C:/build-work/window-release.tar" "$TMP_DIR/window-release.tar"
tar -xf "$TMP_DIR/window-release.tar" -C "$OUT_DIR"
[ -f "$OUT_DIR/niko.exe" ] || { echo "ERROR: niko.exe missing in extracted output $OUT_DIR" >&2; exit 1; }
echo "Windows release bundle ready at $OUT_DIR"
ls -la "$OUT_DIR"
