import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:niko_desktop/app.dart';
import 'package:niko_desktop/daemon/locator.dart';
import 'package:niko_desktop/platform/linux_service_install.dart';
import 'package:niko_desktop/platform/service_install.dart';
import 'package:niko_desktop/state/connection_controller.dart';

void main() {
  group('Linux daemon locator', () {
    test('prefers canonical /run socket when reachable', () async {
      final loc = await locateLinuxDaemon(
        bundledDaemonPath: '/opt/niko/resources/daemon/niko-daemon',
        fileExists: (_) => true,
        probeSocket: (path) async => path == linuxSystemSocketPath,
        runProcess: (exe, args) async => ProcessResult(1, 0, '{"state":"running","binary":"/usr/local/libexec/niko/niko-daemon"}', ''),
      );
      expect(loc.socketPath, linuxSystemSocketPath);
      expect(loc.serviceInstalled, isTrue);
      expect(loc.candidates.length, 2);
      expect(loc.candidates.first.reachable, isTrue);
    });

    test('falls back to legacy socket if canonical /run socket is not reachable', () async {
      final loc = await locateLinuxDaemon(
        bundledDaemonPath: '/opt/niko/resources/daemon/niko-daemon',
        fileExists: (_) => true,
        probeSocket: (path) async => path == linuxLegacySocketPath,
        runProcess: (exe, args) async => ProcessResult(1, 0, '{"state":"running"}', ''),
      );
      expect(loc.socketPath, linuxLegacySocketPath);
    });

    test('returns null socket and notInstalled when service is absent', () async {
      final loc = await locateLinuxDaemon(
        bundledDaemonPath: '/tmp/niko/resources/daemon/niko-daemon',
        fileExists: (_) => true,
        probeSocket: (_) async => false,
        runProcess: (exe, args) async => ProcessResult(1, 3, '{"state":"not-installed"}', ''),
      );
      expect(loc.socketPath, isNull);
      expect(loc.serviceInstalled, isFalse);
      expect(loc.hasBundledDaemon, isTrue);
    });
  });

  group('Linux pkexec 1-click install and AppImage staging', () {
    test('detects AppImage environment and stages daemon files into XDG_RUNTIME_DIR then cleans up', () async {
      final tmp = await Directory.systemTemp.createTemp('niko-appimage-test-');
      final runtimeDir = await Directory.systemTemp.createTemp('niko-runtime-test-');
      addTearDown(() async {
        await tmp.delete(recursive: true);
        if (runtimeDir.existsSync()) await runtimeDir.delete(recursive: true);
      });

      final daemonDir = Directory('${tmp.path}/resources/daemon')..createSync(recursive: true);
      final daemonFile = File('${daemonDir.path}/niko-daemon')..writeAsStringSync('bin');
      File('${daemonDir.path}/libcronet.so').writeAsStringSync('so');
      File('${daemonDir.path}/extra/helper.dat')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('extra');
      final fakeHash = 'a' * 64;
      File('${daemonDir.path}/files.sha256').writeAsStringSync('$fakeHash  libcronet.so\n$fakeHash  extra/helper.dat\n');

      String? capturedExe;
      List<String>? capturedArgs;
      var stagedExistedDuringRun = false;
      String? stagedDirPath;

      final result = await runLinuxPkexecInstall(
        bundledDaemonPath: daemonFile.path,
        environment: {
          'APPIMAGE': '/home/user/Niko.AppImage',
          'XDG_RUNTIME_DIR': runtimeDir.path,
        },
        mountInfoContent: '1 0 0:1 / / rw,relatime - tmpfs tmpfs rw\n',
        runProcess: (exe, args) async {
          capturedExe = exe;
          capturedArgs = args;
          final stagedBin = File(args.first);
          stagedDirPath = stagedBin.parent.path;
          stagedExistedDuringRun = stagedBin.existsSync() &&
              File('${stagedBin.parent.path}/libcronet.so').existsSync() &&
              File('${stagedBin.parent.path}/extra/helper.dat').existsSync() &&
              File('${stagedBin.parent.path}/files.sha256').existsSync();
          return ProcessResult(1, 0, '', '');
        },
      );

      expect(result.code, 0);
      expect(capturedExe, 'pkexec');
      expect(capturedArgs?.sublist(1), ['service', 'install']);
      expect(stagedDirPath, startsWith(runtimeDir.path));
      expect(stagedExistedDuringRun, isTrue);
      // Staging dir must be cleaned up after pkexec finishes.
      expect(Directory(stagedDirPath!).existsSync(), isFalse);
    });

    test('refuses AppImage staging when XDG_RUNTIME_DIR is missing or mounted noexec', () async {
      final runtimeDir = await Directory.systemTemp.createTemp('niko-noexec-test-');
      addTearDown(() => runtimeDir.delete(recursive: true));

      await expectLater(
        stageLinuxDaemonForPkexec('/tmp/niko-daemon', environment: const {}),
        throwsStateError,
      );
      final noExecMountInfo = '22 1 0:20 / ${runtimeDir.resolveSymbolicLinksSync()} rw,nosuid,nodev,noexec - tmpfs tmpfs rw\n';
      expect(isMountNoExec(runtimeDir.path, mountInfoContent: noExecMountInfo), isTrue);
      await expectLater(
        stageLinuxDaemonForPkexec(
          '/tmp/niko-daemon',
          environment: {'XDG_RUNTIME_DIR': runtimeDir.path},
          mountInfoContent: noExecMountInfo,
        ),
        throwsStateError,
      );
    });

    test('maps pkexec exit 126 (cancel) and 127 (no polkit agent) accurately', () {
      expect(installOutcomeFromExitCode(126), InstallOutcome.cancelled);
      expect(installOutcomeFromExitCode(127), InstallOutcome.polkitUnavailable);
      expect(installOutcomeFromExitCode(13), InstallOutcome.manifestFailed);
    });

    test('shellQuotePosix safely quotes spaces and single quotes in sudo command', () {
      expect(
        buildLinuxManualInstallCommand('/opt/niko/niko-daemon'),
        'sudo /opt/niko/niko-daemon service install',
      );
      expect(
        buildLinuxManualInstallCommand("/home/user/my app/it's/niko-daemon"),
        "sudo '/home/user/my app/it'\\''s/niko-daemon' service install",
      );
    });

    testWidgets('Linux ServiceController hot-attaches on exit 0 and shows copyable sudo command on exit 127',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      var attached = false;
      var nextExit = 127;
      final serviceInstall = ServiceController(
        mode: InstallMode.notInstalled,
        installedWindowPath: '/tmp/niko/niko',
        manualCommand: 'sudo /tmp/niko/resources/daemon/niko-daemon service install',
        runElevatedInstall: () async => InstallResult.exit(nextExit),
        onInstalledInPlace: () async {
          attached = true;
        },
      );
      final controller = ConnectionController(daemon: null, loadConfig: null);

      await tester.pumpWidget(NikoApp(
        controller: controller,
        locale: const Locale('en'),
        brightness: Brightness.dark,
        serviceInstall: serviceInstall,
      ));
      await tester.pumpAndSettle();

      // Click "Install service" -> pkexec exit 127 shows manual sudo fallback + Copy command button
      await tester.tap(find.text('Install service'));
      await tester.pumpAndSettle();

      expect(serviceInstall.lastOutcome, InstallOutcome.polkitUnavailable);
      expect(find.text('Copy command'), findsOneWidget);
      expect(find.textContaining('sudo /tmp/niko/resources/daemon/niko-daemon service install'), findsOneWidget);

      // Retry with exit 0 -> hot-attaches in place without exiting window
      nextExit = 0;
      await tester.tap(find.text('Install service'));
      await tester.pumpAndSettle();

      expect(serviceInstall.lastOutcome, InstallOutcome.ok);
      expect(attached, isTrue);
    });
  });
}
