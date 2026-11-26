import 'dart:async';
import 'dart:io';

import 'service_install.dart';

/// Quotes a POSIX shell argument safely with single quotes for copyable manual `sudo` commands.
String shellQuotePosix(String value) {
  if (RegExp(r'^[A-Za-z0-9_./:@-]+$').hasMatch(value)) {
    return value;
  }
  return "'${value.replaceAll("'", "'\\''")}'";
}

/// Returns true when the Linux app is running from an AppImage FUSE mount (which root cannot read
/// without FUSE `allow_other`, so daemon files must be staged into `$XDG_RUNTIME_DIR` first).
bool isAppImageEnvironment({
  Map<String, String>? environment,
  String? resolvedExecutable,
}) {
  final env = environment ?? Platform.environment;
  if ((env['APPIMAGE'] ?? '').isNotEmpty || (env['APPDIR'] ?? '').isNotEmpty) {
    return true;
  }
  final exe = resolvedExecutable ?? Platform.resolvedExecutable;
  return exe.contains('/.mount_');
}

/// Checks `/proc/self/mountinfo` to detect whether the mount covering [dirPath] has the `noexec` option.
bool isMountNoExec(String dirPath, {String? mountInfoContent}) {
  try {
    final content = mountInfoContent ?? File('/proc/self/mountinfo').readAsStringSync();
    final canonical = FileSystemEntity.typeSync(dirPath) != FileSystemEntityType.notFound
        ? Directory(dirPath).resolveSymbolicLinksSync()
        : dirPath;
    String? bestMount;
    var bestNoExec = false;
    for (final line in content.split('\n')) {
      if (line.trim().isEmpty) continue;
      final fields = line.split(' ');
      if (fields.length < 6) continue;
      final mountPoint = fields[4].replaceAll(r'\040', ' ');
      final opts = fields[5].split(',');
      final matches = canonical == mountPoint ||
          (mountPoint == '/' && canonical.startsWith('/')) ||
          canonical.startsWith('$mountPoint/');
      if (matches && (bestMount == null || mountPoint.length > bestMount.length)) {
        bestMount = mountPoint;
        bestNoExec = opts.contains('noexec');
      }
    }
    return bestNoExec;
  } catch (_) {
    return false;
  }
}

/// Staged copy of `resources/daemon/*` inside `$XDG_RUNTIME_DIR` for AppImage -> `pkexec` elevation.
class StagedLinuxDaemon {
  const StagedLinuxDaemon({
    required this.daemonPath,
    required this.stagingDir,
  });

  final String daemonPath;
  final Directory stagingDir;

  Future<void> cleanup() async {
    try {
      if (stagingDir.existsSync()) {
        await stagingDir.delete(recursive: true);
      }
    } catch (_) {
      // Best-effort cleanup.
    }
  }
}

/// Parses relative file paths from `files.sha256` next to the daemon binary so every manifest entry
/// (including subdirectories) is staged before `pkexec` runs.
List<String> parseManifestRelativePaths(File manifestFile) {
  if (!manifestFile.existsSync()) return const [];
  final result = <String>[];
  for (final rawLine in manifestFile.readAsLinesSync()) {
    final line = rawLine.trimRight();
    if (line.length < 67) continue;
    var rel = line.substring(64).trimLeft();
    if (rel.startsWith('*')) rel = rel.substring(1);
    rel = rel.replaceAll('\\', '/');
    if (rel.isEmpty || rel.startsWith('/') || rel.contains('..')) continue;
    result.add(rel);
  }
  return result;
}

/// Stages `<daemonDir>` (`niko-daemon`, `files.sha256`, and every file listed in `files.sha256`)
/// into an atomic `mkdtemp` directory inside `$XDG_RUNTIME_DIR` (refusing world-shared `/tmp`
/// fallback and checking `noexec`) so `pkexec` (root) can execute it when running from AppImage.
Future<StagedLinuxDaemon> stageLinuxDaemonForPkexec(
  String bundledDaemonPath, {
  Map<String, String>? environment,
  String? mountInfoContent,
}) async {
  final env = environment ?? Platform.environment;
  final runtimeDir = env['XDG_RUNTIME_DIR'];
  if (runtimeDir == null || runtimeDir.isEmpty || !Directory(runtimeDir).existsSync()) {
    throw StateError('XDG_RUNTIME_DIR is unavailable; refusing unsafe /tmp staging for root elevation');
  }
  if (isMountNoExec(runtimeDir, mountInfoContent: mountInfoContent)) {
    throw StateError('XDG_RUNTIME_DIR ($runtimeDir) is mounted noexec; install manually with sudo');
  }

  // Atomic mkdtemp (0700) prevents pre-created directory / symlink races.
  final stagingDir = await Directory(runtimeDir).createTemp('niko-install-');
  if (Platform.isLinux) {
    final ch = await Process.run('chmod', ['0700', stagingDir.path]);
    if (ch.exitCode != 0) {
      await stagingDir.delete(recursive: true);
      throw StateError('chmod 0700 on staging dir failed: ${ch.stderr}');
    }
  }

  final srcDir = File(bundledDaemonPath).parent;
  final daemonName = File(bundledDaemonPath).uri.pathSegments.last;
  final manifestFile = File('${srcDir.path}/files.sha256');
  final toCopy = <String>{
    daemonName,
    if (manifestFile.existsSync()) 'files.sha256',
    ...parseManifestRelativePaths(manifestFile),
    if (!manifestFile.existsSync() && File('${srcDir.path}/libcronet.so').existsSync()) 'libcronet.so',
  };

  try {
    for (final rel in toCopy) {
      final src = File('${srcDir.path}/$rel');
      if (!src.existsSync()) continue;
      final dst = File('${stagingDir.path}/$rel');
      await dst.parent.create(recursive: true);
      await src.copy(dst.path);
      if (Platform.isLinux) {
        final mode = rel == daemonName ? '0755' : '0644';
        final ch = await Process.run('chmod', [mode, dst.path]);
        if (ch.exitCode != 0) {
          throw StateError('chmod $mode on ${dst.path} failed: ${ch.stderr}');
        }
      }
    }
  } catch (_) {
    await stagingDir.delete(recursive: true);
    rethrow;
  }

  return StagedLinuxDaemon(
    daemonPath: '${stagingDir.path}/$daemonName',
    stagingDir: stagingDir,
  );
}

/// Builds a copyable manual `sudo` install command for headless / no-polkit environments.
String buildLinuxManualInstallCommand(String bundledDaemonPath) =>
    'sudo ${shellQuotePosix(bundledDaemonPath)} service install';

/// Runs `pkexec <daemon> service install` (staging to `$XDG_RUNTIME_DIR` first when in AppImage)
/// and maps `pkexec` / `boxdd` exit codes into an [InstallResult].
Future<InstallResult> runLinuxPkexecInstall({
  required String bundledDaemonPath,
  Map<String, String>? environment,
  String? resolvedExecutable,
  ProcessRunner? runProcess,
  String? mountInfoContent,
}) async {
  StagedLinuxDaemon? staged;
  var daemonToRun = bundledDaemonPath;
  try {
    if (isAppImageEnvironment(environment: environment, resolvedExecutable: resolvedExecutable)) {
      staged = await stageLinuxDaemonForPkexec(
        bundledDaemonPath,
        environment: environment,
        mountInfoContent: mountInfoContent,
      );
      daemonToRun = staged.daemonPath;
    }
    final res = runProcess != null
        ? await runProcess('pkexec', [daemonToRun, 'service', 'install'])
        : await Process.run('pkexec', [daemonToRun, 'service', 'install']);
    return InstallResult.exit(res.exitCode);
  } on ProcessException {
    // pkexec binary itself is not installed -> treat identically to exit 127 (no polkit agent).
    return const InstallResult.exit(127);
  } finally {
    await staged?.cleanup();
  }
}
