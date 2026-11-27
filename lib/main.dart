import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/widgets.dart';
import 'package:grpc/grpc.dart' show GrpcError, StatusCode;

import 'app.dart';
import 'daemon/daemon.dart';
import 'daemon/endpoint.dart';
import 'daemon/locator.dart';
import 'daemon/user_mode_daemon.dart';
import 'daemon/worker_process.dart';
import 'platform/deep_link.dart';
import 'platform/linux_service_install.dart';
import 'platform/places.dart';
import 'platform/service_install.dart';
import 'platform/user_store_migration.dart';
import 'state/connection_controller.dart';
import 'state/window_settings.dart';

/// The development link is compiled in only when asked for: `--dart-define=NIKO_DEV=true`. A build without it has
/// no way to reach a daemon over TCP at all, whatever its arguments say; a release is built without it.
const _dev = bool.fromEnvironment('NIKO_DEV');

/// `niko --daemon 127.0.0.1:<port> --config <file.json>` (development builds): the daemon started as
/// `niko-daemon run --listen 127.0.0.1:<port>`, and the ready config the connect button starts.
///
/// Release builds (`NIKO_DEV` unset):
/// - Windows: detects whether the `niko-daemon` service is installed and whether this executable is running from
///   the installed Program Files location. When installed, launches the bundled `niko-daemon.exe worker` over AF_UNIX
///   with a mutual HMAC-SHA256 handshake (and offers one-time user-mode store migration if present). When the service
///   is not installed yet, launches an unprivileged `niko-daemon.exe worker --user-mode` so Proxy mode works out of
///   the box without UAC, while offering 1-click UAC service installation for VPN (TUN) mode.
/// - Linux: locates `/run/niko-daemon/niko-daemon.sock` (SO_PEERCRED). If no system service is running and a bundled
///   `niko-daemon` binary is present, starts an unprivileged `niko-daemon run --user-mode` for immediate Proxy mode
///   and offers 1-click `pkexec` installation (with copyable `sudo` fallback and automatic store migration).
Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  // grpc-dart 5.x Http2TransportStream can write to an already-closed http2 sink when a stream is
  // cancelled or reset mid-flight; swallow only that narrow transport-teardown StateError so it
  // does not surface as an unhandled exception in the root zone.
  final previousOnError = PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    if (error is StateError &&
        error.message == 'Cannot add event after closing' &&
        stack.toString().contains('_StreamSinkWrapper.add')) {
      return true;
    }
    return previousOnError?.call(error, stack) ?? false;
  };
  Daemon? daemon;
  ServiceController? serviceInstall;
  UserStoreMigrationController? userMigration;
  LinuxDaemonLocation? linuxLocation;
  LinuxUserModeDaemon? linuxUserMode;
  var address = '';
  File? config;
  String? migrationDaemonExe;
  String? migrationDataDir;

  // all of the development link stands in this branch: without NIKO_DEV the compiler drops it whole, and the gRPC
  // client over TCP with it
  if (_dev) {
    for (var i = 0; i + 1 < arguments.length; i++) {
      if (arguments[i] == '--daemon') {
        final endpoint = DevEndpoint.parse(arguments[i + 1]);
        if (endpoint == null) {
          stderr.writeln('--daemon takes 127.0.0.1:<port> and nothing else');
          exit(2);
        }
        daemon = GrpcDaemon.dev(endpoint);
        address = endpoint.toString();
      } else if (arguments[i] == '--config') {
        config = File(arguments[i + 1]);
      }
    }
  } else if (Platform.isWindows) {
    final daemonExe = WorkerProcess.defaultDaemonPath();
    Future<WindowsInstallDetection> probe() => detectWindowsInstallState(
          daemonExecutablePath: daemonExe,
          currentExecutablePath: Platform.resolvedExecutable,
        );
    final detection = await probe();
    if (detection.mode == InstallMode.installed) {
      daemon = GrpcDaemon.worker(WorkerProcess(daemonExecutablePath: daemonExe));
      migrationDaemonExe = daemonExe;
      migrationDataDir = defaultWindowsUserDataDir();
    } else if (detection.mode == InstallMode.notInstalled) {
      if (File(daemonExe).existsSync()) {
        daemon = GrpcDaemon.worker(
          WorkerProcess(
            daemonExecutablePath: daemonExe,
            userMode: true,
            workingDirectory: defaultWindowsUserDataDir(),
          ),
        );
      }
    }
    serviceInstall = ServiceController(
      mode: detection.mode,
      installedWindowPath: detection.installedWindowPath,
      probeStatus: probe,
    );
  } else if (Platform.isLinux) {
    linuxLocation = await locateLinuxDaemon();
    final active = linuxLocation.activeCandidate;
    if (active != null && active.kind == DaemonCandidateKind.systemService) {
      daemon = GrpcDaemon.unix(active.socketPath);
      if (linuxLocation.hasBundledDaemon) {
        migrationDaemonExe = linuxLocation.bundledDaemonPath;
      } else if (linuxLocation.serviceStatus.binary.isNotEmpty) {
        migrationDaemonExe = linuxLocation.serviceStatus.binary;
      }
      migrationDataDir = defaultLinuxUserDataDir();
      // Ensure no orphaned user-mode daemon keeps holding port 2080 or desktop proxy settings.
      unawaited(stopExistingUserModeDaemon(migrationDataDir));
    } else if (active != null && active.kind == DaemonCandidateKind.userMode) {
      daemon = GrpcDaemon.unix(active.socketPath);
    } else if (linuxLocation.hasBundledDaemon) {
      linuxUserMode = await LinuxUserModeDaemon.ensureRunning(
        daemonExecutablePath: linuxLocation.bundledDaemonPath,
      );
      if (linuxUserMode != null) {
        daemon = GrpcDaemon.unix(linuxUserMode.socketPath, onClose: linuxUserMode.stop);
      }
    }
  } else if (Platform.isMacOS) {
    final userSock = defaultMacosUserSocketPath();
    final bundled = defaultMacosBundledDaemonPath();
    if (userSock != null && await probeUnixSocketReachable(userSock)) {
      daemon = GrpcDaemon.unix(userSock);
    } else if (File(bundled).existsSync()) {
      final macosUserMode = await UnixUserModeDaemon.ensureRunning(
        daemonExecutablePath: bundled,
        socketPath: userSock,
        dataDir: defaultMacosUserDataDir(),
      );
      if (macosUserMode != null) {
        daemon = GrpcDaemon.unix(macosUserMode.socketPath, onClose: macosUserMode.stop);
      }
    }
  }

  final file = config;
  final controller = ConnectionController(
    daemon: daemon,
    // read at each press: the file may be edited between two starts
    loadConfig: file?.readAsString,
  )..attach();

  if (!_dev && migrationDaemonExe != null && migrationDataDir != null) {
    final exe = migrationDaemonExe;
    final dir = migrationDataDir;
    userMigration = UserStoreMigrationController(
      userDataDir: dir,
      exportUserSnapshot: () => UserStoreMigrationController.exportViaTemporaryUserDaemon(
        daemonExecutablePath: exe,
        userDataDir: dir,
      ),
      getServiceDaemon: () => controller.privileged ? controller.daemon : null,
    );
  }

  if (!_dev && Platform.isWindows && serviceInstall != null) {
    final daemonExe = WorkerProcess.defaultDaemonPath();
    final existing = serviceInstall;
    serviceInstall = ServiceController(
      mode: existing.mode,
      installedWindowPath: existing.installedWindowPath,
      probeStatus: existing.probeStatus,
      onUninstalledInPlace: () async {
        final oldDaemon = controller.daemon;
        if (oldDaemon != null) {
          try {
            await oldDaemon.stop().timeout(const Duration(seconds: 2));
          } catch (_) {}
        }
        if (File(daemonExe).existsSync()) {
          controller.attachDaemon(
            GrpcDaemon.worker(
              WorkerProcess(
                daemonExecutablePath: daemonExe,
                userMode: true,
                workingDirectory: defaultWindowsUserDataDir(),
              ),
            ),
          );
        } else {
          controller.attachDaemon(null);
        }
      },
    );
  }

  if (!_dev &&
      Platform.isLinux &&
      linuxLocation != null &&
      (linuxLocation.hasBundledDaemon ||
          linuxLocation.activeCandidate?.kind == DaemonCandidateKind.systemService)) {
    final isInstalled = linuxLocation.activeCandidate?.kind == DaemonCandidateKind.systemService;
    final bundled = linuxLocation.hasBundledDaemon ? linuxLocation.bundledDaemonPath : '';
    final installedBinary = linuxLocation.serviceStatus.binary;
    final uninstallDaemonPath = installedBinary.isNotEmpty && File(installedBinary).existsSync()
        ? installedBinary
        : (bundled.isNotEmpty ? bundled : '/usr/local/libexec/niko/niko-daemon');
    final userDataDir = defaultLinuxUserDataDir();
    if (bundled.isNotEmpty) {
      userMigration ??= userDataDir == null
          ? null
          : UserStoreMigrationController(
              userDataDir: userDataDir,
              exportUserSnapshot: () => UserStoreMigrationController.exportViaTemporaryUserDaemon(
                daemonExecutablePath: bundled,
                userDataDir: userDataDir,
              ),
              getServiceDaemon: () => controller.privileged ? controller.daemon : null,
            );
    }
    serviceInstall = ServiceController(
      mode: isInstalled ? InstallMode.installed : InstallMode.notInstalled,
      installedWindowPath: Platform.resolvedExecutable,
      manualCommand: bundled.isNotEmpty ? buildLinuxManualInstallCommand(bundled) : '',
      manualUninstallCommand: buildLinuxManualUninstallCommand(uninstallDaemonPath),
      runElevatedInstall: bundled.isNotEmpty
          ? () => runLinuxPkexecInstall(bundledDaemonPath: bundled)
          : () async => const InstallResult.exit(11),
      runElevatedUninstall: () => runLinuxPkexecUninstall(
        daemonPath: File(uninstallDaemonPath).existsSync()
            ? uninstallDaemonPath
            : (bundled.isNotEmpty ? bundled : uninstallDaemonPath),
      ),
      onInstalledInPlace: () async {
        // Export user-mode snapshot and stop any running user-mode proxy core before switching to service.
        List<int>? snapshot;
        final oldDaemon = controller.daemon;
        if (oldDaemon != null && controller.isUserMode) {
          try {
            snapshot = await oldDaemon.exportUserStore();
          } catch (_) {}
          try {
            await oldDaemon.stop();
          } catch (_) {}
        }
        await linuxUserMode?.stop();
        linuxUserMode = null;
        await stopExistingUserModeDaemon(userDataDir);

        final serviceDaemon = GrpcDaemon.unix(linuxSystemSocketPath);
        controller.attachDaemon(serviceDaemon);

        if (snapshot != null && snapshot.isNotEmpty && userDataDir != null) {
          try {
            // Wait briefly for the newly started system service to come online; retry only on UNAVAILABLE.
            for (var i = 0; i < 20; i++) {
              try {
                await serviceDaemon.importUserStore(snapshot);
                await markUserStoreMigrated(userDataDir);
                userMigration?.refresh();
                return;
              } on GrpcError catch (e) {
                if (e.code != StatusCode.unavailable) break;
                await Future<void>.delayed(const Duration(milliseconds: 250));
              } catch (_) {
                break;
              }
            }
          } finally {
            zeroBytes(snapshot);
          }
          userMigration?.refresh();
        }
      },
      onUninstalledInPlace: () async {
        final oldDaemon = controller.daemon;
        if (oldDaemon != null) {
          try {
            await oldDaemon.stop().timeout(const Duration(seconds: 2));
          } catch (_) {}
        }
        if (bundled.isNotEmpty && File(bundled).existsSync()) {
          linuxUserMode = await LinuxUserModeDaemon.ensureRunning(
            daemonExecutablePath: bundled,
          );
          if (linuxUserMode != null) {
            controller.attachDaemon(GrpcDaemon.unix(linuxUserMode!.socketPath, onClose: linuxUserMode!.stop));
            return;
          }
        }
        controller.attachDaemon(null);
      },
    );
  }

  // the view chosen last time, before the first frame: the window does not open in one view and turn to the other
  final settings = await WindowSettings.load(settingsFile());
  final initialImportLink = extractDeepLink(arguments);
  runApp(NikoApp(
    controller: controller,
    settings: settings,
    daemonAddress: address,
    configName: file == null ? '' : file.uri.pathSegments.last,
    serviceInstall: serviceInstall,
    userMigration: userMigration,
    initialImportLink: initialImportLink,
  ));
}
