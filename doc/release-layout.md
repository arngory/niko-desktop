# Release Archive Layout

This document freezes the on-disk layout of Niko Desktop release archives so that:

- `niko-daemon` (`service install`) can verify and stage the portable tree into a protected system directory;
- the future updater (`BG-12`, `D-SET-12/33`) can unpack and verify updates without guessing paths;
- local packaging scripts (`tool/package_windows.sh`, `tool/package_linux.sh`) and `.github/workflows/release.yml` produce identical artifacts.

## Artifact Naming

| Target | Archive | Checksums & Signature |
| --- | --- | --- |
| Windows x64 | `niko-<version>-windows-amd64.zip` | `SHA256SUMS`, `SHA256SUMS.minisig` |
| Windows arm64 | `niko-<version>-windows-arm64.zip` | `SHA256SUMS`, `SHA256SUMS.minisig` |
| Linux x64 | `niko-<version>-linux-amd64.tar.gz` | `SHA256SUMS`, `SHA256SUMS.minisig` |
| Linux arm64 | `niko-<version>-linux-arm64.tar.gz` | `SHA256SUMS`, `SHA256SUMS.minisig` |
| macOS arm64 | `niko-<version>-darwin-arm64.zip` | `SHA256SUMS`, `SHA256SUMS.minisig` |
| macOS x64 | `niko-<version>-darwin-amd64.zip` | `SHA256SUMS`, `SHA256SUMS.minisig` |

`<version>` comes from `pubspec.yaml` (`version:` without `+<build>`), e.g. `0.1.0`.

## Windows Portable ZIP Layout

The ZIP contains a single top-level directory `niko-<version>-windows-<arch>/`:

```text
niko-<version>-windows-amd64/
├── niko.exe                          # Flutter release executable (Authenticode-signed)
├── flutter_windows.dll
├── msvcp140.dll                      # MSVC runtime DLLs bundled for clean Windows
├── vcruntime140.dll
├── vcruntime140_1.dll
├── data/
│   ├── app.so
│   ├── icudtl.dat
│   └── flutter_assets/...
└── resources/
    ├── files.sha256                  # Manifest verified by niko-daemon service install
    └── daemon/
        ├── niko-daemon.exe           # Release nikod (same Authenticode signer, embedded manifestSHA256)
        └── libcronet.dll             # Verified against cronet-go SHA256SUMS & ChromiumAnchorsVersion
```

### Manifest Format (`resources/files.sha256`)

- Standard `sha256sum` text lines (`<64-char lowercase hex>  <POSIX relative path>`), sorted lexicographically by path, LF (`\n`) line endings.
- Lists **every** regular file inside the top-level directory **except**:
  - `resources/files.sha256` itself, and
  - `resources/daemon/niko-daemon.exe` (which embeds the SHA-256 of `resources/files.sha256` via `-X main.manifestSHA256=<hex>`).
- Must list `niko.exe` and `resources/daemon/libcronet.dll`.
- No symlinks, no `..`, no leading `/`, no backslashes.

### Non-Cyclic Build & Signing Order (Windows)

Because `niko-daemon.exe` embeds the SHA-256 of `resources/files.sha256` (which hashes the signed `niko.exe`), and `service install` checks that `niko.exe` and `niko-daemon.exe` share the exact same Authenticode signer certificate:

1. Build Flutter Windows release (`flutter build windows --release --dart-define=NIKO_WINDOW_VERSION=<version>`).
2. Verify no forbidden dev/unsafe strings appear in the window bundle (`--daemon takes 127.0.0.1`, `DevEndpoint`, `--allow-unsafe-installation-directory-permissions`).
3. Authenticode-sign `niko.exe` with the release (or local test self-signed code-signing) certificate.
4. Copy verified `libcronet.dll` to `resources/daemon/libcronet.dll`.
5. Generate `resources/files.sha256` covering every staged file except `resources/files.sha256` and `resources/daemon/niko-daemon.exe`, and compute `MANIFEST_SHA256 = sha256(resources/files.sha256)`.
6. Build `niko-daemon.exe` in release mode with `-X main.manifestSHA256=$MANIFEST_SHA256` (`tool/build_daemon.sh --os windows --mode release --manifest-sha256 "$MANIFEST_SHA256"`), place it at `resources/daemon/niko-daemon.exe`, and verify no forbidden dev strings appear in it.
7. Authenticode-sign `resources/daemon/niko-daemon.exe` with the **same** certificate as `niko.exe`.
8. Zip the top-level directory into `niko-<version>-windows-<arch>.zip`, write `SHA256SUMS`, and (when a signing key is configured) produce `SHA256SUMS.minisig` via `minisign`.

### Installed Target Directory (Windows)

When the user clicks **Install service** in Niko Desktop, elevated `niko-daemon.exe service install` copies the verified tree into `%ProgramFiles%\Niko\` with strict ACLs (`SYSTEM` + `BUILTIN\Administrators` full control, `Authenticated Users` read/execute) and registers the `niko-daemon` Windows service pointing to `%ProgramFiles%\Niko\resources\daemon\niko-daemon.exe`.

## Linux Release Tarball Layout (P3)

The tarball contains a single top-level directory `niko-<version>-linux-<arch>/`:

```text
niko-<version>-linux-amd64/
├── niko                              # Flutter release executable
├── lib/...                           # Flutter & plugin shared libraries
├── data/...                          # icudtl.dat, flutter_assets, libapp.so
└── resources/
    └── daemon/
        ├── files.sha256              # Manifest of daemon files verified by Linux service install
        ├── niko-daemon               # Release nikod (embedded manifestSHA256)
        ├── libcronet.so              # Verified against cronet-go SHA256SUMS & ChromiumAnchorsVersion
        └── slipstream-client         # Optional: external slipstream helper (built via tool/build_slipstream.sh)
```

## macOS Application Bundle Layout (Minimal Base)

On macOS (`darwin-arm64` / `darwin-amd64`), user-mode Proxy launches the bundled `niko-daemon` beside the `.app` resources and configures system HTTP/HTTPS proxy via `networksetup`:

```text
Niko.app/
└── Contents/
    ├── Info.plist                    # URL schemes (rcinv1/2/3, vless, hy2, naive+https/quic, …)
    ├── MacOS/
    │   └── niko                      # Flutter macOS release executable
    ├── Frameworks/...
    └── Resources/
        └── daemon/
            ├── niko-daemon           # Release nikod (user-mode socket under ~/Library/Application Support/Niko/)
            ├── libcronet.dylib       # Optional: cronet library for naive outbound
            └── slipstream-client     # Optional: external slipstream helper
```
