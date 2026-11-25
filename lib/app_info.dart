/// Window version injected at build time (`--dart-define=NIKO_WINDOW_VERSION=...`); default matches `pubspec.yaml`.
const windowVersion = String.fromEnvironment('NIKO_WINDOW_VERSION', defaultValue: '0.1.0');

/// Public minisign key that signs desktop releases (matches `niko/niko-update.pub`).
const updateSigningKey = 'minisign D5D2D2E799D74D8D';
