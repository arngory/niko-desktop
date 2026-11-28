/// Window version injected at build time (`--dart-define=NIKO_WINDOW_VERSION=...`); default matches `pubspec.yaml`.
const windowVersion = String.fromEnvironment('NIKO_WINDOW_VERSION', defaultValue: '0.1.0');

/// The window's primary public minisign key, which signs its updates (matches Niko's
/// `libcore/nikoupdater/niko-desktop-update.pub` at the pin in `.github/niko.env`).
const updateSigningKey = 'minisign 0DCF3D8664BAC261';
