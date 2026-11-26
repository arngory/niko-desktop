import 'dart:async';
import 'dart:io';

import '../platform/service_install.dart';

/// Canonical system service Unix socket on Linux (RuntimeDirectory=niko-daemon, mode 0755).
const linuxSystemSocketPath = '/run/niko-daemon/niko-daemon.sock';

/// Legacy Linux socket path under StateDirectory (kept as a fallback probe for older installs).
const linuxLegacySocketPath = '/var/lib/niko-daemon/niko-daemon.sock';

/// Kind of daemon endpoint candidate discovered by the locator.
/// Designed to accommodate user-mode daemon candidates in Phase P4 alongside system service.
enum DaemonCandidateKind { systemService, userMode }

/// A single candidate endpoint inspected during startup daemon discovery.
class DaemonCandidate {
  const DaemonCandidate({
    required this.kind,
    required this.socketPath,
    required this.reachable,
  });

  final DaemonCandidateKind kind;
  final String socketPath;
  final bool reachable;
}

/// Result of locating the Linux daemon at startup.
class LinuxDaemonLocation {
  const LinuxDaemonLocation({
    required this.candidates,
    required this.activeCandidate,
    required this.serviceStatus,
    required this.bundledDaemonPath,
    required this.hasBundledDaemon,
  });

  final List<DaemonCandidate> candidates;
  final DaemonCandidate? activeCandidate;
  final WindowsServiceStatus serviceStatus;
  final String bundledDaemonPath;
  final bool hasBundledDaemon;

  String? get socketPath => activeCandidate?.socketPath;
  bool get serviceInstalled =>
      serviceStatus.kind == ServiceStatusKind.running || serviceStatus.kind == ServiceStatusKind.stopped;
}

/// Resolves `<exeDir>/resources/daemon/niko-daemon` beside the running Linux window executable.
String defaultLinuxBundledDaemonPath({String? resolvedExecutable}) {
  final exeDir = File(resolvedExecutable ?? Platform.resolvedExecutable).parent.path;
  return '$exeDir/resources/daemon/niko-daemon';
}

/// Performs a live non-blocking connect probe to a Unix domain socket path.
Future<bool> probeUnixSocketReachable(
  String socketPath, {
  Duration timeout = const Duration(milliseconds: 500),
}) async {
  try {
    final socket = await Socket.connect(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
      timeout: timeout,
    );
    socket.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

/// Locates an active Linux daemon using an ordered candidate list and service status probe.
Future<LinuxDaemonLocation> locateLinuxDaemon({
  String? bundledDaemonPath,
  List<String>? systemSocketPaths,
  ProcessRunner? runProcess,
  Future<bool> Function(String socketPath)? probeSocket,
  bool Function(String path)? fileExists,
  Duration timeout = const Duration(seconds: 5),
}) async {
  final daemonPath = bundledDaemonPath ?? defaultLinuxBundledDaemonPath();
  final existsFn = fileExists ?? ((p) => File(p).existsSync());
  final hasBundled = existsFn(daemonPath);
  final probeFn = probeSocket ?? probeUnixSocketReachable;
  final sockets = systemSocketPaths ?? const [linuxSystemSocketPath, linuxLegacySocketPath];

  final candidates = <DaemonCandidate>[];
  DaemonCandidate? active;
  for (final sock in sockets) {
    final reachable = await probeFn(sock);
    final candidate = DaemonCandidate(
      kind: DaemonCandidateKind.systemService,
      socketPath: sock,
      reachable: reachable,
    );
    candidates.add(candidate);
    active ??= reachable ? candidate : null;
  }

  var status = const WindowsServiceStatus(ServiceStatusKind.notInstalled);
  if (hasBundled) {
    try {
      final res = runProcess != null
          ? await runProcess(daemonPath, const ['service', 'status', '--format', 'json']).timeout(timeout)
          : await Process.run(daemonPath, const ['service', 'status', '--format', 'json']).timeout(timeout);
      status = parseServiceStatusJson(res.stdout as String? ?? '', res.exitCode);
    } catch (_) {
      status = const WindowsServiceStatus(ServiceStatusKind.unknown);
    }
  } else {
    // Fallback to systemctl show when running without a bundled daemon (e.g. distro package).
    try {
      final res = runProcess != null
          ? await runProcess('systemctl', const ['show', '--property=LoadState,ActiveState', '--value', 'niko-daemon.service']).timeout(timeout)
          : await Process.run('systemctl', const ['show', '--property=LoadState,ActiveState', '--value', 'niko-daemon.service']).timeout(timeout);
      final lines = (res.stdout as String? ?? '').trim().split('\n').map((l) => l.trim()).toList();
      final loadState = lines.isNotEmpty ? lines[0] : '';
      final activeState = lines.length > 1 ? lines[1] : '';
      if (loadState == 'not-found' || loadState.isEmpty) {
        status = const WindowsServiceStatus(ServiceStatusKind.notInstalled);
      } else if (activeState == 'active') {
        status = const WindowsServiceStatus(ServiceStatusKind.running);
      } else {
        status = const WindowsServiceStatus(ServiceStatusKind.stopped);
      }
    } catch (_) {
      status = const WindowsServiceStatus(ServiceStatusKind.notInstalled);
    }
  }

  // If the systemd unit is running and we didn't get a live socket yet, still allow connecting to the
  // canonical socket so ConnectionController's retry loop picks it up as soon as startup finishes.
  if (active == null && status.kind == ServiceStatusKind.running) {
    active = DaemonCandidate(
      kind: DaemonCandidateKind.systemService,
      socketPath: sockets.first,
      reachable: false,
    );
  }

  return LinuxDaemonLocation(
    candidates: candidates,
    activeCandidate: active,
    serviceStatus: status,
    bundledDaemonPath: daemonPath,
    hasBundledDaemon: hasBundled,
  );
}
