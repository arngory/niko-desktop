import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// State reported by `niko-daemon.exe service status --format json`.
enum ServiceStatusKind { running, stopped, notInstalled, unknown }

/// Parsed output of `niko-daemon.exe service status --format json`.
class WindowsServiceStatus {
  const WindowsServiceStatus(this.kind, {this.binary = ''});

  final ServiceStatusKind kind;

  /// Windows SCM `BinaryPathName` (command line of the installed service), if available.
  final String binary;
}

/// Whether an install result code came from the elevated `niko-daemon.exe` exit status or from
/// `ShellExecuteExW` (`GetLastError()`), preventing Win32 errors 10..15 from colliding with
/// `boxdd` installer exit codes.
enum InstallResultKind { exit, shell }

/// Raw result returned by the `niko/window` `installService` method channel.
class InstallResult {
  const InstallResult({required this.kind, required this.code});
  const InstallResult.exit(this.code) : kind = InstallResultKind.exit;
  const InstallResult.shell(this.code) : kind = InstallResultKind.shell;

  final InstallResultKind kind;
  final int code;
}

/// Parses the `niko/window` `installService` channel response (`{"kind": "exit"|"shell", "code": int}`).
InstallResult parseInstallChannelResult(Object? raw) {
  if (raw is Map) {
    final kindStr = raw['kind'] as String? ?? 'exit';
    final code = raw['code'] as int? ?? 1;
    return InstallResult(
      kind: kindStr == 'shell' ? InstallResultKind.shell : InstallResultKind.exit,
      code: code,
    );
  }
  if (raw is int) {
    return InstallResult.exit(raw);
  }
  return const InstallResult.exit(1);
}

/// Structured outcome of elevated `niko-daemon` service install (matches boxdd `InstallExit*`,
/// Windows UAC 1223, and Linux `pkexec` 126/127).
enum InstallOutcome {
  ok,
  cancelled,
  polkitUnavailable,
  notElevated,
  invalidLayout,
  signatureFailed,
  manifestFailed,
  targetBusy,
  invalidSource,
  installedButLaunchFailed,
  failed,
}

/// Maps an exit code from `niko-daemon service install` / `pkexec` to [InstallOutcome].
InstallOutcome installOutcomeFromExitCode(int exitCode) => switch (exitCode) {
      0 => InstallOutcome.ok,
      126 => InstallOutcome.cancelled, // pkexec user dismissed auth dialog
      127 => InstallOutcome.polkitUnavailable, // pkexec missing or no polkit auth agent
      1223 => InstallOutcome.cancelled, // Windows UAC ERROR_CANCELLED
      10 => InstallOutcome.notElevated,
      11 => InstallOutcome.invalidLayout,
      12 => InstallOutcome.signatureFailed,
      13 => InstallOutcome.manifestFailed,
      14 => InstallOutcome.targetBusy,
      15 => InstallOutcome.invalidSource,
      _ => InstallOutcome.failed,
    };

/// Maps an [InstallResult] (distinguishing `ShellExecuteExW` Win32 errors from `niko-daemon.exe`
/// exit codes) to `(outcome, detail)`.
(InstallOutcome, String) classifyInstallResult(InstallResult result) {
  if (result.kind == InstallResultKind.shell) {
    if (result.code == 1223) return (InstallOutcome.cancelled, '');
    return (InstallOutcome.failed, 'Win32 error ${result.code}');
  }
  final outcome = installOutcomeFromExitCode(result.code);
  final detail = outcome == InstallOutcome.failed ? 'exit code ${result.code}' : '';
  return (outcome, detail);
}

/// How this Windows release window relates to the installed Niko service.
enum InstallMode {
  /// Running from the installed Program Files directory and the service exists.
  installed,

  /// Running from a portable folder while the service is already installed in Program Files.
  portableServiceReady,

  /// The service is not installed yet (UAC install required).
  notInstalled,
}

/// Result of inspecting the Windows service and current executable location at startup.
class WindowsInstallDetection {
  const WindowsInstallDetection({
    required this.mode,
    required this.installedWindowPath,
    required this.serviceStatus,
  });

  final InstallMode mode;
  final String installedWindowPath;
  final WindowsServiceStatus serviceStatus;
}

/// Parses the JSON output of `niko-daemon.exe service status --format json`.
WindowsServiceStatus parseServiceStatusJson(String stdout, int exitCode) {
  final trimmed = stdout.trim();
  if (trimmed.isNotEmpty) {
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, Object?>) {
        final state = decoded['state'] as String? ?? '';
        final binary = decoded['binary'] as String? ?? '';
        final kind = switch (state) {
          'running' => ServiceStatusKind.running,
          'stopped' => ServiceStatusKind.stopped,
          'not-installed' => ServiceStatusKind.notInstalled,
          _ => ServiceStatusKind.unknown,
        };
        if (kind != ServiceStatusKind.unknown || binary.isNotEmpty) {
          return WindowsServiceStatus(kind, binary: binary);
        }
      }
    } catch (_) {
      // Fall back to exit code below.
    }
  }
  return switch (exitCode) {
    0 => const WindowsServiceStatus(ServiceStatusKind.running),
    2 => const WindowsServiceStatus(ServiceStatusKind.stopped),
    3 => const WindowsServiceStatus(ServiceStatusKind.notInstalled),
    _ => const WindowsServiceStatus(ServiceStatusKind.unknown),
  };
}

/// Extracts the installed `niko.exe` path from SCM `BinaryPathName` (e.g.
/// `"C:\Program Files\Niko\resources\daemon\niko-daemon.exe" run --working-directory ...`).
/// Returns null if [binaryPathName] does not follow `<root>\resources\daemon\niko-daemon.exe`.
String? installedWindowFromServiceBinary(String binaryPathName) {
  final trimmed = binaryPathName.trim();
  if (trimmed.isEmpty) return null;
  String exePath;
  if (trimmed.startsWith('"')) {
    final endQuote = trimmed.indexOf('"', 1);
    if (endQuote <= 1) return null;
    exePath = trimmed.substring(1, endQuote);
  } else {
    final space = trimmed.indexOf(' ');
    exePath = space < 0 ? trimmed : trimmed.substring(0, space);
  }
  final normalized = exePath.replaceAll('/', '\\');
  const suffix = r'\resources\daemon\niko-daemon.exe';
  if (!normalized.toLowerCase().endsWith(suffix)) return null;
  final root = normalized.substring(0, normalized.length - suffix.length);
  if (root.isEmpty) return null;
  return '$root\\niko.exe';
}

/// Canonicalizes a Windows file path for equality checks (resolving symlinks/8.3 names when
/// present on disk, stripping `\\?\` prefixes, normalizing slashes, and lowercasing).
String normalizeWindowsPathForCompare(String path) {
  var candidate = path;
  try {
    final file = File(path);
    if (file.existsSync()) {
      candidate = file.resolveSymbolicLinksSync();
    }
  } catch (_) {
    // Keep raw path when running in tests or when the target file is not on disk.
  }
  var normalized = candidate.replaceAll('/', '\\');
  if (normalized.startsWith(r'\\?\UNC\')) {
    normalized = r'\\' + normalized.substring(r'\\?\UNC\'.length);
  } else if (normalized.startsWith(r'\\?\')) {
    normalized = normalized.substring(r'\\?\'.length);
  }
  return normalized.toLowerCase();
}

typedef ProcessRunner = Future<ProcessResult> Function(String executable, List<String> arguments);

Future<ProcessResult> _runWithTimeout(
  String executable,
  List<String> arguments, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final proc = await Process.start(executable, arguments);
  final stdoutFuture = proc.stdout.transform(utf8.decoder).join();
  final stderrFuture = proc.stderr.transform(utf8.decoder).join();
  try {
    final code = await proc.exitCode.timeout(timeout);
    return ProcessResult(proc.pid, code, await stdoutFuture, await stderrFuture);
  } on TimeoutException {
    proc.kill();
    unawaited(stdoutFuture.catchError((Object _) => ''));
    unawaited(stderrFuture.catchError((Object _) => ''));
    rethrow;
  }
}

/// Probes the local `niko-daemon.exe` service status without elevation and classifies [InstallMode].
Future<WindowsInstallDetection> detectWindowsInstallState({
  required String daemonExecutablePath,
  required String currentExecutablePath,
  Map<String, String>? environment,
  ProcessRunner? runProcess,
  Duration timeout = const Duration(seconds: 5),
}) async {
  final env = environment ?? Platform.environment;
  final programFiles = env['ProgramFiles'] ?? r'C:\Program Files';
  final fallbackWindow = '$programFiles\\Niko\\niko.exe';

  WindowsServiceStatus status = const WindowsServiceStatus(ServiceStatusKind.notInstalled);
  try {
    final res = runProcess != null
        ? await runProcess(daemonExecutablePath, const ['service', 'status', '--format', 'json']).timeout(timeout)
        : await _runWithTimeout(daemonExecutablePath, const ['service', 'status', '--format', 'json'], timeout: timeout);
    status = parseServiceStatusJson(res.stdout as String? ?? '', res.exitCode);
  } catch (_) {
    status = const WindowsServiceStatus(ServiceStatusKind.notInstalled);
  }

  final installedWindow = installedWindowFromServiceBinary(status.binary) ?? fallbackWindow;
  final serviceExists = status.kind == ServiceStatusKind.running ||
      status.kind == ServiceStatusKind.stopped ||
      (status.kind == ServiceStatusKind.unknown && status.binary.isNotEmpty);
  if (!serviceExists) {
    return WindowsInstallDetection(
      mode: InstallMode.notInstalled,
      installedWindowPath: installedWindow,
      serviceStatus: status,
    );
  }

  final runningInstalled =
      normalizeWindowsPathForCompare(currentExecutablePath) == normalizeWindowsPathForCompare(installedWindow);
  return WindowsInstallDetection(
    mode: runningInstalled ? InstallMode.installed : InstallMode.portableServiceReady,
    installedWindowPath: installedWindow,
    serviceStatus: status,
  );
}

const _windowChannel = MethodChannel('niko/window');

/// Controls elevated service installation and uninstallation (Windows UAC, or Linux `pkexec` + hot-attach).
class ServiceController extends ChangeNotifier {
  ServiceController({
    required this.mode,
    required this.installedWindowPath,
    this.manualCommand = '',
    this.manualUninstallCommand = '',
    this.onInstalledInPlace,
    this.onUninstalledInPlace,
    Future<InstallResult> Function()? runElevatedInstall,
    Future<InstallResult> Function()? runElevatedUninstall,
    this.probeStatus,
    Future<void> Function(String windowPath)? launchInstalled,
    Future<void> Function()? exitApp,
  })  : _runElevatedInstall = runElevatedInstall ?? _defaultRunElevatedInstall,
        _runElevatedUninstall = runElevatedUninstall ?? _defaultRunElevatedUninstall,
        _launchInstalled = launchInstalled ?? _defaultLaunchInstalled,
        _exitApp = exitApp ?? _defaultExitApp;

  InstallMode mode;
  String installedWindowPath;

  /// Copyable manual command (e.g. `sudo /path/to/niko-daemon service install` on Linux when polkit is unavailable).
  final String manualCommand;

  /// Copyable manual uninstall command (e.g. `sudo /usr/local/libexec/niko/niko-daemon service uninstall`).
  final String manualUninstallCommand;

  /// When set (Linux), called on successful install to attach the running window directly to the
  /// newly started service without relaunching the window.
  final Future<void> Function()? onInstalledInPlace;

  /// Called on successful uninstall to detach the system service and fall back to user-mode proxy.
  final Future<void> Function()? onUninstalledInPlace;
  final Future<InstallResult> Function() _runElevatedInstall;
  final Future<InstallResult> Function() _runElevatedUninstall;
  final Future<WindowsInstallDetection> Function()? probeStatus;
  final Future<void> Function(String windowPath) _launchInstalled;
  final Future<void> Function() _exitApp;

  bool installing = false;
  bool uninstalling = false;
  bool lastActionWasUninstall = false;
  InstallOutcome? lastOutcome;
  String lastError = '';

  bool get busy => installing || uninstalling;

  static Future<InstallResult> _defaultRunElevatedInstall() async {
    final raw = await _windowChannel.invokeMethod<Object?>('installService');
    return parseInstallChannelResult(raw);
  }

  static Future<InstallResult> _defaultRunElevatedUninstall() async {
    final raw = await _windowChannel.invokeMethod<Object?>('uninstallService');
    return parseInstallChannelResult(raw);
  }

  static Future<void> _defaultLaunchInstalled(String windowPath) async {
    await Process.start(
      windowPath,
      ['--after-install=$pid'],
      workingDirectory: File(windowPath).parent.path,
      mode: ProcessStartMode.detached,
    );
  }

  static Future<void> _defaultExitApp() async {
    try {
      await _windowChannel.invokeMethod<void>('closeWindow');
      return;
    } catch (_) {
      exit(0);
    }
  }

  /// Triggers elevated `niko-daemon service install`:
  /// - On Linux (`onInstalledInPlace` set): attaches this window directly to the running service.
  /// - On Windows: re-probes SCM, launches installed `niko.exe --after-install=<pid>`, and exits.
  Future<void> installService() async {
    if (busy) return;
    installing = true;
    lastActionWasUninstall = false;
    lastOutcome = null;
    lastError = '';
    notifyListeners();
    try {
      final result = await _runElevatedInstall();
      final (outcome, detail) = classifyInstallResult(result);
      lastOutcome = outcome;
      lastError = detail;
      if (outcome == InstallOutcome.ok) {
        if (onInstalledInPlace case final onInstalled?) {
          mode = InstallMode.installed;
          await onInstalled();
          return;
        }
        if (probeStatus case final probe?) {
          try {
            final updated = await probe();
            installedWindowPath = updated.installedWindowPath;
          } catch (_) {
            // Keep existing installedWindowPath fallback.
          }
        }
        mode = InstallMode.portableServiceReady;
        try {
          await _launchInstalled(installedWindowPath);
        } catch (error) {
          lastOutcome = InstallOutcome.installedButLaunchFailed;
          lastError = error.toString();
          return;
        }
        await _exitApp();
        return;
      }
    } catch (error) {
      lastOutcome = InstallOutcome.failed;
      lastError = error.toString();
    } finally {
      installing = false;
      notifyListeners();
    }
  }

  /// Triggers elevated `niko-daemon service uninstall` (pkexec on Linux, UAC on Windows) and
  /// switches the window back to unprivileged user-mode proxy when [onUninstalledInPlace] is set.
  Future<void> uninstallService() async {
    if (busy) return;
    uninstalling = true;
    lastActionWasUninstall = true;
    lastOutcome = null;
    lastError = '';
    notifyListeners();
    try {
      final result = await _runElevatedUninstall();
      final (outcome, detail) = classifyInstallResult(result);
      lastOutcome = outcome;
      lastError = detail;
      if (outcome == InstallOutcome.ok) {
        mode = InstallMode.notInstalled;
        if (onUninstalledInPlace case final onUninstalled?) {
          await onUninstalled();
        }
      }
    } catch (error) {
      lastOutcome = InstallOutcome.failed;
      lastError = error.toString();
    } finally {
      uninstalling = false;
      notifyListeners();
    }
  }

  /// Opens the already-installed `niko.exe` and exits this portable copy.
  Future<void> openInstalled() async {
    if (busy) return;
    lastOutcome = null;
    lastError = '';
    try {
      await _launchInstalled(installedWindowPath);
      await _exitApp();
    } catch (error) {
      lastOutcome = InstallOutcome.installedButLaunchFailed;
      lastError = error.toString();
      notifyListeners();
    }
  }
}
