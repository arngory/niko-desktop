import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:niko_desktop/app.dart';
import 'package:niko_desktop/platform/service_install.dart';
import 'package:niko_desktop/state/connection_controller.dart';

void main() {
  test('parseServiceStatusJson and installedWindowFromServiceBinary', () {
    final running = parseServiceStatusJson(
      r'{"state":"running","binary":"\"C:\\Program Files\\Niko\\resources\\daemon\\niko-daemon.exe\" run --working-directory C:\\ProgramData\\Niko"}',
      0,
    );
    expect(running.kind, ServiceStatusKind.running);
    expect(installedWindowFromServiceBinary(running.binary), r'C:\Program Files\Niko\niko.exe');

    final stopped = parseServiceStatusJson('{"state":"stopped"}', 2);
    expect(stopped.kind, ServiceStatusKind.stopped);

    final pending = parseServiceStatusJson(
      r'{"state":"start-pending","binary":"\"C:\\Program Files\\Niko\\resources\\daemon\\niko-daemon.exe\" run"}',
      1,
    );
    expect(pending.kind, ServiceStatusKind.unknown);
    expect(installedWindowFromServiceBinary(pending.binary), r'C:\Program Files\Niko\niko.exe');

    final missing = parseServiceStatusJson('not json', 3);
    expect(missing.kind, ServiceStatusKind.notInstalled);

    expect(installedWindowFromServiceBinary(r'C:\Custom\resources\daemon\niko-daemon.exe run'), r'C:\Custom\niko.exe');
    expect(installedWindowFromServiceBinary(r'C:\Wrong\bin\other.exe'), isNull);

    expect(
      normalizeWindowsPathForCompare(r'\\?\C:\Program Files\Niko\niko.exe'),
      normalizeWindowsPathForCompare('c:/program files/niko/niko.exe'),
    );
  });

  test('detectWindowsInstallState distinguishes installed, portable, pending/unknown-with-binary, and not-installed', () async {
    Future<ProcessResult> fakeStatus(String stdout, int code) async => ProcessResult(1, code, stdout, '');

    final installed = await detectWindowsInstallState(
      daemonExecutablePath: r'C:\Program Files\Niko\resources\daemon\niko-daemon.exe',
      currentExecutablePath: r'C:\Program Files\Niko\niko.exe',
      runProcess: (_, _) => fakeStatus(
        r'{"state":"running","binary":"\"C:\\Program Files\\Niko\\resources\\daemon\\niko-daemon.exe\" run"}',
        0,
      ),
    );
    expect(installed.mode, InstallMode.installed);

    final portable = await detectWindowsInstallState(
      daemonExecutablePath: r'C:\Users\Alice\Downloads\Niko\resources\daemon\niko-daemon.exe',
      currentExecutablePath: r'C:\Users\Alice\Downloads\Niko\niko.exe',
      runProcess: (_, _) => fakeStatus(
        r'{"state":"running","binary":"\"C:\\Program Files\\Niko\\resources\\daemon\\niko-daemon.exe\" run"}',
        0,
      ),
    );
    expect(portable.mode, InstallMode.portableServiceReady);
    expect(portable.installedWindowPath, r'C:\Program Files\Niko\niko.exe');

    final unknownWithBinary = await detectWindowsInstallState(
      daemonExecutablePath: r'C:\Program Files\Niko\resources\daemon\niko-daemon.exe',
      currentExecutablePath: r'C:\Program Files\Niko\niko.exe',
      runProcess: (_, _) => fakeStatus(
        r'{"state":"start-pending","binary":"\"C:\\Program Files\\Niko\\resources\\daemon\\niko-daemon.exe\" run"}',
        1,
      ),
    );
    expect(unknownWithBinary.mode, InstallMode.installed);

    final notInstalled = await detectWindowsInstallState(
      daemonExecutablePath: r'C:\Users\Alice\Downloads\Niko\resources\daemon\niko-daemon.exe',
      currentExecutablePath: r'C:\Users\Alice\Downloads\Niko\niko.exe',
      runProcess: (_, _) => fakeStatus('{"state":"not-installed"}', 3),
    );
    expect(notInstalled.mode, InstallMode.notInstalled);
  });

  test('classifyInstallResult separates ShellExecuteExW Win32 errors from boxdd exit codes', () {
    expect(installOutcomeFromExitCode(0), InstallOutcome.ok);
    expect(installOutcomeFromExitCode(1223), InstallOutcome.cancelled);
    expect(installOutcomeFromExitCode(10), InstallOutcome.notElevated);
    expect(installOutcomeFromExitCode(11), InstallOutcome.invalidLayout);
    expect(installOutcomeFromExitCode(12), InstallOutcome.signatureFailed);
    expect(installOutcomeFromExitCode(13), InstallOutcome.manifestFailed);
    expect(installOutcomeFromExitCode(14), InstallOutcome.targetBusy);
    expect(installOutcomeFromExitCode(15), InstallOutcome.invalidSource);
    expect(installOutcomeFromExitCode(99), InstallOutcome.failed);

    // Win32 ERROR_BAD_FORMAT (11) from ShellExecuteExW must NOT be misclassified as invalidLayout (exit 11).
    final (shellErrOutcome, shellErrDetail) = classifyInstallResult(const InstallResult.shell(11));
    expect(shellErrOutcome, InstallOutcome.failed);
    expect(shellErrDetail, 'Win32 error 11');

    final (uacCancel, _) = classifyInstallResult(const InstallResult.shell(1223));
    expect(uacCancel, InstallOutcome.cancelled);

    final (unmappedExit, exitDetail) = classifyInstallResult(const InstallResult.exit(42));
    expect(unmappedExit, InstallOutcome.failed);
    expect(exitDetail, 'exit code 42');

    final parsedMap = parseInstallChannelResult({'kind': 'shell', 'code': 1223});
    expect(parsedMap.kind, InstallResultKind.shell);
    expect(parsedMap.code, 1223);
  });

  testWidgets('MainScreen renders UAC install action, handles cancel/errors, re-probes, and launches on success', (tester) async {
    var nextResult = const InstallResult.shell(1223);
    String? launchedPath;
    var exited = false;
    final service = ServiceController(
      mode: InstallMode.notInstalled,
      installedWindowPath: r'C:\Program Files\Niko\niko.exe',
      runElevatedInstall: () async => nextResult,
      probeStatus: () async => const WindowsInstallDetection(
        mode: InstallMode.portableServiceReady,
        installedWindowPath: r'D:\Program Files\Niko\niko.exe',
        serviceStatus: WindowsServiceStatus(ServiceStatusKind.running),
      ),
      launchInstalled: (path) async => launchedPath = path,
      exitApp: () async => exited = true,
    );
    final controller = ConnectionController(daemon: null, loadConfig: null);

    await tester.pumpWidget(
      NikoApp(
        controller: controller,
        serviceInstall: service,
        locale: const Locale('ru'),
        brightness: Brightness.light,
      ),
    );
    await tester.pump();

    expect(find.text('Служба не установлена'), findsOneWidget);
    expect(find.text('Установить службу'), findsOneWidget);

    // 1. UAC cancelled (shell 1223).
    await tester.ensureVisible(find.text('Установить службу'));
    await tester.tap(find.text('Установить службу'));
    await tester.pumpAndSettle();
    expect(find.text('Установка отменена пользователем'), findsOneWidget);
    expect(exited, isFalse);

    // 2. Manifest tampered (exit 13).
    nextResult = const InstallResult.exit(13);
    await tester.tap(find.text('Установить службу'));
    await tester.pumpAndSettle();
    expect(find.text('Целостность файлов установки нарушена'), findsOneWidget);

    // 3. Target busy (exit 14).
    nextResult = const InstallResult.exit(14);
    await tester.tap(find.text('Установить службу'));
    await tester.pumpAndSettle();
    expect(find.text('Закройте работающий Niko и повторите установку'), findsOneWidget);

    // 4. Success (exit 0) re-probes SCM binary path, launches installed niko.exe, and exits portable window.
    nextResult = const InstallResult.exit(0);
    await tester.tap(find.text('Установить службу'));
    await tester.pumpAndSettle();
    expect(launchedPath, r'D:\Program Files\Niko\niko.exe');
    expect(exited, isTrue);
  });

  testWidgets('MainScreen switches to portableServiceReady if post-install launch fails', (tester) async {
    var exited = false;
    final service = ServiceController(
      mode: InstallMode.notInstalled,
      installedWindowPath: r'C:\Program Files\Niko\niko.exe',
      runElevatedInstall: () async => const InstallResult.exit(0),
      launchInstalled: (_) async => throw const FileSystemException('blocked'),
      exitApp: () async => exited = true,
    );
    final controller = ConnectionController(daemon: null, loadConfig: null);

    await tester.pumpWidget(
      NikoApp(
        controller: controller,
        serviceInstall: service,
        locale: const Locale('ru'),
        brightness: Brightness.light,
      ),
    );
    await tester.pump();

    await tester.ensureVisible(find.text('Установить службу'));
    await tester.tap(find.text('Установить службу'));
    await tester.pumpAndSettle();

    expect(exited, isFalse);
    expect(service.mode, InstallMode.portableServiceReady);
    expect(service.lastOutcome, InstallOutcome.installedButLaunchFailed);
    expect(find.text('Служба Niko уже установлена'), findsOneWidget);
    expect(find.textContaining('Служба установлена, но не удалось открыть установленный Niko'), findsOneWidget);
  });

  testWidgets('MainScreen renders portable-already-installed banner with open and update actions', (tester) async {
    String? openedPath;
    var exited = false;
    final service = ServiceController(
      mode: InstallMode.portableServiceReady,
      installedWindowPath: r'C:\Program Files\Niko\niko.exe',
      runElevatedInstall: () async => const InstallResult.exit(0),
      launchInstalled: (path) async => openedPath = path,
      exitApp: () async => exited = true,
    );
    final controller = ConnectionController(daemon: null, loadConfig: null);

    await tester.pumpWidget(
      NikoApp(
        controller: controller,
        serviceInstall: service,
        locale: const Locale('ru'),
        brightness: Brightness.light,
      ),
    );
    await tester.pump();

    expect(find.text('Служба Niko уже установлена'), findsOneWidget);
    expect(find.text('Открыть установленный Niko'), findsOneWidget);
    expect(find.text('Обновить службу'), findsOneWidget);

    await tester.ensureVisible(find.text('Открыть установленный Niko'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Открыть установленный Niko'));
    await tester.pumpAndSettle();
    expect(openedPath, r'C:\Program Files\Niko\niko.exe');
    expect(exited, isTrue);
  });
}
