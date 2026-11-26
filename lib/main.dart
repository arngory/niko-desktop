import 'dart:io';

import 'package:flutter/widgets.dart';

import 'app.dart';
import 'daemon/daemon.dart';
import 'daemon/endpoint.dart';
import 'daemon/locator.dart';
import 'daemon/worker_process.dart';
import 'platform/linux_service_install.dart';
import 'platform/places.dart';
import 'platform/service_install.dart';
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
///   with a mutual HMAC-SHA256 handshake; otherwise offers UAC service installation or opening the installed `niko.exe`.
/// - Linux: locates `/run/niko-daemon/niko-daemon.sock` (SO_PEERCRED); if the service is not installed yet and a
///   bundled `niko-daemon` binary is present, offers 1-click `pkexec` installation (with copyable `sudo` fallback).
Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  Daemon? daemon;
  ServiceController? serviceInstall;
  LinuxDaemonLocation? linuxLocation;
  var address = '';
  File? config;
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
    } else {
      serviceInstall = ServiceController(
        mode: detection.mode,
        installedWindowPath: detection.installedWindowPath,
        probeStatus: probe,
      );
    }
  } else if (Platform.isLinux) {
    linuxLocation = await locateLinuxDaemon();
    if (linuxLocation.socketPath case final sock?) {
      daemon = GrpcDaemon.unix(sock);
    }
  }

  final file = config;
  final controller = ConnectionController(
    daemon: daemon,
    // read at each press: the file may be edited between two starts
    loadConfig: file?.readAsString,
  )..attach();

  if (!_dev && Platform.isLinux && daemon == null && linuxLocation != null && linuxLocation.hasBundledDaemon) {
    final bundled = linuxLocation.bundledDaemonPath;
    serviceInstall = ServiceController(
      mode: InstallMode.notInstalled,
      installedWindowPath: Platform.resolvedExecutable,
      manualCommand: buildLinuxManualInstallCommand(bundled),
      runElevatedInstall: () => runLinuxPkexecInstall(bundledDaemonPath: bundled),
      onInstalledInPlace: () async {
        controller.attachDaemon(GrpcDaemon.unix(linuxSystemSocketPath));
      },
    );
  }
  // the view chosen last time, before the first frame: the window does not open in one view and turn to the other
  final settings = await WindowSettings.load(settingsFile());
  runApp(NikoApp(
    controller: controller,
    settings: settings,
    daemonAddress: address,
    configName: file == null ? '' : file.uri.pathSegments.last,
    serviceInstall: serviceInstall,
  ));
}
