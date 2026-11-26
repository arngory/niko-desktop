import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../daemon/daemon.dart';
import '../daemon/user_mode_daemon.dart';
import '../daemon/worker_process.dart';

typedef UserModeExporter = Future<List<int>> Function();

/// Manages one-time migration of profiles, subscriptions, rules, settings, and raycontrol nodes
/// from the unprivileged user-mode store to the privileged system service store.
class UserStoreMigrationController extends ChangeNotifier {
  UserStoreMigrationController({
    required this.userDataDir,
    required this.exportUserSnapshot,
    required this.getServiceDaemon,
    bool Function(String? dir)? hasUnmigrated,
    Future<void> Function(String dir)? markMigrated,
  })  : _hasUnmigrated = hasUnmigrated ?? hasUnmigratedUserStore,
        _markMigrated = markMigrated ?? markUserStoreMigrated {
    refresh();
  }

  final String? userDataDir;
  final UserModeExporter exportUserSnapshot;
  final Daemon? Function() getServiceDaemon;
  final bool Function(String? dir) _hasUnmigrated;
  final Future<void> Function(String dir) _markMigrated;

  bool pending = false;
  bool migrating = false;
  bool dismissed = false;
  StoreImportResult? imported;
  String error = '';

  bool get visible => pending && !dismissed;

  void refresh() {
    final next = _hasUnmigrated(userDataDir);
    if (next != pending) {
      pending = next;
      notifyListeners();
    }
  }

  void dismiss() {
    if (dismissed) return;
    dismissed = true;
    notifyListeners();
  }

  /// Exports decrypted data from the user-mode store and imports it into the active system service,
  /// re-sealing every secret under the service's security context, then marks the old store migrated.
  Future<StoreImportResult?> migrateNow() async {
    if (migrating || !pending) return null;
    final dir = userDataDir;
    final service = getServiceDaemon();
    if (dir == null || dir.isEmpty || service == null) return null;

    migrating = true;
    error = '';
    notifyListeners();
    List<int>? snapshot;
    try {
      snapshot = await exportUserSnapshot();
      final result = await service.importUserStore(snapshot);
      await _markMigrated(dir);
      imported = result;
      pending = false;
      return result;
    } catch (e) {
      error = daemonError(e);
      return null;
    } finally {
      if (snapshot != null) zeroBytes(snapshot);
      migrating = false;
      notifyListeners();
    }
  }

  /// Default platform exporter: starts a short-lived unprivileged user-mode daemon/worker as the
  /// current interactive user (`--no-restore` on Linux so no core or proxy is restored), calls
  /// `ExportUserStore()`, and shuts it down cleanly.
  static Future<List<int>> exportViaTemporaryUserDaemon({
    required String daemonExecutablePath,
    required String userDataDir,
  }) async {
    if (Platform.isWindows) {
      final worker = WorkerProcess(
        daemonExecutablePath: daemonExecutablePath,
        userMode: true,
        workingDirectory: userDataDir,
      );
      final daemon = GrpcDaemon.worker(worker);
      try {
        return await daemon.exportUserStore();
      } finally {
        await daemon.close();
      }
    }

    // Ensure any lingering user-mode daemon on this working directory has released its flock.
    await stopExistingUserModeDaemon(userDataDir);

    final rng = Random.secure();
    final suffix = List<int>.generate(6, (_) => rng.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final runtimeDir = Platform.environment['XDG_RUNTIME_DIR']?.trim() ?? '';
    final String sockPath;
    Directory? cleanupDir;
    if (runtimeDir.isNotEmpty) {
      final nikoDir = Directory('$runtimeDir/niko');
      if (!nikoDir.existsSync()) {
        nikoDir.createSync(recursive: true);
      }
      sockPath = '${nikoDir.path}/migrate-$suffix.sock';
    } else {
      cleanupDir = await Directory('/tmp').createTemp('niko-m-');
      sockPath = '${cleanupDir.path}/m.sock';
    }

    LinuxUserModeDaemon? handle;
    GrpcDaemon? daemon;
    try {
      handle = await LinuxUserModeDaemon.ensureRunning(
        daemonExecutablePath: daemonExecutablePath,
        socketPath: sockPath,
        dataDir: userDataDir,
        noRestore: true,
      );
      if (handle == null) {
        throw StateError('failed to start temporary user-mode daemon for migration');
      }
      daemon = GrpcDaemon.unix(handle.socketPath);
      return await daemon.exportUserStore();
    } finally {
      await daemon?.close();
      await handle?.stop();
      try {
        final sockFile = File(sockPath);
        if (sockFile.existsSync()) sockFile.deleteSync();
      } catch (_) {}
      try {
        if (cleanupDir != null && cleanupDir.existsSync()) {
          await cleanupDir.delete(recursive: true);
        }
      } catch (_) {}
    }
  }
}
