import 'dart:io';

/// Pure bootstrap helpers shared by `main.dart` so startup path resolution and
/// transport-teardown error filtering can be unit-tested independently.

/// Returns true for the narrow grpc-dart 5.x `Http2TransportStream` teardown
/// race where cancelling/closing a stream writes to an already-closed http2 sink.
bool isHttp2TeardownStateError(Object error, StackTrace stack) {
  return error is StateError &&
      error.message == 'Cannot add event after closing' &&
      stack.toString().contains('_StreamSinkWrapper.add');
}

/// Picks the daemon executable used to export a user-mode store snapshot when
/// migrating into the installed Linux system service.
String? resolveLinuxMigrationDaemonPath({
  required bool hasBundledDaemon,
  required String bundledDaemonPath,
  required String installedBinaryPath,
}) {
  if (hasBundledDaemon && bundledDaemonPath.isNotEmpty) {
    return bundledDaemonPath;
  }
  if (installedBinaryPath.isNotEmpty) {
    return installedBinaryPath;
  }
  return null;
}

/// Picks the daemon executable used to uninstall the Linux system service.
String resolveLinuxUninstallDaemonPath({
  required String installedBinaryPath,
  required String bundledDaemonPath,
  bool Function(String path)? fileExists,
}) {
  final exists = fileExists ?? (String p) => File(p).existsSync();
  if (installedBinaryPath.isNotEmpty && exists(installedBinaryPath)) {
    return installedBinaryPath;
  }
  if (bundledDaemonPath.isNotEmpty) {
    return bundledDaemonPath;
  }
  return '/usr/local/libexec/niko/niko-daemon';
}
