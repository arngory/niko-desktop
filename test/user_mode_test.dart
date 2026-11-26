import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:niko_desktop/app.dart';
import 'package:niko_desktop/daemon/daemon.dart';
import 'package:niko_desktop/daemon/locator.dart';
import 'package:niko_desktop/daemon/user_mode_daemon.dart';
import 'package:niko_desktop/daemon/worker_process.dart';
import 'package:niko_desktop/platform/service_install.dart';
import 'package:niko_desktop/platform/user_store_migration.dart';
import 'package:niko_desktop/state/connection_controller.dart';

import 'main_screen_test.dart' show MemoryDaemon;

class _UserModeDaemon extends MemoryDaemon {
  _UserModeDaemon({this.privileged = false, this.tun = false});

  final bool privileged;
  final bool tun;
  List<int>? lastImported;
  StoreImportResult nextImportResult = const StoreImportResult(groups: 1, profiles: 2, rules: 1, nodes: 1);

  @override
  Future<NikoInfo> nikoInfo() async => NikoInfo(
        nikoVersion: '0.1.0-test',
        coreVersion: '1.13.0-test',
        storeSchema: 4,
        api: 13,
        privileged: privileged,
        tun: tun,
      );

  @override
  Future<StoreImportResult> importUserStore(List<int> snapshotJson) async {
    lastImported = List<int>.from(snapshotJson);
    return nextImportResult;
  }
}

void main() {
  group('User-mode locator and store detection', () {
    test('locateLinuxDaemon falls back to reachable user-mode socket when system service is absent', () async {
      final loc = await locateLinuxDaemon(
        bundledDaemonPath: '/tmp/niko/resources/daemon/niko-daemon',
        environment: const {'XDG_RUNTIME_DIR': '/run/user/1000'},
        fileExists: (_) => true,
        probeSocket: (path) async => path == '/run/user/1000/niko/niko-daemon.sock',
        runProcess: (exe, args) async => ProcessResult(1, 3, '{"state":"not-installed"}', ''),
      );
      expect(loc.activeCandidate, isNotNull);
      expect(loc.activeCandidate!.kind, DaemonCandidateKind.userMode);
      expect(loc.socketPath, '/run/user/1000/niko/niko-daemon.sock');
      expect(loc.candidates.length, 3);
    });

    test('locateLinuxDaemon prefers system service socket over user-mode socket when both are reachable', () async {
      final loc = await locateLinuxDaemon(
        bundledDaemonPath: '/tmp/niko/resources/daemon/niko-daemon',
        environment: const {'XDG_RUNTIME_DIR': '/run/user/1000'},
        fileExists: (_) => true,
        probeSocket: (_) async => true,
        runProcess: (exe, args) async => ProcessResult(1, 0, '{"state":"running"}', ''),
      );
      expect(loc.activeCandidate!.kind, DaemonCandidateKind.systemService);
      expect(loc.socketPath, linuxSystemSocketPath);
    });

    test('hasUnmigratedUserStore detects store.json and markUserStoreMigrated renames directory', () async {
      final tmp = await Directory.systemTemp.createTemp('niko-usermode-store-');
      addTearDown(() async {
        if (tmp.existsSync()) await tmp.delete(recursive: true);
      });

      final dataDir = '${tmp.path}/user-daemon';
      expect(hasUnmigratedUserStore(dataDir), isFalse);

      final storeFile = File('$dataDir/users/abc123/niko/store.json')..createSync(recursive: true);
      storeFile.writeAsStringSync('{"schema":4}\n');
      expect(hasUnmigratedUserStore(dataDir), isTrue);

      await markUserStoreMigrated(dataDir, now: DateTime.fromMillisecondsSinceEpoch(1800000000000));
      expect(Directory(dataDir).existsSync(), isFalse);
      expect(Directory('$dataDir.migrated-1800000000').existsSync(), isTrue);
      expect(hasUnmigratedUserStore(dataDir), isFalse);
    });

    test('WorkerProcess passes --user-mode and --working-directory when userMode is true', () async {
      List<String>? capturedArgs;
      final fakeStdout = StreamController<List<int>>();
      final fakeStderr = StreamController<List<int>>();
      final fakeStdinSink = StreamController<List<int>>.broadcast();
      final fakeExit = Completer<int>();

      final worker = WorkerProcess(
        daemonExecutablePath: r'C:\portable\resources\daemon\niko-daemon.exe',
        socketDirectory: r'C:\tmp\run',
        userMode: true,
        workingDirectory: r'C:\Users\u\AppData\Local\Niko\user-daemon',
        windowPid: 4321,
        startProcess: (exe, args) async {
          capturedArgs = args;
          unawaited(Future<void>.microtask(() {
            fakeStdout.add(utf8.encode('READY C:\\tmp\\run\\w-test.sock\n'));
          }));
          return _FakeProcess(
            pid: 9876,
            stdout: fakeStdout.stream,
            stderr: fakeStderr.stream,
            stdin: _FakeIOSink(fakeStdinSink, () {
              if (!fakeExit.isCompleted) fakeExit.complete(0);
            }),
            exitCode: fakeExit.future,
          );
        },
      );

      final ep = await worker.ensureReady();
      expect(ep.bindPath, r'C:\tmp\run\w-test.sock');
      expect(capturedArgs, isNotNull);
      expect(capturedArgs, contains('--user-mode'));
      expect(capturedArgs, contains('--working-directory'));
      expect(capturedArgs, contains(r'C:\Users\u\AppData\Local\Niko\user-daemon'));
      await worker.dispose();
    });
  });

  group('User-mode UI and store migration flow', () {
    testWidgets('shows user-mode banner, prompts install for VPN, and triggers install CTA', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final daemon = _UserModeDaemon(privileged: false, tun: false);
      final controller = ConnectionController(daemon: daemon, loadConfig: null)..attach();
      var installTapped = false;
      final serviceInstall = ServiceController(
        mode: InstallMode.notInstalled,
        installedWindowPath: '/tmp/niko',
        runElevatedInstall: () async {
          installTapped = true;
          return const InstallResult.exit(126);
        },
      );

      await tester.pumpWidget(NikoApp(
        controller: controller,
        locale: const Locale('en'),
        brightness: Brightness.dark,
        serviceInstall: serviceInstall,
      ));
      await tester.pumpAndSettle();

      expect(controller.isUserMode, isTrue);
      expect(find.text('User mode (proxy only)'), findsOneWidget);
      expect(find.text('Install service'), findsOneWidget);

      // Switching to VPN mode highlights VPN-needs-service message
      await tester.tap(find.text('VPN'));
      await tester.pumpAndSettle();
      expect(find.text('VPN mode requires the Niko service'), findsOneWidget);

      // Tapping Install service invokes ServiceController
      await tester.tap(find.text('Install service'));
      await tester.pumpAndSettle();
      expect(installTapped, isTrue);

      controller.dispose();
    });

    testWidgets('shows migration banner on privileged service and transfers snapshot on tap', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final daemon = _UserModeDaemon(privileged: true, tun: true);
      final controller = ConnectionController(daemon: daemon, loadConfig: null)..attach();
      var markedMigrated = false;

      final migration = UserStoreMigrationController(
        userDataDir: '/tmp/fake-user-daemon',
        hasUnmigrated: (_) => !markedMigrated,
        markMigrated: (_) async {
          markedMigrated = true;
        },
        exportUserSnapshot: () async => utf8.encode('{"version":1}'),
        getServiceDaemon: () => controller.privileged ? controller.daemon : null,
      );

      await tester.pumpWidget(NikoApp(
        controller: controller,
        locale: const Locale('en'),
        brightness: Brightness.dark,
        userMigration: migration,
      ));
      await tester.pumpAndSettle();

      expect(find.text('Data from user mode found'), findsOneWidget);
      expect(find.text('Transfer'), findsOneWidget);

      await tester.tap(find.text('Transfer'));
      await tester.pumpAndSettle();

      expect(markedMigrated, isTrue);
      expect(daemon.lastImported, utf8.encode('{"version":1}'));
      expect(find.text('Transferred to service: 2 profiles, 1 rules, 1 nodes'), findsOneWidget);

      controller.dispose();
      migration.dispose();
    });
  });
}

class _FakeProcess implements Process {
  _FakeProcess({
    required this.pid,
    required this.stdout,
    required this.stderr,
    required this.stdin,
    required this.exitCode,
  });

  @override
  final int pid;
  @override
  final Stream<List<int>> stdout;
  @override
  final Stream<List<int>> stderr;
  @override
  final IOSink stdin;
  @override
  final Future<int> exitCode;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
}

class _FakeIOSink implements IOSink {
  _FakeIOSink(this._controller, this._onClose);

  final StreamController<List<int>> _controller;
  final void Function() _onClose;

  @override
  Encoding encoding = utf8;

  @override
  void add(List<int> data) => _controller.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<void> addStream(Stream<List<int>> stream) async {}
  @override
  Future<void> close() async {
    _onClose();
    await _controller.close();
  }

  @override
  Future<void> get done => _controller.done;
  @override
  Future<void> flush() async {}
  @override
  void write(Object? object) {}
  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) {}
  @override
  void writeCharCode(int charCode) {}
  @override
  void writeln([Object? object = '']) {}
}
