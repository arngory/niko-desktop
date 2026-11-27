import 'dart:async';
import 'dart:io';

import 'locator.dart';

/// Resolves `%LOCALAPPDATA%\Niko\user-daemon` on Windows.
String? defaultWindowsUserDataDir({Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  final localAppData = env['LOCALAPPDATA'];
  if (localAppData == null || localAppData.trim().isEmpty) return null;
  return '${localAppData.trim()}\\Niko\\user-daemon';
}

/// Resolves the platform's default user-mode daemon working directory.
String? defaultUserModeDataDir({Map<String, String>? environment}) {
  if (Platform.isWindows) return defaultWindowsUserDataDir(environment: environment);
  if (Platform.isLinux) return defaultLinuxUserDataDir(environment: environment);
  if (Platform.isMacOS) return defaultMacosUserDataDir(environment: environment);
  return null;
}

/// Returns true if [dataDir] contains an unmigrated `niko/store.json` inside its `users/` subtree.
bool hasUnmigratedUserStore(String? dataDir) {
  if (dataDir == null || dataDir.isEmpty) return false;
  final root = Directory(dataDir);
  if (!root.existsSync()) return false;
  if (File('${root.path}${Platform.pathSeparator}.migrated').existsSync()) return false;
  final usersDir = Directory('${root.path}${Platform.pathSeparator}users');
  if (!usersDir.existsSync()) return false;
  try {
    for (final entry in usersDir.listSync(followLinks: false)) {
      if (entry is Directory) {
        final store = File('${entry.path}${Platform.pathSeparator}niko${Platform.pathSeparator}store.json');
        if (store.existsSync() && store.lengthSync() > 0) {
          return true;
        }
      }
    }
  } catch (_) {
    return false;
  }
  return false;
}

/// Marks [dataDir] as migrated by renaming it to `<dataDir>.migrated-<unixSeconds>`, falling back
/// to a `.migrated` marker file if the directory is busy on Windows. Throws if both fail.
Future<void> markUserStoreMigrated(String dataDir, {DateTime? now}) async {
  final dir = Directory(dataDir);
  if (!dir.existsSync()) return;
  final ts = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
  final backupPath = '$dataDir.migrated-$ts';
  try {
    await dir.rename(backupPath);
    return;
  } catch (_) {
    // Fall back to marker file if rename fails (e.g. open file handle on Windows).
  }
  await File('$dataDir${Platform.pathSeparator}.migrated').writeAsString('$ts\n', flush: true);
}

/// Zeroes sensitive plaintext bytes in place when backed by a mutable list.
void zeroBytes(List<int> bytes) {
  try {
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = 0;
    }
  } catch (_) {
    // Unmodifiable test lists cannot be zeroed.
  }
}

/// Stops an already-running Linux user-mode daemon identified by `<dataDir>/niko-daemon.lock`
/// after verifying `/proc/<pid>/cmdline` and process UID match this user.
Future<void> stopExistingUserModeDaemon(
  String? dataDir, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  if (!Platform.isLinux || dataDir == null || dataDir.isEmpty) return;
  final lockFile = File('$dataDir/niko-daemon.lock');
  if (!lockFile.existsSync()) return;
  final raw = lockFile.readAsStringSync().trim();
  final targetPid = int.tryParse(raw);
  if (targetPid == null || targetPid <= 1 || targetPid == pid) return;

  final cmdlineFile = File('/proc/$targetPid/cmdline');
  if (!cmdlineFile.existsSync()) return;
  try {
    final cmdBytes = cmdlineFile.readAsBytesSync();
    final cmdline = String.fromCharCodes(cmdBytes.map((b) => b == 0 ? 0x20 : b));
    if (!cmdline.contains('niko-daemon') || !cmdline.contains('--user-mode')) return;

    final selfUid = _readProcRealUid('/proc/self/status');
    final targetUid = _readProcRealUid('/proc/$targetPid/status');
    if (selfUid == null || targetUid == null || selfUid != targetUid) return;
  } catch (_) {
    return;
  }

  Process.killPid(targetPid, ProcessSignal.sigterm);
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (!Directory('/proc/$targetPid').existsSync()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

int? _readProcRealUid(String statusPath) {
  try {
    for (final line in File(statusPath).readAsLinesSync()) {
      if (line.startsWith('Uid:')) {
        final parts = line.substring(4).trim().split(RegExp(r'\s+'));
        if (parts.isNotEmpty) return int.tryParse(parts.first);
      }
    }
  } catch (_) {}
  return null;
}

typedef DetachedProcessStarter = Future<Process> Function(
  String executable,
  List<String> arguments, {
  ProcessStartMode mode,
});

/// Handle to a Unix (Linux / macOS) unprivileged user-mode daemon process (`niko-daemon run --user-mode`).
typedef UnixUserModeDaemon = LinuxUserModeDaemon;

/// Handle to a Linux/macOS unprivileged user-mode daemon process (`niko-daemon run --user-mode`).
class LinuxUserModeDaemon {
  LinuxUserModeDaemon({
    required this.socketPath,
    required this.dataDir,
    this.process,
  });

  final String socketPath;
  final String dataDir;

  /// Non-null when this window spawned the daemon process itself.
  final Process? process;

  /// Ensures a Unix user-mode daemon is listening on [socketPath], starting one if needed.
  static Future<LinuxUserModeDaemon?> ensureRunning({
    required String daemonExecutablePath,
    String? socketPath,
    String? dataDir,
    bool noRestore = false,
    Map<String, String>? environment,
    Future<bool> Function(String socketPath)? probeSocket,
    DetachedProcessStarter? startProcess,
    Duration readyTimeout = const Duration(seconds: 6),
    Duration pollInterval = const Duration(milliseconds: 100),
  }) async {
    final sock = socketPath ??
        (Platform.isMacOS
            ? defaultMacosUserSocketPath(environment: environment)
            : defaultLinuxUserSocketPath(environment: environment));
    final dir = dataDir ??
        (Platform.isMacOS
            ? defaultMacosUserDataDir(environment: environment)
            : defaultLinuxUserDataDir(environment: environment));
    if (sock == null || sock.isEmpty || dir == null || dir.isEmpty) {
      return null;
    }
    final probe = probeSocket ?? probeUnixSocketReachable;
    if (await probe(sock)) {
      return LinuxUserModeDaemon(socketPath: sock, dataDir: dir);
    }
    final starter = startProcess ??
        (String exe, List<String> args, {ProcessStartMode mode = ProcessStartMode.normal}) =>
            Process.start(exe, args, mode: mode);
    final proc = await starter(
      daemonExecutablePath,
      [
        'run',
        '--user-mode',
        if (noRestore) '--no-restore',
        '--socket',
        sock,
        '--working-directory',
        dir,
      ],
      mode: ProcessStartMode.normal,
    );
    // Drain stdout/stderr so pipes never block the daemon process.
    proc.stdout.drain<void>().ignore();
    proc.stderr.drain<void>().ignore();

    var exited = false;
    unawaited(proc.exitCode.then((_) => exited = true));

    final deadline = DateTime.now().add(readyTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await probe(sock)) {
        return LinuxUserModeDaemon(socketPath: sock, dataDir: dir, process: proc);
      }
      if (exited) {
        // Another instance might have won the flock race and opened the socket right as we exited.
        if (await probe(sock)) {
          return LinuxUserModeDaemon(socketPath: sock, dataDir: dir);
        }
        return null;
      }
      await Future<void>.delayed(pollInterval);
    }
    proc.kill(ProcessSignal.sigterm);
    return null;
  }

  /// Stops the spawned user-mode daemon cleanly with SIGTERM (then SIGKILL after 2s).
  Future<void> stop() async {
    final proc = process;
    if (proc == null) return;
    proc.kill(ProcessSignal.sigterm);
    try {
      await proc.exitCode.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      proc.kill(ProcessSignal.sigkill);
      await proc.exitCode.timeout(const Duration(seconds: 2), onTimeout: () => -1);
    }
  }
}
