import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:niko_desktop/app.dart';
import 'package:niko_desktop/daemon/daemon.dart';
import 'package:niko_desktop/platform/autostart.dart';
import 'package:niko_desktop/platform/desktop_integration.dart';
import 'package:niko_desktop/state/connection_controller.dart';
import 'package:niko_desktop/state/window_settings.dart';

import 'fonts.dart';
import 'main_screen_test.dart' show MemoryDaemon;

void main() {
  setUpAll(loadFonts);

  group('WindowSettings P5 fields', () {
    test('persists and reloads startup, tray, notifications, saveDirectory, exitAddressConfirmed', () async {
      final dir = await Directory.systemTemp.createTemp('niko-p5-settings-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/window.json');

      final ws = await WindowSettings.load(file);
      ws.connectOnStartup = true;
      ws.closeToTray = true;
      ws.notifications = false;
      ws.saveDirectory = '/tmp/niko-logs';
      ws.exitAddressConfirmed = true;
      await ws.save();

      final loaded = await WindowSettings.load(file);
      expect(loaded.connectOnStartup, isTrue);
      expect(loaded.closeToTray, isTrue);
      expect(loaded.notifications, isFalse);
      expect(loaded.saveDirectory, '/tmp/niko-logs');
      expect(loaded.exitAddressConfirmed, isTrue);
    });
  });

  group('DesktopAutostart', () {
    test('Linux writes, detects, and removes autostart .desktop entry', () async {
      final dir = await Directory.systemTemp.createTemp('niko-autostart-');
      addTearDown(() => dir.delete(recursive: true));
      final autostart = DesktopAutostart(
        isLinux: true,
        isWindows: false,
        executablePath: '/opt/niko/niko_desktop',
        environment: {'XDG_CONFIG_HOME': dir.path},
      );

      expect(await autostart.isEnabled(), isFalse);
      await autostart.setEnabled(true);
      expect(await autostart.isEnabled(), isTrue);

      final desktopFile = File('${dir.path}/autostart/niko.desktop');
      expect(desktopFile.existsSync(), isTrue);
      final contents = desktopFile.readAsStringSync();
      expect(contents, contains('Exec="/opt/niko/niko_desktop"'));
      expect(contents, contains('X-GNOME-Autostart-enabled=true'));

      await autostart.setEnabled(false);
      expect(await autostart.isEnabled(), isFalse);
      expect(desktopFile.existsSync(), isFalse);
    });

    test('Linux autostart prefers APPIMAGE path over transient mount executable', () async {
      final dir = await Directory.systemTemp.createTemp('niko-appimage-');
      addTearDown(() => dir.delete(recursive: true));
      final autostart = DesktopAutostart(
        isLinux: true,
        isWindows: false,
        environment: {
          'XDG_CONFIG_HOME': dir.path,
          'APPIMAGE': '/home/user/Applications/Niko.AppImage',
        },
      );
      await autostart.setEnabled(true);
      final contents = File('${dir.path}/autostart/niko.desktop').readAsStringSync();
      expect(contents, contains('Exec="/home/user/Applications/Niko.AppImage"'));
    });

    test('Windows queries, adds, and deletes HKCU Run key via reg.exe', () async {
      final calls = <List<String>>[];
      var installed = false;
      final autostart = DesktopAutostart(
        isLinux: false,
        isWindows: true,
        executablePath: r'C:\Program Files\Niko\niko_desktop.exe',
        runProcess: (exe, args) async {
          calls.add([exe, ...args]);
          if (args.first == 'query') {
            return ProcessResult(0, installed ? 0 : 1, installed ? 'Niko REG_SZ' : '', '');
          }
          if (args.first == 'add') installed = true;
          if (args.first == 'delete') installed = false;
          return ProcessResult(0, 0, '', '');
        },
      );

      expect(await autostart.isEnabled(), isFalse);
      await autostart.setEnabled(true);
      expect(await autostart.isEnabled(), isTrue);
      expect(calls.any((c) => c[0] == 'reg' && c[1] == 'add'), isTrue);

      await autostart.setEnabled(false);
      expect(await autostart.isEnabled(), isFalse);
      expect(calls.any((c) => c[0] == 'reg' && c[1] == 'delete'), isTrue);
    });
  });

  group('DesktopIntegration MethodChannel', () {
    test('invokes tray, notify, pickFile, pickDirectory and dispatches trayAction', () async {
      const channel = MethodChannel('niko/window-test');
      final recorded = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async {
          recorded.add(call);
          return switch (call.method) {
            'notify' => true,
            'pickFile' => '/tmp/sample.conf',
            'pickDirectory' => '/tmp/saves',
            _ => null,
          };
        },
      );
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      });

      final desktop = DesktopIntegration(channel: channel);
      final actions = <String>[];
      desktop.setTrayActionHandler(actions.add);

      await desktop.setCloseToTray(true);
      await desktop.updateTray(
        connected: true,
        statusLabel: 'Connected',
        profileName: 'EU-1',
        toggleLabel: 'Disconnect',
        openLabel: 'Open Niko',
        quitLabel: 'Quit',
      );
      await desktop.notify(title: 'Niko', body: 'Connected');
      expect(await desktop.pickFile(extensions: ['json', 'conf']), '/tmp/sample.conf');
      expect(await desktop.pickDirectory(), '/tmp/saves');

      expect(recorded.map((c) => c.method), ['setCloseToTray', 'updateTray', 'notify', 'pickFile', 'pickDirectory']);

      // Simulate native runner invoking trayAction("toggle")
      final codec = const StandardMethodCodec();
      final bytes = codec.encodeMethodCall(const MethodCall('trayAction', 'toggle'));
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
        channel.name,
        bytes,
        (_) {},
      );
      expect(actions, ['toggle']);
    });
  });

  group('MainScreen & NikoShell P5 daily-driver flows', () {
    Future<(MemoryDaemon, ConnectionController, WindowSettings, List<MethodCall>)> pumpShell(
      WidgetTester tester, {
      bool advanced = true,
      bool connectOnStartup = false,
      bool notifications = true,
    }) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final daemon = MemoryDaemon()
        ..api = 14
        ..profileRows = [
          const ProfileRow(id: 11, groupId: 1, order: 1, type: 'vless', name: 'Berlin', address: '198.51.100.10:443'),
          const ProfileRow(id: 12, groupId: 1, order: 2, type: 'socks', name: 'Fallback', address: '198.51.100.20:1080'),
        ]
        ..selectedId = 11;
      final controller = ConnectionController(daemon: daemon, loadConfig: null)..attach();
      final settings = WindowSettings.memory(
        advanced: advanced,
        language: 'en',
        connectOnStartup: connectOnStartup,
        notifications: notifications,
      );
      const channel = MethodChannel('niko/window-p5-widget');
      final channelCalls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async {
          channelCalls.add(call);
          if (call.method == 'notify') return true;
          return null;
        },
      );
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
        controller.dispose();
        settings.dispose();
      });

      await tester.pumpWidget(
        NikoApp(
          controller: controller,
          settings: settings,
          locale: const Locale('en'),
          desktop: DesktopIntegration(channel: channel),
        ),
      );
      await tester.pumpAndSettle();
      return (daemon, controller, settings, channelCalls);
    }

    testWidgets('TestConnection (D-MAIN-18) and ExitAddress with privacy confirmation (D-MAIN-03/14)', (tester) async {
      final (daemon, _, settings, _) = await pumpShell(tester);
      daemon.status.add(const ServiceState(ServicePhase.started));
      await tester.pump();
      await tester.pump();

      expect(find.text('Test connection'), findsOneWidget);
      expect(find.text('Exit IP'), findsOneWidget);

      await tester.tap(find.text('Test connection'));
      await tester.pumpAndSettle();
      expect(find.text('42 ms'), findsOneWidget);

      // First tap on Exit IP asks privacy confirmation
      expect(settings.exitAddressConfirmed, isFalse);
      await tester.tap(find.text('Exit IP'));
      await tester.pumpAndSettle();
      expect(find.text('Check external exit IP?'), findsOneWidget);
      expect(daemon.exitProvidersCalled, isEmpty);

      // Confirm -> persists flag and runs lookup
      await tester.tap(find.text('Check'));
      await tester.pumpAndSettle();
      expect(settings.exitAddressConfirmed, isTrue);
      expect(daemon.exitProvidersCalled, ['cloudflare']);
      expect(find.text('198.51.100.42 · DE · Frankfurt'), findsOneWidget);

      // Switch provider to ipinfo -> queries immediately without re-confirming
      await tester.tap(find.text('ipinfo'));
      await tester.pumpAndSettle();
      expect(daemon.exitProvidersCalled, ['cloudflare', 'ipinfo']);
    });

    testWidgets('D-STATE-RELOAD banner appears on rule change while connected and reconnect clears it', (tester) async {
      final (daemon, _, _, _) = await pumpShell(tester);
      daemon.status.add(const ServiceState(ServicePhase.started));
      await tester.pump();
      await tester.pump();

      // Open Rules, add a rule while core is running
      await tester.tap(find.text('Rules'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New rule'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      // Return Home -> reload banner should be visible
      await tester.tap(find.text('Home'));
      await tester.pumpAndSettle();
      expect(find.text('Settings changed'), findsOneWidget);
      expect(find.text('Reconnect'), findsOneWidget);

      // Tap Reconnect -> calls daemon.connect and clears banner
      final before = daemon.connected.length;
      await tester.tap(find.text('Reconnect'));
      await tester.pumpAndSettle();
      expect(daemon.connected.length, before + 1);
      expect(find.text('Settings changed'), findsNothing);
    });

    testWidgets('connectOnStartup (D-SET-05) auto-connects selected profile on ready', (tester) async {
      final (daemon, _, _, _) = await pumpShell(tester, connectOnStartup: true);
      expect(daemon.connected, [0]);
    });

    testWidgets('tray sync and desktop notification fire on connect transition', (tester) async {
      final (daemon, _, _, calls) = await pumpShell(tester, notifications: true);
      daemon.status.add(const ServiceState(ServicePhase.started));
      await tester.pump();
      await tester.pump();

      final trayUpdates = calls.where((c) => c.method == 'updateTray').toList();
      expect(trayUpdates, isNotEmpty);
      expect((trayUpdates.last.arguments as Map)['connected'], isTrue);

      final notifications = calls.where((c) => c.method == 'notify').toList();
      expect(notifications, isNotEmpty);
      expect((notifications.last.arguments as Map)['body'], contains('Berlin'));
    });

    testWidgets('NodesScreen supports custom group create, latency test, and manual profile editor', (tester) async {
      final (daemon, _, _, _) = await pumpShell(tester);
      await tester.tap(find.text('Nodes'));
      await tester.pumpAndSettle();

      // Test latency on current group
      await tester.tap(find.text('Test latency'));
      await tester.pumpAndSettle();
      expect(find.text('140 ms'), findsOneWidget);
      expect(find.text('150 ms'), findsOneWidget);

      // Create custom group
      await tester.tap(find.text('New group'));
      await tester.pumpAndSettle();
      final groupField = find.byType(EditableText).last;
      await tester.enterText(groupField, 'Work');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(daemon.groupRows.any((g) => g.name == 'Work'), isTrue);

      // Open manual profile editor
      await tester.tap(find.text('New profile'));
      await tester.pumpAndSettle();
      expect(find.text('Protocol'), findsOneWidget);
      await tester.ensureVisible(find.text('Cancel'));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    });

    testWidgets('RulesScreen reset rules clears all rules after confirmation', (tester) async {
      final (daemon, _, _, _) = await pumpShell(tester);
      daemon.ruleRows = [
        const RuleRow(id: 1, name: 'Test rule', domains: 'example.com', outbound: -1),
      ];
      await tester.tap(find.text('Rules'));
      await tester.pumpAndSettle();
      expect(find.text('Test rule'), findsOneWidget);

      await tester.tap(find.text('Reset rules'));
      await tester.pumpAndSettle();
      expect(find.text('Delete all route rules?'), findsOneWidget);
      await tester.tap(find.text('Reset rules').last);
      await tester.pumpAndSettle();
      expect(daemon.ruleRows, isEmpty);
    });
  });
}
